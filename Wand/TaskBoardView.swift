import SwiftUI

struct TaskBoardView: View {
    let api: WandAPI
    /// 任务看板与会话树共用同一套任务/终端：看板里移动会话要直接改归属。
    @ObservedObject var workspaceStore: WorkspaceStore
    var linkedWorkspaceId: String? = nil
    let onOpenSession: (String) -> Void
    /// 会话已绑定任务时优先打开任务上下文（对齐 web / Android 的 openSessionWithOwningTask）。
    var onOpenBoundSession: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var embedded: Bool = false
    var refreshNonce: Int = 0

    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [WandBoardTask] = []
    @State private var workspaces: [Workspace] = []
    @State private var catalog: ModelsResponse?
    @State private var loading = true
    @State private var refreshInFlight: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var moveSessionTarget: WandBoardTaskSession?
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
    /// 当前划开的卡片：同一时刻只允许一张，划开期间悬浮「新建任务」让位，动作条始终点得到。
    @State private var swipedTaskId: String?

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
                busy: busy,
                error: errorMessage
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
                        var dispatchError: String?
                        do {
                            _ = try await api.dispatchBoardTask(id: created.id, agent: agent, prompt: description)
                        } catch {
                            dispatchError = "任务已创建，但第一次指派失败：\(error.localizedDescription)"
                        }
                        await refresh(showProgress: false)
                        // refresh 成功会清掉旧错误，所以错误必须放在刷新之后写回。
                        if let dispatchError { errorMessage = dispatchError }
                    }
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       created.titleSource == "auto" {
                        Task { await awaitGeneratedTitle(taskId: created.id, placeholder: created.title) }
                    }
                }
            }
        }
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
        .onChange(of: refreshNonce) { _, _ in
            Task { await refresh(showProgress: false) }
        }
        .alert("任务操作失败", isPresented: Binding(
            // 新建弹窗上时用弹窗内联错误，弹窗外再弹 alert 会与 sheet 争同一个呈现通道。
            get: { errorMessage != nil && !showCreate },
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
                                if !result.sessionId.isEmpty { openBoardSession(result.sessionId) }
                            }
                        },
                        onDelete: {
                            await mutate {
                                try await api.deleteBoardTask(id: selected.id)
                                self.selected = nil
                            }
                        },
                        onOpenSession: openBoardSession,
                        onClose: { self.selected = nil },
                        onMoveSession: { session in moveSessionTarget = session }
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
            // 筛选条件变了就把划开状态收掉，否则卡片被筛走后悬浮按钮会一直被藏着。
            .onChange(of: [statusFilter, filterWorkspaceId, query]) { _, _ in
                swipedTaskId = nil
            }
            // 竖向滚动时也收掉：和系统 swipeActions 一样，否则划开的卡片滚出屏幕后悬浮按钮就回不来了。
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard swipedTaskId != nil else { return }
                        let dx = abs(value.translation.width)
                        let dy = abs(value.translation.height)
                        if dy > dx, dy > 8 {
                            swipedTaskId = nil
                        }
                    }
            )

            if swipedTaskId == nil {
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
            }
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
        if showProgress { loading = true }
        do {
            tasks = try await api.listBoardTasks()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 跟手期间的额外位移；松手和 `revealed` 一起写回，交给同一帧动画。
    @State private var dragTranslation: CGFloat = 0
    /// 只有横向占优的拖动才跟手，竖直方向的滑动留给列表滚动。
    @State private var draggingHorizontally = false

    private var action: WandBoardSwipeAction? { wandBoardSwipeAction(for: status) }

    var body: some View {
        if let action {
            ZStack(alignment: .trailing) {
                content()
                    // 卡片自身半透明，底下垫一层页面底色，否则动作条颜色会透上来。
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.background)
                    )
                    .offset(x: offset)
                // 动作按钮盖在卡片上面、但只露出被推开的宽度：`.offset` 不会带走命中区域，
                // 用遮罩盖卡片的话动作条永远点不到（点下去只会被遮罩收起）。
                actionButton(action)
                    .frame(width: max(0, -offset), alignment: .trailing)
                    .clipped()
                    .allowsHitTesting(revealed || draggingHorizontally)
                    .accessibilityHidden(!revealed)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: revealed)
            // 和列表的滚动手势并存：动作条要能拖，列表也要能滚。
            .simultaneousGesture(dragGesture)
        } else {
            content()
        }
    }

    private var offset: CGFloat {
        let base = revealed ? -wandBoardSwipeActionWidth : 0
        guard draggingHorizontally, dragTranslation != 0 else { return base }
        return min(0, max(-wandBoardSwipeActionWidth, base + dragTranslation))
    }

    private var dragGesture: some Gesture {
        // 12pt 起手：点按照常穿透到卡片里的按钮，不会误判成滑动。
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = value.translation.width
                draggingHorizontally = abs(dx) > abs(value.translation.height)
                dragTranslation = dx
            }
            .onEnded { value in
                let dx = value.translation.width
                let horizontal = abs(dx) > abs(value.translation.height)
                let settled = min(
                    0,
                    max(-wandBoardSwipeActionWidth, (revealed ? -wandBoardSwipeActionWidth : 0) + (horizontal ? dx : 0))
                )
                // SwiftUI 只给惯性预测终点，按固定视界折回速度，喂给与 Android 同一个判定函数。
                let velocity = horizontal
                    ? (value.predictedEndTranslation.width - dx) / wandBoardSwipeVelocityHorizon
                    : 0
                let open = horizontal
                    && wandBoardSwipeShouldReveal(
                        offset: settled,
                        revealWidth: wandBoardSwipeActionWidth,
                        velocity: velocity
                    )
                dragTranslation = 0
                draggingHorizontally = false
                if open != revealed { onRevealedChange(open) }
            }
    }

    private func actionButton(_ action: WandBoardSwipeAction) -> some View {
        Button {
            // 先收起再弹确认：Android 的 `onAction` 之后同样把 `revealed` 置回 false。
            onRevealedChange(false)
            onAction(action)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: wandBoardSwipeSystemImage(action))
                    .font(.system(size: 18, weight: .semibold))
                Text(wandBoardSwipeActionLabel(action))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(.white)
            .frame(width: wandBoardSwipeActionWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(wandBoardSwipeActionColor(action))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(wandBoardSwipeActionLabel(action))
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
            if let summary = model.body {
                Text(summary)
                    .font(.system(size: 12))
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
                        .font(.system(size: 11))
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(done ? Theme.textMuted : Theme.textPrimary)
                .strikethrough(done)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let identifier = model.identifier {
                Text(identifier)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 11))
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
                                .font(.system(size: 12))
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
                            .font(.system(size: 11))
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
                .font(.system(size: 11))
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
    let onMoveSession: (WandBoardTaskSession) -> Void
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
        onClose: @escaping () -> Void,
        onMoveSession: @escaping (WandBoardTaskSession) -> Void = { _ in }
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
        self.onMoveSession = onMoveSession
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
            Section("任务内的会话") {
                let groups = wandBoardSessionGroups(sessions: task.sessions, assigned: task.agent)
                if groups.isEmpty {
                    Text("还没有关联会话。描述会作为第一次派发的任务内容。")
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(wandBoardAgentTitle(group.provider, group.agent))
                                .font(.subheadline.weight(.semibold))
                            if group.sessions.isEmpty {
                                Text("默认执行参数 · 尚无关联会话")
                                    .font(.caption)
                                    .foregroundColor(Theme.textMuted)
                            } else {
                                ForEach(group.sessions) { session in
                                    HStack(spacing: 8) {
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
                                        Button {
                                            onMoveSession(session)
                                        } label: {
                                            Image(systemName: "folder")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(Theme.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(busy)
                                        .accessibilityLabel("移动会话到其他任务")
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
    var error: String?
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
        error: String? = nil,
        onCreate: @escaping (String, String, String, String, String?, WandBoardTaskAgent) async -> Void
    ) {
        self.workspaces = workspaces
        self.catalog = catalog
        self.lastAgent = lastAgent
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
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(Theme.danger)
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
