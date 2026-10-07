import SwiftUI

struct WorkspaceTaskSelection: Equatable {
    let workspace: Workspace
    let task: WorkspaceTask
}

func workspaceForTaskGroup(
    _ group: TaskDirectoryGroup,
    workspaces: [Workspace]
) -> Workspace {
    if let workspace = workspaces.first(where: { $0.id == group.workspaceId }) {
        return workspace
    }
    return Workspace(
        id: group.workspaceId,
        name: group.workspaceName,
        cwd: group.workspaceCwd,
        defaultProvider: nil,
        layout: nil,
        createdAt: "",
        lastOpenedAt: nil
    )
}

/// 任务行对应的真实项目：优先索引里的完整实体。合成目录组的 `workspaceId` 不是真实项目 ID，
/// 打开任务必须用 `task.workspaceId`（侧栏与看板都走这一个出口）。
func workspaceForTaskSummary(
    _ summary: WorkspaceTaskSummary,
    group: TaskDirectoryGroup,
    workspaces: [Workspace]
) -> Workspace {
    if let workspace = workspaces.first(where: { $0.id == summary.workspaceId }) {
        return workspace
    }
    if !group.isSynthetic, summary.workspaceId == group.workspaceId {
        return workspaceForTaskGroup(group, workspaces: workspaces)
    }
    return Workspace(
        id: summary.workspaceId,
        name: group.workspaceName,
        cwd: summary.cwd.isEmpty ? group.workspaceCwd : summary.cwd,
        defaultProvider: nil,
        layout: nil,
        createdAt: "",
        lastOpenedAt: nil
    )
}

private enum TaskListConfirm: Identifiable {
    case archiveTask(WorkspaceTask)
    case deleteTask(WorkspaceTask)
    case clearSessions(WorkspaceTaskSummary)
    case deleteSession(WorkspaceSessionSummary)
    case deleteWorkspace(Workspace)
    case deleteManaged(TaskListPresentation.ManageSelection)
    case archiveManaged(TaskListPresentation.ManageSelection)

    var id: String {
        switch self {
        case .archiveTask(let task): return "archive-task-\(task.id)"
        case .deleteTask(let task): return "delete-task-\(task.id)"
        case .clearSessions(let task): return "clear-\(task.id)"
        case .deleteSession(let session): return "delete-session-\(session.id)"
        case .deleteWorkspace(let workspace): return "delete-workspace-\(workspace.id)"
        case .deleteManaged: return "delete-managed"
        case .archiveManaged: return "archive-managed"
        }
    }
}

struct WorkspaceListView: View {
    @ObservedObject var store: WorkspaceStore
    let api: WandAPI
    var serverDisplayName: String? = nil
    let selectedTaskId: String?
    var selectedSessionId: String? = nil
    var hidesHomeChrome: Bool = false
    @Binding var isSelecting: Bool
    let onOpenTask: (Workspace, WorkspaceTask) -> Void
    var onTaskRenamed: ((WorkspaceTask) -> Void)? = nil
    var onTaskDeleted: ((String) -> Void)? = nil
    var onTaskArchived: ((String) -> Void)? = nil
    var onOpenSession: ((Workspace, WorkspaceSessionSummary) -> Void)? = nil
    var onOpenTaskSession: ((Workspace, WorkspaceTask, WorkspaceSessionSummary) -> Void)? = nil
    var onRequestNewSession: ((Workspace, WorkspaceTask) -> Void)? = nil
    var onOpenParallel: ((Workspace, WorkspaceTask) -> Void)? = nil
    var onMergeAgentStarted: ((Workspace, SessionSnapshot) -> Void)? = nil
    var onWorkspaceDeleted: ((String) -> Void)? = nil
    var requestNewTask: Binding<Bool> = .constant(false)
    var employees: [SiliconEmployee] = []
    var teams: [ContactTeam] = []
    var onOpenTeamRun: ((String) -> Void)? = nil
    var onModalVisibilityChanged: ((Bool) -> Void)? = nil
    var onMutationBusyChanged: ((Bool) -> Void)? = nil

    @State private var renameTarget: WorkspaceTask?
    @State private var renameDraft = ""
    @State private var renameError: String?
    @State private var renameBusy = false
    @State private var pendingConfirm: TaskListConfirm?
    @State private var confirmBusy = false
    @State private var confirmError: String?
    @State private var newTaskSheetPresented = false
    @State private var newTaskSheetCwd = ""
    @State private var newTaskSheetWorkspaceId: String?
    @State private var collapsedTaskGroups = TaskListExpansionStorage.collapsedIds(kind: "groups")
    @State private var collapsedTaskIds = TaskListExpansionStorage.collapsedIds(kind: "tasks")
    @State private var collapsedLooseGroups = TaskListExpansionStorage.collapsedIds(kind: "loose")
    @State private var selectedTaskIds = Set<String>()
    @State private var selectedSessionIds = Set<String>()

    @State private var renameDirectoryTarget: TaskDirectoryGroup?
    @State private var renameDirectoryDraft = ""
    @State private var renameDirectoryError: String?
    @State private var archiveError: String?
    /// 收起/展开是位移类动效：系统减少动效时退化为瞬时（与 Theme 其它组件同一口径）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsedArchivedTaskIds = Set<String>()
    @State private var renameDirectoryBusy = false

    @State private var reviewTarget: Workspace?
    @State private var moveSessionTarget: WorkspaceSessionSummary?
    @State private var toastMessage: String?
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var attentionOnly = false
    @AppStorage("wand.homeFold.recent") private var recentFoldRaw = HomeFoldMode.expand.rawValue
    @AppStorage("wand.homeFold.workspaces") private var workspaceFoldRaw = HomeFoldMode.expand.rawValue
    @State private var temporaryExpandedRecent = Set<String>()
    @State private var temporaryExpandedWorkspaces = Set<String>()
    @State private var temporaryCollapsedTasks = Set<String>()
    @State private var temporaryCollapsedLoose = Set<String>()
    @State private var workspaceCreateExpanded = false
    @State private var workspaceCreateBusy = false
    @State private var terminalCreateExpanded = false
    @State private var terminalCreateCwd = ""
    @State private var terminalCreateBusy = false
    @State private var terminalCreateUnconfirmed = false
    @State private var terminalCreateError: String?
    @State private var collapsedArchivedLooseIds = Set<String>()

    var body: some View {
        dialogs
    }

    /// 弹窗单独成串：把 body 拆成几段小表达式，避免 Swift type checker 一次求解整条
    /// 修饰符链而超时（CI Xcode 26 曾报 WorkspaceListView.swift:170 unable to type-check
    /// this expression in reasonable time）。
    private var dialogs: some View {
        lifecycleEvents
            .alert("重命名任务", isPresented: renameTaskPresented) {
                renameTaskAlertContent
            } message: {
                if let renameError {
                    Text(renameError)
                } else {
                    Text("修改任务的显示名称。")
                }
            }
            .alert(confirmTitle, isPresented: confirmPresented) {
                Button("取消", role: .cancel) {
                    pendingConfirm = nil
                    confirmError = nil
                }
                Button(confirmBusy ? "处理中…" : confirmActionTitle, role: confirmIsDestructive ? .destructive : nil) {
                    // SwiftUI 在按钮动作返回后就把 isPresented 置 false，confirmPresented 的 setter
                    // 随即清空 pendingConfirm；异步工作要等下一轮才跑，再去读 pendingConfirm 只会拿到
                    // nil（旧的 performPendingConfirm 因此整个确认流程静默失败）。这里先捕获动作本体。
                    guard let confirm = pendingConfirm else { return }
                    Task { await performConfirm(confirm) }
                }
                .disabled(confirmBusy)
            } message: {
                Text(confirmMessage)
            }
    }

