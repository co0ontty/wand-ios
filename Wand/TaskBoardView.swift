import SwiftUI

struct TaskBoardView: View {
    let api: WandAPI
    var linkedWorkspaceId: String? = nil
    let onOpenSession: (String) -> Void
    var onDismiss: (() -> Void)? = nil
    var embedded: Bool = false
    var refreshNonce: Int = 0

    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [WandBoardTask] = []
    @State private var workspaces: [Workspace] = []
    @State private var catalog: ModelsResponse?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var filterWorkspaceId = ""
    @State private var selected: WandBoardTask?
    @State private var showCreate = false
    // 从哪一列点开的「新建」决定初始状态：待办 = 只创建，进行中 = 创建并指派。
    @State private var createStatus = "todo"
    @State private var busy = false
    @State private var lastAgent = WandBoardTaskAgent.default
    @State private var archiveExpanded = false
    @State private var statusFilter = ""
    @State private var pendingSwipe: (task: WandBoardTask, action: WandBoardSwipeAction)?

    var body: some View {
        Group {
            if embedded {
                boardSurface
            } else {
                NavigationStack {
                    boardSurface
                        .navigationTitle(selected == nil ? "任务管理" : selected?.title ?? "任务")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(selected == nil ? "关闭" : "返回") {
                                    if selected != nil { selected = nil } else { close() }
                                }
                            }
                            if selected == nil {
                                ToolbarItem(placement: .primaryAction) {
                                    Button {
                                        Task { await refresh(showProgress: false) }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            TaskBoardCreateView(
                workspaces: workspaces,
                catalog: catalog,
                lastAgent: lastAgent,
                defaultWorkspaceId: filterWorkspaceId,
                initialStatus: createStatus,
                busy: busy
            ) { title, description, status, priority, workspaceId, agent in
                await mutate {
                    let created = try await api.createBoardTask(
                        title: title,
                        description: description,
                        status: status,
                        priority: priority,
                        workspaceId: workspaceId,
                        agent: agent
                    )
                    rememberAgent(agent)
                    showCreate = false
                    selected = created
                    // 只有「进行中」列的新建才顺带第一次指派；「待办」列只创建任务。
                    if wandBoardCreateDispatches(status: status),
                       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try? await api.dispatchBoardTask(id: created.id, agent: agent, prompt: description)
                        await refresh(showProgress: false)
                    }
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       created.titleSource == "auto" {
                        Task { await awaitGeneratedTitle(taskId: created.id, placeholder: created.title) }
                    }
                }
            }
        }
        .task {
            if filterWorkspaceId.isEmpty { filterWorkspaceId = linkedWorkspaceId ?? "" }
            await refresh(showProgress: true)
            workspaces = (try? await api.listWorkspaces()) ?? []
            catalog = try? await api.models()
            lastAgent = (try? await api.boardTaskAgentDefaults()) ?? .default
        }
        .onChange(of: refreshNonce) { _, _ in
            Task { await refresh(showProgress: false) }
        }
        .alert("任务操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var visibleTasks: [WandBoardTask] {
        tasks.filter { task in
            let haystack = "\(task.title) \(task.description) \(task.identifier) \(task.workspace?.name ?? "")"
            let matchesQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || haystack.localizedCaseInsensitiveContains(query)
            let matchesWorkspace = filterWorkspaceId.isEmpty || task.workspaceId == filterWorkspaceId
            return matchesQuery && matchesWorkspace
        }
    }

    private var boardStats: WandBoardTaskStats { wandBoardTaskStats(visibleTasks) }

    private var projectName: String {
        workspaces.first(where: { $0.id == filterWorkspaceId })?.name ?? "全部任务"
    }

    @ViewBuilder
    private var boardSurface: some View {
        Group {
            if let selected {
                VStack(spacing: 0) {
                    if embedded {
                        boardDetailChrome(title: selected.title.isEmpty ? "任务详情" : selected.title)
                    }
                    TaskBoardDetailView(
                        task: selected,
                        workspaces: workspaces,
                        catalog: catalog,
                        lastAgent: lastAgent,
                        busy: busy,
                        onPatch: { body in await mutate { _ = try await api.updateBoardTask(id: selected.id, body: body) } },
                        onRemember: rememberAgent,
                        onDispatch: { agent, prompt in
                            rememberAgent(agent)
                            await mutate {
                                _ = try await api.updateBoardTask(id: selected.id, body: ["agent": agent.jsonObject()])
                                let result = try await api.dispatchBoardTask(id: selected.id, agent: agent, prompt: prompt)
                                if !result.sessionId.isEmpty { onOpenSession(result.sessionId) }
                            }
                        },
                        onDelete: {
                            await mutate {
                                try await api.deleteBoardTask(id: selected.id)
                                self.selected = nil
                            }
                        },
                        onOpenSession: onOpenSession,
                        onClose: { self.selected = nil }
                    )
                }
            } else if loading && tasks.isEmpty {
                ProgressView().tint(Theme.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listContent
            }
        }
        .background { WandAmbientBackground() }
    }

    private func boardDetailChrome(title: String) -> some View {
        HStack(spacing: 10) {
            Button {
                selected = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(Theme.brand)
            }
            .buttonStyle(.plain)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var listContent: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                Section {
                    TaskBoardHero(
                        projectName: projectName,
                        stats: boardStats,
                        query: $query
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 4, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    boardFilters
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if visibleTasks.isEmpty {
                    Section {
                        boardEmptyState
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } else if statusFilter.isEmpty {
                    ForEach(WandBoardStatus.allCases) { status in
                        let items = sortedTasks(visibleTasks.filter { $0.status == status.rawValue })
                        let archived = status == .done
                            ? sortedTasks(visibleTasks.filter { $0.status == "archived" })
                            : []
                        if !items.isEmpty || !archived.isEmpty {
                            Section {
                                boardSectionHeader(status: status.rawValue, count: items.count)
                                    .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 2, trailing: 14))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                ForEach(items) { task in
                                    boardRow(task)
                                }
                                if !archived.isEmpty {
                                    boardArchiveHeader(count: archived.count)
                                        .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 2, trailing: 14))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                    if archiveOpen {
                                        ForEach(archived) { task in
                                            boardRow(task)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(sortedTasks(visibleTasks.filter { $0.status == statusFilter })) { task in
                            boardRow(task)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 88, for: .scrollContent)

            Button {
                openCreate("todo")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Theme.success))
                    .shadow(color: Theme.success.opacity(0.28), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.bottom, 18)
            .accessibilityLabel("新建任务")
        }
        .confirmationDialog(
            pendingSwipe.map { wandBoardSwipeActionTitle($0.action) } ?? "确认",
            isPresented: Binding(
                get: { pendingSwipe != nil },
                set: { if !$0 { pendingSwipe = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingSwipe {
                Button(
                    wandBoardSwipeActionLabel(pending.action),
                    role: pending.action == .archive ? .destructive : nil
                ) {
                    Task { await applySwipe(pending.task, pending.action) }
                    pendingSwipe = nil
                }
                Button("取消", role: .cancel) { pendingSwipe = nil }
            }
        } message: {
            if let pending = pendingSwipe {
                Text("「\(wandBoardCardTitle(pending.task))」\n\(wandBoardSwipeConfirmMessage(pending.action))")
            }
        }
    }

    private var archiveOpen: Bool {
        archiveExpanded || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || statusFilter == "archived"
    }

    private var boardFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                Button("所有项目") { filterWorkspaceId = "" }
                ForEach(workspaces) { workspace in
                    Button(workspace.name) { filterWorkspaceId = workspace.id }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                    Text(workspaces.first(where: { $0.id == filterWorkspaceId })?.name ?? "所有项目")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.surface.opacity(0.92)))
                .overlay(Capsule().stroke(Theme.border.opacity(0.7), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                ForEach(
                    [("", "全部"), ("todo", "待办"), ("doing", "进行中"), ("done", "已完成"), ("archived", "归档")],
                    id: \.0
                ) { value, label in
                    let active = statusFilter == value
                    Button {
                        statusFilter = value
                    } label: {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(active ? Theme.success : Theme.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(active ? Theme.successSoft : Theme.surface.opacity(0.88))
                            )
                            .overlay(
                                Capsule().stroke(active ? Theme.success.opacity(0.35) : Theme.border.opacity(0.55), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var boardEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(Theme.success)
            Text(query.isEmpty && statusFilter.isEmpty ? "工作台还是空的" : "没有匹配的任务")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(query.isEmpty && statusFilter.isEmpty ? "点右下角 +，把事情做完。" : "换个筛选条件，或新建一条任务。")
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted)
            Button("新建任务", action: { openCreate("todo") })
                .buttonStyle(WandPrimaryButtonStyle())
                .frame(maxWidth: 180)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func openCreate(_ status: String) {
        createStatus = status
        showCreate = true
    }

    private func boardSectionHeader(status: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(wandBoardStatusColor(status))
                .frame(width: 8, height: 8)
            Text(WandBoardStatus(rawValue: status)?.label ?? status)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(wandBoardStatusColor(status))
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
            Spacer(minLength: 0)
            Button {
                openCreate(status)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.surface.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在\(WandBoardStatus(rawValue: status)?.label ?? status)中新建任务")
        }
    }

    private func boardArchiveHeader(count: Int) -> some View {
        Button {
            archiveExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                Text("归档任务")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundColor(Theme.textMuted)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func boardRow(_ task: WandBoardTask) -> some View {
        TaskBoardRow(
            task: task,
            showWorkspace: filterWorkspaceId.isEmpty,
            onOpen: { selected = task },
            onToggleComplete: {
                Task { await mutate { _ = try await api.updateBoardTask(id: task.id, body: ["status": wandBoardToggledStatus(task.status)]) } }
            },
            onOpenSession: onOpenSession
        )
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let action = wandBoardSwipeAction(for: task.status) {
                Button {
                    pendingSwipe = (task, action)
                } label: {
                    Label(wandBoardSwipeActionLabel(action), systemImage: wandBoardSwipeSystemImage(action))
                }
                .tint(action == .archive ? Theme.danger : (action == .complete ? Theme.info : Theme.success))
            }
        }
    }

    /// 顺序以 GET /api/wand-tasks 返回为准，客户端不再本地排序。
    private func sortedTasks(_ tasks: [WandBoardTask]) -> [WandBoardTask] {
        tasks
    }

    private func applySwipe(_ task: WandBoardTask, _ action: WandBoardSwipeAction) async {
        await mutate {
            if let status = wandBoardSwipeTargetStatus(action) {
                _ = try await api.updateBoardTask(id: task.id, body: ["status": status])
            } else {
                try await api.deleteBoardTask(id: task.id)
            }
        }
    }

    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private func rememberAgent(_ agent: WandBoardTaskAgent) {
        lastAgent = agent
        Task { _ = try? await api.saveBoardTaskAgentDefaults(agent) }
    }

    private func refresh(showProgress: Bool) async {
        if showProgress { loading = true }
        do {
            tasks = try await api.listBoardTasks()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    /**
     * 标题留空时标题由服务端后台生成。创建响应里只有描述首行占位，
     * 这里短轮询几次，拿到真标题就刷新列表和详情；一直没变就保留占位。
     */
    private func awaitGeneratedTitle(taskId: String, placeholder: String) async {
        for delayMs in [1_200, 2_000, 3_000, 5_000, 8_000] {
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let task = try? await api.getBoardTask(id: taskId) else { continue }
            guard !task.title.isEmpty, task.title != placeholder else { continue }
            await refresh(showProgress: false)
            if let id = selected?.id {
                selected = tasks.first(where: { $0.id == id }) ?? selected
            }
            return
        }
    }

    private func mutate(_ work: () async throws -> Void) async {
        busy = true
        do {
            try await work()
            await refresh(showProgress: false)
            if let id = selected?.id {
                selected = tasks.first(where: { $0.id == id }) ?? selected
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }
}

private func wandBoardStatusColor(_ status: String) -> Color {
    switch status {
    case "todo": return Theme.thinking
    case "doing": return Theme.success
    case "done": return Theme.info
    default: return Theme.textMuted
    }
}

private func wandBoardPriorityColor(_ priority: String) -> Color {
    switch priority {
    case "urgent": return Theme.danger
    case "high": return Theme.warning
    case "medium": return Theme.permission
    default: return Theme.textMuted
    }
}

private struct TaskBoardHero: View {
    let projectName: String
    let stats: WandBoardTaskStats
    @Binding var query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(projectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                boardSearchCapsule
            }
            HStack(alignment: .bottom, spacing: 10) {
                Text("\(stats.remaining)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.success)
                    .monospacedDigit()
                Text("未完成")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .padding(.bottom, 6)
            }
            .padding(.top, 4)
            HStack(spacing: 8) {
                metricTile("待办", value: stats.todo, color: wandBoardStatusColor("todo"))
                metricTile("进行中", value: stats.doing, color: wandBoardStatusColor("doing"))
                metricTile("已完成", value: stats.done, color: wandBoardStatusColor("done"))
            }
            .padding(.top, 12)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.successSoft)
        )
    }

    private var boardSearchCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textMuted)
            TextField("搜索", text: $query)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 148, height: 30)
        .background(Capsule().fill(Theme.surface.opacity(0.88)))
        .overlay(Capsule().stroke(Theme.border.opacity(0.72), lineWidth: 0.5))
    }

    private func metricTile(_ label: String, value: Int, color: Color) -> some View {
        let ratio = stats.total > 0 ? CGFloat(value) / CGFloat(stats.total) : 0
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .padding(.bottom, 8)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.16))
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, proxy.size.width * ratio))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface.opacity(0.82))
        )
    }
}

private struct TaskBoardRow: View {
    let task: WandBoardTask
    var showWorkspace = true
    var onOpen: () -> Void = {}
    var onToggleComplete: () -> Void = {}
    var onOpenSession: (String) -> Void = { _ in }

    private var done: Bool { task.status == "done" || task.status == "archived" }
    private var agentRunning: Bool { wandBoardAgentRunning(task) }
    private var hasChips: Bool {
        (showWorkspace && !(task.workspace?.name ?? "").isEmpty)
            || (task.priority != "none" && !task.priority.isEmpty)
            || wandBoardAgentLabels(sessions: task.sessions, assigned: task.agent) != nil
            || task.labels.contains(where: { !$0.isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button(action: onToggleComplete) {
                    BoardStatusCheck(status: task.status)
                }
                .buttonStyle(.plain)
                Text(wandBoardCardTitle(task))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(done ? Theme.textMuted : Theme.textPrimary)
                    .strikethrough(done)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
            }
            VStack(alignment: .leading, spacing: 8) {
                if hasChips {
                    FlowLayout(spacing: 6) {
                        if showWorkspace, let name = task.workspace?.name, !name.isEmpty {
                            boardChip(name, icon: "folder")
                        }
                        if task.priority != "none", !task.priority.isEmpty {
                            boardChip(
                                WandBoardPriority(rawValue: task.priority)?.label ?? task.priority,
                                color: wandBoardPriorityColor(task.priority)
                            )
                        }
                        if let agent = wandBoardAgentLabels(sessions: task.sessions, assigned: task.agent) {
                            boardChip(agent, color: agentRunning ? Theme.textPrimary : Theme.textSecondary) {
                                if agentRunning { BoardAgentDots() }
                            }
                        }
                        ForEach(task.labels.filter { !$0.isEmpty }.prefix(3), id: \.self) { label in
                            boardChip(label)
                        }
                    }
                    .padding(.top, 8)
                }
                if let processing = wandBoardProcessingLabel(task) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.success).frame(width: 7, height: 7)
                        Text(processing)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.success)
                    }
                    .padding(.top, 8)
                }
                if !task.sessions.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(task.sessions) { session in
                            Button {
                                onOpenSession(session.id)
                            } label: {
                                HStack(spacing: 4) {
                                    BrandLogo(
                                        provider: session.provider.isEmpty ? "terminal" : session.provider,
                                        color: Theme.textPrimary
                                    )
                                    .frame(width: 12, height: 12)
                                    Text(wandBoardProviderLabel(session.provider))
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.textSecondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Theme.surfaceSoft.opacity(0.8)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.border.opacity(0.55), lineWidth: 1)
        )
    }

    private func boardChip(
        _ label: String,
        icon: String? = nil,
        color: Color = Theme.textSecondary,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
            trailing()
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
    }
}

/// 轻量换行布局，任务卡上的项目 / 优先级 / Agent 胶囊按内容折行。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.origins[index].x, y: bounds.minY + result.origins[index].y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            width = max(width, x - spacing)
        }
        return (CGSize(width: width, height: y + rowHeight), origins)
    }
}

private struct BoardStatusCheck: View {
    let status: String
    private var done: Bool { status == "done" || status == "archived" }
    private var doing: Bool { status == "doing" }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.success.opacity(done ? 1 : 0.55), lineWidth: 1.5)
            if done {
                Circle().fill(Theme.success)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            } else if doing {
                Circle()
                    .fill(Theme.success)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(done ? "标为未完成" : "标为已完成")
    }
}

private struct BoardAgentDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    let raised = reduceMotion ? 0 : boardAgentDotLift(index: index, now: now)
                    Circle()
                        .fill(Theme.success.opacity(reduceMotion ? 1 : 0.35 + 0.65 * raised))
                        .frame(width: 3, height: 3)
                        .offset(y: -3 * raised)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private func boardAgentDotLift(index: Int, now: TimeInterval) -> CGFloat {
    let cycle = 1.2
    let t = (now - Double(index) * 0.15).truncatingRemainder(dividingBy: cycle)
    let local = t < 0 ? t + cycle : t
    if local < 0.12 { return CGFloat(local / 0.12) }
    if local < 0.24 { return CGFloat(1 - (local - 0.12) / 0.12) }
    return 0
}

private struct TaskBoardDetailView: View {
    let task: WandBoardTask
    let workspaces: [Workspace]
    let catalog: ModelsResponse?
    let lastAgent: WandBoardTaskAgent
    let busy: Bool
    let onPatch: ([String: Any]) async -> Void
    let onRemember: (WandBoardTaskAgent) -> Void
    let onDispatch: (WandBoardTaskAgent, String) async -> Void
    let onDelete: () async -> Void
    let onOpenSession: (String) -> Void
    let onClose: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var agent: WandBoardTaskAgent
    @State private var composePrompt = ""

    init(
        task: WandBoardTask,
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        lastAgent: WandBoardTaskAgent,
        busy: Bool,
        onPatch: @escaping ([String: Any]) async -> Void,
        onRemember: @escaping (WandBoardTaskAgent) -> Void,
        onDispatch: @escaping (WandBoardTaskAgent, String) async -> Void,
        onDelete: @escaping () async -> Void,
        onOpenSession: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.task = task
        self.workspaces = workspaces
        self.catalog = catalog
        self.lastAgent = lastAgent
        self.busy = busy
        self.onPatch = onPatch
        self.onRemember = onRemember
        self.onDispatch = onDispatch
        self.onDelete = onDelete
        self.onOpenSession = onOpenSession
        self.onClose = onClose
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _agent = State(initialValue: task.agent ?? lastAgent)
    }

    var body: some View {
        Form {
            Section("内容") {
                TextField("任务标题", text: $title)
                TextField("描述", text: $description, axis: .vertical)
                    .lineLimit(4...10)
                Button("保存标题与描述") {
                    Task { await onPatch(["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "description": description]) }
                }
                .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("属性") {
                Picker("状态", selection: Binding(
                    get: { task.status },
                    set: { status in Task { await onPatch(["status": status]) } }
                )) {
                    ForEach(WandBoardStatus.allCases) { status in
                        Text(status.label).tag(status.rawValue)
                    }
                }
                Picker("优先级", selection: Binding(
                    get: { task.priority },
                    set: { priority in Task { await onPatch(["priority": priority]) } }
                )) {
                    ForEach(WandBoardPriority.allCases) { priority in
                        Text(priority.label).tag(priority.rawValue)
                    }
                }
                Picker("项目", selection: Binding(
                    get: { task.workspaceId ?? "" },
                    set: { value in
                        Task { await onPatch(["workspaceId": value.isEmpty ? NSNull() : value]) }
                    }
                )) {
                    Text("不指定项目（使用全局目录）").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
            }
            Section(task.sessions.isEmpty ? "指派 Agent" : "再指派一个 Agent") {
                TextField("提示词", text: $composePrompt, prompt: Text("输入这次派给 Agent 的提示词…"), axis: .vertical)
                    .lineLimit(3...8)
                Picker("CLI 工具", selection: Binding(
                    get: { agent.provider },
                    set: { provider in
                        agent.provider = provider
                        agent.mode = wandBoardNormalizedMode(provider: provider, mode: agent.mode)
                        let options = wandBoardModelOptions(from: catalog, provider: provider)
                        if !options.contains(where: { $0.id == agent.model }) {
                            agent.model = options.first?.id ?? "default"
                        }
                        onRemember(agent)
                    }
                )) {
                    ForEach(wandBoardProviders, id: \.self) { provider in
                        Text(wandBoardProviderLabel(provider)).tag(provider)
                    }
                }
                Picker("模型", selection: Binding(
                    get: { agent.model },
                    set: { model in
                        agent.model = model
                        onRemember(agent)
                    }
                )) {
                    ForEach(wandBoardModelOptions(from: catalog, provider: agent.provider), id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                Picker("思考深度", selection: Binding(
                    get: { agent.thinkingEffort },
                    set: { effort in
                        agent.thinkingEffort = effort
                        onRemember(agent)
                    }
                )) {
                    ForEach(wandBoardEfforts, id: \.self) { effort in
                        Text(wandBoardEffortLabel(effort)).tag(effort)
                    }
                }
                Picker("运行模式", selection: Binding(
                    get: { agent.mode },
                    set: { mode in
                        agent.mode = mode
                        onRemember(agent)
                    }
                )) {
                    ForEach(wandBoardSupportedModes(agent.provider), id: \.self) { mode in
                        Text(wandBoardModeLabel(mode)).tag(mode)
                    }
                }
                Button(task.sessions.isEmpty ? "派发 Agent" : "再派发一次") {
                    Task { await onDispatch(agent, composePrompt.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                .disabled(busy || composePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("已指派的 Agent") {
                let groups = wandBoardSessionGroups(sessions: task.sessions, assigned: task.agent)
                if groups.isEmpty {
                    Text("还没有指派 Agent。描述会作为第一次派发的任务内容。")
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(wandBoardAgentTitle(group.provider, group.agent))
                                .font(.subheadline.weight(.semibold))
                            if group.sessions.isEmpty {
                                Text("已指派，等待派发")
                                    .font(.caption)
                                    .foregroundColor(Theme.textMuted)
                            } else {
                                ForEach(group.sessions) { session in
                                    Button {
                                        onOpenSession(session.id)
                                    } label: {
                                        HStack {
                                            BrandLogo(provider: session.provider, color: Theme.textPrimary)
                                                .frame(width: 14, height: 14)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(session.title.isEmpty ? wandBoardProviderLabel(session.provider) : session.title)
                                                Text([session.model, session.status].filter { !$0.isEmpty }.joined(separator: " · "))
                                                    .font(.caption)
                                                    .foregroundColor(Theme.textMuted)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button("归档", role: .destructive) {
                    Task { await onDelete() }
                }
                .disabled(busy)
            }
        }
        .onChange(of: task.id) { _, _ in
            title = task.title
            description = task.description
            agent = task.agent ?? lastAgent
        }
    }
}

private struct TaskBoardCreateView: View {
    let workspaces: [Workspace]
    let catalog: ModelsResponse?
    let lastAgent: WandBoardTaskAgent
    let defaultWorkspaceId: String
    var busy = false
    let onCreate: (String, String, String, String, String?, WandBoardTaskAgent) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var status: String
    @State private var priority = "none"
    @State private var workspaceId = ""
    @State private var agent: WandBoardTaskAgent

    init(
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        lastAgent: WandBoardTaskAgent,
        defaultWorkspaceId: String,
        initialStatus: String = "todo",
        busy: Bool = false,
        onCreate: @escaping (String, String, String, String, String?, WandBoardTaskAgent) async -> Void
    ) {
        self.workspaces = workspaces
        self.catalog = catalog
        self.lastAgent = lastAgent
        self.defaultWorkspaceId = defaultWorkspaceId
        self.busy = busy
        self.onCreate = onCreate
        _status = State(initialValue: initialStatus)
        _agent = State(initialValue: lastAgent)
    }

    /// 「进行中」列的新建代表已经决定要跑，所以创建后立刻派 Agent；其他列只落库。
    private var dispatches: Bool { wandBoardCreateDispatches(status: status) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("任务标题（可选）", text: $title, prompt: Text("不填写则按描述自动生成"))
                TextField(dispatches ? "描述（作为第一次指派）" : "描述（只创建任务）", text: $description, axis: .vertical)
                    .lineLimit(3...8)
                Picker("目录", selection: $workspaceId) {
                    Text("不指定目录（使用全局目录）").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                if dispatches {
                    Picker("第一次指派", selection: Binding(
                        get: { agent.provider },
                        set: { provider in
                            agent.provider = provider
                            agent.mode = wandBoardNormalizedMode(provider: provider, mode: agent.mode)
                            let options = wandBoardModelOptions(from: catalog, provider: provider)
                            if !options.contains(where: { $0.id == agent.model }) {
                                agent.model = options.first?.id ?? "default"
                            }
                        }
                    )) {
                        ForEach(wandBoardProviders, id: \.self) { provider in
                            Text(wandBoardProviderLabel(provider)).tag(provider)
                        }
                    }
                    Picker("模型", selection: Binding(
                        get: { agent.model },
                        set: { agent.model = $0 }
                    )) {
                        ForEach(wandBoardModelOptions(from: catalog, provider: agent.provider), id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    Picker("思考深度", selection: Binding(
                        get: { agent.thinkingEffort },
                        set: { agent.thinkingEffort = $0 }
                    )) {
                        ForEach(wandBoardEfforts, id: \.self) { effort in
                            Text(wandBoardEffortLabel(effort)).tag(effort)
                        }
                    }
                }
                // 运行模式始终可选：只创建的任务也会把模式写进服务端全局默认。
                Picker("运行模式", selection: Binding(
                    get: { agent.mode },
                    set: { agent.mode = $0 }
                )) {
                    ForEach(wandBoardSupportedModes(agent.provider), id: \.self) { mode in
                        Text(wandBoardModeLabel(mode)).tag(mode)
                    }
                }
                Picker("状态", selection: $status) {
                    ForEach(WandBoardStatus.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
                Picker("优先级", selection: $priority) {
                    ForEach(WandBoardPriority.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
            }
            .navigationTitle("新建任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy
                        ? "创建中…"
                        : (dispatches && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "创建并指派" : "创建任务")) {
                        Task {
                            await onCreate(
                                title.trimmingCharacters(in: .whitespacesAndNewlines),
                                description,
                                status,
                                priority,
                                workspaceId.isEmpty ? nil : workspaceId,
                                agent
                            )
                        }
                    }
                    .disabled(busy || (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .onAppear { workspaceId = defaultWorkspaceId }
    }
}

/**
 * 新建任务是否顺带完成第一次指派。
 * 「待办」列只创建任务；「进行中」列代表已经决定要跑，所以创建后立刻派给所选 Agent。
 */
func wandBoardCreateDispatches(status: String) -> Bool { status == "doing" }
