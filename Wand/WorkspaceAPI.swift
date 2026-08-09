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
    binding: WorkspaceBinding
) -> WorkspaceTaskWindowRequest {
    var body: [String: WorkspaceRequestValue] = [
        "cwd": .string(binding.cwd),
        "workspaceId": .string(binding.workspaceId),
        "workspaceTaskId": .string(binding.workspaceTaskId),
    ]
    if let provider = target.provider {
        body["provider"] = .string(provider.rawValue)
        body["command"] = .string(provider == .qoder ? "qodercli" : provider.rawValue)
    } else {
        body["shell"] = .bool(true)
    }
    return WorkspaceTaskWindowRequest(path: "/api/commands", body: body)
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
        binding: WorkspaceBinding
    ) async throws -> SessionSnapshot {
        let requestSpec = workspaceTaskWindowRequest(target: target, binding: binding)
        return try await request(
            SessionSnapshot.self,
            method: "POST",
            path: requestSpec.path,
            body: requestSpec.foundationBody
        )
    }

    func workspaceDefaultProvider() async throws -> WandProvider {
        WandProvider(normalizing: try await serverConfig().defaultProvider)
    }
}
