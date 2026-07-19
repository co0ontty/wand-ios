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
        /// claude / codex / opencode，用于快速区分并发会话。
        var providerRaw: String
        /// responding / permission / done
        var stateRaw: String
        /// 当前任务标题（TodoWrite 派生），可空。
        var taskTitle: String?
        /// 对话模式中等待发送的消息数。
        var queuedCount: Int
        /// 本轮工作开始时间。系统可直接渲染计时器，无需 App 高频刷新。
        var startedAt: Date? = nil
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

    var priority: Int {
        if needsPermission { return 0 }
        if isResponding { return 1 }
        return 2
    }

    var statusText: String {
        switch stateRaw {
        case "responding": return "回复中"
        case "permission": return "等待授权"
        case "done": return "已完成"
        default: return stateRaw
        }
    }

    private var normalizedProvider: String { providerRaw.lowercased() }

    var providerText: String {
        switch normalizedProvider {
        case "codex": return "Codex"
        case "opencode", "open-code", "open_code": return "OpenCode"
        case "grok": return "Grok"
        case "qoder", "qodercli": return "Qoder"
        default: return "Claude"
        }
    }

    var providerSymbol: String {
        switch normalizedProvider {
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode", "open-code", "open_code": return "terminal"
        case "grok": return "bolt.horizontal"
        case "qoder", "qodercli": return "curlybraces"
        default: return "sparkles"
        }
    }

    var primaryDetail: String {
        if needsPermission { return "需要你的确认后继续" }
        if let taskTitle, !taskTitle.isEmpty { return taskTitle }
        if isDone { return "回复已完成" }
        return "正在生成回复"
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
    var permissionCount: Int { sessions.filter(\.needsPermission).count }
    var needsPermission: Bool { permissionCount > 0 }
    var primarySession: SessionActivityAttributes.SessionEntry? {
        sessions.min { lhs, rhs in lhs.priority < rhs.priority }
    }

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
