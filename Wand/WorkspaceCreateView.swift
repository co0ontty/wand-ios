import SwiftUI

/// 新建项目 sheet（对齐 web 端新建项目对话框）：名称 + 目录 + 默认 Agent。
/// 目录输入防抖调用 `GET /api/path-suggestions` 给出可点选的补全，空输入时展示最近使用目录。
struct WorkspaceCreateView: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    let onCreated: (Workspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cwd = ""
    @State private var defaultProvider: WandProvider = .claude
    @State private var suggestions: [WorkspacePathSuggestion] = []
    @State private var recentPaths: [WorkspaceRecentPath] = []
    @State private var showingSuggestions = false
    @State private var creating = false
    @State private var errorMessage: String?
    @FocusState private var cwdFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                WandAmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        fieldCard(title: "项目名称") {
                            TextField("例如：Wand", text: $name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 15))
                        }
                        directoryCard
                        providerCard
                        if let errorMessage {
                            errorBanner(errorMessage)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("新建项目")
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
            .task {
                if let provider = try? await api.workspaceDefaultProvider() {
                    defaultProvider = provider
                }
                if let recent = try? await api.workspaceRecentPaths() {
                    recentPaths = recent
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

    private var trimmedCwd: String {
        cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !creating && !trimmedName.isEmpty && !trimmedCwd.isEmpty
    }

    private func loadSuggestions() async {
        let query = trimmedCwd
        do {
            let result = try await api.workspacePathSuggestions(query: query)
            suggestions = result.filter(\.isDirectory).prefix(6).map { $0 }
        } catch {
            suggestions = []
        }
    }

    private var directoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldCard(title: "项目目录（服务器上的路径）") {
                TextField("例如：/home/user/wand", text: $cwd)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))
                    .focused($cwdFocused)
            }
            if cwdFocused || showingSuggestions {
                if !suggestions.isEmpty {
                    suggestionList(
                        items: suggestions.map { ($0.path, $0.name) },
                        header: "路径建议"
                    )
                } else if !recentPaths.isEmpty {
                    suggestionList(
                        items: recentPaths.map { ($0.path, $0.name) },
                        header: "最近使用"
                    )
                }
            }
        }
    }

    private func suggestionList(items: [(path: String, name: String)], header: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            ForEach(items, id: \.path) { item in
                Button {
                    cwd = item.path
                    showingSuggestions = false
                    cwdFocused = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                        Text(item.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surface.opacity(0.88))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.border, lineWidth: 0.8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("默认 Agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(WandProvider.allCases) { provider in
                    providerChip(provider)
                }
            }
        }
    }

    private func providerChip(_ provider: WandProvider) -> some View {
        let selected = defaultProvider == provider
        return Button {
            defaultProvider = provider
        } label: {
            VStack(spacing: 6) {
                BrandLogo(provider: provider.rawValue, color: selected ? Theme.brand : Theme.textSecondary)
                    .frame(width: 21, height: 21)
                Text(provider.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.brand.opacity(0.08) : Theme.surface.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.brand : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(creating)
        .accessibilityLabel(provider.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func fieldCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surface.opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        creating = true
        errorMessage = nil
        do {
            let created = try await store.createWorkspace(
                name: trimmedName,
                cwd: trimmedCwd,
                defaultProvider: defaultProvider
            )
            creating = false
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            creating = false
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundColor(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.danger.opacity(0.10))
            )
    }
}
