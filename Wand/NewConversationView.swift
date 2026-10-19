import SwiftUI

/// Chat-first pending conversation. It performs no mutation until the first submit.
struct NewConversationView: View {
    let api: WandAPI
    let serverID: String
    let onCreated: (SessionSnapshot) -> Void
    let initialCwd: String?
    let workspaceID: String?
    let initialWorkspaceTaskID: String?
    let initialEmployeeID: String?
    let initialCreateTask: Bool

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator: NewConversationCoordinator
    @StateObject private var pendingDraft: ComposerDraftState
    @State private var cwd = ""
    @State private var recentPaths: [RecentPath] = []
    @State private var provider = WandProvider.claude.rawValue
    @State private var engine: String?
    @State private var sessionKind = "structured"
    @State private var contactSubject: ContactExecutionSubject?
    @State private var contactEmployees: [SiliconEmployee] = []
    @State private var contactsError: String?
    @State private var employeeOverride = false
    @State private var mode = "managed"
    @State private var model = ""
    @State private var thinkingEffort = "off"
    @State private var defaultCwd: String?
    @State private var defaultEngine: String?
    @State private var modelCatalog: ModelsResponse?
    @State private var frozenDraftText: String?
    @State private var frozenDraftRevision: Int?
    @State private var frozenAttachmentRevision: Int?
    @State private var taskOwnership = "none"
    @State private var newTaskName = ""
    @State private var targetWorkspaceID = ""
    @StateObject private var stagedAttachments: ComposerAttachmentController
    @State private var pendingDraftRevision = 0
    @State private var pendingAttachmentRevision = 0
    @State private var existingTasks: [WorkspaceTaskSummary] = []
    @State private var availableWorkspaces: [Workspace] = []
    @State private var selectedTaskID = ""
    @State private var taskListLoaded = false
    @State private var workspaceSelectionIsLocked = false
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var didLoadConfiguration = false
    @State private var creating = false
    @State private var showExecutionSettings = false
    @State private var confirmedCheckedSessions = false
    @FocusState private var focused: Bool
    private let pendingDraftConsumer = UUID()

    init(
        api: WandAPI,
        serverID: String,
        initialCwd: String? = nil,
        workspaceID: String? = nil,
        initialWorkspaceTaskID: String? = nil,
        initialEmployeeID: String? = nil,
        initialCreateTask: Bool = false,
        onCreated: @escaping (SessionSnapshot) -> Void
    ) {
        self.api = api
        self.serverID = serverID
        self.initialCwd = initialCwd
        self.workspaceID = workspaceID
        self.initialWorkspaceTaskID = initialWorkspaceTaskID
        self.initialEmployeeID = initialEmployeeID
        self.initialCreateTask = initialCreateTask
        self.onCreated = onCreated
        _cwd = State(initialValue: initialCwd ?? "")
        _selectedTaskID = State(initialValue: initialWorkspaceTaskID ?? "")
        _taskOwnership = State(initialValue: initialWorkspaceTaskID == nil ? (initialCreateTask ? "new" : "none") : "existing")
        _targetWorkspaceID = State(initialValue: workspaceID ?? "")
        _workspaceSelectionIsLocked = State(initialValue: initialWorkspaceTaskID != nil)
        let scope = initialWorkspaceTaskID ?? initialCwd ?? workspaceID ?? "global"
        let pendingID = "pending-new-conversation:\(serverID):\(scope)"
        let draft = SessionDraftStore.shared.draft(sessionId: pendingID, api: api)
        _pendingDraft = StateObject(wrappedValue: draft)
        _stagedAttachments = StateObject(wrappedValue: draft.attachments)
        _coordinator = StateObject(wrappedValue: NewConversationCoordinator.shared(
            serverID: serverID,
            scope: scope
        ))
    }

    private var text: String { pendingDraft.text }
    private var normalizedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var coordinatorIdentity: String { initialWorkspaceTaskID ?? initialCwd ?? workspaceID ?? "global" }
    private var isUnknown: Bool {
        if case .deliveryUnknown = coordinator.phase { return true }
        return false
    }
    private var unknownConfirmationLabel: String {
        coordinator.unknownOperation == .task
            ? "我已检查任务列表，确认没有刚创建的任务"
            : "我已检查会话列表，确认没有刚创建的对话"
    }
    private var canSubmit: Bool {
        let hasTaskSelection = taskOwnership != "existing" || isSelectedTaskAvailable
        let hasTaskName = taskOwnership != "new" || !newTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = sessionKind != "structured" || !normalizedText.isEmpty || stagedAttachments.stagedAttachmentCount > 0
        let employeeIsAvailable = contactSubject?.type != "employee" || selectedEmployee != nil
        return didLoadConfiguration && !loading && !creating && !isUnknown && !hasOutstandingCreation && hasContent && !cwd.isEmpty && hasTaskSelection && hasTaskName && employeeIsAvailable
    }

    private var canResumeCreation: Bool {
        !creating && (coordinator.acceptedTaskIDForContinuation != nil || coordinator.acceptedSessionIDForContinuation != nil)
    }

