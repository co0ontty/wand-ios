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
    @State private var historyActionInProgress = false
    @State private var selectedSessionIds: Set<String> = []
    @State private var isSelecting = false
    @State private var sessionRowFrames: [String: CGRect] = [:]
    @State private var dragSelectionAnchorId: String?
    @State private var dragSelectionBaseIds: Set<String> = []
    @State private var suppressedSessionTapId: String?
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
                    SessionDestinationView(session: session, api: api)
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
                        if suppressedSessionTapId == session.id {
                            suppressedSessionTapId = nil
                            return
                        }
                        if isSelecting {
                            toggleSelection(session.id)
                        } else {
                            quickOpenSession = session
                        }
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SessionRowFramePreferenceKey.self,
                                value: [session.id: proxy.frame(in: .named("session-list"))]
                            )
                        }
                    )
                    .simultaneousGesture(selectionGesture(startingWith: session.id))
                    .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
                .onDelete(perform: deleteSessions)
            }
            .listStyle(.plain)
            .coordinateSpace(name: "session-list")
            .onPreferenceChange(SessionRowFramePreferenceKey.self) { sessionRowFrames = $0 }
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
                    .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
                .onDelete(perform: deleteHistory)
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

    private func deleteHistory(at offsets: IndexSet) {
        let targets = offsets.map { visibleHistorySessions[$0] }
        historySessions.removeAll { history in targets.contains { $0.id == history.id } }
        Task {
            for target in targets {
                try? await api.deleteHistory(target)
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

    private func deleteSessions(at offsets: IndexSet) {
        let targets = offsets.map { visibleSessions[$0] }
        sessions.removeAll { snap in targets.contains { $0.id == snap.id } }
        Task {
            for target in targets {
                try? await api.deleteSession(id: target.id)
            }
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

    /// 长按当前行立即进入多选；手指保持按下并划过其它行时连续加入选择。
    /// 使用 sequenced 手势避免普通点击打开会话时误触多选。
    private func selectionGesture(startingWith id: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("session-list")))
            .onChanged { value in
                switch value {
                case .second(true, let drag?):
                    beginDragSelection(with: id)
                    selectSessionRange(through: drag.location)
                default:
                    break
                }
            }
            .onEnded { _ in
                dragSelectionAnchorId = nil
                dragSelectionBaseIds.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    suppressedSessionTapId = nil
                }
            }
    }

    private func beginDragSelection(with id: String) {
        guard dragSelectionAnchorId == nil else { return }
        if !isSelecting { isSelecting = true }
        dragSelectionAnchorId = id
        dragSelectionBaseIds = selectedSessionIds
        suppressedSessionTapId = id
        selectedSessionIds.insert(id)
    }

    private func selectSessionRange(through location: CGPoint) {
        guard
            let anchorId = dragSelectionAnchorId,
            let anchorIndex = visibleSessions.firstIndex(where: { $0.id == anchorId }),
            let targetId = sessionId(nearestTo: location),
            let targetIndex = visibleSessions.firstIndex(where: { $0.id == targetId })
        else { return }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        let rangeIds = Set(bounds.map { visibleSessions[$0].id })
        selectedSessionIds = dragSelectionBaseIds.union(rangeIds)
    }

    /// 手指落在卡片间隙时也取垂直方向最近的行，避免快速滑动漏选。
    private func sessionId(nearestTo location: CGPoint) -> String? {
        if let hit = sessionRowFrames.first(where: { $0.value.contains(location) }) {
            return hit.key
        }
        return sessionRowFrames.min {
            abs($0.value.midY - location.y) < abs($1.value.midY - location.y)
        }?.key
    }

    private func endSelection() {
        isSelecting = false
        selectedSessionIds.removeAll()
        dragSelectionAnchorId = nil
        dragSelectionBaseIds.removeAll()
        suppressedSessionTapId = nil
    }

    private func deleteSelectedSessions() {
        let ids = selectedSessionIds
        sessions.removeAll { ids.contains($0.id) }
        endSelection()
        Task {
            for id in ids {
                try? await api.deleteSession(id: id)
            }
        }
    }
}

extension Notification.Name {
    static let wandBeginSessionSelection = Notification.Name("wandBeginSessionSelection")
}

private struct SessionRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SessionDestinationView: View {
    let session: SessionSnapshot
    let api: WandAPI

    @ViewBuilder var body: some View {
        if session.isStructured {
            ChatView(sessionId: session.id, api: api)
        } else {
            WebSessionView(sessionId: session.id, api: api)
        }
    }
}

private struct WebSessionView: View {
    let sessionId: String
    let api: WandAPI
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        WebContainerView(serverURL: api.baseURL, token: api.token, sessionId: sessionId) {
            presentationMode.wrappedValue.dismiss()
        }
            .navigationBarHidden(true)
    }
}

// MARK: - 列表行

private struct SessionRow: View {
    let session: SessionSnapshot
    let selecting: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 13) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(selected ? Theme.brand : Theme.textSecondary)
            }
            providerMark
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(session.providerLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(providerTint)
                    metadataLabel(
                        session.isStructured ? "聊天" : "终端",
                        icon: session.isStructured ? "bubble.left.fill" : "terminal.fill"
                    )
                }
                if !compactPath.isEmpty {
                    Text(compactPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(statusTint.opacity(0.11)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border.opacity(0.75), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
    }

    private var compactPath: String {
        guard let cwd = session.cwd, !cwd.isEmpty else { return "" }
        let components = (cwd as NSString).pathComponents.filter { $0 != "/" }
        guard components.count > 3 else { return cwd }
        return "…/" + components.suffix(3).joined(separator: "/")
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(providerTint.opacity(0.13))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(providerTint.opacity(0.24), lineWidth: 1)
            BrandLogoShape(provider: session.provider)
                .fill(providerTint)
                .frame(width: 21, height: 21)
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(statusTint)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
        .accessibilityLabel("\(session.providerLabel)，\(statusLabel)")
    }

    private func metadataLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Theme.textSecondary)
    }

    private var providerTint: Color {
        session.provider == "codex" ? Theme.codex : Theme.brand
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
        default: return session.status ?? ""
        }
    }
}

private struct HistorySessionRow: View {
    let history: HistorySession

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(providerTint.opacity(0.13))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(providerTint.opacity(0.24), lineWidth: 1)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(providerTint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text(history.firstUserMessage.isEmpty ? "空会话" : history.firstUserMessage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 7) {
                    Text(providerLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(providerTint)
                    if !relativeTime.isEmpty {
                        Label(relativeTime, systemImage: "clock")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                if !compactPath.isEmpty {
                    Text(compactPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 8)
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(providerTint.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border.opacity(0.75), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
    }

    private var providerLabel: String {
        history.provider == "codex" ? "Codex" : "Claude"
    }

    private var providerTint: Color {
        history.provider == "codex" ? Theme.codex : Theme.brand
    }

    private var compactPath: String {
        let components = (history.cwd as NSString).pathComponents.filter { $0 != "/" }
        guard components.count > 3 else { return history.cwd }
        return "…/" + components.suffix(3).joined(separator: "/")
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
