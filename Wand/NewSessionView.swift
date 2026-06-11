import SwiftUI

/// 新建会话：选择工作目录（最近路径 / 内置目录浏览器）、会话类型与权限模式，
/// 可附带首条消息。创建成功后回调给列表页直接进入会话。
struct NewSessionView: View {
    let api: WandAPI
    let onCreated: (SessionSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cwd = ""
    @State private var recentPaths: [RecentPath] = []
    @State private var provider: Provider = .claude
    @State private var sessionType: SessionType = .structured
    @State private var mode: ModeOption = .standard
    @State private var firstMessage = ""
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var showBrowser = false

    enum Provider: String, CaseIterable, Identifiable {
        case claude, codex
        var id: String { rawValue }
        var label: String { self == .claude ? "Claude" : "Codex" }
    }

    enum SessionType: String, CaseIterable, Identifiable {
        case structured, pty
        var id: String { rawValue }
        var label: String { self == .structured ? "聊天" : "终端" }
    }

    /// 简化的权限模式：standard 不传 mode（用服务端默认），其余映射 ExecutionMode。
    enum ModeOption: String, CaseIterable, Identifiable {
        case standard, autoEdit, fullAccess
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: return "默认"
            case .autoEdit: return "自动编辑"
            case .fullAccess: return "完全访问"
            }
        }
        var apiValue: String? {
            switch self {
            case .standard: return nil
            case .autoEdit: return "auto-edit"
            case .fullAccess: return "full-access"
            }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("工作目录") {
                    TextField("/path/to/project", text: $cwd)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button {
                        showBrowser = true
                    } label: {
                        Label("浏览目录…", systemImage: "folder")
                            .font(.system(size: 14))
                    }
                    if !recentPaths.isEmpty {
                        ForEach(recentPaths.prefix(5)) { recent in
                            Button {
                                cwd = recent.path
                            } label: {
                                HStack {
                                    Image(systemName: "clock")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.textSecondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(recent.displayName)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(Theme.textPrimary)
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
                            }
                        }
                    }
                }

                Section("助手") {
                    Picker("助手", selection: $provider) {
                        ForEach(Provider.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("会话类型") {
                    Picker("类型", selection: $sessionType) {
                        ForEach(SessionType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("权限模式", selection: $mode) {
                        ForEach(ModeOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }

                Section("首条消息（可选）") {
                    TextField("想让它做什么…", text: $firstMessage)
                        .font(.system(size: 15))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(Theme.danger)
                    }
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

    private var canCreate: Bool {
        !cwd.trimmingCharacters(in: .whitespaces).isEmpty && !creating
    }

    private func create() {
        guard canCreate else { return }
        creating = true
        errorMessage = nil
        let path = cwd.trimmingCharacters(in: .whitespaces)
        let prompt = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let snapshot: SessionSnapshot
                switch sessionType {
                case .structured:
                    snapshot = try await api.createStructuredSession(
                        provider: provider.rawValue,
                        cwd: path,
                        mode: mode.apiValue,
                        prompt: prompt.isEmpty ? nil : prompt
                    )
                case .pty:
                    snapshot = try await api.createPtySession(
                        provider: provider.rawValue,
                        cwd: path,
                        mode: mode.apiValue,
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
