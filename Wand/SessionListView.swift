import SwiftUI
import UniformTypeIdentifiers
import Combine

/// 会话列表：原生渲染 /api/sessions，下拉刷新 + 周期轮询，
/// 对话模式进入原生聊天，PTY 模式进入嵌套网页版对应会话。
struct SessionListView: View {
    private enum ListEntry: Identifiable {
        case session(SessionSnapshot)
        case recoverable(HistorySession)

        var id: String {
            switch self {
            case .session(let session): return "session-\(session.id)"
            case .recoverable(let session): return "recoverable-\(session.id)"
            }
        }

        var sortTimestamp: Double {
            switch self {
            case .session(let session):
                return Self.parseISO8601(session.startedAt)?.timeIntervalSince1970 ?? 0
            case .recoverable(let session):
                if let mtimeMs = session.mtimeMs { return mtimeMs / 1000 }
                return Self.parseISO8601(session.timestamp)?.timeIntervalSince1970 ?? 0
            }
        }

        private static func parseISO8601(_ value: String?) -> Date? {
            guard let value, !value.isEmpty else { return nil }
            return fractionalFormatter.date(from: value) ?? isoFormatter.date(from: value)
        }

        private static let fractionalFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private static let isoFormatter = ISO8601DateFormatter()
    }

    let api: WandAPI

    /// 当前被选中的会话身份（供外层 NavigationSplitView/NavigationStack 驱动 detail 栏）。
    /// 由本视图写入：点行 / 恢复历史 / 新建完成回跳 / 长按图标快捷打开。
    @Binding var selection: String?
    /// 选中会话的完整快照：外层 detail 栏渲染 SessionDestinationView 需要它，
    /// 而外层拿不到本视图私有的 sessions 列表，所以选中时一并回传。
    @Binding var selectedSnapshot: SessionSnapshot?

    @State private var sessions: [SessionSnapshot] = []
    @State private var historySessions: [HistorySession] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var showNewSession = false
    /// 待确认的删除：单条会话删除由左滑按钮直接执行；这里仅保留历史/多选等入口。
    @State private var pendingDelete: PendingDelete?

    private enum PendingDelete: Identifiable {
        case history(HistorySession)
        case sessions([SessionSnapshot])

        var id: String {
            switch self {
            case .history(let h): return "history-\(h.id)"
            case .sessions(let arr): return "sessions-\(arr.map(\.id).joined(separator: ","))"
            }
        }

        var dialogTitle: String {
            switch self {
            case .history: return "删除会话"
            case .sessions(let arr): return "删除 \(arr.count) 个会话"
            }
        }

        var dialogMessage: String {
            switch self {
            case .history: return "此操作无法撤销，确定要删除这条会话吗？"
            case .sessions: return "此操作无法撤销，确定要删除选中的会话吗？"
            }
        }
    }
    /// 当前正在恢复的 provider-aware 历史身份；用于逐行进度和防重复提交。
    @State private var restoringHistoryID: String?
    @State private var selectedSessionIds: Set<String> = []
    @State private var isSelecting = false
    @ObservedObject private var quickActions = QuickActionCoordinator.shared

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    /// 列表页是否可见：离开页面后周期轮询暂停，避免后台白耗电和流量。
    @State private var listVisible = false

    private var visibleSessions: [SessionSnapshot] {
        sessions
    }

    private var recoverableSessions: [HistorySession] {
        let managedIds = Set(sessions.compactMap { session -> String? in
            guard let historyID = session.claudeSessionId else { return nil }
            return HistorySession.identity(provider: session.provider, sessionID: historyID)
        })
        return historySessions
            .filter {
                ($0.hasConversation ?? true)
                    && !($0.managedByWand ?? false)
                    && !managedIds.contains($0.id)
            }
            .sorted {
                ($0.mtimeMs ?? 0) > ($1.mtimeMs ?? 0)
            }
    }

