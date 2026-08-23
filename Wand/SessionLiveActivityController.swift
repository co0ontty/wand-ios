import Foundation
import ActivityKit
import os

/// 会话 Live Activity 管理器：所有活跃会话聚合进**同一条**灵动岛活动（长条样式），
/// 条内每个会话显示缩略标题 + 运行状态。回复成功的会话保留「已完成」态片刻再移除，
/// 会话退出 / 被杀时立即从条里移除；条空了整条活动一起收掉。
/// 系统关闭实时活动、或设置页开关关闭时全部是 no-op。
///
/// 局限（自签 sideload 没有 APNs push token）：活动只能由 App 进程本地更新，
/// App 被系统挂起后状态会冻结在最后一次更新——stale date 设为 60s，过期后系统
/// 把活动标灰；「已完成」的自动移除定时器也只在 App 存活时生效。
@MainActor
final class SessionLiveActivityController {
    static let shared = SessionLiveActivityController()

    enum SessionState: String {
        case responding
        case permission
        case done
    }

    private init() {}

    /// 「已完成」会话在长条里保留的时长，超时自动移除。
    private static let doneLingerSeconds: UInt64 = 20
    /// 条内最多保留的会话数（Live Activity 状态有 4KB 上限）。
    private static let maxEntries = 8
    /// 缩略标题最大长度。
    private static let maxTitleLength = 24
    private static let maxTaskTitleLength = 40
    private let logger = Logger(subsystem: "com.wand.app", category: "LiveActivity")

    /// 存储活动参考与辅助状态：全局唯一的 Activity 实例、条内会话表、完成后延迟移除定时器。
    @MainActor
    private enum ActivityStore {
        static var activity: Activity<SessionActivityAttributes>?
        static var entries: [SessionActivityAttributes.SessionEntry] = []
        static var publishedEntries: [SessionActivityAttributes.SessionEntry] = []
        static var scheduledEntries: [SessionActivityAttributes.SessionEntry] = []
        static var doneRemovalTasks: [String: Task<Void, Never>] = [:]
        static var startedAtBySession: [String: Date] = [:]
        static var operationTask: Task<Void, Never>?
        static var operationRevision = 0
        static var endingActivityIDs: Set<String> = []
    }

