import Foundation

/// wand 服务端 REST / WebSocket 协议的 Codable 模型。
/// 字段名与 src/types.ts 一一对应；全部 optional 化 + 容错解码，
/// 服务端新增字段或个别字段形状变化时客户端不至于整体解析失败。

// MARK: - Provider 能力

/// Wand 支持的 CLI provider。与 provider 相关的名称、runner 和模式约束
/// 集中在这里，避免 UI 各自维护 Claude/Codex 二分判断而漏掉 OpenCode。
enum WandProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode
    case grok
    case qoder

    var id: String { rawValue }

    /// 对旧数据、大小写与未知 provider 做安全归一；未知值按 Claude 处理。
    init(normalizing value: String?) {
        let raw = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch raw {
        case Self.codex.rawValue:
            self = .codex
        case Self.opencode.rawValue, "open-code", "open_code":
            self = .opencode
        case Self.grok.rawValue:
            self = .grok
        case Self.qoder.rawValue, "qodercli":
            self = .qoder
        default:
            self = .claude
        }
    }

    /// 给仍使用 String 状态的界面/API 一个统一的归一入口。
    static func normalize(_ value: String?) -> String {
        WandProvider(normalizing: value).rawValue
    }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .grok: return "Grok"
        case .qoder: return "Qoder"
        }
    }

    var structuredRunner: String {
        switch self {
        case .claude: return "claude-cli-print"
        case .codex: return "codex-cli-exec"
        case .opencode: return "opencode-cli-run"
        case .grok: return "grok-cli-headless"
        case .qoder: return "qoder-cli-print"
        }
    }

    /// 与 Web `getSupportedModes` / Android `supportedModeIds` 保持一致。
    var supportedModeIDs: Set<String> {
        switch self {
        case .claude:
            return ["default", "full-access", "auto-edit", "native", "managed"]
        case .codex:
            return ["full-access"]
        case .opencode:
            return ["default", "full-access", "managed"]
        case .grok:
            return ["default", "full-access", "managed"]
        case .qoder:
            return ["default", "full-access", "auto-edit", "managed"]
        }
    }

    /// 将持久化的模式 clamp 到 provider 的有效集合。
    /// 优先使用当前值，其次使用服务端 fallback，最后使用 provider 安全默认。
    func clamp(mode value: String?, fallback: String? = nil) -> String {
        let requested = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if supportedModeIDs.contains(requested) { return requested }

        let configured = fallback?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if supportedModeIDs.contains(configured) { return configured }

        // 与 Web getSafeModeForTool 一致：无效配置必须回落到权限最保守的
        // supported[0]。不能把未知/未来模式静默升级成 managed 自动执行。
        if self == .codex { return "full-access" }
        return "default"
    }
}

// MARK: - 任意 JSON 值

/// 工具调用的 input 是任意 JSON 对象（types.ts: Record<string, unknown>），
/// 用枚举承接后在 UI 层做摘要展示。
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            self = .null
        }
    }

    /// 单行摘要文本，用于 tool_use 卡片里展示参数。
    var summaryText: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            return n == n.rounded() && abs(n) < 1e15
                ? String(Int64(n))
                : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[\(a.count) 项]"
        case .object: return "{…}"
        }
    }

    // 便利访问器：tool_use input 的结构化读取（AskUserQuestion / TodoWrite / Edit 等专用卡片用）。
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// 用于未知协议块和不认识的结构化 content part。限制深度、条数、
    /// 单字符串和最终长度，并遮罩常见敏感键，避免把密钥或无界载荷直接铺到 UI。
    fileprivate func safePayloadText(maxCharacters: Int = 32_768) -> String {
        let object = safeFoundationObject(depth: 0)
        let text = Self.serializedText(object)
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n…[载荷已截断]"
    }

    /// tool_result 本身就是用户可查看/复制的输出，不能复用未知块的 8K/32K
    /// 安全摘要上限。展示层自己限长，这里保留完整文本供复制。
    fileprivate func fullPayloadText() -> String {
        Self.serializedText(fullFoundationObject())
    }

    private static func serializedText(_ object: Any) -> String {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        if let string = object as? String { return string }
        return String(describing: object)
    }

    private func fullFoundationObject() -> Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.isFinite ? value : String(value)
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map { $0.fullFoundationObject() }
        case .object(let values):
            return values.mapValues { $0.fullFoundationObject() }
        }
    }

    private func safeFoundationObject(depth: Int) -> Any {
        guard depth < 10 else { return "[已达最大深度]" }
        switch self {
        case .string(let value):
            let value = Self.redactSensitiveText(value)
            let limit = 8_192
            return value.count > limit ? String(value.prefix(limit)) + "…[已截断]" : value
        case .number(let value):
            return value.isFinite ? value : String(value)
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        case .array(let values):
            let limit = 128
            var result = values.prefix(limit).map { $0.safeFoundationObject(depth: depth + 1) }
            if values.count > limit { result.append("…[其余 \(values.count - limit) 项已省略]") }
            return result
        case .object(let values):
            let limit = 128
            var result: [String: Any] = [:]
            for key in values.keys.sorted().prefix(limit) {
                if Self.isSensitiveKey(key) {
                    result[key] = "••••••"
                } else if let value = values[key] {
                    result[key] = value.safeFoundationObject(depth: depth + 1)
                }
            }
            if values.count > limit { result["_wand_truncated"] = "\(values.count - limit) 个字段已省略" }
            return result
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["password", "passwd", "secret", "token", "authorization", "cookie", "credential", "privatekey", "apikey"]
            .contains { normalized.contains($0) }
    }

    /// 未知块中的敏感值不一定放在同名 key 下，也可能藏在 debug/args/URL
    /// 字符串中。在有界摘要入 UI 前再扫一遍常见 credential 形状。
    private static func redactSensitiveText(_ value: String) -> String {
        var output = value
        let rules: [(pattern: String, replacement: String)] = [
            (#"(?i)\b(?:Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]{6,}"#, "Credential ••••••"),
            (#"(?i)\b((?:[A-Z0-9]+[_-])*(?:API[_-]?KEY|ACCESS[_-]?TOKEN|TOKEN|SECRET|PASSWORD|PASSWD|AUTHORIZATION|COOKIE|CREDENTIAL|PRIVATE[_-]?KEY)(?:[_-][A-Z0-9]+)*)\s*([:=])\s*([^\s,&;\]\}\"]+)"#, "$1$2••••••"),
            (#"(?i)([?&](?:access_token|api[_-]?key|token|secret|password|credential)=)[^&#\s]+"#, "$1••••••"),
            (#"(?i)\b(?:sk-(?:ant-)?|gh[pousr]_|xox[baprs]-)[A-Za-z0-9._-]{8,}"#, "••••••"),
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "••••••"),
        ]
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: rule.replacement
            )
        }
        return output
    }
}

/// tool_result.content 兼容纯字符串、Responses/OpenCode/MCP content parts 及嵌套对象。
/// 对象优先抽取常见文本键；无已知文本键时保留完整 JSON 文本。
private func structuredContentText(_ value: JSONValue) -> String {
    switch value {
    case .null:
        return ""
    case .string(let text):
        return text
    case .number, .bool:
        return value.summaryText
    case .array(let values):
        return values
            .lazy
            .map(structuredContentText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    case .object(let object):
        for key in ["text", "output_text", "input_text", "message", "summary"] {
            guard let nested = object[key] else { continue }
            let extracted = structuredContentText(nested)
            if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return extracted }
        }
        return value.fullPayloadText()
    }
}

/// 读取 tool_use input 里的数组字段，容忍服务端把数组拍成 JSON 字符串的情况。
/// `claude -p --output-format stream-json`（默认结构化 runner）会把 TodoWrite.todos /
/// AskUserQuestion.questions 当成 "[{...}]" 字符串下发，直接取 arrayValue 会拿到 nil，
/// 待办进度条与提问卡片整段渲染不出来。这里数组形态直接用，字符串形态再解析一次。
func jsonArrayField(_ input: [String: JSONValue], _ key: String) -> [JSONValue]? {
    switch input[key] {
    case .array(let a):
        return a
    case .string(let s):
        guard let data = s.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) else { return nil }
        return decoded
    default:
        return nil
    }
}

