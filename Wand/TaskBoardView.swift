import SwiftUI

struct TaskBoardView: View {
    let api: WandAPI
    /// 任务看板与会话树共用同一套任务/终端：看板里移动会话要直接改归属。
    @ObservedObject var workspaceStore: WorkspaceStore
    var linkedWorkspaceId: String? = nil
    let onOpenSession: (String) -> Void
    /// 会话已绑定任务时优先打开任务上下文（对齐 web / Android 的 openSessionWithOwningTask）。
    var onOpenBoundSession: ((String, String) -> Void)? = nil
    var onRequestNewConversation: (String, String?) -> Void = { _, _ in }
    var onOpenTeamRun: ((String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var embedded: Bool = false
    /// 列表级入口随列表一起退场，不叠在任务详情返回/标题行上方。
    var overviewBar: HomeOverviewBar? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.usesSystemHomeNavigation) private var usesSystemNavigation
    @State private var tasks: [WandBoardTask] = []
    @State private var workspaces: [Workspace] = []
    @State private var catalog: ModelsResponse?
    @State private var contactEmployees: [SiliconEmployee] = []
    @State private var contactTeams: [ContactTeam] = []
    @State private var contactsError: String?
    @State private var unconfirmedDispatches = Set<String>()
    @State private var unconfirmedCreate = false
    @State private var activeView = false
    @State private var operationGeneration = 0
    @State private var loading = true
    @State private var refreshInFlight: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var refreshError: String?
    @State private var moveSessionTarget: WandBoardTaskSession?
    @State private var query = ""
    @State private var filterWorkspaceId = ""
    @State private var selected: WandBoardTask?
    /// 打开子任务时保留父任务栈：返回时回到上一层，而不是直接退出详情。
    @State private var taskPath: [WandBoardTask] = []
    @State private var busy = false
    @State private var lastAgent = WandBoardTaskAgent.default
    @State private var archiveExpanded = false
    @State private var statusFilter = ""
    @State private var pendingSwipe: (task: WandBoardTask, action: WandBoardSwipeAction)?
    @State private var expandedUnassignedGroups = Set<String>()
    /// 当前划开的卡片：同一时刻只允许一张，筛选或滚动时收起。
    @State private var swipedTaskId: String?

    var body: some View {
        Group {
            if embedded {
                embeddedBoardSurface
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
                                    if selected != nil { closeTaskDetail() } else { close() }
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
        .homeNavigationHidden(selected != nil)
        .onAppear { activeView = true }
        .onDisappear { activeView = false; operationGeneration += 1 }
        .sheet(item: $moveSessionTarget) { session in
            SessionMoveSheet(
                store: workspaceStore,
                sessionId: session.id,
                sessionTitle: sessionMoveTitle(session)
            ) {
                Task { await refresh(showProgress: false) }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            if filterWorkspaceId.isEmpty { filterWorkspaceId = linkedWorkspaceId ?? "" }
            await refresh(showProgress: true)
            workspaces = (try? await api.listWorkspaces()) ?? []
            catalog = try? await api.models()
            lastAgent = (try? await api.boardTaskAgentDefaults()) ?? .default
            await loadContacts()
        }
        .task {
            // 看板不参与会话树的 10s 轮询：独立周期低调重取，跟上另一端的任务/会话变更。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                await refresh(showProgress: false)
            }
        }
        .onReceive(api.taskChanges) { _ in
            Task { await refresh(showProgress: false) }
        }
        .alert("任务操作失败", isPresented: Binding(
            // 新建弹窗上时用弹窗内联错误，弹窗外再弹 alert 会与 sheet 争同一个呈现通道。
            get: { errorMessage != nil || refreshError != nil },
            set: { if !$0 { errorMessage = nil; refreshError = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil; refreshError = nil }
        } message: {
            Text(errorMessage ?? refreshError ?? "")
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

    private var formalSessionIDs: Set<String> {
        Set(tasks.filter { $0.status != "archived" }.flatMap { $0.sessionIds + $0.sessions.map(\.id) })
    }

    private var visibleUnassignedGroups: [WandBoardUnassignedGroup] {
        guard statusFilter.isEmpty else { return [] }
        return wandBoardUnassignedGroups(
            groups: workspaceStore.taskGroups,
            formalSessionIDs: formalSessionIDs,
            workspaceID: filterWorkspaceId,
            query: query
        )
    }

    private var projectName: String {
        workspaces.first(where: { $0.id == filterWorkspaceId })?.name ?? "全部任务"
    }

    @ViewBuilder
    private var embeddedBoardSurface: some View {
        if usesSystemNavigation && selected == nil {
            boardSurface
                .navigationTitle(overviewBar?.title ?? "任务")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("新建任务", systemImage: "plus") { openCreate("backlog") }
                            .disabled(busy || (loading && tasks.isEmpty))
                    }
                    if #available(iOS 27.1, *), let overviewBar {
                        ToolbarOverflowMenu {
                            Section(overviewBar.serverDisplayName) {
                                Button("设置", systemImage: "gearshape", action: overviewBar.onOpenSettings)
                                Button("切换服务器", systemImage: "server.rack", action: overviewBar.onSwitchServer)
                            }
                        }
                    }
                }
        } else if usesSystemNavigation, let selected {
            boardSurface
                .navigationTitle(selected.title.isEmpty ? "任务详情" : selected.title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden()
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回", systemImage: "chevron.left", action: closeTaskDetail)
                    }
                }
        } else {
            boardSurface
        }
    }

    @ViewBuilder
    private var boardSurface: some View {
        VStack(spacing: 0) {
            if selected == nil && (!embedded || !usesSystemNavigation) { overviewBar }
            boardContent
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private var boardContent: some View {
        Group {
            if let selected {
                VStack(spacing: 0) {
                    if embedded && !usesSystemNavigation {
                        boardDetailChrome(title: selected.title.isEmpty ? "任务详情" : selected.title)
                    }
                    TaskBoardDetailView(
                        api: api,
                        task: selected,
                        childTasks: childTasks(of: selected),
                        workspaces: workspaces,
                        catalog: catalog,
                        lastAgent: lastAgent,
                        busy: busy,
                        employees: contactEmployees, teams: contactTeams, contactsError: contactsError,
                        unconfirmed: unconfirmedDispatches.contains(selected.id),
                        onVerify: { unconfirmedDispatches.remove(selected.id); errorMessage = nil },
                        onContactsRetry: { Task { await loadContacts() } },
                        onPatch: { body in await mutate { _ = try await api.updateBoardTask(id: selected.id, body: body) } },
                        onRemember: rememberAgent,
                        onDispatch: { agent, prompt, subject in
                            await dispatchTask(task: selected, agent: agent, prompt: prompt, subject: subject)
                        },
                        onDelete: {
                            await mutate {
                                try await api.deleteBoardTask(id: selected.id)
                                self.selected = nil
                            }
                        },
                        onOpenSession: openBoardSession,
                        onOpenTask: openTaskDetail,
                        onClose: { self.selected = nil; self.taskPath = [] },
                        onMoveSession: { session in moveSessionTarget = session }
                    )
                    .clipped() // Form 滚动内容不能绘制到独立返回/标题栏。
                }
            } else if loading && tasks.isEmpty {
                ProgressView().tint(Theme.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listContent
            }
        }
    }

    private func boardDetailChrome(title: String) -> some View {
        HStack(spacing: 10) {
            Button {
                closeTaskDetail()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("返回")
                        .font(.wand(size: 15, weight: .medium))
                }
                .foregroundColor(Theme.brand)
            }
            .buttonStyle(WandQuietButtonStyle())
            Text(title)
                .font(.wand(size: 15, weight: .semibold))
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
                if let groupError = workspaceStore.taskGroupsError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("未分组任务读取失败：\(groupError)")
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(Theme.danger)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
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

                ForEach(visibleUnassignedGroups) { group in
                    unassignedGroupSection(group)
                }
                if visibleTasks.isEmpty && visibleUnassignedGroups.isEmpty {
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
            .refreshable {
                expandedUnassignedGroups.removeAll()
                await refresh(showProgress: false)
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 16, for: .scrollContent)
            // 筛选条件变了就把划开状态收掉，否则卡片被筛走后悬浮按钮会一直被藏着。
            .onChange(of: [statusFilter, filterWorkspaceId, query]) { _, _ in
                swipedTaskId = nil
                expandedUnassignedGroups.removeAll()
            }
            // 竖向滚动时也收掉：和系统 swipeActions 一样，否则划开的卡片滚出屏幕后悬浮按钮就回不来了。
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { swipedTaskId = nil }
            }


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
            HStack(spacing: 8) {
                Menu {
                    Button("所有项目") { filterWorkspaceId = "" }
                    ForEach(workspaces) { workspace in Button(workspace.name) { filterWorkspaceId = workspace.id } }
                } label: {
                    Label(workspaces.first(where: { $0.id == filterWorkspaceId })?.name ?? "所有项目", systemImage: "folder")
                        .font(.subheadline).lineLimit(1)
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
                .frame(minHeight: WandLayout.controlTouch)
                Spacer(minLength: 0)
                if !embedded || !usesSystemNavigation {
                    Button { openCreate("backlog") } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 24, height: 28)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.success).buttonBorderShape(.circle)
                    .frame(minWidth: WandLayout.controlTouch, minHeight: WandLayout.controlTouch)
                    .accessibilityLabel("新建任务")
                }
            }
            ViewThatFits(in: .horizontal) {
                statusPicker
                    .pickerStyle(.segmented).tint(Theme.success)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: WandLayout.controlTouch)
                statusPicker
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, minHeight: WandLayout.controlTouch, alignment: .leading)
            }
        }
    }

    private var statusPicker: some View {
        Picker("任务状态", selection: $statusFilter) {
            ForEach([("", "全部"), ("backlog", "待立项"), ("todo", "待办"), ("doing", "进行中"), ("done", "等你确认"), ("archived", "归档")], id: \.0) { value, label in
                Text(label).tag(value)
            }
        }
    }

    private func unassignedGroupSection(_ group: WandBoardUnassignedGroup) -> some View {
        let expanded = expandedUnassignedGroups.contains(group.id)
        return Section {
            Button {
                withAnimation(reduceMotion ? nil : WandMotion.stateSwap) {
                    if expanded { expandedUnassignedGroups.remove(group.id) }
                    else { expandedUnassignedGroups.insert(group.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundColor(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.wand(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\(group.sessions.count) 个会话 · \(TaskListPresentation.shortenWorkspacePath(group.workspaceCwd))")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textMuted)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.title)，\(group.sessions.count) 个会话")
            .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 2, trailing: 14))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            if expanded {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    unassignedSessionRow(session, index: index)
                }
            }
        }
    }

    private func unassignedSessionRow(_ session: WorkspaceSessionSummary, index: Int) -> some View {
        Button {
            expandedUnassignedGroups.removeAll()
            onOpenSession(session.id)
        } label: {
            HStack(spacing: 10) {
                BrandLogo(provider: session.provider ?? "terminal", color: Theme.brand)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(TaskListPresentation.listSessionLabel(
                        title: session.title,
                        providerLabel: session.providerLabel,
                        cwd: session.cwd,
                        index: index
                    ))
                    .font(.wand(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(session.employeeName ?? session.providerLabel)
                        Text("·")
                        Text(HomePresentation.statusLabel(session.activityStatus))
                    }
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开会话 \(session.title ?? session.providerLabel)")
        .listRowInsets(EdgeInsets(top: 4, leading: 38, bottom: 4, trailing: 18))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var boardEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(Theme.success)
            Text(query.isEmpty && statusFilter.isEmpty ? "工作台还是空的" : "没有匹配的任务")
                .font(.wand(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(query.isEmpty && statusFilter.isEmpty ? "点右下角 +，把事情做完。" : "换个筛选条件，或新建一条任务。")
                .font(.wand(size: 13))
                .foregroundColor(Theme.textMuted)
            Button("新建任务", action: { openCreate("backlog") })
                .buttonStyle(WandPrimaryButtonStyle())
                .frame(maxWidth: 180)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func openCreate(_ status: String) {
        let selectedWorkspace = workspaces.first { $0.id == filterWorkspaceId }
        let cwd = selectedWorkspace?.cwd ?? workspaceStore.taskGroups.first(where: { $0.workspaceId == filterWorkspaceId })?.workspaceCwd ?? ""
        errorMessage = nil
        onRequestNewConversation(cwd, selectedWorkspace?.id)
    }

    private func boardSectionHeader(status: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(wandBoardStatusColor(status))
                .frame(width: 8, height: 8)
            Text(WandBoardStatus(rawValue: status)?.label ?? status)
                .font(.wand(size: 13, weight: .semibold))
                .foregroundColor(wandBoardStatusColor(status))
            Text("\(count)")
                .font(.wand(size: 11))
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
                    .font(.wand(size: 13, weight: .semibold))
                Text("\(count)")
                    .font(.wand(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundColor(Theme.textMuted)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func boardRow(_ task: WandBoardTask) -> some View {
        let revealed = swipedTaskId == task.id
        // 划开动作条自己画：系统 swipeActions 的按钮宽度被钳死，会被右下角悬浮按钮盖住。
        TaskBoardSwipeCard(
            status: task.status,
            revealed: revealed,
            onRevealedChange: { open in
                swipedTaskId = open ? task.id : (swipedTaskId == task.id ? nil : swipedTaskId)
            },
            onAction: { action in
                pendingSwipe = (task, action)
            },
            extraActions: [HomeRowAction(id: "detail", title: "详情", symbol: "doc.text", tint: Theme.info) { selected = task }]
                + (task.status == "archived" || task.status == "done" ? [] : [
                    HomeRowAction(id: "archive", title: "归档", symbol: "archivebox", tint: Theme.warning) { pendingSwipe = (task, .archive) }
                ])
        ) {
            TaskBoardRow(
                task: task,
                showWorkspace: filterWorkspaceId.isEmpty,
                // 划开状态下点卡片只收起，不打开详情、不切完成状态（与 Android 的遮罩行为一致）。
                onOpen: {
                    swipedTaskId = nil
                    if !revealed { selected = task }
                },
                onToggleComplete: {
                    if revealed {
                        swipedTaskId = nil
                    } else {
                        Task { await mutate { _ = try await api.updateBoardTask(id: task.id, body: ["status": wandBoardToggledStatus(task.status)]) } }
                    }
                },
                onOpenSession: { sessionId in
                    swipedTaskId = nil
                    if !revealed { onOpenSession(sessionId) }
                }
            )
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
        // 后台轮询不能把已渲染的列表闪回加载态，但显式刷新也不该被吞掉：
        // 先等上一次跑完再发，避免交错赋值（对齐 Android 的 refreshMutex）。
        if let inFlight = refreshInFlight {
            await inFlight.value
        }
        let task = Task { await performRefresh(showProgress: showProgress) }
        refreshInFlight = task
        await task.value
        if refreshInFlight == task { refreshInFlight = nil }
    }

    private func performRefresh(showProgress: Bool) async {
        let generation = operationGeneration
        if showProgress { loading = true }
        do {
            let loadedTasks = try await api.listBoardTasks()
            guard activeView, generation == operationGeneration, !Task.isCancelled else { return }
            tasks = loadedTasks
            refreshError = nil
        } catch {
            guard activeView, generation == operationGeneration, !Task.isCancelled else { return }
            refreshError = error.localizedDescription
        }
        // 默认任务组与正式任务必须同一轮刷新，迟到的 WorkspaceStore 请求由其 generation 丢弃。
        await workspaceStore.loadTaskGroups(force: true)
        guard activeView, generation == operationGeneration, !Task.isCancelled else { return }
        loading = false
        // 卡片被筛掉或已经不在列表里（改状态、归档）时，清掉划开状态。
        if let id = swipedTaskId, !tasks.contains(where: { $0.id == id }) { swipedTaskId = nil }
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

    private func sessionMoveTitle(_ session: WandBoardTaskSession) -> String {
        session.title.isEmpty ? wandBoardProviderLabel(session.provider) : session.title
    }

    /// 已绑定任务的会话要连着任务上下文打开，否则侧栏/详情标题都会丢掉归属。
    private func openBoardSession(_ sessionId: String) {
        let owner = tasks.first { task in task.sessions.contains { $0.id == sessionId } }
        if let bound = onOpenBoundSession,
           let workspaceTaskId = owner?.workspaceTaskId,
           !workspaceTaskId.isEmpty {
            bound(sessionId, workspaceTaskId)
            return
        }
        onOpenSession(sessionId)
    }

    /// 当前任务的直接子任务：既是「可引用任务」列表，也是评论里 `#` 能选到的范围。
    private func childTasks(of task: WandBoardTask) -> [WandBoardTask] {
        tasks.filter { $0.parentTaskId == task.id }
    }

    /// 打开子任务详情；父任务留在栈里，返回时逐层回退。
    private func openTaskDetail(_ task: WandBoardTask) {
        if let current = selected, current.id != task.id { taskPath.append(current) }
        selected = task
    }

    private func closeTaskDetail() {
        if !taskPath.isEmpty {
            selected = taskPath.removeLast()
        } else {
            selected = nil
        }
    }

    private func loadContacts() async {
        async let people = try? api.listContactEmployees()
        async let teams = try? api.listContactTeams()
        let (p, t) = await (people, teams)
        guard !Task.isCancelled else { return }
        if let p { contactEmployees = p }; if let t { contactTeams = t }
        contactsError = p == nil || t == nil ? "通讯录未能完整刷新，已有资料已保留。" : nil
    }
    private func dispatchTask(task: WandBoardTask, agent: WandBoardTaskAgent, prompt: String,
                              subject: ContactExecutionSubject?) async -> Bool {
        guard activeView, !busy, !unconfirmedDispatches.contains(task.id) else { return false }
        let actionGeneration = operationGeneration
        busy = true
        defer { busy = false }
        do {
            let result: WandBoardDispatchResult
            if let subject { result = try await api.dispatchContactTask(id: task.id, subject: subject, prompt: prompt) }
            else { result = try await api.dispatchBoardTask(id: task.id, agent: agent, prompt: prompt); rememberAgent(agent) }
            guard result.ok, result.taskId == task.id, result.queued || !result.sessionId.isEmpty else { throw WandAPI.APIError.network("派发回执无效") }
            await refresh(showProgress: false)
            guard activeView, actionGeneration == operationGeneration, selected?.id == task.id, !Task.isCancelled else { return true }
            selected = tasks.first { $0.id == task.id } ?? selected
            busy = false
            if result.queued { return true }
            if let runID = result.teamRun?.run.id, let onOpenTeamRun { onOpenTeamRun(runID) }
            else { openBoardSession(result.sessionId) }
            return true
        } catch {
            if !isDefiniteInputRejection(error) { unconfirmedDispatches.insert(task.id) }
            errorMessage = unconfirmedDispatches.contains(task.id) ? "指派结果未确认，请核对任务会话，勿重复派发。" : error.localizedDescription
            return false
        }
    }

    private func mutate(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
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

/// 任务状态的中文标签；未知状态回落到原值。
func wandBoardStatusLabel(_ status: String) -> String {
    guard let status = WandBoardStatus(rawValue: status) else { return status }
    return status.label
}

private func wandBoardSwipeActionColor(_ action: WandBoardSwipeAction) -> Color {
    switch action {
    case .start: return Theme.success
    case .complete: return Theme.info
    case .archive: return Theme.danger
    }
}

/// 看板卡的划开动作条，自己画而不是用 `List` 的 `swipeActions`。
///
/// 系统 `swipeActions` 把动作按钮钳在约 50pt 宽，而且整行都在列表里：卡片贴到右下角悬浮的
/// 「新建任务」时，露出的按钮大半被悬浮按钮盖着，点它只会变成新建任务。这里按 Android
/// `BoardTaskSwipeCard` 的做法 —— 卡片向左平移露出固定宽度的动作按钮，同一时刻只允许一张卡
/// 划开（`revealed` 由调用方持有），划开期间调用方把悬浮按钮藏起来，动作按钮就始终点得到。
private struct TaskBoardSwipeCard<Content: View>: View {
    let status: String
    let revealed: Bool
    let onRevealedChange: (Bool) -> Void
    let onAction: (WandBoardSwipeAction) -> Void
    var extraActions: [HomeRowAction] = []
    @ViewBuilder let content: () -> Content

    private var actions: [HomeRowAction] {
        guard let action = wandBoardSwipeAction(for: status) else { return extraActions }
        return [HomeRowAction(id: "status", title: wandBoardSwipeActionLabel(action),
            symbol: wandBoardSwipeSystemImage(action), tint: wandBoardSwipeActionColor(action)) {
            onAction(action)
        }] + extraActions
    }
    var body: some View {
        HomeSwipeRow(id: "board", revealedID: Binding(
            get: { revealed ? "board" : nil },
            set: { onRevealedChange($0 != nil) }), actions: actions, enabled: !actions.isEmpty) { content() }
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
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: WandLayout.fieldGap) {
            HomeSearchField(placeholder: "搜索任务", text: $query, focused: $searchFocused)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(projectName).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(stats.remaining) 项未完成").fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(projectName)
                    Text("\(stats.remaining) 项未完成")
                }
            }
            .font(.subheadline).foregroundStyle(Theme.textSecondary)
            let metricsLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .top, spacing: WandLayout.fieldGap))
            metricsLayout {
                metricTile("待办", value: stats.todo, color: wandBoardStatusColor("todo"))
                metricTile("进行中", value: stats.doing, color: wandBoardStatusColor("doing"))
                metricTile("已验收", value: stats.accepted, color: Theme.success)
            }
        }
        .padding(.vertical, 4)
    }

    private func metricTile(_ label: String, value: Int, color: Color) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: WandLayout.fieldGap))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        return layout {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

///
/// 任务卡：标题行 / 摘要 / 元信息 / 会话 / 状态五段纵向排列，段与段之间留 10pt。
/// 与 Android `BoardTaskCard` 同一套顺序与截断规则：
///
/// - 勾选圈、标题、任务编号一行：编号贴右，扫一眼就能对上号；
/// - 元信息统一成 8pt 圆角细边框小芯片（胶囊只留给状态圆点与计数）；
/// - 会话不再是一排同名胶囊：左侧一根分组细线 + 每行「工具徽标 + 会话标题 + 运行跳动点」，
///   点得到具体那一个终端，超出的会话折成「+N 个会话」；
/// - 状态行（正在处理 / 等待验收）压到卡片底部当页脚，顺序对齐 Web 任务卡。
private struct TaskBoardRow: View {
    let task: WandBoardTask
    var showWorkspace = true
    var onOpen: () -> Void = {}
    var onToggleComplete: () -> Void = {}
    var onOpenSession: (String) -> Void = { _ in }

    private var done: Bool { task.status == "done" || task.status == "archived" }
    private var model: WandBoardTaskCardModel { wandBoardCardModel(task, showWorkspace: showWorkspace) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HomeExecutionBadge(state: HomePresentation.executionState(task)).padding(.top, 6)
            Text(task.acceptance?.acceptedAt != nil ? "验收通过 · 已完成" : task.acceptance?.blocker.isEmpty == false ? "待处理：\(task.acceptance?.blocker ?? "")" : "未验收")
                .font(.caption).foregroundStyle(task.acceptance?.acceptedAt != nil ? Theme.success : Theme.textSecondary)
                .lineLimit(2).padding(.top, 6)
            if let summary = model.body {
                Text(summary)
                    .font(.wand(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            if model.hasChips {
                metaChips.padding(.top, 10)
            }
            if !model.sessions.isEmpty || model.extraSessionCount > 0 {
                sessionBlock.padding(.top, 10)
            }
            if let processing = model.processingLabel {
                HStack(spacing: 6) {
                    Circle().fill(Theme.success).frame(width: 7, height: 7)
                    Text(processing)
                        .font(.wand(size: 11))
                        .foregroundColor(Theme.success)
                }
                .padding(.top, 10)
            }
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
        // 整张卡可点开详情；卡片里的会话行、勾选圈是各自的按钮，点它们不会走这一层。
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggleComplete) {
                BoardStatusCheck(status: task.status)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            Text(model.title)
                .font(.wand(size: 16, weight: .semibold))
                .foregroundColor(done ? Theme.textMuted : Theme.textPrimary)
                .strikethrough(task.acceptance?.acceptedAt != nil)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let identifier = model.identifier {
                Text(identifier)
                    .font(.wand(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .padding(.top, 3)
                    .accessibilityLabel("任务编号 \(identifier)")
            }
        }
    }

    private var metaChips: some View {
        FlowLayout(spacing: 6) {
            if let name = model.workspaceName {
                boardMetaChip(name, icon: "folder")
            }
            if let name = model.milestoneName {
                boardMetaChip(name, icon: "flag")
            }
            if let priority = model.priority {
                let color = wandBoardPriorityColor(priority)
                boardMetaChip(
                    WandBoardPriority(rawValue: priority)?.label ?? priority,
                    icon: "chart.bar.fill",
                    color: color,
                    fill: color.opacity(0.14),
                    stroke: color.opacity(0.32)
                )
            }
            ForEach(model.labels, id: \.self) { label in
                boardMetaChip(label)
            }
            if model.extraLabelCount > 0 {
                Text("+\(model.extraLabelCount)")
                    .font(.wand(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .frame(height: 22)
            }
            if let due = model.due {
                boardMetaChip(
                    due.label,
                    icon: "calendar",
                    color: due.overdue ? Theme.danger : Theme.textSecondary,
                    fill: due.overdue ? Theme.danger.opacity(0.14) : nil,
                    stroke: due.overdue ? Theme.danger.opacity(0.32) : nil
                )
                .accessibilityLabel(due.overdue ? "截止 \(due.label)，已逾期" : "截止 \(due.label)")
            }
            if let agent = model.agentLabel {
                boardMetaChip(agent, icon: "sparkles")
            }
        }
    }

    private var sessionBlock: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.border)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.sessions) { session in
                    Button {
                        onOpenSession(session.id)
                    } label: {
                        HStack(spacing: 6) {
                            BrandLogo(
                                provider: session.provider.isEmpty ? "terminal" : session.provider,
                                color: Theme.textPrimary
                            )
                            .frame(width: 12, height: 12)
                            Text(session.label)
                                .font(.wand(size: 12))
                                .foregroundColor(session.running ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if session.running { BoardAgentDots() }
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开会话 \(session.label)")
                }
                if model.extraSessionCount > 0 {
                    Button(action: onOpen) {
                        Text("+\(model.extraSessionCount) 个会话")
                            .font(.wand(size: 11))
                            .foregroundColor(Theme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 10)
        }
    }

    /// 元信息芯片：8pt 圆角细边框，不是胶囊——胶囊只有状态圆点和计数才用。
    /// 语义色芯片（优先级 / 逾期）靠弱底色 + 同色文字区分，不额外造一套图标。
    private func boardMetaChip(
        _ label: String,
        icon: String? = nil,
        color: Color = Theme.textSecondary,
        fill: Color? = nil,
        stroke: Color? = nil
    ) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(.wand(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .frame(maxWidth: 170, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill ?? Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(stroke ?? Theme.border, lineWidth: 0.5)
        )
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
        .accessibilityLabel(done ? "重新打开任务" : "转为等你确认")
    }
}

private struct BoardAgentDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: WandMotion.activityTick, paused: reduceMotion)) { context in
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

@MainActor private enum IosTaskAcceptanceDrafts {
    static var values: [String: (evidence: String, blocker: String)] = [:]
}

private struct TaskBoardDetailView: View {
    let api: WandAPI
    let task: WandBoardTask
    /// 当前任务的直接子任务：可引用任务列表与评论里 `#` 的可选范围。
    let childTasks: [WandBoardTask]
    let workspaces: [Workspace]
    let catalog: ModelsResponse?
    let lastAgent: WandBoardTaskAgent
    let busy: Bool
    let employees: [SiliconEmployee]
    let teams: [ContactTeam]
    let contactsError: String?
    let unconfirmed: Bool
    let onVerify: () -> Void
    let onContactsRetry: () -> Void
    let onPatch: ([String: Any]) async -> Void
    let onRemember: (WandBoardTaskAgent) -> Void
    let onDispatch: (WandBoardTaskAgent, String, ContactExecutionSubject?) async -> Bool
    let onDelete: () async -> Void
    let onOpenSession: (String) -> Void
    let onOpenTask: (WandBoardTask) -> Void
    let onMoveSession: (WandBoardTaskSession) -> Void
    let onClose: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var agent: WandBoardTaskAgent
    @State private var composePrompt = ""
    @State private var subject: ContactExecutionSubject?
    @State private var commentState = WandTaskCommentState()
    @State private var replyCommentId: String?
    /// 本次回复是否要派发员工（决定评论框里是否预填 `@`）。
    @State private var replyDispatches = false
    /// 正在定位的原评论。
    @State private var locatedCommentId: String?
    @State private var legacyDispatchOpen = false
    @State private var acceptanceEvidence: String
    @State private var acceptanceBlocker: String

    init(
        api: WandAPI,
        task: WandBoardTask,
        childTasks: [WandBoardTask] = [],
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        lastAgent: WandBoardTaskAgent,
        busy: Bool,
        employees: [SiliconEmployee], teams: [ContactTeam], contactsError: String?, unconfirmed: Bool,
        onVerify: @escaping () -> Void, onContactsRetry: @escaping () -> Void,
        onPatch: @escaping ([String: Any]) async -> Void,
        onRemember: @escaping (WandBoardTaskAgent) -> Void,
        onDispatch: @escaping (WandBoardTaskAgent, String, ContactExecutionSubject?) async -> Bool,
        onDelete: @escaping () async -> Void,
        onOpenSession: @escaping (String) -> Void,
        onOpenTask: @escaping (WandBoardTask) -> Void = { _ in },
        onClose: @escaping () -> Void,
        onMoveSession: @escaping (WandBoardTaskSession) -> Void = { _ in }
    ) {
        self.api = api
        self.task = task
        self.childTasks = childTasks
        self.workspaces = workspaces
        self.catalog = catalog
        self.lastAgent = lastAgent
        self.busy = busy; self.employees = employees; self.teams = teams
        self.contactsError = contactsError; self.unconfirmed = unconfirmed
        self.onVerify = onVerify; self.onContactsRetry = onContactsRetry
        self.onPatch = onPatch
        self.onRemember = onRemember
        self.onDispatch = onDispatch
        self.onDelete = onDelete
        self.onOpenSession = onOpenSession
        self.onOpenTask = onOpenTask
        self.onClose = onClose
        self.onMoveSession = onMoveSession
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _agent = State(initialValue: task.agent ?? lastAgent)
        _subject = State(initialValue: task.executionSubject?.type == "team" ? task.executionSubject : nil)
        _acceptanceEvidence = State(initialValue: IosTaskAcceptanceDrafts.values[task.id]?.evidence ?? task.acceptance?.evidence ?? "")
        _acceptanceBlocker = State(initialValue: IosTaskAcceptanceDrafts.values[task.id]?.blocker ?? task.acceptance?.blocker ?? "")
    }

    var body: some View {
        ScrollViewReader { scroll in
            detailForm(scroll: scroll)
        }
        .onChange(of: acceptanceEvidence) { _, _ in cacheAcceptanceDraft() }
        .onChange(of: acceptanceBlocker) { _, _ in cacheAcceptanceDraft() }
    }

    private func detailForm(scroll: ScrollViewProxy) -> some View {
        Form {
            if !commentState.visible(taskId: task.id).isEmpty {
                Section {
                    ForEach(commentState.visible(taskId: task.id)) { comment in
                        commentRow(comment)
                    }
                    if let cursor = commentState.nextCursor, !cursor.isEmpty {
                        Button("加载更早的评论") { loadOlderComments(cursor) }
                            .font(.caption)
                    }
                } header: {
                    HStack {
                        Text("评论")
                        Spacer()
                        Button { Task { await refreshComments() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("刷新评论")
                    }
                }
            }
            Section("评论与员工派发") {
                TaskCommentComposer(api: api, taskId: task.id,
                                    employees: employees.filter { !$0.archived }.map { (id: $0.id, name: $0.name) },
                                    referenceTasks: referenceTargets,
                                    sourceCommentId: $replyCommentId,
                                    replyDispatches: $replyDispatches,
                                    onRevealSubmit: {
                                        scroll.scrollTo(TaskCommentComposer.submitAnchor(taskId: task.id), anchor: .bottom)
                                    }) {
                    await refreshComments()
                }.id(TaskCommentComposer.submitAnchor(taskId: task.id))
            }
            Section("内容") {
                TextField("任务标题", text: $title)
                TextField("描述", text: $description, axis: .vertical)
                    .lineLimit(4...10)
                Button("保存标题与描述") {
                    Task { await onPatch(["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "description": description]) }
                }
                .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("可引用任务") {
                if childTasks.isEmpty {
                    Text("当前任务没有子任务。").font(.caption).foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(childTasks) { child in
                        Button { onOpenTask(child) } label: {
                            HStack(spacing: 8) {
                                Text("#\(child.identifier)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.brandText)
                                Text(child.title)
                                    .font(.callout)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(child.displayStatusLabel)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开子任务 \(child.identifier)，\(child.title)，\(child.displayStatusLabel)")
                    }
                }
            }
            Section("交付与验收") {
                Text("会话运行中、空闲、结束、失败或归档，都不代表任务验收通过。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(task.acceptance?.acceptedAt != nil ? "验收通过 · 已完成" : task.acceptance?.blocker.isEmpty == false ? "待处理 · 有验收缺口" : "未验收 · 待汇总交付")
                    .font(.subheadline.weight(.semibold))
                Text("由任务负责人统一核对各会话产物；等待信息／授权／部署／验收时写明原因与下一步。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                TextField("交付证据、产物路径或源会话", text: $acceptanceEvidence, axis: .vertical)
                    .lineLimit(2...6)
                TextField("待处理原因、授权或部署阻塞（无则留空）", text: $acceptanceBlocker, axis: .vertical)
                    .lineLimit(2...4)
                if task.acceptance?.acceptedAt != nil {
                    Label("已确认验收通过", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.success)
                    Button("保存并重新验收") { saveAcceptance(accepted: false) }
                } else {
                    if !childTasks.filter({ $0.acceptance?.acceptedAt == nil }).isEmpty {
                        Text("仍有子任务未验收通过，主目标不能通过。")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                    HStack {
                        Button("保存交付与缺口") { saveAcceptance(accepted: false) }
                        Button("确认验收通过") { saveAcceptance(accepted: true) }
                            .disabled(busy || acceptanceEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || !acceptanceBlocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || childTasks.contains { $0.acceptance?.acceptedAt == nil })
                    }
                }
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
                Picker("工作区", selection: Binding(
                    get: { task.workspaceId ?? "" },
                    set: { value in
                        Task { await onPatch(["workspaceId": value.isEmpty ? NSNull() : value]) }
                    }
                )) {
                    Text("未归属工作区（使用临时目录）").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
            }
            Section {
              DisclosureGroup("CLI / 团队兼容派发", isExpanded: $legacyDispatchOpen) {
                TextField("提示词", text: $composePrompt, prompt: Text("输入这次派给 Agent 的提示词。任务描述不会自动带上。"), axis: .vertical)
                    .lineLimit(3...8)
                ContactExecutionSubjectPicker(subject: $subject, employees: [], teams: teams,
                    teamAllowed: task.workspaceId != nil && task.workspaceId != "wand-global", error: contactsError, onRetry: onContactsRetry)
                if subject == nil {
                Picker("执行工具", selection: Binding(
                    get: { WandAgentTool(provider: agent.provider, engine: agent.engine).rawValue },
                    set: { id in
                        guard let tool = WandAgentTool(rawValue: id) else { return }
                        let provider = tool.provider.rawValue
                        agent.engine = tool.engine
                        agent.provider = provider
                        agent.mode = wandBoardNormalizedMode(provider: provider, mode: agent.mode)
                        let options = wandBoardModelOptions(from: catalog, provider: provider)
                        if !options.contains(where: { $0.id == agent.model }) {
                            agent.model = options.first?.id ?? "default"
                        }
                        onRemember(agent)
                    }
                )) {
                    ForEach(WandAgentTool.allCases) { tool in Text(tool.title).tag(tool.rawValue) }
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
                }
                if unconfirmed {
                    Text("指派结果未确认，请先核对任务会话。").font(.caption).foregroundStyle(Theme.danger)
                    Button("我已核对，开始新的指派", action: onVerify).font(.caption)
                }
                Button(task.sessions.isEmpty ? "新建执行会话" : "新建并行会话") {
                    let submitted = composePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    let draftAtStart = composePrompt
                    Task { if await onDispatch(agent, submitted, subject), composePrompt == draftAtStart { composePrompt = "" } }
                }
                .disabled(busy || unconfirmed || composePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !subjectAvailable)
              }
            }
            Section("任务内的会话") {
                Text("\(task.sessions.count) 个关联会话 · \(wandBoardSessionSummary(task.sessions))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Text("独立范围才并行；同目录或同文件重叠先协调串行，或隔离后合并。业务子任务须独立验收，不包含模型内部子 Agent。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                let groups = wandBoardSessionGroups(sessions: task.sessions, assigned: task.agent)
                if groups.isEmpty {
                    Text("还没有关联会话。在下面输入提示词后再派发，任务描述不会自动带上。")
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(wandBoardAgentTitle(group.provider, group.agent, catalog))
                                .font(.subheadline.weight(.semibold))
                            if group.sessions.isEmpty {
                                Text("默认执行参数 · 尚无关联会话")
                                    .font(.caption)
                                    .foregroundColor(Theme.textMuted)
                            } else {
                                ForEach(group.sessions) { session in
                                    HStack(spacing: 8) {
                                        Button { onOpenSession(session.id) } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: 6) {
                                                    BrandLogo(provider: session.provider, color: Theme.textPrimary)
                                                        .frame(width: 14, height: 14)
                                                    Text(session.displayPurpose.isEmpty ? wandBoardProviderLabel(session.provider) : session.displayPurpose)
                                                        .lineLimit(1)
                                                    Spacer(minLength: 4)
                                                    Text(session.activityLabel)
                                                        .font(.caption2)
                                                        .foregroundColor(Theme.textMuted)
                                                }
                                                Text([session.employeeName, session.cwd, wandModelDisplayName(session.provider, session.model, catalog)]
                                                    .compactMap { value in value?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                                    .joined(separator: " · "))
                                                    .font(.caption)
                                                    .foregroundColor(Theme.textMuted)
                                                Text("继续此会话")
                                                    .font(.caption2.weight(.medium))
                                                    .foregroundColor(Theme.brand)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        Button { onMoveSession(session) } label: {
                                            Image(systemName: "folder")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(Theme.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(busy)
                                        .accessibilityLabel("移动会话到其他任务")
                                    }
                                    .padding(.vertical, 3)
                                }
                                Text("每次派发都会创建独立执行；需要并行处理请新建会话，不把业务子任务当作同一会话继续。")
                                    .font(.caption2)
                                    .foregroundColor(Theme.textMuted)
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
        .disabled(busy)
        .task(id: task.id) {
            let taskId = task.id
            while !Task.isCancelled {
                await refreshComments(taskId: taskId)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: task.id) { _, _ in
            title = task.title
            description = task.description
            agent = task.agent ?? lastAgent; subject = task.executionSubject?.type == "team" ? task.executionSubject : nil
            acceptanceEvidence = IosTaskAcceptanceDrafts.values[task.id]?.evidence ?? task.acceptance?.evidence ?? ""
            acceptanceBlocker = IosTaskAcceptanceDrafts.values[task.id]?.blocker ?? task.acceptance?.blocker ?? ""
            replyCommentId = nil; replyDispatches = false; locatedCommentId = nil; legacyDispatchOpen = false
            composePrompt = ""
        }
    }
    private var subjectAvailable: Bool {
        guard let subject else { return true }
        if subject.type == "employee" { return employees.contains { $0.id == subject.id && !$0.archived && !$0.agents.isEmpty } }
        return subject.type == "team" && task.workspaceId != nil && task.workspaceId != "wand-global" && teams.contains { $0.id == subject.id }
    }

    // MARK: - 评论与引用

    /// 可引用任务：只认当前任务的直接子任务（编号 + 标题 + 状态）。
    private var referenceTargets: [TaskReferenceTarget] {
        childTasks.map {
            TaskReferenceTarget(id: $0.id, identifier: $0.identifier, title: $0.title, status: wandBoardStatusLabel($0.status))
        }
    }

    private func employee(for id: String) -> SiliconEmployee? {
        employees.first { $0.id == id }
    }

    private func commentRow(_ comment: WandTaskComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(comment.authorName).font(.subheadline.weight(.semibold))
                Spacer()
                Text(comment.createdAt).font(.caption).foregroundStyle(.secondary)
            }
            TaskCommentBodyView(body: comment.body) { identifier in
                openReferencedTask(identifier)
            }
            if let dispatch = comment.dispatch {
                TaskCommentExecutionCard(api: api, taskId: task.id, comment: comment,
                                         employee: employee(for: dispatch.employeeId),
                                         onOpenSession: onOpenSession,
                                         referencedIdentifiers: TaskCommentReferenceTargets.identifiers(for: comment, children: referenceTargets),
                                         onOpenReferencedTask: openReferencedTask)
            }
            HStack(spacing: 12) {
                Button("回复") {
                    replyDispatches = false
                    replyCommentId = comment.id
                }
                .font(.caption)
                Button("回复并派发") {
                    replyDispatches = true
                    replyCommentId = comment.id
                }
                .font(.caption)
                if let dispatch = comment.dispatch {
                    Button("查看员工执行事项") {
                        if let sessionId = dispatch.sessionId { onOpenSession(sessionId) }
                    }
                    .font(.caption)
                    .disabled(dispatch.sessionId == nil)
                }
                if let sourceCommentId = comment.sourceCommentId, !sourceCommentId.isEmpty {
                    Button("定位原评论") { locatedCommentId = sourceCommentId }
                        .font(.caption)
                }
            }
            if locatedCommentId == comment.id {
                HStack {
                    Label("原评论", systemImage: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.brandText)
                    Spacer()
                    Button("取消定位") { locatedCommentId = nil }.font(.caption2)
                }
            }
        }
    }

    /// 正文里的 `#TASK-133` 只能跳到本任务的子任务。
    private func openReferencedTask(_ identifier: String) {
        guard let child = childTasks.first(where: { $0.identifier == identifier }) else { return }
        onOpenTask(child)
    }

    private func cacheAcceptanceDraft() {
        if IosTaskAcceptanceDrafts.values.count >= 100, let oldest = IosTaskAcceptanceDrafts.values.keys.first { IosTaskAcceptanceDrafts.values.removeValue(forKey: oldest) }
        IosTaskAcceptanceDrafts.values[task.id] = (acceptanceEvidence, acceptanceBlocker)
    }

    private func saveAcceptance(accepted: Bool) {
        let evidence = acceptanceEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocker = acceptanceBlocker.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: [String: Any] = [
            "evidence": acceptanceEvidence,
            "blocker": acceptanceBlocker,
            "acceptedAt": accepted ? ISO8601DateFormatter().string(from: Date()) : NSNull()
        ]
        guard !accepted || (!evidence.isEmpty && blocker.isEmpty && !childTasks.contains { $0.acceptance?.acceptedAt == nil }) else { return }
        Task { await onPatch(["acceptance": value]) }
    }

    private func refreshComments(taskId: String? = nil) async {
        let id = taskId ?? task.id
        let requestId = commentState.begin(taskId: id)
        if let page = try? await api.boardTaskCommentsPage(id: id), !Task.isCancelled {
            commentState.mergeFirstPage(page.comments, totalCount: page.totalCount, nextCursor: page.nextCursor,
                                        taskId: id, requestId: requestId)
        }
    }

    /// 翻出更早一页的评论：只校验任务归属，轮询会换请求标识，不能拿它当守卫。
    private func loadOlderComments(_ cursor: String) {
        let id = task.id
        Task {
            if let page = try? await api.boardTaskCommentsPage(id: id, before: cursor), !Task.isCancelled {
                commentState.prependOlderPage(page.comments, nextCursor: page.nextCursor, taskId: id)
            }
        }
    }
}

private struct TaskBoardCreateView: View {
    let workspaces: [Workspace]
    let catalog: ModelsResponse?
    let lastAgent: WandBoardTaskAgent
    let employees: [SiliconEmployee]
    let teams: [ContactTeam]
    let contactsError: String?
    let unconfirmed: Bool
    let onVerify: () -> Void
    let onContactsRetry: () -> Void
    let defaultWorkspaceId: String
    var busy = false
    var error: String?
    let onCreate: (String, String, String, String, String?, WandBoardTaskAgent, ContactExecutionSubject?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var status: String
    @State private var priority = "none"
    @State private var workspaceId = ""
    @State private var agent: WandBoardTaskAgent
    @State private var subject: ContactExecutionSubject?

    init(
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        lastAgent: WandBoardTaskAgent,
        employees: [SiliconEmployee], teams: [ContactTeam], contactsError: String?, unconfirmed: Bool,
        onVerify: @escaping () -> Void, onContactsRetry: @escaping () -> Void,
        defaultWorkspaceId: String,
        initialStatus: String = "todo",
        busy: Bool = false,
        error: String? = nil,
        onCreate: @escaping (String, String, String, String, String?, WandBoardTaskAgent, ContactExecutionSubject?) async -> Void
    ) {
        self.workspaces = workspaces
        self.catalog = catalog
        self.lastAgent = lastAgent; self.employees = employees; self.teams = teams
        self.contactsError = contactsError; self.unconfirmed = unconfirmed
        self.onVerify = onVerify; self.onContactsRetry = onContactsRetry
        self.defaultWorkspaceId = defaultWorkspaceId
        self.busy = busy
        self.error = error
        self.onCreate = onCreate
        _status = State(initialValue: initialStatus)
        _agent = State(initialValue: lastAgent)
    }

    /// 「进行中」列的新建代表已经决定要跑，所以创建后立刻派 Agent；其他列只落库。
    private var dispatches: Bool { wandBoardCreateDispatches(status: status) }

    var body: some View {
        NavigationStack {
            Form {
                Text("与会话树共用同一个任务分组。")
                    .font(.footnote)
                    .foregroundColor(Theme.textMuted)
                if busy {
                    HStack { ProgressView(); Text("正在创建任务，请稍候…") }
                } else if !subjectAvailable {
                    Text("所选执行主体当前不可用，请重新选择。").foregroundStyle(Theme.danger)
                } else if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("填写标题或描述后即可创建任务。").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                TextField("任务标题（可选）", text: $title, prompt: Text("不填写则按描述自动生成"))
                TextField(dispatches ? "描述（作为第一次指派）" : "描述（只创建任务）", text: $description, axis: .vertical)
                    .lineLimit(3...8)
                Picker("工作区", selection: $workspaceId) {
                    Text("未归属工作区（使用临时目录）").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                ContactExecutionSubjectPicker(subject: $subject, employees: employees, teams: teams,
                    teamAllowed: !workspaceId.isEmpty && workspaceId != "wand-global", error: contactsError, onRetry: onContactsRetry)
                if subject == nil {
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
                }
                if unconfirmed {
                    Text("创建结果未确认，请先核对任务列表。").font(.caption).foregroundStyle(Theme.danger)
                    Button("我已核对，开始新的创建操作", action: onVerify).font(.caption)
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
            .disabled(busy)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Theme.surface)
                }
            }
            .navigationTitle("新建任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
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
                                agent,
                                subject
                            )
                        }
                    }
                    .disabled(busy || unconfirmed || !subjectAvailable || (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .onAppear { workspaceId = defaultWorkspaceId }
        .interactiveDismissDisabled(busy)
    }
    private var subjectAvailable: Bool {
        guard let subject else { return true }
        if subject.type == "employee" { return employees.contains { $0.id == subject.id && !$0.archived && !$0.agents.isEmpty } }
        return subject.type == "team" && !workspaceId.isEmpty && workspaceId != "wand-global" && teams.contains { $0.id == subject.id }
    }

}

/**
 * 新建任务是否顺带完成第一次指派。
 * 「待办」列只创建任务；「进行中」列代表已经决定要跑，所以创建后立刻派给所选 Agent。
 */
func wandBoardCreateDispatches(status: String) -> Bool { status == "doing" }
