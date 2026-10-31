import Foundation
import Combine

protocol WorkspaceServing: AnyObject {
    func createWorkspaceSection(name: String, cwd: String, workspaceId: String?, sessionId: String?) async throws -> WorkspaceTask
    func unassignWorkspaceSession(sessionId: String) async throws
    func listWorkspaces() async throws -> [Workspace]
    func listWorkspaceTasks(workspaceId: String) async throws -> [WorkspaceTask]
    func updateWorkspaceTask(taskId: String, name: String?) async throws -> WorkspaceTask
    func deleteWorkspaceTask(taskId: String) async throws
    /// 归档（软删除）任务：终端继续跑、worktree 保留，只从侧栏隐藏。
    func archiveWorkspaceTask(taskId: String) async throws -> WorkspaceTask
    /// 移动会话归属；会话本身、运行目录与历史都不变。
    func moveWorkspaceSession(taskId: String, sessionId: String) async throws
    /// 按标题归类所选任务，并处理这些任务下的会话归属。不确定的不移动。
    func organizeTasksByTitle(taskIds: [String], sessionIds: [String]) async throws -> TitleOrganizeResponse
    /// 合成目录（无工作区实体）改显示名。
    func renameSessionDirectory(path: String, name: String) async throws
    func getWorkspaceTask(taskId: String) async throws -> WorkspaceTaskDetail
    func saveWorkspaceTaskLayout(
        taskId: String,
        layout: TaskWindowLayout?
    ) async throws -> TaskWindowLayout?
    func createWorkspaceTaskWindow(
        target: WorkspaceSessionTarget,
        binding: WorkspaceBinding,
        kind: WorkspaceSessionKind,
        prompt: String?,
        mode: String?,
        model: String?,
        thinkingEffort: String?
    ) async throws -> SessionSnapshot
    func createWorkspaceEmployeeTaskWindow(employeeID: String, binding: WorkspaceBinding, prompt: String?) async throws -> SessionSnapshot
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
        baseRef: String?,
        worktree: Bool?,
        cwd: String?,
        description: String?,
        parentTaskId: String?,
        creationRequestId: String?
    ) async throws -> WorkspaceTaskCreation
    func createStandaloneTask(
        name: String,
        cwd: String?,
        worktree: Bool?,
        description: String?,
        parentTaskId: String?,
        creationRequestId: String?
    ) async throws -> WorkspaceTaskCreation
    func listTaskGroups() async throws -> [TaskDirectoryGroup]
    func saveWorkspaceGroupOrder(_ ids: [String]) async throws
    func listTaskGroupsPage(revision: String?) async throws -> TaskGroupsPage
    func deleteWorkspaceSessions(sessionIds: [String]) async throws -> Int
    func batchArchiveWorkspaceSessions(sessionIds: [String], archived: Bool) async throws -> [String]
    func archiveWorkspaceSession(sessionId: String, archived: Bool) async throws
    func markSessionCompletionViewed(sessionId: String, completionRevision: Int) async throws -> SessionCompletionResponse
    func workspaceWorktreeOverview(workspaceId: String) async throws -> WorkspaceWorktreeOverview
    func startWorktreeMergeAgent(
        workspace: Workspace,
        prompt: String
    ) async throws -> SessionSnapshot
}

extension WorkspaceServing {
    func organizeTasksByTitle(taskIds: [String], sessionIds: [String]) async throws -> TitleOrganizeResponse {
        throw WandAPI.APIError.network("当前服务不支持按标题归类，请更新服务端")
    }
    func saveWorkspaceGroupOrder(_ ids: [String]) async throws { throw WandAPI.APIError.network("当前服务不支持保存工作区顺序，请更新服务端") }
    func createWorkspaceEmployeeTaskWindow(employeeID: String, binding: WorkspaceBinding, prompt: String?) async throws -> SessionSnapshot {
        throw WandAPI.APIError.network("当前服务不支持硅基员工会话。")
    }

    /// Swift 协议不支持默认参数，用一个省略 prompt 的重载对齐 Android 端的 `prompt = null`。
    func createWorkspaceTaskWindow(
        target: WorkspaceSessionTarget,
        binding: WorkspaceBinding,
        kind: WorkspaceSessionKind
    ) async throws -> SessionSnapshot {
        try await createWorkspaceTaskWindow(
            target: target,
            binding: binding,
            kind: kind,
            prompt: nil,
            mode: nil,
            model: nil,
            thinkingEffort: nil
        )
    }
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

enum WorkspaceTaskCreationError: LocalizedError {
    case missingDirectory