// MARK: - 特殊工具卡片的 input 模型

/// AskUserQuestion 的一道题（tool_use input.questions[i]），字段对齐 Web 端 chat-render.ts。
struct AskUserQuestion {
    struct Option {
        let label: String
        let description: String?
    }

    let question: String
    let header: String?
    let multiSelect: Bool
    let options: [Option]

    /// 从 tool_use 的 input 解析 questions 数组；形状不符返回空数组（上层回落普通工具卡）。
    static func parse(input: [String: JSONValue]) -> [AskUserQuestion] {
        guard let items = input["__wandQuestions"]?.arrayValue ?? jsonArrayField(input, "questions") else { return [] }
        var result: [AskUserQuestion] = []
        for item in items {
            guard let obj = item.objectValue else { continue }
            var options: [Option] = []
            for raw in obj["options"]?.arrayValue ?? [] {
                guard let opt = raw.objectValue else { continue }
                let label = opt["label"]?.stringValue ?? ""
                options.append(Option(
                    label: label.isEmpty ? "选项 \(options.count + 1)" : label,
                    description: opt["description"]?.stringValue
                ))
            }
            guard !options.isEmpty else { continue }
            result.append(AskUserQuestion(
                question: obj["question"]?.stringValue ?? "",
                header: obj["header"]?.stringValue,
                multiSelect: obj["multiSelect"]?.boolValue ?? false,
                options: options
            ))
        }
        return result
    }
}

/// TodoWrite 的一项待办（tool_use input.todos[i]）。
struct TodoItem {
    let content: String
    let status: String
    let activeForm: String?

    /// 协议明确标记 in_progress 时优先使用；只有 pending/completed 二态时，
    /// 把首个 pending 推导为正在执行，供两种协议保持一致的展示语义。
    static func activeIndex(in todos: [TodoItem]) -> Int? {
        if let explicit = todos.firstIndex(where: { $0.status == "in_progress" }) {
            return explicit
        }
        return todos.firstIndex(where: { $0.status == "pending" })
    }

    static func parse(input: [String: JSONValue]) -> [TodoItem] {
        guard let items = jsonArrayField(input, "todos") else { return [] }
        var result: [TodoItem] = []
        for item in items {
            guard let obj = item.objectValue else { continue }
            result.append(TodoItem(
                content: obj["content"]?.stringValue ?? "",
                status: obj["status"]?.stringValue ?? "pending",
                activeForm: obj["activeForm"]?.stringValue
            ))
        }
        return result
    }

