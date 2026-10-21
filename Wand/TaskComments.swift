import Foundation
import CryptoKit

/// 任务评论里员工执行状态的统一文案表。
///
/// 权威定义在服务端 `src/task-comment-status.ts`（`statusLabels` / `unknownStatusLabel`）；
/// 这里是那份词表的逐字镜像，供 iOS 渲染与单测对齐用。改词表时服务端先改，三端一起跟。
enum TaskCommentStatusLabels {
    /// 状态 → 用户读到的文案。
    static let labels: [String: String] = [
        "paused": "已暂停", "queued": "排队中", "pending": "等待确认", "accepted": "已创建执行", "running": "执行中", "blocked": "等待审批",
        "idle": "本轮已结束", "exited": "会话已退出", "stopped": "已停止", "failed": "执行失败",
        "done": "已完成", "unknown": "送达未知 · 不会重放", "history": "历史会话", "unavailable": "会话不可用",
    ]
    /// 未知状态的统一回落文案。
    static let unknown = "状态未确认"
}

struct WandTaskCommentDispatch: Decodable, Equatable {
    let employeeId: String
    let employeeName: String
    let state: String
    let sessionId: String?
    let status: String?
    let error: String?
    /// 本评论引用到的子任务 ID（服务端按正文出现顺序解析）。
    var referencedTaskIds: [String]? = nil
    var deliveryUncertain: Bool { state == "pending" || state == "unknown" || status == "pending" || status == "unknown" }
    /// 送达标记：区分「明确已接受」「明确未接受」和「送达未知」。
    var deliveryLabel: String {
        switch state {
        case "accepted": return "已送达"
        case "failed": return "未送达"
        case "paused": return "已暂停"
        case "queued": return "排队中"
        case "pending", "unknown": return "送达未知"
        default: return "送达未知"
        }
    }
    /// 状态键：与 Web 的 `dispatch.status ?? dispatch.state` 同序。
    var statusKey: String { status ?? state }
    /// 状态文案：与服务端 `src/task-comment-status.ts` 的 `statusLabels` 逐字一致
    /// （Web / iOS / Android 共用同一份词表，改词表时三端一起改）。
    var label: String {
        TaskCommentStatusLabels.labels[statusKey] ?? TaskCommentStatusLabels.unknown
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
    /// 本轮指令原文（不含 `@员工 ` 前缀）；服务端只在派发过的评论上返回。
    var instruction: String? = nil
    /// 本评论引用到的子任务 ID（`#TASK-133` 的解析结果），按正文出现顺序。
    var referencedTaskIds: [String]? = nil
    /// 本评论引用到的子任务编号（`TASK-133`），按正文出现顺序；展示用编号，不是内部 UUID。
    var referencedTaskIdentifiers: [String]? = nil
    /// 派发时的指令原文：优先用服务端的 instruction，否则去掉正文里的 `@员工 ` 前缀。
    var dispatchInstruction: String {
        if let instruction, !instruction.isEmpty { return instruction }
        let name = dispatch?.employeeName ?? ""
        if !name.isEmpty, body.hasPrefix("@\(name)") {
            return String(body.dropFirst("@\(name)".count)).trimmingCharacters(in: .whitespaces)
        }
        return body
    }
}

/// 引用目标（`#TASK-133`）的展示编号。
///
/// 服务端在评论投影里直接给出编号（`referencedTaskIdentifiers`）；只给内部 ID 的旧服务端
/// 用本任务的子任务列表把 ID 换回编号。两条路径都只产出编号，内部 UUID 永远不进界面。
enum TaskCommentReferenceTargets {
    /// 评论引用到的子任务编号，按正文出现顺序；没有引用时是空数组。
    static func identifiers(for comment: WandTaskComment, children: [TaskReferenceTarget]) -> [String] {
        let provided = (comment.referencedTaskIdentifiers ?? []).filter { !$0.isEmpty }
        if !provided.isEmpty { return dedupe(provided) }
        let ids = comment.referencedTaskIds ?? comment.dispatch?.referencedTaskIds ?? []
        guard !ids.isEmpty else { return [] }
        let byId = Dictionary(children.map { ($0.id, $0.identifier) }, uniquingKeysWith: { first, _ in first })
        return dedupe(ids.compactMap { byId[$0] })
    }

    /// 同一个引用只展示一次（界面用编号做 identity，重复会撞）。
    private static func dedupe(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }
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
    /// 评论总数；老服务端不返回时为 nil。
    var totalCount: Int? = nil
    /// 更早一页的游标；没有更多评论时为 nil。
    var nextCursor: String? = nil
}

/// 一次评论执行的本轮结果（服务端冻结的执行区间）。
struct WandTaskCommentResult: Decodable {
    let available: Bool
    /// 结果不可读的原因：`still_running` / `unconfirmed_legacy`。
    let reason: String?
    let sessionId: String?
    /// 运行时给出的终态：`done` / `failed` / `stopped`。
    let outcome: String?
    let messages: [ConversationTurn]
    let offset: Int
    let total: Int