    var errorDescription: String? {
        "请选择任务目录。"
    }
}

func normalizeWorkspaceDirectory(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.count > 1 && value.hasSuffix("/") {
        value.removeLast()
    }
    return value
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
    /// Full GET /api/tasks page, including archived tasks/sessions, owned once for IM filtering.
    @Published private(set) var conversationTaskGroups: [TaskDirectoryGroup] = [] {
        didSet { taskGroups = TaskGroupsPage.currentGroups(conversationTaskGroups) }
    }
    /// Derived only from the full page; existing home/workspace screens keep their original scope.
    @Published private(set) var taskGroups: [TaskDirectoryGroup] = []
    @Published private(set) var taskGroupsError: String?
    @Published private(set) var taskGroupsLoading = false
    private var taskGroupsRevision: String?
    @Published private(set) var pendingGroupOrder: [String]?
    @Published private(set) var orderSaveError: String?
    private var orderSaveTail: Task<Void, Never>?
    private var taskGroupsSyncTask: Task<Void, Never>?

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
    @Published var selectedKind: WorkspaceSessionKind = .structured
    @Published private(set) var creating = false
    @Published private(set) var creationError: String?
    @Published private(set) var unconfirmedWindowTasks = Set<String>()
    @Published private(set) var taskCreationUnconfirmed = false
    /// Unknown creation text stays in this endpoint owner's memory, never preferences.
    @Published private(set) var unconfirmedCreationPrompt: String?

    let serverID: String
    private let api: WorkspaceServing
    private var serverDefaultProvider: WandProvider = .claude
    private var indexGeneration = 0
    private var taskGroupsGeneration = 0
    private var taskGeneration = 0
    private var sessionGeneration = 0
    private var loadingStandaloneSessions = Set<String>()
    private var standaloneSessionGenerations: [String: Int] = [:]
    private var pendingSessionSelection: PendingSessionSelection?
    private var backgroundRefreshInFlight = false
    private var taskChangeCancellables = Set<AnyCancellable>()

    private struct PendingSessionSelection {
        let taskId: String
        let sessionId: String
    }

    init(api: WorkspaceServing, serverID: String) {
        self.api = api
        self.serverID = serverID
    }

    private func invalidateTaskGroupsLoad() {
        taskGroupsGeneration &+= 1
        taskGroupsLoading = false
        taskGroupsRevision = nil
    }

    func startTaskGroupsSync() {
        if taskGroupsSyncTask != nil { return }
        // 同端（网页版 / 另一台手机）改了归属时立即失效重取，不靠下一个 10s 轮询周期。
        if let live = api as? WandAPI {
            live.taskChanges
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self else { return }
                    Task { await self.loadTaskGroups(force: true) }
                }
                .store(in: &taskChangeCancellables)
        }
        taskGroupsSyncTask = Task { [weak self] in
            await self?.loadTaskGroups()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.loadTaskGroups(force: true)
            }
        }
    }

    func stopTaskGroupsSync() {
        taskGroupsSyncTask?.cancel()
        taskGroupsSyncTask = nil
        taskChangeCancellables.removeAll()
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
            // 项目数可能很多；任务列表没有相互依赖，并行拉取后按原顺序合并，
            // 避免首页在慢网络/多项目时被串行请求放大成显著的白屏等待。
            let taskResults: [String: Result<[WorkspaceTask], Error>] = await withTaskGroup(
                of: (String, Result<[WorkspaceTask], Error>).self
            ) { group in
                for workspace in projects {
                    group.addTask {
                        do {
                            return (workspace.id, .success(try await self.api.listWorkspaceTasks(
                                workspaceId: workspace.id
                            )))
                        } catch {
                            return (workspace.id, .failure(error))
                        }
                    }
                }
                var results: [String: Result<[WorkspaceTask], Error>] = [:]
                for await result in group { results[result.0] = result.1 }
                return results
            }
            guard generation == indexGeneration, !Task.isCancelled else { return }

            var loadedTasks: [String: [WorkspaceTask]] = [:]
            var errors: [String: String] = [:]
            for workspace in projects {
                switch taskResults[workspace.id] {
                case .success(let tasks):
                    loadedTasks[workspace.id] = tasks
                case .failure(let error):
                    loadedTasks[workspace.id] = tasksByWorkspace[workspace.id] ?? []
                    errors[workspace.id] = error.localizedDescription
                case .none:
                    loadedTasks[workspace.id] = tasksByWorkspace[workspace.id] ?? []
                    errors[workspace.id] = "任务列表未返回"
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
        guard force || !loadingStandaloneSessions.contains(workspaceId) else { return }
        let generation = (standaloneSessionGenerations[workspaceId] ?? 0) &+ 1
        let workspaceIndexGeneration = indexGeneration
        standaloneSessionGenerations[workspaceId] = generation
        loadingStandaloneSessions.insert(workspaceId)
        defer {
            if standaloneSessionGenerations[workspaceId] == generation {
                loadingStandaloneSessions.remove(workspaceId)
            }
        }
        do {
            let detail = try await api.getWorkspaceDetail(workspaceId: workspaceId)
            guard standaloneSessionGenerations[workspaceId] == generation,
                  indexGeneration == workspaceIndexGeneration,
                  !Task.isCancelled else { return }
            standaloneSessions[workspaceId] = detail.standaloneSessions
            standaloneSessionErrors[workspaceId] = nil
        } catch {
            guard standaloneSessionGenerations[workspaceId] == generation,
                  indexGeneration == workspaceIndexGeneration,
                  !Task.isCancelled else { return }
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
        await loadTaskGroups(force: true)
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
        invalidateTaskGroupsLoad()
        conversationTaskGroups = conversationTaskGroups.map { group in
            guard group.workspaceId == workspaceId else { return group }
            return TaskDirectoryGroup(
                workspaceId: group.workspaceId,
                workspaceName: updated.name,
                workspaceCwd: updated.cwd,
                createdAt: group.createdAt,
                synthetic: group.synthetic,
                global: group.global,
                tasks: group.tasks,
                standaloneSessions: group.standaloneSessions
            )
        }
        return updated
    }

    /// 级联删除项目（任务、会话与独立 worktree 一并清理），并清理本地状态。
    func deleteWorkspace(workspaceId: String) async throws {
        var deletedSessionIds = Set(standaloneSessions[workspaceId]?.map(\.id) ?? [])
        for group in conversationTaskGroups {
            if group.workspaceId == workspaceId { deletedSessionIds.formUnion(group.standaloneSessions.map(\.id)) }
            for task in group.tasks where task.workspaceId == workspaceId {
                deletedSessionIds.formUnion(task.sessions.map(\.id))
            }
        }
        if let detail = try? await api.getWorkspaceDetail(workspaceId: workspaceId) {
            deletedSessionIds.formUnion(detail.sessions.map(\.id))
        }
        if let endpoint = api as? WandAPI,
           let tasks = try? await endpoint.listWorkspaceTasks(workspaceId: workspaceId) {
            let taskSessionIds = await withTaskGroup(of: [String].self) { group in
                for task in tasks {
                    group.addTask {
                        (try? await endpoint.getWorkspaceTask(taskId: task.id).sessions.map(\.id)) ?? []
                    }
                }
                var ids: [String] = []
                for await taskIds in group { ids += taskIds }
                return ids
            }
            deletedSessionIds.formUnion(taskSessionIds)
        }
        if currentWorkspace?.id == workspaceId, let detail = taskState.detail {
            deletedSessionIds.formUnion(detail.sessions.map(\.id))
        }
        try await api.deleteWorkspace(workspaceId: workspaceId)
        await removeConfirmedDeletedDrafts(deletedSessionIds)
        workspaces.removeAll { $0.id == workspaceId }
        tasksByWorkspace[workspaceId] = nil
        standaloneSessions[workspaceId] = nil
        standaloneSessionErrors[workspaceId] = nil
        standaloneSessionGenerations[workspaceId, default: 0] &+= 1
        loadingStandaloneSessions.remove(workspaceId)
        invalidateTaskGroupsLoad()
        conversationTaskGroups.removeAll { $0.workspaceId == workspaceId }
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
            baseRef: nil,
            worktree: nil,
            cwd: nil,
            description: nil,
            parentTaskId: nil,
            creationRequestId: nil
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

    /// 跨目录任务聚合：任务视图数据源；失败不阻塞项目树。
    /// force 用于下拉刷新和 10s 轮询；首次加载仍可跳过已有缓存。
    func loadTaskGroups(force: Bool = false) async {
        if !force && !conversationTaskGroups.isEmpty { return }
        taskGroupsGeneration &+= 1
        let generation = taskGroupsGeneration
        if conversationTaskGroups.isEmpty { taskGroupsLoading = true }
        defer {
            if generation == taskGroupsGeneration { taskGroupsLoading = false }
        }
        do {
            let page = try await api.listTaskGroupsPage(revision: taskGroupsRevision)
            guard generation == taskGroupsGeneration, !Task.isCancelled else { return }
            if page.unchanged {
                taskGroupsError = nil
                return
            }
            conversationTaskGroups = applyingWorkspaceGroupOrder(page.groups, order: pendingGroupOrder)
            taskGroupsRevision = page.revision
            taskGroupsError = nil
            await syncCurrentTaskMetadata()
        } catch {
            guard generation == taskGroupsGeneration, !Task.isCancelled else { return }
            // 保留旧数据并显示错误；绝不能把读取失败伪装成空目录。
            taskGroupsError = error.localizedDescription
        }
    }

    func moveWorkspaceGroup(_ id: String, to targetID: String) {
        guard id != targetID, let from = conversationTaskGroups.firstIndex(where: { $0.id == id }),
              let to = conversationTaskGroups.firstIndex(where: { $0.id == targetID }) else { return }
        var next = conversationTaskGroups
        let moved = next.remove(at: from); next.insert(moved, at: to)
        conversationTaskGroups = next
        pendingGroupOrder = next.map(\.id)
        savePendingGroupOrder()
    }

    func moveWorkspaceGroup(_ id: String, delta: Int) {
        guard let index = taskGroups.firstIndex(where: { $0.id == id }), taskGroups.indices.contains(index + delta) else { return }
        moveWorkspaceGroup(id, to: taskGroups[index + delta].id)
    }

    func savePendingGroupOrder() {
        guard pendingGroupOrder != nil else { return }
        orderSaveError = nil
        let previous = orderSaveTail
        orderSaveTail = Task { [weak self] in
            await previous?.value
            guard let self, let order = pendingGroupOrder else { return }
            do {
                try await api.saveWorkspaceGroupOrder(order)
                if pendingGroupOrder == order { pendingGroupOrder = nil; orderSaveError = nil }
            } catch { if pendingGroupOrder == order { orderSaveError = error.localizedDescription } }
        }
    }

    /// 直接拉一份含已完成但未归档任务的分组，保留「移动会话」目的地原有范围。
    /// 不改 conversationTaskGroups：侧栏缓存由下一次轮询/显式刷新接管。
    func freshTaskGroups() async throws -> [TaskDirectoryGroup] {
        try await api.listTaskGroups()
    }

    /// 任务入口：独立任务走 POST /api/tasks（目录可空，使用全局临时目录）；
    /// 指定 workspaceId 时在该项目下创建。description 是首个会话的提示词，
    /// 任务未命名时服务端据此总结标题。
    @discardableResult
    func createTask(
        name: String,
        directory: String,
        worktree: Bool?,
        workspaceId: String? = nil,
        description: String? = nil,
        parentTaskId: String? = nil
    ) async throws -> (workspace: Workspace, creation: WorkspaceTaskCreation) {
        guard !taskCreationUnconfirmed else { throw WandAPI.APIError.network("任务创建结果未确认，请先核对任务列表。") }
        let normalized = normalizeWorkspaceDirectory(directory)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty || description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw WandAPI.APIError.network("任务名称不能为空。")
        }
        let creation: WorkspaceTaskCreation
        let workspace: Workspace
        do {
        if let workspaceId, let existing = workspaces.first(where: { $0.id == workspaceId }) {
            creation = try await api.createWorkspaceTask(
                workspaceId: existing.id,
                name: normalizedName,
                baseRef: nil,
                worktree: worktree,
                cwd: normalized.isEmpty ? nil : normalized,
                description: description,
                parentTaskId: parentTaskId,
                creationRequestId: nil
            )
            workspace = existing
        } else {
            creation = try await api.createStandaloneTask(
                name: normalizedName,
                cwd: normalized.isEmpty ? nil : normalized,
                worktree: normalized.isEmpty ? false : worktree,
                description: description,
                parentTaskId: parentTaskId,
                creationRequestId: nil
            )
            workspace = workspaces.first(where: { $0.id == creation.workspaceId })
                ?? Workspace(
                    id: creation.workspaceId,
                    name: "",
                    cwd: creation.cwd,
                    defaultProvider: nil,
                    layout: nil,
                    createdAt: "",
                    lastOpenedAt: nil
                )
        }
        } catch {
            if contactCreationNeedsReview(attempted: true, error: error) { markUnconfirmedTaskCreation(prompt: description) }
            throw error
        }
        tasksByWorkspace[workspace.id] = (tasksByWorkspace[workspace.id] ?? []) + [WorkspaceTask(
            id: creation.id,
            workspaceId: creation.workspaceId,
            name: creation.name,
            worktree: creation.worktree,
            layout: nil,
            status: creation.status,
            createdAt: "",
            lastOpenedAt: nil
        )]
        let summary = WorkspaceTaskSummary(
            id: creation.id,
            workspaceId: creation.workspaceId,
            name: creation.name,
            worktree: creation.worktree,
            layout: nil,
            status: creation.status,
            createdAt: "",
            lastOpenedAt: nil,
            cwd: creation.cwd,
            isolated: creation.isolated,
            worktreeError: creation.worktreeError,
            sessions: []
        )
        invalidateTaskGroupsLoad()
        upsertCreatedTaskSummary(summary, workspace: workspace)
        await loadTaskGroups(force: true)
        return (workspace, creation)
    }


    private func upsertCreatedTaskSummary(_ summary: WorkspaceTaskSummary, workspace: Workspace) {
        let normalizedCwd = normalizeWorkspaceDirectory(summary.cwd.isEmpty ? workspace.cwd : summary.cwd)
        let matchingIndex = conversationTaskGroups.firstIndex { group in
            if group.isGlobal { return false }
            if group.workspaceId == workspace.id, group.isBindableProject { return true }
            return normalizeWorkspaceDirectory(group.workspaceCwd) == normalizedCwd
        }
        if let matchingIndex {
            let group = conversationTaskGroups[matchingIndex]
            let tasks = group.tasks.contains(where: { $0.id == summary.id })
                ? group.tasks
                : group.tasks + [summary]
            conversationTaskGroups[matchingIndex] = group.replacing(tasks: tasks)
            return
        }
        let synthetic = workspace.name.isEmpty || groupLooksGlobal(workspace)
        let displayName = synthetic
            ? (normalizedCwd.split(separator: "/").map(String.init).last ?? normalizedCwd)
            : workspace.name
        conversationTaskGroups.append(TaskDirectoryGroup(
            workspaceId: synthetic ? "cwd:\(normalizedCwd)" : workspace.id,
            workspaceName: displayName,
            workspaceCwd: normalizedCwd.isEmpty ? workspace.cwd : normalizedCwd,
            createdAt: workspace.createdAt,
            synthetic: synthetic,
            global: false,
            tasks: [summary],
            standaloneSessions: []
        ))
    }

    private func groupLooksGlobal(_ workspace: Workspace) -> Bool {
        workspace.name == "全局" || workspace.name == "全局任务" || workspace.id == "wand-global"
    }

    /// Worktree 合并：用审查结果生成任务书并启动只绑定项目的托管 Agent 会话。
    /// 系统运维功能统一由「勤劳的初二」执行，工具与模型走初二候选链。
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
        return try await api.startWorktreeMergeAgent(
            workspace: workspace,
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
        invalidateTaskGroupsLoad()
        conversationTaskGroups = conversationTaskGroups.map { group in
            let tasks = group.tasks.map { summary in
                guard summary.id == taskId else { return summary }
                return WorkspaceTaskSummary(
                    id: updated.id,
                    workspaceId: updated.workspaceId,
                    name: updated.name,
                    worktree: updated.worktree,
                    layout: updated.layout,
                    status: updated.status,
                    createdAt: updated.createdAt,
                    lastOpenedAt: updated.lastOpenedAt,
                    cwd: summary.cwd,
                    isolated: summary.isolated,
                    worktreeError: summary.worktreeError,
                    sessions: summary.sessions,
                    totalSessions: summary.totalSessions,
                    executionStatus: summary.executionStatus,
                    queuedExecutionCount: summary.queuedExecutionCount,
                    boardTaskId: summary.boardTaskId,
                    boardTaskStatus: summary.boardTaskStatus,
                    archived: summary.archived,
                    parentWorkspaceTaskId: summary.parentWorkspaceTaskId
                )
            }
            return TaskDirectoryGroup(
                workspaceId: group.workspaceId,
                workspaceName: group.workspaceName,
                workspaceCwd: group.workspaceCwd,
                createdAt: group.createdAt,
                synthetic: group.synthetic,
                global: group.global,
                tasks: tasks,
                standaloneSessions: group.standaloneSessions
            )
        }
        return updated
    }

    func deleteWorkspaceTask(workspaceId: String, taskId: String) async throws {
        var deletedSessionIds = Set(conversationTaskGroups.flatMap(\.tasks).filter { $0.id == taskId }.flatMap { $0.sessions.map(\.id) })
        if let detail = try? await api.getWorkspaceTask(taskId: taskId) {
            deletedSessionIds.formUnion(detail.sessions.map(\.id))
        }
        if currentTask?.id == taskId, let detail = taskState.detail {
            deletedSessionIds.formUnion(detail.sessions.map(\.id))
        }
        try await api.deleteWorkspaceTask(taskId: taskId)
        await removeConfirmedDeletedDrafts(deletedSessionIds)
        if var list = tasksByWorkspace[workspaceId] {
            list.removeAll { $0.id == taskId }
            tasksByWorkspace[workspaceId] = list
        }
        invalidateTaskGroupsLoad()
        conversationTaskGroups = conversationTaskGroups.map { group in
            TaskDirectoryGroup(
                workspaceId: group.workspaceId,
                workspaceName: group.workspaceName,
                workspaceCwd: group.workspaceCwd,
                createdAt: group.createdAt,
                synthetic: group.synthetic,
                global: group.global,
                tasks: group.tasks.filter { $0.id != taskId },
                standaloneSessions: group.standaloneSessions
            )
        }
        if currentTask?.id == taskId {
            currentTask = nil
            taskState = .idle
        }
    }

    func deleteSessions(_ sessionIds: [String]) async throws {
        let deleted = try await api.deleteWorkspaceSessions(sessionIds: sessionIds)
        if deleted == Set(sessionIds).count, let endpoint = api as? WandAPI {
            for id in Set(sessionIds) { SessionDraftStore.shared.remove(sessionId: id, api: endpoint) }
        }
        await loadTaskGroups(force: true)
        if let workspace = currentWorkspace, let task = currentTask {
            await openTask(workspace: workspace, task: task, preferredSessionId: visibleSessionID)
        }
    }

    /// A session may have moved since the pre-delete read. Only remove its draft
    /// after successful cascade and an authoritative post-delete absence check.
    private func removeConfirmedDeletedDrafts(_ ids: Set<String>) async {
        guard !ids.isEmpty, let endpoint = api as? WandAPI,
              let remaining = try? await endpoint.listSessions() else { return }
        let liveIds = Set(remaining.map(\.id))
        for id in ids.subtracting(liveIds) { SessionDraftStore.shared.remove(sessionId: id, api: endpoint) }
    }

    /// 归档 / 恢复会话。返回仍然失败的 ID；归档不杀进程也不删历史，
    /// 只刷新列表投影。不在客户端手工改只读字段，让服务端投影回来做准。
    @discardableResult
    func archiveSessions(_ sessionIds: [String], archived: Bool) async throws -> [String] {
        let failed = try await api.batchArchiveWorkspaceSessions(sessionIds: sessionIds, archived: archived)
        await loadTaskGroups(force: true)
        if let workspace = currentWorkspace, let task = currentTask {
            await openTask(workspace: workspace, task: task, preferredSessionId: visibleSessionID)
        }
        return failed
    }

    func archiveSession(_ sessionId: String, archived: Bool) async throws {
        try await api.archiveWorkspaceSession(sessionId: sessionId, archived: archived)
        await loadTaskGroups(force: true)
        if archived && visibleSessionID == sessionId { await reloadCurrentTask() }
        else { await refreshCurrentTaskInBackground() }
    }

    /// 确认完成代次。失败不回滚：未读提示留在原样，下次明确打开还能重试。
    func markSessionCompletionViewed(sessionId: String, completionRevision: Int) async throws {
        _ = try await api.markSessionCompletionViewed(
            sessionId: sessionId,
            completionRevision: completionRevision
        )
        await loadTaskGroups(force: true)
    }

    /// 合成目录改名走 session-directories（改的是该 cwd 的显示名，没有工作区实体）。
    func renameDirectory(cwd: String, name: String) async throws {
        try await api.renameSessionDirectory(path: cwd, name: name)
        invalidateTaskGroupsLoad()
        await loadTaskGroups(force: true)
    }

    func createSection(name: String, group: TaskDirectoryGroup, sessionId: String? = nil) async throws {
        _ = try await api.createWorkspaceSection(name: name, cwd: group.workspaceCwd,
            workspaceId: group.isBindableProject ? group.workspaceId : nil, sessionId: sessionId)
        invalidateTaskGroupsLoad()
        await loadTaskGroups(force: true)
        await refreshCurrentTaskInBackground()
    }

    func unassignSession(_ sessionId: String) async throws {
        try await api.unassignWorkspaceSession(sessionId: sessionId)
        invalidateTaskGroupsLoad()
        await loadTaskGroups(force: true)
        await refreshCurrentTaskInBackground()
    }

    /// 移动会话归属：不动运行目录、不重启 CLI，只改任务归属。
    func moveSession(sessionId: String, toTaskId: String) async throws {
        try await api.moveWorkspaceSession(taskId: toTaskId, sessionId: sessionId)
        invalidateTaskGroupsLoad()
        await loadTaskGroups(force: true)
        await refreshCurrentTaskInBackground()
    }

    /// 多选任务后按标题归类，并处理这些任务下的会话归属。不确定的不移动。
    func organizeTasksByTitle(taskIds: [String], sessionIds: [String]) async throws -> TitleOrganizeResponse {
        let result = try await api.organizeTasksByTitle(taskIds: taskIds, sessionIds: sessionIds)
        invalidateTaskGroupsLoad()
        await loadTaskGroups(force: true)
        await refreshCurrentTaskInBackground()
        return result
    }

    /// 归档任务（软删除）：终端继续跑、worktree 保留，只从侧栏隐藏并进入看板归档。
    func archiveWorkspaceTask(taskId: String, workspaceId: String?) async throws {
        _ = try await api.archiveWorkspaceTask(taskId: taskId)
        if let workspaceId, var list = tasksByWorkspace[workspaceId] {
            list.removeAll { $0.id == taskId }
            tasksByWorkspace[workspaceId] = list
        }
        invalidateTaskGroupsLoad()
        conversationTaskGroups = conversationTaskGroups.map { group in
            group.replacing(tasks: group.tasks.map { task in
                guard task.id == taskId else { return task }
                var archived = task
                archived.archived = true
                return archived
            })
        }
        if currentTask?.id == taskId {
            currentTask = nil
            currentWorkspace = nil
            taskState = .idle
            visibleSessionID = nil
            visibleSnapshot = nil
        }
        await loadTaskGroups(force: true)
    }

    /**
     服务端失效（同端移动会话、看板改任务）驱动的后台重取：
     保留当前选中会话，不闪加载态，失败时留着上一份可用快照。
     */
    func refreshCurrentTaskInBackground() async {
        guard let task = currentTask,
              taskState.detail != nil,
              !creating,
              !backgroundRefreshInFlight else { return }
        if case .loading = taskState { return }
        backgroundRefreshInFlight = true
        defer { backgroundRefreshInFlight = false }
        let generation = taskGeneration
        guard let detail = try? await api.getWorkspaceTask(taskId: task.id) else { return }
        guard isCurrentTask(task.id, generation: generation), !Task.isCancelled, !creating else { return }
        await applyLoadedDetail(detail, preferredSessionId: visibleSessionID, generation: generation)
    }

    /// 侧栏刚拿到新数据：当前打开的任务名称/会话集合变了就静默对齐
    /// （同端移动会话、看板改名都不会经过本机的 mutation 路径）。
    private func syncCurrentTaskMetadata() async {
        guard let task = currentTask, let detail = taskState.detail, detail.id == task.id else { return }
        guard let live = conversationTaskGroups.lazy.flatMap(\.tasks).first(where: { $0.id == task.id }) else { return }
        if live.name != task.name || live.status != task.status {
            currentTask = live.asTask()
        }
        if Set(live.sessions.map(\.id)) != Set(detail.sessions.map(\.id)) {
            await refreshCurrentTaskInBackground()
        }
    }

    func clearTaskSessions(taskId: String) async throws {
        let detail = try await api.getWorkspaceTask(taskId: taskId)
        let ids = detail.sessions.map(\.id)
        guard !ids.isEmpty else { return }
        try await deleteSessions(ids)
    }

    /// 新建任务时「启动会话」开出的首个会话，等任务页打开时直接激活它（布局写失败也不丢）。
    func scheduleAutoSelectSession(taskId: String, sessionId: String) {
        pendingSessionSelection = PendingSessionSelection(taskId: taskId, sessionId: sessionId)
    }

    func openTask(
        workspace: Workspace,
        task: WorkspaceTask,
        preferredSessionId: String? = nil
    ) async {
        let pendingSelection = pendingSessionSelection?.taskId == task.id
            ? pendingSessionSelection
            : nil
        if pendingSelection == nil { pendingSessionSelection = nil }
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
        selectedKind = .structured

        do {
            let detail = try await api.getWorkspaceTask(taskId: task.id)
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else { return }
            let preferred = preferredSessionId ?? pendingSelection?.sessionId
            await applyLoadedDetail(detail, preferredSessionId: preferred, generation: generation)
            if preferred == pendingSelection?.sessionId {
                pendingSessionSelection = nil
            }
        } catch {
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else { return }
            taskState = .failed(error.localizedDescription)
        }
    }

    func openTaskAndPresentPicker(workspace: Workspace, task: WorkspaceTask) async {
        await openTask(workspace: workspace, task: task)
        if case .empty = taskState { return }
        presentTargetPicker()
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

    func loadCreationDefaults() async {
        guard let api = api as? WandAPI, let config = try? await api.serverConfig() else { return }
        selectedKind = config.defaultSessionKind == "pty" ? .pty : .structured
        if config.defaultProvider == "pi", config.defaultEngine == "sdk" { selectedTarget = .wandAgent; selectedKind = .structured }
        else if let raw = config.defaultProvider, let target = WorkspaceSessionTarget(rawValue: raw), target != .shell { selectedTarget = target }
    }

    func rememberCreationChoice(
        provider: WorkspaceSessionTarget? = nil,
        kind: WorkspaceSessionKind? = nil
    ) {
        if let provider { selectedTarget = provider }
        if let kind { selectedKind = kind }
        if selectedTarget == .wandAgent { selectedKind = .structured }
    }

    func presentTargetPicker() {
        guard taskState.detail != nil, !creating else { return }
        creationError = nil
        pickerPresented = true
        Task { await loadCreationDefaults() }
    }

    func dismissTargetPicker() {
        guard !creating else { return }
        pickerPresented = false
        creationError = nil
    }

    func markUnconfirmedTaskCreation(prompt: String? = nil) {
        taskCreationUnconfirmed = true
        if let prompt { unconfirmedCreationPrompt = prompt }
    }
    func acknowledgeUnconfirmedTaskCreation() { taskCreationUnconfirmed = false; unconfirmedCreationPrompt = nil }
    func markUnconfirmedWindow(taskID: String) { unconfirmedWindowTasks.insert(taskID) }
    func acknowledgeUnconfirmedWindow(taskID: String) { unconfirmedWindowTasks.remove(taskID); creationError = nil }
    func contactEmployeesForPicker() async throws -> [SiliconEmployee] {
        guard let nativeAPI = api as? WandAPI else { return [] }
        return try await nativeAPI.listContactEmployees()
    }
    func createSelectedWindow(expectedTaskId: String, employeeID: String? = nil) async {
        guard !creating, !unconfirmedWindowTasks.contains(expectedTaskId),
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
            let created: SessionSnapshot
            if let employeeID {
                created = try await api.createWorkspaceEmployeeTaskWindow(employeeID: employeeID, binding: binding, prompt: nil)
            } else {
                created = try await api.createWorkspaceTaskWindow(target: target, binding: binding, kind: target == .shell ? .pty : selectedKind)
            }
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
            Task { await self.loadTaskGroups(force: true) }
        } catch {
            if !isDefiniteInputRejection(error) { unconfirmedWindowTasks.insert(task.id) }
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else {
                creating = false
                return
            }
            creating = false
            creationError = unconfirmedWindowTasks.contains(task.id) ? "创建结果未确认，请先刷新任务并核对会话，勿重复创建。" : error.localizedDescription
        }
    }

    /// 新建任务后立刻开第一个会话（带首条提示词）；失败不阻塞任务本身已创建的事实。
    func createFirstTaskWindow(
        taskId: String,
        target: WorkspaceSessionTarget,
        kind: WorkspaceSessionKind,
        prompt: String?,
        employeeID: String? = nil,
        mode: String? = nil,
        model: String? = nil,
        thinkingEffort: String? = nil
    ) async throws -> SessionSnapshot {
        guard !unconfirmedWindowTasks.contains(taskId) else { throw WandAPI.APIError.network("会话创建结果未确认，请先核对任务会话。") }
        let detail = try await api.getWorkspaceTask(taskId: taskId)
        let binding = WorkspaceBinding(
            workspaceId: detail.workspaceId,
            workspaceTaskId: detail.id,
            cwd: detail.cwd
        )
        let snapshot: SessionSnapshot
        do {
        if let employeeID {
            snapshot = try await api.createWorkspaceEmployeeTaskWindow(employeeID: employeeID, binding: binding, prompt: prompt)
        } else {
            snapshot = try await api.createWorkspaceTaskWindow(
                target: target,
                binding: binding,
                kind: target == .shell ? .pty : kind,
                prompt: prompt,
                mode: target == .shell ? nil : mode,
                model: target == .shell ? nil : model,
                thinkingEffort: target == .shell ? nil : thinkingEffort
            )
        }
        } catch {
            if contactCreationNeedsReview(attempted: true, error: error) { markUnconfirmedWindow(taskID: taskId) }
            throw error
        }
        // 接受会话回执后，即使布局/刷新失败也禁止盲目重试创建。
        markUnconfirmedWindow(taskID: taskId)
        // 新会话要成为任务里的活动窗口，否则打开任务看到的还是旧窗口（对齐 Android 的
        // addSessionWindow(activate: true)）；布局写失败不影响会话已创建的事实。
        let refreshed = (try? await api.getWorkspaceTask(taskId: taskId)) ?? detail
        var sessions = WorkspaceLayoutReconciler.orderedSessions(refreshed.sessions)
        if !sessions.contains(where: { $0.id == snapshot.id }) {
            sessions.append(WorkspaceSessionSummary(snapshot: snapshot))
        }
        let layout = WorkspaceLayoutReconciler.reconcile(
            persisted: refreshed.layout,
            sessionIds: sessions.map(\.id),
            preferredSessionId: snapshot.id
        )
        _ = try? await api.saveWorkspaceTaskLayout(taskId: taskId, layout: layout)
        scheduleAutoSelectSession(taskId: taskId, sessionId: snapshot.id)
        invalidateTaskGroupsLoad()
        await loadTaskGroups(force: true)
        acknowledgeUnconfirmedWindow(taskID: taskId)
        return snapshot
    }

    func clearLayoutWarning() {
        layoutWarning = nil
    }

    private func applyLoadedDetail(
        _ source: WorkspaceTaskDetail,
        preferredSessionId: String?,
        generation: Int
    ) async {
        guard isCurrentTask(source.id, generation: generation), !Task.isCancelled else { return }
        let ordered = WorkspaceLayoutReconciler.orderedSessions(source.sessions)
        let available = ordered.filter { $0.archived != true || $0.id == preferredSessionId }
        let layout = WorkspaceLayoutReconciler.reconcile(
            persisted: source.layout,
            sessionIds: available.map(\.id),
            preferredSessionId: preferredSessionId
        )
        let detail = source.replacing(layout: layout, sessions: ordered)
        taskState = available.isEmpty ? .empty(detail) : .ready(detail)

        guard isCurrentTask(source.id, generation: generation), !Task.isCancelled else { return }
        if available.isEmpty {
            visibleSessionID = nil
            visibleSnapshot = nil
        } else {
            let active = WorkspaceLayoutReconciler.activeSessionId(
                in: layout,
                validSessionIds: available.map(\.id)
            ) ?? available[0].id
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
