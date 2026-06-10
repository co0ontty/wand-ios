import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// 会话 Live Activity 管理器：发消息时起一条灵动岛活动，状态变化时更新，
/// 回复结束后短暂展示完成态再撤掉。
/// iOS 16.1 以下、系统关闭实时活动、或设置页开关关闭时全部是 no-op。
///
/// 局限（自签 sideload 没有 APNs push token）：活动只能由 App 进程本地更新，
/// App 被系统挂起后状态会冻结在最后一次更新——所以结束态用短超时自动收掉，
/// 且 stale date 设为 60s，过期后系统会把活动标灰。
@MainActor
final class SessionLiveActivityController {
    static let shared = SessionLiveActivityController()

    enum SessionState: String {
        case responding
        case permission
        case done
    }

    private init() {}

#if canImport(ActivityKit)
    /// 存储属性不能标 @available，包一层全量标注的 holder。
    @available(iOS 16.1, *)
    @MainActor
    private enum ActivityStore {
        static var activities: [String: Activity<SessionActivityAttributes>] = [:]
    }

    private var enabled: Bool {
        guard ServerStore.shared.liveActivityEnabled else { return false }
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }

    /// 开始（或复用）一条会话活动。
    func start(sessionId: String, title: String, taskTitle: String?) {
        guard enabled else { return }
        if #available(iOS 16.1, *) {
            if ActivityStore.activities[sessionId] != nil {
                update(sessionId: sessionId, state: .responding, taskTitle: taskTitle)
                return
            }
            let attributes = SessionActivityAttributes(sessionId: sessionId, sessionTitle: title)
            let state = SessionActivityAttributes.ContentState(
                stateRaw: SessionState.responding.rawValue,
                taskTitle: taskTitle,
                updatedAt: Date()
            )
            do {
                let activity: Activity<SessionActivityAttributes>
                if #available(iOS 16.2, *) {
                    activity = try Activity.request(
                        attributes: attributes,
                        content: ActivityContent(state: state, staleDate: staleDate())
                    )
                } else {
                    activity = try Activity.request(attributes: attributes, contentState: state)
                }
                ActivityStore.activities[sessionId] = activity
            } catch {
                // 系统额度用尽 / 用户全局关闭等，静默忽略。
            }
        }
    }

    /// 更新状态（活动不存在时 no-op，避免在用户关掉开关后复活）。
    func update(sessionId: String, state: SessionState, taskTitle: String?) {
        if #available(iOS 16.1, *) {
            guard let activity = ActivityStore.activities[sessionId] else { return }
            let content = SessionActivityAttributes.ContentState(
                stateRaw: state.rawValue,
                taskTitle: taskTitle,
                updatedAt: Date()
            )
            Task {
                if #available(iOS 16.2, *) {
                    await activity.update(ActivityContent(state: content, staleDate: staleDate()))
                } else {
                    await activity.update(using: content)
                }
            }
        }
    }

    /// 结束：先切到完成态短暂停留，再交给系统收掉。
    func end(sessionId: String, immediately: Bool = false) {
        if #available(iOS 16.1, *) {
            guard let activity = ActivityStore.activities.removeValue(forKey: sessionId) else { return }
            let content = SessionActivityAttributes.ContentState(
                stateRaw: SessionState.done.rawValue,
                taskTitle: nil,
                updatedAt: Date()
            )
            Task {
                if #available(iOS 16.2, *) {
                    await activity.end(
                        ActivityContent(state: content, staleDate: nil),
                        dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(3))
                    )
                } else {
                    await activity.end(using: content, dismissalPolicy: immediately ? .immediate : .default)
                }
            }
        }
    }

    @available(iOS 16.1, *)
    private func staleDate() -> Date {
        // App 被挂起后无法继续更新；60s 没更新就让系统把活动标记为过期（变灰）。
        Date().addingTimeInterval(60)
    }
#else
    func start(sessionId: String, title: String, taskTitle: String?) {}
    func update(sessionId: String, state: SessionState, taskTitle: String?) {}
    func end(sessionId: String, immediately: Bool = false) {}
#endif
}
