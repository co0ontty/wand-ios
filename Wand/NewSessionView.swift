import SwiftUI

/// 新建会话 —— 选项与区块顺序对齐 Web 端「新对话」弹窗（renderSessionModal）：
/// Provider（Claude / Codex，品牌 logo 卡）→ 会话类型（结构化 / PTY）→ 模式
/// （托管 / 全权限 / 自动编辑 / 标准 / 原生，codex 锁定全权限）→ 工作目录
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
    // 默认托管模式（claude 全自动完成）；codex 切换时 clamp 成全权限。
    @State private var mode = "managed"
    @State private var availableModels: [ModelInfo] = []
    @State private var codexModels: [ModelInfo] = []
    @State private var selectedModel = ""
    @State private var thinkingEffort = "off"
    @State private var firstMessage = ""
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var showBrowser = false
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

    private static let thinkingLevels = [
        (id: "off", label: "关闭"),
        (id: "standard", label: "标准"),
        (id: "deep", label: "深入"),
        (id: "max", label: "最大"),
    ]

    private var providerModels: [ModelInfo] {
        provider == "codex" ? codexModels : availableModels
    }

    /// codex 仅支持 full-access，对齐 Web getSupportedModes。
    private var supportedModes: Set<String> {
        provider == "codex" ? ["full-access"] : Set(Self.sessionModes.map { $0.id })
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
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: provider) { _, newProvider in
                            mode = supportedMode(mode, provider: newProvider)
                        }

                        sectionHeader("会话类型")
                        Picker("会话类型", selection: $isStructured) {
                            Text("结构化").tag(true)
                            Text("PTY").tag(false)
                        }
                        .pickerStyle(.segmented)
                        fieldHint(Self.sessionKindHint(provider: provider, structured: isStructured))

                        sectionHeader("模型与思考")
                        HStack(spacing: 10) {
                            optionMenuCard(
                                title: "模型",
                                value: selectedModelLabel,
                                icon: "cpu"
                            ) {
                                Button {
                                    selectedModel = ""
                                    saveDefaults(model: "")
                                } label: {
                                    selectedModel.isEmpty
                                        ? Label("默认", systemImage: "checkmark")
                                        : Label("默认", systemImage: "circle")
                                }
                                ForEach(providerModels.filter { $0.id != "default" }) { model in
                                    Button {
                                        selectedModel = model.id
                                        saveDefaults(model: model.id)
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
                                ForEach(Self.thinkingLevels, id: \.id) { level in
                                    Button {
                                        thinkingEffort = level.id
                                        saveDefaults(thinkingEffort: level.id)
                                    } label: {
                                        thinkingEffort == level.id
                                            ? Label(level.label, systemImage: "checkmark")
                                            : Label(level.label, systemImage: "circle")
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
        .task {
            let config = try? await api.serverConfig()
            mode = supportedMode(config?.defaultMode ?? "managed", provider: provider)
            selectedModel = config?.defaultModel ?? ""
            thinkingEffort = config?.defaultThinkingEffort ?? "off"
            if let response = try? await api.models() {
                availableModels = response.models
                codexModels = response.codexModels
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

    private var selectedModelLabel: String {
        guard !selectedModel.isEmpty, selectedModel != "default" else { return "默认" }
        return providerModels.first(where: { $0.id == selectedModel })?.label ?? selectedModel
    }

    private var thinkingLabel: String {
        Self.thinkingLevels.first(where: { $0.id == thinkingEffort })?.label ?? "关闭"
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
            .background(cardBackground(selected: false))
        }
        .buttonStyle(.plain)
    }

    private func supportedMode(_ value: String, provider: String) -> String {
        if provider == "codex" { return "full-access" }
        return Self.sessionModes.contains(where: { $0.id == value }) ? value : "managed"
    }

    /// 模式卡（两列网格单元，标签 + 一句话说明），不支持的模式降透明度且不可点。
    private func modeCard(_ option: SessionMode) -> some View {
        let selected = mode == option.id
        let enabled = supportedModes.contains(option.id)
        return Button {
            mode = option.id
            saveDefaults(mode: option.id)
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
            return provider == "codex"
                ? "Codex JSONL 结构化聊天界面，支持多轮对话和工具调用展示。"
                : "结构化聊天界面，支持多轮对话、流式输出和工具调用展示。"
        }
        return provider == "codex"
            ? "Codex PTY 终端会话；terminal 是原始输出，chat 是解析后的阅读视图。"
            : "原始 PTY 终端会话，支持持续交互、终端视图和权限流。"
    }

    /// 模式动态说明，文案对齐 Web getToolModeHint。
    private static func modeHint(provider: String, mode: String) -> String {
        if provider == "codex" {
            return "Codex 支持 PTY 终端与结构化（JSONL）两种会话，结构化模式按 full-access 启动。"
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

    private func saveDefaults(mode: String? = nil, model: String? = nil, thinkingEffort: String? = nil) {
        Task {
            do {
                try await api.updateNewSessionDefaults(mode: mode, model: model, thinkingEffort: thinkingEffort)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func create() {
        guard canCreate else { return }
        creating = true
        errorMessage = nil
        let path = cwd.trimmingCharacters(in: .whitespaces)
        let prompt = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // codex 仅支持 full-access，对齐 Web getSafeModeForTool 的 clamp。
        let effectiveMode = provider == "codex" ? "full-access" : mode
        Task {
            do {
                let snapshot: SessionSnapshot
                if isStructured {
                    snapshot = try await api.createStructuredSession(
                        provider: provider,
                        cwd: path,
                        mode: effectiveMode,
                        model: selectedModel.isEmpty ? nil : selectedModel,
                        thinkingEffort: thinkingEffort,
                        prompt: prompt.isEmpty ? nil : prompt
                    )
                } else {
                    snapshot = try await api.createPtySession(
                        provider: provider,
                        cwd: path,
                        mode: effectiveMode,
                        model: selectedModel.isEmpty ? nil : selectedModel,
                        thinkingEffort: thinkingEffort,
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
        .task {
            currentPath = startPath.isEmpty ? "~" : startPath
            await load()
        }
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