    private var enabled: Bool {
        ServerStore.shared.liveActivityEnabled
            && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 会话开始回复：插入（或刷新）条内对应条目，必要时创建活动。
    func start(
        sessionId: String,
        serverID: String? = nil,
        title: String,
        provider: String?,
        state: SessionState = .responding,
        taskTitle: String?,
        queuedCount: Int = 0
    ) {
        guard enabled else { return }
        let serverID = serverID ?? ServerStore.shared.activeServerID
        guard serverID == ServerStore.shared.activeServerID else { return }
        restoreExistingActivityIfNeeded()
        cancelDoneRemoval(sessionId, serverID: serverID)
        upsert(
            sessionId: sessionId, serverID: serverID, title: title, provider: provider, state: state,
            taskTitle: taskTitle, queuedCount: queuedCount
        )
        sync(allowCreate: true)
    }

    /// 按服务端快照恢复或更新活动。已有运行中的会话不再依赖本机先点一次发送。
    func sync(snapshot: SessionSnapshot, serverID: String? = nil) {
        let serverID = serverID ?? ServerStore.shared.activeServerID
        guard serverID == ServerStore.shared.activeServerID else { return }
        if snapshot.hasPendingPermission {
            start(
                sessionId: snapshot.id, serverID: serverID,
                title: snapshot.displayTitle, provider: snapshot.provider,
                state: .permission, taskTitle: snapshot.currentTaskTitle,
                queuedCount: snapshot.queuedMessages?.count ?? 0
            )
        } else if snapshot.isResponding {
            start(
                sessionId: snapshot.id, serverID: serverID,
                title: snapshot.displayTitle, provider: snapshot.provider,
                taskTitle: snapshot.currentTaskTitle, queuedCount: snapshot.queuedMessages?.count ?? 0
            )
        } else if snapshot.isEnded {
            end(sessionId: snapshot.id, serverID: serverID, immediately: true)
        } else if let entry = ActivityStore.entries.first(where: {
            $0.id == snapshot.id && $0.serverID == serverID
        }),
                  !entry.isDone {
            end(sessionId: snapshot.id, serverID: serverID)
        }
    }

    /// 列表轮询是全局事实来源：恢复所有活跃会话，并清掉服务端已不存在的遗留条目。
    func reconcile(snapshots: [SessionSnapshot], serverID: String? = nil) {
        guard ServerStore.shared.liveActivityEnabled else {
            endAll()
            return
        }
        let serverID = serverID ?? ServerStore.shared.activeServerID
        guard serverID == ServerStore.shared.activeServerID else { return }
        restoreExistingActivityIfNeeded()
        // iOS only polls the selected endpoint. Do not let a refresh from that endpoint renew
        // stale entries left by an inactive server in the one process-wide Live Activity.
        let inactiveEntries = ActivityStore.entries.filter { $0.serverID != serverID }
        for entry in inactiveEntries {
            removeImmediately(sessionId: entry.id, serverID: entry.serverID)
        }
        let visibleIds = Set(snapshots.filter { !($0.archived ?? false) }.map(\.id))
        for snapshot in snapshots where !(snapshot.archived ?? false) {
            sync(snapshot: snapshot, serverID: serverID)
        }
        let missingIds = ActivityStore.entries
            .filter { $0.serverID == serverID }
            .map(\.id)
            .filter { !visibleIds.contains($0) }
        for id in missingIds {
            end(sessionId: id, serverID: serverID, immediately: true)
        }
        sync(allowCreate: !ActivityStore.entries.isEmpty, refresh: true)
    }

    func endAll() {
        for task in ActivityStore.doneRemovalTasks.values { task.cancel() }
        ActivityStore.doneRemovalTasks.removeAll()
        ActivityStore.entries.removeAll()
        ActivityStore.publishedEntries.removeAll()
        ActivityStore.scheduledEntries.removeAll()
        ActivityStore.startedAtBySession.removeAll()
        ActivityStore.operationRevision &+= 1
        let activities = Activity<SessionActivityAttributes>.activities
        ActivityStore.activity = nil
        ActivityStore.endingActivityIDs.formUnion(activities.map(\.id))
        enqueueActivityOperation {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
                ActivityStore.endingActivityIDs.remove(activity.id)
            }
        }
    }

    func endAll(serverID: String) {
        restoreExistingActivityIfNeeded()
        let entries = ActivityStore.entries.filter { $0.serverID == serverID }
        for entry in entries {
            removeImmediately(sessionId: entry.id, serverID: entry.serverID)
        }
        sync(allowCreate: !ActivityStore.entries.isEmpty, refresh: true)
    }

    /// 结束：immediately = true（会话退出 / 被杀 / 离开页面）直接从条里移除；
    /// 否则视为成功完成，切「已完成」停留片刻再自动移除。
    func end(sessionId: String, serverID: String? = nil, immediately: Bool = false) {
        restoreExistingActivityIfNeeded()
        let serverID = serverID ?? ServerStore.shared.activeServerID
        guard let index = ActivityStore.entries.firstIndex(where: {
            $0.id == sessionId && $0.serverID == serverID
        }) else { return }
        let key = scopedKey(sessionId, serverID: serverID)
        cancelDoneRemoval(sessionId, serverID: serverID)
        if immediately {
            ActivityStore.entries.remove(at: index)
            ActivityStore.startedAtBySession[key] = nil
        } else {
            ActivityStore.entries[index].stateRaw = SessionState.done.rawValue
            ActivityStore.entries[index].taskTitle = nil
            ActivityStore.entries[index].queuedCount = 0
            ActivityStore.entries[index].startedAt = nil
            ActivityStore.startedAtBySession[key] = nil
            scheduleDoneRemoval(sessionId, serverID: serverID)
        }
        sync(allowCreate: false)
    }

