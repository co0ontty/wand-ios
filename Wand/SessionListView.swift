import SwiftUI
import UniformTypeIdentifiers

/// 会话列表：原生渲染 /api/sessions，下拉刷新 + 周期轮询，
/// 对话模式进入原生聊天，PTY 模式进入嵌套网页版对应会话。
struct SessionListView: View {
    private enum SessionScope: String {
        case active
        case history
    }

    let api: WandAPI

    @State private var sessions: [SessionSnapshot] = []
    @State private var historySessions: [HistorySession] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var showNewSession = false
    @State private var scope: SessionScope = .active
    @State private var showClearHistoryConfirmation = false
    /// 待确认的删除：拦截所有删除入口（滑动 / 多选 / 取消选择等），
    /// 在用户二次确认后才真正调用 API；防误触清掉正在用的会话。
    @State private var pendingDelete: PendingDelete?

    private enum PendingDelete: Identifiable {
        case session(SessionSnapshot)
        case history(HistorySession)
        case sessions([SessionSnapshot])

        var id: String {
            switch self {
            case .session(let s): return "session-\(s.id)"
            case .history(let h): return "history-\(h.id)"
            case .sessions(let arr): return "sessions-\(arr.map(\.id).joined(separator: ","))"
            }
        }

        var dialogTitle: String {
            switch self {
            case .session: return "删除会话"
            case .history: return "删除历史会话"
            case .sessions(let arr): return "删除 \(arr.count) 个会话"
            }
        }

        var dialogMessage: String {
            switch self {
            case .session: return "此操作无法撤销，确定要删除这个会话吗？"
            case .history: return "此操作无法撤销，确定要删除这条历史会话吗？"
            case .sessions: return "此操作无法撤销，确定要删除选中的会话吗？"
            }
        }
    }
    @State private var historyActionInProgress = false
    @State private var selectedSessionIds: Set<String> = []
    @State private var isSelecting = false
    /// 长按图标快捷操作 / 新建完成后的程序化跳转目标。
    @State private var quickOpenSession: SessionSnapshot?
    @ObservedObject private var quickActions = QuickActionCoordinator.shared

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    /// 列表页是否可见：离开页面后周期轮询暂停，避免后台白耗电和流量。
    @State private var listVisible = false

    private var visibleSessions: [SessionSnapshot] {
        sessions.filter { !($0.archived ?? false) }
    }

    private var visibleHistorySessions: [HistorySession] {
        let managedIds = Set(sessions.compactMap(\.claudeSessionId))
        return historySessions
            .filter {
                ($0.hasConversation ?? true)
                    && !($0.managedByWand ?? false)
                    && !managedIds.contains($0.claudeSessionId)
            }
            .sorted {
                ($0.mtimeMs ?? 0) > ($1.mtimeMs ?? 0)
            }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // 隐藏的程序化跳转链接：快捷操作「继续会话」用。
            NavigationLink(isActive: quickOpenActive) {
                if let session = quickOpenSession {
                    // 必须按 session.id 绑定身份：本视图只有这一个隐藏 NavigationLink 承接
                    // 所有会话跳转，结构上是同一节点。不加 .id 时 SwiftUI 会复用上一个会话的
                    // 视图身份，ChatView 里的 @StateObject ChatStore 只在首次身份创建时求值，
                    // 第二个会话拿到的仍是上一个会话的 store（started=true → start() no-op，
                    // socket 不重连、快照不重拉），表现为打开后没有数据。
                    SessionDestinationView(session: session, api: api)
                        .id(session.id)
                } else {
                    EmptyView()
                }
            } label: { EmptyView() }
                .hidden()
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
                    Picker("会话范围", selection: $scope) {
                        Text("进行中").tag(SessionScope.active)
                        Text("历史会话").tag(SessionScope.history)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if isSelecting {
                        endSelection()
                    } else if scope == .history {
                        showClearHistoryConfirmation = true
                    } else {
                        showNewSession = true
                    }
                } label: {
                    Image(systemName: trailingToolbarIcon)
                        .font(.system(size: 20))
                        .foregroundColor(scope == .history && !isSelecting ? .red : Theme.brand)
                }
                .disabled(scope == .history && visibleHistorySessions.isEmpty)
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
                    quickOpenSession = newSession
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
        .onChange(of: scope) { _ in
            endSelection()
            Task { await load(silent: true) }
        }
        .confirmationDialog(
            "确认清空全部历史会话？",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部 \(visibleHistorySessions.count) 条历史会话", role: .destructive) {
                clearAllHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机 Claude 和 Codex 的历史会话文件，无法撤销。")
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
    }

    private var trailingToolbarIcon: String {
        if isSelecting { return "xmark.circle.fill" }
        return scope == .history ? "trash.circle.fill" : "plus.circle.fill"
    }

    private var quickOpenActive: Binding<Bool> {
        Binding(
            get: { quickOpenSession != nil },
            set: { if !$0 { quickOpenSession = nil } }
        )
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
            quickOpenSession = nil
            showNewSession = true
        case .openSession(let id):
            showNewSession = false
            if let session = sessions.first(where: { $0.id == id }) {
                quickOpenSession = session
            } else {
                Task {
                    quickOpenSession = try? await api.getSession(id: id)
                }
            }
        case .showSessions:
            showNewSession = false
            quickOpenSession = nil
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
        } else if scope == .history {
            historyContent
        } else if visibleSessions.isEmpty {
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
                ForEach(visibleSessions) { session in
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
                            quickOpenSession = session
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = .session(session)
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
                            pendingDelete = .session(session)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await load(silent: true) }
        }
    }

