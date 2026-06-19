import SwiftUI

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
            case .newSession, .openSession: return true
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
            SessionLiveActivityController.shared.reconcile(snapshots: loadedSessions)
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

/// PTY 会话的原生外壳：套用与 ChatView 一致的原生导航头（provider 徽章 + 标题 +
/// cwd），中间嵌入 embed=terminal 的 WebView 只渲染终端黑窗，底部输入栏走原生组件。
/// 这样 PTY 会话不再是「直接打开整张网页版」，而是和对话模式同样的原生观感，
/// 只是内容区换成了那块黑色终端窗口。
private struct PtySessionView: View {
    let session: SessionSnapshot
    let api: WandAPI

    @StateObject private var store: ChatStore
    @StateObject private var keyboard = KeyboardObserver()
    @State private var draft = ""
    @State private var showStopConfirm = false
    @State private var showQuickCommit = false
    @State private var gitStatus: GitStatusResult?
    @FocusState private var inputFocused: Bool

    init(session: SessionSnapshot, api: WandAPI) {
        self.session = session
        self.api = api
        _store = StateObject(wrappedValue: ChatStore(sessionId: session.id, api: api))
    }

    var body: some View {
        GeometryReader { root in
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    WebContainerView(
                        serverURL: api.baseURL,
                        token: api.token,
                        sessionId: session.id,
                        embedTerminal: true,
                        embedNativeInput: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomBar(safeBottom: root.safeAreaInsets.bottom)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { providerBadge }
            ToolbarItem(placement: .principal) { titleStatus }
            ToolbarItem(placement: .navigationBarTrailing) {
                GitChangesToolbarButton(status: gitStatus) {
                    showQuickCommit = true
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(sessionId: session.id, api: api)
                .presentationDetents([.height(620), .large])
                .presentationDragIndicator(.visible)
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

    private func bottomBar(safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            inputBar
        }
        .padding(.bottom, safeBottom + keyboard.lift)
        .background(
            Theme.background
                .opacity(0.97)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.easeOut(duration: 0.2), value: keyboard.lift)
    }

    private var inputExpanded: Bool {
        inputFocused || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !inputExpanded {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.textSecondary.opacity(0.10)))
            }
            TextField("发消息…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.brand)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .padding(.leading, inputExpanded ? 6 : 2)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .frame(minHeight: 32)
            trailingButtons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(inputFocused ? Theme.brand : Theme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 7, y: 2)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.18), value: inputExpanded)
        .confirmationDialog(
            "确定要停止当前正在运行的任务吗？",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("停止", role: .destructive) { store.stopResponding(forcePtyChat: true) }
            Button("取消", role: .cancel) {}
        }
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
                .foregroundColor(.black)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white))
                .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))
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
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(canSend ? Theme.brand : Theme.brand.opacity(0.4)))
        }
        .disabled(!canSend)
        .accessibilityLabel("发送")
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        store.send(text: text, forcePtyChat: true)
        inputFocused = true
    }

    private func refreshGitStatus() {
        Task {
            gitStatus = try? await api.gitStatus(sessionId: session.id)
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

    private var providerBadge: some View {
        let isCodex = session.provider == "codex"
        let tint: Color = isCodex ? Theme.codex : Theme.brand
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.13))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1)
            BrandLogoShape(provider: session.provider)
                .fill(tint)
                .frame(width: 15, height: 15)
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel(isCodex ? "Codex" : "Claude")
    }

    private var titleStatus: some View {
        VStack(spacing: 0) {
            Text(session.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190)
            Text(session.cwd?.isEmpty == false ? session.cwd! : "未设置工作目录")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190)
        }
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
