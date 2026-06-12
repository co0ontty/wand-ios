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
    @State private var mode = "default"
    @State private var firstMessage = ""
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var showBrowser = false

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

    /// codex 仅支持 full-access，对齐 Web getSupportedModes。
    private var supportedModes: Set<String> {
        provider == "codex" ? ["full-access"] : Set(Self.sessionModes.map { $0.id })
    }

    var body: some View {
        NavigationView {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("Provider")
                        HStack(spacing: 10) {
                            providerCard(
                                id: "claude",
                                label: "Claude",
                                desc: "完整 Claude 会话能力",
                                accent: Theme.brand
                            )
                            providerCard(
                                id: "codex",
                                label: "Codex",
                                desc: "结构化 JSONL 或 PTY 会话",
                                accent: Theme.codex
                            )
                        }

                        sectionHeader("会话类型")
                        HStack(spacing: 10) {
                            kindCard(
                                structured: true,
                                icon: "bubble.left.and.bubble.right",
                                label: "结构化",
                                desc: "智能对话模式"
                            )
                            kindCard(
                                structured: false,
                                icon: "terminal",
                                label: "PTY",
                                desc: "交互式终端会话"
                            )
                        }
                        fieldHint(Self.sessionKindHint(provider: provider, structured: isStructured))

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
                }
            }
            .safeAreaInset(edge: .bottom) { createBar }
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
            recentPaths = (try? await api.recentPaths()) ?? []
            if cwd.isEmpty {
                if let first = recentPaths.first {
                    cwd = first.path
                } else if let config = try? await api.serverConfig(), let def = config.defaultCwd {
                    cwd = def
                }
            }
        }
    }

    // MARK: - 区块组件

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    /// 区块下方的说明文案，对应 Web 的 .field-hint。
    private func fieldHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(3)
            .foregroundColor(Theme.textSecondary.opacity(0.85))
            .padding(.top, 8)
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

    /// Provider 选择卡：品牌 logo（圆形软底）+ 名称 + 一句话说明，2 张横排。
    private func providerCard(id: String, label: String, desc: String, accent: Color) -> some View {
        let selected = provider == id
        return Button {
            provider = id
            // codex 仅支持全权限，切换时同步 clamp 选中态，对齐 Web getSafeModeForTool。
            if id == "codex" { mode = "full-access" }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(accent.opacity(0.13))
                    BrandLogoShape(provider: id)
                        .fill(accent)
                        .frame(width: 20, height: 20)
                }
                .frame(width: 36, height: 36)
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(cardBackground(selected: selected))
        }
        .buttonStyle(.plain)
    }

    /// 会话类型卡：图标 + 标签 + 一句话说明，2 张横排。
    private func kindCard(structured: Bool, icon: String, label: String, desc: String) -> some View {
        let selected = isStructured == structured
        return Button {
            isStructured = structured
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(selected ? Theme.brand : Theme.textSecondary)
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(cardBackground(selected: selected))
        }
        .buttonStyle(.plain)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(cardBackground(selected: selected))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// 工作目录卡：路径输入 + 浏览目录入口 + 最近路径快速选择。
    private var cwdCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("/path/to/project", text: $cwd)
                .font(.system(size: 14, design: .monospaced))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            Divider().background(Theme.border)
            Button {
                showBrowser = true
            } label: {
                Label("浏览目录…", systemImage: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
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
                        prompt: prompt.isEmpty ? nil : prompt
                    )
                } else {
                    snapshot = try await api.createPtySession(
                        provider: provider,
                        cwd: path,
                        mode: effectiveMode,
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
