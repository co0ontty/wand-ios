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
/// `prompt` 是新建任务时顺手发出的第一条提示词：结构化会话走 `prompt`，PTY 走 `initialInput`。
func workspaceTaskWindowRequest(
    target: WorkspaceSessionTarget,
    binding: WorkspaceBinding,
    kind: WorkspaceSessionKind = .structured,
    prompt: String? = nil
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = [
        "cwd": .string(binding.cwd),
        "workspaceId": .string(binding.workspaceId),
        "workspaceTaskId": .string(binding.workspaceTaskId),
    ]
    let initialPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let promptValue = (initialPrompt?.isEmpty == false) ? initialPrompt : nil
    if let provider = target.provider {
        body["provider"] = .string(provider.rawValue)
        if kind == .structured {
            if let promptValue { body["prompt"] = .string(promptValue) }
            body["runner"] = .string(provider.structuredRunner)
            return WorkspaceTaskWindowRequest(path: "/api/structured-sessions", body: body)
        }
        if let promptValue { body["initialInput"] = .string(promptValue) }
        body["command"] = .string(provider == .qoder ? "qodercli" : provider.rawValue)
    } else {
        body["shell"] = .bool(true)
    }
    return WorkspaceTaskWindowRequest(path: "/api/commands", body: body)
}

/// 目录组 / 任务 / 会话归属的写入路径：命中后其他屏要失效重取。
/// `layout` 是任务内的视图状态，改了它不该触发整棵树的刷新（否则后台刷新会自激）。
func changesTaskHierarchy(method: String, path: String) -> Bool {
    if method == "GET" { return false }
    let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    if route.hasSuffix("/layout") { return false }
    if route == "/api/tasks" || route.hasPrefix("/api/workspace-tasks/") { return true }
    if route == "/api/workspaces" || route.hasPrefix("/api/workspaces/") { return true }
    if route == "/api/wand-tasks" || route.hasPrefix("/api/wand-tasks/") { return true }
    if route == "/api/commands" || route == "/api/structured-sessions" { return true }
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
    worktree: Bool? = nil,
    cwd: String? = nil,
    description: String? = nil
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = ["name": .string(name)]
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
    description: String? = nil
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = ["name": .string(name)]
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
        kind: WorkspaceSessionKind,
        prompt: String? = nil
    ) async throws -> SessionSnapshot {
        let requestSpec = workspaceTaskWindowRequest(
            target: target,
            binding: binding,
            kind: kind,
            prompt: prompt
        )
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
        worktree: Bool? = nil,
        cwd: String? = nil,
        description: String? = nil
    ) async throws -> WorkspaceTaskCreation {
        let requestSpec = createWorkspaceTaskRequest(
            workspaceId: workspaceId,
            name: name,
            baseRef: baseRef,
            worktree: worktree,
            cwd: cwd,
            description: description
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
        description: String? = nil
    ) async throws -> WorkspaceTaskCreation {
        let requestSpec = createStandaloneTaskRequest(
            name: name,
            cwd: cwd,
            worktree: worktree,
            description: description
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
