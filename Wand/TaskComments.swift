import Foundation
import CryptoKit

struct WandTaskCommentDispatch: Decodable, Equatable {
    let employeeId: String
    let employeeName: String
    let state: String
    let sessionId: String?
    let status: String?
    let error: String?
    var deliveryUncertain: Bool { state == "pending" || state == "unknown" || status == "pending" || status == "unknown" }
    var label: String {
        switch status ?? state {
        case "running": return "执行中"
        case "blocked": return "等待审批"
        case "idle": return "本轮已结束"
        case "exited": return "会话已退出"
        case "failed": return "执行失败"
        case "stopped": return "已停止"
        case "history": return "历史会话"
        case "unavailable": return "会话不可用"
        case "accepted": return "已创建执行"
        default: return "送达未知 · 不会重放"
        }
    }
}


struct WandTaskComment: Decodable, Equatable, Identifiable {
    let id: String
    let taskId: String
    let authorName: String
    let body: String
    let createdAt: String
    var sourceCommentId: String? = nil
    var dispatch: WandTaskCommentDispatch? = nil
}

/// Persist only a digest and identity; a saved comment is not evidence of accepted execution.
struct TaskCommentRequestIdentity {
    let key: String
    let requestId: String
    private let defaults: UserDefaults
    init(taskId: String, body: String, employeeId: String, sourceCommentId: String?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = (try? JSONEncoder().encode([body.trimmingCharacters(in: .whitespacesAndNewlines), employeeId, sourceCommentId ?? ""])) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        key = "wand.task-comment-request." + taskId + "." + digest
        requestId = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(requestId, forKey: key)
    }
    func settle(_ comment: WandTaskComment) {
        if comment.dispatch?.deliveryUncertain != true { defaults.removeObject(forKey: key) }
    }
}

struct WandTaskCommentsResponse: Decodable {
    let comments: [WandTaskComment]
}

/// A request identity prevents a late A response from replacing B (or a newly reopened A).
struct WandTaskCommentState {
    private(set) var taskId = ""
    private(set) var requestId = UUID()
    private(set) var comments: [WandTaskComment] = []

    mutating func begin(taskId: String) -> UUID {
        if self.taskId != taskId { comments = [] }
        self.taskId = taskId
        requestId = UUID()
        return requestId
    }

    mutating func accept(_ comments: [WandTaskComment], taskId: String, requestId: UUID) {
        guard self.taskId == taskId, self.requestId == requestId else { return }
        self.comments = comments.filter { $0.taskId == taskId }
    }

    func visible(taskId: String) -> [WandTaskComment] {
        self.taskId == taskId ? comments : []
    }
}

enum TaskCommentMention {
    struct Query: Equatable { let start: Int; let text: String }

    static func query(in body: String, caret: Int) -> Query? {
        let chars = Array(body)
        let index = min(max(caret, 0), chars.count)
        guard index > 0, let at = chars[..<index].lastIndex(of: Character("@")) else { return nil }
        if at > 0, !chars[at - 1].isWhitespace { return nil }
        let text = String(chars[(at + 1)..<index])
        if text.contains(where: \.isWhitespace) { return nil }
        return Query(start: at, text: text)
    }

    static func insert(body: String, caret: Int, name: String) -> (body: String, caret: Int) {
        let chars = Array(body)
        let end = min(max(caret, 0), chars.count)
        let start = query(in: body, caret: end)?.start ?? end
        let token = Array("@\(name) ")
        return (String(chars[..<start] + token + chars[end...]), start + token.count)
    }

    static func holds(_ body: String, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let pattern = "(^|\\s)@\(NSRegularExpression.escapedPattern(for: name))(?=\\s|$)"
        return body.range(of: pattern, options: .regularExpression) != nil
    }

    static func caretOffset(from old: String, to new: String) -> Int {
        let previous = Array(old), next = Array(new)
        var head = 0
        while head < previous.count && head < next.count && previous[head] == next[head] { head += 1 }
        var oldEnd = previous.count, newEnd = next.count
        while oldEnd > head && newEnd > head && previous[oldEnd - 1] == next[newEnd - 1] {
            oldEnd -= 1; newEnd -= 1
        }
        return newEnd
    }
}
