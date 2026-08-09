import Foundation
import Combine

protocol WorkspaceServing: AnyObject {
    func listWorkspaces() async throws -> [Workspace]
    func listWorkspaceTasks(workspaceId: String) async throws -> [WorkspaceTask]
    func updateWorkspaceTask(taskId: String, name: String?) async throws -> WorkspaceTask
    func deleteWorkspaceTask(taskId: String) async throws
    func getWorkspaceTask(taskId: String) async throws -> WorkspaceTaskDetail
    func saveWorkspaceTaskLayout(
        taskId: String,
        layout: TaskWindowLayout?
    ) async throws -> TaskWindowLayout?
    func createWorkspaceTaskWindow(
        target: WorkspaceSessionTarget,
        binding: WorkspaceBinding
    ) async throws -> SessionSnapshot
    func getSession(id: String, blockBudget: Int) async throws -> SessionSnapshot
    func workspaceDefaultProvider() async throws -> WandProvider
}

extension WandAPI: WorkspaceServing {}

enum WorkspaceIndexState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum WorkspaceTaskState {
    case idle
    case loading
    case empty(WorkspaceTaskDetail)
    case ready(WorkspaceTaskDetail)
    case failed(String)

    var detail: WorkspaceTaskDetail? {
        switch self {
        case .empty(let detail), .ready(let detail): return detail
        default: return nil
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var indexState: WorkspaceIndexState = .idle
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var tasksByWorkspace: [String: [WorkspaceTask]] = [:]
    @Published private(set) var taskErrors: [String: String] = [:]

    @Published private(set) var currentWorkspace: Workspace?
    @Published private(set) var currentTask: WorkspaceTask?
    @Published private(set) var taskState: WorkspaceTaskState = .idle
    @Published private(set) var visibleSessionID: String?
    @Published private(set) var visibleSnapshot: SessionSnapshot?
    @Published private(set) var sessionLoading = false
    @Published private(set) var sessionError: String?
    @Published private(set) var layoutWarning: String?

    @Published var pickerPresented = false
    @Published var selectedTarget: WorkspaceSessionTarget = .claude
    @Published private(set) var creating = false
    @Published private(set) var creationError: String?

    let serverID: String
    private let api: WorkspaceServing
    private var serverDefaultProvider: WandProvider = .claude
    private var indexGeneration = 0
    private var taskGeneration = 0
    private var sessionGeneration = 0

    init(api: WorkspaceServing, serverID: String) {
        self.api = api
        self.serverID = serverID
    }

    func tasks(for workspaceId: String) -> [WorkspaceTask] {
        tasksByWorkspace[workspaceId] ?? []
    }

    func loadWorkspaceIndex() async {
        indexGeneration &+= 1
        let generation = indexGeneration
        indexState = .loading
        taskErrors = [:]
        do {
            async let projectsRequest = api.listWorkspaces()
            async let defaultProviderRequest = try? api.workspaceDefaultProvider()
            let projects = try await projectsRequest
            let defaultProvider = await defaultProviderRequest
            guard generation == indexGeneration, !Task.isCancelled else { return }

            workspaces = projects
            if let defaultProvider { serverDefaultProvider = defaultProvider }
            var loadedTasks: [String: [WorkspaceTask]] = [:]
            var errors: [String: String] = [:]
            for workspace in projects {
                guard generation == indexGeneration, !Task.isCancelled else { return }
                do {
                    loadedTasks[workspace.id] = try await api.listWorkspaceTasks(
                        workspaceId: workspace.id
                    )
                } catch {
                    loadedTasks[workspace.id] = tasksByWorkspace[workspace.id] ?? []
                    errors[workspace.id] = error.localizedDescription
                }
            }
            guard generation == indexGeneration, !Task.isCancelled else { return }
            tasksByWorkspace = loadedTasks
            taskErrors = errors
            indexState = .loaded
        } catch {
            guard generation == indexGeneration, !Task.isCancelled else { return }
            indexState = .failed(error.localizedDescription)
        }
    }

    /// 成功后返回更新后的任务（名称可能被服务端规范化）。
    @discardableResult
    func renameWorkspaceTask(
        workspaceId: String,
        taskId: String,
        name: String
    ) async throws -> WorkspaceTask {
        let updated = try await api.updateWorkspaceTask(taskId: taskId, name: name)
        if var list = tasksByWorkspace[workspaceId] {
            if let index = list.firstIndex(where: { $0.id == taskId }) {
                list[index] = updated
                tasksByWorkspace[workspaceId] = list
            }
        }
        if currentTask?.id == taskId {
            currentTask = updated
        }
        return updated
    }

    func deleteWorkspaceTask(workspaceId: String, taskId: String) async throws {
        try await api.deleteWorkspaceTask(taskId: taskId)
        if var list = tasksByWorkspace[workspaceId] {
            list.removeAll { $0.id == taskId }
            tasksByWorkspace[workspaceId] = list
        }
        if currentTask?.id == taskId {
            currentTask = nil
            taskState = .idle
        }
    }

    func openTask(workspace: Workspace, task: WorkspaceTask) async {
        taskGeneration &+= 1
        sessionGeneration &+= 1
        let generation = taskGeneration
        currentWorkspace = workspace
        currentTask = task
        taskState = .loading
        visibleSessionID = nil
        visibleSnapshot = nil
        sessionLoading = false
        sessionError = nil
        layoutWarning = nil
        creationError = nil
        pickerPresented = false
        selectedTarget = WorkspaceSessionTarget(
            provider: workspace.defaultProvider ?? serverDefaultProvider
        )

        do {
            let detail = try await api.getWorkspaceTask(taskId: task.id)
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else { return }
            await applyLoadedDetail(detail, preferredSessionId: nil, generation: generation)
        } catch {
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else { return }
            taskState = .failed(error.localizedDescription)
        }
    }

    func reloadCurrentTask() async {
        guard let workspace = currentWorkspace, let task = currentTask else { return }
        await openTask(workspace: workspace, task: task)
    }

    func selectSession(id: String) async {
        guard let detail = taskState.detail,
              detail.sessions.contains(where: { $0.id == id }),
              visibleSessionID != id || visibleSnapshot == nil else { return }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        visibleSessionID = id
        visibleSnapshot = nil
        sessionLoading = true
        sessionError = nil
        do {
            let snapshot = try await api.getSession(id: id, blockBudget: WandAPI.chatBlockWindow)
            guard generation == sessionGeneration,
                  currentTask?.id == detail.id,
                  visibleSessionID == id else { return }
            visibleSnapshot = snapshot
            sessionLoading = false
        } catch {
            guard generation == sessionGeneration,
                  currentTask?.id == detail.id,
                  visibleSessionID == id else { return }
            sessionLoading = false
            sessionError = error.localizedDescription
        }
    }

    func presentTargetPicker() {
        guard taskState.detail != nil, !creating else { return }
        creationError = nil
        pickerPresented = true
    }

    func dismissTargetPicker() {
        guard !creating else { return }
        pickerPresented = false
        creationError = nil
    }

    func createSelectedWindow(expectedTaskId: String) async {
        guard !creating,
              let workspace = currentWorkspace,
              let task = currentTask,
              task.id == expectedTaskId,
              let currentDetail = taskState.detail,
              currentDetail.id == expectedTaskId else { return }
        let generation = taskGeneration
        let target = selectedTarget
        let binding = WorkspaceBinding(
            workspaceId: workspace.id,
            workspaceTaskId: task.id,
            cwd: currentDetail.cwd
        )
        creating = true
        creationError = nil
        layoutWarning = nil

        do {
            let created = try await api.createWorkspaceTaskWindow(target: target, binding: binding)
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else {
                creating = false
                return
            }

            let refreshed: WorkspaceTaskDetail
            do {
                refreshed = try await api.getWorkspaceTask(taskId: task.id)
            } catch {
                var sessions = currentDetail.sessions
                if !sessions.contains(where: { $0.id == created.id }) {
                    sessions.append(WorkspaceSessionSummary(snapshot: created))
                }
                refreshed = currentDetail.replacing(
                    layout: currentDetail.layout,
                    sessions: sessions
                )
            }
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else {
                creating = false
                return
            }

            let ordered = WorkspaceLayoutReconciler.orderedSessions(refreshed.sessions)
            let layout = WorkspaceLayoutReconciler.reconcile(
                persisted: refreshed.layout,
                sessionIds: ordered.map(\.id),
                preferredSessionId: created.id
            )
            do {
                _ = try await api.saveWorkspaceTaskLayout(taskId: task.id, layout: layout)
            } catch {
                layoutWarning = "会话已创建，布局稍后同步：\(error.localizedDescription)"
            }
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else {
                creating = false
                return
            }

            let nextDetail = refreshed.replacing(layout: layout, sessions: ordered)
            taskState = .ready(nextDetail)
            visibleSessionID = created.id
            visibleSnapshot = created
            sessionLoading = false
            sessionError = nil
            pickerPresented = false
            creating = false
        } catch {
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else {
                creating = false
                return
            }
            creating = false
            creationError = error.localizedDescription
        }
    }

    func clearLayoutWarning() {
        layoutWarning = nil
    }

    private func applyLoadedDetail(
        _ source: WorkspaceTaskDetail,
        preferredSessionId: String?,
        generation: Int
    ) async {
        let ordered = WorkspaceLayoutReconciler.orderedSessions(source.sessions)
        let layout = WorkspaceLayoutReconciler.reconcile(
            persisted: source.layout,
            sessionIds: ordered.map(\.id),
            preferredSessionId: preferredSessionId
        )
        let detail = source.replacing(layout: layout, sessions: ordered)
        taskState = ordered.isEmpty ? .empty(detail) : .ready(detail)

        guard isCurrentTask(source.id, generation: generation), !Task.isCancelled else { return }
        if ordered.isEmpty {
            visibleSessionID = nil
            visibleSnapshot = nil
        } else {
            let active = WorkspaceLayoutReconciler.activeSessionId(
                in: layout,
                validSessionIds: ordered.map(\.id)
            ) ?? ordered[0].id
            await selectSession(id: active)
        }
        guard isCurrentTask(source.id, generation: generation), !Task.isCancelled else { return }

        if layout != source.layout {
            do {
                _ = try await api.saveWorkspaceTaskLayout(taskId: source.id, layout: layout)
            } catch {
                guard isCurrentTask(source.id, generation: generation) else { return }
                layoutWarning = "布局将在下次打开时继续同步：\(error.localizedDescription)"
            }
        }
    }

    private func isCurrentTask(_ taskId: String, generation: Int) -> Bool {
        taskGeneration == generation && currentTask?.id == taskId
    }
}
