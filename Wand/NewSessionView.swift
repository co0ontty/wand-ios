import SwiftUI

/// 新建会话 —— 选项与区块顺序对齐 Web 端「新对话」弹窗（renderSessionModal）：
/// Provider（Claude / Codex / OpenCode）→ 会话类型（结构化 / PTY）→ 模式
/// （托管 / 全权限 / 自动编辑 / 标准 / 原生；各 Provider 只开放自身支持项）→ 工作目录
/// （最近路径 / 内置目录浏览器）；iOS 额外保留「首条消息」快捷输入。
/// 创建成功后回调给列表页直接进入会话。
struct NewSessionView: View {
    let api: WandAPI
    let onCreated: (SessionSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cwd = ""
    @State private var recentPaths: [RecentPath] = []
    @State private var provider = "claude"
    @State private var isStructured = true
    // 默认托管模式（Claude / OpenCode 全自动完成）；Codex 切换时 clamp 成全权限。
    @State private var mode = "managed"
    @State private var availableModels: [ModelInfo] = []
    @State private var codexModels: [ModelInfo] = []
    @State private var opencodeModels: [ModelInfo] = []
    @State private var qoderModels: [ModelInfo] = []
    @State private var serverDefaultModels = ProviderDefaultModels(claude: nil, codex: nil, opencode: nil, qoder: nil)
    @State private var selectedModel = ""
    /// Provider -> 用户在本页触碰过的模型。空字符串表示显式恢复
    /// Provider 默认；缺少 key 表示不改服务端现值。保留跨 Provider 待保存值，
    /// 避免快速切换时后一次 debounce 丢掉前一个 Provider 的模型选择。
    @State private var pendingModelDefaults: [String: String] = [:]
    @State private var thinkingEffort = "off"
    @State private var firstMessage = ""
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var showBrowser = false
    /// 选择变化的保存任务。新任务会取消并等待旧任务完全退出，再发最终完整状态，
    /// 避免快速切换时旧请求晚到、覆盖较新的默认值。
    @State private var defaultsSaveTask: Task<Void, Never>?
    @State private var didLoadDefaults = false
    @State private var didLoadModels = false
    @FocusState private var focusedField: InputField?

    private enum InputField: Hashable {
        case cwd
        case firstMessage
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
        case .grok: []
        case .qoder: qoderModels
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
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("Provider")
                        Picker("Provider", selection: $provider) {
                            Text("Claude").tag("claude")
                            Text("Codex").tag("codex")
                            Text("OpenCode").tag("opencode")
                            Text("Grok").tag("grok")
                            Text("Qoder").tag("qoder")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: provider) { _, newProvider in
                            mode = supportedMode(mode, provider: newProvider)
                            selectedModel = pendingModelDefaults[WandProvider.normalize(newProvider)] ?? ""
                            normalizeThinkingEffortIfNeeded()
                            scheduleDefaultsSave()
                        }

                        sectionHeader("会话类型")
                        Picker("会话类型", selection: $isStructured) {
                            Text("结构化").tag(true)
                            Text("PTY").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: isStructured) { _, _ in
                            scheduleDefaultsSave()
                        }
                        fieldHint(Self.sessionKindHint(provider: provider, structured: isStructured))

                        sectionHeader("模型与思考")
                        HStack(spacing: 10) {
                            optionMenuCard(
                                title: "模型",
                                value: selectedModelLabel,
                                icon: "cpu"
                            ) {
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

                        sectionHeader("工作目录")
                        cwdCard

                        sectionHeader("首条消息（可选）")
                        firstMessageCard

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

                // 创建栏作为 ZStack 底部兄弟视图浮在表单上，而非放进 safeAreaInset。
                // safeAreaInset 会把创建栏并入底部安全区参与系统键盘避让：键盘弹出时
                // 系统先把创建栏抬到键盘上方，再滚动表单保证输入框可见，两段叠加导致
                // 输入框过量上浮、底边与键盘顶端留出大空隙。改为浮层后创建栏不再参与
                // 避让，聚焦时直接隐藏，系统只按键盘高度把输入框滚到键盘上方一次。
                if focusedField == nil {
                    createBar
                }
            }
            .dismissKeyboardOnTap()
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
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
                DirectoryBrowserView(api: api, startPath: cwd) { picked in
                    cwd = picked
                    showBrowser = false
                }
            }
        }
        .navigationViewStyle(.stack)
        .wandKeyboardShortcuts(newSessionKeyboardShortcuts)
        .onChange(of: thinkingEffort) { _, _ in
            scheduleDefaultsSave()
        }
        .onChange(of: mode) { _, _ in
            scheduleDefaultsSave()
        }
        .task {
            let config = try? await api.serverConfig()
            // 服务端是跨客户端的新建偏好唯一真源；请求失败时保留页面初始默认。
            if let configuredProvider = config?.defaultProvider {
                provider = WandProvider(normalizing: configuredProvider).rawValue
            }
            if let defaultSessionKind = config?.defaultSessionKind {
                isStructured = defaultSessionKind != "pty"
            }
            mode = supportedMode(config?.defaultMode ?? mode, provider: provider)
            if let config {
                // defaultModelId 同时兼容 defaultModels 映射和三套旧版独立字段。
                serverDefaultModels = ProviderDefaultModels(
                    claude: config.defaultModelId(for: WandProvider.claude.rawValue),
                    codex: config.defaultModelId(for: WandProvider.codex.rawValue),
                    opencode: config.defaultModelId(for: WandProvider.opencode.rawValue),
                    qoder: config.defaultModelId(for: WandProvider.qoder.rawValue)
                )
            }
            selectedModel = ""
            thinkingEffort = config?.defaultThinkingEffort ?? thinkingEffort
            if let response = try? await api.models() {
                availableModels = response.models(for: WandProvider.claude.rawValue)
                codexModels = response.models(for: WandProvider.codex.rawValue)
                opencodeModels = response.models(for: WandProvider.opencode.rawValue)
                qoderModels = response.models(for: WandProvider.qoder.rawValue)
                didLoadModels = true
                serverDefaultModels = ProviderDefaultModels(
                    claude: response.defaultModelId(for: WandProvider.claude.rawValue),
                    codex: response.defaultModelId(for: WandProvider.codex.rawValue),
                    opencode: response.defaultModelId(for: WandProvider.opencode.rawValue),
                    qoder: response.defaultModelId(for: WandProvider.qoder.rawValue)
                )
                selectedModel = normalizedModel(selectedModel, provider: provider)
            }
            let normalizedThinkingEffort = normalizeThinkingEffortIfNeeded()
            // Provider / 类型 / 模式 / 模型偏好已完成 hydration；目录请求不应继续
            // 阻塞用户选择的即时保存。
            didLoadDefaults = true
            if normalizedThinkingEffort {
                scheduleDefaultsSave()
            }
            recentPaths = (try? await api.recentPaths()) ?? []
            if cwd.isEmpty {
                if let first = recentPaths.first {
                    cwd = first.path
                } else if let def = config?.defaultCwd {
                    cwd = def
                }
            }
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
        case .grok: models = []
        case .qoder: models = qoderModels
        case .claude: models = availableModels
        }
        guard !models.isEmpty else { return normalized }
        return models.contains(where: { $0.id == normalized }) ? normalized : ""
    }

