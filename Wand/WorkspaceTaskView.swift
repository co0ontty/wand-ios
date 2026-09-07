import SwiftUI

func workspaceTaskNavigationChrome(taskName: String, workspaceName: String) -> (title: String, subtitle: String?) {
    let task = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
    let workspace = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    if task.isEmpty {
        return (workspace.isEmpty ? "任务" : workspace, nil)
    }
    if workspace.isEmpty || workspace.compare(task, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
        return (task, nil)
    }
    return (task, workspace)
}

/// 任务 Tab 条的铬色：结构化对话跟随亮暗主题；PTY 终端页固定深色铬，
/// 与下方终端视口 / 深色导航栏保持一致，避免浅色主题下 Tab 条孤立发白。
struct SessionStripPalette {
    let background: Color
    let chipFill: Color
    let chipBorder: Color
    let selectedFill: Color
    let selectedBorder: Color
    let text: Color
    let selectedText: Color
    let muted: Color
    let plusFill: Color

    static func palette(terminalChrome: Bool) -> SessionStripPalette {
        if terminalChrome {
            return SessionStripPalette(
                background: Theme.terminalBackground,
                chipFill: Color.white.opacity(0.07),
                chipBorder: Color.white.opacity(0.14),
                selectedFill: Theme.brand.opacity(0.22),
                selectedBorder: Theme.brand.opacity(0.55),
                text: Theme.terminalText.opacity(0.78),
                selectedText: Theme.terminalText,
                muted: Theme.terminalText.opacity(0.45),
                plusFill: Color.white.opacity(0.06)
            )
        }
        return SessionStripPalette(
            background: Theme.background,
            chipFill: Theme.surface,
            chipBorder: Theme.border,
            selectedFill: Theme.brand.opacity(0.16),
            selectedBorder: Theme.brand.opacity(0.55),
            text: Theme.textSecondary,
            selectedText: Theme.textPrimary,
            muted: Theme.textMuted,
            plusFill: Theme.surface
        )
    }
}

func sessionTabTitleMaxWidth(selected: Bool) -> CGFloat {
    selected ? 168 : 112
}

/// 左滑切到下一个工作窗口，右滑回到上一个。位移不足阈值时不切换。
func taskSessionSwipeTarget(
    sessions: [WorkspaceSessionSummary],
    currentSessionId: String,
    horizontalTranslation: CGFloat,
    minDistance: CGFloat = 72
) -> WorkspaceSessionSummary? {
    guard abs(horizontalTranslation) >= minDistance else { return nil }
    guard let currentIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return nil }
    let targetIndex = currentIndex + (horizontalTranslation < 0 ? 1 : -1)
    guard sessions.indices.contains(targetIndex) else { return nil }
    return sessions[targetIndex]
}

func taskSessionTransitionDirection(
    fromSessionId: String?,
    toSessionId: String?,
    sessions: [WorkspaceSessionSummary]
) -> Int? {
    guard let fromSessionId, let toSessionId, fromSessionId != toSessionId else { return nil }
    guard let fromIndex = sessions.firstIndex(where: { $0.id == fromSessionId }),
          let toIndex = sessions.firstIndex(where: { $0.id == toSessionId }),
          fromIndex != toIndex else { return nil }
    return toIndex > fromIndex ? 1 : -1
}

struct WorkspaceTaskView: View {
    let workspace: Workspace
    let task: WorkspaceTask
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    @State private var pendingDeleteSession: WorkspaceSessionSummary?
    @State private var deleteSessionBusy = false
    @State private var deleteSessionError: String?

