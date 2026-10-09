import Foundation

struct ContactCandidate: Codable, Equatable {
    var provider = "claude"
    var model = "default"
    var thinkingEffort = "off"
    var mode = "default"
    var kind = "structured"
    var engine: String? = nil

    init() {}
    private enum CodingKeys: String, CodingKey { case provider, model, thinkingEffort, mode, kind, engine }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "default"
        thinkingEffort = try c.decodeIfPresent(String.self, forKey: .thinkingEffort) ?? "off"
        mode = wandBoardNormalizedMode(provider: provider, mode: try c.decodeIfPresent(String.self, forKey: .mode) ?? "default")
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "structured"
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
    }
    var identity: String { [provider, model.trimmingCharacters(in: .whitespacesAndNewlines), thinkingEffort, wandBoardNormalizedMode(provider: provider, mode: mode), kind, provider == "pi" ? engine ?? "cli" : ""].joined(separator: "\u{0}") }
    func body() -> [String: Any] {
        var body: [String: Any] = ["provider": provider, "model": model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "default" : model.trimmingCharacters(in: .whitespacesAndNewlines), "thinkingEffort": thinkingEffort,
         "mode": wandBoardNormalizedMode(provider: provider, mode: mode), "kind": kind]
        if provider == "pi", let engine { body["engine"] = engine }
        return body
    }
}