    /// 当前 turn 的待办列表：只看最后一条 user 消息之后的待办事件，
    /// 对齐 Web 端 updateTodoProgress 的 scoping（上一轮的进度条不跨 turn 残留）。
    /// 全部完成时返回空（对齐 Web/安卓 allDone 隐藏）。
    /// 同时支持两套协议：
    ///   - 旧 TodoWrite：最后一次写入即完整快照，倒序取最新。
    ///   - 新 TaskCreate / TaskUpdate：创建与更新是增量事件，按时间顺序归并。
    static func currentTodos(in messages: [ConversationTurn]) -> [TodoItem] {
        var startIdx = 0
        for i in stride(from: messages.count - 1, through: 0, by: -1) where messages[i].role == "user" {
            startIdx = i + 1
            break
        }

        // 旧 TodoWrite 协议：最后一次写入就是完整快照，倒序取最新即可。
        for i in stride(from: messages.count - 1, through: startIdx, by: -1) {
            for block in messages[i].content.reversed() {
                if case .toolUse(_, let name, _, let input, _) = block {
                    let source = input["__wandTasks"] != nil ? ["todos": input["__wandTasks"]!] : input
                    if name != "TodoWrite" && input["__wandTasks"] == nil { continue }
                    let todos = parse(input: source)
                    if todos.isEmpty { continue }
                    let completed = todos.filter { $0.status == "completed" }.count
                    return completed == todos.count ? [] : todos
                }
            }
        }

        // 新 TaskCreate / TaskUpdate 协议：两遍归并（对齐 Web reconstructTodosFromTaskTools）。
        guard startIdx <= messages.count else { return [] }
        // 第一遍：按 tool_use_id 收集所有 tool_result 文本——TaskCreate 分配的真实 id
        // 只在结果文本里（「Task #N created …」），input 里没有。
        var resultById: [String: String] = [:]
        for i in startIdx..<messages.count {
            for block in messages[i].content {
                if case .toolResult(let toolUseId, let text, _, _, _) = block {
                    resultById[toolUseId] = text
                }
            }
        }
        // 第二遍：按调用顺序重放 TaskCreate（新建）/ TaskUpdate（改状态/标题）；
        // order 保插入序，看到 TaskCreate 就建条目（结果未到时用 fallback 序号兜底）。
        var order: [String] = []
        var tasks: [String: TodoItem] = [:]
        var sawTaskTool = false
        var createFallback = 0
        for i in startIdx..<messages.count {
            for block in messages[i].content {
                guard case .toolUse(let id, let name, _, let input, _) = block else { continue }
                if name == "TaskCreate" {
                    sawTaskTool = true
                    createFallback += 1
                    let cid = Self.extractTaskId(resultById[id] ?? "") ?? String(createFallback)
                    if tasks[cid] == nil { order.append(cid) }
                    tasks[cid] = TodoItem(
                        content: input["subject"]?.stringValue
                            ?? input["description"]?.stringValue
                            ?? "Task #\(cid)",
                        status: "pending",
                        activeForm: input["activeForm"]?.stringValue
                    )
                } else if name == "TaskUpdate" {
                    sawTaskTool = true
                    guard let uid = Self.idString(input["taskId"]) else { continue }
                    let existing = tasks[uid]
                    if existing == nil { order.append(uid) }
                    tasks[uid] = TodoItem(
                        content: input["subject"]?.stringValue ?? existing?.content ?? "Task #\(uid)",
                        status: input["status"]?.stringValue ?? existing?.status ?? "pending",
                        activeForm: input["activeForm"]?.stringValue ?? existing?.activeForm
                    )
                }
            }
        }
        guard sawTaskTool else { return [] }
        let derived = order.compactMap { tasks[$0] }.filter { $0.status != "deleted" }
        if derived.isEmpty { return [] }
        let completed = derived.filter { $0.status == "completed" }.count
        return completed == derived.count ? [] : derived
    }

    /// 从 TaskCreate 返回文本里抽取「Task #N」中的 N（id 由数字组成）。
    private static let taskIdRegex = try? NSRegularExpression(pattern: #"#(\d+)"#)
    private static func extractTaskId(_ text: String) -> String? {
        guard let re = taskIdRegex else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// taskId 兼容字符串与数字两种 JSON 形态。
    private static func idString(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        default: return nil
        }
    }
}

private struct ToolUseSemantic: Decodable {
    struct Question: Decodable {
        struct Option: Decodable { let label: String; let description: String? }
        let question: String; let header: String?; let multiSelect: Bool; let options: [Option]
    }
    struct Task: Decodable { let id: String; let content: String; let status: String; let activeForm: String? }
    let kind: String
    let questions: [Question]?
    let items: [Task]?
}

private func mergeSemantic(_ semantic: ToolUseSemantic, into input: inout [String: JSONValue]) {
    if semantic.kind == "question_request" {
        input["__wandQuestions"] = .array((semantic.questions ?? []).map { question in
            .object([
                "question": .string(question.question), "header": question.header.map(JSONValue.string) ?? .null,
                "multiSelect": .bool(question.multiSelect),
                "options": .array(question.options.map { .object([
                    "label": .string($0.label), "description": $0.description.map(JSONValue.string) ?? .null,
                ]) }),
            ])
        })
    } else if semantic.kind == "task_list" {
        input["__wandTasks"] = .array((semantic.items ?? []).map { task in
            .object([
                "id": .string(task.id), "content": .string(task.content), "status": .string(task.status),
                "activeForm": task.activeForm.map(JSONValue.string) ?? .null,
            ])
        })
    }
}

// MARK: - 会话消息块

struct SubagentMeta: Decodable {
    let taskId: String?
    let agentType: String?
    let taskDescription: String?
}

/// 单轮 assistant 的用量统计。服务端当前下发 camelCase；这里也兼容 snake_case，
/// 方便以后直接透传上游 usage 时 iOS 不丢字段。
struct TurnUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalCostUsd: Double?
    let estimated: Bool?

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheReadInputTokens
        case cacheCreationInputTokens
        case reasoningOutputTokens
        case totalCostUsd
        case estimated
        case inputTokensSnake = "input_tokens"
        case outputTokensSnake = "output_tokens"
        case cacheReadInputTokensSnake = "cache_read_input_tokens"
        case cacheCreationInputTokensSnake = "cache_creation_input_tokens"
        case reasoningOutputTokensSnake = "reasoning_output_tokens"
        case totalCostUsdSnake = "total_cost_usd"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens))
            ?? (try? c.decode(Int.self, forKey: .inputTokensSnake))
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens))
            ?? (try? c.decode(Int.self, forKey: .outputTokensSnake))
        cacheReadInputTokens = (try? c.decode(Int.self, forKey: .cacheReadInputTokens))
            ?? (try? c.decode(Int.self, forKey: .cacheReadInputTokensSnake))
        cacheCreationInputTokens = (try? c.decode(Int.self, forKey: .cacheCreationInputTokens))
            ?? (try? c.decode(Int.self, forKey: .cacheCreationInputTokensSnake))
        reasoningOutputTokens = (try? c.decode(Int.self, forKey: .reasoningOutputTokens))
            ?? (try? c.decode(Int.self, forKey: .reasoningOutputTokensSnake))
        totalCostUsd = (try? c.decode(Double.self, forKey: .totalCostUsd))
            ?? (try? c.decode(Double.self, forKey: .totalCostUsdSnake))
        estimated = try? c.decode(Bool.self, forKey: .estimated)
    }

    var hasVisibleValue: Bool {
        (inputTokens ?? 0) > 0
            || (outputTokens ?? 0) > 0
            || (cacheReadInputTokens ?? 0) > 0
            || (cacheCreationInputTokens ?? 0) > 0
            || (reasoningOutputTokens ?? 0) > 0
            || (totalCostUsd ?? 0) > 0
    }
}

