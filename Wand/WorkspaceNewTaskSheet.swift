import SwiftUI

/// 新建任务 sheet（对齐 Android 的 TaskListScreen 新建对话框）：名称 + 工作目录 +
/// 「创建后」二选一（启动会话 / 仅建分组）+ 首个会话提示词，worktree 隔离收在「高级」里。
/// 目录按 find-or-create 归入隐式项目；`worktree: false` 时服务端只做界面分组，不建磁盘目录。
struct WorkspaceNewTaskSheet: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    /// 预填目录（从项目组「＋」进入时为项目 cwd；全局入口为空）。
    var initialCwd: String = ""
    var workspaceId: String? = nil
    let onCreated: (WorkspaceNewTaskResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cwd = ""
    @State private var worktreeEnabled = false
    @State private var showingAdvanced = false
    @State private var startFirstSession = true
    @State private var prompt = ""
    @State private var target: WorkspaceSessionTarget = .claude
    @State private var sessionKind: WorkspaceSessionKind = .structured
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
        _cwd = State(initialValue: initialCwd.trimmingCharacters(in: .whitespacesAndNewlines))
        _selectedWorkspaceId = State(initialValue: workspaceId)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WandAmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("任务是工作区内的分组，与任务看板同步，不会创建磁盘子目录。")
                            .font(.footnote)
                            .foregroundColor(Theme.textSecondary)
                        nameCard
                        directoryCard
                        createModeCard
                        if startFirstSession {
                            fieldCard(title: "执行主体") {
                                ContactExecutionSubjectPicker(subject: Binding(get: { subject }, set: { value in
                                    subject = value; if value != nil { sessionKind = .structured }
                                }), employees: employees, teams: teams, teamAllowed: teamAllowed,
                                   loading: contactsLoading, error: contactsError, onRetry: { Task { await loadContacts() } })
                            }
                            if subject == nil { cliCard }
                        }
                        advancedCard
                        if let errorMessage { errorBanner(errorMessage) }
                        if store.taskCreationUnconfirmed {
                            Text("任务创建结果未确认，请先刷新并核对任务列表。").font(.caption).foregroundStyle(Theme.danger)
                            Button("我已核对，开始新的创建操作") { store.acknowledgeUnconfirmedTaskCreation(); errorMessage = nil }
                                .font(.caption).disabled(creating)
                        }
                    }
                    .padding(16)
                }.disabled(creating)
            }
            .navigationTitle("新建任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(creating)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(creating ? "创建中…" : (startFirstSession ? (subject?.type == "team" ? "创建并交给团队" : "创建并启动会话") : "创建任务")) {
                        Task { await submit() }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(canSubmit ? Theme.brand : Theme.textMuted)
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(creating)
            .sheet(isPresented: $directoryPickerPresented) {
                directoryPicker
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task {
                if let config = try? await api.serverConfig() {
                    defaultCwd = config.defaultCwd ?? ""
                    if let raw = config.defaultProvider,
                       let provider = WorkspaceSessionTarget(rawValue: raw), provider != .shell {
                        target = provider
                    }
                    sessionKind = config.defaultSessionKind == "pty" ? .pty : .structured
                }
                if recentPaths.isEmpty, let recent = try? await api.workspaceRecentPaths() {
                    recentPaths = recent
                }
                if cwd.isEmpty { cwd = defaultCwd.isEmpty ? (recentPaths.first?.path ?? "") : defaultCwd }
                await loadContacts()
            }
            .onDisappear { loadGeneration += 1 }
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
        guard startFirstSession, subject != nil || target != .shell else { return nil }
        return trimmedPrompt.isEmpty ? nil : trimmedPrompt
    }

    private var canSubmit: Bool {
        guard !creating, !store.taskCreationUnconfirmed, !trimmedDirectory.isEmpty, trimmedName.count <= 80 else { return false }
        if startFirstSession, let subject {
            if subject.type == "employee", !employees.contains(where: { $0.id == subject.id && !$0.archived && !$0.agents.isEmpty }) { return false }
            if subject.type == "team", (!teamAllowed || trimmedPrompt.isEmpty || !teams.contains(where: { $0.id == subject.id })) { return false }
        }
        return !trimmedName.isEmpty || taskPrompt != nil
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
                .font(.wand(size: 15))
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
        directoryPickerPath = normalizeDirectoryPath(path)
        directoryLoading = true
        directoryError = nil
        Task {
            do {
                let result = try await api.listDirectory(directoryPickerPath)
                guard !Task.isCancelled else { return }
                directoryListing = result
            } catch {
                guard !Task.isCancelled else { return }
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
            Text("CLI 工具")
                .font(.wand(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WorkspaceSessionTarget.allCases) { option in
                        let selected = target == option
                        Button {
                            target = option
                            if option == .wandAgent { sessionKind = .structured }
                            store.rememberCreationChoice(provider: option)
                        } label: {
                            Text(option.title)
                                .font(.wand(size: 13, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                                .background(
                                    Capsule().fill(selected ? Theme.brand.opacity(0.14) : Theme.surface)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if target != .shell {
                Text("会话类型")
                    .font(.wand(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                HStack(spacing: 8) {
                    ForEach(WorkspaceSessionKind.allCases.filter { target != .wandAgent || $0 == .structured }) { option in
                        let selected = sessionKind == option
                        Button {
                            sessionKind = option
                            store.rememberCreationChoice(kind: option)
                        } label: {
                            Text(option.title)
                                .font(.wand(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selected ? Theme.brand.opacity(0.12) : Theme.surface)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
    }

    /// 「创建后」二选一：直接启动首个会话，或只建分组（对齐 Android 的 WandChoiceStrip）。
    private var createModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("创建后")
                .font(.wand(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            HStack(spacing: 8) {
                modeChoice("启动会话", selected: startFirstSession) { startFirstSession = true }
                modeChoice("仅建分组", selected: !startFirstSession) { startFirstSession = false }
            }
            if startFirstSession, target != .shell {
                VStack(alignment: .leading, spacing: 6) {
                    Text("首个会话的提示词（可选）")
                        .font(.wand(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    TextField("希望 CLI 帮你完成什么？", text: $prompt, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.wand(size: 15))
                        .disabled(creating)
                    Text("任务名称留空时按此提示词自动命名，仍可随时改名。")
                        .font(.footnote)
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func modeChoice(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.wand(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Theme.brand.opacity(0.12) : Theme.surface.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
        .disabled(creating)
    }

    /// worktree 隔离默认关闭（服务端默认也不建目录），需要时才在高级里打开。
    @ViewBuilder
    private var advancedCard: some View {
        Button {
            showingAdvanced.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showingAdvanced ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                Text(showingAdvanced ? "收起高级选项" : "高级：独立工作树")
                    .font(.wand(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundColor(Theme.textSecondary)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(creating)
        if showingAdvanced {
            HStack(spacing: 8) {
                modeChoice("共用工作区", selected: !worktreeEnabled) { worktreeEnabled = false }
                modeChoice("隔离 worktree", selected: worktreeEnabled) { worktreeEnabled = true }
            }
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
        let requestedSubject = startFirstSession ? subject : nil
        let requestedPrompt = taskPrompt
        let requestedTarget = target; let requestedKind = sessionKind
        creating = true
        errorMessage = nil
        defer { creating = false }
        do {
            store.rememberCreationChoice(provider: target, kind: sessionKind)
            let (workspace, creation) = try await store.createTask(
                name: trimmedName,
                directory: trimmedDirectory,
                worktree: worktreeEnabled,
                workspaceId: selectedWorkspaceId,
                description: requestedPrompt
            )
            guard startFirstSession else {
                dismiss()
                onCreated(WorkspaceNewTaskResult(
                    workspace: workspace,
                    creation: creation,
                    session: nil,
                    sessionError: nil
                ))
                return
            }
            // Task existence, dispatch receipt, and navigation reads are separate facts.
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
                    // This read is navigation only; an accepted dispatch must never be repeated.
                    snapshot = try await api.getSession(id: result.sessionId)
                    await store.loadTaskGroups(force: true)
                } else {
                    snapshot = try await store.createFirstTaskWindow(taskId: creation.id, target: requestedTarget,
                        kind: requestedKind, prompt: requestedPrompt,
                        employeeID: requestedSubject?.type == "employee" ? requestedSubject?.id : nil)
                }
                dismiss()
                onCreated(WorkspaceNewTaskResult(
                    workspace: workspace,
                    creation: creation,
                    session: snapshot,
                    sessionError: nil
                ))
            } catch {
                if contactCreationNeedsReview(attempted: teamDispatchAttempted, accepted: acceptedTeamReceipt != nil, error: error) {
                    store.markUnconfirmedWindow(taskID: creation.id)
                }
                dismiss()
                onCreated(WorkspaceNewTaskResult(
                    workspace: workspace,
                    creation: creation,
                    session: nil,
                    sessionError: acceptedTeamReceipt != nil ? "团队已开始执行，群聊暂时未能加载，请从任务会话进入。" : store.unconfirmedWindowTasks.contains(creation.id) ? "任务已创建，启动结果未确认，请核对任务会话，勿重复派发。" : isDefiniteInputRejection(error) ? "任务已创建，但本次启动被拒绝：\(error.localizedDescription)" : "任务已创建，启动结果未确认，请核对任务会话，勿重复派发：\(error.localizedDescription)"
                ))
            }
        } catch {
            errorMessage = store.taskCreationUnconfirmed ? "任务创建结果未确认，请先刷新并核对任务列表，勿重复创建。" : error.localizedDescription
        }
    }
}

struct WorkspaceNewTaskResult {
    let workspace: Workspace
    let creation: WorkspaceTaskCreation
    /// 「启动会话」成功时的首个会话；「仅建分组」与启动失败时为 nil。
    let session: SessionSnapshot?
    /// 任务已创建但首个会话没起来时的原因。
    let sessionError: String?
}
