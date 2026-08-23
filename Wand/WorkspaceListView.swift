import SwiftUI

/// 任务面板的显示模式：任务聚合为默认，项目树保留为高级入口。
enum TaskDisplayMode: String, CaseIterable, Identifiable {
    case tasks
    case projects

    var id: String { rawValue }
    var title: String { self == .tasks ? "任务" : "项目" }
}

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

struct WorkspaceListView: View {
    @ObservedObject var store: WorkspaceStore
    let api: WandAPI
    let selectedTaskId: String?
    let onOpenTask: (Workspace, WorkspaceTask) -> Void
    var onTaskRenamed: ((WorkspaceTask) -> Void)? = nil
    var onTaskDeleted: ((String) -> Void)? = nil
    var onOpenSession: ((Workspace, WorkspaceSessionSummary) -> Void)? = nil
    var onMergeAgentStarted: ((Workspace, SessionSnapshot) -> Void)? = nil
    var onWorkspaceDeleted: ((String) -> Void)? = nil

    @State private var expandedWorkspaceIds = Set<String>()
    @State private var renameTarget: WorkspaceTask?
    @State private var renameDraft = ""
    @State private var renameError: String?
    @State private var renameBusy = false
    @State private var deleteTarget: WorkspaceTask?
    @State private var deleteBusy = false
    @State private var deleteError: String?
    /// 任务一级视图（GET /api/tasks 聚合）与项目树的显示切换。
    @State private var displayMode: TaskDisplayMode = .tasks
    @State private var newTaskSheetPresented = false
    @State private var newTaskSheetCwd = ""
    @State private var expandedTaskGroups = Set<String>()
    @State private var expandedLooseGroups = Set<String>()
    @State private var renameWorkspaceTarget: Workspace?
    @State private var renameWorkspaceDraft = ""
    @State private var renameWorkspaceError: String?
    @State private var renameWorkspaceBusy = false
    @State private var deleteWorkspaceTarget: Workspace?
    @State private var deleteWorkspaceBusy = false
    @State private var deleteWorkspaceError: String?
    @State private var reviewTarget: Workspace?
    @State private var createWorkspacePresented = false
    @State private var toastMessage: String?