    private enum CodingKeys: String, CodingKey { case available, reason, sessionId, outcome, messages, offset, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? container.decode(Bool.self, forKey: .available)) ?? false
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
        outcome = try? container.decodeIfPresent(String.self, forKey: .outcome)
        offset = (try? container.decode(Int.self, forKey: .offset)) ?? 0
        total = (try? container.decode(Int.self, forKey: .total)) ?? 0
        messages = (try? container.decode([ConversationTurn].self, forKey: .messages)) ?? []
    }
}

/// 动作明细里的一类工具调用。
struct TaskCommentExecutionTool: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let count: Int
}

/// 执行卡片用的本轮摘要：动作数、思考段、回复段、耗时与工具分类计数。
struct TaskCommentExecution: Equatable {
    var available = false
    var reason = ""
    var outcome = ""
    var actionCount = 0
    var thinkingCount = 0
    var replyCount = 0
    /// 最后一条回复正文。
    var replyText = ""
    var startedAt: String?
    var endedAt: String?
    var tools: [TaskCommentExecutionTool] = []

    var isRunning: Bool { reason == "still_running" }
    var elapsedSeconds: Int? {
        guard let started = SessionTimeFormatting.date(from: startedAt) else { return nil }
        let ended = SessionTimeFormatting.date(from: endedAt) ?? Date()
        return max(0, Int(ended.timeIntervalSince(started)))
    }
}

/// 把服务端冻结的执行区间折算成执行卡片要的摘要。
func taskCommentExecution(from result: WandTaskCommentResult) -> TaskCommentExecution {
    var execution = TaskCommentExecution()
    execution.available = result.available
    execution.reason = result.reason ?? ""
    execution.outcome = result.outcome ?? ""
    guard result.available else { return execution }
    var toolCounts: [String: Int] = [:]
    var toolOrder: [String] = []
    var replies: [String] = []
    for message in result.messages {
        if execution.startedAt == nil { execution.startedAt = message.createdAt }
        if let completed = message.completedAt { execution.endedAt = completed }
        for block in message.content {
            switch block {
            case .toolUse(_, let name, _, _, _):
                execution.actionCount += 1
                if toolCounts[name] == nil { toolOrder.append(name) }
                toolCounts[name, default: 0] += 1
            case .thinking:
                execution.thinkingCount += 1
            case .text(let text, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { break }
                execution.replyCount += 1
                replies.append(trimmed)
            case .toolResult, .unknown:
                break
            }
        }
    }
    execution.tools = toolOrder.compactMap { name in
        guard let count = toolCounts[name] else { return nil }
        return TaskCommentExecutionTool(name: name, count: count)
    }
    execution.replyText = replies.last ?? ""
    return execution
}

/// 耗时文案：`2h 38m 22s`。
func taskCommentElapsedLabel(seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60
    if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, remainder) }
    if minutes > 0 { return String(format: "%dm %02ds", minutes, remainder) }
    return String(format: "%ds", remainder)
}

/// A request identity prevents a late A response from replacing B (or a newly reopened A).
struct WandTaskCommentState {
    private(set) var taskId = ""
    private(set) var requestId = UUID()
    private(set) var comments: [WandTaskComment] = []
    /// 服务端给出的评论总数；老服务端不返回时为 nil。
    private(set) var totalCount: Int? = nil
    /// 更早一页的游标；还有更早评论时非 nil。
    private(set) var nextCursor: String? = nil
    /// 最新一页（轮询会反复替换它）。
    private var firstPage: [WandTaskComment] = []
    /// 用户主动翻出来的更早评论（按时间从早到晚排在新页之前）。
    private var olderComments: [WandTaskComment] = []

    mutating func begin(taskId: String) -> UUID {
        if self.taskId != taskId {
            comments = []
            firstPage = []
            olderComments = []
            totalCount = nil
            nextCursor = nil
        }
        self.taskId = taskId
        requestId = UUID()
        return requestId
    }

    mutating func accept(_ comments: [WandTaskComment], taskId: String, requestId: UUID) {
        guard self.taskId == taskId, self.requestId == requestId else { return }
        self.comments = comments.filter { $0.taskId == taskId }
        firstPage = self.comments
        olderComments = []
    }

    /// 轮询到最新一页：保留用户已经翻出来的更早评论。
    mutating func mergeFirstPage(_ comments: [WandTaskComment], totalCount: Int?, nextCursor: String?, taskId: String, requestId: UUID) {
        guard self.taskId == taskId, self.requestId == requestId else { return }
        firstPage = comments.filter { $0.taskId == taskId }
        self.totalCount = totalCount
        self.nextCursor = nextCursor
        self.comments = merged(olderComments + firstPage)
    }

