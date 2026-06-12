import SwiftUI

/// 会话列表：原生渲染 /api/sessions，下拉刷新 + 周期轮询，
/// 对话模式进入原生聊天，PTY 模式进入嵌套网页版对应会话。
struct SessionListView: View {
    let api: WandAPI

    @State private var sessions: [SessionSnapshot] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var showNewSession = false
    @State private var showArchived = false
    @State private var selectedSessionIds: Set<String> = []
    @State private var isSelecting = false
    /// 长按图标快捷操作 / 新建完成后的程序化跳转目标。
    @State private var quickOpenSession: SessionSnapshot?
    @ObservedObject private var quickActions = QuickActionCoordinator.shared

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var visibleSessions: [SessionSnapshot] {
        sessions.filter { ($0.archived ?? false) == showArchived }
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
                    Picker("会话范围", selection: $showArchived) {
                        Text("进行中").tag(false)
                        Text("已归档").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
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
                    Image(systemName: isSelecting ? "xmark.circle.fill" : "plus.circle.fill")
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
                    quickOpenSession = newSession
                }
            }
        }
        .task { await load() }
        .onReceive(refreshTimer) { _ in
            Task { await load(silent: true) }
        }
        // @Published 订阅时会重放当前值，所以冷启动遗留的待处理操作也能在视图出现时接住。
        .onReceive(quickActions.$pending) { _ in
            handleQuickAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandBeginSessionSelection)) { _ in
            isSelecting = true
        }
        .onChange(of: showArchived) { _ in
            endSelection()
        }
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
        if loading && sessions.isEmpty {
            ProgressView().tint(Theme.brand)
        } else if let error = loadError, sessions.isEmpty {
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
        } else if visibleSessions.isEmpty {
            VStack(spacing: 14) {
                WandBrandMark(size: 52)
                Text(showArchived ? "没有已归档的会话" : "还没有会话")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if !showArchived {
                    Button { showNewSession = true } label: {
                        Text("新建会话")
                    }
                    .buttonStyle(WandPrimaryButtonStyle())
                }
            }
        } else {
            List {
                ForEach(visibleSessions) { session in
                    Group {
                        if isSelecting {
                            Button {
                                toggleSelection(session.id)
                            } label: {
                                SessionRow(
                                    session: session,
                                    selecting: true,
                                    selected: selectedSessionIds.contains(session.id)
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                quickOpenSession = session
                            } label: {
                                SessionRow(session: session, selecting: false, selected: false)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    isSelecting = true
                                    selectedSessionIds = [session.id]
                                } label: {
                                    Label("多选会话", systemImage: "checkmark.circle")
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
                .onDelete(perform: deleteSessions)
            }
            .listStyle(.plain)
            .refreshable { await load(silent: true) }
        }
    }

    private func load(silent: Bool = false) async {
        if !silent { loading = true }
        do {
            sessions = try await api.listSessions()
            loadError = nil
            // 同步「最近会话」动态快捷项到长按图标菜单。
            await QuickActionCoordinator.updateRecentSessionShortcuts(sessions)
        } catch {
            if !silent || sessions.isEmpty {
                loadError = error.localizedDescription
            }
        }
        loading = false
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

    private func endSelection() {
        isSelecting = false
        selectedSessionIds.removeAll()
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
