import Foundation

/// wand 服务端 REST / WebSocket 协议的 Codable 模型。
/// 字段名与 src/types.ts 一一对应；全部 optional 化 + 容错解码，
/// 服务端新增字段或个别字段形状变化时客户端不至于整体解析失败。

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
        guard let items = input["questions"]?.arrayValue else { return [] }
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

    static func parse(input: [String: JSONValue]) -> [TodoItem] {
        guard let items = input["todos"]?.arrayValue else { return [] }
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

    /// 当前 turn 的待办列表：只看最后一条 user 消息之后的 TodoWrite，
    /// 对齐 Web 端 updateTodoProgress 的 scoping（上一轮的进度条不跨 turn 残留）。
    static func currentTodos(in messages: [ConversationTurn]) -> [TodoItem] {
        var startIdx = 0
        for i in stride(from: messages.count - 1, through: 0, by: -1) where messages[i].role == "user" {
            startIdx = i + 1
            break
        }
        for i in stride(from: messages.count - 1, through: startIdx, by: -1) {
            for block in messages[i].content.reversed() {
                if case .toolUse(_, let name, _, let input, _) = block, name == "TodoWrite" {
                    let todos = parse(input: input)
                    if !todos.isEmpty { return todos }
                }
            }
        }
        return []
    }
}

// MARK: - 会话消息块

struct SubagentMeta: Decodable {
    let taskId: String?
    let agentType: String?
    let taskDescription: String?
}

/// ConversationTurn.content 里的一个块。types.ts: ContentBlock 四种变体 + 容错。
enum ContentBlock: Decodable {
    case text(text: String, subagent: SubagentMeta?)
    case thinking(thinking: String, subagent: SubagentMeta?)
    case toolUse(id: String, name: String, description: String?, input: [String: JSONValue], subagent: SubagentMeta?)
    case toolResult(toolUseId: String, text: String, isError: Bool, truncated: Bool, subagent: SubagentMeta?)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, description, input, content
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
            self = .toolUse(
                id: (try? c.decode(String.self, forKey: .id)) ?? "",
                name: (try? c.decode(String.self, forKey: .name)) ?? "tool",
                description: try? c.decode(String.self, forKey: .description),
                input: (try? c.decode([String: JSONValue].self, forKey: .input)) ?? [:],
                subagent: subagent
            )
        case "tool_result":
            // content: string | Array<{type, text?, ...}> —— 数组时抽取所有 text 拼接。
            var text = ""
            if let s = try? c.decode(String.self, forKey: .content) {
                text = s
            } else if let parts = try? c.decode([JSONValue].self, forKey: .content) {
                var pieces: [String] = []
                for part in parts {
                    if case .object(let obj) = part, case .string(let t)? = obj["text"] {
                        pieces.append(t)
                    }
                }
                text = pieces.joined(separator: "\n")
            }
            self = .toolResult(
                toolUseId: (try? c.decode(String.self, forKey: .toolUseId)) ?? "",
                text: text,
                isError: (try? c.decode(Bool.self, forKey: .isError)) ?? false,
                truncated: (try? c.decode(Bool.self, forKey: .truncated)) ?? false,
                subagent: subagent
            )
        default:
            self = .unknown
        }
    }
}

struct ConversationTurn: Decodable {
    let role: String
    let content: [ContentBlock]

    private enum CodingKeys: String, CodingKey { case role, content }

    init(role: String, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
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
    let summary: String?
    let currentTaskTitle: String?
    let selectedModel: String?
    let thinkingEffort: String?
    let claudeSessionId: String?
    let messages: [ConversationTurn]?
    let queuedMessages: [String]?
    let structuredState: StructuredSessionState?
    let pendingEscalation: EscalationRequest?
    let permissionBlocked: Bool?
    let autoApprovePermissions: Bool?

    var isStructured: Bool { (sessionKind ?? "pty") == "structured" }
    var providerLabel: String { provider == "codex" ? "Codex" : "Claude" }

    /// 列表标题：摘要 > 当前任务 > cwd 末段。
    var displayTitle: String {
        if let s = summary, !s.isEmpty { return s }
        if let t = currentTaskTitle, !t.isEmpty { return t }
        if let c = cwd, !c.isEmpty {
            let name = (c as NSString).lastPathComponent
            return name.isEmpty ? c : name
        }
        return "会话"
    }

    var isResponding: Bool {
        if let inFlight = structuredState?.inFlight { return inFlight }
        return false
    }

    var hasPendingPermission: Bool {
        pendingEscalation != nil || (permissionBlocked ?? false)
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

    var id: String { claudeSessionId }
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
    let currentTaskTitle: String?
    let selectedModel: String?
    let thinkingEffort: String?
    let claudeSessionId: String?
    let messages: [ConversationTurn]?
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
    // —— task 事件 ——
    let title: String?
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
}

struct ModelsResponse: Decodable {
    let models: [ModelInfo]
    let codexModels: [ModelInfo]
    let defaultModel: String?
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
    let defaultMode: String?
    let currentVersion: String?
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