/// ConversationTurn.content 里的一个块。types.ts: ContentBlock 四种变体 + 容错。
enum ContentBlock: Decodable {
    case text(text: String, subagent: SubagentMeta?)
    case thinking(thinking: String, subagent: SubagentMeta?)
    case toolUse(id: String, name: String, description: String?, input: [String: JSONValue], subagent: SubagentMeta?)
    case toolResult(toolUseId: String, text: String, isError: Bool, truncated: Bool, subagent: SubagentMeta?)
    /// 协议升级兜底：保留类型和有界、脱敏的原始载荷，UI 可明确告知用户。
    case unknown(type: String, payload: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, description, input, content, semantic
        case toolUseId = "tool_use_id"
        case isError = "is_error"
        case truncated = "_truncated"
        case subagent = "__subagent"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        let subagent = try? c.decode(SubagentMeta.self, forKey: .subagent)
        switch type {
        case "text":
            self = .text(
                text: (try? c.decode(String.self, forKey: .text)) ?? "",
                subagent: subagent
            )
        case "thinking":
            self = .thinking(
                thinking: (try? c.decode(String.self, forKey: .thinking)) ?? "",
                subagent: subagent
            )
        case "tool_use":
            var input = (try? c.decode([String: JSONValue].self, forKey: .input)) ?? [:]
            if let semantic = try? c.decode(ToolUseSemantic.self, forKey: .semantic) {
                mergeSemantic(semantic, into: &input)
            }
            self = .toolUse(
                id: (try? c.decode(String.self, forKey: .id)) ?? "",
                name: (try? c.decode(String.self, forKey: .name)) ?? "tool",
                description: try? c.decode(String.self, forKey: .description),
                input: input,
                subagent: subagent
            )
        case "tool_result":
            // content: string | content parts | object。兼容 Responses/OpenCode/MCP 的常见文本键。
            let content = (try? c.decode(JSONValue.self, forKey: .content)) ?? .null
            self = .toolResult(
                toolUseId: (try? c.decode(String.self, forKey: .toolUseId)) ?? "",
                text: structuredContentText(content),
                isError: (try? c.decode(Bool.self, forKey: .isError)) ?? false,
                truncated: (try? c.decode(Bool.self, forKey: .truncated)) ?? false,
                subagent: subagent
            )
        default:
            let rawPayload = (try? JSONValue(from: decoder)) ?? .null
            let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .unknown(
                type: String((normalizedType.isEmpty ? "unknown" : normalizedType).prefix(128)),
                payload: rawPayload.safePayloadText()
            )
        }
    }
}

struct ConversationTurn: Decodable {
    let role: String
    let content: [ContentBlock]
    let usage: TurnUsage?

    private enum CodingKeys: String, CodingKey { case role, content, usage }

    init(role: String, content: [ContentBlock], usage: TurnUsage? = nil) {
        self.role = role
        self.content = content
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
        usage = try? c.decode(TurnUsage.self, forKey: .usage)
        // 逐块容错：单个块解析失败不拖垮整条消息。
        var blocks: [ContentBlock] = []
        if var arr = try? c.nestedUnkeyedContainer(forKey: .content) {
            while !arr.isAtEnd {
                if let block = try? arr.decode(ContentBlock.self) {
                    blocks.append(block)
                } else {
                    _ = try? arr.decode(JSONValue.self)
                }
            }
        }
        content = blocks
    }
}

extension ContentBlock {
    var subagentMeta: SubagentMeta? {
        switch self {
        case .text(_, let subagent),
             .thinking(_, let subagent),
             .toolUse(_, _, _, _, let subagent),
             .toolResult(_, _, _, _, let subagent):
            return subagent
        case .unknown:
            return nil
        }
    }
}

struct SubagentActivity {
    enum State: Equatable {
        case running
        case completed
        case failed
    }

    let id: String
    let meta: SubagentMeta
    let blocks: [ContentBlock]
    let state: State
}

