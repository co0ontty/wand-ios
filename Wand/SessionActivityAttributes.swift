import Foundation
import ActivityKit

/// 会话 Live Activity 的契约，主 App 与 WandWidgets 扩展共同编译。
/// 所有活跃会话聚合进**同一条**活动（长条样式）：ContentState 携带会话条目数组，
/// 每个条目只保留「哪个会话、缩略标题、什么状态」——灵动岛空间有限。
struct SessionActivityAttributes: ActivityAttributes {
    /// 长条内的单个会话条目。
    struct SessionEntry: Codable, Hashable {
        var id: String
        /// 缩略标题（目录名或摘要，控制器侧已截断）。
        var title: String
        /// claude / codex，用于快速区分并发会话。
        var providerRaw: String
        /// responding / permission / done
        var stateRaw: String
        /// 当前任务标题（TodoWrite 派生），可空。
        var taskTitle: String?
        /// 对话模式中等待发送的消息数。
        var queuedCount: Int
    }

    public struct ContentState: Codable, Hashable {
        var sessions: [SessionEntry]
        var updatedAt: Date
    }
}

extension SessionActivityAttributes.SessionEntry {
    var isResponding: Bool { stateRaw == "responding" }
    var needsPermission: Bool { stateRaw == "permission" }
    var isDone: Bool { stateRaw == "done" }

    var providerText: String { providerRaw == "codex" ? "Codex" : "Claude" }

    var providerSymbol: String {
        providerRaw == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkles"
    }

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

extension SessionActivityAttributes.ContentState {
    var respondingCount: Int { sessions.filter(\.isResponding).count }
    var needsPermission: Bool { sessions.contains { $0.needsPermission } }
    var queuedCount: Int { sessions.reduce(0) { $0 + $1.queuedCount } }

    /// 聚合状态：permission > responding > done，给紧凑视图着色 / 选图标用。
    var aggregateStateRaw: String {
        if needsPermission { return "permission" }
        if respondingCount > 0 { return "responding" }
        return "done"
    }

    var aggregateSymbol: String {
        switch aggregateStateRaw {
        case "permission": return "lock.shield"
        case "responding": return "ellipsis.bubble"
        default: return "checkmark.circle.fill"
        }
    }
}
