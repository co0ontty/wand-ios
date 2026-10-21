import Foundation

/// IM instances are navigation/data projections, not another execution/session implementation.
struct ConversationTarget: Codable, Equatable {
    let taskId: String
    let runId: String
    var body: [String: Any] { ["taskId": taskId, "runId": runId] }
}

struct ConversationExecutionPreference: Equatable {
    let provider: String
    let engine: String?
    let model: String
    let thinkingEffort: String

    var body: [String: Any] {
        var result: [String: Any] = [
            "provider": provider,
            "model": model,
            "thinkingEffort": thinkingEffort,
        ]
        if let engine { result["engine"] = engine }
        return result
    }
}

func conversationMessageBody(
    input: String,
    target: ConversationTarget?,
    cwd: String?,
    executionPreference: ConversationExecutionPreference?
) -> [String: Any] {
    var body: [String: Any] = ["input": input, "target": target?.body ?? NSNull()]
    if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
    if target == nil, let executionPreference { body["executionPreference"] = executionPreference.body }
    return body
}

struct ConversationLink: Decodable {
    let conversationId: String
    let taskId: String
    let title: String
}

struct ConversationSessionLink: Decodable {
    let sessionId: String
    let title: String
}

struct ConversationPreview: Decodable {
    let runId: String?
    let status: String
    let text: String
    private enum CodingKeys: String, CodingKey { case runId, status, text }
    init(status: String, text: String, runId: String? = nil) {
        self.status = status; self.text = String(text.suffix(4000)); self.runId = runId
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(status: try c.decodeIfPresent(String.self, forKey: .status) ?? "starting",
                  text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                  runId: try c.decodeIfPresent(String.self, forKey: .runId))
    }
    var label: String {
        switch status {
        case "starting": return "准备中"
        case "running": return "在跑"
        case "awaiting_approval": return "待审批"
        case "waiting_user": return "等你"
        case "done": return "已完成"
        case "failed": return "失败"
        case "stopped": return "已停止"
        case "unavailable": return "不可用"
        default: return status
        }
    }
    var active: Bool { ["starting", "running", "awaiting_approval", "waiting_user"].contains(status) }
}

