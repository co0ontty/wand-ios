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

private enum TaskListConfirm: Identifiable {
    case deleteTask(WorkspaceTask)
    case clearSessions(WorkspaceTaskSummary)
    case deleteSession(WorkspaceSessionSummary)
    case deleteWorkspace(Workspace)
    case deleteManaged(TaskListPresentation.ManageSelection)

    var id: String {
        switch self {
        case .deleteTask(let task): return "delete-task-\(task.id)"
        case .clearSessions(let task): return "clear-\(task.id)"
        case .deleteSession(let session): return "delete-session-\(session.id)"
        case .deleteWorkspace(let workspace): return "delete-workspace-\(workspace.id)"
        case .deleteManaged: return "delete-managed"
        }
    }
}

struct WorkspaceListView: View {
    @ObservedObject var store: WorkspaceStore
    let api: WandAPI
    var serverDisplayName: String? = nil
    let selectedTaskId: String?
    var selectedSessionId: String? = nil
    let onOpenTask: (Workspace, WorkspaceTask) -> Void
    var onTaskRenamed: ((WorkspaceTask) -> Void)? = nil
    var onTaskDeleted: ((String) -> Void)? = nil
    var onOpenSession: ((Workspace, WorkspaceSessionSummary) -> Void)? = nil
    var onOpenTaskSession: ((Workspace, WorkspaceTask, WorkspaceSessionSummary) -> Void)? = nil
    var onRequestNewSession: ((Workspace, WorkspaceTask) -> Void)? = nil
    var onOpenParallel: ((Workspace, WorkspaceTask) -> Void)? = nil
    var onMergeAgentStarted: ((Workspace, SessionSnapshot) -> Void)? = nil
    var onWorkspaceDeleted: ((String) -> Void)? = nil
    var requestNewTask: Binding<Bool> = .constant(false)

    @State private var expandedWorkspaceIds = Set<String>()
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
    @State private var isSelecting = false
    @State private var selectedTaskIds = Set<String>()
    @State private var selectedSessionIds = Set<String>()

    @State private var renameWorkspaceTarget: Workspace?
    @State private var renameWorkspaceDraft = ""
    @State private var renameWorkspaceError: String?
    @State private var renameWorkspaceBusy = false

    @State private var reviewTarget: Workspace?
    @State private var createWorkspacePresented = false
    @State private var toastMessage: String?