struct SiliconEmployee: Decodable, Identifiable, Equatable {
    let id: String
    var name: String
    var duty: String
    var prompt: String
    var avatar: String
    var agents: [ContactCandidate]
    let systemKey: String?
    let archivedAt: String?
    let createdAt: String
    var tags: [String]
    var archived: Bool { !(archivedAt ?? "").isEmpty }
    var builtin: Bool { !(systemKey ?? "").isEmpty }
    var displayTags: [String] {
        switch systemKey {
        case "wand-ops": return ["系统用户"]
        case "wand-default": return ["默认用户"]
        default: return tags
        }
    }
    private enum CodingKeys: String, CodingKey { case id, name, duty, prompt, avatar, agents, systemKey, archivedAt, tags, createdAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        duty = try c.decodeIfPresent(String.self, forKey: .duty) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
        agents = try c.decodeIfPresent([ContactCandidate].self, forKey: .agents) ?? []
        systemKey = try c.decodeIfPresent(String.self, forKey: .systemKey)
        archivedAt = try c.decodeIfPresent(String.self, forKey: .archivedAt)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct EmployeeDraft: Equatable {
    var name = ""
    var duty = ""
    var prompt = ""
    var avatar = ""
    var agents = [ContactCandidate()]
    var tagInput = ""
    init() {}
    init(_ employee: SiliconEmployee) {
        name = employee.name; duty = employee.duty; prompt = employee.prompt
        avatar = employee.avatar; agents = employee.agents
        tagInput = employee.displayTags.joined(separator: "，")
    }
    var tags: [String] {
        var seen = Set<String>()
        return tagInput.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    func validationError(builtin: Bool) -> String? {
        if !builtin {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写员工名字。" }
            if name.utf16.count > 40 { return "员工名字不能超过40个字符。" }
            if duty.utf16.count > 2000 || prompt.utf16.count > 20_000 { return "职责或角色设定过长。" }
            if tags.count > 8 || tags.contains(where: { $0.utf16.count > 20 }) { return "最多8个标签，每个最多20个字符。" }
            if tags.contains(where: { ["系统用户", "默认用户"].contains($0) }) { return "内置标签不能由普通员工使用。" }
            if tags.contains(where: { $0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }) { return "标签不能包含控制字符。" }
        }
        return contactCandidateError(agents)
    }
    func body(builtin: Bool) -> [String: Any] {
        let candidates = agents.map { $0.body() }
        if builtin { return ["agents": candidates] }
        return ["name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                "duty": duty.trimmingCharacters(in: .whitespacesAndNewlines),
                "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                "avatar": avatar, "tags": tags, "agents": candidates]
    }
}

func contactCandidateError(_ agents: [ContactCandidate]) -> String? {
    if agents.isEmpty || agents.count > 4 { return "请保留1到4个执行候选。" }
    if agents.contains(where: { $0.engine != nil && (!["cli", "sdk"].contains($0.engine!) || ($0.engine == "sdk" && $0.provider != "pi")) }) { return "执行引擎无效，Wand Agent 只支持 Pi。" }
    if agents.contains(where: { $0.kind != "structured" || WandProvider(rawValue: $0.provider) == nil }) { return "员工只能使用已支持的结构化CLI。" }
    if agents.contains(where: { $0.model.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 128 || !["managed", "full-access", "default"].contains($0.mode) }) { return "候选模型过长或执行模式无效。" }
    if agents.contains(where: { !["off", "standard", "deep", "max"].contains($0.thinkingEffort) &&
        $0.thinkingEffort.range(of: #"^(?:claude|codex|opencode|grok|qoder|pi|gemini):[a-z0-9][a-z0-9_-]{0,31}$"#, options: .regularExpression) == nil }) { return "思考深度无效。" }
    if Set(agents.map(\.identity)).count != agents.count { return "执行候选重复，请调整模型或深度。" }
    return nil
}

struct ContactTeamMember: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var duty: String
    var agents: [ContactCandidate]
    var isLeader: Bool
    var avatar: String
    var role: String?
    var employeeId: String?
    private enum CodingKeys: String, CodingKey { case id, name, duty, agents, agent, isLeader, avatar, role, employeeId }
    init(employee: SiliconEmployee, leader: Bool) {
        id = "m_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(); name = employee.name; duty = ""
        agents = employee.agents; isLeader = leader; avatar = employee.avatar
        role = "any"; employeeId = employee.id
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        duty = try c.decodeIfPresent(String.self, forKey: .duty) ?? ""
        agents = try c.decodeIfPresent([ContactCandidate].self, forKey: .agents) ?? []
        if agents.isEmpty, let single = try c.decodeIfPresent(ContactCandidate.self, forKey: .agent) { agents = [single] }
        isLeader = try c.decodeIfPresent(Bool.self, forKey: .isLeader) ?? false
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role)
        employeeId = try c.decodeIfPresent(String.self, forKey: .employeeId)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(duty, forKey: .duty); try c.encode(agents, forKey: .agents)
        try c.encode(isLeader, forKey: .isLeader); try c.encode(avatar, forKey: .avatar)
        try c.encodeIfPresent(role, forKey: .role)
        // Explicit null is unbinding; omitting this field would preserve an old binding.
        try c.encode(employeeId, forKey: .employeeId)
    }
}

struct ContactTeam: Decodable, Identifiable, Equatable {
    let id: String
    var name: String
    var description: String
    var instructions: String
    var members: [ContactTeamMember]
    var requirePlanApproval: Bool
    var maxSteps: Int
    let createdAt: String
    private enum CodingKeys: String, CodingKey { case id, name, description, instructions, members, requirePlanApproval, maxSteps, createdAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        members = try c.decodeIfPresent([ContactTeamMember].self, forKey: .members) ?? []
        requirePlanApproval = try c.decodeIfPresent(Bool.self, forKey: .requirePlanApproval) ?? true
        maxSteps = try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 30
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct ContactTeamDraft: Equatable {
    var name = ""
    var description = ""
    var instructions = ""
    var members: [ContactTeamMember] = []
    var requirePlanApproval = true
    var maxSteps = 30
    init() {}
    init(_ team: ContactTeam) {
        name = team.name; description = team.description; instructions = team.instructions
        members = team.members; requirePlanApproval = team.requirePlanApproval; maxSteps = team.maxSteps
    }
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf16.count > 60 { return "团队名字不能为空，最多60个字符。" }
        if description.utf16.count > 500 || instructions.utf16.count > 4000 { return "说明或协作指令过长。" }
        if !(2...8).contains(members.count) { return "团队需要2到8位成员。" }
        if members.filter(\.isLeader).count != 1 { return "请选择唯一负责人。" }
        if !(5...200).contains(maxSteps) { return "步数上限须为5到200。" }
        if Set(members.map(\.id)).count != members.count { return "成员身份重复。" }
        if Set(members.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count != members.count { return "成员名字不能重复。" }
        let employeeIDs = members.compactMap(\.employeeId).filter { !$0.isEmpty }
        if Set(employeeIDs).count != employeeIDs.count { return "同一员工不能重复加入团队。" }
        for member in members {
            if member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || member.name.utf16.count > 40 || member.duty.utf16.count > 2000 { return "成员名字或分工无效。" }
            if let error = contactCandidateError(member.agents) { return error }
        }
        return nil
    }
    func body() throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(members)
        return ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "description": description,
                "instructions": instructions, "members": try JSONSerialization.jsonObject(with: encoded),
                "requirePlanApproval": requirePlanApproval, "maxSteps": maxSteps]
    }
}

func contactMatches(_ query: String, fields: [String]) -> Bool {
    query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
        fields.contains { $0.range(of: String(term), options: .caseInsensitive) != nil }
    }
}

struct ContactConversationBinding: Equatable {
    let cwd: String
    let workspaceId: String?
}

func contactProjectCandidates(_ workspaces: [Workspace]) -> [Workspace] {
    workspaces.filter { $0.id != "wand-global" && !$0.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
}

func contactConversationBinding(defaultCwd: String?, workspaces: [Workspace]) -> ContactConversationBinding? {
    let preferred = (defaultCwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let cwd = preferred.isEmpty ? contactProjectCandidates(workspaces).first?.cwd : preferred else { return nil }
    func normalized(_ path: String) -> String {
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean == "/" ? clean : String(clean.reversed().drop(while: { $0 == "/" }).reversed())
    }
    let project = workspaces.first { $0.id != "wand-global" && normalized($0.cwd) == normalized(cwd) }
    return ContactConversationBinding(cwd: cwd, workspaceId: project?.id)
}

func employeeConversationBody(employeeId: String, binding: ContactConversationBinding) -> [String: Any] {
    var body: [String: Any] = ["employeeId": employeeId, "cwd": binding.cwd]
    if let workspaceId = binding.workspaceId { body["workspaceId"] = workspaceId }
    // No initial input, old task/worktree, explicit CLI or system prompt: the server owns identity.
    return body
}

struct EmployeeKnowledgeEntry: Decodable, Identifiable {
    let id: String
    let employeeId: String
    let content: String
    let createdAt: String
}
struct EmployeeKnowledgePage: Decodable {
    let employeeId: String
    let entries: [EmployeeKnowledgeEntry]
    let total: Int
    let maxEntries: Int
}

struct ContactTeamRun: Decodable, Identifiable {
    let id: String
    let teamId: String
    let team: ContactTeam?
    let taskId: String
    let status: String
    let statusDetail: String?
    let updatedAt: String
    let cwd: String?
    let chatSessionId: String?
    let objective: String?
    let stepsUsed: Int?
    let stepLimit: Int?
    let taskTitle: String?
    var roundNumber: Int? = nil
    var conversationId: String? = nil
}
struct ContactTeamInfo: Decodable {
    let team: ContactTeam
    let runs: [ContactTeamRun]
}
struct ContactTeamStep: Decodable, Identifiable {
    let id: String
    let seq: Int
    let kind: String
    let memberId: String
    let title: String
    let status: String
    let sessionId: String?
    let dependsOn: [String]?
    let report: String?
}
struct ContactChatAuthor: Decodable {
    let id: String
    let name: String
    let sessionId: String?
    let avatar: String?
    let leader: Bool?
    let provider: String?
    let model: String?
    let thinkingEffort: String?
}
struct ContactReportFile: Decodable {
    struct Preview: Decodable { let title: String; let excerpt: String }
    let stepId: String
    let path: String
    let name: String
    let size: Int
    let preview: Preview?
}
struct ContactChatTurn: Decodable {
    let role: String
    let content: [ContentBlock]
    let author: ContactChatAuthor?
    let reportFile: ContactReportFile?
    let createdAt: String?
    let notice: Bool?
    var text: String {
        content.compactMap { if case .text(let text, _) = $0 { return text }; return nil }.joined(separator: "\n")
    }
}
struct ContactRunDetail: Decodable {
    let run: ContactTeamRun
    let steps: [ContactTeamStep]
    let chatTurns: [ContactChatTurn]?
    let displayTeam: ContactTeam?
    var chatTitle: String?
    var chatTitleUpdatedAt: String?
    var delivery: ContactDeliverySummary?
    let memberStates: [String: String]
    private enum CodingKeys: String, CodingKey { case run, steps, chatTurns, displayTeam, chatTitle, chatTitleUpdatedAt, delivery, memberStates }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decode(ContactTeamRun.self, forKey: .run)
        steps = try c.decodeIfPresent([ContactTeamStep].self, forKey: .steps) ?? []
        chatTurns = try c.decodeIfPresent([ContactChatTurn].self, forKey: .chatTurns)
        displayTeam = try c.decodeIfPresent(ContactTeam.self, forKey: .displayTeam)
        chatTitle = try c.decodeIfPresent(String.self, forKey: .chatTitle)
        chatTitleUpdatedAt = try c.decodeIfPresent(String.self, forKey: .chatTitleUpdatedAt)
        memberStates = (try? c.decode([String: String].self, forKey: .memberStates)) ?? [:]
        // A malformed optional projection cannot hide the original group chat.
        delivery = try? c.decode(ContactDeliverySummary.self, forKey: .delivery)
        if let projection = delivery {
            if projection.runId != run.id || contactTimestamp(projection.updatedAt) == nil ||
                projection.files.contains(where: { $0.stepId != $0.file.stepId }) { delivery = nil }
        }
    }
    var presentationTeam: ContactTeam? { displayTeam ?? run.team }
    var title: String { chatTitle?.isEmpty == false ? chatTitle! : "任务处理群" }
}

func contactNavigationPath(parents: [String], selection: String?) -> [String] {
    parents + (selection.flatMap { parents.last == $0 ? nil : [$0] } ?? [])
}

func contactRunStatus(_ status: String) -> String {
    ["running": "进行中", "awaiting_approval": "等你批准计划", "waiting_user": "等你回复",
     "done": "已完成", "failed": "失败", "stopped": "已停止", "queued": "排队", "skipped": "已跳过"][status] ?? status
}


func contactOrderedEmployees(_ employees: [SiliconEmployee]) -> [SiliconEmployee] {
    employees.sorted { (contactTimeKey($0.createdAt), $0.id) < (contactTimeKey($1.createdAt), $1.id) }
}
func contactOrderedTeams(_ teams: [ContactTeam]) -> [ContactTeam] {
    teams.sorted { (contactTimeKey($0.createdAt), $0.id) < (contactTimeKey($1.createdAt), $1.id) }
}
private func contactTimeKey(_ value: String) -> String {
    let time = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return time.isEmpty ? "\u{FFFF}" : time
}

func contactEmployeeInviteError(_ employee: SiliconEmployee, members: [ContactTeamMember], replacingID: String?) -> String? {
    if employee.archived { return "员工已归档" }
    if employee.agents.isEmpty { return "员工没有执行候选" }
    if members.contains(where: { $0.id != replacingID && $0.employeeId == employee.id }) { return "已在团队中" }
    if members.contains(where: { $0.id != replacingID && $0.name.lowercased() == employee.name.lowercased() }) { return "团队已有同名成员" }
    return nil
}

struct ContactDeliveryFile: Decodable, Identifiable {
    let stepId: String
    let seq: Int
    let title: String
    let memberId: String
    let memberName: String
    let file: ContactReportFile
    var id: String { stepId + "\u{0}" + file.path }
}
struct ContactDeliveryHandoff: Decodable, Identifiable {
    let stepId: String
    let seq: Int
    let title: String
    let memberId: String
    let memberName: String
    let status: String
    let state: String?
    let sessionId: String?
    let waitingFor: [String]
    var id: String { stepId }
}
struct ContactDeliveryAttention: Decodable { let kind: String; let message: String }
struct ContactDeliverySummary: Decodable {
    let runId: String
    let updatedAt: String
    let headline: String
    let conclusion: String?
    let files: [ContactDeliveryFile]
    let totalFiles: Int
    let handoffs: [ContactDeliveryHandoff]
    let totalHandoffs: Int
    let attention: ContactDeliveryAttention?
}
struct ContactLiveStep: Decodable, Identifiable {
    let stepId: String
    let seq: Int
    let memberId: String
    let memberName: String
    let provider: String
    let model: String?
    let thinkingEffort: String?
    let sessionId: String
    let state: String
    let text: String
    let omittedChars: Int
    let updatedAt: String
    var id: String { stepId }
}
struct ContactLiveUpdate: Decodable { let runId: String; let steps: [ContactLiveStep] }

func contactMemberName(_ detail: ContactRunDetail, id: String, recorded: String) -> String {
    detail.presentationTeam?.members.first { $0.id == id }?.name ?? (recorded.isEmpty ? "成员" : recorded)
}
func contactActivityLabel(_ state: String) -> String {
    ["working": "正在处理", "needs_input": "等你回答", "needs_permission": "等待授权", "done": "已完成", "failed": "失败"][state] ?? contactRunStatus(state)
}
func contactReportPath(_ file: ContactReportFile, cwd: String?) -> String? {
    if file.path.hasPrefix("/") { return file.path }
    guard let cwd, !cwd.isEmpty else { return nil }
    return cwd + "/" + file.path
}

/// A request receipt and a polling GET share one source, including title's separate revision.
func mergeContactRunDetail(previous: ContactRunDetail?, incoming: ContactRunDetail, expectedRunID: String) -> ContactRunDetail? {
    guard incoming.run.id == expectedRunID else { return previous?.run.id == expectedRunID ? previous : nil }
    guard let old = previous, old.run.id == expectedRunID,
          old.run.taskId == incoming.run.taskId, old.run.chatSessionId == incoming.run.chatSessionId else { return incoming }
    var next = incoming
    // Renaming the task does not bump run.updatedAt.
    if let oldTitleTime = old.chatTitleUpdatedAt, !oldTitleTime.isEmpty,
       (incoming.chatTitleUpdatedAt ?? "") < oldTitleTime {
        next.chatTitle = old.chatTitle; next.chatTitleUpdatedAt = oldTitleTime
    }
    var retained = old
    if (incoming.chatTitleUpdatedAt ?? "") > (old.chatTitleUpdatedAt ?? "") {
        retained.chatTitle = incoming.chatTitle; retained.chatTitleUpdatedAt = incoming.chatTitleUpdatedAt
    }
    if incoming.run.updatedAt < old.run.updatedAt { return retained }
    if incoming.run.updatedAt == old.run.updatedAt {
        let terminal = ["done", "failed", "stopped"]
        let stepRegression = old.steps.contains { oldStep in
            ["done", "failed", "skipped"].contains(oldStep.status) && incoming.steps.contains {
                $0.id == oldStep.id && ["queued", "running"].contains($0.status)
            }
        }
        if (incoming.run.stepsUsed ?? 0) < (old.run.stepsUsed ?? 0) ||
            (terminal.contains(old.run.status) && incoming.run.status == "running") || stepRegression { return retained }
    }
    guard let oldDelivery = old.delivery else { return next }
    guard let delivery = next.delivery else {
        if incoming.run.updatedAt <= old.run.updatedAt { next.delivery = oldDelivery }
        return next
    }
    let dropsFrozenFiles = delivery.totalFiles < oldDelivery.totalFiles || oldDelivery.files.contains { frozen in
        guard let file = delivery.files.first(where: { $0.stepId == frozen.stepId && $0.file.path == frozen.file.path }) else { return true }
        if let preview = frozen.file.preview {
            return file.file.preview == nil || (!preview.excerpt.isEmpty && file.file.preview?.excerpt.isEmpty != false)
        }
        return false
    }
    if delivery.updatedAt < oldDelivery.updatedAt || (delivery.updatedAt == oldDelivery.updatedAt && dropsFrozenFiles) {
        next.delivery = oldDelivery
    }
    return next
}

private func contactTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}


struct ContactExecutionSubject: Codable, Equatable, Hashable {
    let type: String
    let id: String
    var isCLI: Bool { type == "cli" }
    func jsonObject() -> [String: Any] { ["type": type, "id": id] }
}

func contactEmployeeSessionBody(employeeID: String, cwd: String, workspaceID: String? = nil,
                                workspaceTaskID: String? = nil, prompt: String? = nil) -> [String: Any] {
    var body: [String: Any] = ["employeeId": employeeID, "cwd": cwd]
    if let workspaceID, !workspaceID.isEmpty { body["workspaceId"] = workspaceID }
    if let workspaceTaskID, !workspaceTaskID.isEmpty { body["workspaceTaskId"] = workspaceTaskID }
    if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
        body["prompt"] = prompt; body["respondImmediately"] = true
    }
    return body
}

func contactTaskSubjectBody(subject: ContactExecutionSubject, prompt: String) -> [String: Any] {
    ["subject": subject.jsonObject(), "kind": "structured", "prompt": prompt]
}


func contactCreationNeedsReview(attempted: Bool, accepted: Bool = false, error: Error) -> Bool {
    attempted && !accepted && !isDefiniteInputRejection(error)
}
