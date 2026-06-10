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
    let claudeSessionId: String?
    let messages: [ConversationTurn]?
    let queuedMessages: [String]?
    let structuredState: StructuredSessionState?
    let pendingEscalation: EscalationRequest?
    let permissionBlocked: Bool?
    let autoApprovePermissions: Bool?

    var isStructured: Bool { (sessionKind ?? "pty") == "structured" }

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