    var body: some View {
        sheetContent
            .background(WandAmbientBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelecting {
                        Button("完成") {
                            isSelecting = false
                            selectedTaskIds.removeAll()
                            selectedSessionIds.removeAll()
                        }
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelecting {
                        Button("删除", role: .destructive) {
                            let selection = TaskListPresentation.ManageSelection(
                                taskIds: selectedTaskIds,
                                sessionIds: selectedSessionIds
                            )
                            let resolved = TaskListPresentation.resolveManagedDeletion(
                                selection,
                                groups: store.taskGroups
                            )
                            if !resolved.isEmpty {
                                presentConfirm(.deleteManaged(resolved))
                            }
                        }
                        .disabled(selectedTaskIds.isEmpty && selectedSessionIds.isEmpty)
                    } else {
                        Button {
                            isSelecting = true
                            selectedTaskIds.removeAll()
                            selectedSessionIds.removeAll()
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Theme.brand)
                        }
                        .accessibilityLabel("多选任务和终端")
                        Button {
                            newTaskSheetCwd = ""
                            newTaskSheetWorkspaceId = nil
                            newTaskSheetPresented = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(Theme.brand)
                        }
                        .accessibilityLabel("新建任务")
                    }
                }
            }
            .overlay(alignment: .top) { toastView }
            .animation(.easeInOut(duration: 0.25), value: toastMessage)
            .task {
                store.startTaskGroupsSync()
                if case .idle = store.indexState {
                    await store.loadWorkspaceIndex()
                }
            }
            .onChange(of: store.workspaces.map(\.id)) { _, ids in
                if expandedWorkspaceIds.isEmpty {
                    expandedWorkspaceIds = Set(ids)
                }
            }
            .onChange(of: expandedWorkspaceIds) { _, expanded in
                for workspaceId in expanded where store.standaloneSessions[workspaceId] == nil {
                    Task { await store.loadWorkspaceSessions(workspaceId: workspaceId) }
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
                newTaskSheetCwd = ""
                newTaskSheetWorkspaceId = nil
                newTaskSheetPresented = true
                requestNewTask.wrappedValue = false
            }
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
                Button(confirmBusy ? "处理中…" : confirmActionTitle, role: .destructive) {
                    Task { await performPendingConfirm() }
                }
                .disabled(confirmBusy)
            } message: {
                Text(confirmMessage)
            }
    }

    private var sheetContent: some View {
        alertContent
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
            .sheet(isPresented: $createWorkspacePresented) {
                WorkspaceCreateView(api: api, store: store) { created in
                    showToast("已创建项目「\(created.name)」")
                    Task {
                        do {
                            let (workspace, creation) = try await store.createTask(
                                name: "",
                                directory: created.cwd,
                                worktree: false,
                                workspaceId: created.id
                            )
                            onOpenTask(workspace, WorkspaceTask(
                                id: creation.id,
                                workspaceId: creation.workspaceId,
                                name: creation.name,
                                worktree: creation.worktree,
                                layout: nil,
                                status: creation.status,
                                createdAt: "",
                                lastOpenedAt: nil
                            ))
                        } catch {
                            showToast(error.localizedDescription)
                        }
                    }
                }
            }
            .sheet(isPresented: $newTaskSheetPresented) {
                WorkspaceNewTaskSheet(api: api, store: store, initialCwd: newTaskSheetCwd, workspaceId: newTaskSheetWorkspaceId) { workspace, creation in
                    if !creation.isIsolated, let worktreeError = creation.worktreeError {
                        showToast("已创建任务「\(creation.name)」：\(worktreeError)")
                    } else {
                        showToast("已创建任务「\(creation.name)」\(creation.isIsolated ? "（独立 worktree）" : "")")
                    }
                    let task = WorkspaceTask(
                        id: creation.id,
                        workspaceId: creation.workspaceId,
                        name: creation.name,
                        worktree: creation.worktree,
                        layout: nil,
                        status: creation.status,
                        createdAt: "",
                        lastOpenedAt: nil
                    )
                    store.scheduleAutoCreateWindow(taskId: creation.id)
                    onOpenTask(workspace, task)
                }
                .presentationDetents([.medium, .large])
            }
    }

    private var alertContent: some View {
        stateContent
            .alert("重命名项目", isPresented: renameWorkspacePresented) {
                renameWorkspaceAlertContent
            } message: {
                if let renameWorkspaceError {
                    Text(renameWorkspaceError)
                } else {
                    Text("修改项目的显示名称。")
                }
            }

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
        case .deleteTask: return "删除任务？"
        case .clearSessions: return "清空全部终端？"
        case .deleteSession: return "删除终端？"
        case .deleteWorkspace: return "删除项目？"
        case .deleteManaged: return "删除所选内容？"
        case .none: return ""
        }
    }

    private var confirmActionTitle: String {
        switch pendingConfirm {
        case .clearSessions: return "确认清空"
        default: return "删除"
        }
    }

    private var confirmMessage: String {
        if let confirmError { return confirmError }
        switch pendingConfirm {
        case .deleteTask(let task):
            return "任务「\(task.name)」及其会话和独立 worktree 将被删除，此操作无法撤销。"
        case .clearSessions(let task):
            return "将结束并删除「\(task.name)」的 \(task.listedSessionCount) 个终端，此操作无法撤销。"
        case .deleteSession(let session):
            return "终端「\(sessionDeleteLabel(session))」会结束并被删除，此操作无法撤销。"
        case .deleteWorkspace(let workspace):
            return "项目「\(workspace.name)」及其任务、会话与独立 worktree 将被删除，此操作无法撤销。"
        case .deleteManaged(let selection):
            return "将删除\(TaskListPresentation.describeManagedDeletion(selection))，此操作无法撤销。"
        case .none:
            return ""
        }
    }

    /// 左滑收起动画和 alert 抢同一帧时，确认框会被直接吞掉。
    private func presentAfterSwipe(_ action: @escaping () -> Void) {
        renameTarget = nil
        renameWorkspaceTarget = nil
        pendingConfirm = nil
        confirmError = nil
        DispatchQueue.main.async(execute: action)
    }

    private func presentConfirm(_ confirm: TaskListConfirm) {
        presentAfterSwipe { pendingConfirm = confirm }
    }

    private var renameWorkspacePresented: Binding<Bool> {
        Binding(
            get: { renameWorkspaceTarget != nil },
            set: { if !$0 { renameWorkspaceTarget = nil } }
        )
    }

    @ViewBuilder
    private var renameWorkspaceAlertContent: some View {
        if let target = renameWorkspaceTarget {
            TextField("项目名称", text: $renameWorkspaceDraft)
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) { renameWorkspaceTarget = nil }
            Button(renameWorkspaceBusy ? "保存中…" : "保存") {
                guard !renameWorkspaceBusy else { return }
                let trimmed = renameWorkspaceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    renameWorkspaceError = "名称不能为空"
                    return
                }
                renameWorkspaceBusy = true
                let workspaceId = target.id
                Task {
                    do {
                        _ = try await store.renameWorkspace(
                            workspaceId: workspaceId,
                            name: trimmed
                        )
                        renameWorkspaceTarget = nil
                        renameWorkspaceBusy = false
                        showToast("已重命名为「\(trimmed)」")
                    } catch {
                        renameWorkspaceError = error.localizedDescription
                        renameWorkspaceBusy = false
                    }
                }
            }
            .disabled(renameWorkspaceBusy || renameWorkspaceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        taskGroupsList
    }

    private var emptyProjectsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34))
                .foregroundColor(Theme.brand)
            Text("还没有项目")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("创建项目后可按任务隔离 worktree，多窗口并行推进")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
            Button {
                createWorkspacePresented = true
            } label: {
                Text("新建项目")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var projectTreeList: some View {
        List {
            if case .failed(let message) = store.indexState {
                inlineError(message)
            }
            ForEach(store.workspaces) { workspace in
                workspaceSection(workspace)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await store.loadWorkspaceIndex()
            for workspaceId in expandedWorkspaceIds {
                Task { await store.loadWorkspaceSessions(workspaceId: workspaceId, force: true) }
            }
        }
    }

    /// 任务一级视图：GET /api/tasks 聚合，目录组为一级容器，未分组会话不丢失。
    private var taskGroupsList: some View {
        List {
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
            let visible = TaskListPresentation.orderedDirectoryGroups(store.taskGroups)
            let metrics = TaskListPresentation.metrics(for: visible)
            homeOverviewCard(metrics: metrics)
            if visible.isEmpty && store.taskGroupsError == nil && !store.taskGroupsLoading {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.brand)
                    Text("还没有任务")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("新建任务时选目录，之后在任务里建会话无需再选目录。")
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        newTaskSheetCwd = ""
                        newTaskSheetWorkspaceId = nil
                        newTaskSheetPresented = true
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
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("任务与工作窗口")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(TaskListPresentation.homeTaskSummaryLabel(metrics))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
            }
            ForEach(visible) { group in
                taskGroupSection(group, directoryCount: metrics.directoryCount)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await store.loadTaskGroups(force: true)
            await store.loadWorkspaceIndex()
        }
    }

    private func homeOverviewCard(metrics: TaskListPresentation.TaskListMetrics) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                WandBrandMark(size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("工作台")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Circle()
                            .fill(Theme.success)
                            .frame(width: 7, height: 7)
                        Text("已连接")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.success)
                    }
                    Text(serverDisplayName ?? "当前服务器")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Button {
                newTaskSheetCwd = ""
                newTaskSheetWorkspaceId = nil
                newTaskSheetPresented = true
            } label: {
                Label("新建任务", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WandPrimaryButtonStyle())
            HStack(spacing: 8) {
                homeMetric("目录", value: metrics.directoryCount)
                homeMetric("任务", value: metrics.taskCount)
                homeMetric("窗口", value: metrics.sessionCount)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.border.opacity(0.55), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }

    private func homeMetric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface.opacity(0.65)))
    }

    @ViewBuilder
    private func taskGroupSection(_ group: TaskDirectoryGroup, directoryCount: Int) -> some View {
        let expanded = TaskListPresentation.isDirectoryExpanded(
            userCollapsed: collapsedTaskGroups.contains(group.id),
            directoryCount: directoryCount
        )
        let collapsible = TaskListPresentation.showsDirectoryDisclosure(directoryCount: directoryCount)
        taskGroupHeader(group, expanded: expanded, collapsible: collapsible)
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
        if expanded {
            ForEach(TaskListPresentation.orderedTaskSummaries(group.tasks)) { summary in
                taskRows(summary, group: group)
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
                standaloneSessionSection(group)
            }
        }
    }

    @ViewBuilder
    private func standaloneSessionSection(_ group: TaskDirectoryGroup) -> some View {
        let expanded = !collapsedLooseGroups.contains(group.id)
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
            ForEach(group.standaloneSessions) { session in
                standaloneSessionRow(session, workspace: workspace(from: group))
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func taskGroupHeader(_ group: TaskDirectoryGroup, expanded: Bool, collapsible: Bool) -> some View {
        let sessionTotal = group.tasks.reduce(0) { $0 + $1.listedSessionCount } + group.standaloneSessions.count
        return HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: group.isSynthetic ? "folder.badge.questionmark" : "folder.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.brand)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.brand.opacity(0.10))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.workspaceName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if TaskListPresentation.hasLiveActivity(group) {
                            Circle()
                                .fill(Theme.success)
                                .frame(width: 7, height: 7)
                        }
                        if group.isSynthetic {
                            Text("未归档目录")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    if let caption = TaskListPresentation.directoryPathCaption(name: group.workspaceName, cwd: group.workspaceCwd) {
                        Text(caption)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard collapsible else { return }
                toggleCollapsedTaskGroup(group.id)
            }
            Spacer(minLength: 6)
            if collapsible {
                Button {
                    toggleCollapsedTaskGroup(group.id)
                } label: {
                    treeDisclosureCaret(expanded: expanded)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起目录" : "展开目录")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(group.tasks.count) 任务")
                Text("\(sessionTotal) 会话")
            }
            .font(.system(size: 10))
            .foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: true, vertical: true)
            Button {
                newTaskSheetCwd = group.workspaceCwd
                newTaskSheetWorkspaceId = group.isBindableProject ? group.workspaceId : nil
                newTaskSheetPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(isSelecting)
            .opacity(isSelecting ? 0.35 : 1)
            .accessibilityLabel("在 \(group.workspaceName) 新建任务")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface.opacity(0.55))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目录 \(group.workspaceName)，\(group.tasks.count) 个任务")
    }

    private func treeDisclosureCaret(expanded: Bool) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Theme.textMuted)
            .rotationEffect(.degrees(expanded ? 0 : -90))
            .frame(width: 18, height: 22)
    }

    private func toggleCollapsedTaskGroup(_ id: String) {
        if collapsedTaskGroups.contains(id) {
            collapsedTaskGroups.remove(id)
        } else {
            collapsedTaskGroups.insert(id)
        }
    }

    private func toggleCollapsedTask(_ id: String) {
        if collapsedTaskIds.contains(id) {
            collapsedTaskIds.remove(id)
        } else {
            collapsedTaskIds.insert(id)
        }
    }

    private func toggleCollapsedLooseGroup(_ id: String) {
        if collapsedLooseGroups.contains(id) {
            collapsedLooseGroups.remove(id)
        } else {
            collapsedLooseGroups.insert(id)
        }
    }

    @ViewBuilder
    private func taskRows(_ summary: WorkspaceTaskSummary, group: TaskDirectoryGroup) -> some View {
        let expanded = TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: collapsedTaskIds.contains(summary.id),
            sessionCount: summary.listedSessionCount
        )
        let workspace = workspace(for: summary, group: group)
        taskSummaryRow(summary, group: group)
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 12))
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
            .opacity(summary.status == "done" ? 0.76 : 1)

        if expanded {
            if summary.sessions.isEmpty {
                Text("还没有终端。点右侧「＋」新建。")
                    .font(.footnote)
                    .foregroundColor(Theme.textMuted)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(Array(summary.sessions.enumerated()), id: \.element.id) { index, session in
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
            }
        }
    }

    private func taskSummaryRow(_ summary: WorkspaceTaskSummary, group: TaskDirectoryGroup) -> some View {
        let selected = selectedTaskId == summary.id
        let canCollapseSessions = TaskListPresentation.showsTaskSessionDisclosure(sessionCount: summary.listedSessionCount)
        let expanded = TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: collapsedTaskIds.contains(summary.id),
            sessionCount: summary.listedSessionCount
        )
        let workspace = workspace(for: summary, group: group)
        let task = summary.asTask()
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                if isSelecting {
                    Image(systemName: selectedTaskIds.contains(summary.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(selectedTaskIds.contains(summary.id) ? Theme.brand : Theme.textMuted)
                        .frame(width: 22, height: 22)
                } else if summary.isIsolated || summary.status == "done" {
                    Image(systemName: summary.status == "done" ? "checkmark.circle.fill" : "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(summary.status == "done" ? Theme.success : Theme.textMuted)
                        .frame(width: 18, height: 18)
                }
                Text(summary.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if selected && !isSelecting {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.brand)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    if selectedTaskIds.contains(summary.id) {
                        selectedTaskIds.remove(summary.id)
                    } else {
                        selectedTaskIds.insert(summary.id)
                    }
                    return
                }
                collapsedTaskIds.remove(summary.id)
                onOpenTask(workspace, task)
            }

            Text(summary.status == "done" ? "已完成" : "进行中")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(summary.status == "done" ? Theme.textMuted : Theme.success)
                .padding(.trailing, 4)

            if canCollapseSessions {
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
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("任务 \(summary.name)")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
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
            Button(role: .destructive) {
                presentConfirm(.deleteTask(task))
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                presentConfirm(.deleteTask(task))
            } label: {
                Label("删除", systemImage: "trash")
            }
            if summary.listedSessionCount > 0 {
                Button {
                    presentConfirm(.clearSessions(summary))
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .tint(Theme.warning)
            }
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
            index: index,
            parentNames: [workspace.name, summary.name]
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

    private func requestDeleteSession(_ session: WorkspaceSessionSummary) {
        presentConfirm(.deleteSession(session))
    }

    private func sessionDeleteLabel(_ session: WorkspaceSessionSummary) -> String {
        TaskListPresentation.listSessionLabel(
            title: session.title,
            providerLabel: session.providerLabel,
            cwd: session.cwd,
            index: 0,
            parentNames: []
        )
    }

    private func performPendingConfirm() async {
        guard let pendingConfirm, !confirmBusy else { return }
        confirmBusy = true
        confirmError = nil
        do {
            switch pendingConfirm {
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
                showToast("已删除项目「\(workspace.name)」")
            case .deleteManaged(let selection):
                for taskId in selection.taskIds {
                    if let task = store.taskGroups.flatMap(\.tasks).first(where: { $0.id == taskId }) {
                        try await store.deleteWorkspaceTask(workspaceId: task.workspaceId, taskId: task.id)
                        onTaskDeleted?(task.id)
                    }
                }
                if !selection.sessionIds.isEmpty {
                    try await store.deleteSessions(Array(selection.sessionIds))
                }
                isSelecting = false
                selectedTaskIds.removeAll()
                selectedSessionIds.removeAll()
                showToast("已删除\(TaskListPresentation.describeManagedDeletion(selection))")
            }
            self.pendingConfirm = nil
        } catch {
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
        if let workspace = store.workspaces.first(where: { $0.id == summary.workspaceId }) {
            return workspace
        }
        if !group.isSynthetic, summary.workspaceId == group.workspaceId {
            return workspace(from: group)
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

    private func workspaceSection(_ workspace: Workspace) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedWorkspaceIds.contains(workspace.id) },
                set: { expanded in
                    if expanded {
                        expandedWorkspaceIds.insert(workspace.id)
                        Task { await store.loadWorkspaceSessions(workspaceId: workspace.id) }
                    } else {
                        expandedWorkspaceIds.remove(workspace.id)
                    }
                }
            )
        ) {
            if let error = store.taskErrors[workspace.id] {
                inlineError(error)
            }
            if let error = store.standaloneSessionErrors[workspace.id],
               store.standaloneSessions[workspace.id] == nil {
                inlineError(error)
            }
            let tasks = store.tasks(for: workspace.id)
            let sessions = store.standaloneSessions[workspace.id] ?? []
            if sessions.isEmpty && tasks.isEmpty
                && store.taskErrors[workspace.id] == nil
                && store.standaloneSessionErrors[workspace.id] == nil {
                Text("还没有任务。点击「+」创建隔离任务，或在「会话」里新建。")
                    .font(.footnote)
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 10)
            } else {
                ForEach(sessions) { session in
                    standaloneSessionRow(session, workspace: workspace)
                }
                ForEach(tasks) { task in
                    taskRow(task, workspace: workspace)
                }
            }
        } label: {
            workspaceHeader(workspace)
        }
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
        .contextMenu {
            Button {
                newTaskSheetCwd = workspace.cwd
                newTaskSheetWorkspaceId = workspace.id
                newTaskSheetPresented = true
            } label: {
                Label("新任务", systemImage: "plus")
            }
            Button {
                reviewTarget = workspace
            } label: {
                Label("Worktree 审查", systemImage: "arrow.triangle.branch")
            }
            Button {
                renameWorkspaceDraft = workspace.name
                renameWorkspaceError = nil
                renameWorkspaceTarget = workspace
            } label: {
                Label("重命名项目", systemImage: "pencil")
            }
            Button(role: .destructive) {
                presentConfirm(.deleteWorkspace(workspace))
            } label: {
                Label("删除项目", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                presentConfirm(.deleteWorkspace(workspace))
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func workspaceHeader(_ workspace: Workspace) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "folder.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.brand)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brand.opacity(0.10))
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if let provider = workspace.defaultProvider {
                        Text(provider.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                Text(workspace.cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            worktreeBadge(workspace)
            Button {
                newTaskSheetCwd = workspace.cwd
                newTaskSheetWorkspaceId = workspace.id
                newTaskSheetPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(Theme.brand.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在 \(workspace.name) 新建任务")
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("项目 \(workspace.name)，目录 \(workspace.cwd)")
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
                    index: 0,
                    parentNames: [workspace.name]
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

    private func taskRow(_ task: WorkspaceTask, workspace: Workspace) -> some View {
        Button {
            onOpenTask(workspace, task)
        } label: {
            HStack(spacing: 10) {
                if task.status == "done" || task.worktree != nil {
                    Image(systemName: task.status == "done" ? "checkmark.circle.fill" : "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(task.status == "done" ? Theme.success : Theme.textMuted)
                        .frame(width: 18, height: 18)
                }
                Text(task.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if selectedTaskId == task.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.brand)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.leading, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("任务 \(task.name)")
        .accessibilityValue(task.status == "done" ? "已完成" : "进行中")
        .contextMenu {
            Button {
                renameDraft = task.name
                renameError = nil
                renameTarget = task
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                presentConfirm(.deleteTask(task))
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                presentConfirm(.deleteTask(task))
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
