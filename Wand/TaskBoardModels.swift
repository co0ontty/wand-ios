import Foundation

struct WandBoardTaskAgent: Codable, Equatable {
    var provider: String
    var model: String
    var thinkingEffort: String
    /// 派发时的执行模式：托管 / 全权限 / 标准。
    var mode: String

    enum CodingKeys: String, CodingKey {
        case provider, model, thinkingEffort, mode
    }

    init(provider: String, model: String, thinkingEffort: String, mode: String = "default") {
        self.provider = provider
        self.model = model
        self.thinkingEffort = thinkingEffort
        self.mode = wandBoardNormalizedMode(provider: provider, mode: mode)
    }

    static let `default` = WandBoardTaskAgent(provider: "claude", model: "default", thinkingEffort: "off")

    /// mode 是后加字段：老服务端不返回时按 provider 支持范围读默认值，不整条配置解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: (try? container.decode(String.self, forKey: .provider)) ?? "claude",
            model: (try? container.decode(String.self, forKey: .model)) ?? "default",
            thinkingEffort: (try? container.decode(String.self, forKey: .thinkingEffort)) ?? "off",
            mode: (try? container.decode(String.self, forKey: .mode)) ?? "default"
        )
    }

    func jsonObject() -> [String: Any] {
        ["provider": provider, "model": model, "thinkingEffort": thinkingEffort, "mode": mode]
    }
}

struct WandBoardWorkspace: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let cwd: String
}

