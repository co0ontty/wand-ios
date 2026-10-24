import Foundation
import ActivityKit

/// Small, credential-free activity projection shared by app and WidgetKit.
struct SessionActivityAttributes: ActivityAttributes {
    /// Immutable owner/creation-mode marker; optional fields keep legacy local activities decodable.
    var serverID: String? = nil
    var remoteUpdates: Bool? = nil
    /// One-way credential fingerprint, not a login token. Pins ownership even before the first ActivityKit token arrives.
    var connectionIdentity: String? = nil
    struct SessionEntry: Codable, Hashable {
        var id: String
        var serverID: String? = nil
        var title: String
        var providerRaw: String
        var stateRaw: String
        var taskTitle: String?
        var queuedCount: Int
        var startedAt: Date? = nil
        var finishedAt: Date? = nil
        var engineRaw: String? = nil
        /// 「待授权/等你回复」时真正被问的那件事（例如「写入 src/index.ts」）。
        /// 只有状态而说不出在等什么时，灵动岛就只剩一句无用的「需要你的确认」。
        var pendingPrompt: String? = nil
    }
    struct ContentState: Codable, Hashable {
        var sessions: [SessionEntry]
        var updatedAt: Date
    }
}

extension SessionActivityAttributes.SessionEntry {
    var isResponding: Bool { stateRaw == "responding" }
    var isBackground: Bool { stateRaw == "background" }
    var needsPermission: Bool { stateRaw == "permission" }
    var needsInput: Bool { stateRaw == "waiting-input" }
    var isFailed: Bool { stateRaw == "failed" }
    var isStopped: Bool { stateRaw == "stopped" }
    var isDone: Bool { stateRaw == "done" }
    var needsAttention: Bool { needsPermission || needsInput || isFailed }
    var isFinished: Bool { isDone || isFailed || isStopped }
    var priority: Int {
        switch stateRaw {
        case "permission": return 0
        case "waiting-input": return 1
        case "failed": return 2
        case "responding": return 3
        case "background": return 4
        case "stopped": return 5
        default: return 6
        }
    }
    var statusText: String {
        switch stateRaw {
        case "responding": return "运行中"
        case "background": return "后台收尾"
        case "permission": return "待授权"
        case "waiting-input": return "等你回复"
        case "failed": return "执行失败"
        case "stopped": return "已停止"
        case "done": return "已完成"
        default: return "状态待确认"
        }
    }
    private var normalizedProvider: String { providerRaw.lowercased() }
    var providerText: String {
        if normalizedProvider == "pi", ["core", "sdk"].contains(engineRaw ?? "") { return "Wand Agent" }
        switch normalizedProvider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "opencode", "open-code", "open_code": return "OpenCode"
        case "grok": return "Grok"
        case "qoder", "qodercli": return "Qoder"
        case "pi": return "Pi"
        case "shell", "terminal", "": return "终端"
        default: return String(normalizedProvider.prefix(40))
        }
    }
    var providerSymbol: String {
        switch normalizedProvider {
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode", "open-code", "open_code", "shell", "terminal", "": return "terminal"
        case "grok": return "bolt.horizontal"
        case "qoder", "qodercli": return "curlybraces"
        case "pi": return ["core", "sdk"].contains(engineRaw ?? "") ? "wand.and.stars" : "pi"
        default: return "sparkles"
        }
    }
    /// 真实在做的事优先于通用提示：锁屏与灵动岛的状态胶囊已经说明「待授权/等你回复/已完成」，
    /// 再复述一遍只会挤掉用户真正要看的内容。没有真实任务内容时才回落到动作提示。
    private var currentTaskDetail: String? {
        let detail = taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !detail.isEmpty, detail != title else { return nil }
        return detail
    }
    var primaryDetail: String {
        if let pendingPrompt { return pendingPrompt }
        if let currentTaskDetail { return currentTaskDetail }
        if needsPermission { return "需要你的确认后继续" }
        if needsInput { return "需要你的回复后继续" }
        if isFailed { return "打开会话查看失败原因" }
        if isStopped { return "本轮已停止" }
        if isDone { return "打开会话查看结果" }
        return isBackground ? "等待子任务结束" : "正在处理"
    }
    /// 灵动岛展开态只有一两行可用：只给真实内容，状态胶囊说过的话不再占一行。
    var focusDetail: String? { pendingPrompt ?? currentTaskDetail }
    var statusSymbol: String {
        switch stateRaw {
        case "permission": return "lock.shield"
        case "waiting-input": return "bubble.left.and.text.bubble.right"
        case "failed": return "exclamationmark.circle.fill"
        case "stopped": return "pause.circle"
        case "done": return "checkmark.circle.fill"
        case "background": return "rectangle.stack"
        default: return "ellipsis"
        }
    }
}

