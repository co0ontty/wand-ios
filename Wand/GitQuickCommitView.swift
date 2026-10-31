import SwiftUI

enum QuickCommitToolbarPhase: Hashable {
    case idle
    case loading
    case done
}

@MainActor
final class QuickCommitFeedbackController: ObservableObject {
    @Published private(set) var phase: QuickCommitToolbarPhase = .idle
    private var generation = 0

    func begin() {
        generation += 1
        phase = .loading
    }

    func complete(onReset: @escaping () -> Void) {
        generation += 1
        let completedGeneration = generation
        phase = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == completedGeneration else { return }
            self.phase = .idle
            onReset()
        }
    }

    func fail() {
        generation += 1
        phase = .idle
    }
}

/// The compact Git action now lives in the same native symbol menu as files.
///
/// 入口的可达性只由「会话有没有工作目录」和「这里确定不是 git 仓库」决定：
/// 工作区干净、还没取到状态、取状态失败都仍然给入口，点开后面板自己解释状态并重试。
/// 以前这里按「有改动才出现」门控，工作区一干净入口就消失，等于 git 页打不开。
struct GitQuickCommitMenuAction {
    let status: GitStatusResult?
    var phase: QuickCommitToolbarPhase = .idle
    /// 会话有工作目录才提供入口；状态未知不影响能否打开。
    var hasCwd = true
    let action: () -> Void

    var item: SessionMenuAction? {
        guard shouldShow else { return nil }
        return SessionMenuAction(id: "git", title: title, symbol: symbol,
            isEnabled: phase == .idle, action: action)
    }

    /// 只有「确认不是 git 仓库且读取没有报错」才隐藏：目录被删、权限或命令失败时
    /// 仍保留入口，让用户能打开面板看到原因并重试。
    private var shouldShow: Bool {
        guard hasCwd else { return false }
        if phase != .idle { return true }
        guard let status else { return true }
        if status.isGit { return true }
        return !(status.error ?? "").isEmpty
    }

    private var totalChanges: Int {
        counts.modified + counts.deleted + counts.added
    }

    private var symbol: String {
        switch phase {
        case .loading: return "hourglass"
        case .done: return "checkmark"
        case .idle: return "arrow.triangle.branch"
        }
    }

    private var title: String {
        switch phase {
        case .loading:
            return "快捷提交执行中"
        case .done:
            return "快捷提交完成"
        case .idle:
            guard let status else { return "变更与提交，正在读取 git 状态" }
            guard status.isGit else {
                let reason = (status.error ?? "").isEmpty ? "当前目录不是 git 仓库" : "git 状态读取失败"
                return "变更与提交，\(reason)"
            }
            let ahead = status.ahead ?? 0
            let worktrees = status.worktreeCount ?? 0
            if totalChanges == 0 && ahead == 0 {
                return worktrees > 0
                    ? "变更与提交，工作区干净，\(worktrees) 个 Worktree"
                    : "变更与提交，工作区干净"
            }
            return "变更与提交，修改 \(counts.modified)，删除 \(counts.deleted)，新增 \(counts.added)，未推送 \(ahead)"
        }
    }

    private var counts: (modified: Int, deleted: Int, added: Int) {
        var counts = (modified: 0, deleted: 0, added: 0)
        for file in status?.files ?? [] {
            let fileStatus = file.status.uppercased()
            if fileStatus.contains("?") || fileStatus.contains("A") {
                counts.added += 1
            } else if fileStatus.contains("D") {
                counts.deleted += 1
            } else {
                counts.modified += 1
            }
        }
        return counts
    }
}

/// 快速提交面板：交互对齐 Web 端 quick-commit 的「磁吸 dock」。
/// Commit / Tag / Push（+ 可选 Sub）四颗气泡散落在力场里，抓任意一颗拖动，
/// 途经其他气泡会被磁吸进队伍；丢进右侧发射区执行组合动作（commit 永远隐含），
/// 松手在别处则全员弹回原位；单击气泡直接执行该气泡自己的动作。
///
/// message 留空 → 服务端 AI 根据 staged diff 生成；tag 留空且带 Tag 动作 → AI 推荐
/// 版本号；「AI」按钮可预生成两者填进表单。提交未推送时结果面板提供 Push & Close。
struct GitQuickCommitView: View {
    let sessionId: String
    let api: WandAPI
    let onRunning: () -> Void
    let onCompleted: (String) -> Void
    let onFailed: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    // git 状态
    @State private var status: GitStatusResult?
    @State private var statusLoading = true
    @State private var statusError: String?