    /// 生命周期与状态同步回调。
    private var lifecycleEvents: some View {
        navigationChrome
            .task {
                store.startTaskGroupsSync()
                if case .idle = store.indexState {
                    await store.loadWorkspaceIndex()
                }
            }
            .onChange(of: selectedTaskId) { _, taskId in
                if let taskId { collapsedTaskIds.remove(taskId) }
            }
            .onChange(of: collapsedTaskGroups) { _, ids in
                TaskListExpansionStorage.setCollapsedIds(ids, kind: "groups")
            }
            .onChange(of: collapsedTaskIds) { _, ids in
                TaskListExpansionStorage.setCollapsedIds(ids, kind: "tasks")
            }
            .onChange(of: collapsedLooseGroups) { _, ids in
                TaskListExpansionStorage.setCollapsedIds(ids, kind: "loose")
            }
            .onChange(of: requestNewTask.wrappedValue) { _, requested in
                guard requested else { return }
                presentNewTaskSheet()
                requestNewTask.wrappedValue = false
            }
            .onChange(of: isSelecting) { _, selecting in
                if !selecting { clearManagedSelection() }
            }
            .onChange(of: recentFoldRaw) { _, _ in temporaryExpandedRecent.removeAll() }
            .onChange(of: workspaceFoldRaw) { _, _ in
                temporaryExpandedWorkspaces.removeAll()
                temporaryCollapsedTasks.removeAll()
                temporaryCollapsedLoose.removeAll()
            }
            .onChange(of: modalVisible, initial: true) { _, visible in onModalVisibilityChanged?(visible) }
            .onChange(of: creationBusy, initial: true) { _, busy in onMutationBusyChanged?(busy) }
    }

    /// 导航栏外观 + 工具栏 + 提示浮层。
    private var navigationChrome: some View {
        sheetContent
            .background(WandAmbientBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(hidesHomeChrome ? .hidden : .automatic, for: .navigationBar)
            .toolbar { navigationToolbar }
            .overlay(alignment: .top) { toastView }
            .animation(reduceMotion ? nil : WandMotion.stateSwap, value: toastMessage)
    }

    /// 工具栏内容独立成 builder：内联在 body 里时，嵌套的 if/else 加 Button label 闭包
    /// 会把整条链的推导成本叠到超过 type checker 预算。
    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        if !hidesHomeChrome {
            leadingToolbarItem
            trailingToolbarItems
        }
    }

