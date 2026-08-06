import Combine
import Foundation
import SwiftUI

private enum MissionWorkspaceTab: String, CaseIterable, Identifiable {
    case inbox
    case missions

    var id: String { rawValue }
    var title: String { self == .inbox ? "Inbox" : "任务" }
}

private struct MissionProviderOption: Identifiable {
    let id: String
    let title: String

    static let all = [
        MissionProviderOption(id: "claude", title: "Claude"),
        MissionProviderOption(id: "codex", title: "Codex"),
        MissionProviderOption(id: "opencode", title: "OpenCode"),
        MissionProviderOption(id: "grok", title: "Grok"),
        MissionProviderOption(id: "qoder", title: "Qoder"),
        MissionProviderOption(id: "pi", title: "Pi"),
    ]
}

private struct MissionProviderMark: View {
    let provider: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Group {
            if provider == "pi" {
                Text("π")
                    .font(.system(size: size * 0.78, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            } else {
                BrandLogo(provider: provider, color: color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.capitalized)
    }
}

private struct MissionReviewTarget: Identifiable {
    let filePath: String
    let line: Int?
    let side: String

    var id: String { "\(filePath)-\(side)-\(line ?? 0)" }
}

private struct MissionRenderedDiffLine: Identifiable {
    let id: Int
    let text: String
    let kind: Kind
    let target: MissionReviewTarget?

    enum Kind { case added, removed, context, metadata }
}

private let missionHunkRegex = try! NSRegularExpression(
    pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
)

private func renderMissionDiff(_ patch: String) -> [MissionRenderedDiffLine] {
    var oldFile: String?
    var newFile: String?
    var oldLine = 0
    var newLine = 0
    return patch.components(separatedBy: "\n").prefix(5_000).enumerated().map { index, text in
        if text.hasPrefix("--- ") {
            let path = String(text.dropFirst(4)).replacingOccurrences(of: "a/", with: "", options: .anchored)
            oldFile = path == "/dev/null" ? nil : path
        }
        if text.hasPrefix("+++ ") {
            let path = String(text.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored)
            newFile = path == "/dev/null" ? nil : path
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = missionHunkRegex.firstMatch(in: text, range: range),
           let oldRange = Range(match.range(at: 1), in: text),
           let newRange = Range(match.range(at: 2), in: text) {
            oldLine = Int(text[oldRange]) ?? 0
            newLine = Int(text[newRange]) ?? 0
            return MissionRenderedDiffLine(id: index, text: text, kind: .metadata, target: nil)
        }
        if text.hasPrefix("+") && !text.hasPrefix("+++") {
            defer { newLine += 1 }
            let target = (newFile ?? oldFile).map { MissionReviewTarget(filePath: $0, line: newLine, side: "new") }
            return MissionRenderedDiffLine(id: index, text: text, kind: .added, target: target)
        }
        if text.hasPrefix("-") && !text.hasPrefix("---") {
            defer { oldLine += 1 }
            let target = (oldFile ?? newFile).map { MissionReviewTarget(filePath: $0, line: oldLine, side: "old") }
            return MissionRenderedDiffLine(id: index, text: text, kind: .removed, target: target)
        }
        if text.hasPrefix(" ") {
            defer {
                oldLine += 1
                newLine += 1
            }
            let target = (newFile ?? oldFile).map { MissionReviewTarget(filePath: $0, line: newLine, side: "new") }
            return MissionRenderedDiffLine(id: index, text: text, kind: .context, target: target)
        }
        return MissionRenderedDiffLine(id: index, text: text, kind: .metadata, target: nil)
    }
}

private func missionStatePresentation(_ state: String) -> (String, String, Color) {
    switch state {
    case "needs_input": return ("等待输入", "questionmark.bubble.fill", .orange)
    case "needs_permission": return ("等待权限", "lock.trianglebadge.exclamationmark.fill", .orange)
    case "working", "running": return ("执行中", "bolt.horizontal.circle.fill", Theme.codex)
    case "queued", "dispatching": return ("准备中", "clock.fill", Theme.textMuted)
    case "done", "completed": return ("已完成", "checkmark.circle.fill", Theme.success)
    case "failed": return ("失败", "exclamationmark.circle.fill", Theme.danger)
    case "archived": return ("已归档", "archivebox.fill", Theme.textMuted)
    default: return (state, "circle.fill", Theme.textMuted)
    }
}

struct MissionsView: View {
    let api: WandAPI
    let onOpenSession: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: MissionWorkspaceTab = .inbox
    @State private var inbox: [AgentActivityItem] = []
    @State private var missions: [MissionInfo] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showCreate = false

    private let refreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("任务视图", selection: $tab) {
                    ForEach(MissionWorkspaceTab.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Group {
                    if loading && inbox.isEmpty && missions.isEmpty {
                        ProgressView().tint(Theme.brand)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if tab == .inbox {
                        inboxContent
                    } else {
                        missionsContent
                    }
                }
            }
            .background { WandAmbientBackground() }
            .navigationTitle("Agent Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await refresh(showProgress: false) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("新建并行任务")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            MissionCreateView(api: api) { mission in
                missions.removeAll { $0.id == mission.id }
                missions.insert(mission, at: 0)
                tab = .missions
            }
        }
        .task { await refresh(showProgress: true) }
        .onReceive(refreshTimer) { _ in
            Task { await refresh(showProgress: false) }
        }
        .alert("任务操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder private var inboxContent: some View {
        let attention = inbox.filter(\.needsAttention)
        let working = inbox.filter { $0.state == "working" }
        let finished = inbox.filter { !$0.needsAttention && $0.state != "working" }
        if inbox.isEmpty {
            MissionEmptyState(
                icon: "tray",
                title: "Inbox 是空的",
                detail: "Agent 需要输入、权限或完成任务时会出现在这里。"
            )
        } else {
            List {
                MissionActivitySection(title: "需要你", items: attention, onOpen: openActivity)
                MissionActivitySection(title: "执行中", items: working, onOpen: openActivity)
                MissionActivitySection(title: "最近完成", items: finished, onOpen: openActivity)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await refresh(showProgress: false) }
        }
    }

    @ViewBuilder private var missionsContent: some View {
        if missions.isEmpty {
            MissionEmptyState(
                icon: "point.3.connected.trianglepath.dotted",
                title: "还没有并行任务",
                detail: "把同一个目标分派给多个 Agent，在独立 worktree 中并行推进。",
                actionTitle: "新建任务",
                action: { showCreate = true }
            )
        } else {
            List(missions) { mission in
                NavigationLink {
                    MissionDetailView(api: api, initialMission: mission, onOpenSession: openSessionAndDismiss)
                } label: {
                    MissionRow(mission: mission)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await refresh(showProgress: false) }
        }
    }

    private func openActivity(_ item: AgentActivityItem) {
        Task { try? await api.markMissionInboxRead(sessionId: item.sessionId) }
        openSessionAndDismiss(item.sessionId)
    }

    private func openSessionAndDismiss(_ sessionId: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onOpenSession(sessionId)
        }
    }

    private func refresh(showProgress: Bool) async {
        if showProgress { loading = true }
        async let loadedInbox = api.missionInbox()
        async let loadedMissions = api.missions()
        do {
            let values = try await (loadedInbox, loadedMissions)
            inbox = values.0
            missions = values.1
            errorMessage = nil
        } catch {
            if showProgress || (inbox.isEmpty && missions.isEmpty) {
                errorMessage = error.localizedDescription
            }
        }
        loading = false
    }
}

private struct MissionActivitySection: View {
    let title: String
    let items: [AgentActivityItem]
    let onOpen: (AgentActivityItem) -> Void

    var body: some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button { onOpen(item) } label: {
                        MissionActivityRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct MissionActivityRow: View {
    let item: AgentActivityItem

    var body: some View {
        let presentation = missionStatePresentation(item.state)
        HStack(spacing: 12) {
            Image(systemName: presentation.1)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(presentation.2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if item.readAt == nil {
                        Circle().fill(Theme.brand).frame(width: 7, height: 7)
                            .accessibilityLabel("未读")
                    }
                }
                Text(item.summary ?? item.cwd ?? presentation.0)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                Text([item.provider?.capitalized, presentation.0].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(presentation.2)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.vertical, 4)
    }
}

private struct MissionRow: View {
    let mission: MissionInfo

    var body: some View {
        let presentation = missionStatePresentation(mission.status)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mission.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Spacer()
                Label(presentation.0, systemImage: presentation.1)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(presentation.2)
            }
            Text(mission.prompt)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Label("\(mission.attempts.count) Agents", systemImage: "person.2")
                if let base = mission.worktree.baseRef, !base.isEmpty {
                    Label(base, systemImage: "arrow.triangle.branch").lineLimit(1)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.textMuted)
        }
        .padding(.vertical, 6)
    }
}

private struct MissionDetailView: View {
    let api: WandAPI
    let initialMission: MissionInfo
    let onOpenSession: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mission: MissionInfo
    @State private var errorMessage: String?
    @State private var archiving = false
    @State private var confirmArchive = false

    init(api: WandAPI, initialMission: MissionInfo, onOpenSession: @escaping (String) -> Void) {
        self.api = api
        self.initialMission = initialMission
        self.onOpenSession = onOpenSession
        _mission = State(initialValue: initialMission)
    }

    var body: some View {
        List {
            Section("目标") {
                Text(mission.prompt)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                LabeledContent("工作目录", value: mission.cwd)
                if let base = mission.worktree.baseRef {
                    LabeledContent("基线", value: base)
                }
            }
            Section("Attempts") {
                ForEach(mission.attempts) { attempt in
                    NavigationLink {
                        MissionDiffView(
                            api: api,
                            mission: mission,
                            attempt: attempt,
                            onOpenSession: onOpenSession
                        )
                    } label: {
                        MissionAttemptRow(attempt: attempt)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if let sessionId = attempt.sessionId {
                            Button { onOpenSession(sessionId) } label: {
                                Label("会话", systemImage: "bubble.left.and.bubble.right")
                            }
                            .tint(Theme.codex)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { WandAmbientBackground() }
        .navigationTitle(mission.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Task { await refresh() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { confirmArchive = true } label: {
                        Label("归档任务", systemImage: "archivebox")
                    }
                    .disabled(archiving)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await refresh() }
        .confirmationDialog("归档这个任务？", isPresented: $confirmArchive) {
            Button("归档", role: .destructive) { Task { await archive() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("归档后将从任务列表隐藏，会话和 worktree 不会被删除。")
        }
        .alert("任务操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func refresh() async {
        do {
            let loaded = try await api.missions()
            if let current = loaded.first(where: { $0.id == mission.id }) {
                mission = current
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive() async {
        archiving = true
        do {
            _ = try await api.archiveMission(id: mission.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        archiving = false
    }
}

private struct MissionAttemptRow: View {
    let attempt: MissionAttempt

    var body: some View {
        let presentation = missionStatePresentation(attempt.state)
        HStack(spacing: 12) {
            MissionProviderMark(provider: attempt.provider, color: presentation.2, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(attempt.provider.capitalized)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Label(presentation.0, systemImage: presentation.1)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(presentation.2)
                }
                Text(attempt.error ?? attempt.summary ?? attempt.branch ?? "等待 Agent 更新")
                    .font(.system(size: 11))
                    .foregroundColor(attempt.error == nil ? Theme.textSecondary : Theme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MissionDiffView: View {
    let api: WandAPI
    let mission: MissionInfo
    let attempt: MissionAttempt
    let onOpenSession: (String) -> Void

    @State private var diff: MissionDiff?
    @State private var comments: [MissionReviewComment]
    @State private var target: MissionReviewTarget?
    @State private var loading = true
    @State private var sending = false
    @State private var errorMessage: String?

    init(
        api: WandAPI,
        mission: MissionInfo,
        attempt: MissionAttempt,
        onOpenSession: @escaping (String) -> Void
    ) {
        self.api = api
        self.mission = mission
        self.attempt = attempt
        self.onOpenSession = onOpenSession
        _comments = State(initialValue: mission.comments.filter { $0.attemptId == attempt.id })
    }

    private var pending: [MissionReviewComment] { comments.filter { $0.status == "pending" } }

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(Theme.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff {
                VStack(spacing: 0) {
                    diffSummary(diff)
                    Divider().opacity(0.3)
                    diffBody(diff)
                }
            } else {
                MissionEmptyState(icon: "doc.text.magnifyingglass", title: "没有可显示的 Diff", detail: errorMessage ?? "Agent 尚未产生文件变更。")
            }
        }
        .background { WandAmbientBackground() }
        .navigationTitle("\(attempt.provider.capitalized) Diff")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let sessionId = attempt.sessionId {
                    Button {
                        onOpenSession(sessionId)
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .accessibilityLabel("打开 Agent 会话")
                }
                if !pending.isEmpty {
                    Button {
                        Task { await sendReview() }
                    } label: {
                        Text("发送 \(pending.count) 条")
                    }
                    .disabled(sending)
                }
            }
        }
        .sheet(item: $target) { selected in
            MissionReviewComposer(target: selected) { body in
                await addComment(target: selected, body: body)
            }
        }
        .task { await loadDiff() }
        .alert("Review 操作失败", isPresented: Binding(
            get: { errorMessage != nil && diff != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func diffSummary(_ diff: MissionDiff) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("\(diff.files.count) 个文件", systemImage: "doc.on.doc")
                Spacer()
                Text(String(diff.baseRef.prefix(12)))
                    .font(.system(size: 10, design: .monospaced))
            }
            if diff.truncated {
                Label("Diff 过大，当前只显示前 2 MB。", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
            } else {
                Text("点按代码行可添加审阅意见，意见会先保存在本地任务中。")
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .font(.system(size: 11))
        .padding(12)
    }

    private func diffBody(_ diff: MissionDiff) -> some View {
        let lines = renderMissionDiff(diff.patch)
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Button {
                        if let target = line.target { self.target = target }
                    } label: {
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(diffLineTextColor(line.kind))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .frame(minWidth: 760, maxWidth: .infinity, alignment: .leading)
                            .background(diffLineBackground(line.kind))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(line.target == nil)
                    .accessibilityHint(line.target == nil ? "" : "添加行级审阅意见")
                }
            }
        }
    }

    private func diffLineBackground(_ kind: MissionRenderedDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Theme.success.opacity(0.13)
        case .removed: return Theme.danger.opacity(0.12)
        case .metadata: return Theme.codex.opacity(0.08)
        case .context: return .clear
        }
    }

    private func diffLineTextColor(_ kind: MissionRenderedDiffLine.Kind) -> Color {
        kind == .metadata ? Theme.textMuted : Theme.textPrimary
    }

    private func loadDiff() async {
        loading = true
        do {
            diff = try await api.missionDiff(missionId: mission.id, attemptId: attempt.id)
            if let loaded = try? await api.missions(),
               let current = loaded.first(where: { $0.id == mission.id }) {
                comments = current.comments.filter { $0.attemptId == attempt.id }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func addComment(target: MissionReviewTarget, body: String) async -> Bool {
        do {
            let comment = try await api.addMissionReviewComment(
                missionId: mission.id,
                attemptId: attempt.id,
                filePath: target.filePath,
                line: target.line,
                side: target.side,
                body: body
            )
            comments.append(comment)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func sendReview() async {
        sending = true
        do {
            comments = try await api.sendMissionReview(missionId: mission.id, attemptId: attempt.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        sending = false
    }
}

private struct MissionReviewComposer: View {
    let target: MissionReviewTarget
    let onSubmit: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var reviewText = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("位置") {
                    Text(target.filePath).font(.system(.caption, design: .monospaced))
                    if let line = target.line {
                        LabeledContent("行", value: "\(line) · \(target.side)")
                    }
                }
                Section("审阅意见") {
                    TextEditor(text: $reviewText)
                        .frame(minHeight: 150)
                }
            }
            .navigationTitle("添加 Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            submitting = true
                            if await onSubmit(reviewText.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                            submitting = false
                        }
                    }
                    .disabled(reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MissionCreateView: View {
    let api: WandAPI
    let onCreated: (MissionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var cwd = ""
    @State private var baseRef = ""
    @State private var sharedPaths = ""
    @State private var copyPaths = ""
    @State private var providers: Set<String> = ["claude", "codex"]
    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("标题（可选）", text: $title)
                    TextEditor(text: $prompt)
                        .frame(minHeight: 150)
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("描述要完成的目标、约束和验收方式")
                                    .foregroundColor(Theme.textMuted)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Section("并行 Agent") {
                    ForEach(MissionProviderOption.all) { provider in
                        Button {
                            if providers.contains(provider.id) { providers.remove(provider.id) }
                            else { providers.insert(provider.id) }
                        } label: {
                            HStack {
                                MissionProviderMark(provider: provider.id, color: Theme.textSecondary, size: 22)
                                Text(provider.title).foregroundColor(Theme.textPrimary)
                                Spacer()
                                Image(systemName: providers.contains(provider.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(providers.contains(provider.id) ? Theme.brand : Theme.textMuted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Worktree") {
                    TextField("工作目录", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("基线分支、Tag 或 commit（可选）", text: $baseRef)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("高级路径") {
                    TextField("共享的 gitignored 目录，逗号分隔", text: $sharedPaths)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("复制的 gitignored 路径，逗号分隔", text: $copyPaths)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("共享目录以符号链接接入；复制路径会为每个 Agent 创建独立副本。")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .navigationTitle("新建并行任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await create() } }
                        .disabled(!canCreate || submitting)
                }
            }
        }
        .task {
            if cwd.isEmpty { cwd = (try? await api.serverConfig().defaultCwd) ?? "" }
        }
        .alert("无法创建任务", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var canCreate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !providers.isEmpty
    }

    private func paths(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func create() async {
        submitting = true
        do {
            let mission = try await api.createMission(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
                providers: MissionProviderOption.all.map(\.id).filter { providers.contains($0) },
                baseRef: baseRef.trimmingCharacters(in: .whitespacesAndNewlines),
                sharedDirectories: paths(sharedPaths),
                copyPaths: paths(copyPaths)
            )
            onCreated(mission)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        submitting = false
    }
}

private struct MissionEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(Theme.textMuted)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(WandPrimaryButtonStyle())
                    .frame(maxWidth: 220)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