    private func load(silent: Bool = false) async {
        if !silent { loading = true }
        do {
            async let active = api.listSessions()
            async let claudeHistory = api.listClaudeHistory()
            async let codexHistory = api.listCodexHistory()
            let (loadedSessions, loadedClaudeHistory, loadedCodexHistory) = try await (active, claudeHistory, codexHistory)
            sessions = loadedSessions
            SessionPresenceController.shared.reconcile(snapshots: loadedSessions)
            historySessions = loadedClaudeHistory.map { history in
                HistorySession(
                    claudeSessionId: history.claudeSessionId,
                    cwd: history.cwd,
                    firstUserMessage: history.firstUserMessage,
                    timestamp: history.timestamp,
                    mtimeMs: history.mtimeMs,
                    hasConversation: history.hasConversation,
                    managedByWand: history.managedByWand,
                    provider: "claude"
                )
            } + loadedCodexHistory
            loadError = nil
            // 同步「最近会话」动态快捷项到长按图标菜单。
            QuickActionCoordinator.updateRecentSessionShortcuts(sessions)
        } catch {
            if !silent || sessions.isEmpty {
                loadError = error.localizedDescription
            }
        }
        loading = false
    }

    @ViewBuilder private var historyContent: some View {
        if visibleHistorySessions.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(Theme.textSecondary)
                Text("没有历史会话")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text("Claude 和 Codex 的本地历史会话会显示在这里")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        } else {
            List {
                ForEach(visibleHistorySessions) { history in
                    Button {
                        resume(history)
                    } label: {
                        HistorySessionRow(history: history)
                    }
                    .buttonStyle(.plain)
                    .disabled(historyActionInProgress)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = .history(history)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDelete = .history(history)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await load(silent: true) }
        }
    }