    @ToolbarContentBuilder
    private var leadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if isSelecting {
                Button("完成") { endManagedSelection() }
            }
        }
    }

    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            trailingToolbarButtons
        }
    }

    @ViewBuilder
    private var trailingToolbarButtons: some View {
        if isSelecting {
            Button("归档所选") {
                requestManagedSelection()
            }
            .disabled(managedToolbarSelection.isEmpty)
            if !managedToolbarSelection.sessionIds.isEmpty {
                Button("删除终端", role: .destructive) {
                    presentConfirm(.deleteManaged(TaskListPresentation.ManageSelection(sessionIds: managedToolbarSelection.sessionIds)))
                }
            }
        } else {
            toolbarSelectionToggle
            toolbarNewTaskButton
        }
    }

    private var managedToolbarSelection: TaskListPresentation.ManageSelection {
        TaskListPresentation.pruneManagedSelection(
            TaskListPresentation.ManageSelection(
                taskIds: selectedTaskIds,
                sessionIds: selectedSessionIds
            ),
            groups: store.taskGroups
        )
    }

    private var toolbarSelectionToggle: some View {
        Button {
            beginManagedSelection()
        } label: {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.brand)
        }
        .accessibilityLabel("多选任务和终端")
    }

    private var toolbarNewTaskButton: some View {
        Button {
            presentNewTaskSheet()
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(Theme.brand)
        }
        .accessibilityLabel("新建任务")
    }

    private var sheetContent: some View {
        alertContent
            .sheet(item: $moveSessionTarget) { session in
                SessionMoveSheet(
                    store: store,
                    sessionId: session.id,
                    sessionTitle: sessionMoveTitle(session)
                ) {
                    showToast("已移动终端「\(sessionMoveTitle(session))」")
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $reviewTarget) { workspace in
                WorkspaceWorktreeReviewView(
                    workspace: workspace,
                    api: api,
                    store: store,
                    onMergeAgentStarted: { started in
                        onMergeAgentStarted?(workspace, started)
                    }
                )
            }
            .sheet(isPresented: $newTaskSheetPresented) {
                WorkspaceNewTaskSheet(api: api, store: store, initialCwd: newTaskSheetCwd, workspaceId: newTaskSheetWorkspaceId) { result in
                    let creation = result.creation
                    if let sessionError = result.sessionError {
                        showToast(sessionError)
                    } else if !creation.isIsolated, let worktreeError = creation.worktreeError {
                        showToast("已创建任务「\(creation.name)」：\(worktreeError)")
                    } else if result.session != nil {
                        showToast("已创建任务「\(creation.name)」并启动会话")
                    } else {
                        showToast("已创建任务「\(creation.name)」")
                    }
                    onOpenTask(result.workspace, WorkspaceTask(
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
                .presentationDetents([.medium, .large])
            }
    }

    private var alertContent: some View {
        stateContent
            .alert("重命名工作区", isPresented: renameDirectoryPresented) {
                renameDirectoryAlertContent
            } message: {
                if let renameDirectoryError {
                    Text(renameDirectoryError)
                } else {
                    Text("改的是工作区的显示名称，磁盘目录与已知会话都不变。")
                }
            }
            .alert("归档失败", isPresented: archiveErrorPresented) {
                Button("好", role: .cancel) { archiveError = nil }
            } message: {
                Text(archiveError ?? "")
            }
    }

    private var archiveErrorPresented: Binding<Bool> {
        Binding(
            get: { archiveError != nil },
            set: { presented in
                if !presented { archiveError = nil }
            }
        )
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.indexState {
        case .idle:
            loadingState
        case .loading:
            if store.workspaces.isEmpty { loadingState }
            else { workspaceContent }
        case .failed(let message):
            if store.workspaces.isEmpty { errorState(message) }
            else { workspaceContent }
        case .loaded:
            workspaceContent
        }
    }

    private var renameTaskPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    @ViewBuilder
    private var renameTaskAlertContent: some View {
        if let target = renameTarget {
            TextField("任务名称", text: $renameDraft)
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button(renameBusy ? "保存中…" : "保存") {
                guard !renameBusy else { return }
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 80 else {
                    renameError = "名称不能为空且不超过 80 字符"
                    return
                }
                renameBusy = true
                let workspaceId = target.workspaceId
                let taskId = target.id
                Task {
                    do {
                        let updated = try await store.renameWorkspaceTask(
                            workspaceId: workspaceId,
                            taskId: taskId,
                            name: trimmed
                        )
                        renameTarget = nil
                        renameBusy = false
                        onTaskRenamed?(updated)
                    } catch {
                        renameError = error.localizedDescription
                        renameBusy = false
                    }
                }
            }
            .disabled(renameBusy || renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var confirmPresented: Binding<Bool> {
        Binding(
            get: { pendingConfirm != nil },
            set: { if !$0 && !confirmBusy { pendingConfirm = nil; confirmError = nil } }
        )
    }

    private var confirmTitle: String {
        switch pendingConfirm {
        case .archiveTask: return "归档任务？"
        case .deleteTask: return "删除任务并清理 Worktree？"
        case .clearSessions: return "清空全部终端？"
        case .deleteSession: return "删除终端？"
        case .deleteWorkspace: return "删除工作区？"
        case .deleteManaged(let selection):
            return "\(TaskListPresentation.describeManagedAction(selection))？"
        case .archiveManaged: return "归档所选任务和会话？"
        case .none: return ""
        }
    }

    private var confirmActionTitle: String {
        switch pendingConfirm {
        case .archiveTask: return "确认归档"
        case .archiveManaged: return "确认归档"
        case .clearSessions: return "确认清空"
        case .deleteManaged(let selection):
            return "确认\(TaskListPresentation.describeManagedAction(selection))"
        default: return "删除"
        }
    }

    /// 纯归档不该渲染成红色破坏性操作（对齐 web 端 managedSelectionIsDestructive）。
    private var confirmIsDestructive: Bool {
        switch pendingConfirm {
        case .archiveTask, .archiveManaged: return false
        case .deleteManaged(let selection):
            return TaskListPresentation.managedSelectionIsDestructive(selection)
        default: return true
        }
    }

    private var confirmMessage: String {
        if let confirmError { return confirmError }
        switch pendingConfirm {
        case .archiveTask(let task):
            return "「\(task.name)」会从侧栏隐藏并移入任务看板的归档任务，终端继续运行、Worktree 保留。"
        case .deleteTask(let task):
            return "任务「\(task.name)」及其会话和独立 worktree 将被删除，此操作无法撤销。"
        case .clearSessions(let task):
            return "将结束并删除「\(task.name)」的 \(task.listedSessionCount) 个终端，此操作无法撤销。"
        case .deleteSession(let session):
            return "终端「\(sessionDeleteLabel(session))」会结束并被删除，此操作无法撤销。"
        case .deleteWorkspace(let workspace):
            return "工作区「\(workspace.name)」及其任务、会话与独立 worktree 将被删除，此操作无法撤销。"
        case .deleteManaged(let selection):
            if selection.taskIds.isEmpty {
                return "将结束所选终端，此操作无法撤销。"
            }
            if selection.sessionIds.isEmpty {
                return "所选任务会从侧栏隐藏并移入看板归档，终端与 Worktree 都保留。"
            }
            return "所选任务会移入看板归档（终端与 Worktree 保留），同时结束所选终端。"
        case .archiveManaged:
            return "所选任务移入看板归档，所选会话收进已归档区。终端继续运行，历史与 Worktree 都保留。"
        case .none:
            return ""
        }
    }

    /// 左滑收起动画和 alert 抢同一帧时，确认框会被直接吞掉。
    private func presentAfterSwipe(_ action: @escaping () -> Void) {
        renameTarget = nil
        renameDirectoryTarget = nil
        pendingConfirm = nil
        confirmError = nil
        DispatchQueue.main.async(execute: action)
    }

    private func presentConfirm(_ confirm: TaskListConfirm) {
        presentAfterSwipe { pendingConfirm = confirm }
    }

    private var renameDirectoryPresented: Binding<Bool> {
        Binding(
            get: { renameDirectoryTarget != nil },
            set: { if !$0 { renameDirectoryTarget = nil } }
        )
    }

    /// 目录组改名：合成目录走 session-directories（改的是该 cwd 的显示名），
    /// 真实工作区走 PATCH /api/workspaces/:id；全局组不参与改名（对齐 web 的 canRenameDirectory）。
    private func submitDirectoryRename(_ target: TaskDirectoryGroup) {
        guard !renameDirectoryBusy else { return }
        let trimmed = renameDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameDirectoryError = "名称不能为空"
            return
        }
        guard trimmed != target.workspaceName else {
            renameDirectoryTarget = nil
            return
        }
        renameDirectoryBusy = true
        Task {
            do {
                if target.isSynthetic {
                    try await store.renameDirectory(cwd: target.workspaceCwd, name: trimmed)
                } else {
                    _ = try await store.renameWorkspace(workspaceId: target.workspaceId, name: trimmed)
                }
                renameDirectoryTarget = nil
                renameDirectoryBusy = false
                showToast("已将工作区重命名为「\(trimmed)」")
            } catch {
                renameDirectoryError = error.localizedDescription
                renameDirectoryBusy = false
            }
        }
    }

    @ViewBuilder
    private var renameDirectoryAlertContent: some View {
        if let target = renameDirectoryTarget {
            TextField("工作区名称", text: $renameDirectoryDraft)
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) { renameDirectoryTarget = nil }
            Button(renameDirectoryBusy ? "保存中…" : "保存") { submitDirectoryRename(target) }
                .disabled(
                    renameDirectoryBusy
                        || renameDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        taskGroupsList
    }

    /// 任务一级视图：GET /api/tasks 聚合，目录组为一级容器，未分组会话不丢失。
    private var taskGroupsList: some View {
        List {
            if !isSelecting { homeSearchAndActivity }
            if store.taskGroupsLoading && store.taskGroups.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载任务…")
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .listRowSeparator(.hidden)
            }
            if let error = store.taskGroupsError, store.taskGroups.isEmpty {
                inlineError(error)
            }
            let visible = HomePresentation.visibleGroups(
                TaskListPresentation.orderedDirectoryGroups(store.taskGroups),
                query: searchQuery, attentionOnly: attentionOnly)
            if hidesHomeChrome && isSelecting {
                homeManageBar(visible: visible)
            }
            if !isSelecting {
                HomeSectionHeader(title: "最近对话", foldRaw: $recentFoldRaw)
                recentConversationRows(visible)
                HomeSectionHeader(title: "任务与工作区", foldRaw: $workspaceFoldRaw, onCreate: {
                    guard !workspaceCreateBusy else { return }
                    withAnimation(reduceMotion ? nil : WandMotion.stateSwap) {
                        workspaceCreateExpanded.toggle()
                    }
                }, creatingExpanded: workspaceCreateExpanded, disabled: workspaceCreateBusy)
                if workspaceCreateExpanded {
                    WorkspaceCreatePanel(api: api, store: store, onCreated: { workspace in
                        workspaceCreateExpanded = false
                        showToast("已创建工作区「\(workspace.name)」")
                    }, onBusy: { workspaceCreateBusy = $0 })
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
            }
            if visible.isEmpty && store.taskGroupsError == nil && !store.taskGroupsLoading {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.brand)
                    Text(searchQuery.isEmpty && !attentionOnly ? "还没有任务" : "没有匹配的会话")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(searchQuery.isEmpty && !attentionOnly ? "新建任务时选目录，之后在任务里建会话无需再选目录。" : "清空搜索或取消「等你」筛选可显示其他内容。")
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        presentNewTaskSheet()
                    } label: {
                        Label("新建任务", systemImage: "plus")
                            .frame(maxWidth: 220)
                    }
                    .buttonStyle(WandPrimaryButtonStyle())
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .listRowSeparator(.hidden)
            }
            ForEach(visible) { group in
                taskGroupSection(group)
                    .disabled(creationBusy)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await store.loadTaskGroups(force: true)
            await store.loadWorkspaceIndex()
        }
    }

    private var workspaceFold: HomeFoldMode {
        isSelecting ? .expand : (HomeFoldMode(rawValue: workspaceFoldRaw) ?? .expand)
    }

    private var modalVisible: Bool {
        newTaskSheetPresented || reviewTarget != nil || moveSessionTarget != nil
            || renameTarget != nil || renameDirectoryTarget != nil || pendingConfirm != nil
    }

    private var creationBusy: Bool { workspaceCreateBusy || terminalCreateBusy || terminalCreateUnconfirmed }

    private var homeSearchAndActivity: some View {
        let counts = HomePresentation.counts(store.taskGroups)
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.textMuted)
                TextField("搜索对话、员工、任务或目录", text: $searchQuery)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("搜索对话、员工、任务或目录")
                Button { searchQuery = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textMuted)
                        .opacity(searchQuery.isEmpty ? 0 : 1).frame(width: 32, height: 32)
                }.buttonStyle(.plain).disabled(searchQuery.isEmpty).accessibilityLabel("清空搜索")
            }
            .padding(.horizontal, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            if counts.running > 0 || counts.needsYou > 0 || attentionOnly {
                HStack(spacing: 12) {
                    Label("在跑 \(counts.running)", systemImage: "bolt.fill")
                        .foregroundColor(Theme.success)
                    Spacer(minLength: 4)
                    Button {
                        attentionOnly.toggle()
                        if attentionOnly { recentFoldRaw = "expand"; workspaceFoldRaw = "expand" }
                    } label: {
                        Label("等你 \(counts.needsYou)", systemImage: attentionOnly ? "checkmark.circle.fill" : "hand.raised")
                            .foregroundColor(attentionOnly ? Theme.brand : Theme.textSecondary)
                    }.buttonStyle(.plain).accessibilityLabel(attentionOnly ? "取消只看等你" : "只看等你处理的会话")
                }.font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private func recentConversationRows(_ visible: [TaskDirectoryGroup]) -> some View {
        let groups = HomePresentation.recentGroups(store.taskGroups, employees: employees, teams: teams)
        let fold = HomeFoldMode(rawValue: recentFoldRaw) ?? .expand
        ForEach(groups) { group in
            let titleMatches = HomePresentation.matches(searchQuery, [group.title])
            let matching = group.conversations.filter {
                (titleMatches || HomePresentation.matches(searchQuery, HomePresentation.sessionFields($0.session)
                    + [$0.task?.name, $0.group.workspaceName, $0.group.workspaceCwd]))
                && (!attentionOnly || HomePresentation.pulse($0.session) == .needsYou)
            }
            let groupFold = HomePresentation.recentGroupFold(
                fold,
                temporarilyExpanded: temporaryExpandedRecent.contains(group.id)
            )
            let shown = groupFold == .running ? matching.filter { HomePresentation.isActive($0.session) } : matching
            let showsHeader = HomePresentation.recentGroupShowsHeader(
                group,
                sectionFold: fold,
                visibleConversationCount: shown.count
            )
            let expanded = HomePresentation.recentGroupExpandsContent(
                groupFold,
                visibleConversationCount: shown.count
            )
            if !matching.isEmpty || (group.kind == .blankTerminal && searchQuery.isEmpty && !attentionOnly) {
                if !showsHeader, let item = shown.first {
                    recentConversationRow(item, index: 0, secondary: false)
                        .listRowBackground(Theme.background)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                } else {
                    HomeRecentGroupHeader(
                        group: group,
                        expanded: expanded,
                        onToggle: fold == .expand || group.conversations.isEmpty ? nil : {
                            withAnimation(reduceMotion ? nil : WandMotion.stateSwap) {
                                if temporaryExpandedRecent.contains(group.id) {
                                    temporaryExpandedRecent.remove(group.id)
                                } else {
                                    temporaryExpandedRecent.insert(group.id)
                                }
                            }
                        },
                        onCreate: group.kind == .blankTerminal ? {
                            guard !terminalCreateBusy else { return }
                            withAnimation(reduceMotion ? nil : WandMotion.stateSwap) { terminalCreateExpanded.toggle() }
                        } : nil
                    )
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                    .disabled(creationBusy)
                    if group.kind == .blankTerminal && terminalCreateExpanded { terminalCreatePanel }
                    if expanded {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            recentConversationRow(item, index: index, secondary: true)
                                .disabled(creationBusy)
                                .listRowBackground(Theme.background)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 1, leading: 28, bottom: 1, trailing: 12))
                        }
                        if shown.isEmpty && !matching.isEmpty && groupFold == .running {
                            Text("暂无在跑或待查看的会话").font(.caption).foregroundColor(Theme.textMuted)
                                .listRowSeparator(.hidden).listRowBackground(Theme.background)
                        }
                    }
                }
            }
        }
    }

    private func recentConversationRow(
        _ item: HomeRecentConversation,
        index: Int,
        secondary: Bool
    ) -> some View {
        let employee = employees.first { $0.id == item.session.employeeId }
        let directEmployee = !secondary && item.session.employeeId != nil
        let conversationTitle = item.session.teamStep?.title ?? TaskListPresentation.listSessionLabel(
            title: item.session.title, providerLabel: item.session.providerLabel, cwd: item.session.cwd, index: index)
        return Button {
            searchFocused = false
            if let chat = item.session.teamChat, let onOpenTeamRun { onOpenTeamRun(chat.runId) }
            else if let task = item.task {
                onOpenTaskSession?(workspace(for: task, group: item.group), task.asTask(), item.session)
            } else { onOpenSession?(workspace(from: item.group), item.session) }
        } label: {
            HStack(spacing: 9) {
                recentConversationLeading(item, secondary: secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(directEmployee ? employee?.name ?? item.session.employeeName ?? "员工" : conversationTitle)
                        .font(.system(size: 14, weight: .medium)).foregroundColor(Theme.textPrimary)
                        .lineLimit(secondary ? 1 : 2)
                    if !secondary {
                        Text([directEmployee ? conversationTitle : nil, item.task?.name, item.session.teamStep?.teamName, item.group.isGlobal ? nil : item.group.workspaceName]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundColor(Theme.textMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(item.session.isJustCompleted ? "刚完成" : HomePresentation.statusLabel(item.session.activityStatus))
                    .font(.system(size: 11)).foregroundColor(item.session.isJustCompleted ? Theme.brand : Theme.textSecondary)
            }.padding(.vertical, 7)
        }.buttonStyle(.plain)
        .contextMenu {
            Button { Task { await toggleArchive(item.session) } } label: { Label("归档会话", systemImage: "archivebox") }
            Button { moveSessionTarget = item.session } label: { Label("移动到任务", systemImage: "folder") }
            Button(role: .destructive) { presentConfirm(.deleteSession(item.session)) } label: { Label("删除会话", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func recentConversationLeading(_ item: HomeRecentConversation, secondary: Bool) -> some View {
        if !secondary, let employeeId = item.session.employeeId {
            let employee = employees.first { $0.id == employeeId }
            ContactAvatar(
                id: employeeId,
                avatar: employee?.avatar ?? item.session.employeeAvatar ?? "",
                systemKey: employee?.systemKey,
                size: 28
            )
        } else if secondary, item.session.employeeId != nil {
            BrandLogo(provider: item.session.provider ?? "terminal", color: Theme.brand)
                .frame(width: 17, height: 17)
        } else if !secondary, item.session.teamChat != nil {
            Image(systemName: "person.3.fill")
                .foregroundColor(Theme.brand)
                .frame(width: 28, height: 28)
                .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 8))
        } else {
            BrandLogo(provider: item.session.provider ?? "terminal", color: Theme.brand)
                .frame(width: secondary ? 17 : 28, height: secondary ? 17 : 28)
        }
    }

    private var terminalCreatePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("终端工作目录", text: $terminalCreateCwd).textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if let error = terminalCreateError { Text(error).font(.footnote).foregroundColor(Theme.danger) }
            if terminalCreateUnconfirmed {
                Button("刷新列表核对") { Task { await store.loadTaskGroups(force: true) } }
                    .buttonStyle(WandSecondaryButtonStyle())
                Button("我已核对，允许重新创建") { terminalCreateUnconfirmed = false; terminalCreateError = nil }
                    .font(.footnote).foregroundColor(Theme.brand)
            } else {
                Button(terminalCreateBusy ? "正在创建…" : "创建空白终端") { Task { await createBlankTerminal() } }
                    .buttonStyle(WandPrimaryButtonStyle())
                    .disabled(normalizeWorkspaceDirectory(terminalCreateCwd).isEmpty)
            }
        }.disabled(terminalCreateBusy).padding(.vertical, 10)
        .listRowBackground(Theme.background).listRowSeparator(.hidden)
        .task {
            if terminalCreateCwd.isEmpty, let config = try? await api.serverConfig() {
                guard terminalCreateCwd.isEmpty, !terminalCreateBusy, !terminalCreateUnconfirmed, !Task.isCancelled else { return }
                terminalCreateCwd = config.defaultCwd ?? ""
            }
        }
    }

    private func createBlankTerminal() async {
        guard !terminalCreateBusy, !terminalCreateUnconfirmed else { return }
        let cwd = normalizeWorkspaceDirectory(terminalCreateCwd)
        guard !cwd.isEmpty else { return }
        terminalCreateBusy = true; terminalCreateError = nil
        defer { terminalCreateBusy = false }
        do {
            let snapshot = try await api.createShellSession(cwd: cwd)
            guard !snapshot.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  snapshot.sessionKind == "pty" else {
                throw WandAPI.APIError.network("终端创建回执不完整，请刷新核对，勿重复创建。")
            }
            await store.loadTaskGroups(force: true)
            terminalCreateExpanded = false
            let workspace = store.workspaces.first { normalizeWorkspaceDirectory($0.cwd) == cwd }
                ?? Workspace(id: "", name: "空白终端", cwd: cwd, defaultProvider: nil, layout: nil, createdAt: "", lastOpenedAt: nil)
            onOpenSession?(workspace, WorkspaceSessionSummary(snapshot: snapshot))
        } catch {
            terminalCreateUnconfirmed = !isDefiniteInputRejection(error)
            terminalCreateError = terminalCreateUnconfirmed ? "创建结果未确认，请先刷新核对，勿重复创建。" : error.localizedDescription
        }
    }

    @ViewBuilder private func archivedLooseSessions(_ sessions: [WorkspaceSessionSummary], group: TaskDirectoryGroup) -> some View {
        let expanded = collapsedArchivedLooseIds.contains(group.id)
        Button {
            withAnimation(reduceMotion ? nil : WandMotion.stateSwap) {
                if expanded { collapsedArchivedLooseIds.remove(group.id) } else { collapsedArchivedLooseIds.insert(group.id) }
            }
        } label: {
            Label("已归档会话 \(sessions.count)", systemImage: "archivebox")
                .font(.footnote).foregroundColor(Theme.textMuted)
        }.buttonStyle(.plain).listRowSeparator(.hidden).listRowBackground(Theme.background)
        if expanded {
            ForEach(sessions) { session in
                standaloneSessionRow(session, workspace: workspace(from: group))
                    .listRowSeparator(.hidden).listRowBackground(Theme.background)
            }
        }
    }

    private func homeManageBar(visible: [TaskDirectoryGroup]) -> some View {
        let all = TaskListPresentation.collectManagedIds(visible)
        let selection = TaskListPresentation.ManageSelection(
            taskIds: selectedTaskIds,
            sessionIds: selectedSessionIds
        )
        let resolved = TaskListPresentation.pruneManagedSelection(selection, groups: store.taskGroups)
        let allOn = !resolved.isEmpty
            && selectedTaskIds.count == all.taskIds.count
            && selectedSessionIds.count == all.sessionIds.count
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
            Button(allOn ? "取消全选" : "全选") {
                if allOn {
                    clearManagedSelection()
                } else {
                    selectedTaskIds = all.taskIds
                    selectedSessionIds = all.sessionIds
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.brand)
            Text(resolved.isEmpty ? "选择任务或终端" : "已选 \(resolved.count)")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
            Spacer(minLength: 8)
            Button("完成") { endManagedSelection() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            }
            HStack(spacing: 16) {
            Button("归档所选") {
                requestManagedSelection()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.brand)
            .disabled(resolved.isEmpty)
            if !resolved.sessionIds.isEmpty {
                Button("删除终端", role: .destructive) {
                    presentConfirm(.deleteManaged(TaskListPresentation.ManageSelection(sessionIds: resolved.sessionIds)))
                }.font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }

    private func requestManagedSelection() {
        let selection = TaskListPresentation.ManageSelection(
            taskIds: selectedTaskIds,
            sessionIds: selectedSessionIds
        )
        let resolved = TaskListPresentation.pruneManagedSelection(
            selection,
            groups: store.taskGroups
        )
        if !resolved.isEmpty {
            presentConfirm(.archiveManaged(resolved))
        }
    }

    private func presentNewTaskSheet(cwd: String = "", workspaceId: String? = nil) {
        newTaskSheetCwd = cwd
        newTaskSheetWorkspaceId = workspaceId
        newTaskSheetPresented = true
    }

    private func beginManagedSelection() {
        isSelecting = true
        clearManagedSelection()
    }

    private func endManagedSelection() {
        isSelecting = false
        clearManagedSelection()
    }

    private func clearManagedSelection() {
        selectedTaskIds.removeAll()
        selectedSessionIds.removeAll()
    }

    @ViewBuilder
    private func taskGroupSection(_ group: TaskDirectoryGroup) -> some View {
        let fold = HomePresentation.recentGroupFold(workspaceFold,
            temporarilyExpanded: temporaryExpandedWorkspaces.contains(group.id))
        let expanded = isSelecting || (fold != .collapse &&
            (temporaryExpandedWorkspaces.contains(group.id) || !collapsedTaskGroups.contains(group.id)))
        taskGroupHeader(group, expanded: expanded)
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
        if expanded {
            ForEach(TaskListPresentation.orderedTaskSummaries(group.tasks).filter {
                fold != .running || !HomePresentation.sessions($0.sessions, fold: .running).isEmpty
            }) { summary in
                taskRows(summary, group: group, fold: fold)
            }
            if group.tasks.isEmpty && group.standaloneSessions.isEmpty {
                Text("这个目录还没有任务。")
                    .font(.footnote)
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 10)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            }
            if !group.standaloneSessions.isEmpty {
                standaloneSessionSection(group, fold: fold)
            }
        }
    }

    @ViewBuilder
    private func standaloneSessionSection(_ group: TaskDirectoryGroup, fold: HomeFoldMode) -> some View {
        let expanded = !(temporaryExpandedWorkspaces.contains(group.id)
            ? temporaryCollapsedLoose.contains(group.id) : collapsedLooseGroups.contains(group.id))
        Button {
            toggleCollapsedLooseGroup(group.id)
        } label: {
            HStack {
                Text("未分组会话（\(group.standaloneSessions.count)）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                Spacer(minLength: 6)
                treeDisclosureCaret(expanded: expanded)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起未分组会话" : "展开未分组会话")
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
        if expanded {
            let split = WorkspaceSessionSummary.splitArchived(HomePresentation.sessions(group.standaloneSessions, fold: fold))
            ForEach(split.active) { session in
                standaloneSessionRow(session, workspace: workspace(from: group))
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            }
            if !attentionOnly && fold != .running && !split.archived.isEmpty {
                archivedLooseSessions(split.archived, group: group)
            }
        }
    }

    private func taskGroupHeader(_ group: TaskDirectoryGroup, expanded: Bool) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Button {
                toggleCollapsedTaskGroup(group.id)
            } label: {
              HStack(spacing: 9) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.brand)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brandSoft)
                )
            HStack(spacing: 7) {
                Text(group.workspaceName.isEmpty ? "任务目录" : group.workspaceName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if TaskListPresentation.hasLiveActivity(group) {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 7, height: 7)
                }
            }
            Spacer(minLength: 6)
            treeDisclosureCaret(expanded: expanded)
              }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起目录" : "展开目录")
            if group.tasks.contains(where: { $0.worktree != nil }) {
                worktreeBadge(workspace(from: group))
            }
            Button {
                presentNewTaskSheet(
                    cwd: group.workspaceCwd,
                    workspaceId: group.isBindableProject ? group.workspaceId : nil
                )
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.brandSoft))
            }
            .buttonStyle(.plain)
            .disabled(isSelecting)
            .opacity(isSelecting ? 0.35 : 1)
            .accessibilityLabel("在 \(group.workspaceName) 新建任务")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目录 \(group.workspaceName)，\(group.tasks.count) 个任务")
        .contextMenu {
            // 全局（未归属）组不参与改名，合成目录与真实工作区走各自接口；删除只留给真实工作区。
            if !group.isGlobal {
                Button {
                    renameDirectoryDraft = group.workspaceName
                    renameDirectoryError = nil
                    renameDirectoryTarget = group
                } label: {
                    Label("重命名工作区", systemImage: "pencil")
                }
            }
            if group.isBindableProject {
                Button(role: .destructive) {
                    presentConfirm(.deleteWorkspace(workspace(from: group)))
                } label: {
                    Label("删除工作区", systemImage: "trash")
                }
            }
        }
    }

    private func treeDisclosureCaret(expanded: Bool) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Theme.textMuted)
            .rotationEffect(.degrees(expanded ? 0 : -90))
            .frame(width: 18, height: 22)
    }

    private func toggleCollapsedTaskGroup(_ id: String) {
        withAnimation(reduceMotion ? nil : WandMotion.stateSwap) {
            if workspaceFold != .expand && !isSelecting {
                if temporaryExpandedWorkspaces.contains(id) { temporaryExpandedWorkspaces.remove(id) }
                else { temporaryExpandedWorkspaces.insert(id) }
                temporaryCollapsedLoose.remove(id)
                for task in store.taskGroups.first(where: { $0.id == id })?.tasks ?? [] {
                    temporaryCollapsedTasks.remove(task.id)
                }
                return
            }
            if collapsedTaskGroups.contains(id) {
                collapsedTaskGroups.remove(id)
            } else {
                collapsedTaskGroups.insert(id)
            }
        }
    }

    private func taskIsCollapsed(_ id: String, in groupId: String) -> Bool {
        temporaryExpandedWorkspaces.contains(groupId)
            ? temporaryCollapsedTasks.contains(id) : collapsedTaskIds.contains(id)
    }

    private func toggleCollapsedTask(_ id: String) {
        if store.taskGroups.contains(where: {
            temporaryExpandedWorkspaces.contains($0.id) && $0.tasks.contains(where: { $0.id == id })
        }) {
            if temporaryCollapsedTasks.contains(id) { temporaryCollapsedTasks.remove(id) }
            else { temporaryCollapsedTasks.insert(id) }
            return
        }
        if collapsedTaskIds.contains(id) {
            collapsedTaskIds.remove(id)
        } else {
            collapsedTaskIds.insert(id)
        }
    }

    private func toggleCollapsedLooseGroup(_ id: String) {
        if temporaryExpandedWorkspaces.contains(id) {
            if temporaryCollapsedLoose.contains(id) { temporaryCollapsedLoose.remove(id) }
            else { temporaryCollapsedLoose.insert(id) }
            return
        }
        if collapsedLooseGroups.contains(id) {
            collapsedLooseGroups.remove(id)
        } else {
            collapsedLooseGroups.insert(id)
        }
    }

    @ViewBuilder
    private func taskRows(_ summary: WorkspaceTaskSummary, group: TaskDirectoryGroup, fold: HomeFoldMode) -> some View {
        let expanded = (isSelecting || fold != .collapse) && TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: taskIsCollapsed(summary.id, in: group.id),
            sessionCount: summary.listedSessionCount,
            isOnlyTask: group.tasks.count == 1
        )
        let workspace = workspace(for: summary, group: group)
        taskSummaryRow(summary, group: group)
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 12))
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
            .opacity(summary.status == "done" ? 0.76 : 1)

        if expanded {
            // 归档项从活跃列表拆出去，收进本层自己的折叠区（分一次，不在渲染处过滤）。
            let split = WorkspaceSessionSummary.splitArchived(HomePresentation.sessions(summary.sessions, fold: fold))
            if split.active.isEmpty && split.archived.isEmpty {
                Text("还没有终端。点右侧「＋」新建。")
                    .font(.footnote)
                    .foregroundColor(Theme.textMuted)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(Array(split.active.enumerated()), id: \.element.id) { index, session in
                    taskOwnedSessionRow(session, summary: summary, workspace: workspace, index: index)
                        .listRowInsets(EdgeInsets(top: 1, leading: 28, bottom: 1, trailing: 12))
                        .listRowBackground(Theme.background)
                        .listRowSeparator(.hidden)
                }
                if summary.listedSessionCount > summary.sessions.count {
                    Text("列表仅显示 \(summary.sessions.count)/\(summary.listedSessionCount) 个会话，打开任务可查看全部。")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                        .padding(.leading, 8)
                        .padding(.vertical, 6)
                        .listRowBackground(Theme.background)
                        .listRowSeparator(.hidden)
                }
                if !attentionOnly && fold != .running {
                    archivedSessionsFold(split.archived, summary: summary, workspace: workspace)
                }
            }
        }
    }

    private func taskSummaryRow(_ summary: WorkspaceTaskSummary, group: TaskDirectoryGroup) -> some View {
        let selected = selectedTaskId == summary.id
        let canCollapseSessions = TaskListPresentation.showsTaskSessionDisclosure(sessionCount: summary.listedSessionCount)
        let expanded = TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: taskIsCollapsed(summary.id, in: group.id),
            sessionCount: summary.listedSessionCount,
            isOnlyTask: group.tasks.count == 1
        )
        let workspace = workspace(for: summary, group: group)
        let task = summary.asTask()
        return HStack(spacing: 8) {
            taskSummaryTitle(summary, workspace: workspace, task: task)

            if summary.status == "done" {
                Text("已完成")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .padding(.trailing, 4)
            }

            if canCollapseSessions {
                taskSummaryDisclosureButton(summary, expanded: expanded)
            }

            taskSummaryNewSessionButton(summary, workspace: workspace, task: task)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((isSelecting ? selectedTaskIds.contains(summary.id) : selected) ? Theme.brandSoft : Color.clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("任务 \(summary.name)")
        .accessibilityAddTraits(.isButton)
        .contextMenu { taskSummaryContextMenu(summary, workspace: workspace, task: task) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            taskSummarySwipeActions(summary, task: task)
        }
    }

    /// 任务名与多选勾选、点击行为单独成体：整行内联时这一个表达式就会占满 type
    /// checker 预算（本地实测 137–145ms，CI 更慢）。
    @ViewBuilder
    private func taskSummaryTitle(
        _ summary: WorkspaceTaskSummary,
        workspace: Workspace,
        task: WorkspaceTask
    ) -> some View {
        let selected = selectedTaskId == summary.id
        let isSelected = selectedTaskIds.contains(summary.id)
        HStack(spacing: 8) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.brand : Theme.textMuted)
                    .frame(width: 22, height: 22)
            } else if summary.isIsolated {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.success)
                    .frame(width: 14, height: 18)
            }
            Text(summary.name)
                .font(.system(size: 15, weight: selected || (isSelecting && isSelected) ? .semibold : .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggleSelectedTask(summary.id)
                return
            }
            collapsedTaskIds.remove(summary.id)
            onOpenTask(workspace, task)
        }
    }

    private func toggleSelectedTask(_ taskId: String) {
        if selectedTaskIds.contains(taskId) {
            selectedTaskIds.remove(taskId)
        } else {
            selectedTaskIds.insert(taskId)
        }
    }

    private func taskSummaryDisclosureButton(_ summary: WorkspaceTaskSummary, expanded: Bool) -> some View {
        Button {
            toggleCollapsedTask(summary.id)
        } label: {
            HStack(spacing: 2) {
                Text("\(summary.listedSessionCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
                treeDisclosureCaret(expanded: expanded)
            }
        }
        .buttonStyle(.plain)
        .disabled(isSelecting)
        .accessibilityLabel(expanded ? "收起终端" : "展开终端")
    }

    private func taskSummaryNewSessionButton(
        _ summary: WorkspaceTaskSummary,
        workspace: Workspace,
        task: WorkspaceTask
    ) -> some View {
        Button {
            collapsedTaskIds.remove(summary.id)
            onRequestNewSession?(workspace, task)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.brand)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(isSelecting)
        .opacity(isSelecting ? 0.35 : 1)
        .accessibilityLabel("在任务 \(summary.name) 中新建终端")
    }

    @ViewBuilder
    private func taskSummaryContextMenu(
        _ summary: WorkspaceTaskSummary,
        workspace: Workspace,
        task: WorkspaceTask
    ) -> some View {
        Button {
            collapsedTaskIds.remove(summary.id)
            onOpenTask(workspace, task)
        } label: {
            Label("打开任务", systemImage: "arrow.forward")
        }
        Button {
            collapsedTaskIds.remove(summary.id)
            onRequestNewSession?(workspace, task)
        } label: {
            Label("新建终端", systemImage: "plus")
        }
        Button {
            presentAfterSwipe {
                renameDraft = summary.name
                renameError = nil
                renameTarget = task
            }
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        if summary.listedSessionCount > 0 {
            Button(role: .destructive) {
                presentConfirm(.clearSessions(summary))
            } label: {
                Label("清空会话(\(summary.listedSessionCount))", systemImage: "trash.slash")
            }
        }
        if onOpenParallel != nil {
            Button {
                onOpenParallel?(workspace, task)
            } label: {
                Label("并行任务", systemImage: "square.stack.3d.up")
            }
        }
        Button {
            presentAfterSwipe { pendingConfirm = .archiveTask(task) }
        } label: {
            Label(summary.isIsolated ? "归档任务（保留 Worktree）" : "归档任务", systemImage: "archivebox")
        }
        // 归档是软删除；只有隔离任务才真删并清理 worktree（对齐 web 端）。
        if summary.isIsolated {
            Button(role: .destructive) {
                presentConfirm(.deleteTask(task))
            } label: {
                Label("删除任务并清理 Worktree", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func taskSummarySwipeActions(_ summary: WorkspaceTaskSummary, task: WorkspaceTask) -> some View {
        Button {
            presentConfirm(.archiveTask(task))
        } label: {
            Label("归档", systemImage: "archivebox")
        }
        .tint(Theme.brand)
        if summary.listedSessionCount > 0 {
            Button {
                presentConfirm(.clearSessions(summary))
            } label: {
                Label("清空", systemImage: "trash")
            }
            .tint(Theme.warning)
        }
    }

    private func taskOwnedSessionRow(
        _ session: WorkspaceSessionSummary,
        summary: WorkspaceTaskSummary,
        workspace: Workspace,
        index: Int
    ) -> some View {
        let selected = selectedSessionId == session.id
        let label = TaskListPresentation.listSessionLabel(
            title: session.title,
            providerLabel: session.providerLabel,
            cwd: session.cwd,
            index: index
        )
        return HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: selectedSessionIds.contains(session.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(selectedSessionIds.contains(session.id) ? Theme.brand : Theme.textMuted)
                    .frame(width: 22, height: 22)
            }
            BrandLogo(provider: session.provider ?? "terminal", color: selected ? Theme.brand : Theme.textSecondary)
                .frame(width: 14, height: 14)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if session.sessionKind == "pty" {
                    Text("终端")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer(minLength: 0)
            if session.isJustCompleted {
                // 完成但还没被明确打开看过；纯展示态，不改 runner 生命周期。
                Text("刚完成")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.success)
                    .help("已完成，还没查看")
                    .accessibilityLabel("刚完成，还没查看")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.brand.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                if selectedSessionIds.contains(session.id) {
                    selectedSessionIds.remove(session.id)
                } else {
                    selectedSessionIds.insert(session.id)
                }
                return
            }
            onOpenTaskSession?(workspace, summary.asTask(), session)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("会话 \(label)")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button {
                moveSessionTarget = session
            } label: {
                Label("移动到任务", systemImage: "folder")
            }
            Button {
                Task { await toggleArchive(session) }
            } label: {
                Label(
                    session.archived == true ? "恢复会话" : "归档会话",
                    systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox"
                )
            }
            Button(role: .destructive) {
                requestDeleteSession(session)
            } label: {
                Label("删除终端", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestDeleteSession(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 每层自己的「已归档会话」折叠区：归档不杀进程也不删历史，
    /// 收起只是不再占用活跃列表的视线，展开后每条仍可原位恢复。
    @ViewBuilder
    private func archivedSessionsFold(
        _ archived: [WorkspaceSessionSummary],
        summary: WorkspaceTaskSummary,
        workspace: Workspace
    ) -> some View {
        if !archived.isEmpty {
            let open = collapsedArchivedTaskIds.contains(summary.id)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if open { collapsedArchivedTaskIds.remove(summary.id) }
                    else { collapsedArchivedTaskIds.insert(summary.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox").font(.system(size: 11))
                        Text("已归档会话 \(archived.count)").font(.footnote.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(Theme.textMuted)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("已归档会话 \(archived.count) 个，\(open ? "已展开" : "已收起")")

                if open {
                    ForEach(Array(archived.enumerated()), id: \.element.id) { _, session in
                        taskOwnedSessionRow(session, summary: summary, workspace: workspace, index: 0)
                    }
                }
            }
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
            .animation(reduceMotion ? nil : WandMotion.stateSwap,
                       value: collapsedArchivedTaskIds)
        }
    }

    /// 归档 / 恢复。归档是软标记：不杀进程、不删历史，也不改任务归属。
    /// 失败只提示、不改本地状态，避免「界面显示已归档但服务端没改」。
    private func toggleArchive(_ session: WorkspaceSessionSummary) async {
        let target = !(session.archived == true)
        do {
            try await store.archiveSession(session.id, archived: target)
        } catch {
            archiveError = "无法\(target ? "归档" : "恢复")会话：\(error.localizedDescription)"
        }
    }

    private func requestDeleteSession(_ session: WorkspaceSessionSummary) {
        presentConfirm(.deleteSession(session))
    }

    /// 移动会话行内与 sheet 标题共用同一个名字：优先原生标题，否则用 provider + 序号。
    private func sessionMoveTitle(_ session: WorkspaceSessionSummary) -> String {
        TaskListPresentation.listSessionLabel(
            title: session.title,
            providerLabel: session.providerLabel,
            cwd: session.cwd,
            index: 0
        )
    }

    private func sessionDeleteLabel(_ session: WorkspaceSessionSummary) -> String {
        TaskListPresentation.listSessionLabel(
            title: session.title,
            providerLabel: session.providerLabel,
            cwd: session.cwd,
            index: 0
        )
    }

    private func performConfirm(_ confirm: TaskListConfirm) async {
        guard !confirmBusy else { return }
        confirmBusy = true
        confirmError = nil
        do {
            switch confirm {
            case .archiveTask(let task):
                try await store.archiveWorkspaceTask(taskId: task.id, workspaceId: task.workspaceId)
                onTaskArchived?(task.id)
                showToast("已归档任务「\(task.name)」，可在任务看板的归档任务中恢复")
            case .deleteTask(let task):
                try await store.deleteWorkspaceTask(workspaceId: task.workspaceId, taskId: task.id)
                onTaskDeleted?(task.id)
                showToast("已删除任务「\(task.name)」")
            case .clearSessions(let task):
                try await store.clearTaskSessions(taskId: task.id)
                showToast("已清空「\(task.name)」的会话")
            case .deleteSession(let session):
                try await store.deleteSessions([session.id])
                showToast("已删除终端「\(sessionDeleteLabel(session))」")
            case .deleteWorkspace(let workspace):
                try await store.deleteWorkspace(workspaceId: workspace.id)
                onWorkspaceDeleted?(workspace.id)
                showToast("已删除工作区「\(workspace.name)」")
            case .deleteManaged(let selection):
                if !selection.sessionIds.isEmpty {
                    try await store.deleteSessions(Array(selection.sessionIds))
                }
                endManagedSelection()
                showToast("已删除 \(selection.sessionIds.count) 个终端")
            case .archiveManaged(let selection):
                if !selection.sessionIds.isEmpty {
                    let failed = try await store.archiveSessions(Array(selection.sessionIds), archived: true)
                    if !failed.isEmpty {
                        throw WandAPI.APIError.server(status: 400, message: "有 \(failed.count) 个会话未能归档，请刷新后重试。")
                    }
                }
                for taskId in selection.taskIds {
                    guard let task = store.taskGroups.flatMap(\.tasks).first(where: { $0.id == taskId }) else { continue }
                    try await store.archiveWorkspaceTask(taskId: task.id, workspaceId: task.workspaceId)
                    onTaskArchived?(task.id)
                }
                endManagedSelection()
                showToast("已归档所选任务和会话")
            }
            pendingConfirm = nil
        } catch {
            // 失败时把弹窗留在屏幕上（重新置为待确认），让 confirmMessage 展示错误。
            pendingConfirm = confirm
            confirmError = error.localizedDescription
        }
        confirmBusy = false
    }

    /// 聚合接口为列表体积省略了项目级配置；优先复用索引中的完整实体，
    /// 否则才用组字段构造兼容旧服务端的最小值。
    /// 合成目录组的 group.workspaceId 不是真实项目 ID，打开任务必须用 task.workspaceId。
    private func workspace(from group: TaskDirectoryGroup) -> Workspace {
        workspaceForTaskGroup(group, workspaces: store.workspaces)
    }

    private func workspace(for summary: WorkspaceTaskSummary, group: TaskDirectoryGroup) -> Workspace {
        workspaceForTaskSummary(summary, group: group, workspaces: store.workspaces)
    }

    /// 行尾的 Worktree 徽章按钮：显示数量，为 0 时禁用（对齐 web 端审查入口）。
    private func worktreeBadge(_ workspace: Workspace) -> some View {
        let count = workspace.worktreeCount
            ?? store.tasks(for: workspace.id).filter { $0.worktree != nil }.count
        return Button {
            reviewTarget = workspace
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundColor(count > 0 ? Theme.brand : Theme.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(count > 0 ? Theme.brand.opacity(0.10) : Theme.surface)
            )
            .overlay(
                Capsule().stroke(Theme.border, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel("\(workspace.name) 的 Worktree：\(count) 个")
    }

    private func standaloneSessionRow(
        _ session: WorkspaceSessionSummary,
        workspace: Workspace
    ) -> some View {
        HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: selectedSessionIds.contains(session.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(selectedSessionIds.contains(session.id) ? Theme.brand : Theme.textMuted)
                    .frame(width: 22, height: 22)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surface)
                BrandLogo(
                    provider: session.provider ?? "terminal",
                    color: Theme.textSecondary
                )
                .frame(width: 17, height: 17)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(TaskListPresentation.listSessionLabel(
                    title: session.title,
                    providerLabel: session.providerLabel,
                    cwd: session.cwd,
                    index: 0
                ))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(session.providerLabel)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(["running", "thinking"].contains(session.activityStatus) ? Theme.success : Theme.textMuted.opacity(0.5))
                .frame(width: 7, height: 7)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.leading, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                if selectedSessionIds.contains(session.id) {
                    selectedSessionIds.remove(session.id)
                } else {
                    selectedSessionIds.insert(session.id)
                }
                return
            }
            onOpenSession?(workspace, session)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("会话 \(session.title ?? session.providerLabel)")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button {
                moveSessionTarget = session
            } label: {
                Label("移动到任务", systemImage: "folder")
            }
            Button {
                Task { await toggleArchive(session) }
            } label: {
                Label(
                    session.archived == true ? "恢复会话" : "归档会话",
                    systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox"
                )
            }
            Button(role: .destructive) {
                requestDeleteSession(session)
            } label: {
                Label("删除终端", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestDeleteSession(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
    }

    @ViewBuilder
    private var toastView: some View {
        if let toastMessage {
            Text(toastMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    let current = toastMessage
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        if toastMessage == current { self.toastMessage = nil }
                    }
                }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.brand)
            Text("正在加载项目…")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(Theme.textSecondary)
            Text(message)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await store.loadWorkspaceIndex() } }
                .buttonStyle(WandSecondaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundColor(Theme.danger)
            .padding(.vertical, 6)
    }
}