struct WandBoardMilestone: Codable, Equatable, Identifiable {
    let id: String
    let name: String
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
        case milestone, workspaceTaskId
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
    /// 卡片上的里程碑芯片；服务端 DTO 已解好名字。
    let milestone: WandBoardMilestone?
    /// 侧栏任务 ID：卡片与会话树共用同一套任务分组，打开会话时要带回真实工作区/任务上下文。
    let workspaceTaskId: String?

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
        milestone = try? container.decodeIfPresent(WandBoardMilestone.self, forKey: .milestone)
        let rawWorkspaceTaskId = (try? container.decodeIfPresent(String.self, forKey: .workspaceTaskId)) ?? nil
        workspaceTaskId = (rawWorkspaceTaskId?.isEmpty == false) ? rawWorkspaceTaskId : nil
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
/// 任务派发允许的执行模式；顺序即下拉顺序。
let wandBoardModes = ["managed", "full-access", "default"]

/// Codex 只有 full-access 一个有效值，其余 provider 支持三种。
func wandBoardSupportedModes(_ provider: String) -> [String] {
    provider == "codex" ? ["full-access"] : wandBoardModes
}

/// 把任意（含旧数据 / 其它客户端缺省的）模式夹到该 provider 真正支持的值。
func wandBoardNormalizedMode(provider: String, mode: String) -> String {
    let supported = wandBoardSupportedModes(provider)
    let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
    if supported.contains(trimmed) { return trimmed }
    return supported.contains("default") ? "default" : (supported.first ?? "default")
}

func wandBoardModeLabel(_ mode: String) -> String {
    switch mode {
    case "managed": return "托管"
    case "full-access": return "全权限"
    default: return "标准"
    }
}

/// 已指派 Agent 的分组标题：provider · 模型 · 运行模式。
func wandBoardAgentTitle(_ provider: String, _ agent: WandBoardTaskAgent?) -> String {
    guard let agent else { return wandBoardProviderLabel(provider) }
    let model = agent.model == "default" ? "默认模型" : agent.model
    return "\(wandBoardProviderLabel(provider)) · \(model) · \(wandBoardModeLabel(agent.mode))"
}

func wandBoardProviderLabel(_ provider: String) -> String {
    switch provider {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    case "grok": return "Grok"
    case "qoder": return "Qoder"
    case "pi": return "Pi"
    // 空白终端与老服务端的会话类型也是卡片上的“provider”，不能原样把 shell 当工具名印出来。
    case "shell", "session": return "终端"
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
    /// 返回归一化后的分组键：空 provider（PTY / 老服务端会话）统一归到 "session"。
    /// 调用方必须用返回值当字典键，否则会话会被挂到空串桶里，界面看到的是「尚无关联会话」。
    @discardableResult
    func ensure(_ provider: String, _ agent: WandBoardTaskAgent?) -> String {
        let key = provider.isEmpty ? "session" : provider
        if !providers.contains(key) {
            providers.append(key)
            grouped[key] = []
        }
        if agents[key] == nil, let agent {
            agents[key] = agent
        }
        return key
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
        let key = ensure(agent?.provider ?? session.provider, agent)
        grouped[key, default: []].append(session)
    }
    return providers.map { key in
        WandBoardAgentGroup(provider: key, agent: agents[key], sessions: grouped[key] ?? [])
    }
}

let wandUnnamedTaskName = "未命名任务"

/// 划开看板卡后露出的动作条宽度。
///
/// Android 用 76.dp；iOS 再放宽一点，因为按钮上还要放图标 + 文字，而且划开期间
/// 右下角悬浮的「新建任务」会让位，动作条越宽越好点。
let wandBoardSwipeActionWidth: CGFloat = 104

/// 松手时按速度判定「划开 / 收起」的最小速度（pt/s，对齐 Android `BOARD_TASK_SWIPE_OPEN_VELOCITY`）。
let wandBoardSwipeOpenVelocity: CGFloat = 480

/// SwiftUI 的手势只给「惯性预测终点」，按这个时间视界折回速度，
/// 再交给 `wandBoardSwipeShouldReveal` 判定，保证与 Android 同一套规则。
let wandBoardSwipeVelocityHorizon: CGFloat = 0.25

enum WandBoardSwipeAction: String, Identifiable {
    case start, complete, archive
    var id: String { rawValue }
}

/// 松手后是否停在「已划开」状态：速度优先，速度过小才看位移过半。
///
/// 动作按钮露在右侧，所以划开方向是从右往左：位移为负、速度为负。
/// 与 Android `boardTaskSwipeShouldReveal` 同一套规则。
func wandBoardSwipeShouldReveal(offset: CGFloat, revealWidth: CGFloat, velocity: CGFloat) -> Bool {
    if revealWidth <= 0 { return false }
    if velocity <= -wandBoardSwipeOpenVelocity { return true }
    if velocity >= wandBoardSwipeOpenVelocity { return false }
    return offset <= -revealWidth / 2
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

// MARK: - 任务卡展示模型

/// 卡片一行里最多画几个会话 / 标签；多出来的折成「+N」，长任务不会把卡片撑成一面墙。
let wandBoardCardSessionLimit = 3
let wandBoardCardLabelLimit = 2

/// 卡片上的会话行：标题优先，没标题就退回工具名。
struct WandBoardTaskSessionCard: Equatable, Identifiable {
    let id: String
    let provider: String
    let label: String
    let running: Bool
    let isStructured: Bool
}

/// 卡片上的截止日期：已过期时交给 UI 换成警示语义色。
struct WandBoardTaskDue: Equatable {
    let label: String
    let overdue: Bool
}

struct WandBoardTaskCardModel: Equatable {
    let title: String
    /// 任务编号（WAND-12），卡片右上角等宽小字；服务端没给编号时为 nil。
    let identifier: String?
    /// 没有会话也没有指派时补一行描述摘要，避免卡片只剩一个标题。
    let body: String?
    let workspaceName: String?
    /// 里程碑名字；未归属里程碑时为 nil。
    let milestoneName: String?
    let priority: String?
    let agentLabel: String?
    let labels: [String]
    let extraLabelCount: Int
    let due: WandBoardTaskDue?
    let processingLabel: String?
    let running: Bool
    let sessions: [WandBoardTaskSessionCard]
    let extraSessionCount: Int

    var hasChips: Bool {
        workspaceName != nil || milestoneName != nil || priority != nil || agentLabel != nil
            || !labels.isEmpty || extraLabelCount > 0 || due != nil
    }
}

func wandBoardCardModel(
    _ task: WandBoardTask,
    showWorkspace: Bool,
    today: String = wandBoardTodayIso()
) -> WandBoardTaskCardModel {
    let workspaceName = (task.workspace?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let milestoneName = (task.milestone?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let labels = task.labels.filter { !$0.isEmpty }
    let identifier = task.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    return WandBoardTaskCardModel(
        title: wandBoardCardTitle(task),
        identifier: identifier.isEmpty ? nil : identifier,
        body: wandBoardCardBody(task),
        workspaceName: (showWorkspace && !workspaceName.isEmpty) ? workspaceName : nil,
        milestoneName: milestoneName.isEmpty ? nil : milestoneName,
        priority: (task.priority.isEmpty || task.priority == "none") ? nil : task.priority,
        agentLabel: wandBoardAgentLabels(sessions: task.sessions, assigned: task.agent),
        labels: Array(labels.prefix(wandBoardCardLabelLimit)),
        extraLabelCount: max(0, labels.count - wandBoardCardLabelLimit),
        due: wandBoardCardDue(task.dueDate, status: task.status, today: today),
        processingLabel: wandBoardProcessingLabel(task),
        running: wandBoardAgentRunning(task),
        sessions: wandBoardCardSessions(task.sessions),
        extraSessionCount: max(0, task.sessions.count - wandBoardCardSessionLimit)
    )
}

/// 会话行按服务端顺序取前几条；标题缺失时用工具名占位，不出现空行。
func wandBoardCardSessions(
    _ sessions: [WandBoardTaskSession],
    limit: Int = wandBoardCardSessionLimit
) -> [WandBoardTaskSessionCard] {
    sessions.prefix(limit).map { session in
        WandBoardTaskSessionCard(
            id: session.id,
            provider: session.provider,
            label: wandBoardSessionCardLabel(session),
            running: wandBoardSessionRunning(session.status),
            isStructured: session.isStructured
        )
    }
}

/// 会话标题；与工具名重复（或为空）时退回工具名，避免一行里出现两次「Claude」。
func wandBoardSessionCardLabel(_ session: WandBoardTaskSession) -> String {
    let provider = wandBoardProviderLabel(session.provider)
    let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty || title.caseInsensitiveCompare(provider) == .orderedSame { return provider }
    return title
}

///
/// 没有会话也没有指派时的描述摘要：
/// 取描述里前两行有内容的正文（跳过同步写进去的「项目 / 目录 / 分支」行），
/// 与标题重复的那行丢掉——自动标题本来就是从这行生成的。
func wandBoardCardBody(_ task: WandBoardTask) -> String? {
    guard task.sessions.isEmpty, task.agent == nil else { return nil }
    let title = wandBoardCardTitle(task)
    let lines = task.description
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !wandBoardIsSyncedWorkspaceLine($0) }
        .filter { $0.caseInsensitiveCompare(title) != .orderedSame }
        .prefix(2)
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

/// 截止日期标签：M/D（对齐 Web 的 issueDueStamp），过期时前面加「逾期」，不只靠颜色表示。
func wandBoardCardDue(
    _ dueDate: String?,
    status: String,
    today: String = wandBoardTodayIso()
) -> WandBoardTaskDue? {
    let value = (dueDate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard wandBoardDatePattern.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
    ) != nil else { return nil }
    let overdue = wandBoardIsOverdue(value, status: status, today: today)
    let month = Int(value.dropFirst(5).prefix(2)) ?? 0
    let day = Int(value.dropFirst(8).prefix(2)) ?? 0
    return WandBoardTaskDue(
        label: overdue ? "逾期 · \(month)/\(day)" : "\(month)/\(day)",
        overdue: overdue
    )
}

/// 已关闭的任务不再算逾期：做完/归档之后日期只剩记录意义。
func wandBoardIsOverdue(_ dueDate: String, status: String, today: String = wandBoardTodayIso()) -> Bool {
    status != "done" && status != "archived" && dueDate < today
}

/// 本机今天的 ISO 日期（与 Web 的 isoDate(new Date()) 同为浏览器/设备本地时区）。
func wandBoardTodayIso(now: Date = Date()) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
    return String(
        format: "%04d-%02d-%02d",
        parts.year ?? 0,
        parts.month ?? 0,
        parts.day ?? 0
    )
}

private let wandBoardDatePattern = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")

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