    // 表单
    @State private var message = ""
    @State private var tagName = ""
    @State private var tagEdited = false
    @FocusState private var focusedInput: QuickCommitInput?

    private enum QuickCommitInput: Hashable {
        case message
        case tag
    }

    // AI 预生成
    @State private var generating = false

    // 提交
    @State private var committing = false
    @State private var autoGenerating = false
    @State private var submoduleIntent = false
    @State private var mergingWorktrees = false
    @State private var errorMessage: String?
    @State private var worktreeFeedback: String?
    @State private var worktreeSummary: String?

    // 结果
    @State private var outcome: CommitOutcome?
    @State private var pushing = false
    @State private var pushError: String?

    /// 一次快捷提交的结果（new 侧），old 侧字段来自提交前的 git 状态快照。
    private struct CommitOutcome {
        var includeSubmodule: Bool
        var pushed: Bool
        var pushError: String?
        var commitHash: String
        var commitMessage: String
        var tagName: String
        var oldTag: String
        var oldCommitHash: String
        var oldCommitSubject: String
        var submoduleCount: Int
    }

    init(
        sessionId: String,
        api: WandAPI,
        onRunning: @escaping () -> Void = {},
        onCompleted: @escaping (String) -> Void = { _ in },
        onFailed: @escaping (String) -> Void = { _ in }
    ) {
        self.sessionId = sessionId
        self.api = api
        self.onRunning = onRunning
        self.onCompleted = onCompleted
        self.onFailed = onFailed
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerSubtitle
                    if status?.isGit == true {
                        if let statusError {
                            staleStatusNotice(statusError)
                        }
                        statusFilesSection
                        if outcome != nil {
                            resultPanel
                        } else {
                            formPanel
                        }
                    } else if statusLoading && status == nil {
                        statusLoadingCard
                    } else {
                        statusUnavailableCard
                    }
                }
                .padding(20)
            }
            .background { WandAmbientBackground() }
            .dismissKeyboardOnTap()
            .navigationTitle("快捷提交")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(outcome == nil ? "取消" : "完成") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                        .disabled(committing || pushing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if committing || pushing {
                        ProgressView()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(committing || pushing)
        .task { await loadStatus(force: true) }
        .wandKeyboardShortcuts(quickCommitKeyboardShortcuts)
    }

    private var quickCommitKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "primary-action",
                title: primaryKeyboardActionTitle,
                key: .return,
                modifiers: .command,
                isEnabled: primaryKeyboardActionEnabled
            ) {
                runPrimaryKeyboardAction()
            },
            WandKeyboardShortcutAction(
                id: "generate-ai-message",
                title: "生成提交文案",
                key: "a",
                modifiers: [.command, .shift],
                isEnabled: hasChanges && !generating && !committing
            ) {
                generateAI()
            },
            WandKeyboardShortcutAction(
                id: "refresh-git-status",
                title: "刷新 Git 状态",
                key: "r",
                modifiers: .command,
                isEnabled: !statusLoading && !committing && !pushing
            ) {
                Task { await loadStatus(force: true) }
            },
            WandKeyboardShortcutAction(
                id: "dismiss-quick-commit",
                title: outcome == nil ? "取消" : "完成",
                key: .escape,
                modifiers: [],
                isEnabled: !committing && !pushing
            ) {
                dismiss()
            },
        ]
    }

    private var primaryKeyboardActionTitle: String {
        if hasChanges { return "提交" }
        if (status?.ahead ?? 0) > 0 { return "推送" }
        return "执行"
    }

    private var primaryKeyboardActionEnabled: Bool {
        !committing && !pushing && (hasChanges || (status?.ahead ?? 0) > 0)
    }

    private func runPrimaryKeyboardAction() {
        if hasChanges {
            submit(action: "commit", includeSubmodule: false)
        } else if (status?.ahead ?? 0) > 0 {
            pushCommitsOnly()
        }
    }

    // MARK: - 头部与状态

    @ViewBuilder private var headerSubtitle: some View {
        if let s = status, s.isGit {
            let count = s.modifiedCount ?? 0
            let parts: [String] = [
                s.branch ?? "(no branch)",
                count > 0 ? "\(count) 个改动" : "工作区干净",
            ]
            + ((s.ahead ?? 0) > 0 ? ["↑\(s.ahead ?? 0)"] : [])
            + ((s.behind ?? 0) > 0 ? ["↓\(s.behind ?? 0)"] : [])
            Text(parts.joined(separator: " · "))
                .font(.wand(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private var statusLoadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在读取 git 状态…")
                .font(.wand(size: 13))
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    /// 已经拿到过状态、但这次刷新失败：保留面板里的旧数据，只提示这次没刷新到。
    private func staleStatusNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.danger)
            Text("刷新失败，显示的是上一次状态：\(message)")
                .font(.wand(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("重试") { Task { await loadStatus(force: true) } }
                .font(.wand(size: 11, weight: .semibold))
                .foregroundColor(Theme.brand)
                .disabled(statusLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.danger.opacity(0.08)))
    }

    /// 读不到状态时不能只给一句错误：目录被删、临时失败、真不是仓库要分开说，
    /// 并且始终留一个原地重试，不让入口“点进来就到底”。
    private var statusUnavailableCard: some View {
        let failure = statusError ?? status?.error
        let notRepository = status?.isGit == false && (failure ?? "").isEmpty
        let title = notRepository ? "当前会话目录不是 git 仓库" : "暂时读不到 git 状态"
        let detail = notRepository
            ? "这个会话的工作目录没有 git 仓库，提交与推送无从谈起。换一个仓库里的会话再试。"
            : (failure ?? "请求没有拿到结果，可能是网络或服务端临时失败。")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: notRepository ? "folder.badge.questionmark" : "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(notRepository ? Theme.textSecondary : Theme.danger)
                Text(title)
                    .font(.wand(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.wand(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    Task { await loadStatus(force: true) }
                } label: {
                    HStack(spacing: 6) {
                        if statusLoading { ProgressView().controlSize(.small) }
                        Text(statusLoading ? "重试中…" : "重试")
                            .font(.wand(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule).tint(Theme.brand)
                .foregroundColor(Theme.brand)
                .disabled(statusLoading)
                Button("关闭") { dismiss() }
                    .font(.wand(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(notRepository ? Theme.border : Theme.danger.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder private var statusFilesSection: some View {
        if let s = status, s.isGit, let files = s.files, !files.isEmpty, outcome == nil {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files.prefix(30)) { file in
                        HStack(spacing: 8) {
                            Text(file.shortStatus)
                                .font(.wand(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 18, height: 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(file.shortStatus == "?" ? Theme.textSecondary : Theme.brand)
                                )
                            Text(file.path)
                                .font(.wand(size: 12, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if file.isSubmodule == true {
                                tinyChip("submodule", color: Theme.brandStrong)
                            }
                        }
                    }
                    if files.count > 30 {
                        Text("…还有 \(files.count - 30) 个文件")
                            .font(.wand(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("改动 \(s.modifiedCount ?? files.count) 个文件")
                    .font(.wand(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .tint(Theme.textSecondary)
        }
    }

    // MARK: - 表单面板

    private var hasChanges: Bool { (status?.modifiedCount ?? 0) > 0 }

    @ViewBuilder private var formPanel: some View {
        commitWorkspaceLens

        // 提交信息 + AI 预生成按钮
        HStack {
            Text("提交信息")
                .font(.wand(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Button(action: generateAI) {
                HStack(spacing: 5) {
                    if generating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles").font(.wand(size: 12))
                    }
                    Text(generating ? "生成中…" : "AI").font(.wand(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                            }
            .buttonStyle(.glass).buttonBorderShape(.capsule)
            .foregroundColor(Theme.brand)
            .disabled(generating || committing || !hasChanges)
        }

        // Commit：上一笔 → 新 message
        VStack(alignment: .leading, spacing: 6) {
            pairOldLine(label: "Commit", old: oldCommitLine)
            Text("新的 Commit 信息")
                .font(.wand(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            TextField("留空由 AI 根据改动生成", text: $message)
                .font(.wand(size: 15))
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.brand)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .focused($focusedInput, equals: .message)
                .wandInputSurface(focused: focusedInput == .message, cornerRadius: 12)
                .disabled(committing)
        }

        // Tag：最新 tag → 新 tag
        VStack(alignment: .leading, spacing: 6) {
            pairOldLine(label: "Tag", old: status?.latestTag ?? "无 tag")
            Text("Tag（可选）")
                .font(.wand(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            TextField("留空则 AI 生成（拖入 Tag 球时生效）", text: $tagName)
                .font(.wand(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.brand)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .focused($focusedInput, equals: .tag)
                .wandInputSurface(focused: focusedInput == .tag, cornerRadius: 12)
                .disabled(committing)
                .onChange(of: tagName) { tagEdited = true }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundColor(Theme.danger)
        }

        MagneticDockView(
            hasChanges: hasChanges,
            hasSubmodule: status?.hasSubmodule == true,
            hasWorktrees: (status?.worktreeCount ?? 0) > 0,
            ahead: status?.ahead ?? 0,
            busy: committing || mergingWorktrees || generating || pushing,
            feedback: committing ? busyLabel : pushing ? "推送中…" : worktreeFeedback,
            onAction: { action, sub in submit(action: action, includeSubmodule: sub) },
            onWorktree: mergeWorktrees,
            onPush: pushCommitsOnly
        )
        .frame(height: 200)

        Text(worktreeFeedback == "已完成"
            ? worktreeSummary ?? "已合并并推送"
            : "点按气泡执行，拖动气泡组合后丢进提交区。Worktree：合并全部工作树到当前分支并推送。")
            .font(.wand(size: 11))
            .foregroundColor(Theme.textSecondary)
    }

    private var busyLabel: String {
        (autoGenerating ? "AI 生成 + 提交中…" : "执行中…") + (submoduleIntent ? "（含 submodule）" : "")
    }

    private var oldCommitLine: String {
        Self.joinedOr([status?.lastCommit?.shortHash, status?.lastCommit?.subject], fallback: "无 commit")
    }

    /// 提交前先交代当前分支、改动和待推送状态，避免表单脱离工作区上下文。
    private var commitWorkspaceLens: some View {
        let changeCount = status?.modifiedCount ?? 0
        let ahead = status?.ahead ?? 0
        let hasPendingChanges = changeCount > 0
        let tone: Color = hasPendingChanges ? Theme.brand : Theme.success
        let stateText = hasPendingChanges
            ? "\(changeCount) 个改动待处理"
            : (ahead > 0 ? "\(ahead) 个 commit 待推送" : "工作区干净")

        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(tone)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tone.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.branch ?? "未识别分支")
                    .font(.wand(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stateText)
                    .font(.wand(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if ahead > 0 && hasPendingChanges {
                Text("↑\(ahead)")
                    .font(.wand(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .wandGlassCapsule(tint: Theme.success)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tone.opacity(0.30), lineWidth: 1))
    }

    /// 拼接非空片段；全空时回退占位文案。
    private static func joinedOr(_ parts: [String?], fallback: String) -> String {
        let cleaned = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? fallback : cleaned.joined(separator: " ")
    }

    private func pairOldLine(label: String, old: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.wand(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text(old)
                .font(.wand(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("→")
                .font(.wand(size: 12))
                .foregroundColor(Theme.textSecondary.opacity(0.75))
        }
    }

    private func tinyChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.wand(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .wandGlassCapsule(tint: color)
    }

    // MARK: - 结果面板

    @ViewBuilder private var resultPanel: some View {
        if let r = outcome {
            VStack(alignment: .leading, spacing: 12) {
                resultPair(
                    label: "Commit",
                    old: Self.joinedOr([r.oldCommitHash, r.oldCommitSubject], fallback: "无"),
                    new: Self.joinedOr([r.commitHash, r.commitMessage], fallback: "无")
                )
                resultPair(
                    label: "Tag",
                    old: r.oldTag.isEmpty ? "无 tag" : r.oldTag,
                    new: r.tagName.isEmpty ? "未打 tag" : r.tagName
                )
                if r.submoduleCount > 0 {
                    Text("已先提交 \(r.submoduleCount) 个 submodule")
                        .font(.wand(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                if let err = pushError ?? r.pushError, !err.isEmpty {
                    Text("push 失败:\(err)")
                        .font(.footnote)
                        .foregroundColor(Theme.danger)
                }
                HStack {
                    Button("关闭") { dismiss() }
                        .font(.wand(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .disabled(pushing)
                    Spacer()
                    if r.pushed {
                        Label("已推送", systemImage: "icloud.and.arrow.up")
                            .font(.wand(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Button(action: pushAfterCommit) {
                            HStack(spacing: 6) {
                                if pushing { ProgressView().controlSize(.small).tint(.white) }
                                Text(pushing ? "推送中…" : "Push & Close")
                                    .font(.wand(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(Theme.brand)
                        .disabled(pushing)
                    }
                }
            }
        }
    }

    private func resultPair(label: String, old: String, new: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.wand(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            HStack(alignment: .top, spacing: 8) {
                Text(old)
                    .font(.wand(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("→")
                    .font(.wand(size: 12))
                    .foregroundColor(Theme.textSecondary.opacity(0.75))
                Text(new)
                    .font(.wand(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 逻辑

    private func loadStatus(force: Bool) async {
        statusLoading = true
        statusError = nil
        do {
            status = try await api.gitStatus(sessionId: sessionId)
        } catch {
            statusError = error.localizedDescription
        }
        statusLoading = false
    }

    private func generateAI() {
        guard !generating, !committing else { return }
        generating = true
        errorMessage = nil
        Task {
            do {
                let r = try await api.generateCommitMessage(sessionId: sessionId)
                let aiMessage = (r.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let aiTag = (r.suggestedTag ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // 只在空白时填 message，绝不覆盖用户已输入的内容。
                if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !aiMessage.isEmpty {
                    message = aiMessage
                }
                if !aiTag.isEmpty, !tagEdited {
                    tagName = aiTag
                    // onChange(tagName) 会把 tagEdited 置 true —— 这里是程序填充，复位。
                    DispatchQueue.main.async { tagEdited = false }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            generating = false
        }
    }

    /// action ∈ {commit, commit-tag, commit-push, commit-tag-push}，与网页一致；
    /// includeSubmodule 是正交 scope flag。
    private func submit(action: String, includeSubmodule: Bool) {
        guard !committing, !mergingWorktrees, !generating, hasChanges else { return }
        let withTag = action == "commit-tag" || action == "commit-tag-push"
        let push = action == "commit-push" || action == "commit-tag-push"
        let userTag = withTag ? tagName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = status

        committing = true
        onRunning()
        dismiss()
        submoduleIntent = includeSubmodule
        autoGenerating = msg.isEmpty || (withTag && userTag.isEmpty)
        errorMessage = nil
        pushError = nil
        Task {
            do {
                let r = try await api.quickCommit(
                    sessionId: sessionId,
                    customMessage: msg.isEmpty ? nil : msg,
                    tag: userTag.isEmpty ? nil : userTag,
                    autoTag: withTag && userTag.isEmpty,
                    push: push,
                    submodule: includeSubmodule
                )
                if !(r.archivedTaskIds ?? []).isEmpty {
                    api.taskChanges.send()
                }
                let o = CommitOutcome(
                    includeSubmodule: includeSubmodule,
                    pushed: r.pushed == true,
                    pushError: (r.pushError?.isEmpty == false) ? r.pushError : nil,
                    commitHash: String((r.commit?.hash ?? "").prefix(7)),
                    commitMessage: r.commit?.message ?? msg,
                    tagName: r.tag?.name ?? "",
                    oldTag: before?.latestTag ?? "",
                    oldCommitHash: before?.lastCommit?.shortHash ?? "",
                    oldCommitSubject: before?.lastCommit?.subject ?? "",
                    submoduleCount: r.submoduleCommits?.count ?? 0
                )
                if push && o.pushError == nil {
                    onCompleted(summaryText(o) + "，已推送")
                } else if let pushError = o.pushError {
                    onFailed("推送失败：\(pushError)")
                } else {
                    onCompleted(summaryText(o))
                }
            } catch {
                errorMessage = error.localizedDescription
                onFailed(error.localizedDescription)
            }
            committing = false
            autoGenerating = false
        }
    }

    private func mergeWorktrees() {
        guard !mergingWorktrees, !committing, !pushing,
              let branch = status?.branch, let head = status?.head else { return }
        mergingWorktrees = true
        worktreeFeedback = "合并并推送中…"
        errorMessage = nil
        onRunning()
        Task {
            do {
                let result = try await api.mergeWorktrees(sessionId: sessionId, branch: branch, head: head)
                if result.ok && result.pushed {
                    worktreeFeedback = "已完成"
                    worktreeSummary = "已合并 \(result.mergedBranches.count) 个 Worktree 到 \(result.targetBranch) 并推送"
                    onCompleted("已合并 \(result.mergedBranches.count) 个 Worktree 到 \(result.targetBranch) 并推送")
                } else {
                    worktreeFeedback = "操作失败"
                    errorMessage = result.error ?? "合并或推送未完成"
                    onFailed(errorMessage ?? "合并失败")
                }
            } catch {
                worktreeFeedback = "操作失败"
                errorMessage = error.localizedDescription
                onFailed(error.localizedDescription)
            }
            await loadStatus(force: true)
            mergingWorktrees = false
        }
    }

    /// 结果面板的 Push & Close。
    private func pushAfterCommit() {
        guard let r = outcome, !pushing else { return }
        pushing = true
        pushError = nil
        Task {
            do {
                let res = try await api.gitPush(
                    sessionId: sessionId,
                    pushCommits: true,
                    pushTags: !r.tagName.isEmpty,
                    submodule: r.includeSubmodule,
                    tag: r.tagName.isEmpty ? nil : r.tagName
                )
                if let err = res.error, !err.isEmpty {
                    pushError = err
                } else {
                    outcome?.pushed = true
                    dismiss()
                }
            } catch {
                pushError = error.localizedDescription
            }
            pushing = false
        }
    }

    /// 工作区干净但 ahead > 0 时的「仅推送 commits」。
    private func pushCommitsOnly() {
        guard !pushing, !committing, !mergingWorktrees, !generating else { return }
        pushing = true
        onRunning()
        dismiss()
        pushError = nil
        Task {
            do {
                let res = try await api.gitPush(
                    sessionId: sessionId,
                    pushCommits: true,
                    pushTags: false,
                    submodule: false,
                    tag: nil
                )
                if let err = res.error, !err.isEmpty {
                    pushError = err
                    onFailed(err)
                } else {
                    onCompleted("已推送 commits")
                }
            } catch {
                pushError = error.localizedDescription
                onFailed(error.localizedDescription)
            }
            pushing = false
        }
    }

    private func summaryText(_ outcome: CommitOutcome) -> String {
        let subPrefix = outcome.submoduleCount > 0 ? "已先提交 \(outcome.submoduleCount) 个 submodule，" : ""
        return subPrefix + "已提交"
            + (outcome.commitHash.isEmpty ? "" : " \(outcome.commitHash)")
            + (outcome.tagName.isEmpty ? "" : "，已打 Tag \(outcome.tagName)")
    }
}

// MARK: - 磁吸 dock

/// 力场 + 发射区：对齐网页 attachQuickCommitDrag 的手势语义。
/// 坐标系是力场（ZStack topLeading）的本地坐标，DragGesture 越界后仍持续上报，
/// 所以「拖出右缘 = 悬在发射区上」的 hot 判定与网页 pointInLaunch 等价。
private struct MagneticDockView: View {
    let hasChanges: Bool
    let hasSubmodule: Bool
    let hasWorktrees: Bool
    let ahead: Int
    let busy: Bool
    let feedback: String?
    let onAction: (String, Bool) -> Void
    let onWorktree: () -> Void
    let onPush: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let actionOrder = ["commit", "tag", "push"]
    private var allIds: [String] { Self.actionOrder + (hasSubmodule ? ["sub"] : []) + ["worktree"] }

    private func isEnabled(_ id: String) -> Bool {
        !busy && (id == "worktree" ? hasWorktrees : id == "push" ? hasChanges || ahead > 0 : hasChanges)
    }

    private static let chipColors: [String: Color] = [
        "commit": Theme.brand,
        "tag": Theme.info,
        "push": Theme.success,
        "sub": Theme.teal,
        "worktree": Theme.info,
    ]
    private static let chipLabels: [String: String] = [
        "commit": "Commit", "tag": "Tag", "push": "Push", "sub": "Sub", "worktree": "Worktree",
    ]

    @State private var fieldSize: CGSize = .zero
    @State private var chipSizes: [String: CGSize] = [:]
    @State private var chipPos: [String: CGPoint] = [:]
    @State private var placed = false
    @State private var dragAnchor: String?
    @State private var dragMembers: [String]?
    @State private var dragMoved = false
    @State private var hot = false
    @State private var clusterBox: CGRect?

    private var composedAction: String {
        Self.compose(dragMembers ?? [])
    }

    private var launchTone: Color {
        switch composedAction {
        case "commit-tag": return Self.chipColors["tag"] ?? Theme.brand
        case "commit-push": return Self.chipColors["push"] ?? Theme.brand
        case "commit-tag-push": return Self.chipColors["sub"] ?? Theme.brand
        default: return Theme.brand
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 8) {
                field
                    .frame(width: max(0, geo.size.width - 84))
                launchPad
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
    }

    // MARK: 力场

    private var field: some View {
        ZStack(alignment: .topLeading) {
            // 队伍光环（多球抱团时的描边框）
            if let box = clusterBox {
                RoundedRectangle(cornerRadius: 12)
                    .fill(launchTone.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(launchTone.opacity(0.4), lineWidth: 1))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }
            ForEach(allIds, id: \.self) { id in
                chipView(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        )
        .coordinateSpace(name: "qcdock")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        fieldSize = geo.size
                        placeHome(animated: false)
                    }
                    .onChange(of: geo.size) { _, newSize in
                        fieldSize = newSize
                        if dragAnchor == nil { placeHome(animated: false) }
                    }
            }
        )
        .onPreferenceChange(ChipSizeKey.self) { sizes in
            for (k, v) in sizes { chipSizes[k] = v }
            if dragAnchor == nil { placeHome(animated: false) }
        }
        .zIndex(1)
    }

    private func chipView(_ id: String) -> some View {
        let color = Self.chipColors[id] ?? Theme.brand
        let active = dragMembers?.contains(id) == true
        let pos = chipPos[id] ?? .zero
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(Self.chipLabels[id] ?? id)
                .font(.wand(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .wandGlassCapsule(tint: active ? color : nil)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ChipSizeKey.self, value: [id: geo.size])
            }
        )
        .opacity(!placed ? 0 : (isEnabled(id) ? 1 : 0.45))
        .scaleEffect(active && !reduceMotion ? 1.06 : 1)
        .offset(x: pos.x, y: pos.y)
        .zIndex(active ? 3 : 2)
        .allowsHitTesting(isEnabled(id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(id == "worktree" ? "合并全部 Worktree 到当前分支并推送" : (Self.chipLabels[id] ?? id))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard isEnabled(id) else { return }
            if id == "worktree" { onWorktree() }
            else if id == "push" && !hasChanges { onPush() }
            else { let intent = Self.tapIntent(id); onAction(intent.0, intent.1) }
        }
        .highPriorityGesture(dragGesture(id))
    }

    // MARK: 发射区

    private var launchPad: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(launchTone)
            Text(feedback ?? (hot ? "松手执行" : "提交"))
                .font(.wand(size: 12, weight: .medium))
                .foregroundColor(hot ? launchTone : Theme.textSecondary)
        }
        .frame(width: 76)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(hot ? launchTone.opacity(0.14) : Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(launchTone.opacity(hot ? 0.85 : 0.3), lineWidth: 1.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if hasChanges && !busy && dragAnchor == nil { onAction("commit", false) }
        }
    }

    // MARK: 几何

    private var chipH: CGFloat { chipSizes.values.first?.height ?? 38 }
    private func w(_ id: String) -> CGFloat { chipSizes[id]?.width ?? 86 }

    /// 原位布局：无 Sub 时 ∧ 三角（Commit 顶中 / Tag 左下 / Push 右下），
    /// 有 Sub 时 2×2 网格 —— 对齐网页窄屏 homePositions()。
    private func homePositions() -> [String: CGPoint] {
        guard fieldSize.width > 0, fieldSize.height > 0 else { return [:] }
        let rows = CGFloat((allIds.count + 1) / 2)
        var positions: [String: CGPoint] = [:]
        for (index, id) in allIds.enumerated() {
            let row = CGFloat(index / 2)
            let column = CGFloat(index % 2)
            let centerX = fieldSize.width * (column == 0 ? 0.27 : 0.73)
            positions[id] = CGPoint(
                x: max(4, min(fieldSize.width - w(id) - 4, centerX - w(id) / 2)),
                y: max(4, (row + 0.5) * fieldSize.height / rows - chipH / 2))
        }
        return positions
    }

    private func placeHome(animated: Bool) {
        let homes = homePositions()
        guard !homes.isEmpty, allIds.allSatisfy({ chipSizes[$0] != nil }) else { return }
        if animated && !reduceMotion {
            withAnimation(WandMotion.disclosure) { chipPos = homes }
        } else {
            chipPos = homes
        }
        placed = true
    }

    // MARK: 手势

    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("qcdock"))
            .onChanged { value in
                if dragAnchor == nil {
                    dragAnchor = id
                    dragMembers = [id]
                    dragMoved = false
                }
                guard dragAnchor == id else { return }
                var members = dragMembers ?? [id]
                let loc = value.location
                if !dragMoved,
                   hypot(value.translation.width, value.translation.height) > 6 {
                    dragMoved = true
                }
                guard dragMoved else { return }

                // 磁吸拾取：只吸主动作球 —— Sub 永不被「路过吸附」（默认不纳入），
                // 但可作为锚点被显式抓起、反向吸附动作球。
                let homes = homePositions()
                for cand in Self.actionOrder where id != "worktree" && hasChanges && !members.contains(cand) {
                    guard let hp = homes[cand] else { continue }
                    let center = CGPoint(x: hp.x + w(cand) / 2, y: hp.y + chipH / 2)
                    if hypot(loc.x - center.x, loc.y - center.y) < 58 {
                        members.append(cand)
                        WandFeedback.impact(.light)
                    }
                }
                dragMembers = members

                // 拖动中的队伍层叠显示；标签无需完整可读，露出的前缘足以表示已吸附。
                let ids = allIds.filter { members.contains($0) }
                let stackStep: CGFloat = 24
                let widest = ids.map(w).max() ?? 0
                let total = widest + stackStep * CGFloat(max(0, ids.count - 1))
                let h = chipH
                let y = min(max(loc.y - h / 2, 2), max(2, fieldSize.height - h - 2))
                var x = loc.x - total / 2
                for cid in ids {
                    chipPos[cid] = CGPoint(x: x, y: y)
                    x += stackStep
                }
                clusterBox = ids.count > 1
                    ? CGRect(x: loc.x - total / 2 - 7, y: y - 7, width: total + 14, height: h + 14)
                    : nil

                // 拖出场地右缘 → 悬在发射区上方（hot）。
                let nowHot = loc.x > fieldSize.width + 4
                if nowHot && !hot {
                    WandFeedback.impact(.medium)
                }
                hot = nowHot
            }
            .onEnded { _ in
                guard dragAnchor == id else { return }
                let members = dragMembers ?? [id]
                let endHot = hot
                let moved = dragMoved
                dragAnchor = nil
                dragMembers = nil
                dragMoved = false
                hot = false
                clusterBox = nil
                placeHome(animated: true)

                if !moved {
                    // 原地单击 → 直接执行该气泡自己的动作。
                    if id == "worktree" { onWorktree() }
                    else if id == "push" && !hasChanges { onPush() }
                    else { let intent = Self.tapIntent(id); onAction(intent.0, intent.1) }
                } else if endHot {
                    // 丢进发射区 → 执行组合动作（commit 永远隐含）。
                    if id == "worktree" { onWorktree() }
                    else if id == "push" && !hasChanges { onPush() }
                    else { onAction(Self.compose(members), members.contains("sub")) }
                }
                // 松手在别处：placeHome 已让全员弹回，不执行任何动作。
            }
    }

    // MARK: 动作合成

    private static func compose(_ members: [String]) -> String {
        let hasTag = members.contains("tag")
        let hasPush = members.contains("push")
        if hasTag && hasPush { return "commit-tag-push" }
        if hasTag { return "commit-tag" }
        if hasPush { return "commit-push" }
        return "commit"
    }

    /// 单击气泡的直发动作（tag/push 隐含 commit；sub 是正交 scope 修饰符）。
    private static func tapIntent(_ id: String) -> (String, Bool) {
        switch id {
        case "tag": return ("commit-tag", false)
        case "push": return ("commit-push", false)
        case "sub": return ("commit", true)
        default: return ("commit", false)
        }
    }
}

/// 气泡尺寸测量（PreferenceKey 聚合所有气泡）。
private struct ChipSizeKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { _, new in new }
    }
}