    private func removeImmediately(sessionId: String, serverID: String?) {
        let key = scopedKey(sessionId, serverID: serverID)
        cancelDoneRemoval(sessionId, serverID: serverID)
        ActivityStore.entries.removeAll { $0.id == sessionId && $0.serverID == serverID }
        ActivityStore.startedAtBySession[key] = nil
    }

#if DEBUG
    /// Simulator-only fixture hook. Launch with WAND_MOCK_LIVE_ACTIVITY=single|multi|permission|done.
    func installMockScenario(_ scenario: String) {
        guard enabled else {
            logger.warning("Live Activity mock skipped because activities are disabled")
            return
        }
        for task in ActivityStore.doneRemovalTasks.values { task.cancel() }
        ActivityStore.doneRemovalTasks.removeAll()
        switch scenario {
        case "multi":
            ActivityStore.entries = [
                mockEntry(
                    id: "mock-codex-1",
                    title: "wand iOS 终端适配",
                    provider: "codex",
                    state: .responding,
                    taskTitle: "验证 PTY 输入栏、终端缩放和灵动岛入口",
                    queuedCount: 2
                ),
                mockEntry(
                    id: "mock-claude-2",
                    title: "发布检查清单",
                    provider: "claude",
                    state: .permission,
                    taskTitle: "需要确认读取 docs/screenshots 目录",
                    queuedCount: 0
                ),
                mockEntry(
                    id: "mock-opencode-3",
                    title: "OpenCode 回归",
                    provider: "opencode",
                    state: .done,
                    taskTitle: nil,
                    queuedCount: 0
                )
            ]
        case "permission":
            ActivityStore.entries = [
                mockEntry(
                    id: "mock-permission",
                    title: "权限确认",
                    provider: "claude",
                    state: .permission,
                    taskTitle: "Codex 请求写入 iOS Widget 预览截图",
                    queuedCount: 1
                )
            ]
        case "done":
            ActivityStore.entries = [
                mockEntry(
                    id: "mock-done",
                    title: "会话已完成",
                    provider: "codex",
                    state: .done,
                    taskTitle: nil,
                    queuedCount: 0
                )
            ]
        default:
            ActivityStore.entries = [
                mockEntry(
                    id: "mock-single",
                    title: "灵动岛交互检查",
                    provider: "codex",
                    state: .responding,
                    taskTitle: "整理展开卡片内容，并确认点击不会直接进入会话",
                    queuedCount: 2
                )
            ]
        }
        sync(allowCreate: true)
    }

    private func mockEntry(
        id: String,
        title: String,
        provider: String,
        state: SessionState,
        taskTitle: String?,
        queuedCount: Int
    ) -> SessionActivityAttributes.SessionEntry {
        SessionActivityAttributes.SessionEntry(
            id: id,
            title: String(title.prefix(Self.maxTitleLength)),
            providerRaw: provider,
            stateRaw: state.rawValue,
            taskTitle: taskTitle.map { String($0.prefix(Self.maxTaskTitleLength)) },
            queuedCount: queuedCount,
            startedAt: state == .responding ? Date().addingTimeInterval(-94) : nil
        )
    }
#endif

    // MARK: - 内部

    private func enqueueActivityOperation(
        latestRevision: Int? = nil,
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let previous = ActivityStore.operationTask
        ActivityStore.operationTask = Task { @MainActor in
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            if let latestRevision,
               latestRevision != ActivityStore.operationRevision {
                return
            }
            await operation()
        }
    }

    private func restoreExistingActivityIfNeeded() {
        guard ActivityStore.activity == nil else { return }
        let activities = Array(Activity<SessionActivityAttributes>.activities)
        let restorable = activities.filter {
            !ActivityStore.endingActivityIDs.contains($0.id)
                && ($0.activityState == .active || $0.activityState == .stale)
        }
        guard let activity = restorable.first else { return }
        ActivityStore.activity = activity
        ActivityStore.entries = activity.content.state.sessions
        let legacyServerID = ServerStore.shared.activeServerID
        ActivityStore.entries = ActivityStore.entries.map { entry in
            var scoped = entry
            if scoped.serverID == nil { scoped.serverID = legacyServerID }
            return scoped
        }
        ActivityStore.publishedEntries = ActivityStore.entries
        ActivityStore.scheduledEntries = ActivityStore.entries
        for entry in ActivityStore.entries {
            if let startedAt = entry.startedAt {
                ActivityStore.startedAtBySession[scopedKey(entry.id, serverID: entry.serverID)] = startedAt
            }
        }
        for duplicate in restorable.dropFirst() {
            ActivityStore.endingActivityIDs.insert(duplicate.id)
            enqueueActivityOperation {
                await duplicate.end(nil, dismissalPolicy: .immediate)
                ActivityStore.endingActivityIDs.remove(duplicate.id)
            }
        }
    }