    private func resume(_ history: HistorySession) {
        guard !historyActionInProgress else { return }
        historyActionInProgress = true
        Task {
            do {
                let resumed = try await api.resumeHistory(history)
                historySessions.removeAll { $0.id == history.id }
                sessions.insert(resumed, at: 0)
                quickOpenSession = resumed
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            historyActionInProgress = false
        }
    }

    /// 用户在确认弹窗里点了「删除」才真正落库：先乐观更新本地 state 让 UI 立刻消失，
    /// 再后台逐个调 API；网络失败时下次 load 会重新拉回。
    private func performDelete() {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil
        switch pending {
        case .session(let s):
            sessions.removeAll { $0.id == s.id }
            Task { try? await api.deleteSession(id: s.id) }
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

    private func clearAllHistory() {
        let targets = visibleHistorySessions
        guard !targets.isEmpty else { return }
        historySessions.removeAll { history in targets.contains { $0.id == history.id } }
        Task {
            let claudeIds = targets.filter { $0.provider != "codex" }.map(\.id)
            let codexIds = targets.filter { $0.provider == "codex" }.map(\.id)
            try? await api.deleteHistoryBatch(provider: "claude", ids: claudeIds)
            try? await api.deleteHistoryBatch(provider: "codex", ids: codexIds)
        }
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

private struct SessionDestinationView: View {
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

struct NativeComposerShell<CollapsedLeading: View, InputContent: View, CollapsedTrailing: View, ExpandedControls: View>: View {
    let expanded: Bool
    let focused: Bool
    let onFocusInput: () -> Void
    @ViewBuilder let collapsedLeading: () -> CollapsedLeading
    @ViewBuilder let inputContent: () -> InputContent
    @ViewBuilder let collapsedTrailing: () -> CollapsedTrailing
    @ViewBuilder let expandedControls: () -> ExpandedControls

    var body: some View {
        let cornerRadius: CGFloat = expanded ? 28 : 24
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return VStack(alignment: .leading, spacing: expanded ? 10 : 0) {
            HStack(alignment: expanded ? .bottom : .center, spacing: 8) {
                if !expanded {
                    collapsedLeading()
                }
                inputContent()
                if !expanded {
                    collapsedTrailing()
                }
            }
            if expanded {
                expandedControls()
            }
        }
        .padding(.horizontal, expanded ? 10 : 9)
        .padding(.vertical, expanded ? 9 : 4)
        .background(.ultraThinMaterial, in: shape)
        .background {
            shape
                .fill(Theme.surface.opacity(expanded ? 0.58 : 0.48))
        }
        .overlay {
            shape
                .stroke(Theme.border.opacity(expanded ? 0.42 : 0.32), lineWidth: 0.8)
        }
        .overlay(alignment: .top) {
            shape
                .stroke(Color.white.opacity(expanded ? 0.36 : 0.28), lineWidth: 0.7)
                .blendMode(.screen)
        }
        .overlay {
            if focused {
                shape
                    .stroke(Theme.brand.opacity(0.28), lineWidth: 1)
            }
        }
        .contentShape(shape)
        .simultaneousGesture(
            TapGesture().onEnded {
                onFocusInput()
            }
        )
        .compositingGroup()
        .shadow(color: Color.black.opacity(expanded ? 0.14 : 0.08), radius: expanded ? 22 : 12, x: 0, y: expanded ? 10 : 4)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.18), value: expanded)
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
    @State private var voiceMode = false
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
        .onChange(of: showQuickCommit) { showing in
            if !showing { refreshGitStatus() }
        }
        .onDisappear { store.shutdown() }
        .overlay(alignment: .top) { connectionBanner }
        .overlay(alignment: .top) { toastView }
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
        inputFocused || voiceMode || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private var inputBar: some View {
        NativeComposerShell(
            expanded: inputExpanded,
            focused: inputFocused,
            onFocusInput: {
                if !voiceMode { inputFocused = true }
            },
            collapsedLeading: { composerActionsMenu },
            inputContent: { ptyTextField },
            collapsedTrailing: {
                micButton
                trailingButtons
            },
            expandedControls: {
                HStack(spacing: 8) {
                    composerActionsMenu
                    terminalChip
                    Spacer(minLength: 0)
                    micButton
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
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
        }
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
            if !pendingAttachments.isEmpty && !voiceMode {
                PendingAttachmentsPreview(
                    baseURL: api.baseURL,
                    attachments: pendingAttachments,
                    onRemove: { file in
                        pendingAttachments.removeAll { $0.savedPath == file.savedPath }
                    }
                )
            }
            if voiceMode {
                voiceHoldField
            } else {
                TextField("输入到终端…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .tint(Theme.brand)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .padding(.leading, inputExpanded ? 6 : 2)
                    .padding(.trailing, inputExpanded ? 4 : 0)
                    .padding(.vertical, inputExpanded ? 4 : 2)
                    .frame(minHeight: inputExpanded ? 32 : 34)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            inputFocused = true
                        }
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            stopButtonPrimary
        } else {
            if store.isResponding {
                stopButtonSecondary
            }
            sendButton
        }
    }

    private var stopButtonPrimary: some View {
        Button { showStopConfirm = true } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.surface)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.textPrimary))
                .overlay(Circle().stroke(Theme.border.opacity(0.25), lineWidth: 0.5))
        }
        .accessibilityLabel("停止任务")
    }

    private var stopButtonSecondary: some View {
        Button { showStopConfirm = true } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.danger))
        }
        .accessibilityLabel("停止任务")
    }

