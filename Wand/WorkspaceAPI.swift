import Foundation

enum WorkspaceRequestValue: Equatable {
    case string(String)
    case bool(Bool)

    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        }
    }
}

struct WorkspaceTaskWindowRequest: Equatable {
    let path: String
    let body: [String: WorkspaceRequestValue]

    var foundationBody: [String: Any] {
        body.mapValues(\.foundationValue)
    }
}

/// Pure request construction keeps provider mapping, task binding, and the unified endpoint contract testable.
/// `prompt` 是新建任务时顺手发出的第一条提示词：结构化会话走 `prompt`，PTY 走 `initialInput`。
func workspaceTaskWindowRequest(
    target: WorkspaceSessionTarget,
    binding: WorkspaceBinding,
    kind: WorkspaceSessionKind = .structured,
    prompt: String? = nil,
    mode: String? = nil,
    model: String? = nil,
    thinkingEffort: String? = nil
) -> WorkspaceTaskWindowRequest {
    // Wand Agent is an in-process structured harness, never a PTY CLI.
    let sessionKind: WorkspaceSessionKind = target == .wandAgent ? .structured : kind
    var body: [String: WorkspaceRequestValue] = [
        "kind": .string(target == .shell ? "pty" : sessionKind.rawValue),
        "cwd": .string(binding.cwd),
        "workspaceId": .string(binding.workspaceId),
        "workspaceTaskId": .string(binding.workspaceTaskId),
    ]
    let initialPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let promptValue = (initialPrompt?.isEmpty == false) ? initialPrompt : nil
    if sessionKind == .structured, target != .shell {
        if let mode, !mode.isEmpty { body["mode"] = .string(mode) }
        if let model, !model.isEmpty { body["model"] = .string(model) }
        if let thinkingEffort, !thinkingEffort.isEmpty { body["thinkingEffort"] = .string(thinkingEffort) }
    }
    if let provider = target.provider {
        body["provider"] = .string(provider.rawValue)
        if sessionKind == .structured {
            if target == .wandAgent { body["engine"] = .string("sdk") }
            else if target == .pi { body["engine"] = .string("cli") }
            if let promptValue { body["prompt"] = .string(promptValue) }
            body["runner"] = .string(provider.structuredRunner)
        } else {
            body["command"] = .string(provider == .qoder ? "qodercli" : provider.rawValue)
            if let promptValue { body["initialInput"] = .string(promptValue) }
        }
    } else {
        body["shell"] = .bool(true)
    }
    return WorkspaceTaskWindowRequest(path: "/api/sessions", body: body)
}

/// 目录组 / 任务 / 会话归属的写入路径：命中后其他屏要失效重取。
/// `layout` 是任务内的视图状态，改了它不该触发整棵树的刷新（否则后台刷新会自激）。
func changesTaskHierarchy(method: String, path: String) -> Bool {
    if method == "GET" { return false }
    let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    if route.hasSuffix("/layout") { return false }
    if route == "/api/tasks" || route.hasPrefix("/api/tasks/") || route.hasPrefix("/api/workspace-tasks/") { return true }
    if route == "/api/workspaces" || route.hasPrefix("/api/workspaces/") { return true }
    if route == "/api/wand-tasks" || route.hasPrefix("/api/wand-tasks/") { return true }
    if route == "/api/sessions" { return true }
    if route.hasPrefix("/api/sessions/") {
        return ["/archive", "/unarchive", "/provider", "/directory", "/completion/view"].contains { route.hasSuffix($0) }
            || route == "/api/sessions/batch-archive" || route == "/api/sessions/batch-delete"
    }
    if route.hasPrefix("/api/ai-teams/"), route.hasSuffix("/runs") { return true }
    return route == "/api/sessions/batch-delete"
}

/// Worktree 合并 Agent 的托管会话请求：mode=managed + initialInput 任务书，
/// 会话只绑定项目、不绑定任务（对齐 web 端 startWorktreeMergeAgent）。
func worktreeMergeAgentRequest(
    workspace: Workspace,
    provider: WandProvider,
    prompt: String
) -> WorkspaceTaskWindowRequest {
    WorkspaceTaskWindowRequest(
        path: "/api/sessions",
        body: [
            "kind": .string("pty"),
            "command": .string(provider == .qoder ? "qodercli" : provider.rawValue),
            "provider": .string(provider.rawValue),
            "cwd": .string(workspace.cwd),
            "mode": .string("managed"),
            "initialInput": .string(prompt),
            "sessionSource": .string("interactive"),
            "workspaceId": .string(workspace.id),
        ]
    )
}

/// `GET /api/path-suggestions` 的目录建议项。
struct WorkspacePathSuggestion: Codable, Equatable, Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }
}

