import SwiftUI

/// 新建任务 sheet（对齐 web 端新建任务对话框）：名称 + 目录 + worktree 隔离开关。
/// 目录按 find-or-create 归入隐式项目；git 仓库默认生成独立 worktree，
/// 可通过开关显式关闭（服务端 `worktree: false`）。
struct WorkspaceNewTaskSheet: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    /// 预填目录（从项目组「＋」进入时为项目 cwd；全局入口为空）。
    var initialCwd: String = ""
    var workspaceId: String? = nil
    let onCreated: (Workspace, WorkspaceTaskCreation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cwd = ""
    @State private var worktreeEnabled = true
    @State private var target: WorkspaceSessionTarget = .claude
    @State private var sessionKind: WorkspaceSessionKind = .structured
    @State private var suggestions: [WorkspacePathSuggestion] = []
    @State private var recentPaths: [WorkspaceRecentPath] = []
    @State private var showingSuggestions = false
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var defaultCwd = ""
    @State private var directoryPickerPresented = false
    @State private var directoryPickerPath = "/"
    @State private var directoryListing: DirectoryListing?
    @State private var directoryLoading = false
    @State private var directoryError: String?
    @FocusState private var cwdFocused: Bool

    init(
        api: WandAPI,
        store: WorkspaceStore,
        initialCwd: String = "",
        workspaceId: String? = nil,
        onCreated: @escaping (Workspace, WorkspaceTaskCreation) -> Void
    ) {
        self.api = api
        self.store = store
        self.initialCwd = initialCwd
        self.workspaceId = workspaceId
        self.onCreated = onCreated
        _cwd = State(initialValue: initialCwd.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WandAmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("先选工作目录，再决定是否归入已有项目。任务名称由系统自动生成。")
                            .font(.footnote)
                            .foregroundColor(Theme.textSecondary)
                        directoryCard
                        if !trimmedDirectory.isEmpty {
                            worktreeCard
                        }
                        cliCard
                        if let errorMessage {
                            errorBanner(errorMessage)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("新建任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(creating)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(creating ? "创建中…" : "创建") {
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
                    worktreeEnabled = config.defaultTaskWorktree != false
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
                if cwd.isEmpty {
                    cwd = defaultCwd.isEmpty ? (recentPaths.first?.path ?? "") : defaultCwd
                }
            }
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

    private var canSubmit: Bool {
        !creating && !trimmedDirectory.isEmpty && trimmedName.count <= 80
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
                .font(.system(size: 12, weight: .semibold))
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

    private var directoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldCard(title: "工作目录（服务器上的路径）") {
                HStack(spacing: 8) {
                    TextField("点击浏览或输入路径", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                        .focused($cwdFocused)
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
                            cwd = suggestion.path
                            showingSuggestions = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text(suggestion.path)
                                    .font(.system(size: 11, design: .monospaced))
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
                                cwd = recent.path
                            } label: {
                                Text(recent.path)
                                    .font(.system(size: 11, design: .monospaced))
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
                            cwd = directoryPickerPath
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
                                            .font(.system(size: 11, design: .monospaced))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WorkspaceSessionTarget.allCases) { option in
                        let selected = target == option
                        Button {
                            target = option
                            store.rememberCreationChoice(provider: option)
                        } label: {
                            Text(option.title)
                                .font(.system(size: 13, weight: .semibold))
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                HStack(spacing: 8) {
                    ForEach(WorkspaceSessionKind.allCases) { option in
                        let selected = sessionKind == option
                        Button {
                            sessionKind = option
                            store.rememberCreationChoice(kind: option)
                        } label: {
                            Text(option.title)
                                .font(.system(size: 13, weight: .semibold))
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

    private var worktreeCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(worktreeEnabled ? Theme.brand : Theme.textMuted)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(worktreeEnabled ? Theme.brand.opacity(0.12) : Theme.surface)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("独立 worktree 隔离")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(worktreeEnabled
                    ? "为任务创建独立分支与工作树，改动隔离、可审查后合并。"
                    : "会话直接运行在任务目录；非 git 目录自动用这种模式。")
                    .font(.footnote)
                    .foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $worktreeEnabled)
                .labelsHidden()
                .tint(Theme.brand)
                .onChange(of: worktreeEnabled) { _, enabled in
                    Task { try? await api.updateNewSessionDefaults(defaultTaskWorktree: enabled) }
                }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(worktreeEnabled ? Theme.brand.opacity(0.42) : .clear, lineWidth: 1)
        )
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
        creating = true
        errorMessage = nil
        defer { creating = false }
        do {
            store.rememberCreationChoice(provider: target, kind: sessionKind)
            let (workspace, creation) = try await store.createTask(
                name: trimmedName.isEmpty ? "未命名任务" : trimmedName,
                directory: trimmedDirectory,
                worktree: workspaceId != nil && worktreeEnabled,
                workspaceId: workspaceId
            )
            dismiss()
            onCreated(workspace, creation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
