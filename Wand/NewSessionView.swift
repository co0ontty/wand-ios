import SwiftUI

/// Serializes state-changing new-session work per endpoint. Cancellation may remove an
/// operation that is still waiting, but an HTTP mutation that already started is allowed to
/// finish before the next snapshot begins. This mirrors Android's per-endpoint workflow mutex
/// and prevents an older POST from committing after a newer selection.
@MainActor
final class NewSessionEndpointMutationQueue {
    static let shared = NewSessionEndpointMutationQueue()

    private var activeEndpoints: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func pendingOperationCount(endpointID: String) -> Int {
        waiters[endpointID]?.count ?? 0
    }

    func run<Value>(
        endpointID: String,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        await acquire(endpointID)
        if Task.isCancelled {
            release(endpointID)
            throw CancellationError()
        }

        // An unstructured task does not inherit later cancellation from the debounce owner.
        // Once its first request starts, the endpoint remains locked until the whole snapshot
        // (and, for create, the session creation) has completed.
        let operationTask = Task { @MainActor in
            try await operation()
        }
        let result = await operationTask.result
        release(endpointID)
        return try result.get()
    }

    private func acquire(_ endpointID: String) async {
        guard activeEndpoints.contains(endpointID) else {
            activeEndpoints.insert(endpointID)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[endpointID, default: []].append(continuation)
        }
    }

    private func release(_ endpointID: String) {
        guard var endpointWaiters = waiters[endpointID], !endpointWaiters.isEmpty else {
            waiters[endpointID] = nil
            activeEndpoints.remove(endpointID)
            return
        }
        let next = endpointWaiters.removeFirst()
        waiters[endpointID] = endpointWaiters.isEmpty ? nil : endpointWaiters
        next.resume()
    }
}