/// `GET /api/recent-paths` 的最近使用目录。
struct WorkspaceRecentPath: Codable, Equatable, Identifiable {
    let path: String
    let name: String
    let lastUsedAt: String?

    var id: String { path }
}

func createWorkspaceRequest(
    name: String,
    cwd: String,
    defaultProvider: WandProvider?
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = [
        "name": .string(name),
        "cwd": .string(cwd),
    ]
    if let defaultProvider {
        body["defaultProvider"] = .string(defaultProvider.rawValue)
    }
    return WorkspaceTaskWindowRequest(path: "/api/workspaces", body: body)
}

func createWorkspaceTaskRequest(
    workspaceId: String,
    name: String,
    baseRef: String?,
    worktree: Bool? = nil,
    cwd: String? = nil,
    description: String? = nil,
    parentTaskId: String? = nil,
    creationRequestId: String? = nil
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = ["name": .string(name)]
    if let creationRequestId, !creationRequestId.isEmpty { body["creationRequestId"] = .string(creationRequestId) }
    if let parentTaskId, !parentTaskId.isEmpty { body["parentTaskId"] = .string(parentTaskId) }
    if let baseRef, !baseRef.isEmpty {
        body["baseRef"] = .string(baseRef)
    }
    if let cwd, !cwd.isEmpty {
        body["cwd"] = .string(cwd)
    }
    // 显式 true/false 都传给服务端：true 失败不再静默降级，false 跳过隔离。
    if let worktree {
        body["worktree"] = .bool(worktree)
    }
    // 首个会话的提示词：任务留空名时服务端据此总结标题，不再写“未命名任务”。
    if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        body["description"] = .string(description)
    }
    return WorkspaceTaskWindowRequest(
        path: "/api/workspaces/\(workspaceId)/tasks",
        body: body
    )
}

func createStandaloneTaskRequest(
    name: String,
    cwd: String? = nil,
    worktree: Bool? = nil,
    description: String? = nil,
    parentTaskId: String? = nil,
    creationRequestId: String? = nil
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = ["name": .string(name)]
    if let creationRequestId, !creationRequestId.isEmpty { body["creationRequestId"] = .string(creationRequestId) }
    if let parentTaskId, !parentTaskId.isEmpty { body["parentTaskId"] = .string(parentTaskId) }
    if let cwd, !cwd.isEmpty {
        body["cwd"] = .string(cwd)
    }
    if worktree == false {
        body["worktree"] = .bool(false)
    } else if worktree == true {
        body["worktree"] = .bool(true)
    }
    if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        body["description"] = .string(description)
    }
    return WorkspaceTaskWindowRequest(path: "/api/tasks", body: body)
}

private struct WorkspaceLayoutResponse: Decodable {
    let layout: TaskWindowLayout?
}

