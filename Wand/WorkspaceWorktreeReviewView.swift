import SwiftUI

/// 项目级 Worktree 审查与 Agent 合并入口（对齐 web 端 WorkspaceWorktreeDialog）：
/// 读取 `GET /api/workspaces/:id/worktrees` 的可合并状态，勾选后生成中文任务书，
/// 以 managed 模式启动只绑定项目的托管 Agent 会话。
struct WorkspaceWorktreeReviewView: View {
    let workspace: Workspace
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    let onMergeAgentStarted: (SessionSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var overview: WorkspaceWorktreeOverview?
    @State private var selectedTaskIds = Set<String>()
    @State private var loading = true
    @State private var submitting = false
    @State private var errorMessage: String?

    private var actionable: [WorkspaceWorktreeReview] {
        overview?.actionableWorktrees ?? []
    }

    private var selectedCount: Int {
        actionable.filter { selectedTaskIds.contains($0.taskId) }.count
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                WandAmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        targetLens
                        if loading {
                            loadingView
                        } else if let overview, !overview.worktrees.isEmpty {
                            pickerSection(overview)
                        } else if overview != nil {
                            Text("这个项目还没有独立 Worktree。请先新建任务。")
                                .font(.footnote)
                                .foregroundColor(Theme.textSecondary)
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity)
                        }
                        if let errorMessage {
                            errorBanner(errorMessage)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 92)
                }
                submitBar
            }
            .navigationTitle("项目 Worktrees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .disabled(submitting)
                }
            }
            .task { await load() }
        }
        .interactiveDismissDisabled(submitting)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let result = try await api.workspaceWorktreeOverview(workspaceId: workspace.id)
            overview = result
            selectedTaskIds = Set(result.worktrees.filter(\.actionable).map(\.taskId))
            loading = false
        } catch {
            errorMessage = presentError(error, fallback: "无法读取项目 Worktree。")
            loading = false
        }
    }

    /// 顶部「合并目标」区：默认分支 + 主工作区路径（对齐 web 端 lens 区块）。
    private var targetLens: some View {
        let target = overview?.targetBranch.isEmpty == false ? overview!.targetBranch : "项目默认分支"
        let repoRoot = overview?.repoRoot.isEmpty == false ? overview!.repoRoot : workspace.cwd
        return HStack(spacing: 11) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.brand)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.brand.opacity(0.10))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("合并目标")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                Text(target)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            Spacer(minLength: 8)
            Text(repoRoot)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("合并目标 \(target)，主工作区 \(repoRoot)")
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.brand)
            Text("正在检查所有 Worktree…")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func pickerSection(_ overview: WorkspaceWorktreeOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("选择要交给 Agent 合并的 Worktree")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 8)
                if actionable.count > 1 {
                    Button(selectedCount == actionable.count ? "取消全选" : "全选可合并项") {
                        if selectedCount == actionable.count {
                            selectedTaskIds = []
                        } else {
                            selectedTaskIds = Set(actionable.map(\.taskId))
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .disabled(submitting)
                }
            }
            ForEach(overview.worktrees) { worktree in
                worktreeBubble(worktree)
            }
        }
    }

    private func worktreeBubble(_ worktree: WorkspaceWorktreeReview) -> some View {
        let selected = selectedTaskIds.contains(worktree.taskId)
        let disabled = !worktree.actionable || submitting
        return Button {
            guard !disabled else { return }
            if selected {
                selectedTaskIds.remove(worktree.taskId)
            } else {
                selectedTaskIds.insert(worktree.taskId)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(selected ? Theme.brand : Theme.textMuted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(worktree.summary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    Text(worktree.branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(worktree.details)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Text(worktree.stateLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(stateColor(worktree.state))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(stateColor(worktree.state).opacity(0.12))
                    )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.brand.opacity(0.06) : Theme.surface.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        selected ? Theme.brand : Theme.border,
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .opacity(worktree.actionable ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("\(worktree.summary)，\(worktree.stateLabel)")
        .accessibilityValue(worktree.details)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "ready": return Theme.brand
        case "dirty": return Theme.codex
        case "conflict": return Theme.danger
        case "empty": return Theme.success
        default: return Theme.textMuted
        }
    }

    private var submitBar: some View {
        VStack(spacing: 8) {
            Text(submitHint)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 8) {
                    if submitting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text(submitTitle)
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(canSubmit ? Theme.brand : Theme.brand.opacity(0.45))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var submitHint: String {
        selectedCount > 0 ? "已选择 \(selectedCount) 个" : "选择后会启动一个托管 Agent"
    }

    private var submitTitle: String {
        submitting ? "正在启动 Agent…" : "启动 Agent 合并\(selectedCount > 0 ? " \(selectedCount) 个" : "")"
    }

    private var canSubmit: Bool {
        !loading && !submitting && selectedCount > 0
    }

    private func submit() async {
        guard canSubmit, let overview else { return }
        submitting = true
        errorMessage = nil
        do {
            let started = try await store.startWorktreeMergeAgent(
                workspace: workspace,
                overview: overview,
                selectedTaskIds: selectedTaskIds
            )
            submitting = false
            onMergeAgentStarted(started)
            dismiss()
        } catch {
            errorMessage = presentError(error, fallback: "无法启动 Worktree 合并 Agent。")
            submitting = false
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

    private func presentError(_ error: Error, fallback: String) -> String {
        let message = error.localizedDescription
        return message.isEmpty ? fallback : message
    }
}