func collectSubagentActivities(
    messages: [ConversationTurn],
    isResponding: Bool
) -> [SubagentActivity] {
    struct PendingActivity {
        var meta: SubagentMeta
        var blocks: [ContentBlock]
        var lastSeenTurnIndex: Int
        var completed = false
        var failed = false
    }

    let lastUserTurnIndex = messages.lastIndex { $0.role == "user" } ?? -1
    var activities: [String: PendingActivity] = [:]
    var orderedIDs: [String] = []

    for (turnIndex, turn) in messages.enumerated() {
        for block in turn.content {
            guard let meta = block.subagentMeta,
                  let taskID = meta.taskId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !taskID.isEmpty else {
                continue
            }

            if activities[taskID] == nil {
                orderedIDs.append(taskID)
                activities[taskID] = PendingActivity(
                    meta: meta,
                    blocks: [],
                    lastSeenTurnIndex: turnIndex
                )
            }

            guard var activity = activities[taskID] else { continue }
            activity.meta = meta
            activity.blocks.append(block)
            activity.lastSeenTurnIndex = turnIndex
            if case .toolResult(let toolUseID, _, let isError, _, _) = block, toolUseID == taskID {
                activity.completed = true
                activity.failed = isError
            }
            activities[taskID] = activity
        }
    }

    return orderedIDs.compactMap { taskID in
        guard let activity = activities[taskID] else { return nil }
        let state: SubagentActivity.State
        if activity.completed {
            state = activity.failed ? .failed : .completed
        } else if isResponding && activity.lastSeenTurnIndex > lastUserTurnIndex {
            state = .running
        } else {
            state = .completed
        }
        return SubagentActivity(
            id: taskID,
            meta: activity.meta,
            blocks: activity.blocks,
            state: state
        )
    }
}

func parentTranscriptBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
    blocks.filter { $0.subagentMeta == nil }
}

// MARK: - 权限请求

struct EscalationRequest: Decodable, Equatable {
    let requestId: String
    let scope: String
    let reason: String
    let target: String?
    let source: String?

    static func == (lhs: EscalationRequest, rhs: EscalationRequest) -> Bool {
        lhs.requestId == rhs.requestId
    }

    /// scope → 用户可读标题（types.ts EscalationScope）。
    var scopeTitle: String {
        switch scope {
        case "write_file": return "写入文件"
        case "run_command": return "执行命令"
        case "network": return "访问网络"
        case "outside_workspace": return "访问工作区外路径"
        case "dangerous_shell": return "执行高危命令"
        default: return "权限请求"
        }
    }
}

/// PTY 会话 status 事件里的旧式权限提示（ws data.permissionRequest）。
struct PermissionRequestInfo: Decodable {
    let scope: String?
    let target: String?
    let prompt: String?
}

struct StructuredSessionState: Decodable {
    let runner: String?
    let model: String?
    let lastError: String?
    let inFlight: Bool?
    let activeRequestId: String?
}

// MARK: - 会话快照

/// SessionSnapshot 的客户端子集。GET /api/sessions 返回 slim 版（无 messages），
/// GET /api/sessions/:id?format=chat 与 ws init 返回带 messages 的完整版。
struct SessionSnapshot: Decodable, Identifiable {
    let id: String
    let sessionKind: String?
    let provider: String?
    let runner: String?
    let command: String?
    let cwd: String?
    let mode: String?
    let status: String?
    let exitCode: Int?
    let startedAt: String?
    let endedAt: String?
    let archived: Bool?
    var summary: String?
    var title: String? = nil
    var description: String? = nil
    var titleGenerating: Bool? = nil
    let currentTaskTitle: String?
    let selectedModel: String?
    let thinkingEffort: String?
    let claudeSessionId: String?
    let messages: [ConversationTurn]?
    /// 窗口化：messages 是完整历史的「最近一窗」，messageOffset = 首条的绝对下标，
    /// messageTotal = 完整 turn 数。更早的消息按需翻页（GET /api/sessions/:id/messages）。
    let messageOffset: Int?
    let messageTotal: Int?
    /// 块级窗口（iOS 带 blockBudget 时）：messages[0] 被切掉的头部块数（0=该 turn 完整），
    /// 以及 turn messageOffset 的完整块数。滚动到顶时先按块翻这条 turn 的头部，再按 turn 往前翻。
    var leadingBlockOffset: Int? = nil
    var leadingBlockTotal: Int? = nil
    let queuedMessages: [String]?
    let structuredState: StructuredSessionState?
    let pendingEscalation: EscalationRequest?
    let permissionBlocked: Bool?
    let autoApprovePermissions: Bool?

    var isStructured: Bool { (sessionKind ?? "pty") == "structured" }
    var providerLabel: String { WandProvider(normalizing: provider).title }

    /// 列表标题：模型标题 > 摘要 > 当前任务 > cwd 末段。
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let s = summary, !s.isEmpty { return s }
        if let t = currentTaskTitle, !t.isEmpty { return t }
        if let c = cwd, !c.isEmpty {
            let name = (c as NSString).lastPathComponent
            return name.isEmpty ? c : name
        }
        return "会话"
    }

    var isResponding: Bool {
        if isStructured { return structuredState?.inFlight ?? false }
        return ["initializing", "running", "thinking"].contains(status ?? "")
    }

    var hasPendingPermission: Bool {
        pendingEscalation != nil || (permissionBlocked ?? false)
    }

    var isEnded: Bool {
        ["exited", "failed", "stopped"].contains(status ?? "")
    }
}

/// GET /api/sessions/:id/messages 的分页响应：完整历史的 [offset, offset+limit) 段 + 总数。
struct MessagesPage: Decodable {
    let messages: [ConversationTurn]
    let offset: Int
    let total: Int
}