    var body: some View {
        ZStack {
            WandAmbientBackground()
            content
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                workspaceNavigationTitle
            }
            .sharedBackgroundVisibility(.hidden)
            if showsToolbarPlus {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.presentTargetPicker() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 19))
                            .foregroundColor(Theme.brand)
                    }
                    .disabled(store.creating)
                    .accessibilityLabel("新建工作窗口")
                }
            }
        }
        .wandToolbarSurface()
        .sheet(isPresented: pickerBinding) {
            WorkspaceTargetPicker(store: store, taskId: task.id)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task(id: task.id) {
            await store.openTask(workspace: workspace, task: task)
        }
        .alert("删除终端？", isPresented: Binding(
            get: { pendingDeleteSession != nil },
            set: { if !$0 && !deleteSessionBusy { pendingDeleteSession = nil; deleteSessionError = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingDeleteSession = nil
                deleteSessionError = nil
            }
            Button(deleteSessionBusy ? "删除中…" : "删除", role: .destructive) {
                Task { await confirmDeleteSession() }
            }
            .disabled(deleteSessionBusy)
        } message: {
            if let deleteSessionError {
                Text(deleteSessionError)
            } else if let session = pendingDeleteSession {
                Text("终端「\(sessionLabel(session, index: 0))」会结束并被删除，此操作无法撤销。")
            } else {
                Text("终端会结束并被删除，此操作无法撤销。")
            }
        }
    }

    private var showsToolbarPlus: Bool {
        guard store.currentTask?.id == task.id else { return false }
        if case .empty = store.taskState { return true }
        return false
    }

    private var workspaceNavigationTitle: some View {
        let chrome = workspaceTaskNavigationChrome(taskName: task.name, workspaceName: workspace.name)
        return VStack(spacing: 1) {
            Text(chrome.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            if let subtitle = chrome.subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var pickerBinding: Binding<Bool> {
        Binding(
            get: { store.pickerPresented && store.currentTask?.id == task.id },
            set: { presented in if !presented { store.dismissTargetPicker() } }
        )
    }

    @ViewBuilder
    private var content: some View {
        if store.currentTask?.id != task.id {
            loadingState("正在打开任务…")
        } else {
            switch store.taskState {
            case .idle, .loading:
                loadingState("正在恢复任务上下文…")
            case .failed(let message):
                errorState(message)
            case .empty(let detail):
                emptyTask(detail)
            case .ready(let detail):
                readyTask(detail)
            }
        }
    }

    private func emptyTask(_ detail: WorkspaceTaskDetail) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 54)
                Text(workspace.name.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.brand)
                    .padding(.bottom, 18)

                Image(systemName: "terminal")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .frame(width: 68, height: 68)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.brand.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.brand.opacity(0.28), lineWidth: 1)
                    )
                    .padding(.bottom, 20)

                Text(detail.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)

                Text(detail.isIsolated ? "独立 worktree 已就绪" : "在任务目录中运行")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 8)

                Button {
                    store.presentTargetPicker()
                } label: {
                    Label("选择工作窗口", systemImage: "plus")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .padding(.top, 26)
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 7) {
                    Text("工作目录")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                    Text(detail.cwd)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.top, 24)

                if let warning = detail.worktreeError, !warning.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                }
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func readyTask(_ detail: WorkspaceTaskDetail) -> some View {
        VStack(spacing: 0) {
            if let warning = store.layoutWarning {
                warningBanner(warning)
            }
            // PTY 终端页固定深色铬（terminalBackground + 深色导航栏），Tab 条必须跟随
            // 当前会话的铬色，否则浅色主题下会出现「页面全黑、Tab 条还是米白」的割裂。
            sessionStrip(detail.sessions, palette: SessionStripPalette.palette(terminalChrome: showsTerminalChrome))
            Divider().overlay(showsTerminalChrome ? AnyShapeStyle(Color.white.opacity(0.12)) : AnyShapeStyle(Theme.border))
            sessionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func switchTaskSession(_ session: WorkspaceSessionSummary) {
        Task { await store.selectSession(id: session.id) }
    }

    /// 当前可见会话是否为 PTY 终端（终端页固定深色铬；结构化对话跟随亮暗主题）。
    private var showsTerminalChrome: Bool {
        if let snapshot = store.visibleSnapshot, snapshot.id == store.visibleSessionID {
            return !snapshot.isStructured
        }
        guard let id = store.visibleSessionID,
              let summary = currentDetail?.sessions.first(where: { $0.id == id }) else { return false }
        return (summary.sessionKind ?? "pty") != "structured"
    }

    private var currentDetail: WorkspaceTaskDetail? {
        if case .ready(let detail) = store.taskState { return detail }
        return nil
    }

    private func sessionStrip(_ sessions: [WorkspaceSessionSummary], palette: SessionStripPalette) -> some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            sessionTab(session, index: index, palette: palette)
                                .id(session.id)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 8)
                }
                .onAppear { scrollSessionTab(proxy, id: store.visibleSessionID, animated: false) }
                .onChange(of: store.visibleSessionID) { _, id in
                    scrollSessionTab(proxy, id: id, animated: true)
                }
            }
            sessionAddButton(palette: palette)
                .padding(.trailing, 10)
        }
        .background(palette.background)
    }

    private func scrollSessionTab(_ proxy: ScrollViewProxy, id: String?, animated: Bool) {
        guard let id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func sessionTab(
        _ session: WorkspaceSessionSummary,
        index: Int,
        palette: SessionStripPalette
    ) -> some View {
        let selected = store.visibleSessionID == session.id
        let label = sessionLabel(session, index: index)
        return HStack(spacing: 0) {
            Button {
                switchTaskSession(session)
            } label: {
                HStack(spacing: 7) {
                    BrandLogo(
                        provider: session.provider ?? "terminal",
                        color: selected ? Theme.brand : palette.text
                    )
                    .frame(width: 14, height: 14)
                    Text(label)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundColor(selected ? palette.selectedText : palette.text)
                        .frame(maxWidth: sessionTabTitleMaxWidth(selected: selected), alignment: .leading)
                    if ["running", "thinking"].contains(session.activityStatus) {
                        Circle()
                            .fill(Theme.success)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, selected ? 2 : 10)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "当前工作窗口 \(label)" : "切换到 \(label)")
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected {
                Button {
                    requestDeleteSession(session)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(palette.muted)
                        .frame(width: 22, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除终端 \(label)")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? palette.selectedFill : palette.chipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? palette.selectedBorder : palette.chipBorder, lineWidth: 1)
        )
        .contextMenu {
            Button(role: .destructive) {
                requestDeleteSession(session)
            } label: {
                Label("删除终端", systemImage: "trash")
            }
        }
    }

    private func sessionAddButton(palette: SessionStripPalette) -> some View {
        Button { store.presentTargetPicker() } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(store.creating ? palette.muted : Theme.brand)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.plusFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.chipBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(store.creating)
        .accessibilityLabel("新建工作窗口")
    }

    @ViewBuilder
    private var sessionContent: some View {
        if let snapshot = store.visibleSnapshot,
           snapshot.id == store.visibleSessionID {
            SessionDestinationView(session: snapshot, api: api, showsNavigationChrome: false)
                .id(snapshot.id)
        } else if store.sessionLoading {
            loadingState("正在加载工作窗口…")
        } else if let error = store.sessionError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.danger)
                Text(error)
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if let id = store.visibleSessionID {
                    Button("重试") { Task { await store.selectSession(id: id) } }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loadingState("正在选择工作窗口…")
        }
    }

    private func sessionLabel(_ session: WorkspaceSessionSummary, index: Int) -> String {
        TaskListPresentation.listSessionLabel(
            title: session.title,
            providerLabel: session.providerLabel,
            cwd: session.cwd,
            index: index,
            parentNames: [workspace.name, task.name]
        )
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            Text(message)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button { store.clearLayoutWarning() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .accessibilityLabel("关闭提示")
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.brand.opacity(0.08))
    }

    private func loadingState(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.brand)
            Text(text)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(Theme.textSecondary)
            Text(message)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await store.reloadCurrentTask() } }
                .buttonStyle(WandSecondaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestDeleteSession(_ session: WorkspaceSessionSummary) {
        deleteSessionError = nil
        pendingDeleteSession = session
    }

    private func confirmDeleteSession() async {
        guard let target = pendingDeleteSession, !deleteSessionBusy else { return }
        deleteSessionBusy = true
        do {
            try await store.deleteSessions([target.id])
            pendingDeleteSession = nil
            deleteSessionError = nil
        } catch {
            deleteSessionError = error.localizedDescription
        }
        deleteSessionBusy = false
    }
}
