import SwiftUI

enum NewTaskChoice: String, Identifiable {
    case subject, model, thinking, mode, kind, parent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subject: return "选择派发对象"
        case .model: return "模型"
        case .thinking: return "思考深度"
        case .mode: return "执行模式"
        case .kind: return "会话类型"
        case .parent: return "归属父任务"
        }
    }
}

func newTaskStartsUngroupedSession(name: String, startFirstSession: Bool, parentTaskID: String?, teamSelected: Bool) -> Bool {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && startFirstSession &&
        (parentTaskID?.isEmpty != false) && !teamSelected
}

struct NewTaskWindowLaunch {
    let workspace: Workspace
    let creation: WorkspaceTaskCreation
    let subject: ContactExecutionSubject?
    let target: WorkspaceSessionTarget
    let kind: WorkspaceSessionKind
    let prompt: String?
    let mode: String
    let model: String
    let thinking: String
}
func newTaskMayRetryLaunch(accepted: Bool, unknown: Bool) -> Bool { !accepted && !unknown }

/// Content first, one subject selector and a fixed submission surface. The existing
/// WorkspaceStore still owns creation receipts and unknown-delivery protection.
/// 目录按 find-or-create 归入隐式项目；`worktree: false` 时服务端只做界面分组，不建磁盘目录。
struct WorkspaceNewTaskSheet: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    @StateObject private var dispatchModel: TeamDispatchStore
    @State private var dispatchMode = false
    @State private var confirmNewDispatch = false
    /// 预填目录（从项目组「＋」进入时为项目 cwd；全局入口为空）。
    var initialCwd: String = ""
    var workspaceId: String? = nil
    let onCreated: (WorkspaceNewTaskResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var cwd = ""
    @State private var worktreeEnabled = false
    @State private var showingAdvanced = false
    @State private var startFirstSession = true
    @State private var prompt = ""
    @State private var target: WorkspaceSessionTarget = .claude
    @State private var sessionKind: WorkspaceSessionKind = .structured
    @State private var model = ""
    @State private var thinkingEffort = "off"
    @State private var mode = "default"
    @State private var defaultThinkingEffort = "off"
    @State private var defaultModels = ProviderDefaultModels()
    @State private var availableModels: [ModelInfo] = []
    @State private var thinkingOptions: [ThinkingEffortOption] = []
    @State private var suggestions: [WorkspacePathSuggestion] = []
    @State private var recentPaths: [WorkspaceRecentPath] = []
    @State private var showingSuggestions = false
    @State private var creating = false
    @State private var subject: ContactExecutionSubject?
    @State private var employees: [SiliconEmployee] = []
    @State private var teams: [ContactTeam] = []
    @State private var contactsLoading = false
    @State private var contactsError: String?
    @State private var loadGeneration = 0
    @State private var errorMessage: String?
    @State private var choice: NewTaskChoice?
    @State private var parentTaskID = ""
    @State private var parentTasks: [WandBoardTask] = []
    @State private var parentError: String?
    @State private var defaultsLoaded = false
    @State private var parentsLoading = false
    @State private var submissionPhase = ComposerSendPhase.idle
    @State private var acceptedCreation: WorkspaceNewTaskResult?
    @State private var pendingLaunch: NewTaskWindowLaunch?
    @State private var modelRevision = 0
    @State private var directoryRevision = 0
    @FocusState private var promptFocused: Bool
    @FocusState private var nameFocused: Bool
    @State private var defaultCwd = ""
    @State private var directoryPickerPresented = false
    @State private var directoryPickerPath = "/"
    @State private var directoryListing: DirectoryListing?
    @State private var directoryLoading = false
    @State private var directoryError: String?
    @State private var selectedWorkspaceId: String?
    @FocusState private var cwdFocused: Bool

    init(
        api: WandAPI,
        store: WorkspaceStore,
        initialCwd: String = "",
        workspaceId: String? = nil,
        onCreated: @escaping (WorkspaceNewTaskResult) -> Void
    ) {
        self.api = api
        self.store = store
        self.initialCwd = initialCwd
        self.workspaceId = workspaceId
        self.onCreated = onCreated
        _dispatchModel = StateObject(wrappedValue: TeamDispatchStoreCache.shared.store(api: api, scope: "new-task"))
        _cwd = State(initialValue: initialCwd.trimmingCharacters(in: .whitespacesAndNewlines))
        _selectedWorkspaceId = State(initialValue: workspaceId)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WandAmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("任务内容").font(.subheadline.weight(.semibold))
                            TextField("输入任务内容", text: $prompt, axis: .vertical)
                                .lineLimit(4...8).font(.body).focused($promptFocused)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("new-task-prompt")
                        }.padding(.vertical, 8)
                        Button { choice = .subject } label: {
                            HStack(spacing: 12) {
                                Image(systemName: subject == nil ? "terminal" : subject?.type == "team" ? "person.3" : "person")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(subjectTitle).font(.subheadline.weight(.semibold))
                                    Text("选择员工、团队或执行工具").font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer(); Image(systemName: "chevron.down")
                            }.frame(minHeight: 56).contentShape(Rectangle())
                        }.buttonStyle(WandQuietButtonStyle()).disabled(!defaultsLoaded)
                            .accessibilityIdentifier("new-task-subject")
                        Button { promptFocused = false; openDirectoryPicker() } label: {
                            HStack {
                                Label("运行目录", systemImage: "folder")
                                Spacer()
                                Text(trimmedDirectory.isEmpty ? "选择目录" : trimmedDirectory)
                                    .lineLimit(1).truncationMode(.middle)
                                Image(systemName: "chevron.down")
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(WandQuietButtonStyle()).disabled(!defaultsLoaded).accessibilityIdentifier("new-task-directory")
                        if let contactsError {
                            errorBanner(contactsError)
                            Button("重试执行对象") { Task { await loadContacts() } }.buttonStyle(WandQuietButtonStyle())
                        }
                        if dispatchMode {
                            Stepper("建议最多 \(dispatchModel.maxMembers) 位员工", value: $dispatchModel.maxMembers, in: 2...8)
                            TeamDispatchRoster(store: dispatchModel)
                            if dispatchModel.uncertain {
                                Text("开工结果未确认，请先核对任务记录，勿重复开工。").font(.caption).foregroundStyle(Theme.danger)
                                Button("已核对记录，开始新派工") { confirmNewDispatch = true }.buttonStyle(WandQuietButtonStyle())
                            }
                        } else { advancedCard }
                        if store.taskCreationUnconfirmed {
                            Text("任务创建结果未确认，请先刷新并核对任务列表。").font(.caption).foregroundStyle(Theme.danger)
                            Button("我已核对，开始新的创建操作") { store.acknowledgeUnconfirmedTaskCreation(); errorMessage = nil }
                                .font(.caption).disabled(creating)
                        }
                    }
                    .padding(16)
                }
                .disabled(creationBusy || acceptedCreation != nil)
                .safeAreaInset(edge: .bottom, spacing: 0) { submissionFooter }
            }
            .navigationTitle("新建任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(creationBusy)
                }
            }
            .interactiveDismissDisabled(creationBusy)
            .alert("确认已核对任务记录？", isPresented: $confirmNewDispatch) {
                Button("取消", role: .cancel) {}
                Button("开始新派工") { dispatchModel.newIntent() }
            } message: { Text("这不是重试旧请求。未确认的任务可能已开工，新派工将创建另一项任务。") }
            .onAppear { dispatchModel.activate() }
            .onKeyPress(.escape) {
                guard !creationBusy else { return .handled }
                if promptFocused || cwdFocused || nameFocused { promptFocused = false; cwdFocused = false; nameFocused = false }
                else if showingAdvanced { setAdvanced(false) }
                else { dismiss() }
                return .handled
            }
            .onChange(of: prompt) { _, value in if dispatchMode { dispatchModel.note = value } }
            .onChange(of: boundProjectID) { _, id in if dispatchMode { dispatchModel.workspaceID = id ?? "" } }
            .sheet(item: $choice) { choiceSheet($0) }
            .sheet(isPresented: $directoryPickerPresented) {
                directoryPicker
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task {
                defer { defaultsLoaded = true }
                if prompt.isEmpty, let recovery = store.unconfirmedCreationPrompt { prompt = recovery }
                if let config = try? await api.serverConfig() {
                    defaultCwd = config.defaultCwd ?? ""
                    if config.defaultProvider == "pi", config.defaultEngine == "sdk" {
                        target = .wandAgent
                        sessionKind = .structured
                    } else {
                        if let raw = config.defaultProvider,
                           let provider = WorkspaceSessionTarget(rawValue: raw), provider != .shell {
                            target = provider
                        }
                        sessionKind = config.defaultSessionKind == "pty" && target != .wandAgent ? .pty : .structured
                    }
                    if config.defaultProvider == "pi" && config.defaultEngine != "sdk" && target == .wandAgent {
                        target = .pi
                    }
                    let configuredMode = config.defaultMode?.trimmingCharacters(in: .whitespacesAndNewlines)
                    mode = (target.provider?.clamp(mode: configuredMode) ?? configuredMode.map { $0.isEmpty ? "default" : $0 }) ?? "default"
                    model = ""
                    thinkingEffort = config.resolvedDefaultThinkingEffort
                    defaultThinkingEffort = config.resolvedDefaultThinkingEffort
                    defaultModels = ProviderDefaultModels(
                        claude: config.defaultModelId(for: "claude"),
                        codex: config.defaultModelId(for: "codex"),
                        opencode: config.defaultModelId(for: "opencode"),
                        grok: config.defaultModelId(for: "grok"),
                        qoder: config.defaultModelId(for: "qoder"),
                        pi: config.defaultModelId(for: "pi")
                    )
                    if let models = try? await api.models() {
                        availableModels = models.models(for: target.provider?.rawValue ?? "claude")
                        thinkingOptions = thinkingEffortOptions(
                            provider: target.provider?.rawValue ?? "claude",
                            selectedModel: model,
                            defaultModel: defaultModels.modelId(for: target.provider?.rawValue ?? "claude"),
                            models: availableModels,
                            providerEfforts: models.thinkingEfforts[target.provider?.rawValue ?? "claude"] ?? []
                        )
                        if !thinkingOptions.contains(where: { $0.id == thinkingEffort }) {
                            thinkingEffort = thinkingOptions.contains(where: { $0.id == defaultThinkingEffort }) ? defaultThinkingEffort : "off"
                        }
                    }
                }
                if recentPaths.isEmpty, let recent = try? await api.workspaceRecentPaths() {
                    recentPaths = recent
                }
                if cwd.isEmpty { cwd = defaultCwd.isEmpty ? (recentPaths.first?.path ?? "") : defaultCwd }
                await loadContacts()
            }
            .task(id: boundProjectID) { await loadParents() }
            .onDisappear { dispatchModel.close(); loadGeneration += 1; directoryRevision += 1 }
            .task(id: debounceKey) {
                guard cwdFocused else { return }
                try? await Task.sleep(nanoseconds: 240_000_000)
                guard !Task.isCancelled else { return }
                await loadSuggestions()
            }
            .onChange(of: cwdFocused) { _, focused in
                if focused {
                    showingSuggestions = true
                    Task { await loadSuggestions() }
                } else {
                    showingSuggestions = false
                }
            }
        }
    }

    private var startsUngrouped: Bool {
        newTaskStartsUngroupedSession(name: name, startFirstSession: startFirstSession,
            parentTaskID: parentTaskID, teamSelected: subject?.type == "team" || dispatchMode)
    }
    private var creationBusy: Bool { creating || (dispatchMode && dispatchModel.phase == .sending) }
    private var subjectTitle: String {
        if dispatchMode { return "不指派 · 决策派工" }
        if let subject, subject.type == "employee" { return employees.first { $0.id == subject.id }?.name ?? "员工已不可用" }
        if let subject, subject.type == "team" { return teams.first { $0.id == subject.id }?.name ?? "团队已不可用" }
        return target.title
    }
    private var submitTitle: String {
        if creating { return submissionPhase == .sent ? "已创建" : "创建中…" }
        if let pendingLaunch { return pendingLaunch.subject?.type == "team" ? "重试交给团队" : "重试启动会话" }
        if acceptedCreation != nil { return "打开已创建的任务" }
        if dispatchMode {
            if dispatchModel.acceptedRunID != nil { return "打开已接受的任务" }
            if dispatchModel.phase == .sending { return dispatchModel.plan == nil ? "正在选人…" : "正在开工…" }
            return dispatchModel.plan == nil ? "决策选人" : "确认开工"
        }
        if startsUngrouped { return "直接开工" }
        if startFirstSession && subject?.type == "team" { return "创建并交给团队" }
        if startFirstSession && subject?.type == "employee" { return "创建并交给员工" }
        return startFirstSession ? "创建并启动会话" : "创建任务分组"
    }
    private var submissionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                Text(errorMessage ?? (dispatchMode ? (!teamAllowed ? "决策派工需要先选择一个已有项目。" : dispatchModel.message ?? "决策选人后再确认开工；只将任务内容作为执行目标。") : submissionHint) ?? (startsUngrouped
                    ? "直接开始会话，不建卡；稍后可归纳到任务。"
                    : "\(trimmedName.isEmpty ? "自动命名" : trimmedName) · \(worktreeEnabled ? "独立工作树" : "共用目录")"))
                    .font(.caption).foregroundStyle(errorMessage == nil ? Theme.textSecondary : Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let acceptedCreation, pendingLaunch != nil {
                        Button("打开已创建的任务，不重试") { Task { await deliver(acceptedCreation) } }
                            .font(.caption).disabled(creationBusy)
                    }
                }
            }.frame(height: 48)
            Button { Task { await submit() } } label: {
                HStack {
                    ProgressView().controlSize(.small).opacity(creationBusy && submissionPhase != .sent ? 1 : 0)
                    Text(submitTitle).font(.subheadline.weight(.semibold))
                    Image(systemName: "checkmark").opacity(submissionPhase == .sent ? 1 : 0)
                }.frame(maxWidth: .infinity, minHeight: 22)
            }.buttonStyle(WandPrimaryButtonStyle()).disabled(!canSubmit)
                .accessibilityIdentifier("new-task-submit")
        }.padding(.horizontal, 16).padding(.vertical, 8).background(Theme.background)
    }
    private var subjectSections: [SearchableChoiceSection] {
        var sections: [SearchableChoiceSection] = [SearchableChoiceSection(id: "dispatch",
            items: [SearchableChoiceItem(id: "dispatch", label: "不指派 · 决策选人后再确认开工")], selectedId: dispatchMode ? "dispatch" : "")]
        let people = employees.filter { !$0.archived && !$0.agents.isEmpty }
        if !people.isEmpty {
            sections.append(SearchableChoiceSection(id: "employee", title: "硅基员工",
                items: people.map { SearchableChoiceItem(id: $0.id, label: $0.name) },
                selectedId: subject?.type == "employee" ? subject!.id : "", searchable: true))
        }
        if teamAllowed && !teams.isEmpty {
            sections.append(SearchableChoiceSection(id: "team", title: "AI 团队",
                items: teams.map { SearchableChoiceItem(id: $0.id, label: "\($0.name)（\($0.members.count) 人）") },
                selectedId: subject?.type == "team" ? subject!.id : "", searchable: true))
        }
        sections.append(SearchableChoiceSection(id: "tool", title: "执行工具",
            items: WorkspaceSessionTarget.allCases.map { SearchableChoiceItem(id: $0.rawValue, label: $0.title) },
            selectedId: subject == nil && !dispatchMode ? target.rawValue : ""))
        return sections
    }
    private func choiceSheet(_ selected: NewTaskChoice) -> some View {
        let sections: [SearchableChoiceSection]
        switch selected {
        case .subject: sections = subjectSections
        case .model: sections = [SearchableChoiceSection(id: "model", items:
            [SearchableChoiceItem(id: "", label: "默认模型")] + availableModels.filter { $0.id != "default" }.map { SearchableChoiceItem(id: $0.id, label: $0.label) }, selectedId: model, searchable: true)]
        case .thinking: sections = [SearchableChoiceSection(id: "thinking", items: thinkingOptions.map { SearchableChoiceItem(id: $0.id, label: $0.menuLabel) }, selectedId: thinkingEffort)]
        case .kind: sections = [SearchableChoiceSection(id: "kind", items: WorkspaceSessionKind.allCases.filter { target != .wandAgent || $0 == .structured }.map { SearchableChoiceItem(id: $0.rawValue, label: $0.title) }, selectedId: sessionKind.rawValue)]
        case .mode: sections = [SearchableChoiceSection(id: "mode", items: Self.sessionModes.filter { target.provider?.supportedModeIDs.contains($0.id) == true }.map { SearchableChoiceItem(id: $0.id, label: $0.label + " · " + $0.desc) }, selectedId: mode)]
        case .parent: sections = [SearchableChoiceSection(id: "parent", items: [SearchableChoiceItem(id: "", label: "不关联父任务")] + parentTasks.map { SearchableChoiceItem(id: $0.id, label: "\($0.identifier) \($0.title)") }, selectedId: parentTaskID, searchable: true)]
        }
        return SearchableChoiceSheet(title: selected.title, sections: sections) { section, id in
            errorMessage = nil
            switch selected {
            case .subject:
                dispatchMode = section == "dispatch"
                if dispatchMode {
                    subject = nil; dispatchModel.note = prompt; dispatchModel.workspaceID = boundProjectID ?? ""
                } else if section == "tool", let next = WorkspaceSessionTarget(rawValue: id) {
                    subject = nil
                    if target != next { model = ""; thinkingEffort = defaultThinkingEffort }
                    target = next
                    if next == .wandAgent { sessionKind = .structured }
                    if next == .shell { sessionKind = .pty }
                    mode = next.provider?.clamp(mode: mode) ?? "default"
                    refreshModelChoices(for: next)
                } else { subject = ContactExecutionSubject(type: section, id: id); sessionKind = .structured }
            case .model: model = id; refreshModelChoices(for: target)
            case .thinking: thinkingEffort = id
            case .mode: mode = id
            case .kind: if let kind = WorkspaceSessionKind(rawValue: id) { sessionKind = kind }
            case .parent: parentTaskID = id
            }
        }.presentationDetents([.medium, .large])
    }
    private func loadParents() async {
        parentsLoading = true; parentError = nil
        let project = boundProjectID
        guard project != nil else { parentTasks = []; parentTaskID = ""; parentsLoading = false; return }
        do {
            let tasks = try await api.listBoardTasks(workspaceId: project)
            guard !Task.isCancelled, boundProjectID == project else { return }
            parentTasks = tasks.filter { project == nil || $0.workspaceId == project }
            if !parentTaskID.isEmpty && !parentTasks.contains(where: { $0.id == parentTaskID }) { parentTaskID = "" }
        } catch { if !Task.isCancelled && boundProjectID == project { parentError = "父任务读取失败，可重试。" } }
        if boundProjectID == project { parentsLoading = false }
    }

    private func deliver(_ result: WorkspaceNewTaskResult) async {
        creating = true
        submissionPhase = .sent
        try? await Task.sleep(nanoseconds: WandMotion.submittedDwell)
        dismiss()
        onCreated(result)
    }

    private var debounceKey: String {
        "\(cwdFocused)-\(cwd)"
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDirectory: String {
        cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 首个会话的提示词：仅结构化会话能当描述用；PTY 的首行输入不走自动命名。
    private var taskPrompt: String? {
        return trimmedPrompt.isEmpty ? nil : trimmedPrompt
    }

    private var submissionHint: String? {
        if store.taskCreationUnconfirmed { return "创建结果未确认，请先核对任务列表，勿重复创建。" }
        if !defaultsLoaded { return "正在读取默认配置…" }
        if trimmedDirectory.isEmpty { return "请选择工作目录后创建任务。" }
        if trimmedName.utf16.count > 80 { return "任务名称不能超过 80 个字符。" }
        if startFirstSession, let subject {
            if subject.type == "employee", !employees.contains(where: { $0.id == subject.id && !$0.archived && !$0.agents.isEmpty }) {
                return "所选员工当前不可用，请重新选择执行主体。"
            }
            if subject.type == "team" {
                if !teamAllowed || !teams.contains(where: { $0.id == subject.id }) { return "请为团队选择有效的工作区和执行主体。" }
                if trimmedPrompt.isEmpty { return "请填写交给团队的任务描述。" }
            }
        }
        if !parentTaskID.isEmpty && !parentTasks.contains(where: { $0.id == parentTaskID }) { return "父任务已不可用，请重新选择。" }
        if trimmedName.isEmpty && !startsUngrouped && subject?.type != "team" { return "请填写任务名称。" }
        return nil
    }

    private var canSubmit: Bool {
        guard !creationBusy, defaultsLoaded else { return false }
        if acceptedCreation != nil { return true }
        if dispatchMode {
            if dispatchModel.acceptedRunID != nil { return true }
            return teamAllowed && (dispatchModel.plan == nil ? dispatchModel.canPlan : dispatchModel.canStart)
        }
        return submissionHint == nil
    }

    private var boundProjectID: String? {
        selectedWorkspaceId ?? (matchingProjects.count == 1 ? matchingProjects.first?.workspaceId : nil)
    }
    private var teamAllowed: Bool {
        guard let id = boundProjectID else { return false }
        return id != "wand-global" && matchingProjects.contains { $0.workspaceId == id }
    }
    private func loadContacts() async {
        loadGeneration += 1; let generation = loadGeneration; contactsLoading = true
        async let people = try? api.listContactEmployees()
        async let groups = try? api.listContactTeams()
        let (p, t) = await (people, groups)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if let p { employees = p }; if let t { teams = t }
        contactsError = p == nil || t == nil ? "通讯录未能完整刷新，已有选择已保留。" : nil
        contactsLoading = false
    }

    private var matchingProjects: [TaskDirectoryGroup] {
        let cwd = normalizeDirectoryPath(trimmedDirectory)
        guard cwd != "/" else { return [] }
        return store.taskGroups.filter { group in
            group.isBindableProject && normalizeDirectoryPath(group.workspaceCwd) == cwd
        }
    }

    private func updateTaskCwd(_ value: String) {
        if cwd != value { cwd = value }
        if directoryPickerPresented && normalizeDirectoryPath(value) != directoryPickerPath { browseDirectory(value) }
        reconcileSelectedWorkspace()
    }

    private func reconcileSelectedWorkspace() {
        if let selectedWorkspaceId,
           matchingProjects.contains(where: { $0.workspaceId == selectedWorkspaceId }) == false {
            self.selectedWorkspaceId = nil
        }
        errorMessage = nil
    }

    private func loadSuggestions() async {
        let query = trimmedDirectory
        do {
            let result = try await api.workspacePathSuggestions(query: query)
            guard query == trimmedDirectory, cwdFocused else { return }
            suggestions = result.filter(\.isDirectory).prefix(6).map { $0 }
        } catch {
            guard query == trimmedDirectory else { return }
            suggestions = []
        }
    }

    private func fieldCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.wand(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private var nameCard: some View {
        fieldCard(title: "任务名称（可选）") {
            TextField("留空按提示词自动命名", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.wand(size: 15)).focused($nameFocused).accessibilityIdentifier("new-task-name")
        }
    }

    private func refreshModelChoices(for target: WorkspaceSessionTarget) {
        guard let provider = target.provider?.rawValue else {
            availableModels = []
            thinkingOptions = []
            model = ""
            return
        }
        modelRevision += 1; let revision = modelRevision
        Task {
            guard let response = try? await api.models() else { return }
            guard !Task.isCancelled, revision == modelRevision, self.target == target else { return }
            availableModels = response.models(for: provider)
            thinkingOptions = thinkingEffortOptions(
                provider: provider,
                selectedModel: model,
                defaultModel: defaultModels.modelId(for: provider),
                models: availableModels,
                providerEfforts: response.thinkingEfforts[provider] ?? []
            )
            if !thinkingOptions.contains(where: { $0.id == thinkingEffort }) {
                thinkingEffort = thinkingOptions.contains(where: { $0.id == defaultThinkingEffort }) ? defaultThinkingEffort : "off"
            }
        }
    }

    private var directoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldCard(title: "工作目录（服务器上的路径）") {
                HStack(spacing: 8) {
                    TextField("点击浏览或输入路径", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.wand(size: 15, design: .monospaced))
                        .focused($cwdFocused)
                        .onSubmit { browseDirectory(trimmedDirectory) }
                        .onChange(of: cwd) { _, _ in
                            reconcileSelectedWorkspace()
                        }
                    Button {
                        openDirectoryPicker()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.brand)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brand.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("浏览工作目录")
                }
            }
            if showingSuggestions, cwdFocused, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            updateTaskCwd(suggestion.path)
                            showingSuggestions = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.name)
                                    .font(.wand(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text(suggestion.path)
                                    .font(.wand(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.4)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
                .padding(.top, -6)
            }
            if !recentPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentPaths) { recent in
                            Button {
                                updateTaskCwd(recent.path)
                            } label: {
                                Text(recent.name.isEmpty ? recent.path : recent.name)
                                    .font(.wand(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(
                                            cwd == recent.path ? Theme.brand.opacity(0.16) : Theme.surface
                                        )
                                    )
                                    .foregroundColor(cwd == recent.path ? Theme.brand : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var directoryPicker: some View {
        NavigationStack {
            ZStack {
                WandAmbientBackground()
                if directoryLoading {
                    ProgressView("读取目录…").tint(Theme.brand)
                } else if let directoryError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundColor(Theme.danger)
                        Text(directoryError)
                            .font(.footnote)
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { browseDirectory(directoryPickerPath) }
                            .buttonStyle(WandSecondaryButtonStyle())
                    }
                    .padding(24)
                } else {
                    List {
                        Button {
                            updateTaskCwd(directoryPickerPath)
                            directoryPickerPresented = false
                        } label: {
                            Label("选择此目录", systemImage: "checkmark.circle")
                                .foregroundColor(Theme.brand)
                        }
                        .listRowBackground(Theme.surface)
                        if directoryPickerPath != "/" {
                            Button {
                                browseDirectory(parentDirectory(directoryPickerPath))
                            } label: {
                                Label("返回上级目录", systemImage: "arrow.up")
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .listRowBackground(Theme.background)
                        }
                        ForEach((directoryListing?.items ?? []).filter(\.isDirectory)) { item in
                            Button {
                                browseDirectory(item.path)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(Theme.brand)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .foregroundColor(Theme.textPrimary)
                                        Text(item.path)
                                            .font(.wand(size: 11, design: .monospaced))
                                            .foregroundColor(Theme.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Theme.textMuted)
                                }
                            }
                            .listRowBackground(Theme.background)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { directoryCard.padding(.horizontal, 16) }
            .navigationTitle("选择工作目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { directoryPickerPresented = false }
                }
            }
        }
    }

    private func openDirectoryPicker() {
        directoryPickerPath = trimmedDirectory.isEmpty ? (defaultCwd.isEmpty ? "/" : defaultCwd) : trimmedDirectory
        directoryPickerPresented = true
        browseDirectory(directoryPickerPath)
    }

    private func browseDirectory(_ path: String) {
        let requestedPath = normalizeDirectoryPath(path)
        directoryRevision += 1; let revision = directoryRevision
        directoryPickerPath = requestedPath
        directoryLoading = true
        directoryError = nil
        Task {
            do {
                let result = try await api.listDirectory(requestedPath)
                guard !Task.isCancelled, revision == directoryRevision else { return }
                directoryListing = result
            } catch {
                guard !Task.isCancelled, revision == directoryRevision else { return }
                directoryError = error.localizedDescription
            }
            directoryLoading = false
        }
    }

    private func parentDirectory(_ path: String) -> String {
        let normalized = normalizeDirectoryPath(path)
        guard normalized != "/" else { return "/" }
        guard let slash = normalized.lastIndex(of: "/") else { return "/" }
        let parent = String(normalized[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    private func normalizeDirectoryPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        if trimmed == "/" { return "/" }
        var normalized = trimmed
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private var cliCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if target != .shell {
                Text("会话类型")
                    .font(.wand(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Button { choice = .kind } label: {
                    HStack { Text(sessionKind.title); Spacer(); Image(systemName: "chevron.down") }.frame(minHeight: 44)
                }.buttonStyle(WandQuietButtonStyle())
            }
            if target != .shell && sessionKind == .structured {
                Divider().overlay(Theme.border)
                executionSettingsCard
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private var executionSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模式")
                .font(.wand(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Button { choice = .mode } label: {
                HStack { Text(Self.sessionModes.first { $0.id == mode }?.label ?? "标准"); Spacer(); Image(systemName: "chevron.down") }.frame(minHeight: 44)
            }.buttonStyle(WandQuietButtonStyle())
            HStack(spacing: 8) {
                Button { choice = .model } label: {
                    Label(availableModels.first { $0.id == model }?.label ?? "默认模型", systemImage: "slider.horizontal.3").lineLimit(2)
                }.buttonStyle(WandQuietButtonStyle())
                Button { choice = .thinking } label: {
                    Label(thinkingOptions.first { $0.id == thinkingEffort }?.label ?? "自动", systemImage: "brain").lineLimit(2)
                }.buttonStyle(WandQuietButtonStyle())
            }
        }
    }

    private static let sessionModes = [
        SessionModeChoice(id: "managed", label: "托管", desc: "自动完成任务"),
        SessionModeChoice(id: "full-access", label: "全权限", desc: "自动批准权限"),
        SessionModeChoice(id: "auto-edit", label: "自动编辑", desc: "偏向直接编辑"),
        SessionModeChoice(id: "default", label: "标准", desc: "保留确认流程"),
        SessionModeChoice(id: "native", label: "原生", desc: "原生 API 输出"),
    ]

    private struct SessionModeChoice: Identifiable {
        let id: String
        let label: String
        let desc: String
    }

    /// 「创建后」二选一：直接启动首个会话，或只建分组（对齐 Android 的 WandChoiceStrip）。
    private var createModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("创建后")
                .font(.wand(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Toggle(startsUngrouped ? "直接开工，不建任务卡" : "创建后启动会话", isOn: $startFirstSession)
                .disabled(subject != nil).accessibilityIdentifier("new-task-start")
            Text(startsUngrouped ? "会话先落在该目录的未分组任务里，需要时再归纳成新任务。" : "关闭后只建任务分组，任务内容仍保留为描述。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func setAdvanced(_ open: Bool) {
        withAnimation(reduceMotion ? nil : WandMotion.expansion) { showingAdvanced = open }
    }

    /// worktree 隔离默认关闭（服务端默认也不建目录），需要时才在高级里打开。
    @ViewBuilder
    private var advancedCard: some View {
        Button {
            setAdvanced(!showingAdvanced)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showingAdvanced ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                Text(showingAdvanced ? "收起高级选项" : "高级选项")
                    .font(.wand(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(WandQuietButtonStyle())
        .disabled(creating || !defaultsLoaded).accessibilityIdentifier("new-task-advanced")
        if showingAdvanced {
            nameCard
            createModeCard
            if startFirstSession && subject == nil { cliCard }
            Button { choice = .parent } label: {
                HStack {
                    Label("归属父任务", systemImage: "list.bullet.indent")
                    Spacer()
                    Text(parentTasks.first { $0.id == parentTaskID }?.title ?? "不关联父任务").lineLimit(1)
                    Image(systemName: "chevron.down")
                }.frame(minHeight: 44)
            }.buttonStyle(WandQuietButtonStyle()).disabled(parentsLoading || boundProjectID == nil)
            if let parentError {
                Text(parentError).font(.caption).foregroundStyle(Theme.danger)
                Button("重试父任务") { Task { await loadParents() } }.buttonStyle(WandQuietButtonStyle())
            }
            Picker("工作目录方式", selection: $worktreeEnabled) {
                Text("共用工作区").tag(false)
                Text("隔离 worktree").tag(true)
            }.pickerStyle(.segmented)
            Text(worktreeEnabled
                ? "需要 Git 仓库，会创建独立工作树。"
                : "默认仅做界面分组，不创建目录。")
                .font(.footnote)
                .foregroundColor(Theme.textMuted)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundColor(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.danger.opacity(0.08))
            )
    }

    private func submit() async {
        guard canSubmit else { return }
        if let acceptedCreation {
            if let pendingLaunch {
                creating = true; submissionPhase = .sending; errorMessage = nil
                defer { creating = false }
                await launchFirstWindow(pendingLaunch)
            } else { await deliver(acceptedCreation) }
            return
        }
        if dispatchMode {
            if let runID = dispatchModel.acceptedRunID { await deliver(WorkspaceNewTaskResult(runID: runID)); return }
            if dispatchModel.plan == nil { dispatchModel.suggest() }
            else { dispatchModel.start { runID in Task { await deliver(WorkspaceNewTaskResult(runID: runID)) } } }
            return
        }
        let requestedSubject = startFirstSession ? subject : nil
        let requestedPrompt = taskPrompt
        let requestedTarget = target
        let requestedKind: WorkspaceSessionKind = subject != nil || target == .wandAgent ? .structured : target == .shell ? .pty : sessionKind
        let requestedName = trimmedName
        let requestedDirectory = trimmedDirectory
        let requestedWorkspaceId = selectedWorkspaceId ?? (matchingProjects.count == 1 ? matchingProjects[0].workspaceId : nil)
        let requestedMode = requestedTarget.provider?.clamp(mode: mode) ?? mode
        let requestedModel = model == "default" ? "" : model
        let requestedThinking = thinkingEffort
        let requestedEngine = requestedTarget == .wandAgent ? "sdk" : requestedTarget == .pi ? "cli" : nil
        let requestedParentID = parentTaskID.isEmpty ? nil : parentTaskID
        creating = true
        submissionPhase = .sending
        errorMessage = nil
        defer { creating = false }

        // Same decision as Android, independent of cwd registration, prompt content,
        // CLI vs employee or Shell. A selected parent/team always retains task ownership.
        let createUnattachedSession = startsUngrouped
        if createUnattachedSession {
            var creationAttempted = false
            do {
                let snapshot = try await NewSessionEndpointMutationQueue.shared.run(endpointID: api.baseURL.absoluteString) {
                    creationAttempted = true
                    return try await api.createSession(
                        kind: requestedKind.rawValue,
                        provider: requestedSubject == nil ? requestedTarget.provider?.rawValue : nil,
                        cwd: requestedDirectory,
                        mode: requestedSubject == nil ? requestedMode : nil,
                        model: requestedSubject == nil ? requestedModel : nil,
                        thinkingEffort: requestedSubject == nil ? requestedThinking : nil,
                        prompt: requestedKind == .structured ? requestedPrompt : nil,
                        initialInput: requestedKind == .pty ? requestedPrompt : nil,
                        engine: requestedSubject == nil ? requestedEngine : nil,
                        shell: requestedSubject == nil && requestedTarget == .shell,
                        workspaceId: requestedWorkspaceId,
                        employeeId: requestedSubject?.type == "employee" ? requestedSubject?.id : nil
                    )
                }
                await deliver(WorkspaceNewTaskResult(session: snapshot, sessionError: nil))
            } catch {
                submissionPhase = .failed
                if contactCreationNeedsReview(attempted: creationAttempted, error: error) {
                    store.markUnconfirmedTaskCreation(prompt: prompt)
                    errorMessage = "会话创建结果未确认，请先核对会话列表，勿重复创建。"
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        let workspace: Workspace
        let creation: WorkspaceTaskCreation
        do {
            (workspace, creation) = try await store.createTask(
                name: requestedName,
                directory: requestedDirectory,
                worktree: worktreeEnabled,
                workspaceId: requestedWorkspaceId,
                description: requestedPrompt,
                parentTaskId: requestedParentID
            )
        } catch {
            submissionPhase = .failed
            if store.taskCreationUnconfirmed { store.markUnconfirmedTaskCreation(prompt: prompt) }
            errorMessage = store.taskCreationUnconfirmed
                ? "任务创建结果未确认，请先刷新并核对任务列表，勿重复创建。"
                : error.localizedDescription
            return
        }

        guard startFirstSession else {
            await deliver(WorkspaceNewTaskResult(workspace: workspace, creation: creation, session: nil, sessionError: nil))
            return
        }

        await launchFirstWindow(NewTaskWindowLaunch(workspace: workspace, creation: creation,
            subject: requestedSubject, target: requestedTarget, kind: requestedKind, prompt: requestedPrompt,
            mode: requestedMode, model: requestedModel, thinking: requestedThinking))
    }

    private func launchFirstWindow(_ launch: NewTaskWindowLaunch) async {
        let workspace = launch.workspace, creation = launch.creation
        let requestedSubject = launch.subject, requestedTarget = launch.target, requestedKind = launch.kind
        let requestedPrompt = launch.prompt, requestedMode = launch.mode, requestedModel = launch.model, requestedThinking = launch.thinking
        var teamDispatchAttempted = false
        var acceptedTeamReceipt: WandBoardDispatchResult?
        do {
            let snapshot: SessionSnapshot
            if let requestedSubject, requestedSubject.type == "team" {
                let board = try await api.contactBoardTask(workspaceTaskID: creation.id, workspaceID: workspace.id)
                teamDispatchAttempted = true
                let result = try await api.dispatchContactTask(id: board.id, subject: requestedSubject, prompt: requestedPrompt ?? "")
                acceptedTeamReceipt = result
                store.scheduleAutoSelectSession(taskId: creation.id, sessionId: result.sessionId)
                snapshot = try await api.getSession(id: result.sessionId)
                await store.loadTaskGroups(force: true)
            } else {
                snapshot = try await store.createFirstTaskWindow(
                    taskId: creation.id,
                    target: requestedTarget,
                    kind: requestedTarget == .shell ? .pty : requestedKind,
                    prompt: requestedPrompt,
                    employeeID: requestedSubject?.type == "employee" ? requestedSubject?.id : nil,
                    mode: requestedSubject == nil ? requestedMode : nil,
                    model: requestedSubject == nil ? requestedModel : nil,
                    thinkingEffort: requestedSubject == nil ? requestedThinking : nil
                )
            }
            pendingLaunch = nil; acceptedCreation = nil
            await deliver(WorkspaceNewTaskResult(workspace: workspace, creation: creation, session: snapshot, sessionError: nil))
        } catch {
            if contactCreationNeedsReview(attempted: teamDispatchAttempted, accepted: acceptedTeamReceipt != nil, error: error) {
                store.markUnconfirmedWindow(taskID: creation.id)
            }
            submissionPhase = .failed
            let message = acceptedTeamReceipt != nil
                ? "团队已开始执行，群聊暂时未能加载，请从任务会话进入。"
                : store.unconfirmedWindowTasks.contains(creation.id)
                    ? "任务已创建，启动结果未确认，请核对任务会话，勿重复派发。"
                    : isDefiniteInputRejection(error)
                        ? "任务已创建，但本次启动被拒绝：\(error.localizedDescription)"
                        : "任务已创建，本次会话尚未启动，可重试：\(error.localizedDescription)"
            errorMessage = message
            pendingLaunch = newTaskMayRetryLaunch(accepted: acceptedTeamReceipt != nil,
                unknown: store.unconfirmedWindowTasks.contains(creation.id)) ? launch : nil
            acceptedCreation = WorkspaceNewTaskResult(workspace: workspace, creation: creation, session: nil, sessionError: nil)
        }
    }
}

struct WorkspaceNewTaskResult {
    let workspace: Workspace?
    let creation: WorkspaceTaskCreation?
    /// 「启动会话」成功时的首个会话；「仅建分组」与启动失败时为 nil。
    let session: SessionSnapshot?
    /// 任务已创建但首个会话没起来时的原因。
    let sessionError: String?
    let runID: String?

    init(runID: String) {
        workspace = nil; creation = nil; session = nil; sessionError = nil; self.runID = runID
    }

    init(workspace: Workspace, creation: WorkspaceTaskCreation, session: SessionSnapshot?, sessionError: String?) {
        self.workspace = workspace
        self.creation = creation
        self.session = session
        self.sessionError = sessionError
        runID = nil
    }

    init(session: SessionSnapshot?, sessionError: String?) {
        workspace = nil
        creation = nil
        self.session = session
        self.sessionError = sessionError
        runID = nil
    }
}