    private func upsert(
        sessionId: String, serverID: String?, title: String, provider: String?, state: SessionState,
        taskTitle: String?, queuedCount: Int
    ) {
        let key = scopedKey(sessionId, serverID: serverID)
        let shortTitle = String(title.prefix(Self.maxTitleLength))
        let shortTaskTitle = taskTitle.map { String($0.prefix(Self.maxTaskTitleLength)) }
        let startedAt: Date?
        if state == .responding {
            startedAt = ActivityStore.startedAtBySession[key] ?? Date()
            ActivityStore.startedAtBySession[key] = startedAt
        } else {
            startedAt = nil
            ActivityStore.startedAtBySession[key] = nil
        }
        if let index = ActivityStore.entries.firstIndex(where: {
            $0.id == sessionId && $0.serverID == serverID
        }) {
            ActivityStore.entries[index].title = shortTitle
            ActivityStore.entries[index].providerRaw = provider ?? "claude"
            ActivityStore.entries[index].stateRaw = state.rawValue
            ActivityStore.entries[index].taskTitle = shortTaskTitle
            ActivityStore.entries[index].queuedCount = queuedCount
            ActivityStore.entries[index].startedAt = startedAt
        } else {
            ActivityStore.entries.append(SessionActivityAttributes.SessionEntry(
                id: sessionId, serverID: serverID,
                title: shortTitle, providerRaw: provider ?? "claude",
                stateRaw: state.rawValue, taskTitle: shortTaskTitle, queuedCount: queuedCount,
                startedAt: startedAt
            ))
            trimEntriesIfNeeded()
        }
    }

    /// 超出上限时优先挤掉最早的「已完成」，否则挤掉最早进条的会话。
    private func trimEntriesIfNeeded() {
        while ActivityStore.entries.count > Self.maxEntries {
            let victim = ActivityStore.entries.firstIndex { $0.isDone } ?? 0
            let victimEntry = ActivityStore.entries[victim]
            let victimId = victimEntry.id
            cancelDoneRemoval(victimId, serverID: victimEntry.serverID)
            ActivityStore.startedAtBySession[scopedKey(victimId, serverID: victimEntry.serverID)] = nil
            ActivityStore.entries.remove(at: victim)
        }
    }

    private func scheduleDoneRemoval(_ sessionId: String, serverID: String?) {
        let key = scopedKey(sessionId, serverID: serverID)
        ActivityStore.doneRemovalTasks[key] = Task {
            try? await Task.sleep(nanoseconds: Self.doneLingerSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            ActivityStore.doneRemovalTasks[key] = nil
            ActivityStore.entries.removeAll {
                $0.id == sessionId && $0.serverID == serverID && $0.isDone
            }
            ActivityStore.startedAtBySession[key] = nil
            sync(allowCreate: false)
        }
    }

    private func cancelDoneRemoval(_ sessionId: String, serverID: String?) {
        ActivityStore.doneRemovalTasks.removeValue(forKey: scopedKey(sessionId, serverID: serverID))?.cancel()
    }

    private func scopedKey(_ sessionId: String, serverID: String?) -> String {
        "\(serverID ?? "legacy"):\(sessionId)"
    }

    /// 把当前条目集合同步到系统：空 → 收掉活动；非空 → 更新或（允许时）创建。
    private func sync(allowCreate: Bool, refresh: Bool = false) {
        let entries = ActivityStore.entries.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }

        if entries.isEmpty {
            guard let activity = ActivityStore.activity else { return }
            ActivityStore.operationRevision &+= 1
            ActivityStore.activity = nil
            ActivityStore.publishedEntries.removeAll()
            ActivityStore.scheduledEntries.removeAll()
            ActivityStore.endingActivityIDs.insert(activity.id)
            enqueueActivityOperation {
                await activity.end(nil, dismissalPolicy: .immediate)
                ActivityStore.endingActivityIDs.remove(activity.id)
            }
            return
        }
        restoreExistingActivityIfNeeded()
        guard let activity = ActivityStore.activity else {
            guard allowCreate else { return }
            ActivityStore.operationRevision &+= 1
            let revision = ActivityStore.operationRevision
            requestActivity(entries: entries, revision: revision)
            return
        }
        guard refresh
                || entries != ActivityStore.publishedEntries
                || entries != ActivityStore.scheduledEntries else { return }
        ActivityStore.operationRevision &+= 1
        let revision = ActivityStore.operationRevision
        ActivityStore.scheduledEntries = entries
        let state = SessionActivityAttributes.ContentState(sessions: entries, updatedAt: Date())
        enqueueActivityOperation(latestRevision: revision) {
            guard ActivityStore.activity?.id == activity.id,
                  activity.activityState == .active || activity.activityState == .stale else {
                if ActivityStore.activity?.id == activity.id {
                    ActivityStore.activity = nil
                    ActivityStore.publishedEntries.removeAll()
                    ActivityStore.scheduledEntries.removeAll()
                }
                if allowCreate {
                    self.requestActivity(entries: entries, revision: revision)
                }
                return
            }
            await activity.update(ActivityContent(state: state, staleDate: self.staleDate()))
            guard revision == ActivityStore.operationRevision,
                  ActivityStore.activity?.id == activity.id else { return }
            ActivityStore.publishedEntries = entries
        }
    }

