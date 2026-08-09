import Foundation

/// Workspace task windows intentionally support only PTY agents and a bare shell.
enum WorkspaceSessionTarget: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex
    case opencode
    case grok
    case qoder
    case pi
    case shell

    var id: String { rawValue }

    var provider: WandProvider? {
        self == .shell ? nil : WandProvider(rawValue: rawValue)
    }

    var title: String {
        provider?.title ?? "空白终端"
    }

    var summary: String {
        switch self {
        case .claude: return "Claude Code PTY 工作窗口"
        case .codex: return "Codex CLI PTY 工作窗口"
        case .opencode: return "OpenCode TUI 工作窗口"
        case .grok: return "Grok Build TUI 工作窗口"
        case .qoder: return "Qoder CLI TUI 工作窗口"
        case .pi: return "Pi TUI 工作窗口"
        case .shell: return "不启动 Agent 的交互式 Shell"
        }
    }

    init(provider: WandProvider) {
        self = WorkspaceSessionTarget(rawValue: provider.rawValue) ?? .claude
    }
}

struct WorkspaceBinding: Equatable {
    let workspaceId: String
    let workspaceTaskId: String
    let cwd: String
}

/// Codable JSON used only to retain future pane-tab fields during a decode/encode round trip.
indirect enum WorkspaceJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WorkspaceJSONValue])
    case array([WorkspaceJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WorkspaceJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: WorkspaceJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

enum PaneTab: Codable, Equatable, Identifiable {
    case session(id: String, sessionId: String)
    case editor(id: String, path: String)
    case preview(id: String, path: String)
    case unknown(id: String, kind: String, payload: [String: WorkspaceJSONValue])

    var id: String {
        switch self {
        case .session(let id, _), .editor(let id, _), .preview(let id, _), .unknown(let id, _, _):
            return id
        }
    }

    var sessionId: String? {
        if case .session(_, let sessionId) = self { return sessionId }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, sessionId, path
    }

    init(from decoder: Decoder) throws {
        let rawValue = try WorkspaceJSONValue(from: decoder)
        guard case .object(let payload) = rawValue else {
            self = .unknown(id: "unknown-tab", kind: "unknown", payload: [:])
            return
        }
        let id = payload["id"]?.stringValue ?? "unknown-tab"
        let kind = payload["kind"]?.stringValue ?? "unknown"
        switch kind {
        case "session":
            if let sessionId = payload["sessionId"]?.stringValue, !sessionId.isEmpty {
                self = .session(id: id, sessionId: sessionId)
            } else {
                self = .unknown(id: id, kind: kind, payload: payload)
            }
        case "editor":
            if let path = payload["path"]?.stringValue, !path.isEmpty {
                self = .editor(id: id, path: path)
            } else {
                self = .unknown(id: id, kind: kind, payload: payload)
            }
        case "preview":
            if let path = payload["path"]?.stringValue, !path.isEmpty {
                self = .preview(id: id, path: path)
            } else {
                self = .unknown(id: id, kind: kind, payload: payload)
            }
        default:
            self = .unknown(id: id, kind: kind, payload: payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .session(let id, let sessionId):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("session", forKey: .kind)
            try container.encode(sessionId, forKey: .sessionId)
        case .editor(let id, let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("editor", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .preview(let id, let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("preview", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .unknown(let id, let kind, var payload):
            payload["id"] = .string(id)
            payload["kind"] = .string(kind)
            try WorkspaceJSONValue.object(payload).encode(to: encoder)
        }
    }
}

indirect enum LayoutNode: Codable, Equatable {
    case pane(tabs: [PaneTab], active: Int)
    case split(direction: String, ratio: Double, first: LayoutNode, second: LayoutNode)

    private enum CodingKeys: String, CodingKey {
        case type, tabs, active, dir, ratio, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pane":
            let tabs = (try? container.decode([PaneTab].self, forKey: .tabs)) ?? []
            let requested = (try? container.decode(Int.self, forKey: .active)) ?? 0
            self = .pane(tabs: tabs, active: min(max(0, requested), max(0, tabs.count - 1)))
        case "split":
            let direction = try container.decode(String.self, forKey: .dir)
            let children = try container.decode([LayoutNode].self, forKey: .children)
            guard children.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .children,
                    in: container,
                    debugDescription: "A split layout requires exactly two children"
                )
            }
            let ratio = (try? container.decode(Double.self, forKey: .ratio)) ?? 0.5
            self = .split(
                direction: direction,
                ratio: min(0.95, max(0.05, ratio)),
                first: children[0],
                second: children[1]
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown layout node"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let tabs, let active):
            try container.encode("pane", forKey: .type)
            try container.encode(tabs, forKey: .tabs)
            try container.encode(active, forKey: .active)
        case .split(let direction, let ratio, let first, let second):
            try container.encode("split", forKey: .type)
            try container.encode(direction, forKey: .dir)
            try container.encode(ratio, forKey: .ratio)
            try container.encode([first, second], forKey: .children)
        }
    }
}

struct WorkWindowLayout: Codable, Equatable, Identifiable {
    let id: String
    let layout: LayoutNode
    let activeTabId: String?
}

struct TaskWindowLayout: Codable, Equatable {
    let type: String
    let windows: [WorkWindowLayout]
    let activeWindowId: String?

    private enum CodingKeys: String, CodingKey {
        case type, windows, activeWindowId
    }

    init(windows: [WorkWindowLayout], activeWindowId: String?) {
        type = "windows"
        self.windows = windows
        self.activeWindowId = activeWindowId
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           (try? container.decode(String.self, forKey: .type)) == "windows" {
            type = "windows"
            windows = (try? container.decode([WorkWindowLayout].self, forKey: .windows)) ?? []
            activeWindowId = try? container.decodeIfPresent(String.self, forKey: .activeWindowId)
            return
        }

        // Old servers persisted a single LayoutNode directly.
        let legacy = try LayoutNode(from: decoder)
        type = "windows"
        windows = [WorkWindowLayout(id: "window-legacy", layout: legacy, activeTabId: nil)]
        activeWindowId = "window-legacy"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("windows", forKey: .type)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(activeWindowId, forKey: .activeWindowId)
    }
}

struct Workspace: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let cwd: String
    let defaultProvider: WandProvider?
    let layout: LayoutNode?
    let createdAt: String
    let lastOpenedAt: String?
}

struct WorkspaceSessionSummary: Codable, Equatable, Identifiable {
    let id: String
    let provider: String?
    let sessionKind: String?
    let runner: String?
    let title: String?
    let status: String?
    let cwd: String?
    let startedAt: String?

    init(snapshot: SessionSnapshot) {
        id = snapshot.id
        provider = snapshot.provider
        sessionKind = snapshot.sessionKind
        runner = snapshot.runner
        title = snapshot.title
        status = snapshot.status
        cwd = snapshot.cwd
        startedAt = snapshot.startedAt
    }

    var providerLabel: String {
        guard let provider, !provider.isEmpty else { return "终端" }
        return WandProvider(normalizing: provider).title
    }
}

struct WorkspaceTaskWorktree: Codable, Equatable {
    let branch: String
    let path: String
    let baseRef: String?
    let repoRoot: String?
}

struct WorkspaceTask: Codable, Equatable, Identifiable {
    let id: String
    let workspaceId: String
    let name: String
    let worktree: WorkspaceTaskWorktree?
    let layout: TaskWindowLayout?
    let status: String
    let createdAt: String
    let lastOpenedAt: String?
}

struct WorkspaceTaskDetail: Codable, Equatable, Identifiable {
    let id: String
    let workspaceId: String
    let name: String
    let worktree: WorkspaceTaskWorktree?
    let layout: TaskWindowLayout?
    let status: String
    let createdAt: String
    let lastOpenedAt: String?
    let cwd: String
    let isolated: Bool?
    let worktreeError: String?
    let sessions: [WorkspaceSessionSummary]

    var isIsolated: Bool { isolated ?? (worktree != nil) }

    func replacing(
        layout: TaskWindowLayout?,
        sessions: [WorkspaceSessionSummary]? = nil
    ) -> WorkspaceTaskDetail {
        WorkspaceTaskDetail(
            id: id,
            workspaceId: workspaceId,
            name: name,
            worktree: worktree,
            layout: layout,
            status: status,
            createdAt: createdAt,
            lastOpenedAt: lastOpenedAt,
            cwd: cwd,
            isolated: isolated,
            worktreeError: worktreeError,
            sessions: sessions ?? self.sessions
        )
    }
}
