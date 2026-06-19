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
        static var doneRemovalTasks: [String: Task<Void, Never>] = [:]
    }

    private var enabled: Bool {
        ServerStore.shared.liveActivityEnabled
            && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 会话开始回复：插入（或刷新）条内对应条目，必要时创建活动。
    func start(
        sessionId: String,
        title: String,
        provider: String?,
        state: SessionState = .responding,
        taskTitle: String?,
        queuedCount: Int = 0
    ) {
        guard enabled else { return }
        cancelDoneRemoval(sessionId)
        upsert(
            sessionId: sessionId, title: title, provider: provider, state: state,
            taskTitle: taskTitle, queuedCount: queuedCount
        )
        sync(allowCreate: true)
    }

    /// 按服务端快照恢复或更新活动。已有运行中的会话不再依赖本机先点一次发送。
    func sync(snapshot: SessionSnapshot) {
        if snapshot.hasPendingPermission {
            start(
                sessionId: snapshot.id, title: snapshot.displayTitle, provider: snapshot.provider,
                state: .permission, taskTitle: snapshot.currentTaskTitle,
                queuedCount: snapshot.queuedMessages?.count ?? 0
            )
        } else if snapshot.isResponding {
            start(
                sessionId: snapshot.id, title: snapshot.displayTitle, provider: snapshot.provider,
                taskTitle: snapshot.currentTaskTitle, queuedCount: snapshot.queuedMessages?.count ?? 0
            )
        } else if snapshot.isEnded {
            end(sessionId: snapshot.id, immediately: true)
        } else if let entry = ActivityStore.entries.first(where: { $0.id == snapshot.id }),
                  !entry.isDone {
            end(sessionId: snapshot.id)
        }
    }

    /// 列表轮询是全局事实来源：恢复所有活跃会话，并清掉服务端已不存在的遗留条目。
    func reconcile(snapshots: [SessionSnapshot]) {
        guard ServerStore.shared.liveActivityEnabled else {
            endAll()
            return
        }
        let visibleIds = Set(snapshots.filter { !($0.archived ?? false) }.map(\.id))
        for snapshot in snapshots where !(snapshot.archived ?? false) {
            sync(snapshot: snapshot)
        }
        let missingIds = ActivityStore.entries.map(\.id).filter { !visibleIds.contains($0) }
        for id in missingIds {
            end(sessionId: id, immediately: true)
        }
    }

    func endAll() {
        for task in ActivityStore.doneRemovalTasks.values { task.cancel() }
        ActivityStore.doneRemovalTasks.removeAll()
        ActivityStore.entries.removeAll()
        sync(allowCreate: false)
    }

    /// 结束：immediately = true（会话退出 / 被杀 / 离开页面）直接从条里移除；
    /// 否则视为成功完成，切「已完成」停留片刻再自动移除。
    func end(sessionId: String, immediately: Bool = false) {
        guard let index = ActivityStore.entries.firstIndex(where: { $0.id == sessionId }) else { return }
        cancelDoneRemoval(sessionId)
        if immediately {
            ActivityStore.entries.remove(at: index)
        } else {
            ActivityStore.entries[index].stateRaw = SessionState.done.rawValue
            ActivityStore.entries[index].taskTitle = nil
            ActivityStore.entries[index].queuedCount = 0
            scheduleDoneRemoval(sessionId)
        }
        sync(allowCreate: false)
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
                    id: "mock-codex-3",
                    title: "Web UI 回归",
                    provider: "codex",
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
            queuedCount: queuedCount
        )
    }
