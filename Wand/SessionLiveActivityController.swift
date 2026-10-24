import Foundation
import ActivityKit
import UIKit
import os

/// 会话 Live Activity 管理器：所有活跃会话聚合进**同一条**灵动岛活动（长条样式），
/// 条内每个会话显示缩略标题 + 运行状态。回复成功的会话保留「已完成」态片刻再移除，
/// 会话退出 / 被杀时立即从条里移除；条空了整条活动一起收掉。
/// 系统关闭实时活动、或设置页开关关闭时全部是 no-op。
///
/// 前台创建同一条聚合活动并请求独立 ActivityKit token；服务器可在 App 挂起后更新/结束。
/// 未配置远程链路时保留原本地更新，过期后明确显示离线；不通过静默推送保活或后台远程新建。
@MainActor
final class SessionLiveActivityController {
    static let shared = SessionLiveActivityController()

    enum SessionState: String {
        case responding
        case permission
        case waitingInput = "waiting-input"
        case background
        case failed
        case stopped
        case done
    }

    private init() {}

    /// 「已完成」会话在长条里保留的时长，超时自动移除。
    private static let doneLingerSeconds: UInt64 = 12
    private static let failureLingerSeconds: UInt64 = 30
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
        queuedCount: Int = 0,
        startedAt: Date? = nil,
        engine: String? = nil,
        pendingPrompt: String? = nil
    ) {
        guard enabled else { return }
        let serverID = serverID ?? ServerStore.shared.activeServerID
        guard serverID == ServerStore.shared.activeServerID else { return }
        restoreExistingActivityIfNeeded()
        cancelDoneRemoval(sessionId, serverID: serverID)
        upsert(
            sessionId: sessionId, serverID: serverID, title: title, provider: provider, state: state,
            taskTitle: taskTitle, queuedCount: queuedCount, startedAt: startedAt, engine: engine,
            pendingPrompt: pendingPrompt
        )
        sync(allowCreate: true)
    }

    /// 按服务端快照恢复或更新活动。已有运行中的会话不再依赖本机先点一次发送。
    func sync(snapshot: SessionSnapshot, serverID: String? = nil) {
        let serverID = serverID ?? ServerStore.shared.activeServerID
        guard serverID == ServerStore.shared.activeServerID else { return }
        let previous = ActivityStore.entries.first { $0.id == snapshot.id && $0.serverID == serverID }
        let next: SessionState?
        if snapshot.hasPendingPermission { next = .permission }
        else if snapshot.activityStatus == "waiting-input" { next = .waitingInput }
        else if Self.isActivityResponding(snapshot) { next = snapshot.structuredState?.phase == "background" ? .background : .responding }
        else if snapshot.status == "failed" && previous != nil { next = .failed }
        else if snapshot.status == "stopped" && previous != nil { next = .stopped }
        else { next = nil }
        if let next {
            // Do not renew a finished entry on every poll, otherwise it never leaves the island.
            if previous?.stateRaw == next.rawValue && previous?.isFinished == true { return }
            start(sessionId: snapshot.id, serverID: serverID, title: snapshot.displayTitle, provider: snapshot.provider,
                state: next, taskTitle: snapshot.currentTaskTitle, queuedCount: snapshot.queuedMessages?.count ?? 0,
                startedAt: SessionTimeFormatting.date(from: snapshot.structuredState?.turnStartedAt),
                engine: snapshot.structuredState?.engine, pendingPrompt: Self.pendingPrompt(of: snapshot))
            if next == .failed || next == .stopped { scheduleDoneRemoval(snapshot.id, serverID: serverID) }
        } else if let previous, !previous.isFinished {
            if snapshot.isEnded { end(sessionId: snapshot.id, serverID: serverID, immediately: true) }
            else if previous.isResponding || previous.isBackground { end(sessionId: snapshot.id, serverID: serverID) }
            else { end(sessionId: snapshot.id, serverID: serverID, immediately: true) }
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
        for activity in activities { LiveActivityPushController.shared.retire(activityID: activity.id) }
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
            let finishedAt = ActivityStore.entries[index].stateRaw == SessionState.done.rawValue
                ? ActivityStore.entries[index].finishedAt ?? Date() : Date()
            ActivityStore.entries[index].stateRaw = SessionState.done.rawValue
            ActivityStore.entries[index].finishedAt = finishedAt
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
                    queuedCount: 0,
                    pendingPrompt: "读取文件 · docs/screenshots"
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
                    queuedCount: 1,
                    pendingPrompt: "写入文件 · ios/WandWidgets"
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
        queuedCount: Int,
        pendingPrompt: String? = nil
    ) -> SessionActivityAttributes.SessionEntry {
        SessionActivityAttributes.SessionEntry(
            id: id,
            title: String(title.prefix(Self.maxTitleLength)),
            providerRaw: provider,
            stateRaw: state.rawValue,
            taskTitle: taskTitle.map { String($0.prefix(Self.maxTaskTitleLength)) },
            queuedCount: queuedCount,
            startedAt: state == .responding ? Date().addingTimeInterval(-94) : nil,
            pendingPrompt: pendingPrompt.map { String($0.prefix(Self.maxTaskTitleLength)) }
        )
    }
#endif

    /// Remote end/dismiss invalidates the retained local handle; never resurrect an ended Activity on the next poll.
    func remoteActivityEnded(id: String) {
        guard ActivityStore.activity?.id == id else { return }
        for task in ActivityStore.doneRemovalTasks.values { task.cancel() }
        ActivityStore.doneRemovalTasks.removeAll()
        ActivityStore.activity = nil
        ActivityStore.entries.removeAll()
        ActivityStore.publishedEntries.removeAll()
        ActivityStore.scheduledEntries.removeAll()
        ActivityStore.startedAtBySession.removeAll()
        ActivityStore.operationRevision &+= 1
    }

    private static func isActivityResponding(_ snapshot: SessionSnapshot) -> Bool {
        if snapshot.isStructured { return snapshot.structuredState?.inFlight == true }
        guard snapshot.status == "running", snapshot.providerCliActive != false else { return false }
        return isProviderCliSession(snapshot.provider) ? snapshot.ptyBusy == true : snapshot.ptyCommandRunning == true
    }

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
        LiveActivityPushController.shared.observe(activity)
        for entry in ActivityStore.entries {
            if entry.isFinished {
                scheduleDoneRemoval(entry.id, serverID: entry.serverID, since: entry.finishedAt)
            }
            if let startedAt = entry.startedAt {
                ActivityStore.startedAtBySession[scopedKey(entry.id, serverID: entry.serverID)] = startedAt
            }
        }
        for duplicate in restorable.dropFirst() {
            LiveActivityPushController.shared.retire(activityID: duplicate.id)
            ActivityStore.endingActivityIDs.insert(duplicate.id)
            enqueueActivityOperation {
                await duplicate.end(nil, dismissalPolicy: .immediate)
                ActivityStore.endingActivityIDs.remove(duplicate.id)
            }
        }
    }

    /// 「待授权/等你回复」时真正被问的那件事。灵动岛只有一两行，只写「需要你的确认」等于什么都没说。
    /// 取 escalation 的 scope + target；没有目标时退回 scope 标题。
    private static func pendingPrompt(of snapshot: SessionSnapshot) -> String? {
        guard let escalation = snapshot.pendingEscalation else { return nil }
        let target = escalation.target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return target.isEmpty ? escalation.scopeTitle : "\(escalation.scopeTitle) · \(target)"
    }

    private func upsert(
        sessionId: String, serverID: String?, title: String, provider: String?, state: SessionState,
        taskTitle: String?, queuedCount: Int, startedAt requestedStartedAt: Date? = nil, engine: String? = nil,
        pendingPrompt: String? = nil
    ) {
        let key = scopedKey(sessionId, serverID: serverID)
        let shortTitle = activityBoundedText(title, maxCharacters: Self.maxTitleLength, maxBytes: 96)
        let shortTaskTitle = taskTitle.map { activityBoundedText($0, maxCharacters: Self.maxTaskTitleLength, maxBytes: 120) }
        let shortPrompt = pendingPrompt.map { activityBoundedText($0, maxCharacters: Self.maxTaskTitleLength, maxBytes: 120) }
        let startedAt: Date?
        if state == .responding || state == .background {
            startedAt = requestedStartedAt ?? ActivityStore.startedAtBySession[key]
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
            let finished = state == .done || state == .failed || state == .stopped
            let finishedAt = finished ? (ActivityStore.entries[index].stateRaw == state.rawValue ? ActivityStore.entries[index].finishedAt ?? Date() : Date()) : nil
            ActivityStore.entries[index].stateRaw = state.rawValue
            ActivityStore.entries[index].finishedAt = finishedAt
            ActivityStore.entries[index].taskTitle = shortTaskTitle
            ActivityStore.entries[index].queuedCount = queuedCount
            ActivityStore.entries[index].startedAt = startedAt
            ActivityStore.entries[index].engineRaw = engine
            ActivityStore.entries[index].pendingPrompt = shortPrompt
        } else {
            ActivityStore.entries.append(SessionActivityAttributes.SessionEntry(
                id: sessionId, serverID: serverID,
                title: shortTitle, providerRaw: provider ?? "claude",
                stateRaw: state.rawValue, taskTitle: shortTaskTitle, queuedCount: queuedCount,
                startedAt: startedAt, finishedAt: (state == .done || state == .failed || state == .stopped) ? Date() : nil, engineRaw: engine, pendingPrompt: shortPrompt
            ))
            trimEntriesIfNeeded()
        }
    }

    /// 超出上限时优先挤掉最早的「已完成」，否则挤掉最早进条的会话。
    private func trimEntriesIfNeeded() {
        while ActivityStore.entries.count > Self.maxEntries {
            let victim = ActivityStore.entries.indices.max { ActivityStore.entries[$0].priority < ActivityStore.entries[$1].priority } ?? 0
            let victimEntry = ActivityStore.entries[victim]
            let victimId = victimEntry.id
            cancelDoneRemoval(victimId, serverID: victimEntry.serverID)
            ActivityStore.startedAtBySession[scopedKey(victimId, serverID: victimEntry.serverID)] = nil
            ActivityStore.entries.remove(at: victim)
        }
    }

    private func scheduleDoneRemoval(_ sessionId: String, serverID: String?, since: Date? = nil) {
        let key = scopedKey(sessionId, serverID: serverID)
        cancelDoneRemoval(sessionId, serverID: serverID)
        let linger = ActivityStore.entries.first { $0.id == sessionId && $0.serverID == serverID }?.isFailed == true ? Self.failureLingerSeconds : Self.doneLingerSeconds
        let finishedAt = ActivityStore.entries.first { $0.id == sessionId && $0.serverID == serverID }?.finishedAt ?? since
        let delay = LiveActivityPushPolicy.remainingLinger(since: finishedAt, now: Date(), duration: TimeInterval(linger))
        ActivityStore.doneRemovalTasks[key] = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            ActivityStore.doneRemovalTasks[key] = nil
            ActivityStore.entries.removeAll {
                $0.id == sessionId && $0.serverID == serverID && $0.isFinished
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
        var entries = ActivityStore.entries.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }

        // ActivityKit rejects payloads above 4KB; keep a reserve for attributes/metadata.
        while entries.count > 1, let size = try? JSONEncoder().encode(SessionActivityAttributes.ContentState(sessions: entries, updatedAt: Date())).count, size > 3500 { entries.removeLast() }
        if entries.isEmpty {
            guard let activity = ActivityStore.activity else { return }
            ActivityStore.operationRevision &+= 1
            ActivityStore.activity = nil
            ActivityStore.publishedEntries.removeAll()
            ActivityStore.scheduledEntries.removeAll()
            ActivityStore.endingActivityIDs.insert(activity.id)
            LiveActivityPushController.shared.retire(activityID: activity.id)
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
        // An old locally-created Activity cannot acquire a push token. Replace it once after upgrade, preserving its entries.
        if LiveActivityPushController.supportsPush, ServerStore.shared.activeProfile != nil,
           (activity.attributes.remoteUpdates != true || activity.attributes.connectionIdentity != ServerStore.shared.activeProfile?.connectionIdentity) {
            ActivityStore.operationRevision &+= 1
            let revision = ActivityStore.operationRevision
            ActivityStore.activity = nil
            ActivityStore.endingActivityIDs.insert(activity.id)
            enqueueActivityOperation {
                await activity.end(nil, dismissalPolicy: .immediate)
                ActivityStore.endingActivityIDs.remove(activity.id)
            }
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
            guard ActivityStore.activity == nil, !ActivityStore.entries.isEmpty,
                  UIApplication.shared.applicationState == .active else { return }
            do {
                let profile = ServerStore.shared.activeProfile
                let remote = LiveActivityPushController.supportsPush && profile != nil
                let pushType: PushType? = remote ? .token : nil
                let activity = try Activity.request(
                    attributes: SessionActivityAttributes(serverID: profile?.id, remoteUpdates: remote ? true : nil, connectionIdentity: profile?.connectionIdentity),
                    content: ActivityContent(state: state, staleDate: self.staleDate()),
                    pushType: pushType
                )
                ActivityStore.activity = activity
                LiveActivityPushController.shared.observe(activity)
                if revision == ActivityStore.operationRevision {
                    ActivityStore.publishedEntries = entries
                }
            } catch {
                self.logger.error("Live Activity 创建失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func staleDate() -> Date {
        // Confirmed remote subscriptions heartbeat every minute; no connection means the system visibly marks data stale.
        let remote = ActivityStore.activity.map { LiveActivityPushController.shared.isRegistered(activityID: $0.id) } ?? false
        return Date().addingTimeInterval(remote ? 180 : 60)
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
        queuedCount: Int = 0,
        pendingPrompt: String? = nil
    ) {
        SessionLiveActivityController.shared.start(
            sessionId: sessionId,
            serverID: serverID,
            title: title,
            provider: provider,
            state: state,
            taskTitle: taskTitle,
            queuedCount: queuedCount,
            pendingPrompt: pendingPrompt
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