struct ConversationMessage: Decodable, Identifiable {
    let turn: ConversationTurn
    let messageId: String?
    let requestId: String?
    let conversationTarget: ConversationTarget?
    let conversationLink: ConversationLink?
    let sessionLink: ConversationSessionLink?
    var sessionPreview: ConversationPreview?
    var taskPreview: ConversationPreview?
    let author: Author?
    let notice: Bool?
    let reportFile: ContactReportFile?
    struct Author: Decodable {
        let id: String?
        let name: String?
        let avatar: String?
        let sessionId: String?
        let kind: String?
    }
    private enum CodingKeys: String, CodingKey {
        case messageId, requestId, conversationTarget, conversationLink, sessionLink, sessionPreview, taskPreview, author, notice, reportFile
    }
    init(from decoder: Decoder) throws {
        turn = try ConversationTurn(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decodeIfPresent(String.self, forKey: .messageId)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        conversationTarget = try c.decodeIfPresent(ConversationTarget.self, forKey: .conversationTarget)
        conversationLink = try c.decodeIfPresent(ConversationLink.self, forKey: .conversationLink)
        sessionLink = try c.decodeIfPresent(ConversationSessionLink.self, forKey: .sessionLink)
        sessionPreview = try c.decodeIfPresent(ConversationPreview.self, forKey: .sessionPreview)
        taskPreview = try c.decodeIfPresent(ConversationPreview.self, forKey: .taskPreview)
        author = try c.decodeIfPresent(Author.self, forKey: .author)
        notice = try c.decodeIfPresent(Bool.self, forKey: .notice)
        reportFile = try c.decodeIfPresent(ContactReportFile.self, forKey: .reportFile)
    }
    var id: String { messageId ?? [requestId ?? "", turn.role, turn.createdAt ?? "", sessionLink?.sessionId ?? "", author?.id ?? ""].joined(separator: ":") }
    var taskId: String? { conversationTarget?.taskId ?? conversationLink?.taskId }
    var renderRevision: Int {
        var hash = Hasher(); hash.combine(id)
        hash.combine(sessionPreview?.text); hash.combine(sessionPreview?.status)
        hash.combine(taskPreview?.text); hash.combine(taskPreview?.status)
        for block in turn.content {
            switch block {
            case .text(let text, _): hash.combine(text)
            case .thinking(let text, _, _, _): hash.combine(text)
            case .toolUse(let id, let name, _, let input, _): hash.combine(id); hash.combine(name); hash.combine(input.count)
            case .toolResult(let id, let text, let error, let truncated, _, _, _): hash.combine(id); hash.combine(text); hash.combine(error); hash.combine(truncated)
            case .unknown(let type, let payload): hash.combine(type); hash.combine(payload)
            }
        }
        return hash.finalize()
    }
}

struct ConversationTask: Decodable, Identifiable {
    let task: WandBoardTask
    let runs: [ContactTeamRun]
    let startup: Startup?
    struct Startup: Decodable { let state: String; let error: String? }
    var id: String { task.id }
}

struct ConversationInstance: Decodable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let peerEmployeeId: String?
    let team: ContactTeam?
    let sourceTemplateId: String?
    let memberVersion: Int
    let joinedVersions: [String: Int]
    let sessionId: String?
    let communicationSessionId: String?
    let preview: String
    let messageAt: String
    let unavailableReason: String?
    let memberUnavailableReasons: [String: String]
    let tasks: [ConversationTask]
    var messages: [ConversationMessage]
    let runDetails: [ContactRunDetail]
    let pinnedAt: String?
    let dissolvedAt: String?
    let deleting: Bool
    var history: ConversationHistory? = nil
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, peerEmployeeId, team, sourceTemplateId, memberVersion, joinedVersions,
             sessionId, communicationSessionId, preview, messageAt, unavailableReason, memberUnavailableReasons,
             tasks, messages, runDetails, pinnedAt, dissolvedAt, deleting, history
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        guard ["dm", "group"].contains(kind), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "无效的对话身份")
        }
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "对话"
        peerEmployeeId = try c.decodeIfPresent(String.self, forKey: .peerEmployeeId)
        team = try c.decodeIfPresent(ContactTeam.self, forKey: .team)
        sourceTemplateId = try c.decodeIfPresent(String.self, forKey: .sourceTemplateId)
        memberVersion = try c.decodeIfPresent(Int.self, forKey: .memberVersion) ?? 1
        joinedVersions = try c.decodeIfPresent([String: Int].self, forKey: .joinedVersions) ?? [:]
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        communicationSessionId = try c.decodeIfPresent(String.self, forKey: .communicationSessionId)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        messageAt = try c.decodeIfPresent(String.self, forKey: .messageAt) ?? ""
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
        memberUnavailableReasons = try c.decodeIfPresent([String: String].self, forKey: .memberUnavailableReasons) ?? [:]
        tasks = try c.decodeIfPresent([ConversationTask].self, forKey: .tasks) ?? []
        messages = try c.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? []
        runDetails = try c.decodeIfPresent([ContactRunDetail].self, forKey: .runDetails) ?? []
        pinnedAt = try c.decodeIfPresent(String.self, forKey: .pinnedAt)
        dissolvedAt = try c.decodeIfPresent(String.self, forKey: .dissolvedAt)
        deleting = try c.decodeIfPresent(Bool.self, forKey: .deleting) ?? false
        history = try c.decodeIfPresent(ConversationHistory.self, forKey: .history)
    }
    var leader: ContactTeamMember? { team?.members.first { $0.isLeader } }
    var identityStatus: String {
        if deleting { return "正在删除对话" }
        if dissolvedAt != nil { return "群聊已解散" }
        if unavailableReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return "当前对象暂不可用" }
        let runs = tasks.flatMap(\.runs)
        if runs.contains(where: { $0.status == "awaiting_approval" }) { return "等待你的确认" }
        if runs.contains(where: { $0.status == "waiting_user" }) { return "等待你的回复" }
        if runs.contains(where: { $0.status == "running" || $0.status == "starting" }) { return "任务执行中" }
        if runs.max(by: { $0.updatedAt < $1.updatedAt })?.status == "failed" { return "最近一轮失败" }
        if kind == "group" {
            return team.map { "\($0.members.count) 位员工 · 可派发任务" } ?? "群聊 · 可派发任务"
        }
        return "可以继续对话"
    }
}

