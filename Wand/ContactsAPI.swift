import Foundation

protocol ContactDirectoryService {
    func listContactEmployees() async throws -> [SiliconEmployee]
    func listContactTeams() async throws -> [ContactTeam]
    func listWorkspaces() async throws -> [Workspace]
    func contactDefaultCwd() async throws -> String?
    func createEmployeeConversation(employeeId: String, binding: ContactConversationBinding) async throws -> SessionSnapshot
    func startContactTeam(teamId: String, workspaceId: String) async throws -> ContactRunDetail
}

protocol EmployeeEditingService {
    func contactDefaultCandidate() async throws -> ContactCandidate
    func models() async throws -> ModelsResponse
    func contactEmployee(_ id: String) async throws -> SiliconEmployee
    func saveContactEmployee(id: String?, draft: EmployeeDraft, builtin: Bool) async throws -> SiliconEmployee
    func manageContactEmployee(id: String, action: String) async throws
}

extension EmployeeEditingService {
    func contactDefaultCandidate() async throws -> ContactCandidate { ContactCandidate() }
}

protocol ContactTeamService {
    func contactDefaultCandidate() async throws -> ContactCandidate
    func models() async throws -> ModelsResponse
    func contactTeam(_ id: String) async throws -> ContactTeamInfo
    func saveContactTeam(id: String?, draft: ContactTeamDraft) async throws -> ContactTeam
    func deleteContactTeam(_ id: String) async throws
    func startContactTeam(teamId: String, workspaceId: String, note: String) async throws -> ContactRunDetail
}
extension ContactTeamService {
    func contactDefaultCandidate() async throws -> ContactCandidate { ContactCandidate() }
}

protocol ContactRunService {
    func contactRun(_ id: String) async throws -> ContactRunDetail
    func contactRunAction(_ id: String, action: String, body: [String: Any]) async throws -> ContactRunDetail
    func sendStructuredInput(id: String, input: String) async throws -> SessionSnapshot
    func contactTaskRuns(_ taskId: String) async throws -> [ContactTeamRun]
    func contactLive(_ id: String) async throws -> ContactLiveUpdate
}