    private func serverDefaultModel(for provider: String) -> String {
        switch WandProvider(normalizing: provider) {
        case .codex: serverDefaultModels.codex ?? ""
        case .opencode: serverDefaultModels.opencode ?? ""
        case .grok: ""
        case .qoder: serverDefaultModels.qoder ?? ""
        case .claude: serverDefaultModels.claude ?? ""
        }
    }

    private var selectedModelForRequest: String? {
        let normalized = normalizedModel(selectedModel, provider: provider)
        guard !normalized.isEmpty else { return nil }
        return providerModels.contains(where: { $0.id == normalized }) ? normalized : nil
    }

    private func selectModel(_ model: String) {
        selectedModel = model
        pendingModelDefaults[selectedProvider.rawValue] = model
        normalizeThinkingEffortIfNeeded()
        scheduleDefaultsSave()
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
        .background(cardBackground(selected: false))
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
            .background(cardBackground(selected: false))
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
                Text(creating ? "创建中…" : "创建会话")
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
        .background(Theme.background.opacity(0.96))
    }

    // MARK: - 提示文案（对齐 Web）

    /// 会话类型动态说明，文案对齐 Web getSessionKindHint。
    private static func sessionKindHint(provider: String, structured: Bool) -> String {
        if structured {
            switch WandProvider(normalizing: provider) {
            case .codex:
                return "Codex JSONL 结构化聊天界面，支持多轮对话和工具调用展示。"
            case .opencode:
                return "OpenCode JSON 结构化聊天界面，支持多轮对话和工具调用展示。"
            case .grok:
                return "Grok streaming-json 结构化聊天界面，支持多轮续聊与思考过程展示。"
            case .qoder:
                return "Qoder stream-json 结构化聊天界面，支持续聊、思考过程和工具调用展示。"
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
        !cwd.trimmingCharacters(in: .whitespaces).isEmpty && !creating
    }

    /// 保存的是当前完整选择，而不是单字段补丁。即使前一次请求已经开始，新任务也会先
    /// 取消并等待它结束；最后一次完整写入因此总是获胜。
    private func scheduleDefaultsSave() {
        guard didLoadDefaults, !creating else { return }
        let values = currentDefaults
        let previous = defaultsSaveTask
        previous?.cancel()
        defaultsSaveTask = Task {
            _ = await previous?.result
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                try await persistDefaults(values)
                commitPersistedDefaults(values)
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
        let provider: String
        let sessionKind: String
        let mode: String
        let modelUpdates: [String: String]
        let thinkingEffort: String
    }

    private var currentDefaults: DefaultsSnapshot {
        let normalizedProvider = selectedProvider.rawValue
        return DefaultsSnapshot(
            provider: normalizedProvider,
            sessionKind: isStructured ? "structured" : "pty",
            mode: supportedMode(mode, provider: normalizedProvider),
            modelUpdates: pendingModelDefaults,
            thinkingEffort: thinkingEffort
        )
    }

    private func persistDefaults(_ values: DefaultsSnapshot) async throws {
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
        var claude = serverDefaultModels.claude
        var codex = serverDefaultModels.codex
        var opencode = serverDefaultModels.opencode
        var qoder = serverDefaultModels.qoder
        for (provider, model) in values.modelUpdates {
            switch WandProvider(normalizing: provider) {
            case .claude: claude = model
            case .codex: codex = model
            case .opencode: opencode = model
            case .grok: break
            case .qoder: qoder = model
            }
            if pendingModelDefaults[provider] == model {
                pendingModelDefaults.removeValue(forKey: provider)
            }
        }
        serverDefaultModels = ProviderDefaultModels(
            claude: claude,
            codex: codex,
            opencode: opencode,
            qoder: qoder
        )
    }

    private func create() {
        guard canCreate else { return }
        creating = true
        errorMessage = nil
        let path = cwd.trimmingCharacters(in: .whitespaces)
        let prompt = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = currentDefaults
        let effectiveMode = defaults.mode
        let effectiveModel = selectedModelForRequest
        let pendingDefaultsSave = defaultsSaveTask
        pendingDefaultsSave?.cancel()
        Task {
            do {
                // 先等即时保存任务完全退出，再以点击创建时的完整快照兜底写一次。
                _ = await pendingDefaultsSave?.result
                try await persistDefaults(defaults)
                commitPersistedDefaults(defaults)
                let snapshot: SessionSnapshot
                if defaults.sessionKind == "structured" {
                    snapshot = try await api.createStructuredSession(
                        provider: defaults.provider,
                        cwd: path,
                        mode: effectiveMode,
                        model: effectiveModel,
                        thinkingEffort: defaults.thinkingEffort,
                        prompt: prompt.isEmpty ? nil : prompt
                    )
                } else {
                    snapshot = try await api.createPtySession(
                        provider: defaults.provider,
                        cwd: path,
                        mode: effectiveMode,
                        model: effectiveModel,
                        thinkingEffort: defaults.thinkingEffort,
                        initialInput: prompt.isEmpty ? nil : prompt
                    )
                }
                creating = false
                onCreated(snapshot)
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

    var body: some View {
        NavigationView {
            ZStack {
                Theme.background.ignoresSafeArea()
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
                }
            }
        }
        .navigationViewStyle(.stack)
        .wandKeyboardShortcuts(directoryBrowserKeyboardShortcuts)
        .task {
            currentPath = startPath.isEmpty ? "~" : startPath
            await load()
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
                Task { await load() }
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
                let parent = (currentPath as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != currentPath else { return }
                currentPath = parent
                Task { await load() }
            } label: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.brand)
            }
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
                    currentPath = item.path
                    Task { await load() }
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

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let listing = try await api.listDirectory(currentPath)
            items = listing.items
            // 服务端会把 ~ 之类输入解析为绝对路径；用首项的父路径回填展示。
            if currentPath == "~", let first = listing.items.first {
                currentPath = (first.path as NSString).deletingLastPathComponent
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
