import SwiftUI

/// 会话列表：原生渲染 /api/sessions，下拉刷新 + 周期轮询，
/// 点击进入原生 ChatView，支持滑动删除与新建会话。
struct SessionListView: View {
    let api: WandAPI

    @State private var sessions: [SessionSnapshot] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var showNewSession = false
    @State private var showArchived = false
    /// 长按图标快捷操作「继续会话」的程序化跳转目标。
    @State private var quickOpenSessionId: String?
    @ObservedObject private var quickActions = QuickActionCoordinator.shared

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var visibleSessions: [SessionSnapshot] {
        sessions.filter { ($0.archived ?? false) == showArchived }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
            // 隐藏的程序化跳转链接：快捷操作「继续会话」用。
            NavigationLink(isActive: quickOpenActive) {
                if let id = quickOpenSessionId {
                    ChatView(sessionId: id, api: api)
                } else {
                    EmptyView()
                }
            } label: { EmptyView() }
                .hidden()
        }
        .navigationTitle("Wand")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showNewSession = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.brand)
                }
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView(api: api) { newSession in
                showNewSession = false
                sessions.insert(newSession, at: 0)
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
    }

    private var quickOpenActive: Binding<Bool> {
        Binding(
            get: { quickOpenSessionId != nil },
            set: { if !$0 { quickOpenSessionId = nil } }
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
            quickOpenSessionId = nil
            showNewSession = true
        case .openSession(let id):
            showNewSession = false
            quickOpenSessionId = id
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
                    ZStack {
                        NavigationLink(destination: ChatView(sessionId: session.id, api: api)) {
                            EmptyView()
                        }
                        .opacity(0)
                        SessionRow(session: session)
                    }
                    .listRowBackground(Theme.background)
                    .listRowSeparatorTint(Theme.border)
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
            QuickActionCoordinator.updateRecentSessionShortcuts(sessions)
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
}

// MARK: - 列表行

private struct SessionRow: View {
    let session: SessionSnapshot

    var body: some View {
        HStack(spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(session.providerLabel) · \(session.isStructured ? "聊天" : "终端")")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Theme.surface)
                        )
                        .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                        .foregroundColor(Theme.textSecondary)
                    Text(cwdTail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(statusLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusTint)
        }
        .padding(.vertical, 6)
    }

    private var cwdTail: String {
        guard let cwd = session.cwd, !cwd.isEmpty else { return "" }
        return (cwd as NSString).lastPathComponent
    }

    private var statusDot: some View {
        Circle()
            .fill(statusTint)
            .frame(width: 9, height: 9)
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