extension WandAPI: ContactDirectoryService, EmployeeEditingService, ContactTeamService, ContactRunService {
    func createContactEmployeeSession(employeeID: String, cwd: String, workspaceID: String? = nil,
                                      workspaceTaskID: String? = nil, prompt: String? = nil) async throws -> SessionSnapshot {
        let snapshot = try await createSession(
            kind: "structured", cwd: cwd, prompt: prompt,
            workspaceId: workspaceID, workspaceTaskId: workspaceTaskID, employeeId: employeeID
        )
        guard !snapshot.id.isEmpty, snapshot.isStructured, snapshot.employeeId == employeeID,
              workspaceTaskID == nil || snapshot.workspaceTaskId == workspaceTaskID else {
            throw APIError.network("员工会话回执身份或任务归属不一致，请刷新核对，勿重复创建。")
        }
        return snapshot
    }
    func createWorkspaceEmployeeTaskWindow(employeeID: String, binding: WorkspaceBinding, prompt: String?) async throws -> SessionSnapshot {
        try await createContactEmployeeSession(employeeID: employeeID, cwd: binding.cwd, workspaceID: binding.workspaceId,
                                               workspaceTaskID: binding.workspaceTaskId, prompt: prompt)
    }
    func dispatchContactTask(id: String, subject: ContactExecutionSubject, prompt: String) async throws -> WandBoardDispatchResult {
        let result = try await request(WandBoardDispatchResult.self, method: "POST",
            path: "/api/wand-tasks/\(percentEncodePathComponent(id))/dispatch", body: contactTaskSubjectBody(subject: subject, prompt: prompt))
        guard result.ok, result.taskId == id, !result.sessionId.isEmpty else {
            throw APIError.network("任务派发回执无效，请刷新核对，勿重复派发。")
        }
        return result
    }
    func contactBoardTask(workspaceTaskID: String, workspaceID: String?) async throws -> WandBoardTask {
        let matches = try await listBoardTasks(workspaceId: workspaceID).filter { $0.workspaceTaskId == workspaceTaskID }
        guard matches.count == 1 else { throw APIError.network("任务已创建，但暂时无法确认对应的看板任务，请刷新核对。") }
        return matches[0]
    }
    func contactDefaultCandidate() async throws -> ContactCandidate {
        let agent = try await boardTaskAgentDefaults()
        var candidate = ContactCandidate()
        candidate.provider = agent.provider; candidate.model = agent.model
        candidate.thinkingEffort = agent.thinkingEffort; candidate.mode = agent.mode; candidate.engine = agent.engine
        return candidate
    }
    func listContactEmployees() async throws -> [SiliconEmployee] {
        struct Page: Decodable { let employees: [SiliconEmployee] }
        return try await request(Page.self, method: "GET", path: "/api/silicon-employees").employees
    }
    func listContactTeams() async throws -> [ContactTeam] {
        try await request([ContactTeam].self, method: "GET", path: "/api/ai-teams")
    }
    func contactDefaultCwd() async throws -> String? { try await serverConfig().defaultCwd }
    func createEmployeeConversation(employeeId: String, binding: ContactConversationBinding) async throws -> SessionSnapshot {
        let result = try await createSession(
            kind: "structured", cwd: binding.cwd, workspaceId: binding.workspaceId, employeeId: employeeId
        )
        guard !result.id.isEmpty, result.isStructured, result.employeeId == employeeId else {
            throw APIError.network("员工对话回执无效，请刷新核对，勿重复创建。")
        }
        return result
    }
    func contactEmployee(_ id: String) async throws -> SiliconEmployee {
        try await request(SiliconEmployee.self, method: "GET", path: "/api/silicon-employees/\(percentEncodePathComponent(id))")
    }
    func saveContactEmployee(id: String?, draft: EmployeeDraft, builtin: Bool) async throws -> SiliconEmployee {
        try await request(SiliconEmployee.self, method: id == nil ? "POST" : "PUT",
                          path: "/api/silicon-employees" + (id.map { "/" + percentEncodePathComponent($0) } ?? ""),
                          body: draft.body(builtin: builtin))
    }
    func manageContactEmployee(id: String, action: String) async throws {
        let base = "/api/silicon-employees/\(percentEncodePathComponent(id))"
        _ = try await requestData(method: action == "delete" ? "DELETE" : "POST",
                                  path: action == "delete" ? base : base + "/" + action)
    }
    func contactKnowledge(employeeId: String, query: String) async throws -> EmployeeKnowledgePage {
        let page = try await request(EmployeeKnowledgePage.self, method: "GET",
                                    path: "/api/silicon-employees/\(percentEncodePathComponent(employeeId))/knowledge",
                                    queryItems: [URLQueryItem(name: "q", value: query)])
        guard page.employeeId == employeeId, page.entries.allSatisfy({ $0.employeeId == employeeId }) else {
            throw APIError.network("知识归属不一致，已停止显示。")
        }
        return page
    }
    func addContactKnowledge(employeeId: String, text: String) async throws -> EmployeeKnowledgeEntry {
        try await request(EmployeeKnowledgeEntry.self, method: "POST",
                          path: "/api/silicon-employees/\(percentEncodePathComponent(employeeId))/knowledge", body: ["content": text])
    }
    func deleteContactKnowledge(employeeId: String, entryId: String?) async throws {
        let base = "/api/silicon-employees/\(percentEncodePathComponent(employeeId))/knowledge"
        _ = try await requestData(method: "DELETE", path: base + (entryId.map { "/" + percentEncodePathComponent($0) } ?? ""))
    }
    func contactTeam(_ id: String) async throws -> ContactTeamInfo {
        try await request(ContactTeamInfo.self, method: "GET", path: "/api/ai-teams/\(percentEncodePathComponent(id))")
    }
    func saveContactTeam(id: String?, draft: ContactTeamDraft) async throws -> ContactTeam {
        try await request(ContactTeam.self, method: id == nil ? "POST" : "PUT",
                          path: "/api/ai-teams" + (id.map { "/" + percentEncodePathComponent($0) } ?? ""), body: draft.body())
    }
    func deleteContactTeam(_ id: String) async throws {
        _ = try await requestData(method: "DELETE", path: "/api/ai-teams/\(percentEncodePathComponent(id))")
    }
    func startContactTeam(teamId: String, workspaceId: String) async throws -> ContactRunDetail {
        try await startContactTeam(teamId: teamId, workspaceId: workspaceId, note: "新对话")
    }
    func startContactTeam(teamId: String, workspaceId: String, note: String) async throws -> ContactRunDetail {
        let result = try await request(ContactRunDetail.self, method: "POST",
                                       path: "/api/ai-teams/\(percentEncodePathComponent(teamId))/runs",
                                       body: ["workspaceId": workspaceId, "note": note])
        guard !result.run.id.isEmpty, result.run.teamId == teamId else { throw APIError.network("群聊回执无效，请刷新核对，勿重复创建。") }
        return result
    }
    func contactRun(_ id: String) async throws -> ContactRunDetail {
        try await request(ContactRunDetail.self, method: "GET", path: "/api/ai-team-runs/\(percentEncodePathComponent(id))")
    }
    func contactTaskRuns(_ taskId: String) async throws -> [ContactTeamRun] {
        try await request([ContactTeamRun].self, method: "GET", path: "/api/wand-tasks/\(percentEncodePathComponent(taskId))/team-runs")
    }
    func contactLive(_ id: String) async throws -> ContactLiveUpdate {
        try await request(ContactLiveUpdate.self, method: "GET", path: "/api/ai-team-runs/\(percentEncodePathComponent(id))/live")
    }
    func contactRunAction(_ id: String, action: String, body: [String: Any] = [:]) async throws -> ContactRunDetail {
        try await request(ContactRunDetail.self, method: "POST", path: "/api/ai-team-runs/\(percentEncodePathComponent(id))/\(action)", body: body)
    }
}
