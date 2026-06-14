import SwiftUI

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

    @Environment(\.dismiss) private var dismiss

    // git 状态
    @State private var status: GitStatusResult?
    @State private var statusLoading = true
    @State private var statusError: String?

    // 表单
    @State private var message = ""
    @State private var tagName = ""
    @State private var tagEdited = false

    // AI 预生成
    @State private var generating = false

    // 提交
    @State private var committing = false
    @State private var autoGenerating = false
    @State private var submoduleIntent = false
    @State private var errorMessage: String?

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

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerSubtitle
                    statusFilesSection
                    if outcome != nil {
                        resultPanel
                    } else {
                        formPanel
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
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
    }

    // MARK: - 头部与状态

    @ViewBuilder private var headerSubtitle: some View {
        if statusLoading && status == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("读取 git 状态…")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }
        } else if let statusError {
            Text(statusError)
                .font(.footnote)
                .foregroundColor(Theme.danger)
        } else if let s = status {
            if !s.isGit {
                Text("当前会话目录不是 git 仓库")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            } else {
                let count = s.modifiedCount ?? 0
                let parts: [String] = [
                    s.branch ?? "(no branch)",
                    count > 0 ? "\(count) 个改动" : "工作区干净",
                ]
                + ((s.ahead ?? 0) > 0 ? ["↑\(s.ahead ?? 0)"] : [])
                + ((s.behind ?? 0) > 0 ? ["↓\(s.behind ?? 0)"] : [])
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var statusFilesSection: some View {
        if let s = status, s.isGit, let files = s.files, !files.isEmpty, outcome == nil {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files.prefix(30)) { file in
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
                                tinyChip("submodule", color: Theme.brandStrong)
                            }
                        }
                    }
                    if files.count > 30 {
                        Text("…还有 \(files.count - 30) 个文件")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("改动 \(s.modifiedCount ?? files.count) 个文件")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .tint(Theme.textSecondary)
        }
    }

    // MARK: - 表单面板

    private var hasChanges: Bool { (status?.modifiedCount ?? 0) > 0 }

    @ViewBuilder private var formPanel: some View {
        // "New" + AI 预生成按钮
        HStack {
            Text("New")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Button(action: generateAI) {
                HStack(spacing: 5) {
                    if generating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("✦").font(.system(size: 12))
                    }
                    Text(generating ? "生成中…" : "AI").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().stroke(Theme.border, lineWidth: 1))
            }
            .foregroundColor(Theme.brand)
            .disabled(generating || committing || !hasChanges)
        }

        // Commit：上一笔 → 新 message
        VStack(alignment: .leading, spacing: 6) {
            pairOldLine(label: "Commit", old: oldCommitLine)
            TextField("留空由 AI 根据改动生成", text: $message)
                .font(.system(size: 15))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                .disabled(committing)
        }

        // Tag：最新 tag → 新 tag
        VStack(alignment: .leading, spacing: 6) {
            pairOldLine(label: "Tag", old: status?.latestTag ?? "无 tag")
            TextField("留空则 AI 生成（拖入 Tag 球时生效）", text: $tagName)
                .font(.system(size: 14, design: .monospaced))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                .disabled(committing)
                .onChange(of: tagName) { _ in tagEdited = true }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundColor(Theme.danger)
        }

        // 磁吸 dock（提交中替换为 busy 面板）
        if committing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(busyLabel)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        } else {
            MagneticDockView(
                hasChanges: hasChanges,
                hasSubmodule: status?.hasSubmodule == true,
                onAction: { action, sub in submit(action: action, includeSubmodule: sub) }
            )
            .frame(height: 170)

            Text(hasChanges
                ? "拖动磁吸组合 · 丢进提交区执行 · 单击直接执行该项"
                    + (status?.hasSubmodule == true ? "\nSub 球可选，纳入后递归处理 submodule" : "")
                : "工作区干净，无可提交")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary.opacity(0.8))
        }

        // 工作区干净但本地领先远端：dock 无事可做，给一个「仅推送」直达按钮。
        if !hasChanges, let ahead = status?.ahead, ahead > 0, !committing {
            Button(action: pushCommitsOnly) {
                HStack(spacing: 8) {
                    if pushing { ProgressView().controlSize(.small) }
                    Text(pushing ? "推送中…" : "推送 ↑\(ahead) 个待推 commit")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).stroke(Theme.brand.opacity(0.5), lineWidth: 1))
            }
            .foregroundColor(Theme.brand)
            .disabled(pushing)
            if let pushError {
                Text(pushError).font(.footnote).foregroundColor(Theme.danger)
            }
        }
    }

    private var busyLabel: String {
        (autoGenerating ? "AI 生成 + 提交中…" : "执行中…") + (submoduleIntent ? "（含 submodule）" : "")
    }

    private var oldCommitLine: String {
        Self.joinedOr([status?.lastCommit?.shortHash, status?.lastCommit?.subject], fallback: "无 commit")
    }

    /// 拼接非空片段；全空时回退占位文案。
    private static func joinedOr(_ parts: [String?], fallback: String) -> String {
        let cleaned = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? fallback : cleaned.joined(separator: " ")
    }

    private func pairOldLine(label: String, old: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text(old)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("→")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary.opacity(0.75))
        }
    }

    private func tinyChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
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
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                if let err = pushError ?? r.pushError, !err.isEmpty {
                    Text("push 失败:\(err)")
                        .font(.footnote)
                        .foregroundColor(Theme.danger)
                }
                HStack {
                    Button("关闭") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .disabled(pushing)
                    Spacer()
                    if r.pushed {
                        Label("已推送", systemImage: "icloud.and.arrow.up")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Button(action: pushAfterCommit) {
                            HStack(spacing: 6) {
                                if pushing { ProgressView().controlSize(.small).tint(.white) }
                                Text(pushing ? "推送中…" : "Push & Close")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.brand))
                            .foregroundColor(.white)
                        }
                        .disabled(pushing)
                    }
                }
            }
        }
    }

    private func resultPair(label: String, old: String, new: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            HStack(alignment: .top, spacing: 8) {
                Text(old)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("→")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary.opacity(0.75))
                Text(new)
                    .font(.system(size: 12, design: .monospaced))
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
        guard !committing, hasChanges else { return }
        let withTag = action == "commit-tag" || action == "commit-tag-push"
        let push = action == "commit-push" || action == "commit-tag-push"
        let userTag = withTag ? tagName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = status

        committing = true
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
                    // 提交 + 推送一步到位：直接收面板。
                    dismiss()
                } else {
                    outcome = o
                    await loadStatus(force: true)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            committing = false
            autoGenerating = false
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
        guard !pushing else { return }
        pushing = true
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
                } else {
                    dismiss()
                }
            } catch {
                pushError = error.localizedDescription
            }
            pushing = false
        }
    }
}

