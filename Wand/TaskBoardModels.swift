import Foundation

struct WandBoardTaskAgent: Codable, Equatable {
    var provider: String
    var model: String
    var thinkingEffort: String

    static let `default` = WandBoardTaskAgent(provider: "claude", model: "default", thinkingEffort: "off")

    func jsonObject() -> [String: Any] {
        ["provider": provider, "model": model, "thinkingEffort": thinkingEffort]
    }
}

struct WandBoardWorkspace: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let cwd: String
}

struct WandBoardTaskSession: Codable, Equatable, Identifiable {
    let id: String
    let provider: String
    let sessionKind: String
    let title: String
    let status: String
    let cwd: String
    let model: String
    let thinkingEffort: String

    var isStructured: Bool { sessionKind != "pty" && sessionKind != "shell" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = (try? container.decode(String.self, forKey: .provider)) ?? ""
        sessionKind = (try? container.decode(String.self, forKey: .sessionKind)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? id
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
        cwd = (try? container.decode(String.self, forKey: .cwd)) ?? ""
        model = (try? container.decode(String.self, forKey: .model)) ?? ""
        thinkingEffort = (try? container.decode(String.self, forKey: .thinkingEffort)) ?? "off"
    }
}

struct WandBoardDispatchResult: Decodable {
    let ok: Bool
    let taskId: String
    let sessionId: String
    let provider: String
    let cwd: String

    private struct Session: Decodable {
        let id: String?
        let provider: String?
        let cwd: String?
    }

    private enum CodingKeys: String, CodingKey { case ok, taskId, session }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decode(Bool.self, forKey: .ok)) ?? true
        taskId = (try? container.decode(String.self, forKey: .taskId)) ?? ""
        let session = try? container.decode(Session.self, forKey: .session)
        sessionId = session?.id ?? ""
        provider = session?.provider ?? ""
        cwd = session?.cwd ?? ""
    }
}

struct WandBoardTask: Decodable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id, workspaceId, identifier, title, titleSource
        case taskDescription = "description"
        case status, priority, labels, dueDate
        case sortOrder, agent, createdAt, updatedAt, sessionIds, sessions, workspace
    }

    let id: String
    let workspaceId: String?
    let identifier: String
    let title: String
    /// "auto" = 标题由服务端按描述自动生成；老服务端不返回时按用户手写处理。
    let titleSource: String
    let description: String
    let status: String
    let priority: String
    let labels: [String]
    let dueDate: String?
    let sortOrder: Int
    let agent: WandBoardTaskAgent?
    let createdAt: String
    let updatedAt: String
    let sessionIds: [String]
    let sessions: [WandBoardTaskSession]
    let workspace: WandBoardWorkspace?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceId = try? container.decodeIfPresent(String.self, forKey: .workspaceId)
        identifier = (try? container.decode(String.self, forKey: .identifier)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? "任务"
        titleSource = (try? container.decode(String.self, forKey: .titleSource)) ?? "user"
        description = (try? container.decode(String.self, forKey: .taskDescription)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? "todo"
        priority = (try? container.decode(String.self, forKey: .priority)) ?? "none"
        labels = (try? container.decode([String].self, forKey: .labels)) ?? []
        dueDate = try? container.decodeIfPresent(String.self, forKey: .dueDate)
        sortOrder = (try? container.decode(Int.self, forKey: .sortOrder)) ?? 0
        agent = try? container.decodeIfPresent(WandBoardTaskAgent.self, forKey: .agent)
        createdAt = (try? container.decode(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? container.decode(String.self, forKey: .updatedAt)) ?? ""
        sessionIds = (try? container.decode([String].self, forKey: .sessionIds)) ?? []
        sessions = (try? container.decode([WandBoardTaskSession].self, forKey: .sessions)) ?? []
        workspace = try? container.decodeIfPresent(WandBoardWorkspace.self, forKey: .workspace)
    }
}

enum WandBoardStatus: String, CaseIterable, Identifiable {
    case todo, doing, done
    var id: String { rawValue }
    var label: String {
        switch self {
        case .todo: return "待办"
        case .doing: return "进行中"
        case .done: return "已完成"
        }
    }
    var empty: String {
        switch self {
        case .todo: return "还没有待办任务"
        case .doing: return "暂无进行中的任务"
        case .done: return "还没有完成的任务"
        }
    }
}

enum WandBoardPriority: String, CaseIterable, Identifiable {
    case none, urgent, high, medium, low
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "无优先级"
        case .urgent: return "紧急"
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }
}

let wandBoardProviders = ["claude", "codex", "opencode", "grok", "qoder", "pi"]
let wandBoardEfforts = ["off", "standard", "deep", "max"]

func wandBoardProviderLabel(_ provider: String) -> String {
    switch provider {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    case "grok": return "Grok"
    case "qoder": return "Qoder"
    case "pi": return "Pi"
    default: return provider.isEmpty ? "Agent" : provider
    }
}

func wandBoardEffortLabel(_ effort: String) -> String {
    switch effort {
    case "standard": return "标准"
    case "deep": return "深入"
    case "max": return "最大"
    default: return "关闭"
    }
}

func wandBoardModelOptions(from catalog: ModelsResponse?, provider: String) -> [(id: String, label: String)] {
    let models = catalog?.models(for: provider) ?? []
    let mapped = models.map { (id: $0.id, label: $0.label.isEmpty ? $0.id : $0.label) }
    if mapped.contains(where: { $0.id == "default" }) { return mapped }
    let fallback = catalog?.defaultModelId(for: provider) ?? ""
    let defaultLabel = fallback.isEmpty ? "跟随服务端默认" : "跟随服务端默认（\(fallback)）"
    return [(id: "default", label: defaultLabel)] + mapped
}

