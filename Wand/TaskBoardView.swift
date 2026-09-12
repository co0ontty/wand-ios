import SwiftUI

struct TaskBoardView: View {
    let api: WandAPI
    var linkedWorkspaceId: String? = nil
    let onOpenSession: (String) -> Void
    var onDismiss: (() -> Void)? = nil

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
    @State private var busy = false
    @State private var lastAgent = WandBoardTaskAgent.default

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    TaskBoardDetailView(
                        task: selected,
                        workspaces: workspaces,
                        catalog: catalog,
                        lastAgent: lastAgent,
                        busy: busy,
                        onPatch: { body in await mutate { _ = try await api.updateBoardTask(id: selected.id, body: body) } },
                        onRemember: rememberAgent,
                        onDispatch: { agent in
                            rememberAgent(agent)
                            await mutate {
                                _ = try await api.updateBoardTask(id: selected.id, body: ["agent": agent.jsonObject()])
                                let result = try await api.dispatchBoardTask(id: selected.id, agent: agent)
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
                } else if loading && tasks.isEmpty {
                    ProgressView().tint(Theme.brand)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    listContent
                }
            }
            .background { WandAmbientBackground() }
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
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            Task { await refresh(showProgress: false) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button { showCreate = true } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .accessibilityLabel("新建任务")
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            TaskBoardCreateView(
                workspaces: workspaces,
                catalog: catalog,
                lastAgent: lastAgent,
                defaultWorkspaceId: filterWorkspaceId
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
                    if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try? await api.dispatchBoardTask(id: created.id, agent: agent)
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

    private var listContent: some View {
        List {
            Section {
                TextField("搜索任务", text: $query)
                Picker("项目", selection: $filterWorkspaceId) {
                    Text("所有项目").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
            }
            ForEach(WandBoardStatus.allCases) { status in
                let items = visibleTasks.filter { $0.status == status.rawValue }
                    .sorted { lhs, rhs in
                        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                        return lhs.updatedAt > rhs.updatedAt
                    }
                Section("\(status.label)  \(items.count)") {
                    if items.isEmpty {
                        Text(status.empty).foregroundStyle(Theme.textMuted)
                    } else {
                        ForEach(items) { task in
                            Button {
                                selected = task
                            } label: {
                                TaskBoardRow(task: task)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
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

private struct TaskBoardRow: View {
    let task: WandBoardTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
            Text(task.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(task.workspace?.name ?? "未指定项目")
                if task.priority != "none" {
                    Text(WandBoardPriority(rawValue: task.priority)?.label ?? task.priority)
                        .foregroundStyle(Theme.warning)
                }
                Text(task.agent.map { wandBoardProviderLabel($0.provider) } ?? "未指派")
            }
            .font(.caption)
            .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 4)
    }
}

private struct TaskBoardDetailView: View {
    let task: WandBoardTask
    let workspaces: [Workspace]
    let catalog: ModelsResponse?
    let lastAgent: WandBoardTaskAgent
    let busy: Bool
    let onPatch: ([String: Any]) async -> Void
    let onRemember: (WandBoardTaskAgent) -> Void
    let onDispatch: (WandBoardTaskAgent) async -> Void
    let onDelete: () async -> Void
    let onOpenSession: (String) -> Void
    let onClose: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var agent: WandBoardTaskAgent

    init(
        task: WandBoardTask,
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        lastAgent: WandBoardTaskAgent,
        busy: Bool,
        onPatch: @escaping ([String: Any]) async -> Void,
        onRemember: @escaping (WandBoardTaskAgent) -> Void,
        onDispatch: @escaping (WandBoardTaskAgent) async -> Void,
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
                Picker("CLI 工具", selection: Binding(
                    get: { agent.provider },
                    set: { provider in
                        agent.provider = provider
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
                Button(task.sessions.isEmpty ? "派发 Agent" : "再派发一次") {
                    Task { await onDispatch(agent) }
                }
                .disabled(busy)
            }
            Section("已指派的 Agent") {
                let groups = wandBoardSessionGroups(sessions: task.sessions, assigned: task.agent)
                if groups.isEmpty {
                    Text("还没有指派 Agent。描述会作为第一次派发的任务内容。")
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(wandBoardProviderLabel(group.provider))
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
    let onCreate: (String, String, String, String, String?, WandBoardTaskAgent) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var status = "todo"
    @State private var priority = "none"
    @State private var workspaceId = ""
    @State private var agent: WandBoardTaskAgent

    init(
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        lastAgent: WandBoardTaskAgent,
        defaultWorkspaceId: String,
        onCreate: @escaping (String, String, String, String, String?, WandBoardTaskAgent) async -> Void
    ) {
        self.workspaces = workspaces
        self.catalog = catalog
        self.lastAgent = lastAgent
        self.defaultWorkspaceId = defaultWorkspaceId
        self.onCreate = onCreate
        _agent = State(initialValue: lastAgent)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("任务标题（可选）", text: $title, prompt: Text("不填写则按描述自动生成"))
                TextField("描述（作为第一次指派）", text: $description, axis: .vertical)
                    .lineLimit(3...8)
                Picker("目录", selection: $workspaceId) {
                    Text("不指定目录（使用全局目录）").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                Picker("第一次指派", selection: Binding(
                    get: { agent.provider },
                    set: { provider in
                        agent.provider = provider
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
                    Button(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "创建" : "创建并指派") {
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
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { workspaceId = defaultWorkspaceId }
    }
}
