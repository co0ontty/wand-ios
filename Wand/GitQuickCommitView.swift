import SwiftUI

/// 快速提交面板：对称 Web 端 quick-commit。
/// commit message 留空 → 服务端 AI 根据 staged diff 生成；
/// 可选打 tag（tag 名留空 → AI 推荐下一个语义化版本号）、提交后推送、纳入 submodule。
/// 直连 GET /api/sessions/:id/git-status 与 POST /api/sessions/:id/quick-commit。
struct GitQuickCommitView: View {
    let sessionId: String
    let api: WandAPI

    @Environment(\.dismiss) private var dismiss

    @State private var status: GitStatusResult?
    @State private var statusLoading = true
    @State private var statusError: String?

    @State private var message = ""
    @State private var withTag = false
    @State private var tagName = ""
    @State private var pushAfter = true
    @State private var includeSubmodule = false

    @State private var committing = false
    @State private var result: QuickCommitResult?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                statusSection
                if let result {
                    resultSection(result)
                } else {
                    messageSection
                    optionsSection
                }
                if committing {
                    progressSection
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
            .navigationTitle("快速提交")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(result == nil ? "取消" : "完成") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                        .disabled(committing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if committing {
                        ProgressView()
                    } else if result == nil {
                        Button("提交") { submit() }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(canCommit ? Theme.brand : Theme.textSecondary)
                            .disabled(!canCommit)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(committing)
        .task { await loadStatus() }
    }

    // MARK: - 仓库状态

    @ViewBuilder private var statusSection: some View {
        Section("仓库状态") {
            if statusLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("读取 git 状态…")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                }
            } else if let statusError {
                Text(statusError)
                    .font(.footnote)
                    .foregroundColor(Theme.danger)
            } else if let status {
                if !status.isGit {
                    Text("当前会话目录不是 git 仓库")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    branchRow(status)
                    filesRow(status)
                    if let last = status.lastCommit {
                        infoRow(label: "最新提交", value: "\(last.shortHash) \(last.subject)")
                    }
                    if let tag = status.latestTag {
                        infoRow(label: "最新 tag", value: tag)
                    }
                }
            }
        }
    }

    private func branchRow(_ status: GitStatusResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13))
                .foregroundColor(Theme.brand)
            Text(status.branch ?? "-")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            if let ahead = status.ahead, ahead > 0 {
                chip("↑\(ahead)", color: Theme.brand)
            }
            if let behind = status.behind, behind > 0 {
                chip("↓\(behind)", color: Theme.textSecondary)
            }
        }
    }

    @ViewBuilder private func filesRow(_ status: GitStatusResult) -> some View {
        let count = status.modifiedCount ?? 0
        if count == 0 {
            Text("没有改动可提交")
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
        } else {
            DisclosureGroup {
                ForEach((status.files ?? []).prefix(30)) { file in
                    HStack(spacing: 8) {
                        Text(file.shortStatus)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(file.shortStatus == "?" ? Theme.textSecondary : Theme.brand)
                            )
                        Text(file.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if file.isSubmodule == true {
                            chip("submodule", color: Theme.brandStrong)
                        }
                    }
                }
                if count > 30 {
                    Text("…还有 \(count - 30) 个文件")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
            } label: {
                Text("改动 \(count) 个文件")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
        }
    }

    // MARK: - message 与选项

    private var messageSection: some View {
        Section {
            TextField("留空由 AI 根据改动生成", text: $message)
                .font(.system(size: 15))
        } header: {
            Text("Commit message")
        } footer: {
            Text("留空时由 AI 阅读 staged diff 自动撰写，可能需要几十秒。")
        }
    }

    @ViewBuilder private var optionsSection: some View {
        Section("选项") {
            Toggle("提交后推送", isOn: $pushAfter)
                .tint(Theme.brand)
            Toggle("同时打 tag", isOn: $withTag.animation(.easeInOut(duration: 0.15)))
                .tint(Theme.brand)
            if withTag {
                TextField("留空由 AI 推荐版本号", text: $tagName)
                    .font(.system(size: 14, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            if status?.hasSubmodule == true {
                Toggle("纳入 submodule", isOn: $includeSubmodule)
                    .tint(Theme.brand)
            }
        }
    }

    private var progressSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var progressText: String {
        let aiMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let aiTag = withTag && tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if aiMessage || aiTag {
            return "AI 正在阅读改动生成\(aiMessage ? " message" : "")\(aiTag ? " tag" : "")，请稍候…"
        }
        return pushAfter ? "提交并推送中…" : "提交中…"
    }

    // MARK: - 结果

    private func resultSection(_ r: QuickCommitResult) -> some View {
        Section("提交结果") {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.commit?.message ?? "已提交")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    if let hash = r.commit?.hash, !hash.isEmpty {
                        Text(hash)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            if let tag = r.tag {
                infoRow(label: "Tag", value: tag.name)
            }
            if let subs = r.submoduleCommits, !subs.isEmpty {
                infoRow(
                    label: "Submodule",
                    value: subs.map { "\($0.path)@\($0.hash)" }.joined(separator: "、")
                )
            }
            if pushAfter {
                if r.pushed == true {
                    Label("已推送到远端", systemImage: "icloud.and.arrow.up")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Label(r.pushError ?? "推送失败，可稍后重试", systemImage: "exclamationmark.icloud")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: - 小组件

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: - 逻辑

    private var canCommit: Bool {
        guard let status, status.isGit, !committing else { return false }
        return (status.modifiedCount ?? 0) > 0
    }

    private func loadStatus() async {
        statusLoading = true
        statusError = nil
        do {
            status = try await api.gitStatus(sessionId: sessionId)
        } catch {
            statusError = error.localizedDescription
        }
        statusLoading = false
    }

    private func submit() {
        guard canCommit else { return }
        committing = true
        errorMessage = nil
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let r = try await api.quickCommit(
                    sessionId: sessionId,
                    customMessage: msg.isEmpty ? nil : msg,
                    tag: withTag && !tag.isEmpty ? tag : nil,
                    autoTag: withTag && tag.isEmpty,
                    push: pushAfter,
                    submodule: includeSubmodule
                )
                result = r
                await loadStatus()
            } catch {
                errorMessage = error.localizedDescription
            }
            committing = false
        }
    }
}