/// GET /api/sessions/:id/messages?turn=&blockOffset=&blockLimit= 的块级分页响应：
/// 某条 turn 的 [blockOffset, 原 leading 偏移) 段内容块 + 该 turn 的完整块数。
struct BlocksPage: Decodable {
    let turnIndex: Int
    let blocks: [ContentBlock]
    let blockOffset: Int
    let blockTotal: Int
}

/// GET /api/sessions/:id/tool-content/:toolUseId 的完整工具结果。
/// 服务端返回的 `content` 可为字符串或结构化 content parts，模型层统一为 text。
struct ToolContentResponse: Decodable {
    let toolUseId: String
    let text: String
    let isError: Bool

    private enum CodingKeys: String, CodingKey {
        case content
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolUseId = (try? container.decode(String.self, forKey: .toolUseId)) ?? ""
        isError = (try? container.decode(Bool.self, forKey: .isError)) ?? false
        let content = (try? container.decode(JSONValue.self, forKey: .content)) ?? .null
        text = structuredContentText(content)
    }

    var contentBlock: ContentBlock {
        .toolResult(
            toolUseId: toolUseId,
            text: text,
            isError: isError,
            truncated: false,
            subagent: nil
        )
    }
}

// MARK: - 历史会话

/// 从 Claude/Codex 本地历史文件扫描出的会话。两个 provider 的接口形状一致。
struct HistorySession: Decodable, Identifiable {
    let claudeSessionId: String
    let cwd: String
    let firstUserMessage: String
    let timestamp: String?
    let mtimeMs: Double?
    let hasConversation: Bool?
    let managedByWand: Bool?
    let provider: String?

    /// 历史 ID 只在同一 provider 内唯一。把 provider 纳入 SwiftUI 身份，避免
    /// Claude/Codex 恰好使用相同 ID 时列表去重或本地删除误伤另一条记录。
    var id: String { "\(WandProvider.normalize(provider)):\(claudeSessionId)" }
}

// MARK: - WebSocket 消息

/// /ws 推送的统一包络。data 的形状随 type 不同，这里用「超集 struct」承接：
/// init 的 data 就是 SessionSnapshot；output/status/ended 的 data 是其子集 + 增量字段。
struct WsIncoming: Decodable {
    let type: String
    let sessionId: String?
    let seq: Int?
    let t: Double?
    let reason: String?
    let error: String?
    let resync: Bool?
    let data: WsData?
}

struct WsData: Decodable {
    // —— system notification ——
    let kind: String?
    let current: String?
    let latest: String?
    let error: String?
    // —— 快照公共字段（init / status / ended）——
    let id: String?
    let sessionKind: String?
    let provider: String?
    let runner: String?
    let command: String?
    let cwd: String?
    let mode: String?
    let status: String?
    let exitCode: Int?
    let startedAt: String?
    let endedAt: String?
    let archived: Bool?
    let summary: String?
    let title: String?
    let description: String?
    let titleGenerating: Bool?
    let currentTaskTitle: String?
    let selectedModel: String?
    let thinkingEffort: String?
    let claudeSessionId: String?
    let messages: [ConversationTurn]?
    let messageOffset: Int?
    let messageTotal: Int?
    let leadingBlockOffset: Int?
    let leadingBlockTotal: Int?
    let queuedMessages: [String]?
    let structuredState: StructuredSessionState?
    let pendingEscalation: EscalationRequest?
    let permissionBlocked: Bool?
    let autoApprovePermissions: Bool?
    // —— output 事件增量字段 ——
    let chunk: String?
    let lastMessage: ConversationTurn?
    let messageCount: Int?
    let incremental: Bool?
    let isResponding: Bool?
    // —— status 事件附加字段 ——
    let permissionRequest: PermissionRequestInfo?
    // —— task 事件（title 与上方会话标题共用同一 JSON 字段）——
    let tool: String?
}

// MARK: - 目录浏览 / 最近路径

struct DirectoryItem: Decodable, Identifiable {
    let path: String
    let name: String
    let type: String

    var id: String { path }
    var isDirectory: Bool { type == "dir" }
}

struct ModelInfo: Decodable, Identifiable {
    let id: String
    let label: String
    let alias: Bool?
    let reasoningEfforts: [ReasoningEffortInfo]?
    let defaultReasoningEffort: String?
}

struct ReasoningEffortInfo: Decodable {
    let effort: String
    let description: String?
}

struct ThinkingEffortOption: Identifiable {
    let id: String
    let label: String
    let shortLabel: String
    let menuLabel: String
}

func thinkingEffortOptions(provider: String, selectedModel: String?, defaultModel: String?, models: [ModelInfo]) -> [ThinkingEffortOption] {
    let legacy = [
        ThinkingEffortOption(id: "off", label: "自动", shortLabel: "自", menuLabel: "自动（模型默认）"),
        ThinkingEffortOption(id: "standard", label: "低", shortLabel: "低", menuLabel: "低（low）"),
        ThinkingEffortOption(id: "deep", label: "中", shortLabel: "中", menuLabel: "中（medium）"),
        ThinkingEffortOption(id: "max", label: "高", shortLabel: "高", menuLabel: "高（max）"),
    ]
    guard provider == "codex" else { return legacy }
    let modelID = selectedModel.flatMap { !$0.isEmpty && $0 != "default" ? $0 : nil }
        ?? defaultModel.flatMap { !$0.isEmpty && $0 != "default" ? $0 : nil }
        ?? "default"
    guard let levels = (models.first { $0.id == modelID } ?? models.first { $0.id == "default" })?.reasoningEfforts,
          !levels.isEmpty else { return legacy }
    let dynamic = levels.map { level -> ThinkingEffortOption in
        let effort = level.effort.lowercased()
        let id = effort == "low" ? "standard" : effort == "medium" ? "deep" : effort == "xhigh" ? "max" : "codex:\(effort)"
        let label: String
        switch effort {
        case "low": label = "低"
        case "medium": label = "中"
        case "high": label = "高"
        case "xhigh": label = "超高"
        case "max": label = "极高"
        case "ultra": label = "极限"
        default: label = effort
        }
        return ThinkingEffortOption(id: id, label: label, shortLabel: label, menuLabel: "\(label)（\(effort)）")
    }
    return [ThinkingEffortOption(id: "off", label: "自动", shortLabel: "自", menuLabel: "自动（模型默认）")] + dynamic
}