    private var sendButton: some View {
        Button(action: sendDraft) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(canSend ? Theme.surface : Theme.textSecondary.opacity(0.55))
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(canSend ? Theme.textPrimary : Theme.textSecondary.opacity(0.16))
                )
        }
        .disabled(!canSend)
        .accessibilityLabel("发送")
    }

    private var micButton: some View {
        Image(systemName: micButtonSymbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(voicePressed ? .white : Theme.brand)
            .frame(width: 32, height: 32)
            .background(
                Circle().fill(
                    voicePressed
                        ? (voiceCanceling ? Theme.danger : Theme.brand)
                        : Theme.brand.opacity(0.12)
                )
            )
            .scaleEffect(voicePressed ? 1.1 : 1)
            .animation(.easeInOut(duration: 0.15), value: voicePressed)
            .animation(.easeInOut(duration: 0.15), value: voiceCanceling)
            .gesture(voiceTapOrHoldGesture(onTap: {
                voiceMode.toggle()
                if voiceMode {
                    inputFocused = false
                    speech.prewarm()
                } else {
                    DispatchQueue.main.async { inputFocused = true }
                }
            }))
            .accessibilityLabel(voiceMode ? "切回键盘输入" : "轻点切语音模式，长按说话")
    }

    private var micButtonSymbol: String {
        if speech.isRecording { return "waveform" }
        return voiceMode && !voicePressed ? "keyboard" : "mic"
    }

    private var voiceHoldField: some View {
        HStack {
            if voicePressed || draft.isEmpty {
                Spacer(minLength: 0)
            }
            Group {
                if voicePressed {
                    Text(voiceCanceling ? "松开手指，取消输入" : "松开结束 · 上滑取消")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(voiceCanceling ? Theme.danger : Theme.brand)
                } else if draft.isEmpty {
                    Text("按住说话")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Text(draft)
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    voicePressed
                        ? (voiceCanceling ? Theme.danger.opacity(0.14) : Theme.brand.opacity(0.12))
                        : Color.clear
                )
        )
        .animation(.easeInOut(duration: 0.15), value: voicePressed)
        .animation(.easeInOut(duration: 0.15), value: voiceCanceling)
        .contentShape(Rectangle())
        .gesture(voiceTapOrHoldGesture(onTap: {
            voiceMode = false
            DispatchQueue.main.async { inputFocused = true }
        }))
        .accessibilityLabel("按住说话，轻点切回键盘输入")
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
        if !voiceMode {
            inputFocused = true
        }
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
                try await api.sendInput(id: session.id, input: trimmed, view: "terminal")
                try await Task.sleep(nanoseconds: 30_000_000)
                try await api.sendInput(id: session.id, input: "\r", view: "terminal", shortcutKey: "enter_text")
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
        VStack(spacing: 0) {
            Text(session.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 205)
            Text(session.cwd?.isEmpty == false ? session.cwd! : "未设置工作目录")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.58))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 205)
        }
        .shadow(color: Color.black.opacity(0.26), radius: 3, x: 0, y: 1)
        .accessibilityElement(children: .combine)
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
                BrandLogoShape(provider: session.provider)
                    .fill(providerTint.opacity(0.88))
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
        session.provider == "codex" ? Theme.codex : Theme.brand
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
                Image(systemName: "clock.arrow.circlepath")
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
        history.provider == "codex" ? Theme.codex : Theme.brand
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