/// 新建会话 —— 选项与区块顺序对齐 Web 端「新对话」弹窗（renderSessionModal）：
/// Provider（Claude / Codex / OpenCode / Grok / Qoder / Pi）→ 会话类型
/// （结构化 / PTY / 空白终端）→ 模式
/// （托管 / 全权限 / 自动编辑 / 标准 / 原生；各 Provider 只开放自身支持项）→ 工作目录
/// （最近路径 / 内置目录浏览器）；iOS 额外保留「首条消息」快捷输入。
/// 创建成功后回调给列表页直接进入会话。
struct NewSessionView: View {
    let api: WandAPI
    let hostServerID: String
    let initialCwd: String?
    let onCreated: (SessionSnapshot, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var serverStore: ServerStore

    @State private var selectedServerID: String
    @State private var cwd: String
    @State private var recentPaths: [RecentPath] = []
    @State private var provider = "claude"
    @State private var sessionKind = SessionKind.structured
    // 默认托管模式（Claude / OpenCode 全自动完成）；Codex 切换时 clamp 成全权限。
    @State private var mode = "managed"
    @State private var availableModels: [ModelInfo] = []
    @State private var codexModels: [ModelInfo] = []
    @State private var opencodeModels: [ModelInfo] = []
    @State private var grokModels: [ModelInfo] = []
    @State private var qoderModels: [ModelInfo] = []
    @State private var piModels: [ModelInfo] = []
    @State private var serverDefaultModels = ProviderDefaultModels(
        claude: nil,
        codex: nil,
        opencode: nil,
        grok: nil,
        qoder: nil,
        pi: nil
    )
    @State private var selectedModel = ""
    /// 目录请求与用户选项可并发发生；代次避免旧响应覆盖较新的模型目录或选择。
    @State private var modelCatalogRevision = 0
    @State private var modelSelectionRevision = 0
    /// Provider -> 用户在本页触碰过的模型。空字符串表示显式恢复
    /// Provider 默认；缺少 key 表示不改服务端现值。保留跨 Provider 待保存值，
    /// 避免快速切换时后一次 debounce 丢掉前一个 Provider 的模型选择。
    @State private var pendingModelDefaults: [String: String] = [:]
    @State private var thinkingEffort = "off"
    @State private var firstMessage = ""
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var showBrowser = false
    /// 选择变化的 debounce 所有者；真正开始的 HTTP mutation 由 endpoint queue 接管，
    /// 不会随下一次选择的 debounce 取消。
    @State private var defaultsSaveTask: Task<Void, Never>?
    @State private var didLoadDefaults = false
    @State private var didLoadModels = false
    @State private var bootstrapState = BootstrapState.loading
    @State private var bootstrapGeneration = 0
    @FocusState private var focusedField: InputField?

    init(
        api: WandAPI,
        hostServerID: String,
        initialCwd: String? = nil,
        onCreated: @escaping (SessionSnapshot, String) -> Void
    ) {
        self.api = api
        self.hostServerID = hostServerID
        self.initialCwd = initialCwd
        self.onCreated = onCreated
        _selectedServerID = State(initialValue: hostServerID)
        _cwd = State(initialValue: initialCwd ?? "")
    }

    /// 单服务器调用点的兼容入口；新列表会显式传 hostServerID 以支持跨服务器创建。
    init(api: WandAPI, onCreated: @escaping (SessionSnapshot) -> Void) {
        let serverID = ServerProfiles.stableID(for: api.baseURL)
        self.init(api: api, hostServerID: serverID) { snapshot, _ in
            onCreated(snapshot)
        }
    }

    private var targetProfile: ServerProfile? {
        serverStore.profile(id: selectedServerID)
    }

    private var targetAPI: WandAPI {
        guard let targetProfile else { return api }
        return WandAPI(baseURL: targetProfile.baseURL, token: targetProfile.token)
    }

    private enum InputField: Hashable {
        case cwd
        case firstMessage
    }

    private enum SessionKind: String, CaseIterable, Identifiable {
        case structured
        case pty
        case shell

        var id: String { rawValue }
        var title: String {
            switch self {
            case .structured: return "结构化"
            case .pty: return "PTY"
            case .shell: return "空白终端"
            }
        }

        /// 服务端偏好只持久化 AI 会话类型；空白终端不覆盖用户原本的默认类型。
        var preferenceValue: String? {
            self == .shell ? nil : rawValue
        }
    }

    private enum BootstrapState {
        case loading
        case ready
        case failed(String)
    }

    /// 模式选项：id / 标签 / 卡片内一句话说明，与 Web renderModeCards 完全一致。
    private struct SessionMode: Identifiable {
        let id: String
        let label: String
        let desc: String
    }

    private static let sessionModes: [SessionMode] = [
        SessionMode(id: "managed", label: "托管", desc: "全自动完成任务"),
        SessionMode(id: "full-access", label: "全权限", desc: "自动确认权限"),
        SessionMode(id: "auto-edit", label: "自动编辑", desc: "自动确认修改"),
        SessionMode(id: "default", label: "标准", desc: "逐步确认操作"),
        SessionMode(id: "native", label: "原生", desc: "原生结构化输出"),
    ]

    private var selectedProvider: WandProvider {
        WandProvider(normalizing: provider)
    }

    private var providerModels: [ModelInfo] {
        switch selectedProvider {
        case .codex: codexModels
        case .opencode: opencodeModels
        case .grok: grokModels
        case .qoder: qoderModels
        case .pi: piModels
        case .claude: availableModels
        }
    }

    private var thinkingLevels: [ThinkingEffortOption] {
        thinkingEffortOptions(
            provider: provider,
            selectedModel: selectedModel,
            defaultModel: serverDefaultModel(for: provider),
            models: providerModels
        )
    }

    /// Provider 能力来自统一协议模型，避免页面内继续散落二元判断。
    private var supportedModes: Set<String> {
        selectedProvider.supportedModeIDs
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                WandAmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if serverStore.profiles.count > 1 {
                            sectionHeader("服务器")
                            Picker("服务器", selection: $selectedServerID) {
                                ForEach(serverStore.profiles) { profile in
                                    Text(profile.displayName).tag(profile.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .wandInputSurface(focused: false)
                            .onChange(of: selectedServerID) { _, newServerID in
                                defaultsSaveTask?.cancel()
                                defaultsSaveTask = nil
                                pendingModelDefaults.removeAll()
                                cwd = newServerID == hostServerID ? (initialCwd ?? "") : ""
                                Task { await bootstrap() }
                            }
                            fieldHint("配置、目录和会话都会从所选服务器读取，认证信息彼此隔离。")
                        }

                        sectionHeader("会话类型")
                        Picker("会话类型", selection: $sessionKind) {
                            ForEach(SessionKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: sessionKind) { _, newKind in
                            if newKind.preferenceValue != nil {
                                scheduleDefaultsSave()
                            }
                        }
                        fieldHint(Self.sessionKindHint(provider: provider, kind: sessionKind))

                        if sessionKind != .shell {
                            sectionHeader("Provider")
                            Picker("Provider", selection: $provider) {
                                Text("Claude").tag("claude")
                                Text("Codex").tag("codex")
                                Text("OpenCode").tag("opencode")
                                Text("Grok").tag("grok")
                                Text("Qoder").tag("qoder")
                                Text("Pi").tag("pi")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: provider) { _, newProvider in
                                modelSelectionRevision &+= 1
                                mode = supportedMode(mode, provider: newProvider)
                                selectedModel = pendingModelDefaults[WandProvider.normalize(newProvider)] ?? ""
                                normalizeThinkingEffortIfNeeded()
                                scheduleDefaultsSave()
                            }

                            sectionHeader("模型与思考")
                            HStack(spacing: 10) {
                                optionMenuCard(
                                    title: "模型",
                                    value: selectedModelLabel,
                                    icon: "cpu"
                                ) {
                                    Section("模型") {
                                        Button {
                                            selectModel("")
                                        } label: {
                                            selectedModel.isEmpty
                                                ? Label("默认 · \(defaultModelLabel)", systemImage: "checkmark")
                                                : Label("默认 · \(defaultModelLabel)", systemImage: "circle")
                                        }
                                        ForEach(providerModels.filter { $0.id != "default" }) { model in
                                            Button {
                                                selectModel(model.id)
                                            } label: {
                                                selectedModel == model.id
                                                    ? Label(model.label, systemImage: "checkmark")
                                                    : Label(model.label, systemImage: "circle")
                                            }
                                        }
                                    }
                                }
                                optionMenuCard(
                                    title: "思考深度",
                                    value: thinkingLabel,
                                    icon: "brain"
                                ) {
                                    ForEach(thinkingLevels) { level in
                                        Button {
                                            thinkingEffort = level.id
                                        } label: {
                                            effectiveThinkingOption?.id == level.id
                                                ? Label(level.menuLabel, systemImage: "checkmark")
                                                : Label(level.menuLabel, systemImage: "circle")
                                        }
                                    }
                                }
                            }
                            sectionHeader("模式")
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(Self.sessionModes) { option in
                                    modeCard(option)
                                }
                            }
                            fieldHint(Self.modeHint(provider: provider, mode: mode))
                        }

                        sectionHeader("工作目录")
                        cwdCard

                        if sessionKind == .shell {
                            fieldHint("创建后会直接进入可输入命令的空白终端，不启动任何 AI CLI。")
                        } else {
                            sectionHeader("首条消息（可选）")
                            firstMessageCard
                        }

                        if let errorMessage {
                            errorBanner(errorMessage)
                        }

                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 16)
                    // 创建栏改为浮层后不再占布局，这里补足其高度，确保表单尾部内容
                    // 能滚动到浮层上方、不被遮住。
                    .padding(.bottom, focusedField == nil ? 68 : 0)
                }
                .scrollDismissesKeyboard(.interactively)
                .allowsHitTesting(bootstrapReady && !creating)
                .opacity(bootstrapReady ? 1 : 0)

                if !bootstrapReady {
                    bootstrapStatusView
                }

                // 创建栏作为 ZStack 底部兄弟视图浮在表单上，而非放进 safeAreaInset。
                // safeAreaInset 会把创建栏并入底部安全区参与系统键盘避让：键盘弹出时
                // 系统先把创建栏抬到键盘上方，再滚动表单保证输入框可见，两段叠加导致
                // 输入框过量上浮、底边与键盘顶端留出大空隙。改为浮层后创建栏不再参与
                // 避让，聚焦时直接隐藏，系统只按键盘高度把输入框滚到键盘上方一次。
                if focusedField == nil && bootstrapReady {
                    createBar
                }
            }
            .dismissKeyboardOnTap()
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(creating ? "创建中…" : "取消") {
                        guard !creating else { return }
                        dismiss()
                    }
                    .foregroundColor(creating ? Theme.textSecondary.opacity(0.5) : Theme.textSecondary)
                    .disabled(creating)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if creating {
                        ProgressView()
                    } else {
                        Button("创建") { create() }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(canCreate ? Theme.brand : Theme.textSecondary)
                            .disabled(!canCreate)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .sheet(isPresented: $showBrowser) {
                DirectoryBrowserView(api: targetAPI, startPath: cwd) { picked in
                    cwd = picked
                    showBrowser = false
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(creating)
        .wandKeyboardShortcuts(newSessionKeyboardShortcuts)
        .onChange(of: thinkingEffort) { _, _ in
            scheduleDefaultsSave()
        }
        .onChange(of: mode) { _, _ in
            scheduleDefaultsSave()
        }
        .task {
            await bootstrap()
        }
        .onDisappear {
            bootstrapGeneration &+= 1
            defaultsSaveTask?.cancel()
            defaultsSaveTask = nil
        }
    }

    private var bootstrapReady: Bool {
        if case .ready = bootstrapState { return true }
        return false
    }

    @ViewBuilder
    private var bootstrapStatusView: some View {
        VStack(spacing: 14) {
            Spacer()
            switch bootstrapState {
            case .loading:
                ProgressView()
                    .tint(Theme.brand)
                Text("正在读取服务器配置…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            case .failed(let message):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(Theme.danger)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await bootstrap() }
                } label: {
                    Label("重试连接", systemImage: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.brand)
                )
            case .ready:
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `/api/config` 是本页所有默认值和创建请求的根。它失败时保留明确错误状态，
    /// 不能用一套本地猜测值继续创建；模型目录和最近路径则按服务端一致行为独立容错。
    private func bootstrap() async {
        defaultsSaveTask?.cancel()
        defaultsSaveTask = nil
        pendingModelDefaults.removeAll()
        bootstrapGeneration &+= 1
        let generation = bootstrapGeneration
        bootstrapState = .loading
        didLoadDefaults = false
        didLoadModels = false
        errorMessage = nil
        availableModels = []
        codexModels = []
        opencodeModels = []
        grokModels = []
        qoderModels = []
        piModels = []
        recentPaths = []

        do {
            let api = targetAPI
            let config = try await NewSessionEndpointMutationQueue.shared.run(
                endpointID: selectedServerID
            ) {
                try await api.serverConfig()
            }
            guard !Task.isCancelled, generation == bootstrapGeneration else { return }

            provider = WandProvider(normalizing: config.defaultProvider).rawValue
            sessionKind = config.defaultSessionKind == SessionKind.pty.rawValue ? .pty : .structured
            mode = supportedMode(config.resolvedDefaultMode, provider: provider)
            serverDefaultModels = ProviderDefaultModels(
                claude: config.defaultModelId(for: WandProvider.claude.rawValue),
                codex: config.defaultModelId(for: WandProvider.codex.rawValue),
                opencode: config.defaultModelId(for: WandProvider.opencode.rawValue),
                grok: config.defaultModelId(for: WandProvider.grok.rawValue),
                qoder: config.defaultModelId(for: WandProvider.qoder.rawValue),
                pi: config.defaultModelId(for: WandProvider.pi.rawValue)
            )
            selectedModel = ""
            thinkingEffort = config.resolvedDefaultThinkingEffort

            let initialModelSelectionRevision = modelSelectionRevision
            await loadModelCatalog(using: api)
            guard !Task.isCancelled, generation == bootstrapGeneration else { return }
            let normalizedThinkingEffort = initialModelSelectionRevision == modelSelectionRevision
                ? normalizeThinkingEffortIfNeeded()
                : false

            recentPaths = (try? await api.recentPaths()) ?? []
            guard !Task.isCancelled, generation == bootstrapGeneration else { return }
            if cwd.isEmpty {
                if let first = recentPaths.first {
                    cwd = first.path
                } else if let defaultCwd = config.defaultCwd {
                    cwd = defaultCwd
                }
            }

            // Provider / 类型 / 模式 / 模型偏好已完成 hydration；从这里开始才允许
            // 即时保存与创建，避免失败的配置请求产生半套默认值。
            didLoadDefaults = true
            bootstrapState = .ready
            if normalizedThinkingEffort {
                scheduleDefaultsSave()
            }
        } catch {
            guard !Task.isCancelled, generation == bootstrapGeneration else { return }
            bootstrapState = .failed("无法读取服务器配置：\(error.localizedDescription)")
        }
    }

    private var newSessionKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "create-session",
                title: "创建会话",
                key: .return,
                modifiers: .command,
                isEnabled: canCreate
            ) {
                create()
            },
            WandKeyboardShortcutAction(
                id: "browse-directory",
                title: "浏览目录",
                key: "o",
                modifiers: .command,
                isEnabled: !creating
            ) {
                focusedField = nil
                showBrowser = true
            },
            WandKeyboardShortcutAction(
                id: "dismiss",
                title: "取消",
                key: .escape,
                modifiers: [],
                isEnabled: !creating
            ) {
                dismiss()
            },
        ]
    }

    private var selectedModelLabel: String {
        guard !selectedModel.isEmpty, selectedModel != "default" else { return defaultModelLabel }
        return providerModels.first(where: { $0.id == selectedModel })?.label ?? "默认"
    }

    private var defaultModelLabel: String {
        let id = serverDefaultModel(for: provider)
        if !id.isEmpty {
            return providerModels.first(where: { $0.id == id })?.label ?? id
        }
        return providerModels.first(where: { $0.id == "default" })?.label ?? "默认"
    }

    private var effectiveThinkingOption: ThinkingEffortOption? {
        thinkingLevels.first { $0.id == thinkingEffort } ?? thinkingLevels.first
    }

    private var thinkingLabel: String {
        effectiveThinkingOption?.label ?? "自动"
    }

    // MARK: - 区块组件

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
            .padding(.top, 16)
            .padding(.bottom, 7)
    }

    /// 区块下方的说明文案，对应 Web 的 .field-hint。
    private func fieldHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(3)
            .foregroundColor(Theme.textSecondary.opacity(0.85))
            .padding(.top, 6)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 选择卡通用底：surface 底 + border 描边，选中切 brand 软底 + brand 1.5pt 描边。
    private func cardBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(selected ? Theme.brand.opacity(0.10) : Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Theme.brand : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
    }

    private func optionMenuCard<Content: View>(
        title: String,
        value: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.brand.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(cardBackground(selected: false))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("轻点选择\(title)")
    }

    private func supportedMode(_ value: String, provider: String) -> String {
        WandProvider(normalizing: provider).clamp(mode: value)
    }

    private func normalizedModel(_ value: String, provider: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != "default" else { return "" }
        let models: [ModelInfo]
        switch WandProvider(normalizing: provider) {
        case .codex: models = codexModels
        case .opencode: models = opencodeModels
        case .grok: models = grokModels
        case .qoder: models = qoderModels
        case .pi: models = piModels
        case .claude: models = availableModels
        }
        guard !models.isEmpty else { return normalized }
        return models.contains(where: { $0.id == normalized }) ? normalized : ""
    }

    private func serverDefaultModel(for provider: String) -> String {
        switch WandProvider(normalizing: provider) {
        case .codex: serverDefaultModels.codex ?? ""
        case .opencode: serverDefaultModels.opencode ?? ""
        case .grok: serverDefaultModels.grok ?? ""
        case .qoder: serverDefaultModels.qoder ?? ""
        case .pi: serverDefaultModels.pi ?? ""
        case .claude: serverDefaultModels.claude ?? ""
        }
    }

    private var selectedModelForRequest: String? {
        let normalized = normalizedModel(selectedModel, provider: provider)
        guard !normalized.isEmpty else { return nil }
        return providerModels.contains(where: { $0.id == normalized }) ? normalized : nil
    }

    private func selectModel(_ model: String) {
        modelSelectionRevision &+= 1
        selectedModel = model
        pendingModelDefaults[selectedProvider.rawValue] = model
        normalizeThinkingEffortIfNeeded()
        scheduleDefaultsSave()
    }

    /// 读取服务端当前持久化目录。CLI 探测由服务端的自动或管理员刷新完成。
    private func loadModelCatalog(using api: WandAPI) async {
        modelCatalogRevision &+= 1
        let catalogRevision = modelCatalogRevision
        let selectionRevision = modelSelectionRevision

        let response: ModelsResponse
        do {
            response = try await api.models()
        } catch {
            guard !Task.isCancelled, catalogRevision == modelCatalogRevision else { return }
            return
        }
        guard !Task.isCancelled, catalogRevision == modelCatalogRevision else { return }

        availableModels = response.models(for: WandProvider.claude.rawValue)
        codexModels = response.models(for: WandProvider.codex.rawValue)
        opencodeModels = response.models(for: WandProvider.opencode.rawValue)
        grokModels = response.models(for: WandProvider.grok.rawValue)
        qoderModels = response.models(for: WandProvider.qoder.rawValue)
        piModels = response.models(for: WandProvider.pi.rawValue)
        serverDefaultModels = ProviderDefaultModels(
            claude: response.defaultModelId(for: WandProvider.claude.rawValue),
            codex: response.defaultModelId(for: WandProvider.codex.rawValue),
            opencode: response.defaultModelId(for: WandProvider.opencode.rawValue),
            grok: response.defaultModelId(for: WandProvider.grok.rawValue),
            qoder: response.defaultModelId(for: WandProvider.qoder.rawValue),
            pi: response.defaultModelId(for: WandProvider.pi.rawValue)
        )
        didLoadModels = true

        // 用户请求在飞行中换了 provider 或模型时，目录可以更新，但绝不能替他重置选择。
        if selectionRevision == modelSelectionRevision {
            selectedModel = normalizedModel(selectedModel, provider: provider)
            _ = normalizeThinkingEffortIfNeeded()
        }
    }

    /// 模型/Provider 改变后，旧档位可能不在新的能力列表里。此时真实选择必须
    /// 收敛为协议的 off（自动），不能只让标签看起来回落到第一个选项。
    @discardableResult
    private func normalizeThinkingEffortIfNeeded() -> Bool {
        // Codex 动态档位必须等模型目录成功返回，否则 legacy 回退会误伤有效值。
        if selectedProvider == .codex && !didLoadModels { return false }
        guard !thinkingLevels.contains(where: { $0.id == thinkingEffort }) else { return false }
        thinkingEffort = "off"
        return true
    }

    /// 模式卡（两列网格单元，标签 + 一句话说明），不支持的模式降透明度且不可点。
    private func modeCard(_ option: SessionMode) -> some View {
        let selected = mode == option.id
        let enabled = supportedModes.contains(option.id)
        return Button {
            mode = option.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                    .lineLimit(1)
                Text(option.desc)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(cardBackground(selected: selected))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// 工作目录卡：路径输入 + 右侧浏览按钮 + 最近路径快速选择。
    private var cwdCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                TextField("/path/to/project", text: $cwd)
                    .font(.system(size: 14, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .cwd)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .firstMessage }
                    .padding(.leading, 12)
                    .padding(.vertical, 11)

                Button {
                    showBrowser = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Theme.brand)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("浏览目录")
            }
            if !recentPaths.isEmpty {
                Divider().background(Theme.border)
                ForEach(recentPaths.prefix(5)) { recent in
                    Button {
                        cwd = recent.path
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.system(size: 12))
                                .foregroundColor(cwd == recent.path ? Theme.brand : Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(recent.displayName)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(cwd == recent.path ? Theme.brand : Theme.textPrimary)
                                Text(recent.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if cwd == recent.path {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.brand)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .wandInputSurface(focused: focusedField == .cwd)
    }

    /// 首条消息输入卡。
    private var firstMessageCard: some View {
        TextField("想让它做什么…", text: $firstMessage)
            .font(.system(size: 15))
            .focused($focusedField, equals: .firstMessage)
            .submitLabel(.send)
            .onSubmit { create() }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .foregroundColor(Theme.textPrimary)
            .tint(Theme.brand)
            .wandInputSurface(focused: focusedField == .firstMessage)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(Theme.danger)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.danger.opacity(0.10))
        )
        .padding(.top, 16)
    }

    /// 底部通栏创建按钮，对齐 Android 端布局。
    private var createBar: some View {
        Button {
            create()
        } label: {
            HStack(spacing: 8) {
                if creating {
                    ProgressView().tint(.white)
                }
                Text(creating ? "创建中…" : sessionKind == .shell ? "创建空白终端" : "创建会话")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(canCreate ? Theme.brand : Theme.brand.opacity(0.4))
            )
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .wandGlassSurface()
    }

    // MARK: - 提示文案（对齐 Web）

    /// 会话类型动态说明，文案对齐 Web getSessionKindHint。
    private static func sessionKindHint(provider: String, kind: SessionKind) -> String {
        if kind == .shell {
            return "启动当前工作目录下的交互式登录 Shell，不自动运行任何 CLI 工具。"
        }
        if kind == .structured {
            switch WandProvider(normalizing: provider) {
            case .codex:
                return "Codex JSONL 结构化聊天界面，支持多轮对话和工具调用展示。"
            case .opencode:
                return "OpenCode JSON 结构化聊天界面，支持多轮对话和工具调用展示。"
            case .grok:
                return "Grok streaming-json 结构化聊天界面，支持多轮续聊与思考过程展示。"
            case .qoder:
                return "Qoder stream-json 结构化聊天界面，支持续聊、思考过程和工具调用展示。"
            case .pi:
                return "Pi JSON 结构化聊天界面，支持续聊、思考过程和工具调用展示。"
            case .claude:
                return "结构化聊天界面，支持多轮对话、流式输出和工具调用展示。"
            }
        }
        switch WandProvider(normalizing: provider) {
        case .codex:
            return "Codex PTY 终端会话；terminal 是原始输出，chat 是解析后的阅读视图。"
        case .opencode:
            return "OpenCode TUI 终端会话，支持持续交互和终端视图。"
        case .grok:
            return "Grok Build TUI 的原始 PTY 终端会话。"
        case .qoder:
            return "Qoder CLI TUI 的原始 PTY 终端会话。"
        case .pi:
            return "Pi TUI 的原始 PTY 终端会话。"
        case .claude:
            return "原始 PTY 终端会话，支持持续交互、终端视图和权限流。"
        }
    }

    /// 模式动态说明，文案对齐 Web getToolModeHint。
    private static func modeHint(provider: String, mode: String) -> String {
        switch WandProvider(normalizing: provider) {
        case .codex:
            return "Codex 支持 PTY 终端与结构化（JSONL）两种会话，结构化模式按 full-access 启动。"
        case .opencode:
            if mode == "full-access" || mode == "managed" {
                return "OpenCode 将自动批准未显式拒绝的权限；支持 TUI 与 JSON 结构化会话。"
            }
            return "OpenCode 使用自身权限配置；结构化模式会自动拒绝未批准的权限请求。"
        case .grok:
            if mode == "full-access" || mode == "managed" {
                return "Grok 将以 always-approve 运行；支持 TUI 与 streaming-json 结构化会话。"
            }
            return "Grok 使用自身权限确认；支持 TUI 与 streaming-json 结构化会话。"
        case .qoder:
            if mode == "full-access" || mode == "managed" {
                return "Qoder 将以 bypass_permissions 运行；支持 TUI 与 stream-json 结构化会话。"
            }
            if mode == "auto-edit" { return "Qoder 将自动批准工作区内的安全编辑。" }
            return "Qoder 使用自身权限确认；结构化模式下未批准的操作会被拒绝。"
        case .pi:
            if mode == "full-access" || mode == "managed" {
                return "Pi 将自动批准工具调用；支持 TUI 与 JSON 结构化会话。"
            }
            return "Pi 使用自身权限确认；支持 TUI 与 JSON 结构化会话。"
        case .claude:
            break
        }
        switch mode {
        case "full-access": return "自动确认权限请求与高权限操作，适合你确认环境安全后的连续修改。"
        case "auto-edit": return "保留交互式会话，同时更偏向直接编辑代码。"
        case "native": return "调用 Claude 原生 API 输出，适合快速问答或一次性生成。"
        case "managed": return "AI 自动完成所有工作，无需中途确认，适合有明确目标的任务。"
        default: return "保留标准交互流程，适合手动确认每一步。"
        }
    }

    // MARK: - 创建

    private var canCreate: Bool {
        bootstrapReady && !cwd.trimmingCharacters(in: .whitespaces).isEmpty && !creating
    }

    /// 保存当前完整选择而不是单字段补丁。快速输入只取消尚未入队的 debounce；已开始
    /// 的 HTTP 写入会完成，后续快照再按 endpoint FIFO 执行，保证最终选择最后提交。
    private func scheduleDefaultsSave() {
        guard didLoadDefaults, !creating, sessionKind != .shell else { return }
        let values = currentDefaults
        let api = targetAPI
        defaultsSaveTask?.cancel()
        defaultsSaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                try await NewSessionEndpointMutationQueue.shared.run(endpointID: values.serverID) {
                    try await persistDefaults(values, using: api)
                }
                try Task.checkCancellation()
                if selectedServerID == values.serverID {
                    commitPersistedDefaults(values)
                }
            } catch is CancellationError {
                // 快速连续选择时的正常合并路径。
            } catch {
                // WandAPI 会把 URLSession 的取消包装成 network error；任务本身的取消
                // 仍可辨认，不能把正常 debounce 当成失败提示给用户。
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private struct DefaultsSnapshot {
        let serverID: String
        let provider: String
        let sessionKind: String?
        let mode: String
        let modelUpdates: [String: String]
        let thinkingEffort: String
    }

    private var currentDefaults: DefaultsSnapshot {
        let normalizedProvider = selectedProvider.rawValue
        return DefaultsSnapshot(
            serverID: selectedServerID,
            provider: normalizedProvider,
            sessionKind: sessionKind.preferenceValue,
            mode: supportedMode(mode, provider: normalizedProvider),
            modelUpdates: pendingModelDefaults,
            thinkingEffort: thinkingEffort
        )
    }

    private func persistDefaults(_ values: DefaultsSnapshot, using api: WandAPI) async throws {
        // 通用默认项一次写入；模型按 Provider 单独写，使 defaultModels 的
        // 部分更新语义与 Android/Web 保持一致。
        try await api.updateNewSessionDefaults(
            mode: values.mode,
            model: nil,
            provider: values.provider,
            thinkingEffort: values.thinkingEffort,
            defaultProvider: values.provider,
            defaultSessionKind: values.sessionKind
        )
        for provider in values.modelUpdates.keys.sorted() {
            try Task.checkCancellation()
            guard let model = values.modelUpdates[provider] else { continue }
            // 空字符串会明确下发，表示恢复该 Provider 默认模型。
            try await api.updateNewSessionDefaults(model: model, provider: provider)
        }
    }

    /// 只清理与该次快照仍一致的 pending 值；若请求期间用户又选了
    /// 新模型，新值会继续留待下一次保存。同步本地默认供切回 Provider 时立即显示。
    private func commitPersistedDefaults(_ values: DefaultsSnapshot) {
        guard selectedServerID == values.serverID else { return }
        var claude = serverDefaultModels.claude
        var codex = serverDefaultModels.codex
        var opencode = serverDefaultModels.opencode
        var grok = serverDefaultModels.grok
        var qoder = serverDefaultModels.qoder
        var pi = serverDefaultModels.pi
        for (provider, model) in values.modelUpdates {
            switch WandProvider(normalizing: provider) {
            case .claude: claude = model
            case .codex: codex = model
            case .opencode: opencode = model
            case .grok: grok = model
            case .qoder: qoder = model
            case .pi: pi = model
            }
            if pendingModelDefaults[provider] == model {
                pendingModelDefaults.removeValue(forKey: provider)
            }
        }
        serverDefaultModels = ProviderDefaultModels(
            claude: claude,
            codex: codex,
            opencode: opencode,
            grok: grok,
            qoder: qoder,
            pi: pi
        )
    }

    private func create() {
        guard canCreate else { return }
        creating = true
        errorMessage = nil
        let path = cwd.trimmingCharacters(in: .whitespaces)
        let prompt = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = sessionKind
        let defaults = currentDefaults
        let effectiveMode = defaults.mode
        let effectiveModel = selectedModelForRequest
        let targetServerID = selectedServerID
        let api = targetAPI
        defaultsSaveTask?.cancel()
        defaultsSaveTask = nil
        Task {
            do {
                let snapshot = try await NewSessionEndpointMutationQueue.shared.run(
                    endpointID: targetServerID
                ) {
                    switch kind {
                    case .shell:
                        return try await api.createShellSession(cwd: path)
                    case .structured:
                        try await persistDefaults(defaults, using: api)
                        return try await api.createStructuredSession(
                            provider: defaults.provider,
                            cwd: path,
                            mode: effectiveMode,
                            model: effectiveModel,
                            thinkingEffort: defaults.thinkingEffort,
                            prompt: prompt.isEmpty ? nil : prompt
                        )
                    case .pty:
                        try await persistDefaults(defaults, using: api)
                        return try await api.createPtySession(
                            provider: defaults.provider,
                            cwd: path,
                            mode: effectiveMode,
                            model: effectiveModel,
                            thinkingEffort: defaults.thinkingEffort,
                            initialInput: prompt.isEmpty ? nil : prompt
                        )
                    }
                }
                if kind != .shell { commitPersistedDefaults(defaults) }
                creating = false
                onCreated(snapshot, targetServerID)
            } catch {
                creating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 目录浏览器

/// 极简目录浏览器：基于 /api/directory 逐层进入，选中当前目录。
struct DirectoryBrowserView: View {
    let api: WandAPI
    let startPath: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = "~"
    @State private var items: [DirectoryItem] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var requestGeneration = 0

    var body: some View {
        NavigationView {
            ZStack {
                WandAmbientBackground()
                VStack(spacing: 0) {
                    pathHeader
                    Divider()
                    if loading {
                        Spacer()
                        ProgressView().tint(Theme.brand)
                        Spacer()
                    } else if let errorMessage {
                        Spacer()
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(Theme.danger)
                            .padding()
                        Spacer()
                    } else {
                        directoryList
                    }
                }
            }
            .navigationTitle("选择目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("选择此目录") { onPick(currentPath) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.brand)
                        .disabled(loading)
                }
            }
        }
        .navigationViewStyle(.stack)
        .wandKeyboardShortcuts(directoryBrowserKeyboardShortcuts)
        .task {
            currentPath = startPath.isEmpty ? "~" : startPath
            await load(path: currentPath)
        }
    }

    private var directoryBrowserKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "choose-directory",
                title: "选择此目录",
                key: .return,
                modifiers: .command,
                isEnabled: !loading
            ) {
                onPick(currentPath)
            },
            WandKeyboardShortcutAction(
                id: "refresh-directory",
                title: "刷新目录",
                key: "r",
                modifiers: .command,
                isEnabled: !loading
            ) {
                let path = currentPath
                Task { await load(path: path) }
            },
            WandKeyboardShortcutAction(
                id: "dismiss-directory-browser",
                title: "取消",
                key: .escape,
                modifiers: []
            ) {
                dismiss()
            },
        ]
    }

    private var pathHeader: some View {
        HStack(spacing: 8) {
            Button {
                guard !loading else { return }
                let parent = (currentPath as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != currentPath else { return }
                navigate(to: parent)
            } label: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.brand)
            }
            .disabled(loading)
            Text(currentPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var directoryList: some View {
        List {
            ForEach(items.filter { $0.isDirectory }) { item in
                Button {
                    navigate(to: item.path)
                } label: {
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.brand.opacity(0.8))
                        Text(item.name)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
    }

    private func navigate(to path: String) {
        currentPath = path
        Task { await load(path: path) }
    }

    private func load(path requestedPath: String) async {
        requestGeneration &+= 1
        let generation = requestGeneration
        loading = true
        errorMessage = nil
        do {
            let listing = try await api.listDirectory(requestedPath)
            guard generation == requestGeneration, currentPath == requestedPath else { return }
            items = listing.items
            // 服务端会把 ~ 之类输入解析为绝对路径；用首项的父路径回填展示。
            if requestedPath == "~", let first = listing.items.first {
                currentPath = (first.path as NSString).deletingLastPathComponent
            }
        } catch {
            guard generation == requestGeneration, currentPath == requestedPath else { return }
            errorMessage = error.localizedDescription
        }
        if generation == requestGeneration { loading = false }
    }
}
