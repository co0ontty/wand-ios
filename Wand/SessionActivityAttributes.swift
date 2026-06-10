import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// 会话 Live Activity 的契约，主 App 与 WandWidgets 扩展共同编译。
/// 字段保持精简：灵动岛空间有限，只展示「哪个会话、什么状态、在干什么」。
@available(iOS 16.1, *)
struct SessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// responding / permission / done
        var stateRaw: String
        /// 当前任务标题（TodoWrite 派生），可空。
        var taskTitle: String?
        var updatedAt: Date
    }

    /// wand 会话 ID（一个会话最多一条活动）。
    var sessionId: String
    /// 会话标题（目录名或摘要）。
    var sessionTitle: String
}

@available(iOS 16.1, *)
extension SessionActivityAttributes.ContentState {
    var isResponding: Bool { stateRaw == "responding" }
    var needsPermission: Bool { stateRaw == "permission" }
    var isDone: Bool { stateRaw == "done" }

    var statusText: String {
        switch stateRaw {
        case "responding": return "回复中"
        case "permission": return "等待授权"
        case "done": return "已完成"
        default: return stateRaw
        }
    }

    var statusSymbol: String {
        switch stateRaw {
        case "responding": return "ellipsis.bubble"
        case "permission": return "lock.shield"
        case "done": return "checkmark.circle.fill"
        default: return "wand.and.stars"
        }
    }
}
#endif