    private var listEntries: [ListEntry] {
        (visibleSessions.map(ListEntry.session) + recoverableSessions.map(ListEntry.recoverable))
            .sorted { $0.sortTimestamp > $1.sortTimestamp }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isSelecting {
                    Text("已选择 \(selectedSessionIds.count) 项")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                } else {
                    Text("会话")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if isSelecting {
                        endSelection()
                    } else {
                        showNewSession = true
                    }
                } label: {
                    Image(systemName: trailingToolbarIcon)
                        .font(.system(size: 20))
                        .foregroundColor(Theme.brand)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView(api: api) { newSession in
                showNewSession = false
                sessions.insert(newSession, at: 0)
                DispatchQueue.main.async {
                    selectSession(id: newSession.id, newSession)
                }
            }
        }
        .task { await load() }
        .onAppear { listVisible = true }
        .onDisappear { listVisible = false }
        .onReceive(refreshTimer) { _ in
            guard listVisible else { return }
            Task { await load(silent: true) }
        }
        // @Published 订阅时会重放当前值，所以冷启动遗留的待处理操作也能在视图出现时接住。
        .onReceive(quickActions.$pending) { _ in
            handleQuickAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandBeginSessionSelection)) { _ in
            isSelecting = true
        }
        .confirmationDialog(
            pendingDelete?.dialogTitle ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingDelete?.dialogMessage ?? "")
        }
        .wandKeyboardShortcuts(sessionListKeyboardShortcuts)
    }

    private var sessionListKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "refresh-sessions",
                title: "刷新会话",
                key: "r",
                modifiers: .command,
                isEnabled: !loading
            ) {
                Task { await load(silent: true) }
            },
            WandKeyboardShortcutAction(
                id: "end-selection",
                title: "退出选择",
                key: .escape,
                modifiers: [],
                isEnabled: isSelecting
            ) {
                endSelection()
            },
        ]
    }

    private var trailingToolbarIcon: String {
        if isSelecting { return "xmark.circle.fill" }
        return "plus.circle.fill"
    }

    /// 统一的「打开会话」入口：同时写 selection 身份和完整快照，
    /// 外层 detail 栈/栏据此渲染。快照可能来自异步拉取，先置身份再回填快照。
    private func selectSession(id: String?, _ snapshot: SessionSnapshot?) {
        selection = id
        selectedSnapshot = snapshot
    }

    private func handleQuickAction() {
        guard let action = quickActions.consume(where: { action in
            switch action {
            case .newSession, .openSession, .showSessions: return true
            case .openWeb: return false
            }
        }) else { return }
        switch action {
        case .newSession:
            selectSession(id: nil, nil)
            showNewSession = true
        case .openSession(let id):
            showNewSession = false
            if let session = sessions.first(where: { $0.id == id }) {
                selectSession(id: id, session)
            } else {
                // 先占住身份，外层 detail 栈推入占位视图，拿到快照后再回填内容。
                selectSession(id: id, nil)
                Task {
                    let snapshot = try? await api.getSession(id: id)
                    if selection == id {
                        selectedSnapshot = snapshot
                    }
                }
            }
        case .showSessions:
            showNewSession = false
            selectSession(id: nil, nil)
        case .openWeb:
            break
        }
    }

    @ViewBuilder private var content: some View {
        if loading && sessions.isEmpty && historySessions.isEmpty {
            ProgressView().tint(Theme.brand)
        } else if let error = loadError, sessions.isEmpty && historySessions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30))
                    .foregroundColor(Theme.textSecondary)
                Text(error)
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await load() } }
                    .buttonStyle(WandSecondaryButtonStyle())
            }
            .padding(32)
        } else if listEntries.isEmpty {
            VStack(spacing: 14) {
                WandBrandMark(size: 52)
                Text("还没有会话")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Button { showNewSession = true } label: {
                    Text("新建会话")
                }
                .buttonStyle(WandPrimaryButtonStyle())
            }
        } else {
            List {
                ForEach(listEntries) { entry in
                    switch entry {
                    case .session(let session):
                        managedSessionRow(session)
                    case .recoverable(let session):
                        recoverableSessionRow(session)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await load(silent: true) }
        }
    }

    private func load(silent: Bool = false) async {
        if !silent { loading = true }
        async let active = try? api.listSessions()
        async let claudeHistory = try? api.listClaudeHistory()
        async let codexHistory = try? api.listCodexHistory()
        let (loadedSessions, loadedClaudeHistory, loadedCodexHistory) = await (
            active,
            claudeHistory,
            codexHistory
        )

        if let loadedSessions {
            sessions = loadedSessions
            SessionPresenceController.shared.reconcile(snapshots: loadedSessions)
            // 同步「最近会话」动态快捷项到长按图标菜单。
            QuickActionCoordinator.updateRecentSessionShortcuts(sessions)
        }

        // 两个历史扫描端点独立容错：单个 provider 瞬时失败时保留它上一轮的
        // 成功结果，同时仍更新会话和另一个 provider，避免列表整体闪空。
        if let loadedClaudeHistory {
            historySessions.removeAll { WandProvider(normalizing: $0.provider) == .claude }
            historySessions += loadedClaudeHistory.map { $0.withProvider(.claude) }
        }
        if let loadedCodexHistory {
            historySessions.removeAll { WandProvider(normalizing: $0.provider) == .codex }
            historySessions += loadedCodexHistory.map { $0.withProvider(.codex) }
        }

        if loadedSessions != nil || loadedClaudeHistory != nil || loadedCodexHistory != nil {
            loadError = nil
        } else if !silent || sessions.isEmpty {
            loadError = "无法刷新会话，请检查服务连接"
        }
        loading = false
    }

    private func managedSessionRow(_ session: SessionSnapshot) -> some View {
        SessionRow(
            session: session,
            selecting: isSelecting,
            selected: selectedSessionIds.contains(session.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggleSelection(session.id)
            } else {
                selectSession(id: session.id, session)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                beginSelection(with: session.id)
            } label: {
                Label("多选会话", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }

    private func recoverableSessionRow(_ session: HistorySession) -> some View {
        Button {
            resume(session)
        } label: {
            HistorySessionRow(
                history: session,
                loading: restoringHistoryID == session.id
            )
        }
        .buttonStyle(.plain)
        .disabled(restoringHistoryID != nil || isSelecting)
        .accessibilityLabel(
            restoringHistoryID == session.id
                ? "正在恢复会话，\(session.firstUserMessage)"
                : "恢复会话，\(session.firstUserMessage)"
        )
        .accessibilityValue(restoringHistoryID == session.id ? "处理中" : "可恢复")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = .history(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                pendingDelete = .history(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }

    private func resume(_ history: HistorySession) {
        guard restoringHistoryID == nil else { return }
        let historyID = history.id
        restoringHistoryID = historyID
        Task {
            do {
                let resumed = try await api.resumeHistory(history)
                historySessions.removeAll { $0.id == history.id }
                sessions.insert(resumed, at: 0)
                selectSession(id: resumed.id, resumed)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            if restoringHistoryID == historyID {
                restoringHistoryID = nil
            }
        }
    }

    /// 用户在确认弹窗里点了「删除」才真正落库：先乐观更新本地 state 让 UI 立刻消失，
    /// 再后台逐个调 API；网络失败时下次 load 会重新拉回。
    private func performDelete() {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil
        switch pending {
        case .history(let h):
            historySessions.removeAll { $0.id == h.id }
            Task { try? await api.deleteHistory(h) }
        case .sessions(let arr):
            sessions.removeAll { snap in arr.contains { $0.id == snap.id } }
            endSelection()
            Task {
                for s in arr { try? await api.deleteSession(id: s.id) }
            }
        }
    }

    private func deleteSession(_ session: SessionSnapshot) {
        sessions.removeAll { $0.id == session.id }
        if selection == session.id {
            selectSession(id: nil, nil)
        }
        Task { try? await api.deleteSession(id: session.id) }
    }

    private var selectionBar: some View {
        HStack {
            Button(selectedSessionIds.count == visibleSessions.count ? "取消全选" : "全选") {
                if selectedSessionIds.count == visibleSessions.count {
                    selectedSessionIds.removeAll()
                } else {
                    selectedSessionIds = Set(visibleSessions.map(\.id))
                }
            }
            Spacer()
            Button(role: .destructive) {
                deleteSelectedSessions()
            } label: {
                Label("删除 \(selectedSessionIds.count)", systemImage: "trash")
            }
            .disabled(selectedSessionIds.isEmpty)
            Spacer()
            Button("完成") { endSelection() }
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider().overlay(Theme.border) }
    }

    private func toggleSelection(_ id: String) {
        if selectedSessionIds.contains(id) {
            selectedSessionIds.remove(id)
        } else {
            selectedSessionIds.insert(id)
        }
    }

    private func beginSelection(with id: String) {
        if !isSelecting { isSelecting = true }
        selectedSessionIds.insert(id)
    }

    private func endSelection() {
        isSelecting = false
        selectedSessionIds.removeAll()
    }

    private func deleteSelectedSessions() {
        let ids = selectedSessionIds
        let targets = visibleSessions.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        pendingDelete = .sessions(targets)
    }
}

extension Notification.Name {
    static let wandBeginSessionSelection = Notification.Name("wandBeginSessionSelection")
}

private extension HistorySession {
    static func identity(provider: String?, sessionID: String) -> String {
        "\(WandProvider.normalize(provider)):\(sessionID)"
    }

    func withProvider(_ provider: WandProvider) -> HistorySession {
        HistorySession(
            claudeSessionId: claudeSessionId,
            cwd: cwd,
            firstUserMessage: firstUserMessage,
            timestamp: timestamp,
            mtimeMs: mtimeMs,
            hasConversation: hasConversation,
            managedByWand: managedByWand,
            provider: provider.rawValue
        )
    }
}

struct SessionDestinationView: View {
    let session: SessionSnapshot
    let api: WandAPI

    @ViewBuilder var body: some View {
        if session.isStructured {
            ChatView(sessionId: session.id, api: api)
        } else {
            PtySessionView(session: session, api: api)
        }
    }
}

/// PTY 会话的原生外壳：套用与 ChatView 一致的原生导航头（provider 徽章 + 标题 +
/// cwd），中间嵌入 embed=terminal 的 WebView 只渲染终端黑窗，底部输入栏走原生组件。
/// 这样 PTY 会话不再是「直接打开整张网页版」，而是和对话模式同样的原生观感，
/// 只是内容区换成了那块黑色终端窗口。
private struct PtySessionView: View {
    let session: SessionSnapshot
    let api: WandAPI

    @StateObject private var store: ChatStore
    @StateObject private var terminalWebModel = WebViewModel()
    @StateObject private var keyboard = KeyboardObserver()
    @StateObject private var speech = SpeechRecognizerService()
    @State private var draft = ""
    @State private var showStopConfirm = false
    @State private var showQuickCommit = false
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var uploadingAttachments = false
    @State private var pendingAttachments: [UploadedFile] = []
    @State private var voicePressed = false
    @State private var voiceCanceling = false
    @State private var draftNeedsExpanded = false
    @State private var voiceHoldWork: DispatchWorkItem?
    @State private var gitStatus: GitStatusResult?
    @State private var quickCommitPhase: QuickCommitToolbarPhase = .idle
    @State private var quickCommitFeedbackToken = 0
    @FocusState private var inputFocused: Bool

    private var ptyBackground: Color {
        Color(red: 0.090, green: 0.071, blue: 0.059)
    }

    init(session: SessionSnapshot, api: WandAPI) {
        self.session = session
        self.api = api
        _store = StateObject(wrappedValue: ChatStore(sessionId: session.id, api: api))
    }

    var body: some View {
        GeometryReader { root in
            ZStack {
                ptyBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        WebContainerView(
                            serverURL: api.baseURL,
                            token: api.token,
                            sessionId: session.id,
                            embedTerminal: true,
                            embedNativeInput: true,
                            webViewModel: terminalWebModel
                        )
                        terminalScaleControls
                            .padding(.top, 10)
                            .padding(.trailing, 10)
                            .opacity(terminalWebModel.phase == .ready ? 1 : 0)
                            .allowsHitTesting(terminalWebModel.phase == .ready)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomBar(safeBottom: root.safeAreaInsets.bottom)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleStatus }
            ToolbarItem(placement: .navigationBarTrailing) {
                GitChangesToolbarButton(status: gitStatus, phase: quickCommitPhase) {
                    showQuickCommit = true
                }
            }
        }
        .toolbarBackground(ptyBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(
                sessionId: session.id,
                api: api,
                onRunning: beginQuickCommitFeedback,
                onCompleted: completeQuickCommitFeedback,
                onFailed: failQuickCommitFeedback
            )
                .presentationDetents([.height(620), .large])
                .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handlePickedAttachments
        )
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { result in
                showPhotoPicker = false
                handlePickedPhotos(result)
            }
        }
        .onAppear {
            store.start()
            refreshGitStatus()
        }
        .onChange(of: showQuickCommit) { _, showing in
            if !showing { refreshGitStatus() }
        }
        .onDisappear { store.shutdown() }
        .overlay(alignment: .top) { connectionBanner }
        .overlay(alignment: .top) { toastView }
        .wandKeyboardShortcuts(ptyKeyboardShortcuts)
    }

    private var ptyKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "focus-input",
                title: "聚焦输入",
                key: "l",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && !inputFocused
            ) {
                inputFocused = true
            },
            WandKeyboardShortcutAction(
                id: "send",
                title: "发送终端命令",
                key: .return,
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && canSend
            ) {
                sendDraft()
            },
            WandKeyboardShortcutAction(
                id: "stop",
                title: "停止任务",
                key: ".",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && store.isResponding
            ) {
                showStopConfirm = true
            },
            WandKeyboardShortcutAction(
                id: "attach-file",
                title: "选择文件",
                key: "o",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && !uploadingAttachments
            ) {
                inputFocused = false
                showFileImporter = true
            },
            WandKeyboardShortcutAction(
                id: "quick-commit",
                title: "快速提交",
                key: "c",
                modifiers: [.command, .shift],
                isEnabled: keyboardShortcutsActive && quickCommitPhase == .idle
            ) {
                showQuickCommit = true
            },
            WandKeyboardShortcutAction(
                id: "refresh-terminal",
                title: "刷新终端",
                key: "r",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && terminalWebModel.phase == .ready
            ) {
                terminalWebModel.refreshEmbeddedTerminal()
            },
            WandKeyboardShortcutAction(
                id: "zoom-terminal-in",
                title: "放大终端",
                key: "=",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && terminalWebModel.phase == .ready
            ) {
                terminalWebModel.adjustEmbeddedTerminalScale(delta: 0.25)
            },
            WandKeyboardShortcutAction(
                id: "zoom-terminal-out",
                title: "缩小终端",
                key: "-",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && terminalWebModel.phase == .ready
            ) {
                terminalWebModel.adjustEmbeddedTerminalScale(delta: -0.25)
            },
            WandKeyboardShortcutAction(
                id: "dismiss-input",
                title: "收起输入",
                key: .escape,
                modifiers: [],
                isEnabled: keyboardShortcutsActive && inputFocused
            ) {
                inputFocused = false
            },
        ]
    }

    private var keyboardShortcutsActive: Bool {
        !showQuickCommit
            && !showFileImporter
            && !showPhotoPicker
            && !showStopConfirm
    }

    private var terminalScaleControls: some View {
        HStack(spacing: 2) {
            terminalScaleButton(systemName: "minus", accessibilityLabel: "缩小终端") {
                terminalWebModel.adjustEmbeddedTerminalScale(delta: -0.25)
            }
            Text(terminalWebModel.terminalScaleLabel)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.92))
                .frame(width: 42, height: 28)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .accessibilityLabel("终端缩放 \(terminalWebModel.terminalScaleLabel)")
            terminalScaleButton(systemName: "plus", accessibilityLabel: "放大终端") {
                terminalWebModel.adjustEmbeddedTerminalScale(delta: 0.25)
            }
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 3)
            terminalScaleButton(systemName: "arrow.clockwise", accessibilityLabel: "刷新终端") {
                terminalWebModel.refreshEmbeddedTerminal()
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.58))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 6)
        .accessibilityElement(children: .contain)
    }

    private func terminalScaleButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color.white.opacity(0.94))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func bottomBar(safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            if voicePressed {
                voiceBubble
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            inputBar
        }
        .padding(.bottom, safeBottom + keyboard.lift)
        .animation(.easeOut(duration: 0.2), value: keyboard.lift)
    }

    private var inputExpanded: Bool {
        composerShouldExpand(
            focused: inputFocused,
            voiceMode: voicePressed,
            contentNeedsSpace: draftNeedsExpanded || !pendingAttachments.isEmpty
        )
    }

    private var inputBar: some View {
        NativeComposerShell(
            expanded: inputExpanded,
            focused: inputFocused,
            onFocusInput: {
                inputFocused = true
            },
            collapsedLeading: { composerActionsMenu },
            inputContent: { ptyTextField },
            collapsedTrailing: {
                trailingButtons
            },
            expandedControls: {
                HStack(spacing: ComposerMetrics.actionSpacing) {
                    composerActionsMenu
                    terminalChip
                    Spacer(minLength: 0)
                    trailingButtons
                }
            }
        )
        .confirmationDialog(
            "确定要停止当前正在运行的任务吗？",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("停止", role: .destructive) { stopPtyInput() }
            Button("取消", role: .cancel) {}
        }
    }

    private var composerActionsMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("从相册选择", systemImage: "photo.on.rectangle")
            }
            .disabled(uploadingAttachments)

            Button {
                showFileImporter = true
            } label: {
                Label("从文件选择", systemImage: "paperclip")
            }
            .disabled(uploadingAttachments)
        } label: {
            if uploadingAttachments {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                    .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
                    .contentShape(Rectangle())
            }
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .accessibilityLabel("更多操作")
    }

    private var terminalGlyph: some View {
        Image(systemName: "terminal")
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
    }

    private var ptyTextField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pendingAttachments.isEmpty {
                PendingAttachmentsPreview(
                    baseURL: api.baseURL,
                    attachments: pendingAttachments,
                    onRemove: { file in
                        pendingAttachments.removeAll { $0.savedPath == file.savedPath }
                    }
                )
            }
            TextField(ptyComposerPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.brand)
                .submitLabel(.send)
                .wandSubmitOnHardwareReturn(isEnabled: { keyboardShortcutsActive && canSend }, perform: sendDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .padding(.leading, inputExpanded ? 6 : 2)
                .padding(.trailing, inputExpanded ? 4 : 0)
                .padding(.vertical, inputExpanded ? 4 : 2)
                .frame(minHeight: inputExpanded ? 32 : 34)
                .contentShape(Rectangle())
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ComposerInputHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                .onPreferenceChange(ComposerInputHeightPreferenceKey.self) { height in
                    draftNeedsExpanded = !draft.isEmpty && height > 36
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerVoiceButton: some View {
        Image(systemName: voicePressed ? "waveform" : "mic")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(voiceCanceling ? Theme.danger : (voicePressed ? Theme.brand : Theme.textSecondary))
            .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
            .background(Circle().fill(Theme.surface.opacity(0.92)))
            .overlay(Circle().stroke(Theme.border.opacity(0.5), lineWidth: 0.8))
            .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
            .contentShape(Circle())
            .gesture(voiceTapOrHoldGesture(onTap: { inputFocused = true }))
            .accessibilityLabel("语音输入")
            .accessibilityValue(voicePressed ? "正在录音" : "长按录音")
    }

    private var terminalChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
            Text("终端")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.textSecondary.opacity(0.10)))
        .overlay(Capsule().stroke(Theme.textSecondary.opacity(0.22), lineWidth: 1))
    }

    @ViewBuilder private var trailingButtons: some View {
        if store.isResponding && !canSend {
            composerVoiceButton
            stopButtonPrimary
        } else {
            if store.isResponding {
                stopButtonSecondary
            }
            composerVoiceButton
            sendButton
        }
    }

    private var stopButtonPrimary: some View {
        Button { showStopConfirm = true } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.surface)
                .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
                .background(Circle().fill(Theme.textPrimary))
                .overlay(Circle().stroke(Theme.border.opacity(0.25), lineWidth: 0.5))
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .accessibilityLabel("停止任务")
    }

    private var stopButtonSecondary: some View {
        Button { showStopConfirm = true } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
                .background(Circle().fill(Theme.danger))
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .accessibilityLabel("停止任务")
    }

    private var sendButton: some View {
        Button(action: sendDraft) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(canSend ? Theme.surface : Theme.textSecondary.opacity(0.55))
                .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
                .background(
                    Circle().fill(canSend ? Theme.textPrimary : Theme.textSecondary.opacity(0.16))
                )
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("发送")
    }

    private var ptyComposerPlaceholder: String {
        if voicePressed {
            return voiceCanceling ? "松开取消" : "松开结束 · 上滑取消"
        }
        return "输入终端命令"
    }

    private var voiceBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: voiceCanceling ? "xmark.circle.fill" : "waveform.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(voiceCanceling ? Theme.danger : Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voiceCanceling ? "松开取消" : (speech.transcript.isEmpty ? "正在聆听…" : speech.transcript))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(voiceCanceling ? Theme.danger : Theme.textPrimary)
                        .lineLimit(3)
                    Text(speech.usingOnDevice ? "端侧识别" : "语音识别")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((voiceCanceling ? Theme.danger : Theme.brand).opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = buildAttachmentPrompt(pendingAttachments, body: draft)
        let restoreDraft = draft
        let restoreAttachments = pendingAttachments
        draft = ""
        pendingAttachments.removeAll()
        sendPtyInput(text, restoreDraft: restoreDraft, restoreAttachments: restoreAttachments)
        inputFocused = true
    }

    private func sendPtyInput(_ text: String, restoreDraft: String, restoreAttachments: [UploadedFile]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await MainActor.run {
                SessionPresenceController.shared.start(
                    sessionId: session.id,
                    title: session.displayTitle,
                    provider: session.provider,
                    taskTitle: store.currentTaskTitle
                )
            }
            do {
                try await store.sendPtyTerminalInput(trimmed)
            } catch {
                await MainActor.run {
                    if draft.isEmpty { draft = restoreDraft }
                    if pendingAttachments.isEmpty { pendingAttachments = restoreAttachments }
                    store.toast = error.localizedDescription
                    SessionPresenceController.shared.end(sessionId: session.id, immediately: true)
                }
            }
        }
    }

    private func stopPtyInput() {
        Task {
            do {
                try await api.sendInput(id: session.id, input: "\u{1B}", view: "terminal", shortcutKey: "esc")
            } catch {
                await MainActor.run {
                    store.toast = error.localizedDescription
                }
            }
        }
    }

    private static let voiceCancelThreshold: CGFloat = 60
    private static let voiceHoldThreshold: TimeInterval = 0.18

    private func voiceTapOrHoldGesture(onTap: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if voiceHoldWork == nil && !voicePressed {
                    let work = DispatchWorkItem {
                        voiceHoldWork = nil
                        startVoiceRecording()
                    }
                    voiceHoldWork = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Self.voiceHoldThreshold,
                        execute: work
                    )
                }
                if voicePressed {
                    voiceCanceling = value.translation.height < -Self.voiceCancelThreshold
                }
            }
            .onEnded { _ in
                if let work = voiceHoldWork {
                    work.cancel()
                    voiceHoldWork = nil
                    onTap()
                    return
                }
                let cancelled = voiceCanceling
                voicePressed = false
                voiceCanceling = false
                speech.stop(cancelled: cancelled) { text in
                    appendTranscriptToDraft(text)
                }
            }
    }

    private func startVoiceRecording() {
        guard !voicePressed else { return }
        voicePressed = true
        voiceCanceling = false
        speech.start { message in
            store.toast = message
            voicePressed = false
            voiceCanceling = false
        }
    }

    private func appendTranscriptToDraft(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var existing = draft
        while let last = existing.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            existing.unicodeScalars.removeLast()
        }
        draft = existing.isEmpty ? clean : existing + " " + clean
    }

    private func refreshGitStatus() {
        Task {
            gitStatus = try? await api.gitStatus(sessionId: session.id)
        }
    }

    private func beginQuickCommitFeedback() {
        quickCommitFeedbackToken += 1
        quickCommitPhase = .loading
    }

    private func completeQuickCommitFeedback(_ message: String) {
        store.toast = message
        let token = quickCommitFeedbackToken + 1
        quickCommitFeedbackToken = token
        quickCommitPhase = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if quickCommitFeedbackToken == token {
                quickCommitPhase = .idle
                refreshGitStatus()
            }
        }
    }

    private func failQuickCommitFeedback(_ message: String) {
        quickCommitFeedbackToken += 1
        quickCommitPhase = .idle
        store.toast = message
        refreshGitStatus()
    }

    private func handlePickedAttachments(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { store.toast = error.localizedDescription }
            return
        }
        uploadAttachments(urls)
    }

    private func handlePickedPhotos(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { store.toast = error.localizedDescription }
            return
        }
        uploadAttachments(urls, cleanupAfterUpload: true)
    }

    private func uploadAttachments(_ urls: [URL], cleanupAfterUpload: Bool = false) {
        uploadingAttachments = true
        Task {
            defer {
                uploadingAttachments = false
                if cleanupAfterUpload {
                    for url in urls {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            do {
                let files = try await api.uploadAttachments(id: session.id, urls: urls)
                pendingAttachments = Array((pendingAttachments + files).suffix(5))
                store.toast = "已上传 \(files.count) 个附件"
            } catch {
                store.toast = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var connectionBanner: some View {
        if !store.connected {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                Text("连接已断开，正在重连…")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Theme.danger)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        if store.toast == toast { store.toast = nil }
                    }
                }
        }
    }

    private var titleStatus: some View {
        HStack(spacing: 8) {
            let provider = store.snapshot?.provider ?? session.provider
            let providerInfo = WandProvider(normalizing: provider)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(providerInfo == .codex ? Theme.codex.opacity(0.24) : Theme.brand.opacity(0.22))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                BrandLogo(provider: provider, color: Color.white.opacity(0.9))
                    .frame(width: 14, height: 14)
            }
            .frame(width: 26, height: 26)

            VStack(spacing: 0) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 175)
                Text(session.cwd?.isEmpty == false ? session.cwd! : "未设置工作目录")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.58))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 175)
            }
        }
        .shadow(color: Color.black.opacity(0.26), radius: 3, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(WandProvider(normalizing: store.snapshot?.provider ?? session.provider).title)，\(session.displayTitle)")
    }
}