    /// 翻出更早一页：插到已加载列表的最前面（更早 = 更靠前）。
    /// 只校验任务归属：轮询会换请求标识，拿它当守卫会把这一页丢掉。
    mutating func prependOlderPage(_ comments: [WandTaskComment], nextCursor: String?, taskId: String) {
        guard self.taskId == taskId else { return }
        olderComments = comments.filter { $0.taskId == taskId } + olderComments
        self.nextCursor = nextCursor
        self.comments = merged(olderComments + firstPage)
    }

    private func merged(_ list: [WandTaskComment]) -> [WandTaskComment] {
        var seen = Set<String>()
        var result: [WandTaskComment] = []
        for comment in list where !seen.contains(comment.id) {
            seen.insert(comment.id)
            result.append(comment)
        }
        return result
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

    static func insert(body: String, caret: Int, name: String, replacingName: String = "") -> (body: String, caret: Int) {
        let chars = Array(body)
        let index = min(max(caret, 0), chars.count)
        // A stale candidate must not append another mention. Replace the whole token,
        // including the name to the right of the real caret.
        guard let query = query(in: body, caret: index) else { return (body, index) }
        var end = index
        while end < chars.count && !chars[end].isWhitespace { end += 1 }
        let previous = mentionRanges(in: body, name: replacingName).first { range in
            let start = body.distance(from: body.startIndex, to: range.lowerBound)
            let finish = body.distance(from: body.startIndex, to: range.upperBound)
            return finish <= query.start || start >= end
        }
        if let previous {
            let start = body.distance(from: body.startIndex, to: previous.lowerBound)
            let finish = body.distance(from: body.startIndex, to: previous.upperBound)
            var value = chars
            let edits = [(query.start, end, [Character]()), (start, finish, Array("@\(name)"))]
            for edit in edits.sorted(by: { $0.0 > $1.0 }) { value.replaceSubrange(edit.0..<edit.1, with: edit.2) }
            let offset = query.start + (start < query.start ? name.count - replacingName.count : 0)
            return compactPrefix(String(value), caret: offset, name: name, replacingName: replacingName)
        }
        let token = Array("@\(name)" + (end == chars.count ? " " : ""))
        let value = String(chars[..<query.start] + token + chars[end...])
        return compactPrefix(value, caret: query.start + token.count + (end < chars.count ? 1 : 0), name: name, replacingName: replacingName)
    }

    /// Only the dispatch preamble is canonicalized. Never rewrite @ examples,
    /// addresses, quoted text, or other prose later in the instruction.
    private static func compactPrefix(_ body: String, caret: Int, name: String, replacingName: String = "") -> (body: String, caret: Int) {
        guard !name.isEmpty else { return (body, caret) }
        let chars = Array(body)
        let allowed = ["@\(name)", "@\(replacingName)", "@"].sorted { $0.count > $1.count }.map(Array.init)
        var end = 0, count = 0
        while end < chars.count {
            var start = end
            while start < chars.count && chars[start].isWhitespace { start += 1 }
            guard let token = allowed.first(where: { token in
                let next = start + token.count
                return next <= chars.count && Array(chars[start..<next]) == token
                    && (next == chars.count || chars[next].isWhitespace)
            }) else { break }
            count += 1
            end = start + token.count
            while end < chars.count && chars[end].isWhitespace { end += 1 }
        }
        guard count > 0 else { return (body, caret) }
        let prefix = "@\(name) "
        return (prefix + String(chars[end...]), caret <= end ? prefix.count : caret - end + prefix.count)
    }

    static func submissionBody(_ body: String, name: String) -> String {
        compactPrefix(body, caret: body.count, name: name).body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validationMessage(_ body: String, name: String) -> String? {
        let text = submissionBody(body, name: name)
        guard !text.isEmpty else { return "请填写评论内容。" }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let mentions = tokens.filter { $0.hasPrefix("@") }
        if name.isEmpty && !mentions.isEmpty { return "请从 @ 候选列表选择员工，或删除未完成的提及后发表普通评论。" }
        if !name.isEmpty {
            let ranges = mentionRanges(in: text, name: name)
            guard ranges.count == 1, let range = ranges.first else {
                return "请删除残留或重复的 @，本次只派发给选中的一位员工。"
            }
            var instruction = text
            instruction.removeSubrange(range)
            if instruction.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix("@") }) {
                return "请删除残留或重复的 @，本次只派发给选中的一位员工。"
            }
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "请在 @员工 后填写本轮指令。" }
        }
        return nil
    }

    static func caretOffset(in body: String, at index: String.Index) -> Int? {
        // Native selection notifications can arrive after a shorter replacement.
        guard index >= body.startIndex, index <= body.endIndex,
              let current = index.samePosition(in: body) else { return nil }
        return body.distance(from: body.startIndex, to: current)
    }

    private static func mentionRanges(in body: String, name: String) -> [Range<String.Index>] {
        guard !name.isEmpty else { return [] }
        let pattern = "(?<!\\S)@\(NSRegularExpression.escapedPattern(for: name))(?=\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)).compactMap { Range($0.range, in: body) }
    }

    static func holds(_ body: String, name: String) -> Bool {
        !mentionRanges(in: body, name: name).isEmpty
    }

}
