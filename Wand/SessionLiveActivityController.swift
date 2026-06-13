import Foundation
import ActivityKit

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
    func start(sessionId: String, title: String, taskTitle: String?, queuedCount: Int = 0) {
        guard enabled else { return }
        cancelDoneRemoval(sessionId)
        upsert(
            sessionId: sessionId, title: title, state: .responding,
            taskTitle: taskTitle, queuedCount: queuedCount
        )
        sync(allowCreate: true)
    }

    /// 更新状态（条内不存在时 no-op，避免在用户关掉开关后复活）。
    func update(sessionId: String, state: SessionState, taskTitle: String?, queuedCount: Int = 0) {
        guard let index = ActivityStore.entries.firstIndex(where: { $0.id == sessionId }) else { return }
        cancelDoneRemoval(sessionId)
        ActivityStore.entries[index].stateRaw = state.rawValue
        ActivityStore.entries[index].taskTitle = taskTitle
        ActivityStore.entries[index].queuedCount = queuedCount
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

    // MARK: - 内部

    private func upsert(
        sessionId: String, title: String, state: SessionState,
        taskTitle: String?, queuedCount: Int
    ) {
        let shortTitle = String(title.prefix(Self.maxTitleLength))
        if let index = ActivityStore.entries.firstIndex(where: { $0.id == sessionId }) {
            ActivityStore.entries[index].title = shortTitle
            ActivityStore.entries[index].stateRaw = state.rawValue
            ActivityStore.entries[index].taskTitle = taskTitle
            ActivityStore.entries[index].queuedCount = queuedCount
        } else {
            ActivityStore.entries.append(SessionActivityAttributes.SessionEntry(
                id: sessionId, title: shortTitle, stateRaw: state.rawValue,
                taskTitle: taskTitle, queuedCount: queuedCount
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
            // 系统额度用尽 / 用户全局关闭等，静默忽略。
        }
    }

    private func staleDate() -> Date {
        // App 被挂起后无法继续更新；60s 没更新就让系统把活动标记为过期（变灰）。
        Date().addingTimeInterval(60)
    }
}
