import Foundation
import Combine

protocol WorkspaceServing: AnyObject {
    func listWorkspaces() async throws -> [Workspace]
    func listWorkspaceTasks(workspaceId: String) async throws -> [WorkspaceTask]
    func updateWorkspaceTask(taskId: String, name: String?) async throws -> WorkspaceTask
    func deleteWorkspaceTask(taskId: String) async throws
    /// 归档（软删除）任务：终端继续跑、worktree 保留，只从侧栏隐藏。
    func archiveWorkspaceTask(taskId: String) async throws -> WorkspaceTask
    /// 移动会话归属；会话本身、运行目录与历史都不变。
    func moveWorkspaceSession(taskId: String, sessionId: String) async throws
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
        prompt: String?
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
        baseRef: String?,
        worktree: Bool?,
        cwd: String?,
        description: String?
    ) async throws -> WorkspaceTaskCreation
    func createStandaloneTask(
        name: String,
        cwd: String?,
        worktree: Bool?,
        description: String?
    ) async throws -> WorkspaceTaskCreation
    func listTaskGroups() async throws -> [TaskDirectoryGroup]
    func listTaskGroupsPage(revision: String?) async throws -> TaskGroupsPage
    func deleteWorkspaceSessions(sessionIds: [String]) async throws -> Int
    func workspaceWorktreeOverview(workspaceId: String) async throws -> WorkspaceWorktreeOverview
    func startWorktreeMergeAgent(
        workspace: Workspace,
        provider: WandProvider,
        prompt: String
    ) async throws -> SessionSnapshot
}

