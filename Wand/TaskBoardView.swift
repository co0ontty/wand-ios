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

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    TaskBoardDetailView(
                        task: selected,
                        workspaces: workspaces,
                        catalog: catalog,
                        busy: busy,
                        onPatch: { body in await mutate { _ = try await api.updateBoardTask(id: selected.id, body: body) } },
                        onDispatch: { agent in
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
                defaultWorkspaceId: filterWorkspaceId
            ) { title, description, status, priority, workspaceId in
                await mutate {
                    let created = try await api.createBoardTask(
                        title: title,
                        description: description,
                        status: status,
                        priority: priority,
                        workspaceId: workspaceId
                    )
                    showCreate = false
                    selected = created
                }
            }
        }
        .task {
            if filterWorkspaceId.isEmpty { filterWorkspaceId = linkedWorkspaceId ?? "" }
            await refresh(showProgress: true)
            workspaces = (try? await api.listWorkspaces()) ?? []
            catalog = try? await api.models()
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
    let busy: Bool
    let onPatch: ([String: Any]) async -> Void
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
        busy: Bool,
        onPatch: @escaping ([String: Any]) async -> Void,
        onDispatch: @escaping (WandBoardTaskAgent) async -> Void,
        onDelete: @escaping () async -> Void,
        onOpenSession: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.task = task
        self.workspaces = workspaces
        self.catalog = catalog
        self.busy = busy
        self.onPatch = onPatch
        self.onDispatch = onDispatch
        self.onDelete = onDelete
        self.onOpenSession = onOpenSession
        self.onClose = onClose
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _agent = State(initialValue: task.agent ?? .default)
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
            Section("指派 Agent") {
                Picker("CLI 工具", selection: $agent.provider) {
                    ForEach(wandBoardProviders, id: \.self) { provider in
                        Text(wandBoardProviderLabel(provider)).tag(provider)
                    }
                }
                .onChange(of: agent.provider) { _, provider in
                    let options = wandBoardModelOptions(from: catalog, provider: provider)
                    if !options.contains(where: { $0.id == agent.model }) {
                        agent.model = options.first?.id ?? "default"
                    }
                }
                Picker("模型", selection: $agent.model) {
                    ForEach(wandBoardModelOptions(from: catalog, provider: agent.provider), id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                Picker("思考深度", selection: $agent.thinkingEffort) {
                    ForEach(wandBoardEfforts, id: \.self) { effort in
                        Text(wandBoardEffortLabel(effort)).tag(effort)
                    }
                }
                Button(task.sessions.isEmpty ? "派发 Agent" : "再派发一次") {
                    Task { await onDispatch(agent) }
                }
                .disabled(busy)
            }
            if !task.sessions.isEmpty {
                Section("已绑定会话") {
                    ForEach(task.sessions) { session in
                        Button {
                            onOpenSession(session.id)
                        } label: {
                            HStack {
                                BrandLogo(provider: session.provider, color: Theme.textPrimary)
                                    .frame(width: 14, height: 14)
                                Text("\(wandBoardProviderLabel(session.provider))\(session.model.isEmpty ? "" : " · \(session.model)")")
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
            agent = task.agent ?? .default
        }
    }
}

private struct TaskBoardCreateView: View {
    let workspaces: [Workspace]
    let defaultWorkspaceId: String
    let onCreate: (String, String, String, String, String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var status = "todo"
    @State private var priority = "none"
    @State private var workspaceId = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("任务标题", text: $title)
                TextField("描述", text: $description, axis: .vertical)
                    .lineLimit(3...8)
                Picker("项目", selection: $workspaceId) {
                    Text("不指定项目（使用全局目录）").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
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
                    Button("创建") {
                        Task {
                            await onCreate(
                                title.trimmingCharacters(in: .whitespacesAndNewlines),
                                description,
                                status,
                                priority,
                                workspaceId.isEmpty ? nil : workspaceId
                            )
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { workspaceId = defaultWorkspaceId }
    }
}
