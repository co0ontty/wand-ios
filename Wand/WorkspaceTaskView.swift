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
    let text: Color
    let muted: Color
    let plusFill: Color

    static func palette(terminalChrome: Bool) -> SessionStripPalette {
        if terminalChrome {
            return SessionStripPalette(
                background: Theme.terminalBackground,
                chipFill: Color.white.opacity(0.07),
                chipBorder: Color.white.opacity(0.14),
                text: Theme.terminalText.opacity(0.78),
                muted: Theme.terminalText.opacity(0.45),
                plusFill: Color.white.opacity(0.06)
            )
        }
        return SessionStripPalette(
            background: Theme.background,
            chipFill: Theme.surface,
            chipBorder: Theme.border,
            text: Theme.textSecondary,
            muted: Theme.textMuted,
            plusFill: Theme.surface
        )
    }
}

struct WorkspaceTaskView: View {
    let workspace: Workspace
    let task: WorkspaceTask
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    @State private var pendingDeleteSession: WorkspaceSessionSummary?

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
            set: { if !$0 { pendingDeleteSession = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeleteSession = nil }
            Button("删除", role: .destructive) {
                if let id = pendingDeleteSession?.id {
                    Task { try? await store.deleteSessions([id]) }
                }
                pendingDeleteSession = nil
            }
        } message: {
            Text("终端会结束并被删除，此操作无法撤销。")
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
        }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    let selected = store.visibleSessionID == session.id
                    HStack(spacing: 0) {
                        Button {
                            Task { await store.selectSession(id: session.id) }
                        } label: {
                            HStack(spacing: 7) {
                                BrandLogo(
                                    provider: session.provider ?? "terminal",
                                    color: selected ? Theme.brand : palette.text
                                )
                                .frame(width: 14, height: 14)
                                Text(sessionLabel(session, index: index))
                                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                    .lineLimit(1)
                                    .foregroundColor(selected ? Theme.brand : palette.text)
                                if ["initializing", "running", "thinking"].contains(session.status ?? "") {
                                    Circle()
                                        .fill(Theme.success)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 6)
                            .frame(height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("工作窗口 \(sessionLabel(session, index: index))")
                        .accessibilityAddTraits(selected ? .isSelected : [])

                        Button {
                            pendingDeleteSession = session
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(palette.muted)
                                .frame(width: 22, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除终端 \(sessionLabel(session, index: index))")
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Theme.brand.opacity(0.16) : palette.chipFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? Theme.brand.opacity(0.55) : palette.chipBorder, lineWidth: 1)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeleteSession = session
                        } label: {
                            Label("删除终端", systemImage: "trash")
                        }
                    }
                }

                Button { store.presentTargetPicker() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.brand)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(palette.plusFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(palette.chipBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建工作窗口")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(palette.background)
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
}