extension WorkspaceServing {
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
            prompt: nil
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
    /// 跨目录任务聚合（GET /api/tasks）；加载失败时置空并回退到逐项目拉取。
    @Published private(set) var taskGroups: [TaskDirectoryGroup] = []
    @Published private(set) var taskGroupsError: String?
    @Published private(set) var taskGroupsLoading = false
    private var taskGroupsRevision: String?
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
        taskGroups = taskGroups.map { group in
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
        try await api.deleteWorkspace(workspaceId: workspaceId)
        workspaces.removeAll { $0.id == workspaceId }
        tasksByWorkspace[workspaceId] = nil
        standaloneSessions[workspaceId] = nil
        standaloneSessionErrors[workspaceId] = nil
        standaloneSessionGenerations[workspaceId, default: 0] &+= 1
        loadingStandaloneSessions.remove(workspaceId)
        invalidateTaskGroupsLoad()
        taskGroups.removeAll { $0.workspaceId == workspaceId }
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
            description: nil
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
        if !force && !taskGroups.isEmpty { return }
        taskGroupsGeneration &+= 1
        let generation = taskGroupsGeneration
        if taskGroups.isEmpty { taskGroupsLoading = true }
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
            taskGroups = page.groups
            taskGroupsRevision = page.revision
            taskGroupsError = nil
            await syncCurrentTaskMetadata()
        } catch {
            guard generation == taskGroupsGeneration, !Task.isCancelled else { return }
            // 保留旧数据，仅记错误供 UI 提示；老服务端无该接口时静默降级。
            if taskGroups.isEmpty { taskGroupsError = error.localizedDescription }
        }
    }

    /// 直接拉一份不经展示层过滤的分组（含已完成任务），供「移动会话」选目的地。
    /// 不改 taskGroups：侧栏缓存由下一次轮询/显式刷新接管。
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
        description: String? = nil
    ) async throws -> (workspace: Workspace, creation: WorkspaceTaskCreation) {
        let normalized = normalizeWorkspaceDirectory(directory)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名任务"
            : name
        let creation: WorkspaceTaskCreation
        let workspace: Workspace
        if let workspaceId, let existing = workspaces.first(where: { $0.id == workspaceId }) {
            creation = try await api.createWorkspaceTask(
                workspaceId: existing.id,
                name: normalizedName,
                baseRef: nil,
                worktree: worktree,
                cwd: normalized.isEmpty ? nil : normalized,
                description: description
            )
            workspace = existing
        } else {
            creation = try await api.createStandaloneTask(
                name: normalizedName,
                cwd: normalized.isEmpty ? nil : normalized,
                worktree: normalized.isEmpty ? false : worktree,
                description: description
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
        let matchingIndex = taskGroups.firstIndex { group in
            if group.isGlobal { return false }
            if group.workspaceId == workspace.id, group.isBindableProject { return true }
            return normalizeWorkspaceDirectory(group.workspaceCwd) == normalizedCwd
        }
        if let matchingIndex {
            let group = taskGroups[matchingIndex]
            let tasks = group.tasks.contains(where: { $0.id == summary.id })
                ? group.tasks
                : group.tasks + [summary]
            taskGroups[matchingIndex] = group.replacing(tasks: tasks)
            return
        }
        let synthetic = workspace.name.isEmpty || groupLooksGlobal(workspace)
        let displayName = synthetic
            ? (normalizedCwd.split(separator: "/").map(String.init).last ?? normalizedCwd)
            : workspace.name
        taskGroups.append(TaskDirectoryGroup(
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
        invalidateTaskGroupsLoad()
        taskGroups = taskGroups.map { group in
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
                    sessions: summary.sessions
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
        try await api.deleteWorkspaceTask(taskId: taskId)
        if var list = tasksByWorkspace[workspaceId] {
            list.removeAll { $0.id == taskId }
            tasksByWorkspace[workspaceId] = list
        }
        invalidateTaskGroupsLoad()
        taskGroups = taskGroups.map { group in
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
        _ = try await api.deleteWorkspaceSessions(sessionIds: sessionIds)
        await loadTaskGroups(force: true)
        if let workspace = currentWorkspace, let task = currentTask {
            await openTask(workspace: workspace, task: task, preferredSessionId: visibleSessionID)
        }
    }

    /// 合成目录改名走 session-directories（改的是该 cwd 的显示名，没有工作区实体）。
    func renameDirectory(cwd: String, name: String) async throws {
        try await api.renameSessionDirectory(path: cwd, name: name)
        invalidateTaskGroupsLoad()
        await loadTaskGroups(force: true)
    }

    /// 移动会话归属：不动运行目录、不重启 CLI，只改任务归属。
    func moveSession(sessionId: String, toTaskId: String) async throws {
        try await api.moveWorkspaceSession(taskId: toTaskId, sessionId: sessionId)
        invalidateTaskGroupsLoad()
        await loadTaskGroups(force: true)
        await refreshCurrentTaskInBackground()
    }

    /// 归档任务（软删除）：终端继续跑、worktree 保留，只从侧栏隐藏并进入看板归档。
    func archiveWorkspaceTask(taskId: String, workspaceId: String?) async throws {
        _ = try await api.archiveWorkspaceTask(taskId: taskId)
        if let workspaceId, var list = tasksByWorkspace[workspaceId] {
            list.removeAll { $0.id == taskId }
            tasksByWorkspace[workspaceId] = list
        }
        invalidateTaskGroupsLoad()
        taskGroups = taskGroups.map { $0.replacing(tasks: $0.tasks.filter { $0.id != taskId }) }
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
        guard let live = taskGroups.lazy.flatMap(\.tasks).first(where: { $0.id == task.id }) else { return }
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
        if let raw = config.defaultProvider,
           let target = WorkspaceSessionTarget(rawValue: raw),
           target != .shell {
            selectedTarget = target
        }
    }

    func rememberCreationChoice(
        provider: WorkspaceSessionTarget? = nil,
        kind: WorkspaceSessionKind? = nil
    ) {
        // 本地选择必须无条件跟着走：只把「不覆盖服务端默认 CLI」的限制放在下面写偏好那一步，
        // 否则「空白终端」在目标选择器里永远选不中（对齐 Android 的 newTaskTarget = option）。
        if let provider { selectedTarget = provider }
        if let kind { selectedKind = kind }
        Task {
            guard let api = api as? WandAPI else { return }
            try? await api.updateCreationDefaults(
                defaultProvider: provider.flatMap { $0 == .shell ? nil : $0.rawValue },
                defaultSessionKind: kind?.rawValue
            )
        }
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
            let created = try await api.createWorkspaceTaskWindow(
                target: target,
                binding: binding,
                kind: target == .shell ? .pty : selectedKind
            )
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
            guard isCurrentTask(task.id, generation: generation), !Task.isCancelled else {
                creating = false
                return
            }
            creating = false
            creationError = error.localizedDescription
        }
    }

    /// 新建任务后立刻开第一个会话（带首条提示词）；失败不阻塞任务本身已创建的事实。
    func createFirstTaskWindow(
        taskId: String,
        target: WorkspaceSessionTarget,
        kind: WorkspaceSessionKind,
        prompt: String?
    ) async throws -> SessionSnapshot {
        let detail = try await api.getWorkspaceTask(taskId: taskId)
        let binding = WorkspaceBinding(
            workspaceId: detail.workspaceId,
            workspaceTaskId: detail.id,
            cwd: detail.cwd
        )
        let snapshot = try await api.createWorkspaceTaskWindow(
            target: target,
            binding: binding,
            kind: target == .shell ? .pty : kind,
            prompt: prompt
        )
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