    private var hasOutstandingCreation: Bool {
        switch coordinator.phase {
        case .idle, .rejected: return false
        case .creating, .taskAccepted, .accepted, .deliveryUnknown: return true
        }
    }

    private var isSelectedTaskAvailable: Bool {
        taskListLoaded && existingTasks.contains { $0.id == selectedTaskID }
    }

    private var taskWorkspaceOptions: [Workspace] {
        let byID = Dictionary(availableWorkspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("新建对话")
                            .font(.wand(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("先写下要做的事。发送前不会创建会话或任务。")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("消息")
                                .font(.wand(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            TextEditor(text: $pendingDraft.text)
                                .focused($focused)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 150)
                                .padding(8)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .accessibilityLabel("输入要处理的内容")
                                .disabled(creating)
                            stagedAttachmentPreview
                            attachmentActions
                        }

                        DisclosureGroup(isExpanded: $showExecutionSettings) {
                            VStack(alignment: .leading, spacing: 12) {
                            Picker("会话类型", selection: $sessionKind) {
                                Text("结构化").tag("structured")
                                Text("PTY").tag("pty")
                                Text("空白终端").tag("shell")
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("会话类型")
                            .onChange(of: sessionKind) { _, value in
                                if value != "structured" { contactSubject = nil }
                                if value == "shell" { engine = nil }
                            }
                            if sessionKind == "structured" {
                                ContactExecutionSubjectPicker(
                                    subject: $contactSubject,
                                    employees: contactEmployees,
                                    error: contactsError,
                                    onRetry: { Task { await loadContacts() } }
                                )
                                .onChange(of: contactSubject) { oldValue, newValue in
                                    if oldValue?.id != newValue?.id || oldValue?.type != newValue?.type {
                                        employeeOverride = false
                                        if let employee = contactEmployees.first(where: { $0.id == newValue?.id && newValue?.type == "employee" }),
                                           let candidate = employee.agents.first {
                                            provider = candidate.provider
                                            engine = candidate.engine
                                            model = candidate.model == "default" ? "" : candidate.model
                                            mode = currentProvider.clamp(mode: candidate.mode, fallback: "managed")
                                            thinkingEffort = candidate.thinkingEffort
                                            normalizeThinkingEffort()
                                        }
                                    }
                                }
                            }
                            if sessionKind != "shell" && (contactSubject?.type != "employee" || employeeOverride) {
                                Picker("执行工具", selection: Binding(
                                    get: { WandAgentTool(provider: provider, engine: engine).rawValue },
                                    set: { rawValue in
                                        guard let tool = WandAgentTool(rawValue: rawValue) else { return }
                                        provider = tool.provider.rawValue
                                        engine = tool.engine
                                        if tool.structuredOnly { sessionKind = "structured" }
                                    }
                                )) {
                                    ForEach(WandAgentTool.allCases.filter { sessionKind == "structured" || !$0.structuredOnly }) {
                                        Text($0.title).tag($0.rawValue)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accessibilityLabel("执行工具")
                                .onChange(of: provider) { _, value in
                                    guard contactSubject?.type != "employee" || employeeOverride else { return }
                                    model = configModel(for: value)
                                    mode = currentProvider.clamp(mode: mode, fallback: "managed")
                                    thinkingEffort = "off"
                                    normalizeThinkingEffort()
                                }
                            }
                            if sessionKind == "structured" && (contactSubject?.type != "employee" || employeeOverride) {
                                Picker("模式", selection: $mode) {
                                    ForEach(currentProvider.supportedModeIDs.sorted(), id: \.self) { value in
                                        Text(modeTitle(value)).tag(value)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accessibilityLabel("执行模式")
                                TextField("模型 ID（留空使用服务器默认）", text: $model)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("模型")
                                Picker("思考深度", selection: $thinkingEffort) {
                                    ForEach(thinkingOptions) { option in
                                        Text(option.menuLabel).tag(option.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accessibilityLabel("思考深度")
                            }
                            if contactSubject?.type == "employee", !employeeOverride, let employee = selectedEmployee,
                               let candidate = employee.agents.first {
                                Text("员工默认：\(WandProvider(normalizing: candidate.provider).title) · \(candidate.model) · \(candidate.mode)。")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Button("自定义本次工具、模型与思考设置") { employeeOverride = true }
                                    .font(.caption.weight(.medium))
                            } else if contactSubject?.type == "employee", employeeOverride {
                                Button("恢复员工默认设置") {
                                    employeeOverride = false
                                    if let candidate = selectedEmployee?.agents.first {
                                        provider = candidate.provider
                                        engine = candidate.engine
                                        model = candidate.model == "default" ? "" : candidate.model
                                        mode = currentProvider.clamp(mode: candidate.mode, fallback: "managed")
                                        thinkingEffort = candidate.thinkingEffort
                                        normalizeThinkingEffort()
                                    }
                                }
                                .font(.caption.weight(.medium))
                            }
                            }
                            .padding(14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } label: {
                            Label("执行设置", systemImage: "slider.horizontal.3")
                                .font(.wand(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.textSecondary)

                        VStack(alignment: .leading, spacing: 10) {
                            Label("所属任务", systemImage: "checklist")
                                .font(.wand(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Picker("所属任务", selection: $taskOwnership) {
                                Text("不归属任务").tag("none")
                                Text("新建任务").tag("new")
                                if taskListLoaded { Text("已有任务").tag("existing") }
                            }
                            .pickerStyle(.menu)
                            .accessibilityLabel("所属任务")
                            .onChange(of: taskOwnership) { _, value in
                                if value == "existing", selectedTaskID.isEmpty {
                                    selectedTaskID = existingTasks.first?.id ?? ""
                                }
                                if value == "existing", let task = existingTasks.first(where: { $0.id == selectedTaskID }) {
                                    cwd = task.cwd
                                }
                                workspaceSelectionIsLocked = value == "existing"
                                if value == "none" || value == "new" {
                                    cwd = initialCwd ?? defaultCwd ?? cwd
                                    workspaceSelectionIsLocked = false
                                }
                            }
                            if taskOwnership == "new" {
                                TextField("任务名称", text: $newTaskName)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("新任务名称")
                                Picker("任务所在项目", selection: $targetWorkspaceID) {
                                    Text("按工作目录创建").tag("")
                                    ForEach(taskWorkspaceOptions) { workspace in Text(workspace.name + " · " + workspace.cwd).tag(workspace.id) }
                                }.pickerStyle(.menu).accessibilityLabel("任务所在项目")
                            }
                            if taskOwnership == "existing", !taskListLoaded {
                                Text("正在加载任务列表…")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Button("重试加载任务") { Task { await loadTaskList() } }
                                    .font(.caption)
                            } else if taskOwnership == "existing", existingTasks.isEmpty {
                                Text("当前没有可绑定的已有任务。")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            } else if taskOwnership == "existing" {
                                existingTaskPicker
                            }
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        VStack(alignment: .leading, spacing: 10) {
                            Label("工作目录", systemImage: "folder")
                                .font(.wand(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            TextField("输入服务器目录", text: $cwd)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .disabled(workspaceSelectionIsLocked || loading)
                                .accessibilityLabel("工作目录")
                            if !recentPaths.isEmpty && !workspaceSelectionIsLocked {
                                ForEach(recentPaths.prefix(4)) { path in
                                    Button {
                                        cwd = path.path
                                    } label: {
                                        Label(path.path, systemImage: "clock")
                                            .font(.caption)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(workspaceSelectionIsLocked || loading)
                                    .accessibilityLabel("选择最近目录 \(path.path)")
                                }
                            }
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    }
                    .padding(16)
                    .disabled(creating)
                }

                if isUnknown {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage ?? "创建结果未知。请先检查会话列表，确认是否已创建。")
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                        Toggle(unknownConfirmationLabel, isOn: $confirmedCheckedSessions)
                            .font(.footnote)
                        if coordinator.unknownOperation == nil || (coordinator.unknownOperation == .session && coordinator.unknownSessionID == nil) || (coordinator.unknownOperation == .task && coordinator.unknownTaskID == nil) {
                            Text("当前服务端没有返回创建请求标识。仅查看列表无法证明没有创建成功，因此不会允许重试。")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }

                HStack(spacing: 12) {
                    Button("取消") { dismiss() }
                        .buttonStyle(WandSecondaryButtonStyle())
                        .disabled(creating)
                    Spacer(minLength: 0)
                    Button {
                        if isUnknown {
                            errorMessage = nil
                            switch coordinator.unknownOperation {
                            case .task:
                                Task { await verifyUnknownTaskCreation() }
                            case .session:
                                Task { await loadSessionList() }
                            case nil:
                                errorMessage = "创建请求缺少可核对的请求标识，无法安全继续；请保留此页面并联系支持。"
                            }
                        } else if canResumeCreation {
                            if let sessionID = coordinator.acceptedSessionIDForContinuation {
                                let source = frozenDraftText ?? text
                                resumeAcceptedSession(sessionID, text: source,
                                                      textRevision: frozenDraftRevision ?? pendingDraftRevision,
                                                      sourceText: source,
                                                      attachmentRevision: frozenAttachmentRevision ?? pendingAttachmentRevision,
                                                      attachments: stagedAttachments)
                            } else if let taskID = coordinator.acceptedTaskIDForContinuation {
                                coordinator.beginSessionContinuation()
                                continueSessionCreation(taskID: taskID)
                            }
                        } else {
                            submit()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if creating { ProgressView().tint(.white) }
                            Text(isUnknown ? "检查并继续" : canResumeCreation ? "继续创建" : "发送")
                        }
                        .frame(minWidth: 90)
                    }
                    .buttonStyle(WandPrimaryButtonStyle())
                    .disabled(isUnknown ? !confirmedCheckedSessions : (!canResumeCreation && !canSubmit))
                    .accessibilityHint(isUnknown ? "检查对应列表；如果创建已成功，将继续使用该任务或会话" : "创建会话后发送此消息")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.background.opacity(0.98))
            }
            .background(WandAmbientBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { focused = false }
                        .disabled(!focused)
                }
            }
            .onAppear {
                pendingDraft.acquire(pendingDraftConsumer)
                pendingDraftRevision = pendingDraft.textRevision
                pendingAttachmentRevision = stagedAttachments.stagedInputRevision
            }
            .task { await loadConfiguration() }
            .onChange(of: pendingDraft.textRevision) { _, revision in
                pendingDraftRevision = revision
                if !creating { clearFrozenDraft() }
            }
            .onChange(of: stagedAttachments.stagedInputRevision) { _, revision in
                pendingAttachmentRevision = revision
                if !creating { clearFrozenDraft() }
            }
            .onDisappear {
                pendingDraft.release(pendingDraftConsumer)
            }
        }
    }

    private var stagedAttachmentPreview: some View {
        ForEach(Array(stagedAttachments.stagedAttachments.enumerated()), id: \.element.id) { index, attachment in
            HStack {
                Label(attachment.name, systemImage: "paperclip").lineLimit(1)
                Spacer()
                Button("移除") { stagedAttachments.removeStaged(at: index) }
                    .accessibilityLabel("移除附件 \(attachment.name)")
            }.font(.caption).padding(8).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var attachmentActions: some View {
        HStack(spacing: 12) {
            Button("照片", systemImage: "photo") { stagedAttachments.showPhotoPicker = true }
                .frame(maxWidth: .infinity, minHeight: 44)
            Button("文件", systemImage: "doc") { stagedAttachments.showFileImporter = true }
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(WandQuietButtonStyle())
        .fileImporter(isPresented: $stagedAttachments.showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            stagedAttachments.handleFileSelection($0)
        }
        .sheet(isPresented: $stagedAttachments.showPhotoPicker) {
            PhotoLibraryPicker { stagedAttachments.handlePhotoSelection($0) }
        }
    }

    private var existingTaskPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("选择已有任务", selection: $selectedTaskID) {
                ForEach(existingTasks) { task in
                    Text(taskPickerTitle(task)).tag(task.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("选择已有任务")
            .onChange(of: selectedTaskID) { _, taskID in
                guard let task = existingTasks.first(where: { $0.id == taskID }) else { return }
                cwd = task.cwd
            }
            if let task = existingTasks.first(where: { $0.id == selectedTaskID }) {
                Text("工作目录已锁定：\(task.cwd)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func taskPickerTitle(_ task: WorkspaceTaskSummary) -> String {
        task.name + " · " + task.cwd
    }

    private var currentProvider: WandProvider { WandProvider(normalizing: provider) }
    private var selectedEmployee: SiliconEmployee? {
        guard contactSubject?.type == "employee" else { return nil }
        return contactEmployees.first { $0.id == contactSubject?.id && !$0.archived && !$0.agents.isEmpty }
    }
    private var effectiveEngine: String? {
        guard provider == "pi" else { return nil }
        return engine ?? defaultEngine ?? "cli"
    }
    private var providerModels: [ModelInfo] { modelCatalog?.models(for: currentProvider) ?? [] }
    private var thinkingOptions: [ThinkingEffortOption] {
        thinkingEffortOptions(
            provider: provider,
            selectedModel: model,
            defaultModel: configModel(for: provider),
            models: providerModels,
            providerEfforts: modelCatalog?.thinkingEfforts(for: provider) ?? []
        )
    }

    private func configModel(for provider: String) -> String {
        modelCatalog?.defaultModelId(for: provider) ?? ""
    }

    private func normalizeThinkingEffort() {
        guard let options = dynamicThinkingEffortOptions(
            provider: provider,
            selectedModel: model,
            defaultModel: configModel(for: provider),
            models: providerModels,
            providerEfforts: modelCatalog?.thinkingEfforts(for: provider) ?? []
        ), !options.contains(where: { $0.id == thinkingEffort }) else { return }
        thinkingEffort = "off"
    }

    private func createTask(name: String, cwd: String, workspaceID: String?, description: String,
                            creationRequestId: String) async throws -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw WandAPI.APIError.server(status: 400, message: "任务名称不能为空。") }
        let created: WorkspaceTaskCreation
        if let workspaceID, !workspaceID.isEmpty {
            created = try await api.createWorkspaceTask(
                workspaceId: workspaceID,
                name: normalizedName,
                baseRef: nil,
                worktree: false,
                cwd: cwd,
                description: description,
                creationRequestId: creationRequestId
            )
        } else {
            created = try await api.createStandaloneTask(
                name: normalizedName,
                cwd: cwd,
                worktree: false,
                description: description,
                creationRequestId: creationRequestId
            )
        }
        return created.id
    }

    private func loadSessionList() async {
        do {
            let firstPage = try await api.fetchSessionList(offset: 0, limit: 100)
            var entries = firstPage.entries
            var offset = entries.count
            while offset < firstPage.total {
                let page = try await api.fetchSessionList(offset: offset, limit: 100, revision: firstPage.revision)
                guard page.revision == firstPage.revision, !page.entries.isEmpty else {
                    throw WandAPI.APIError.network("会话列表在核对期间发生变化，请重试核对。")
                }
                entries += page.entries
                offset += page.entries.count
            }
            guard offset >= firstPage.total else {
                throw WandAPI.APIError.network("会话列表不完整，无法确认创建结果。")
            }
            guard coordinator.currentCreationRequestID != nil else {
                throw WandAPI.APIError.network("创建请求缺少可核对标识，无法安全关联会话。")
            }
            let sessionID = coordinator.unknownSessionID
            if let sessionID, let entry = entries.first(where: { $0.session?.id == sessionID }),
               let session = entry.session {
                coordinator.resolveUnknownSession(session)
                resumeAcceptedSession(session.id, text: text, textRevision: pendingDraftRevision,
                                      sourceText: text, attachmentRevision: pendingAttachmentRevision,
                                      attachments: stagedAttachments)
                return
            }
            coordinator.rejectUnknownSessionAfterCheck()
            confirmedCheckedSessions = false
            errorMessage = "会话列表中未找到可确认的会话，但当前服务端不支持按创建请求核对结果。为避免重复创建，请勿再次发送。"
        } catch {
            errorMessage = "无法核对会话列表：\(error.localizedDescription)"
        }
    }

    private func verifyUnknownTaskCreation() async {
        do {
            let page = try await api.listTaskGroupsPage(revision: nil)
            guard !page.unchanged, page.revision != nil else {
                throw WandAPI.APIError.network("当前服务端未提供可验证的任务列表快照，无法安全核对创建结果。")
            }
            let groups = page.groups
            let workspaces = try await api.listWorkspaces()
            availableWorkspaces = workspaces
            existingTasks = groups.flatMap(\.tasks)
            taskListLoaded = true
            guard coordinator.currentCreationRequestID != nil else {
                throw WandAPI.APIError.network("创建请求缺少可核对标识，无法安全关联任务。")
            }
            let taskID = coordinator.unknownTaskID
            if let taskID, let task = existingTasks.first(where: { $0.id == taskID }) {
                coordinator.resolveUnknownTask(task.id)
                taskOwnership = "existing"
                selectedTaskID = task.id
                workspaceSelectionIsLocked = true
                cwd = task.cwd
                errorMessage = "任务已创建，已选择该任务。再次发送只会继续创建会话。"
                return
            }
            coordinator.rejectUnknownTaskAfterCheck()
            confirmedCheckedSessions = false
            errorMessage = "任务列表中未找到可确认的任务，但当前服务端不支持按创建请求核对结果。为避免重复创建，请勿再次发送。"
        } catch {
            errorMessage = "无法核对任务列表：\(error.localizedDescription)"
        }
    }

    private func clearFrozenDraft() {
        frozenDraftText = nil
        frozenDraftRevision = nil
        frozenAttachmentRevision = nil
    }

    private func clearPendingDraft(textRevision: Int, attachmentRevision: Int, sourceText: String) {
        guard pendingDraftRevision == textRevision,
              pendingDraft.text == sourceText,
              stagedAttachments.stagedInputRevision == attachmentRevision else { return }
        pendingDraft.text = ""
        stagedAttachments.discardStaged()
        pendingDraftRevision = pendingDraft.textRevision
        pendingAttachmentRevision = stagedAttachments.stagedInputRevision
    }

    private func loadContacts() async {
        do {
            let employees = try await api.listContactEmployees()
            guard !Task.isCancelled else { return }
            contactEmployees = employees
            contactsError = nil
            if contactSubject == nil, let employeeID = initialEmployeeID,
               let employee = employees.first(where: { $0.id == employeeID && !$0.archived && !$0.agents.isEmpty }) {
                contactSubject = ContactExecutionSubject(type: "employee", id: employee.id)
            }
            if let current = contactSubject, current.type == "employee",
               !employees.contains(where: { $0.id == current.id && !$0.archived && !$0.agents.isEmpty }) {
                contactSubject = nil
                employeeOverride = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            contactsError = "无法读取员工列表：\(error.localizedDescription)"
        }
    }

    private func loadTaskList() async {
        do {
            availableWorkspaces = try await api.listWorkspaces()
            existingTasks = try await api.listTaskGroups().flatMap(\.tasks)
            taskListLoaded = true
            errorMessage = nil
        } catch {
            taskListLoaded = false
            errorMessage = "无法读取已有任务：\(error.localizedDescription)"
        }
    }

    private func loadConfiguration() async {
        do {
            let config = try await api.serverConfig()
            let catalog = try? await api.models()
            guard !Task.isCancelled else { return }
            modelCatalog = catalog
            let shouldApplyInitialCwd = cwd == (initialCwd ?? "")
            if !didLoadConfiguration {
                provider = WandProvider(normalizing: config.defaultProvider).rawValue
                mode = currentProvider.clamp(mode: config.resolvedDefaultMode)
                model = catalog?.defaultModelId(for: provider) ?? config.defaultModelId(for: provider)
                thinkingEffort = config.resolvedDefaultThinkingEffort
                normalizeThinkingEffort()
                didLoadConfiguration = true
            }
            defaultCwd = config.defaultCwd
            defaultEngine = config.defaultEngine
            await loadContacts()
            guard !Task.isCancelled else { return }
            let paths = (try? await api.recentPaths()) ?? []
            guard !Task.isCancelled else { return }
            recentPaths = paths
            if shouldApplyInitialCwd {
                if let initialCwd { cwd = initialCwd }
                else { cwd = paths.first?.path ?? config.defaultCwd ?? "" }
            }
            do {
                let workspaces = try await api.listWorkspaces()
                availableWorkspaces = workspaces
                let groups = try await api.listTaskGroups()
                existingTasks = groups.flatMap(\.tasks)
                taskListLoaded = true
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "无法读取已有任务：\(error.localizedDescription)"
                loading = false
                return
            }
            if let requestedTaskID = initialWorkspaceTaskID,
               let task = existingTasks.first(where: { $0.id == requestedTaskID }) {
                selectedTaskID = task.id
                taskOwnership = "existing"
                workspaceSelectionIsLocked = true
                cwd = task.cwd
            }
            if !selectedTaskID.isEmpty, !existingTasks.contains(where: { $0.id == selectedTaskID }) {
                selectedTaskID = ""
                taskOwnership = "none"
                workspaceSelectionIsLocked = false
                if initialWorkspaceTaskID != nil {
                    errorMessage = "此任务已不存在，无法在原任务下新建会话。"
                }
            }
            didLoadConfiguration = true
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "无法读取服务器配置：\(error.localizedDescription)"
            loading = false
        }
    }

    private func resumeAcceptedSession(_ sessionID: String, text: String, textRevision: Int,
                                       sourceText: String, attachmentRevision: Int,
                                       attachments: ComposerAttachmentController, alreadyCreating: Bool = false) {
        guard alreadyCreating || !creating else { return }
        creating = true
        Task {
            let snapshot: SessionSnapshot
            do {
                snapshot = try await api.getSession(id: sessionID)
            } catch {
                creating = false
                errorMessage = "暂时无法读取会话；已保留创建结果，可再次重试。\n\(error.localizedDescription)"
                return
            }
            do {
                if attachments.stagedAttachmentCount > 0 {
                    try await attachments.uploadStaged(to: snapshot.id)
                }
            } catch {
                creating = false
                errorMessage = "会话已创建，附件上传失败；保留本地附件。\n\(error.localizedDescription)"
                return
            }
            let draft = SessionDraftStore.shared.draft(sessionId: snapshot.id, api: api)
            guard coordinator.adopt(text, expectedSourceRevision: textRevision, currentSourceRevision: pendingDraftRevision,
                                    expectedAttachmentRevision: attachmentRevision,
                                    currentAttachmentRevision: pendingAttachmentRevision,
                                    sourceText: sourceText, attachments: attachments.attachments,
                                    targetSessionID: snapshot.id, into: draft) == .adopted else {
                creating = false
                errorMessage = "会话已创建，但草稿交接未完成；目标草稿已保留。"
                return
            }
            if !text.isEmpty || !attachments.attachments.isEmpty { draft.requestInitialSend() }
            clearPendingDraft(textRevision: textRevision, attachmentRevision: attachmentRevision, sourceText: sourceText)
            coordinator.resetAfterHandoff(sessionID: snapshot.id)
            creating = false
            onCreated(snapshot)
        }
    }

    private func continueSessionCreation(taskID: String) {
        guard !creating else { return }
        creating = true
        let frozenCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let frozenProvider = provider
        let frozenMode = mode
        let frozenModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let frozenEffort = thinkingEffort
        let frozenEngine = effectiveEngine
        let frozenSessionKind = sessionKind
        let frozenEmployeeID = selectedEmployee?.id
        let frozenEmployeeOverride = employeeOverride
        let frozenTextRevision = self.frozenDraftRevision ?? pendingDraftRevision
        let frozenAttachmentRevisionValue = self.frozenAttachmentRevision ?? pendingAttachmentRevision
        let frozenTextValue = self.frozenDraftText ?? text
        frozenDraftText = frozenTextValue
        self.frozenDraftRevision = frozenTextRevision
        self.frozenAttachmentRevision = frozenAttachmentRevisionValue
        let attachmentController = stagedAttachments
        let frozenTaskID = taskID
        let frozenSourceText = frozenTextValue
        Task {
            if let existingSessionID = coordinator.acceptedSessionIDForContinuation {
                resumeAcceptedSession(existingSessionID, text: frozenTextValue, textRevision: frozenTextRevision,
                                      sourceText: frozenTextValue, attachmentRevision: frozenAttachmentRevisionValue,
                                      attachments: attachmentController, alreadyCreating: true)
                return
            }
            let sessionRequestID = coordinator.currentCreationRequestID ?? UUID().uuidString.lowercased()
            let snapshot = await coordinator.create(requestID: sessionRequestID) {
                try await api.createSession(
                    kind: frozenSessionKind == "shell" ? "pty" : frozenSessionKind,
                    provider: frozenSessionKind == "shell" || (frozenEmployeeID != nil && !frozenEmployeeOverride) ? nil : frozenProvider,
                    cwd: frozenCwd,
                    mode: frozenSessionKind == "structured" && (frozenEmployeeID == nil || frozenEmployeeOverride) ? frozenMode : nil,
                    model: frozenSessionKind == "structured" && (frozenEmployeeID == nil || frozenEmployeeOverride) && !frozenModel.isEmpty ? frozenModel : nil,
                    thinkingEffort: frozenSessionKind == "structured" && (frozenEmployeeID == nil || frozenEmployeeOverride) ? frozenEffort : nil,
                    prompt: nil,
                    engine: frozenSessionKind == "structured" && (frozenEmployeeID == nil || frozenEmployeeOverride) ? frozenEngine : nil,
                    shell: frozenSessionKind == "shell",
                    workspaceId: workspaceID, workspaceTaskId: frozenTaskID,
                    employeeId: frozenEmployeeID,
                    overrideCli: frozenEmployeeID != nil && frozenEmployeeOverride,
                    creationRequestId: sessionRequestID
                )
            }
            guard let snapshot else {
                creating = false
                if case .deliveryUnknown(let reason) = coordinator.phase {
                    errorMessage = "创建结果未知，请核对会话列表。\n\(reason)"
                }
                return
            }
            do {
                if attachmentController.stagedAttachmentCount > 0 {
                    try await attachmentController.uploadStaged(to: snapshot.id)
                }
            } catch {
                creating = false
                errorMessage = "会话已创建，附件上传失败；保留本地附件。\n\(error.localizedDescription)"
                return
            }
            let draft = SessionDraftStore.shared.draft(sessionId: snapshot.id, api: api)
            guard coordinator.adopt(frozenTextValue, expectedSourceRevision: frozenTextRevision,
                                    currentSourceRevision: pendingDraftRevision,
                                    expectedAttachmentRevision: frozenAttachmentRevisionValue,
                                    currentAttachmentRevision: pendingAttachmentRevision,
                                    sourceText: frozenSourceText,
                                    attachments: attachmentController.attachments,
                                    targetSessionID: snapshot.id, into: draft) == .adopted else {
                creating = false
                errorMessage = "会话已创建，但草稿交接未完成；目标原有草稿已保留。"
                return
            }
            if !frozenTextValue.isEmpty || !attachmentController.attachments.isEmpty { draft.requestInitialSend() }
            clearPendingDraft(textRevision: frozenTextRevision, attachmentRevision: frozenAttachmentRevisionValue,
                              sourceText: frozenTextValue)
            coordinator.resetAfterHandoff(sessionID: snapshot.id)
            creating = false
            onCreated(snapshot)
        }
    }

    private func submit(afterUnknownAcknowledgement: Bool = false) {
        guard afterUnknownAcknowledgement ? (!creating && didLoadConfiguration && !loading &&
            (sessionKind != "structured" || !normalizedText.isEmpty || stagedAttachments.stagedAttachmentCount > 0) && !cwd.isEmpty &&
            (taskOwnership != "existing" || isSelectedTaskAvailable)) : canSubmit else { return }
        focused = false
        creating = true
        errorMessage = nil
        let frozenText = self.frozenDraftText ?? text
        let frozenCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let frozenProvider = provider
        let frozenMode = mode
        let frozenModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let frozenEffort = thinkingEffort
        let frozenEngine = effectiveEngine
        let frozenSessionKind = sessionKind
        let frozenEmployeeID = selectedEmployee?.id
        let frozenEmployeeOverride = employeeOverride
        let frozenDraftRevision = self.frozenDraftRevision ?? pendingDraftRevision
        let frozenAttachmentRevision = self.frozenAttachmentRevision ?? pendingAttachmentRevision
        let frozenOwnership = taskOwnership
        let frozenTaskID = selectedTaskID
        let frozenTaskName = newTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let frozenTargetWorkspaceID = targetWorkspaceID
        let frozenSourceText = frozenText
        frozenDraftText = frozenText
        self.frozenDraftRevision = frozenDraftRevision
        self.frozenAttachmentRevision = frozenAttachmentRevision
        let frozenAttachments = stagedAttachments
        let selectedTask = existingTasks.first { $0.id == frozenTaskID }
        if let sessionID = coordinator.acceptedSessionIDForContinuation {
            resumeAcceptedSession(sessionID, text: frozenText, textRevision: frozenDraftRevision,
                                  sourceText: frozenSourceText, attachmentRevision: frozenAttachmentRevision,
                                  attachments: frozenAttachments)
            return
        }
        if isUnknown {
            creating = false
            errorMessage = "请先核对创建结果，再继续处理。"
            return
        }
        guard frozenOwnership != "existing" || selectedTask != nil else {
            creating = false
            errorMessage = "所选任务已不存在或工作区列表尚未加载，请刷新后重试。"
            return
        }
        let sessionCwd = frozenOwnership == "existing" ? selectedTask?.cwd ?? frozenCwd : frozenCwd
        let sessionWorkspaceID: String? = frozenOwnership == "existing"
            ? selectedTask?.workspaceId
            : frozenOwnership == "new" ? (frozenTargetWorkspaceID.isEmpty ? nil : frozenTargetWorkspaceID) : workspaceID
        Task {
            let frozenTaskIDForSession: String?
            if frozenOwnership == "existing" {
                frozenTaskIDForSession = frozenTaskID
            } else if let acceptedTaskID = coordinator.acceptedTaskIDForContinuation {
                frozenTaskIDForSession = acceptedTaskID
            } else if frozenOwnership == "new" {
                guard case .idle = coordinator.phase else {
                    creating = false
                    errorMessage = "创建任务结果尚未确认，请先核对任务列表。"
                    return
                }
                let taskRequestID = UUID().uuidString.lowercased()
                let task = await coordinator.createTask(requestID: taskRequestID) {
                    try await self.createTask(name: frozenTaskName, cwd: sessionCwd,
                                              workspaceID: sessionWorkspaceID, description: frozenText,
                                              creationRequestId: taskRequestID)
                }
                guard let task else {
                    creating = false
                    if case .deliveryUnknown(let reason) = coordinator.phase {
                        errorMessage = "创建任务结果未知，请先核对任务列表。\n\(reason)"
                    } else if case .rejected(let reason) = coordinator.phase {
                        errorMessage = reason
                        coordinator.retryRejectedTaskCreation()
                    }
                    return
                }
                frozenTaskIDForSession = task
            } else {
                frozenTaskIDForSession = nil
            }
            let sessionRequestID = UUID().uuidString.lowercased()
            let snapshot = await coordinator.create(requestID: sessionRequestID, using: {
                try await api.createSession(
                    kind: frozenSessionKind == "shell" ? "pty" : frozenSessionKind,
                    provider: frozenSessionKind == "shell" || (frozenEmployeeID != nil && !frozenEmployeeOverride) ? nil : frozenProvider,
                    cwd: sessionCwd,
                    mode: frozenSessionKind == "structured" && (frozenEmployeeID == nil || frozenEmployeeOverride) ? frozenMode : nil,
                    model: frozenSessionKind == "structured" && (frozenEmployeeID == nil || frozenEmployeeOverride) && !frozenModel.isEmpty ? frozenModel : nil,
                    thinkingEffort: frozenSessionKind == "structured" && (frozenEmployeeID == nil || frozenEmployeeOverride) ? frozenEffort : nil,
                    prompt: nil,
                    engine: frozenSessionKind == "structured" && (frozenEmployeeID == nil || frozenEmployeeOverride) ? frozenEngine : nil,
                    shell: frozenSessionKind == "shell",
                    workspaceId: sessionWorkspaceID,
                    workspaceTaskId: frozenTaskIDForSession,
                    employeeId: frozenEmployeeID,
                    overrideCli: frozenEmployeeID != nil && frozenEmployeeOverride,
                    creationRequestId: sessionRequestID
                )
            })
            guard let snapshot else {
                creating = false
                if case .deliveryUnknown(let reason) = coordinator.phase {
                    errorMessage = "创建结果未知，请先到会话列表核对，不能重复创建。\n\(reason)"
                } else if case .rejected(let reason) = coordinator.phase {
                    errorMessage = reason
                    coordinator.retryRejectedTaskCreation()
                }
                return
            }
            do {
                if frozenAttachments.stagedAttachmentCount > 0 {
                    try await frozenAttachments.uploadStaged(to: snapshot.id)
                }
            } catch {
                creating = false
                errorMessage = "会话已创建，但附件上传失败；保留会话与本地附件，请重试交接。\n\(error.localizedDescription)"
                return
            }
            creating = false
            let draft = SessionDraftStore.shared.draft(sessionId: snapshot.id, api: api)
            let attachmentFiles = frozenAttachments.attachments
            guard coordinator.adopt(frozenText, expectedSourceRevision: frozenDraftRevision,
                                    currentSourceRevision: pendingDraftRevision,
                                    expectedAttachmentRevision: frozenAttachmentRevision,
                                    currentAttachmentRevision: pendingAttachmentRevision,
                                    sourceText: frozenSourceText, attachments: attachmentFiles,
                                    targetSessionID: snapshot.id, into: draft) == .adopted else {
                errorMessage = "会话已创建，但草稿在交接期间发生变化或目标草稿已有内容，已保留两侧内容。"
                return
            }
            if !frozenText.isEmpty || !attachmentFiles.isEmpty { draft.requestInitialSend() }
            clearPendingDraft(textRevision: frozenDraftRevision, attachmentRevision: frozenAttachmentRevision,
                              sourceText: frozenText)
            coordinator.resetAfterHandoff(sessionID: snapshot.id)
            onCreated(snapshot)
        }
    }

    private func modeTitle(_ value: String) -> String {
        switch value {
        case "managed": return "托管"
        case "full-access": return "全权限"
        case "auto-edit": return "自动编辑"
        case "native": return "原生"
        default: return "标准"
        }
    }
}
