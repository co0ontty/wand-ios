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

/// Pure request construction keeps provider-to-command mapping and workspace binding testable.
func workspaceTaskWindowRequest(
    target: WorkspaceSessionTarget,
    binding: WorkspaceBinding,
    kind: WorkspaceSessionKind = .structured
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = [
        "cwd": .string(binding.cwd),
        "workspaceId": .string(binding.workspaceId),
        "workspaceTaskId": .string(binding.workspaceTaskId),
    ]
    if let provider = target.provider {
        body["provider"] = .string(provider.rawValue)
        if kind == .structured {
            body["runner"] = .string(provider.structuredRunner)
            return WorkspaceTaskWindowRequest(path: "/api/structured-sessions", body: body)
        }
        body["command"] = .string(provider == .qoder ? "qodercli" : provider.rawValue)
    } else {
        body["shell"] = .bool(true)
    }
    return WorkspaceTaskWindowRequest(path: "/api/commands", body: body)
}

/// Worktree 合并 Agent 的托管会话请求：mode=managed + initialInput 任务书，
/// 会话只绑定项目、不绑定任务（对齐 web 端 startWorktreeMergeAgent）。
func worktreeMergeAgentRequest(
    workspace: Workspace,
    provider: WandProvider,
    prompt: String
) -> WorkspaceTaskWindowRequest {
    WorkspaceTaskWindowRequest(
        path: "/api/commands",
        body: [
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
    worktree: Bool? = nil
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = ["name": .string(name)]
    if let baseRef, !baseRef.isEmpty {
        body["baseRef"] = .string(baseRef)
    }
    // 仅在显式关掉时传 worktree:false；缺省交由服务端默认（git 仓库自动隔离）。
    if worktree == false {
        body["worktree"] = .bool(false)
    }
    return WorkspaceTaskWindowRequest(
        path: "/api/workspaces/\(workspaceId)/tasks",
        body: body
    )
}

private struct WorkspaceLayoutResponse: Decodable {
    let layout: TaskWindowLayout?
}

extension WandAPI {
    func listWorkspaces() async throws -> [Workspace] {
        try await request([Workspace].self, method: "GET", path: "/api/workspaces")
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
        kind: WorkspaceSessionKind
    ) async throws -> SessionSnapshot {
        let requestSpec = workspaceTaskWindowRequest(target: target, binding: binding, kind: kind)
        return try await request(
            SessionSnapshot.self,
            method: "POST",
            path: requestSpec.path,
            body: requestSpec.foundationBody
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
        worktree: Bool? = nil
    ) async throws -> WorkspaceTaskCreation {
        let requestSpec = createWorkspaceTaskRequest(
            workspaceId: workspaceId,
            name: name,
            baseRef: baseRef,
            worktree: worktree
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
    func listTaskGroups() async throws -> [TaskDirectoryGroup] {
        try await request([TaskDirectoryGroup].self, method: "GET", path: "/api/tasks")
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