struct WandBoardAgentGroup: Identifiable, Equatable {
    var id: String { provider }
    let provider: String
    let agent: WandBoardTaskAgent?
    let sessions: [WandBoardTaskSession]
}

func wandBoardSessionGroups(
    sessions: [WandBoardTaskSession],
    assigned: WandBoardTaskAgent?
) -> [WandBoardAgentGroup] {
    var providers: [String] = []
    var agents: [String: WandBoardTaskAgent] = [:]
    var grouped: [String: [WandBoardTaskSession]] = [:]
    func ensure(_ provider: String, _ agent: WandBoardTaskAgent?) {
        let key = provider.isEmpty ? "session" : provider
        if !providers.contains(key) {
            providers.append(key)
            grouped[key] = []
        }
        if agents[key] == nil, let agent {
            agents[key] = agent
        }
    }
    if let assigned, wandBoardProviders.contains(assigned.provider) {
        ensure(assigned.provider, assigned)
    }
    for session in sessions {
        let agent = wandBoardProviders.contains(session.provider)
            ? WandBoardTaskAgent(
                provider: session.provider,
                model: session.model.isEmpty ? "default" : session.model,
                thinkingEffort: session.thinkingEffort.isEmpty ? "off" : session.thinkingEffort
            )
            : nil
        let key = (agent?.provider ?? session.provider)
        ensure(key, agent)
        grouped[key, default: []].append(session)
    }
    return providers.map { key in
        WandBoardAgentGroup(provider: key, agent: agents[key], sessions: grouped[key] ?? [])
    }
}

let wandUnnamedTaskName = "未命名任务"

enum WandBoardSwipeAction: String, Identifiable {
    case start, complete, archive
    var id: String { rawValue }
}

func wandBoardSwipeAction(for status: String) -> WandBoardSwipeAction? {
    switch status {
    case "todo": return .start
    case "doing": return .complete
    case "done": return .archive
    default: return nil
    }
}

func wandBoardSwipeActionLabel(_ action: WandBoardSwipeAction) -> String {
    switch action {
    case .start: return "开始"
    case .complete: return "完成"
    case .archive: return "归档"
    }
}

func wandBoardSwipeActionTitle(_ action: WandBoardSwipeAction) -> String {
    switch action {
    case .start: return "开始任务？"
    case .complete: return "确认完成？"
    case .archive: return "归档任务？"
    }
}

func wandBoardSwipeConfirmMessage(_ action: WandBoardSwipeAction) -> String {
    switch action {
    case .start: return "任务将标记为进行中。"
    case .complete: return "任务将标记为已完成。"
    case .archive: return "任务将移入归档，之后仍可在「归档」中找回。"
    }
}

func wandBoardSwipeTargetStatus(_ action: WandBoardSwipeAction) -> String? {
    switch action {
    case .start: return "doing"
    case .complete: return "done"
    case .archive: return nil
    }
}

func wandBoardSwipeSystemImage(_ action: WandBoardSwipeAction) -> String {
    switch action {
    case .start: return "play.fill"
    case .complete: return "checkmark"
    case .archive: return "archivebox"
    }
}

func wandBoardToggledStatus(_ status: String) -> String {
    (status == "done" || status == "archived") ? "todo" : "done"
}

func wandBoardSessionRunning(_ status: String) -> Bool { status == "running" }

func wandBoardSessionFinished(_ status: String) -> Bool {
    status == "exited" || status == "idle"
}

func wandBoardCardTitle(_ task: WandBoardTask) -> String {
    let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty { return title }
    let fromDescription = task.description.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty && !wandBoardIsSyncedWorkspaceLine($0) }
    return fromDescription ?? wandUnnamedTaskName
}

func wandBoardAgentLabels(sessions: [WandBoardTaskSession], assigned: WandBoardTaskAgent?) -> String? {
    let labels = wandBoardSessionGroups(sessions: sessions, assigned: assigned)
        .map { wandBoardProviderLabel($0.provider) }
    return labels.isEmpty ? nil : labels.joined(separator: " · ")
}

func wandBoardProcessingLabel(_ task: WandBoardTask) -> String? {
    guard task.status == "doing" else { return nil }
    let running = task.sessions.contains { wandBoardSessionRunning($0.status) }
    let finished = !task.sessions.isEmpty && task.sessions.allSatisfy { wandBoardSessionFinished($0.status) }
    if running { return "正在处理..." }
    if finished { return "等待验收" }
    if !task.sessions.isEmpty { return "暂停处理" }
    return "等待派发"
}

func wandBoardAgentRunning(_ task: WandBoardTask) -> Bool {
    task.sessions.contains { wandBoardSessionRunning($0.status) }
}

struct WandBoardTaskStats: Equatable {
    var total: Int
    var todo: Int
    var doing: Int
    var done: Int
    var remaining: Int
    var high: Int
}

func wandBoardTaskStats(_ tasks: [WandBoardTask]) -> WandBoardTaskStats {
    var todo = 0
    var doing = 0
    var done = 0
    var high = 0
    for task in tasks {
        switch task.status {
        case "todo": todo += 1
        case "doing": doing += 1
        case "done": done += 1
        default: break
        }
        if task.priority == "high" || task.priority == "urgent" {
            high += 1
        }
    }
    return WandBoardTaskStats(
        total: tasks.count,
        todo: todo,
        doing: doing,
        done: done,
        remaining: todo + doing,
        high: high
    )
}

private func wandBoardIsSyncedWorkspaceLine(_ line: String) -> Bool {
    line.hasPrefix("项目：") || line.hasPrefix("目录：") || line.hasPrefix("分支：")
}