    var body: some View {
        sheetContent
            .background(WandAmbientBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newTaskSheetCwd = ""
                        newTaskSheetPresented = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.brand)
                    }
                    .accessibilityLabel("新建任务")
                }
            }
            .overlay(alignment: .top) { toastView }
            .animation(.easeInOut(duration: 0.25), value: toastMessage)
            .task {
                async let taskGroupsLoad: Void = store.loadTaskGroups()
                if case .idle = store.indexState {
                    await store.loadWorkspaceIndex()
                }
                await taskGroupsLoad
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
            .alert("重命名任务", isPresented: renameTaskPresented) {
                renameTaskAlertContent
            } message: {
                if let renameError {
                    Text(renameError)
                } else {
                    Text("修改任务的显示名称。")
                }
            }
            .alert("删除任务？", isPresented: deleteTaskPresented) {
                deleteTaskAlertContent
            } message: {
                if let deleteError {
                    Text(deleteError)
                } else if let target = deleteTarget {
                    Text("任务「\(target.name)」及其会话和独立 worktree 将被删除，此操作无法撤销。")
                }
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
                }
            }
            .sheet(isPresented: $newTaskSheetPresented) {
                WorkspaceNewTaskSheet(api: api, store: store, initialCwd: newTaskSheetCwd) { workspace, creation in
                    if !creation.isIsolated, let worktreeError = creation.worktreeError {
                        showToast("已创建任务「\(creation.name)」：\(worktreeError)")
                    } else {
                        showToast("已创建任务「\(creation.name)」\(creation.isIsolated ? "（独立 worktree）" : "")")
                    }
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
            .alert("删除项目？", isPresented: deleteWorkspacePresented) {
                deleteWorkspaceAlertContent
            } message: {
                if let deleteWorkspaceError {
                    Text(deleteWorkspaceError)
                } else if let target = deleteWorkspaceTarget {
                    Text("项目「\(target.name)」及其任务、会话与独立 worktree 将被删除，此操作无法撤销。")
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

    private var deleteTaskPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    @ViewBuilder
    private var deleteTaskAlertContent: some View {
        if let target = deleteTarget {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                guard !deleteBusy else { return }
                deleteBusy = true
                let workspaceId = target.workspaceId
                let taskId = target.id
                Task {
                    do {
                        try await store.deleteWorkspaceTask(
                            workspaceId: workspaceId,
                            taskId: taskId
                        )
                        deleteTarget = nil
                        deleteBusy = false
                        onTaskDeleted?(taskId)
                    } catch {
                        deleteError = error.localizedDescription
                        deleteBusy = false
                    }
                }
            }
            .disabled(deleteBusy)
        }
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

    private var deleteWorkspacePresented: Binding<Bool> {
        Binding(
            get: { deleteWorkspaceTarget != nil },
            set: { if !$0 { deleteWorkspaceTarget = nil } }
        )
    }

    @ViewBuilder
    private var deleteWorkspaceAlertContent: some View {
        if let target = deleteWorkspaceTarget {
            Button("取消", role: .cancel) { deleteWorkspaceTarget = nil }
            Button("删除", role: .destructive) {
                guard !deleteWorkspaceBusy else { return }
                deleteWorkspaceBusy = true
                let workspaceId = target.id
                Task {
                    do {
                        try await store.deleteWorkspace(workspaceId: workspaceId)
                        deleteWorkspaceTarget = nil
                        deleteWorkspaceBusy = false
                        onWorkspaceDeleted?(workspaceId)
                    } catch {
                        deleteWorkspaceError = error.localizedDescription
                        deleteWorkspaceBusy = false
                    }
                }
            }
            .disabled(deleteWorkspaceBusy)
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        VStack(spacing: 0) {
            Picker("显示方式", selection: $displayMode) {
                ForEach(TaskDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if displayMode == .tasks {
                taskGroupsList
            } else if store.workspaces.isEmpty {
                emptyProjectsState
            } else {
                projectTreeList
            }
        }
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
            let visible = store.taskGroups.filter { !$0.tasks.isEmpty || !$0.standaloneSessions.isEmpty }
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
            ForEach(visible) { group in
                taskGroupSection(group)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await store.loadTaskGroups(force: true)
            await store.loadWorkspaceIndex()
        }
    }

    private func taskGroupSection(_ group: TaskDirectoryGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedTaskGroups.contains(group.id) },
                set: { expanded in
                    if expanded { expandedTaskGroups.insert(group.id) } else { expandedTaskGroups.remove(group.id) }
                }
            )
        ) {
            ForEach(group.tasks) { summary in
                taskSummaryRow(summary, group: group)
            }
            if group.tasks.isEmpty && group.standaloneSessions.isEmpty {
                Text("这个目录还没有任务。")
                    .font(.footnote)
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 10)
            }
            if !group.standaloneSessions.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedLooseGroups.contains(group.id) },
                        set: { expanded in
                            if expanded { expandedLooseGroups.insert(group.id) } else { expandedLooseGroups.remove(group.id) }
                        }
                    )
                ) {
                    ForEach(group.standaloneSessions) { session in
                        standaloneSessionRow(session, workspace: workspace(from: group))
                    }
                } label: {
                    Text("未分组会话（\(group.standaloneSessions.count)）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                }
                .padding(.vertical, 3)
            }
        } label: {
            taskGroupHeader(group)
        }
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }

    private func taskGroupHeader(_ group: TaskDirectoryGroup) -> some View {
        HStack(spacing: 11) {
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
            Spacer(minLength: 6)
            let sessionTotal = group.tasks.reduce(0) { $0 + $1.sessions.count } + group.standaloneSessions.count
            Text("\(group.tasks.count) 任务 · \(sessionTotal) 会话")
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
            if !group.isSynthetic {
                Button {
                    newTaskSheetCwd = group.workspaceCwd
                    newTaskSheetPresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.brand)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.brand.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在 \(group.workspaceName) 新建任务")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("目录 \(group.workspaceName)，\(group.tasks.count) 个任务")
    }

    private func taskSummaryRow(_ summary: WorkspaceTaskSummary, group: TaskDirectoryGroup) -> some View {
        Button {
            onOpenTask(workspace(from: group), WorkspaceTask(
                id: summary.id,
                workspaceId: summary.workspaceId,
                name: summary.name,
                worktree: summary.worktree,
                layout: summary.layout,
                status: summary.status,
                createdAt: summary.createdAt,
                lastOpenedAt: summary.lastOpenedAt
            ))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: summary.status == "done" ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(summary.status == "done" ? Theme.success : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    Text(TaskListPresentation.taskIsolationCaption(isolated: summary.isIsolated))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !summary.sessions.isEmpty {
                    Text("\(summary.sessions.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(Theme.textMuted)
                }
                if selectedTaskId == summary.id {
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
        .accessibilityLabel("任务 \(summary.name)")
        .contextMenu {
            Button {
                renameDraft = summary.name
                renameError = nil
                renameTarget = WorkspaceTask(
                    id: summary.id,
                    workspaceId: summary.workspaceId,
                    name: summary.name,
                    worktree: summary.worktree,
                    layout: summary.layout,
                    status: summary.status,
                    createdAt: summary.createdAt,
                    lastOpenedAt: summary.lastOpenedAt
                )
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteError = nil
                deleteTarget = WorkspaceTask(
                    id: summary.id,
                    workspaceId: summary.workspaceId,
                    name: summary.name,
                    worktree: summary.worktree,
                    layout: summary.layout,
                    status: summary.status,
                    createdAt: summary.createdAt,
                    lastOpenedAt: summary.lastOpenedAt
                )
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 聚合接口为列表体积省略了项目级配置；优先复用索引中的完整实体，
    /// 否则才用组字段构造兼容旧服务端的最小值。
    private func workspace(from group: TaskDirectoryGroup) -> Workspace {
        workspaceForTaskGroup(group, workspaces: store.workspaces)
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
                deleteWorkspaceError = nil
                deleteWorkspaceTarget = workspace
            } label: {
                Label("删除项目", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteWorkspaceError = nil
                deleteWorkspaceTarget = workspace
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                newTaskSheetCwd = workspace.cwd
                newTaskSheetPresented = true
            } label: {
                Label("新任务", systemImage: "plus")
            }
            .tint(Theme.brand)
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
        Button {
            onOpenSession?(workspace, session)
        } label: {
            HStack(spacing: 10) {
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
                    .fill(session.status == "running" ? Theme.success : Theme.textMuted.opacity(0.5))
                    .frame(width: 7, height: 7)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.leading, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("会话 \(session.title ?? session.providerLabel)")
        .contextMenu {
            Button(role: .destructive) {
                Task { try? await store.deleteSessions([session.id]) }
            } label: {
                Label("删除终端", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { try? await store.deleteSessions([session.id]) }
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
                Image(systemName: task.status == "done" ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(task.status == "done" ? Theme.success : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.surface)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    Text(TaskListPresentation.taskIsolationCaption(isolated: task.worktree != nil))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
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
                deleteError = nil
                deleteTarget = task
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteError = nil
                deleteTarget = task
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                renameDraft = task.name
                renameError = nil
                renameTarget = task
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(Theme.brand)
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