#endif

    // MARK: - 内部

    private func upsert(
        sessionId: String, title: String, provider: String?, state: SessionState,
        taskTitle: String?, queuedCount: Int
    ) {
        let shortTitle = String(title.prefix(Self.maxTitleLength))
        let shortTaskTitle = taskTitle.map { String($0.prefix(Self.maxTaskTitleLength)) }
        if let index = ActivityStore.entries.firstIndex(where: { $0.id == sessionId }) {
            ActivityStore.entries[index].title = shortTitle
            ActivityStore.entries[index].providerRaw = provider ?? "claude"
            ActivityStore.entries[index].stateRaw = state.rawValue
            ActivityStore.entries[index].taskTitle = shortTaskTitle
            ActivityStore.entries[index].queuedCount = queuedCount
        } else {
            ActivityStore.entries.append(SessionActivityAttributes.SessionEntry(
                id: sessionId, title: shortTitle, providerRaw: provider ?? "claude",
                stateRaw: state.rawValue, taskTitle: shortTaskTitle, queuedCount: queuedCount
            ))
            trimEntriesIfNeeded()
        }
    }

    /// 超出上限时优先挤掉最早的「已完成」，否则挤掉最早进条的会话。
    private func trimEntriesIfNeeded() {
        while ActivityStore.entries.count > Self.maxEntries {
            let victim = ActivityStore.entries.firstIndex { $0.isDone } ?? 0
            cancelDoneRemoval(ActivityStore.entries[victim].id)
            ActivityStore.entries.remove(at: victim)
        }
    }

    private func scheduleDoneRemoval(_ sessionId: String) {
        ActivityStore.doneRemovalTasks[sessionId] = Task {
            try? await Task.sleep(nanoseconds: Self.doneLingerSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            ActivityStore.doneRemovalTasks[sessionId] = nil
            ActivityStore.entries.removeAll { $0.id == sessionId && $0.isDone }
            sync(allowCreate: false)
        }
    }

    private func cancelDoneRemoval(_ sessionId: String) {
        ActivityStore.doneRemovalTasks.removeValue(forKey: sessionId)?.cancel()
    }

    /// 把当前条目集合同步到系统：空 → 收掉活动；非空 → 更新或（允许时）创建。
    private func sync(allowCreate: Bool) {
        let state = SessionActivityAttributes.ContentState(
            sessions: ActivityStore.entries, updatedAt: Date()
        )
        if ActivityStore.entries.isEmpty {
            guard let activity = ActivityStore.activity else { return }
            ActivityStore.activity = nil
            Task {
                await activity.end(
                    ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate
                )
            }
            return
        }
        if let activity = ActivityStore.activity {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: staleDate()))
            }
            return
        }
        guard allowCreate else { return }
        // 收掉上次进程遗留的孤儿活动，避免叠出多条岛。
        for orphan in Activity<SessionActivityAttributes>.activities {
            Task {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
        do {
            ActivityStore.activity = try Activity.request(
                attributes: SessionActivityAttributes(),
                content: ActivityContent(state: state, staleDate: staleDate())
            )
        } catch {
            logger.error("Live Activity 创建失败: \(error.localizedDescription, privacy: .public)")
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
        title: String,
        provider: String?,
        state: SessionLiveActivityController.SessionState = .responding,
        taskTitle: String?,
        queuedCount: Int = 0
    ) {
        SessionLiveActivityController.shared.start(
            sessionId: sessionId,
            title: title,
            provider: provider,
            state: state,
            taskTitle: taskTitle,
            queuedCount: queuedCount
        )
    }

    func sync(snapshot: SessionSnapshot) {
        SessionLiveActivityController.shared.sync(snapshot: snapshot)
    }

    func reconcile(snapshots: [SessionSnapshot]) {
        SessionLiveActivityController.shared.reconcile(snapshots: snapshots)
        SessionNotificationController.shared.reconcile(snapshots: snapshots)
    }

    func end(sessionId: String, immediately: Bool = false) {
        SessionLiveActivityController.shared.end(sessionId: sessionId, immediately: immediately)
    }

    func endAll() {
        SessionLiveActivityController.shared.endAll()
    }

#if DEBUG
    func installMockScenario(_ scenario: String) {
        SessionLiveActivityController.shared.installMockScenario(scenario)
    }
#endif
}
