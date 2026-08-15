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
    func getWorkspaceDetail(workspaceId: String) async throws -> WorkspaceDetail
    func createWorkspace(
        name: String,
        cwd: String,
        defaultProvider: WandProvider?
    ) async throws -> Workspace
    func updateWorkspace(workspaceId: String, name: String) async throws -> Workspace
    func deleteWorkspace(workspaceId: String) async throws
    func createWorkspaceTask(
        workspaceId: String,
        name: String,
        baseRef: String?
    ) async throws -> WorkspaceTaskCreation
    func workspaceWorktreeOverview(workspaceId: String) async throws -> WorkspaceWorktreeOverview
    func startWorktreeMergeAgent(
        workspace: Workspace,
        provider: WandProvider,
        prompt: String
    ) async throws -> SessionSnapshot
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
    /// 项目直属会话（未绑定任务的会话），按项目缓存，展开项目行时加载。
    @Published private(set) var standaloneSessions: [String: [WorkspaceSessionSummary]] = [:]
    @Published private(set) var standaloneSessionErrors: [String: String] = [:]

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
    private var loadingStandaloneSessions = Set<String>()

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
            standaloneSessions = [:]
            standaloneSessionErrors = [:]
            indexState = .loaded
        } catch {
            guard generation == indexGeneration, !Task.isCancelled else { return }
            indexState = .failed(error.localizedDescription)
        }
    }

    /// 展开项目行时加载直属会话；已缓存或加载中时跳过。
    func loadWorkspaceSessions(workspaceId: String, force: Bool = false) async {
        guard force || standaloneSessions[workspaceId] == nil else { return }
        guard !loadingStandaloneSessions.contains(workspaceId) else { return }
        loadingStandaloneSessions.insert(workspaceId)
        defer { loadingStandaloneSessions.remove(workspaceId) }
        do {
            let detail = try await api.getWorkspaceDetail(workspaceId: workspaceId)
            standaloneSessions[workspaceId] = detail.standaloneSessions
            standaloneSessionErrors[workspaceId] = nil
        } catch {
            if standaloneSessions[workspaceId] == nil {
                standaloneSessionErrors[workspaceId] = error.localizedDescription
            }
        }
    }

    /// 新建项目后整表刷新，返回服务端创建的实体。
    @discardableResult
    func createWorkspace(
        name: String,
        cwd: String,
        defaultProvider: WandProvider?
    ) async throws -> Workspace {
        let created = try await api.createWorkspace(
            name: name,
            cwd: cwd,
            defaultProvider: defaultProvider
        )
        await loadWorkspaceIndex()
        return created
    }

    @discardableResult
    func renameWorkspace(workspaceId: String, name: String) async throws -> Workspace {
        let updated = try await api.updateWorkspace(workspaceId: workspaceId, name: name)
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            workspaces[index] = updated
        }
        if currentWorkspace?.id == workspaceId {
            currentWorkspace = updated
        }
        return updated
    }

    /// 级联删除项目（任务、会话与独立 worktree 一并清理），并清理本地状态。
    func deleteWorkspace(workspaceId: String) async throws {
        try await api.deleteWorkspace(workspaceId: workspaceId)
        workspaces.removeAll { $0.id == workspaceId }
        tasksByWorkspace[workspaceId] = nil
        standaloneSessions[workspaceId] = nil
        standaloneSessionErrors[workspaceId] = nil
        if currentWorkspace?.id == workspaceId {
            currentWorkspace = nil
            currentTask = nil
            taskState = .idle
            visibleSessionID = nil
            visibleSnapshot = nil
        }
    }

    /// 新建任务（服务端会尝试创建独立 worktree），成功后刷新任务列表。
    /// 返回创建结果（含 isolated/worktreeError 提示信息）与可打开的任务实体。
    @discardableResult
    func createWorkspaceTask(
        workspaceId: String,
        name: String
    ) async throws -> (creation: WorkspaceTaskCreation, task: WorkspaceTask) {
        let creation = try await api.createWorkspaceTask(
            workspaceId: workspaceId,
            name: name,
            baseRef: nil
        )
        var refreshed: [WorkspaceTask] = []
        do {
            refreshed = try await api.listWorkspaceTasks(workspaceId: workspaceId)
            tasksByWorkspace[workspaceId] = refreshed
        } catch {
            var existing = tasksByWorkspace[workspaceId] ?? []
            if !existing.contains(where: { $0.id == creation.id }) {
                existing.append(WorkspaceTask(
                    id: creation.id,
                    workspaceId: creation.workspaceId,
                    name: creation.name,
                    worktree: creation.worktree,
                    layout: nil,
                    status: creation.status,
                    createdAt: "",
                    lastOpenedAt: nil
                ))
            }
            tasksByWorkspace[workspaceId] = existing
        }
        let task = refreshed.first { $0.id == creation.id }
            ?? WorkspaceTask(
                id: creation.id,
                workspaceId: creation.workspaceId,
                name: creation.name,
                worktree: creation.worktree,
                layout: nil,
                status: creation.status,
                createdAt: "",
                lastOpenedAt: nil
            )
        return (creation, task)
    }

    /// Worktree 合并：用审查结果生成任务书并启动只绑定项目的托管 Agent 会话。
    /// provider 回退：项目默认 → 服务器默认 → Claude。
    func startWorktreeMergeAgent(
        workspace: Workspace,
        overview: WorkspaceWorktreeOverview,
        selectedTaskIds: Set<String>
    ) async throws -> SessionSnapshot {
        let prompt = try buildWorkspaceMergeAgentPrompt(
            workspace: workspace,
            overview: overview,
            selectedTaskIds: selectedTaskIds
        )
        let provider = workspace.defaultProvider ?? serverDefaultProvider
        return try await api.startWorktreeMergeAgent(
            workspace: workspace,
            provider: provider,
            prompt: prompt
        )
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