struct ModelsResponse: Decodable {
    let models: [ModelInfo]
    let codexModels: [ModelInfo]
    let opencodeModels: [ModelInfo]
    let qoderModels: [ModelInfo]
    let defaultModel: String?
    let defaultCodexModel: String?
    let defaultOpenCodeModel: String?
    let defaultQoderModel: String?
    let defaultModels: ProviderDefaultModels?

    private enum CodingKeys: String, CodingKey {
        case models, codexModels, opencodeModels, qoderModels
        case defaultModel, defaultCodexModel, defaultOpenCodeModel, defaultQoderModel, defaultModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 旧服务端可能没有 Codex/OpenCode 列表，单个 provider 形状异常也不应
        // 让整个 /api/models 失败。
        models = (try? container.decode([ModelInfo].self, forKey: .models)) ?? []
        codexModels = (try? container.decode([ModelInfo].self, forKey: .codexModels)) ?? []
        opencodeModels = (try? container.decode([ModelInfo].self, forKey: .opencodeModels)) ?? []
        qoderModels = (try? container.decode([ModelInfo].self, forKey: .qoderModels)) ?? []
        defaultModel = try? container.decode(String.self, forKey: .defaultModel)
        defaultCodexModel = try? container.decode(String.self, forKey: .defaultCodexModel)
        defaultOpenCodeModel = try? container.decode(String.self, forKey: .defaultOpenCodeModel)
        defaultQoderModel = try? container.decode(String.self, forKey: .defaultQoderModel)
        defaultModels = try? container.decode(ProviderDefaultModels.self, forKey: .defaultModels)
    }

    func models(for provider: String) -> [ModelInfo] {
        models(for: WandProvider(normalizing: provider))
    }

    func models(for provider: WandProvider) -> [ModelInfo] {
        switch provider {
        case .claude: return models
        case .codex: return codexModels
        case .opencode: return opencodeModels
        case .grok: return []
        case .qoder: return qoderModels
        }
    }

    func defaultModelId(for provider: String) -> String {
        switch WandProvider(normalizing: provider) {
        case .claude:
            return defaultModels?.claude ?? defaultModel ?? ""
        case .codex:
            return defaultModels?.codex ?? defaultCodexModel ?? ""
        case .opencode:
            return defaultModels?.opencode ?? defaultOpenCodeModel ?? ""
        case .grok:
            return ""
        case .qoder:
            return defaultModels?.qoder ?? defaultQoderModel ?? ""
        }
    }
}

struct UploadedFile: Decodable {
    let originalName: String
    let savedPath: String
    let size: Int
    let mimeType: String
}

struct UploadResponse: Decodable {
    let files: [UploadedFile]
}

struct DirectoryListing: Decodable {
    let items: [DirectoryItem]
    let truncated: Bool?
}

struct RecentPath: Decodable, Identifiable {
    let path: String
    let name: String?
    let lastUsedAt: String?

    var id: String { path }
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// GET /api/config 的客户端子集。
struct ServerConfigInfo: Decodable {
    let defaultCwd: String?
    let defaultProvider: String?
    let defaultSessionKind: String?
    let defaultMode: String?
    let defaultModel: String?
    let defaultCodexModel: String?
    let defaultOpenCodeModel: String?
    let defaultQoderModel: String?
    let defaultModels: ProviderDefaultModels?
    let defaultThinkingEffort: String?
    let cardDefaults: CardExpandDefaults?
    let currentVersion: String?
    let latestVersion: String?
    let updateAvailable: Bool?
    let updateChannel: String?

    private enum CodingKeys: String, CodingKey {
        case defaultCwd, defaultProvider, defaultSessionKind, defaultMode
        case defaultModel, defaultCodexModel, defaultOpenCodeModel, defaultQoderModel, defaultModels
        case defaultThinkingEffort, cardDefaults
        case currentVersion, latestVersion, updateAvailable, updateChannel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultCwd = try? container.decode(String.self, forKey: .defaultCwd)
        defaultProvider = try? container.decode(String.self, forKey: .defaultProvider)
        defaultSessionKind = try? container.decode(String.self, forKey: .defaultSessionKind)
        defaultMode = try? container.decode(String.self, forKey: .defaultMode)
        defaultModel = try? container.decode(String.self, forKey: .defaultModel)
        defaultCodexModel = try? container.decode(String.self, forKey: .defaultCodexModel)
        defaultOpenCodeModel = try? container.decode(String.self, forKey: .defaultOpenCodeModel)
        defaultQoderModel = try? container.decode(String.self, forKey: .defaultQoderModel)
        defaultModels = try? container.decode(ProviderDefaultModels.self, forKey: .defaultModels)
        defaultThinkingEffort = try? container.decode(String.self, forKey: .defaultThinkingEffort)
        cardDefaults = try? container.decode(CardExpandDefaults.self, forKey: .cardDefaults)
        currentVersion = try? container.decode(String.self, forKey: .currentVersion)
        latestVersion = try? container.decode(String.self, forKey: .latestVersion)
        updateAvailable = try? container.decode(Bool.self, forKey: .updateAvailable)
        updateChannel = try? container.decode(String.self, forKey: .updateChannel)
    }