    private func requestActivity(
        entries: [SessionActivityAttributes.SessionEntry],
        revision: Int
    ) {
        let state = SessionActivityAttributes.ContentState(sessions: entries, updatedAt: Date())
        ActivityStore.scheduledEntries = entries
        enqueueActivityOperation(latestRevision: revision) {
            guard ActivityStore.activity == nil, !ActivityStore.entries.isEmpty else { return }
            do {
                ActivityStore.activity = try Activity.request(
                    attributes: SessionActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: self.staleDate())
                )
                if revision == ActivityStore.operationRevision {
                    ActivityStore.publishedEntries = entries
                }
            } catch {
                self.logger.error("Live Activity 创建失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func staleDate() -> Date {
        // App 被挂起后无法继续更新；60s 没更新就让系统把活动标记为过期（变灰）。
        Date().addingTimeInterval(60)
    }
}

/// 会话对外呈现的统一入口：调用方只报告会话状态，内部再分发到灵动岛和本地通知。
@MainActor
final class SessionPresenceController {
    static let shared = SessionPresenceController()

    private init() {}

    func start(
        sessionId: String,
        serverID: String? = nil,
        title: String,
        provider: String?,
        state: SessionLiveActivityController.SessionState = .responding,
        taskTitle: String?,
        queuedCount: Int = 0
    ) {
        SessionLiveActivityController.shared.start(
            sessionId: sessionId,
            serverID: serverID,
            title: title,
            provider: provider,
            state: state,
            taskTitle: taskTitle,
            queuedCount: queuedCount
        )
    }

    func sync(snapshot: SessionSnapshot, serverID: String? = nil) {
        SessionLiveActivityController.shared.sync(snapshot: snapshot, serverID: serverID)
    }

    func reconcile(snapshots: [SessionSnapshot], serverID: String? = nil) {
        let serverID = serverID ?? ServerStore.shared.activeServerID
        guard serverID == ServerStore.shared.activeServerID else { return }
        SessionLiveActivityController.shared.reconcile(snapshots: snapshots, serverID: serverID)
        SessionNotificationController.shared.reconcile(snapshots: snapshots, serverID: serverID)
    }

    func end(sessionId: String, serverID: String? = nil, immediately: Bool = false) {
        SessionLiveActivityController.shared.end(
            sessionId: sessionId,
            serverID: serverID,
            immediately: immediately
        )
    }

    func endAll() {
        SessionLiveActivityController.shared.endAll()
    }

    func endAll(serverID: String) {
        SessionLiveActivityController.shared.endAll(serverID: serverID)
    }

#if DEBUG
    func installMockScenario(_ scenario: String) {
        SessionLiveActivityController.shared.installMockScenario(scenario)
    }
#endif
}