extension SessionActivityAttributes.ContentState {
    var respondingCount: Int { sessions.filter { $0.isResponding || $0.isBackground }.count }
    var permissionCount: Int { sessions.filter(\.needsPermission).count }
    var inputCount: Int { sessions.filter(\.needsInput).count }
    var failedCount: Int { sessions.filter(\.isFailed).count }
    var attentionCount: Int { sessions.filter(\.needsAttention).count }
    var needsPermission: Bool { permissionCount > 0 }
    var primarySession: SessionActivityAttributes.SessionEntry? { sessions.min { $0.priority < $1.priority } }
    /// A sibling worth its own row: still doing something and not the primary one. Sessions that
    /// only linger in their 「已完成」 grace period are already covered by the session count.
    var activeSecondarySessions: [SessionActivityAttributes.SessionEntry] {
        guard let primarySession, sessions.count > 1 else { return [] }
        return sessions.filter {
            !$0.isFinished && !($0.id == primarySession.id && $0.serverID == primarySession.serverID)
        }
    }
    var aggregateStateRaw: String { primarySession?.stateRaw ?? "done" }
    var aggregateSymbol: String { primarySession?.statusSymbol ?? "checkmark.circle.fill" }
    var aggregateText: String {
        if attentionCount > 0 { return "\(attentionCount) 项等你" }
        if respondingCount > 0 { return "\(respondingCount) 项运行中" }
        return primarySession?.statusText ?? "已完成"
    }
    /// Compact island avoids an unbounded timer and still distinguishes attention from work.
    func compactText(isStale: Bool) -> String {
        if isStale { return "离线" }
        if attentionCount > 0 { return attentionCount > 1 ? "等你\(attentionCount)" : "等你" }
        if respondingCount > 1 { return "\(respondingCount)项" }
        if let primarySession, primarySession.isStopped { return "停止" }
        if respondingCount == 0 { return "完成" }
        return primarySession?.isBackground == true ? "收尾" : "运行"
    }
    var destinationURL: URL {
        // Multiple sessions keep an unambiguous list destination; individual expanded rows link precisely.
        guard sessions.count == 1, let primarySession else { return URL(string: "wand://live-activity")! }
        return primarySession.destinationURL
    }
}

extension SessionActivityAttributes.SessionEntry {
    var destinationURL: URL {
        var c = URLComponents(); c.scheme = "wand"; c.host = "session"; c.path = "/" + id
        if let serverID, !serverID.isEmpty { c.queryItems = [URLQueryItem(name: "serverId", value: serverID)] }
        return c.url ?? URL(string: "wand://live-activity")!
    }
}

/// Elapsed time with a bounded footprint. `Text(style: .timer)` grows to `238:58:42` on a
/// long run and pushes the status capsule out of the island; this never exceeds 5 characters.
func activityElapsedText(_ elapsed: TimeInterval) -> String {
    let seconds = max(0, Int(elapsed))
    if seconds < 3_600 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
    let hours = seconds / 3_600
    if hours < 100 { return String(format: "%dh%02d", hours, (seconds % 3_600) / 60) }
    return "99h+"
}

func activityBoundedText(_ text: String, maxCharacters: Int, maxBytes: Int) -> String {
    var result = "", bytes = 0
    for character in text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters) {
        let size = String(character).utf8.count
        if bytes + size > maxBytes { break }
        result.append(character); bytes += size
    }
    return result
}