extension WandAPI {
    func listWorkspaces() async throws -> [Workspace] {
        let workspaces = try await request([Workspace].self, method: "GET", path: "/api/workspaces")
        return workspaces.sorted { lhs, rhs in
            switch (lhs.createdAt.isEmpty, rhs.createdAt.isEmpty) {
            case (false, false) where lhs.createdAt != rhs.createdAt:
                return lhs.createdAt < rhs.createdAt
            case (false, true):
                return true
            case (true, false):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    func listWorkspaceTasks(workspaceId: String) async throws -> [WorkspaceTask] {
        let id = percentEncodePathComponent(workspaceId)
        return try await request(
            [WorkspaceTask].self,
            method: "GET",
            path: "/api/workspaces/\(id)/tasks"
        )
    }

    @discardableResult
    func updateWorkspaceTask(taskId: String, name: String?) async throws -> WorkspaceTask {
        let id = percentEncodePathComponent(taskId)
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        return try await request(
            WorkspaceTask.self,
            method: "PATCH",
            path: "/api/workspace-tasks/\(id)",
            body: body.isEmpty ? nil : body
        )
    }

    func deleteWorkspaceTask(taskId: String) async throws {
        let id = percentEncodePathComponent(taskId)
        _ = try await requestData(method: "DELETE", path: "/api/workspace-tasks/\(id)?cascade=1")
    }

    /// 移动会话归属：不动运行目录、不重启 CLI，只改任务归属。
    func moveWorkspaceSession(taskId: String, sessionId: String) async throws {
        let id = percentEncodePathComponent(taskId)
        _ = try await requestData(
            method: "POST",
            path: "/api/workspace-tasks/\(id)/sessions",
            body: ["sessionId": sessionId]
        )
    }

    /// 归档任务：软删除。终端继续运行、worktree 保留，只是侧栏不再显示。
    @discardableResult
    func archiveWorkspaceTask(taskId: String) async throws -> WorkspaceTask {
        let id = percentEncodePathComponent(taskId)
        return try await request(
            WorkspaceTask.self,
            method: "POST",
            path: "/api/workspace-tasks/\(id)/archive"
        )
    }

    /// 按标题归类所选任务，并处理这些任务下的会话归属。不确定的不移动。
    func organizeTasksByTitle(taskIds: [String], sessionIds: [String]) async throws -> TitleOrganizeResponse {
        try await request(
            TitleOrganizeResponse.self,
            method: "POST",
            path: "/api/tasks/organize-by-title",
            body: ["taskIds": taskIds, "sessionIds": sessionIds],
            timeout: 90
        )
    }

    func deleteWorkspaceSessions(sessionIds: [String]) async throws -> Int {
        let ids = Array(Set(sessionIds.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return 0 }
        let response = try await request(
            SessionBatchDeleteResponse.self,
            method: "POST",
            path: "/api/sessions/batch-delete",
            body: ["sessionIds": ids]
        )
        return response.deleted ?? ids.count
    }

    /// 归档 / 恢复会话。归档是软标记：不杀进程、不删历史，也不改任务归属。
    /// 返回服务端仍然失败的 ID，调用方据此保留原状态，不谎报成功。
    func batchArchiveWorkspaceSessions(sessionIds: [String], archived: Bool) async throws -> [String] {
        let ids = Array(Set(sessionIds.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [] }
        let response = try await request(
            SessionBatchArchiveResponse.self,
            method: "POST",
            path: "/api/sessions/batch-archive",
            body: ["sessionIds": ids, "archived": archived]
        )
        return response.failed ?? []
    }

    func archiveWorkspaceSession(sessionId: String, archived: Bool) async throws {
        let id = percentEncodePathComponent(sessionId)
        _ = try await requestData(
            method: "POST",
            path: "/api/sessions/\(id)/\(archived ? "archive" : "unarchive")"
        )
    }

    /// 确认「这一代完成结果已经在屏幕上」。只有用户明确打开的会话才调用；
    /// 自动选中 / 列表刷新 / 重连都不算，否则未读提示会被后台刷新吃掉。
    func markSessionCompletionViewed(
        sessionId: String,
        completionRevision: Int
    ) async throws -> SessionCompletionResponse {
        let id = percentEncodePathComponent(sessionId)
        return try await request(
            SessionCompletionResponse.self,
            method: "POST",
            path: "/api/sessions/\(id)/completion/view",
            body: ["completionRevision": completionRevision]
        )
    }

    func getWorkspaceTask(taskId: String) async throws -> WorkspaceTaskDetail {
        let id = percentEncodePathComponent(taskId)
        return try await request(
            WorkspaceTaskDetail.self,
            method: "GET",
            path: "/api/workspace-tasks/\(id)"
        )
    }

    @discardableResult
    func saveWorkspaceTaskLayout(
        taskId: String,
        layout: TaskWindowLayout?
    ) async throws -> TaskWindowLayout? {
        let id = percentEncodePathComponent(taskId)
        let encoded: Any
        if let layout {
            let data = try JSONEncoder().encode(layout)
            encoded = try JSONSerialization.jsonObject(with: data)
        } else {
            encoded = NSNull()
        }
        let response = try await request(
            WorkspaceLayoutResponse.self,
            method: "PUT",
            path: "/api/workspace-tasks/\(id)/layout",
            body: ["layout": encoded]
        )
        return response.layout
    }

    func createWorkspaceTaskWindow(
        target: WorkspaceSessionTarget,
        binding: WorkspaceBinding,
        kind: WorkspaceSessionKind,
        prompt: String? = nil,
        mode: String? = nil,
        model: String? = nil,
        thinkingEffort: String? = nil
    ) async throws -> SessionSnapshot {
        let requestSpec = workspaceTaskWindowRequest(
            target: target,
            binding: binding,
            kind: kind,
            prompt: prompt,
            mode: mode,
            model: model,
            thinkingEffort: thinkingEffort
        )
        let body = requestSpec.foundationBody
        return try await request(
            SessionSnapshot.self,
            method: "POST",
            path: requestSpec.path,
            body: body,
            timeout: kind == .structured && prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? 180 : 30
        )
    }

    // ── 项目级操作（v4.40+ 服务端）──

    func getWorkspaceDetail(workspaceId: String) async throws -> WorkspaceDetail {
        let id = percentEncodePathComponent(workspaceId)
        return try await request(WorkspaceDetail.self, method: "GET", path: "/api/workspaces/\(id)")
    }

    @discardableResult
    func createWorkspace(
        name: String,
        cwd: String,
        defaultProvider: WandProvider?
    ) async throws -> Workspace {
        let requestSpec = createWorkspaceRequest(
            name: name,
            cwd: cwd,
            defaultProvider: defaultProvider
        )
        return try await request(
            Workspace.self,
            method: "POST",
            path: requestSpec.path,
            body: requestSpec.foundationBody
        )
    }

    @discardableResult
    func updateWorkspace(workspaceId: String, name: String) async throws -> Workspace {
        let id = percentEncodePathComponent(workspaceId)
        return try await request(
            Workspace.self,
            method: "PATCH",
            path: "/api/workspaces/\(id)",
            body: ["name": name]
        )
    }

    func deleteWorkspace(workspaceId: String) async throws {
        let id = percentEncodePathComponent(workspaceId)
        _ = try await requestData(method: "DELETE", path: "/api/workspaces/\(id)?cascade=1")
    }

    func createWorkspaceTask(
        workspaceId: String,
        name: String,
        baseRef: String? = nil,
        worktree: Bool? = nil,
        cwd: String? = nil,
        description: String? = nil,
        parentTaskId: String? = nil,
        creationRequestId: String? = nil
    ) async throws -> WorkspaceTaskCreation {
        let requestSpec = createWorkspaceTaskRequest(
            workspaceId: workspaceId,
            name: name,
            baseRef: baseRef,
            worktree: worktree,
            cwd: cwd,
            description: description,
            parentTaskId: parentTaskId,
            creationRequestId: creationRequestId
        )
        return try await request(
            WorkspaceTaskCreation.self,
            method: "POST",
            path: requestSpec.path,
            body: requestSpec.foundationBody
        )
    }

    func createStandaloneTask(
        name: String,
        cwd: String? = nil,
        worktree: Bool? = nil,
        description: String? = nil,
        parentTaskId: String? = nil,
        creationRequestId: String? = nil
    ) async throws -> WorkspaceTaskCreation {
        let requestSpec = createStandaloneTaskRequest(
            name: name,
            cwd: cwd,
            worktree: worktree,
            description: description,
            parentTaskId: parentTaskId,
            creationRequestId: creationRequestId
        )
        return try await request(
            WorkspaceTaskCreation.self,
            method: "POST",
            path: requestSpec.path,
            body: requestSpec.foundationBody
        )
    }

    /// 跨目录任务聚合列表（GET /api/tasks）：目录组一级容器，
    /// 未绑定任务的会话归入 standaloneSessions。
    func saveWorkspaceGroupOrder(_ ids: [String]) async throws {
        _ = try await requestData(method: "PUT", path: "/api/workspaces/order", body: ["ids": ids])
    }

    func listTaskGroups() async throws -> [TaskDirectoryGroup] {
        try await listTaskGroupsPage(revision: nil).groups
    }

    func listTaskGroupsPage(revision: String?) async throws -> TaskGroupsPage {
        var path = "/api/tasks"
        if let revision, !revision.isEmpty {
            path += "?revision=\(percentEncodePathComponent(revision))"
        }
        let data = try await requestData(method: "GET", path: path)
        return try TaskGroupsPage.decode(from: data)
    }

    func workspaceWorktreeOverview(workspaceId: String) async throws -> WorkspaceWorktreeOverview {
        let id = percentEncodePathComponent(workspaceId)
        return try await request(
            WorkspaceWorktreeOverview.self,
            method: "GET",
            path: "/api/workspaces/\(id)/worktrees"
        )
    }

    func startWorktreeMergeAgent(
        workspace: Workspace,
        provider: WandProvider,
        prompt: String
    ) async throws -> SessionSnapshot {
        let requestSpec = worktreeMergeAgentRequest(
            workspace: workspace,
            provider: provider,
            prompt: prompt
        )
        return try await request(
            SessionSnapshot.self,
            method: "POST",
            path: requestSpec.path,
            body: requestSpec.foundationBody
        )
    }

    func workspacePathSuggestions(query: String) async throws -> [WorkspacePathSuggestion] {
        let encoded = query.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics
        ) ?? ""
        return try await request(
            [WorkspacePathSuggestion].self,
            method: "GET",
            path: "/api/path-suggestions?q=\(encoded)"
        )
    }

    func workspaceRecentPaths() async throws -> [WorkspaceRecentPath] {
        try await request([WorkspaceRecentPath].self, method: "GET", path: "/api/recent-paths")
    }

    func workspaceDefaultProvider() async throws -> WandProvider {
        WandProvider(normalizing: try await serverConfig().defaultProvider)
    }
}