struct ConversationReceipt: Decodable {
    let requestId: String
    let state: String
    let conversationId: String
    let taskId: String?
    let runId: String?
    let sessionId: String?
    let error: String?
    let startup: String?
    private enum CodingKeys: String, CodingKey { case requestId, state, conversationId, taskId, runId, sessionId, error, startup }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        state = try c.decode(String.self, forKey: .state)
        guard !requestId.isEmpty, ["pending", "accepted", "rejected"].contains(state) else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "无法确认请求接受状态")
        }
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId) ?? ""
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        startup = try c.decodeIfPresent(String.self, forKey: .startup)
    }
}

struct ConversationSessionUpdate: Decodable {
    let conversationId: String
    let sessionId: String
    let preview: ConversationPreview
}

struct ConversationUnconfirmed: LocalizedError {
    let requestId: String
    var errorDescription: String? { "送达未确认，请先核对记录，勿重复提交。" }
}

enum ConversationListTier: String, CaseIterable {
    case all, dm, group, dissolved
    var title: String { switch self { case .all: return "全部"; case .dm: return "私聊"; case .group: return "群聊"; case .dissolved: return "已解散" } }
    func contains(_ item: ConversationInstance) -> Bool {
        if self == .dissolved { return item.dissolvedAt != nil }
        return item.dissolvedAt == nil && (self == .all || item.kind == rawValue)
    }
}

struct ConversationGroupDraft: Equatable {
    var employeeIds: Set<String> = []
    var templateId = ""
    var excludedMemberIds: Set<String> = []
    var leaderId = ""
    var name = ""
    var duties: [String: String] = [:]
    var body: [String: Any] {
        ["employeeIds": employeeIds.sorted(), "templateId": templateId, "excludedMemberIds": excludedMemberIds.sorted(),
         "leaderId": leaderId, "name": name, "duties": duties]
    }
    mutating func selectEmployee(_ employeeID: String, selected: Bool, employees: [SiliconEmployee], presets: [ContactTeam]) {
        let existing = members(employees: employees, presets: presets)
        if selected {
            employeeIds.insert(employeeID)
            excludedMemberIds.remove(employeeID)
            for member in presets.first(where: { $0.id == templateId })?.members ?? [] where member.employeeId == employeeID {
                excludedMemberIds.remove(member.id)
            }
        } else {
            employeeIds.remove(employeeID)
            for member in existing where member.employeeId == employeeID || member.id == employeeID {
                excludedMemberIds.insert(member.id)
                if leaderId == member.id { leaderId = "" }
            }
            if leaderId == employeeID { leaderId = "" }
        }
    }

    func members(employees: [SiliconEmployee], presets: [ContactTeam]) -> [ContactTeamMember] {
        var members = presets.first { $0.id == templateId }?.members.filter { !excludedMemberIds.contains($0.id) } ?? []
        for employee in employees where employeeIds.contains(employee.id) && !members.contains(where: { $0.employeeId == employee.id }) {
            var member = ContactTeamMember(employee: employee, leader: false)
            member.id = employee.id // Draft identity is deterministic; server assigns instance member IDs.
            members.append(member)
        }
        return members
    }
}
