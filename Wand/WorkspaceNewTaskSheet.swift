import SwiftUI

/// 新建任务 sheet（对齐 web 端新建任务对话框）：名称 + 目录 + worktree 隔离开关。
/// 目录按 find-or-create 归入隐式项目；git 仓库默认生成独立 worktree，
/// 可通过开关显式关闭（服务端 `worktree: false`）。
struct WorkspaceNewTaskSheet: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    /// 预填目录（从项目组「＋」进入时为项目 cwd；全局入口为空）。
    var initialCwd: String = ""
    let onCreated: (Workspace, WorkspaceTaskCreation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cwd = ""
    @State private var worktreeEnabled = true
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
                        fieldCard(title: "任务名称") {
                            TextField("例如：重构会话恢复流程", text: $name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 15))
                        }
                        directoryCard
                        worktreeCard
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
            .task {
                if recentPaths.isEmpty, let recent = try? await api.workspaceRecentPaths() {
                    recentPaths = recent
                }
                if cwd.isEmpty && initialCwd.isEmpty, let recent = recentPaths.first {
                    cwd = recent.path
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

    private var canSubmit: Bool {
        !creating && !trimmedName.isEmpty && trimmedName.count <= 80
    }

    private func loadSuggestions() async {
        let query = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await api.workspacePathSuggestions(query: query)
            suggestions = result.filter(\.isDirectory).prefix(6).map { $0 }
        } catch {
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
            fieldCard(title: "任务目录（服务器上的路径）") {
                TextField(initialCwd.isEmpty ? "例如：/home/user/wand" : initialCwd, text: $cwd)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))
                    .focused($cwdFocused)
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
            let directory = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let (workspace, creation) = try await store.createTask(
                name: trimmedName,
                directory: directory,
                worktree: worktreeEnabled ? nil : false
            )
            dismiss()
            onCreated(workspace, creation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