// MARK: - 磁吸 dock

/// 力场 + 发射区：对齐网页 attachQuickCommitDrag 的手势语义。
/// 坐标系是力场（ZStack topLeading）的本地坐标，DragGesture 越界后仍持续上报，
/// 所以「拖出右缘 = 悬在发射区上」的 hot 判定与网页 pointInLaunch 等价。
private struct MagneticDockView: View {
    let hasChanges: Bool
    let hasSubmodule: Bool
    let onAction: (String, Bool) -> Void

    private static let actionOrder = ["commit", "tag", "push"]
    private var allIds: [String] { hasSubmodule ? Self.actionOrder + ["sub"] : Self.actionOrder }

    private static let chipColors: [String: Color] = [
        "commit": Theme.brand,
        "tag": Color(red: 0.290, green: 0.435, blue: 0.647),   // #4A6FA5
        "push": Color(red: 0.310, green: 0.478, blue: 0.345),  // #4F7A58
        "sub": Color(red: 0.227, green: 0.541, blue: 0.561),   // #3A8A8F
    ]
    private static let chipLabels: [String: String] = [
        "commit": "Commit", "tag": "Tag", "push": "Push", "sub": "Sub",
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
                    .onChange(of: geo.size) { newSize in
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
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(active ? color.opacity(0.16) : Theme.surface))
        .overlay(Capsule().stroke(color.opacity(active ? 0.7 : 0.32), lineWidth: 1.2))
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ChipSizeKey.self, value: [id: geo.size])
            }
        )
        .opacity(!placed ? 0 : (hasChanges ? 1 : 0.45))
        .scaleEffect(active ? 1.06 : 1)
        .offset(x: pos.x, y: pos.y)
        .zIndex(active ? 3 : 2)
        .allowsHitTesting(hasChanges)
        .highPriorityGesture(dragGesture(id))
    }

    // MARK: 发射区

    private var launchPad: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(launchTone)
            Text(hot ? "松手执行" : "提交")
                .font(.system(size: 12, weight: .medium))
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
            if hasChanges && dragAnchor == nil { onAction("commit", false) }
        }
    }

    // MARK: 几何

    private var chipH: CGFloat { chipSizes.values.first?.height ?? 38 }
    private func w(_ id: String) -> CGFloat { chipSizes[id]?.width ?? 86 }

    /// 原位布局：无 Sub 时 ∧ 三角（Commit 顶中 / Tag 左下 / Push 右下），
    /// 有 Sub 时 2×2 网格 —— 对齐网页窄屏 homePositions()。
    private func homePositions() -> [String: CGPoint] {
        let fw = fieldSize.width
        let fh = fieldSize.height
        guard fw > 0, fh > 0 else { return [:] }
        let h = chipH
        let m: CGFloat = 8
        var pos: [String: CGPoint] = [:]
        if hasSubmodule {
            let topY = max(m, fh * 0.20 - h / 2)
            let botY = min(fh - h - m, fh * 0.70 - h / 2)
            func colL(_ wd: CGFloat) -> CGFloat { max(m, fw * 0.27 - wd / 2) }
            func colR(_ wd: CGFloat) -> CGFloat { min(fw - wd - m, fw * 0.73 - wd / 2) }
            pos["commit"] = CGPoint(x: colL(w("commit")), y: topY)
            pos["tag"] = CGPoint(x: colR(w("tag")), y: topY)
            pos["push"] = CGPoint(x: colL(w("push")), y: botY)
            pos["sub"] = CGPoint(x: colR(w("sub")), y: botY)
        } else {
            let topY = max(m, fh * 0.18 - h / 2)
            let botY = min(fh - h - m, fh * 0.72 - h / 2)
            pos["commit"] = CGPoint(x: max(m, (fw - w("commit")) / 2), y: topY)
            pos["tag"] = CGPoint(x: max(m, fw * 0.24 - w("tag") / 2), y: botY)
            pos["push"] = CGPoint(x: min(fw - w("push") - m, fw * 0.76 - w("push") / 2), y: botY)
        }
        return pos
    }

    private func placeHome(animated: Bool) {
        let homes = homePositions()
        guard !homes.isEmpty, allIds.allSatisfy({ chipSizes[$0] != nil }) else { return }
        if animated {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { chipPos = homes }
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
                for cand in Self.actionOrder where !members.contains(cand) {
                    guard let hp = homes[cand] else { continue }
                    let center = CGPoint(x: hp.x + w(cand) / 2, y: hp.y + chipH / 2)
                    if hypot(loc.x - center.x, loc.y - center.y) < 58 {
                        members.append(cand)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                    let intent = Self.tapIntent(id)
                    onAction(intent.0, intent.1)
                } else if endHot {
                    // 丢进发射区 → 执行组合动作（commit 永远隐含）。
                    onAction(Self.compose(members), members.contains("sub"))
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
