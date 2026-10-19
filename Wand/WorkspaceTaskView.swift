import SwiftUI
import UIKit

func workspaceTaskNavigationChrome(taskName: String, workspaceName: String) -> (title: String, subtitle: String?) {
    let task = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
    let workspace = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    if task.isEmpty {
        return (workspace.isEmpty ? "任务" : workspace, nil)
    }
    if workspace.isEmpty || isGenericWorkspaceName(workspace)
        || workspace.compare(task, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
        return (task, nil)
    }
    return (task, workspace)
}

func isGenericWorkspaceName(_ name: String) -> Bool {
    ["全局", "全局任务"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
}

func emptyTaskWorkspaceCaption(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isGenericWorkspaceName(trimmed) else { return nil }
    return trimmed.uppercased()
}

/// The task retains ownership while its selected conversation is shown directly.
/// Other windows remain available through an optional switcher.
func workspaceTaskVisibleSessions(_ sessions: [WorkspaceSessionSummary]) -> [WorkspaceSessionSummary] {
    WorkspaceSessionSummary.splitArchived(sessions).active
}

struct WorkspaceTaskSessionList: View {
    let sessions: [WorkspaceSessionSummary]
    let selectedID: String?
    let onOpen: (WorkspaceSessionSummary) -> Void
    let onMove: (WorkspaceSessionSummary) -> Void
    let onDelete: (WorkspaceSessionSummary) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(sessions.count) 个工作窗口").font(.caption).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 12)
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    HStack(spacing: 4) {
                        Button { onOpen(session) } label: {
                            WorkspaceSessionLabel(session: session,
                                title: TaskListPresentation.listSessionLabel(title: session.title,
                                    providerLabel: session.providerLabel, cwd: session.cwd, index: index),
                                selected: selectedID == session.id)
                                .frame(minHeight: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("task-session-open-" + session.id)
                        Menu {
                            Button("打开", systemImage: "arrow.forward") { onOpen(session) }
                            Button("移动到任务", systemImage: "folder") { onMove(session) }
                            Button("删除终端", systemImage: "trash", role: .destructive) { onDelete(session) }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("终端操作：" + (session.title ?? session.providerLabel))
                    }
                    Divider()
                }
            }.padding(.horizontal, 16).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("task-session-directory")
    }
}

struct WorkspaceTaskView: View {
    let workspace: Workspace
    let task: WorkspaceTask
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    var initialSessionId: String? = nil
    var initialShowPicker = false
    var onExplicitOpen: ((String) -> Void)? = nil
    var onCompletionVisible: ((SessionSnapshot) -> Void)? = nil
    var onOpenTeamRun: ((String) -> Void)? = nil
    var onPickerRequestConsumed: (() -> Void)? = nil
    var onOpenParallel: (() -> Void)? = nil
    var onOpenTaskBoard: (() -> Void)? = nil
    var onOpenChat: (() -> Void)? = nil
    var onSessionPresentationChanged: ((String?) -> Void)? = nil
    @State private var pendingDeleteSession: WorkspaceSessionSummary?
    @State private var moveSessionTarget: WorkspaceSessionSummary?
    @State private var deleteSessionBusy = false
    @State private var deleteSessionError: String?
    @State private var visibleCompletionSnapshot: SessionSnapshot?
    @State private var archivedSessionsExpanded = false
    @State private var presentedSessionID: String?
    @State private var initialSessionIntentConsumed = false
    @State private var sessionSwitcherPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WandAmbientBackground()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let onOpenChat { Button("打开聊天", systemImage: "bubble.left.and.bubble.right", action: onOpenChat) }
                    if let onOpenParallel {
                        Button("并行任务", systemImage: "square.stack.3d.up", action: onOpenParallel)
                            .disabled(taskCwd.isEmpty)
                    }
                    if let onOpenTaskBoard { Button("任务管理", systemImage: "square.grid.2x2", action: onOpenTaskBoard) }
                    Button("刷新任务", systemImage: "arrow.clockwise") { Task { await store.reloadCurrentTask() } }
                    Button("复制工作目录", systemImage: "doc.on.doc") { UIPasteboard.general.string = taskCwd }
                        .disabled(taskCwd.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("任务操作")
            }
        }
        .wandToolbarSurface()
        .sheet(isPresented: $sessionSwitcherPresented) {
            NavigationStack {
                WorkspaceTaskSessionList(sessions: workspaceTaskVisibleSessions(currentDetail?.sessions ?? []),
                    selectedID: store.visibleSessionID, onOpen: { session in
                        sessionSwitcherPresented = false
                        switchTaskSession(session)
                    }, onMove: { session in
                        sessionSwitcherPresented = false
                        moveSessionTarget = session
                    }, onDelete: requestDeleteSession)
                    .navigationTitle("切换工作窗口")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { sessionSwitcherPresented = false }
                        }
                    }
            }
        }
        .sheet(isPresented: pickerBinding) {
            WorkspaceTargetPicker(store: store, taskId: task.id)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $moveSessionTarget) { session in
            SessionMoveSheet(
                store: store,
                sessionId: session.id,
                sessionTitle: sessionLabel(session, index: 0)
            )
            .presentationDetents([.medium, .large])
        }
        .task(id: task.id) {
            let initialIntent = initialSessionIntentConsumed ? nil : initialSessionId
            initialSessionIntentConsumed = true
            presentedSessionID = nil
            await store.openTask(workspace: workspace, task: task, preferredSessionId: initialIntent)
            if let selectedID = store.visibleSessionID { presentTaskSession(selectedID) }
            if initialShowPicker { store.presentTargetPicker(); onPickerRequestConsumed?() }
        }
        .onChange(of: initialSessionId) { _, id in
            guard let id, store.currentTask?.id == task.id else { return }
            presentTaskSession(id)
        }
        .onChange(of: store.visibleSessionID) { _, id in
            guard store.currentTask?.id == task.id else { return }
            if let id, store.taskState.detail?.sessions.contains(where: { $0.id == id }) != true { return }
            syncPresentedSession(id)
        }
        .onChange(of: store.creating) { wasCreating, creating in
            if wasCreating && !creating && !store.pickerPresented,
               let snapshot = store.visibleSnapshot, store.currentTask?.id == task.id {
                presentTaskSession(snapshot.id)
            }
        }
        .onChange(of: initialShowPicker) { _, show in
            if show, store.currentTask?.id == task.id {
                store.presentTargetPicker(); onPickerRequestConsumed?()
            }
        }
        .onChange(of: modalVisible) { _, visible in
            if !visible, let snapshot = visibleCompletionSnapshot { reportCompletionVisible(snapshot) }
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
                // 同 WorkspaceListView：SwiftUI 关闭弹窗时会立刻清空 pendingDeleteSession，
                // 异步工作必须先把目标捕获下来，否则整个删除流程静默无操作。
                guard let target = pendingDeleteSession else { return }
                Task { await confirmDeleteSession(target) }
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
        if case .ready = store.taskState { return true }
        return false
    }

    private var workspaceNavigationTitle: some View {
        let chrome = workspaceTaskNavigationChrome(taskName: task.name, workspaceName: workspace.name)
        return VStack(spacing: 1) {
            Text(chrome.title)
                .font(.wand(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            if let subtitle = chrome.subtitle {
                Text(subtitle)
                    .font(.wand(size: 11, weight: .medium))
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
                archivedSessions(detail.sessions)
                    .padding(.horizontal, 24)
                Spacer(minLength: 54)
                if let caption = emptyTaskWorkspaceCaption(workspace.name) {
                    Text(caption)
                        .font(.wand(size: 11, weight: .semibold))
                        .foregroundColor(Theme.brand)
                        .padding(.bottom, 18)
                }

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
                    .font(.wand(size: 24, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)

                Text("选择 CLI 工具，以及结构化或 PTY，开始这个任务。")
                    .font(.wand(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 8)

                WorkspaceTargetPicker(store: store, taskId: task.id, embedded: true)
                    .padding(.top, 26)
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 7) {
                    Text("工作目录")
                        .font(.wand(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                    Text(detail.cwd)
                        .font(.wand(size: 12, design: .monospaced))
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
            archivedSessions(detail.sessions)
                .padding(.horizontal, 12)
            if let warning = store.layoutWarning {
                warningBanner(warning)
            }
            if workspaceTaskVisibleSessions(detail.sessions).count > 1 {
                Button("切换工作窗口", systemImage: "rectangle.stack") {
                    sessionSwitcherPresented = true
                }
                .padding(.vertical, 8)
            }
            sessionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func archivedSessions(_ sessions: [WorkspaceSessionSummary]) -> some View {
        let archived = WorkspaceSessionSummary.splitArchived(sessions).archived
        if let error = deleteSessionError, pendingDeleteSession == nil {
            Text(error).font(.footnote).foregroundColor(Theme.danger).padding(.vertical, 6)
        }
        if !archived.isEmpty {
            Button {
                withAnimation(reduceMotion ? nil : WandMotion.stateSwap) { archivedSessionsExpanded.toggle() }
            } label: {
                HStack {
                    Label("已归档会话 \(archived.count)", systemImage: "archivebox")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(archivedSessionsExpanded ? 0 : -90))
                }.font(.footnote).foregroundColor(Theme.textMuted).padding(.vertical, 8)
            }.buttonStyle(.plain)
            if archivedSessionsExpanded {
                ForEach(Array(archived.enumerated()), id: \.element.id) { index, session in
                    HStack {
                        Text(sessionLabel(session, index: index)).font(.footnote).lineLimit(1)
                        Spacer()
                        Button("恢复") { Task { await restoreSession(session) } }
                            .font(.footnote).foregroundColor(Theme.brand)
                            .accessibilityLabel("恢复会话 \(sessionLabel(session, index: index))")
                    }.padding(.vertical, 6)
                }
            }
        }
    }

    private func restoreSession(_ session: WorkspaceSessionSummary) async {
        do { try await store.archiveSession(session.id, archived: false); deleteSessionError = nil }
        catch { deleteSessionError = error.localizedDescription }
    }

    private func switchTaskSession(_ session: WorkspaceSessionSummary) {
        if let chat = session.teamChat, let onOpenTeamRun { onOpenTeamRun(chat.runId); return }
        presentTaskSession(session.id)
    }

    private func presentTaskSession(_ id: String) {
        guard store.taskState.detail?.sessions.contains(where: { $0.id == id }) == true else { return }
        if presentedSessionID != id {
            onExplicitOpen?(id)
            syncPresentedSession(id)
        }
        Task { await store.selectSession(id: id) }
    }

    private func syncPresentedSession(_ id: String?) {
        guard presentedSessionID != id else { return }
        presentedSessionID = id
        onSessionPresentationChanged?(id)
    }

    private var currentDetail: WorkspaceTaskDetail? {
        guard store.currentTask?.id == task.id else { return nil }
        return store.taskState.detail
    }

    private var taskCwd: String { currentDetail?.cwd ?? task.worktree?.path ?? workspace.cwd }

    @ViewBuilder
    private var sessionContent: some View {
        if let snapshot = store.visibleSnapshot,
           snapshot.id == presentedSessionID {
            SessionDestinationView(session: snapshot, api: api, showsNavigationChrome: true, onCompletionVisible: { visible in
                visibleCompletionSnapshot = visible
                reportCompletionVisible(visible)
            })
                .id(snapshot.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var modalVisible: Bool {
        sessionSwitcherPresented || store.pickerPresented || moveSessionTarget != nil || pendingDeleteSession != nil
    }

    private func reportCompletionVisible(_ snapshot: SessionSnapshot) {
        guard store.currentTask?.id == task.id, presentedSessionID == snapshot.id, !modalVisible else { return }
        onCompletionVisible?(snapshot)
    }

    private func sessionLabel(_ session: WorkspaceSessionSummary, index: Int) -> String {
        TaskListPresentation.listSessionLabel(
            title: session.title,
            providerLabel: session.providerLabel,
            cwd: session.cwd,
            index: index
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

    private func confirmDeleteSession(_ target: WorkspaceSessionSummary) async {
        guard !deleteSessionBusy else { return }
        deleteSessionBusy = true
        do {
            try await store.deleteSessions([target.id])
            pendingDeleteSession = nil
            deleteSessionError = nil
        } catch {
            pendingDeleteSession = target
            deleteSessionError = error.localizedDescription
        }
        deleteSessionBusy = false
    }
}