    func defaultModelId(for provider: String) -> String {
        switch WandProvider(normalizing: provider) {
        case .claude:
            return defaultModels?.claude ?? defaultModel ?? ""
        case .codex:
            return defaultModels?.codex ?? defaultCodexModel ?? ""
        case .opencode:
            return defaultModels?.opencode ?? defaultOpenCodeModel ?? ""
        case .grok:
            return ""
        case .qoder:
            return defaultModels?.qoder ?? defaultQoderModel ?? ""
        }
    }
}

struct ProviderDefaultModels: Decodable {
    let claude: String?
    let codex: String?
    let opencode: String?
    let qoder: String?

    private enum CodingKeys: String, CodingKey { case claude, codex, opencode, qoder }

    init(claude: String? = nil, codex: String? = nil, opencode: String? = nil, qoder: String? = nil) {
        self.claude = claude
        self.codex = codex
        self.opencode = opencode
        self.qoder = qoder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claude = try? container.decode(String.self, forKey: .claude)
        codex = try? container.decode(String.self, forKey: .codex)
        opencode = try? container.decode(String.self, forKey: .opencode)
        qoder = try? container.decode(String.self, forKey: .qoder)
    }

    func modelId(for provider: String) -> String? {
        switch WandProvider(normalizing: provider) {
        case .claude: return claude
        case .codex: return codex
        case .opencode: return opencode
        case .grok: return nil
        case .qoder: return qoder
        }
    }
}

/// 结构化聊天卡片的全局默认展开状态（由服务端 /api/config.cardDefaults 下发）。
struct CardExpandDefaults: Decodable, Equatable {
    var editCards = false
    var inlineTools = false
    var terminal = false
    var thinking = false
    var toolGroup = false

    init(
        editCards: Bool = false,
        inlineTools: Bool = false,
        terminal: Bool = false,
        thinking: Bool = false,
        toolGroup: Bool = false
    ) {
        self.editCards = editCards
        self.inlineTools = inlineTools
        self.terminal = terminal
        self.thinking = thinking
        self.toolGroup = toolGroup
    }

    private enum CodingKeys: String, CodingKey {
        case editCards, inlineTools, terminal, thinking, toolGroup
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        editCards = try values.decodeIfPresent(Bool.self, forKey: .editCards) ?? false
        inlineTools = try values.decodeIfPresent(Bool.self, forKey: .inlineTools) ?? false
        terminal = try values.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        thinking = try values.decodeIfPresent(Bool.self, forKey: .thinking) ?? false
        toolGroup = try values.decodeIfPresent(Bool.self, forKey: .toolGroup) ?? false
    }

    func shouldExpandTool(_ toolName: String) -> Bool {
        switch toolName {
        case "Read", "Glob", "Grep", "WebFetch", "WebSearch", "TodoRead":
            return inlineTools
        case "Bash":
            return terminal
        case "Edit", "Write", "MultiEdit":
            return editCards
        default:
            // 与 Web 通用工具卡保持一致：未单独分类的工具沿用 editCards。
            return editCards
        }
    }
}

/// 服务端自身 npm 包更新状态。iOS App 不能自更新，但可以提示并触发服务端更新。
struct ServerUpdateInfo: Equatable {
    var current: String
    var latest: String
    var channel: String?

    var normalizedLatest: String {
        latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
    }

    var displayCurrent: String {
        current.hasPrefix("v") ? current : "v\(current)"
    }

    var displayLatest: String {
        latest.hasPrefix("v") ? latest : "v\(latest)"
    }
}

// MARK: - Git 快速提交

/// GET /api/sessions/:id/git-status 的文件条目（porcelain v2 状态码）。
struct GitFileEntry: Decodable, Identifiable {
    let path: String
    let status: String
    let isSubmodule: Bool?

    var id: String { path }

    /// ".M" → "M"、"??" → "?"，给列表一个紧凑的状态徽标。
    var shortStatus: String {
        let cleaned = status.replacingOccurrences(of: ".", with: "")
        if cleaned == "??" { return "?" }
        return cleaned.isEmpty ? "·" : cleaned
    }
}

/// GET /api/sessions/:id/git-status 响应（服务端 GitStatusResult 子集）。
struct GitStatusResult: Decodable {
    struct LastCommit: Decodable {
        let hash: String
        let shortHash: String
        let subject: String
    }

    let isGit: Bool
    let branch: String?
    let modifiedCount: Int?
    let files: [GitFileEntry]?
    let initialCommit: Bool?
    let upstream: String?
    let ahead: Int?
    let behind: Int?
    let lastCommit: LastCommit?
    let latestTag: String?
    let hasSubmodule: Bool?
    let error: String?
}

/// POST /api/sessions/:id/generate-commit-message 响应：AI 撰写的 message 与推荐 tag（不提交）。
struct GenerateCommitMessageResult: Decodable {
    let message: String?
    let suggestedTag: String?
}

/// POST /api/sessions/:id/git/push 响应。部分失败时 HTTP 仍是 200，error 带原因。
struct GitPushResult: Decodable {
    let ok: Bool
    let pushedCommits: Bool?
    let pushedTags: Bool?
    let error: String?
}

/// POST /api/sessions/:id/quick-commit 响应。
struct QuickCommitResult: Decodable {
    struct Commit: Decodable {
        let hash: String
        let message: String
    }
    struct Tag: Decodable {
        let name: String
    }
    struct SubmoduleCommit: Decodable {
        let path: String
        let hash: String
    }

    let ok: Bool
    let commit: Commit?
    let tag: Tag?
    let pushed: Bool?
    let pushError: String?
    let submoduleCommits: [SubmoduleCommit]?
}