// MARK: - 列表行

private struct SessionRow: View {
    let session: SessionSnapshot
    let selecting: Bool
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(selected ? Theme.brand : Theme.textSecondary)
            }

            VStack(spacing: 6) {
                providerMark
                metadataChip(
                        session.isStructured ? "聊天" : "终端",
                        icon: session.isStructured ? "bubble.left.fill" : "terminal.fill",
                        tint: Theme.textSecondary
                    )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(session.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(session.cwd?.isEmpty == false ? session.cwd! : "未设置工作目录")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !durationLabel.isEmpty {
                        Label(durationLabel, systemImage: "clock")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary.opacity(0.9))
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Theme.brand.opacity(0.08) : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? Theme.brand.opacity(0.5) : Theme.border.opacity(0.75), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(selected ? 0.06 : 0.035), radius: 7, y: 2)
    }

    private var providerMark: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [providerTint.opacity(0.16), providerTint.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(providerTint.opacity(0.16), lineWidth: 1)
                    )
                BrandLogo(provider: session.provider, color: providerTint.opacity(0.88))
                    .frame(width: 20, height: 20)
            }
            .frame(width: 44, height: 44)

            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
                .padding(2)
                .background(Circle().fill(Theme.surface.opacity(0.82)))
        }
        .frame(width: 48, height: 48, alignment: .topLeading)
        .accessibilityLabel("\(session.providerLabel)，\(statusLabel)")
    }

    private func metadataChip(_ text: String, icon: String?, tint: Color) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.1)))
    }

    private var providerTint: Color {
        WandProvider(normalizing: session.provider) == .codex ? Theme.codex : Theme.brand
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private var durationLabel: String {
        guard let raw = session.startedAt, let started = Self.isoFormatter.date(from: raw) else { return "" }
        let ended = session.endedAt.flatMap(Self.isoFormatter.date(from:)) ?? Date()
        let seconds = max(0, Int(ended.timeIntervalSince(started)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    private var statusTint: Color {
        if session.hasPendingPermission { return .orange }
        switch session.status ?? "" {
        case "running": return session.isResponding ? .green : Theme.brand
        case "idle": return Theme.brand.opacity(0.6)
        default: return .gray
        }
    }

    private var statusLabel: String {
        if session.hasPendingPermission { return "待授权" }
        if session.isResponding { return "回复中" }
        switch session.status ?? "" {
        case "running": return "运行中"
        case "idle": return "空闲"
        case "exited", "stopped": return "已结束"
        case "failed": return "失败"
        default:
            if let status = session.status, !status.isEmpty { return status }
            return "未知"
        }
    }
}

private struct HistorySessionRow: View {
    let history: HistorySession
    let loading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [providerTint.opacity(0.2), providerTint.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(providerTint)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 8) {
                Text(history.firstUserMessage.isEmpty ? "空会话" : history.firstUserMessage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)

                if !relativeTime.isEmpty {
                    Label(relativeTime, systemImage: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.textSecondary.opacity(0.08)))
                }

                if !history.cwd.isEmpty {
                    Text(history.cwd)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if loading {
                ProgressView()
                    .tint(providerTint)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border.opacity(0.75), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 7, y: 2)
    }

    private var providerTint: Color {
        WandProvider(normalizing: history.provider) == .codex ? Theme.codex : Theme.brand
    }

    // 复用单例 formatter：构造 ISO8601DateFormatter / RelativeDateTimeFormatter 很贵，
    // 历史列表上百行各 new 一个会卡主线程。都在主线程渲染，static 复用安全。
    private static let isoFormatter = ISO8601DateFormatter()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    private var relativeTime: String {
        guard let timestamp = history.timestamp else { return "" }
        guard let date = Self.isoFormatter.date(from: timestamp) else { return "" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
