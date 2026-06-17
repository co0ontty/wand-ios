import SwiftUI

/// 原生客户端根视图：先用 appToken 登录拿 session cookie（ephemeral 存储，
/// 冷启动后为空），然后进入原生会话列表。WebView 仅作为「网页版」兜底入口保留，
/// 覆盖设置、文件浏览等原生未实现的功能。
struct NativeRootView: View {
    let serverURL: URL
    let token: String?

    @EnvironmentObject private var store: ServerStore
    @State private var phase: Phase = .authenticating
    @State private var showWebFallback = false
    @State private var showSettings = false
    @State private var serverUpdate: ServerUpdateInfo?
    @State private var dismissedUpdateVersion: String?
    @State private var updateBannerMessage: String?
    @State private var updateError: String?
    @State private var installingUpdate = false
    @State private var systemSocket: WandSocket?
    @ObservedObject private var quickActions = QuickActionCoordinator.shared

    private enum Phase: Equatable {
        case authenticating
        case ready
        case failed(String)
    }

    private var api: WandAPI {
        WandAPI(baseURL: serverURL, token: token)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Theme.background.ignoresSafeArea()
                switch phase {
                case .authenticating:
                    VStack(spacing: 16) {
                        WandBrandMark(size: 52)
                        ProgressView().tint(Theme.brand)
                        Text("正在登录…")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .navigationTitle("Wand")
                case .failed(let message):
                    VStack(spacing: 14) {
                        Image(systemName: "lock.slash")
                            .font(.system(size: 30))
                            .foregroundColor(Theme.danger)
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { authenticate() }
                            .buttonStyle(WandPrimaryButtonStyle())
                        if LocalNetworkPermission.isLikelyLanHost(serverURL.host) {
                            Button("打开 Wand 设置") {
                                LocalNetworkPermission.openSettings()
                            }
                            .buttonStyle(WandSecondaryButtonStyle())
                        }
                        Button("重新连接") { store.disconnect() }
                            .buttonStyle(WandSecondaryButtonStyle())
                    }
                    .padding(32)
                    .navigationTitle("Wand")
                case .ready:
                    VStack(spacing: 0) {
                        if shouldShowUpdateBanner {
                            updateBanner
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .padding(.bottom, 6)
                                .background(Theme.background)
                        }
                        SessionListView(api: api)
                    }
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Menu {
                                    Button {
                                        NotificationCenter.default.post(name: .wandBeginSessionSelection, object: nil)
                                    } label: {
                                        Label("多选会话", systemImage: "checkmark.circle")
                                    }
                                    Button {
                                        showSettings = true
                                    } label: {
                                        Label("设置", systemImage: "gearshape")
                                    }
                                    Button {
                                        showWebFallback = true
                                    } label: {
                                        Label("打开网页版", systemImage: "safari")
                                    }
                                    Button {
                                        NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                                    } label: {
                                        Label("切换服务器", systemImage: "server.rack")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 18))
                                        .foregroundColor(Theme.textSecondary)
                                }
                            }
                        }
                }
            }
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(isPresented: $showWebFallback) {
            // 网页版兜底：不再套壳顶栏，返回入口在网页侧边栏（「返回App」按钮）。
            // 旧版网页 / 加载中 / 出错时 WebContainerView 内部自带回退返回方式。
            WebContainerView(serverURL: serverURL, token: token) {
                showWebFallback = false
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(serverURL: serverURL, token: token) {
                // sheet 收起动画结束后再呈现 fullScreenCover，避免双 present 冲突。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showWebFallback = true
                }
            }
            .environmentObject(store)
        }
        .onAppear { authenticate() }
        .onDisappear {
            systemSocket?.close()
            systemSocket = nil
        }
        // 「打开网页版」快捷操作归本视图消费；登录完成前先挂起，ready 后再接。
        .onReceive(quickActions.$pending) { _ in
            handleQuickAction()
        }
        .onChange(of: phase) { _, _ in
            handleQuickAction()
        }
        .task { await monitorSessionStatus() }
    }

    private var shouldShowUpdateBanner: Bool {
        guard let info = serverUpdate else { return false }
        return dismissedUpdateVersion != info.normalizedLatest
    }

    private var updateBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: installingUpdate ? "arrow.triangle.2.circlepath" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.brand)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(installingUpdate ? "正在更新服务端" : "发现新版本")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(updateError ?? updateBannerMessage ?? "点击下方按钮一键更新")
                        .font(.system(size: 12))
                        .foregroundColor(updateError == nil ? Theme.textSecondary : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    if let latest = serverUpdate?.normalizedLatest {
                        dismissedUpdateVersion = latest
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .disabled(installingUpdate)
            }
            if let info = serverUpdate {
                HStack(spacing: 10) {
                    versionPill(info.displayCurrent, filled: false)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    versionPill(info.displayLatest, filled: true)
                    Spacer(minLength: 0)
                    Button {
                        installUpdate()
                    } label: {
                        HStack(spacing: 6) {
                            if installingUpdate {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white)
                            }
                            Text(installingUpdate ? "更新中" : "立即更新")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(installingUpdate ? Theme.brand.opacity(0.65) : Theme.brand)
                        )
                    }
                    .disabled(installingUpdate)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func versionPill(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(filled ? Theme.brand : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(filled ? Theme.brand.opacity(0.12) : Theme.border.opacity(0.45))
            )
            .overlay(
                Capsule()
                    .stroke(filled ? Theme.brand.opacity(0.55) : Color.clear, lineWidth: 1)
            )
    }

    private func handleQuickAction() {
        guard phase == .ready else { return }
        if quickActions.consume(where: { $0 == .openWeb }) != nil {
            showSettings = false
            showWebFallback = true
        }
    }

    private func authenticate() {
        phase = .authenticating
        guard let token, !token.isEmpty else {
            // 裸地址连接（无 token）：直接试列表，401 时引导重新连接。
            Task {
                do {
                    _ = try await api.listSessions()
                    phase = .ready
                    startSystemSocket()
                    await refreshServerUpdateInfo()
                } catch {
                    phase = .failed("无法访问服务器：\(error.localizedDescription)\n如果服务器设有密码，请用「连接码」重新连接。")
                }
            }
            return
        }
        WandAuth.loginWithToken(serverURL: serverURL, appToken: token) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    phase = .ready
                    startSystemSocket()
                    Task { await refreshServerUpdateInfo() }
                case .failure(let err):
                    phase = .failed(err.userMessage)
                }
            }
        }
    }

    /// Live Activity 不应依赖会话列表或聊天页是否可见。前台期间从根视图轻量轮询，
    /// 因此网页版发起的任务、冷启动时已运行的任务也能进入灵动岛。
    private func monitorSessionStatus() async {
        while !Task.isCancelled {
            if phase == .ready {
                if let snapshots = try? await api.listSessions() {
                    SessionLiveActivityController.shared.reconcile(snapshots: snapshots)
                    SessionNotificationController.shared.reconcile(snapshots: snapshots)
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func refreshServerUpdateInfo() async {
        guard let config = try? await api.serverConfig(),
              config.updateAvailable == true,
              let latest = config.latestVersion,
              !latest.isEmpty else { return }
        serverUpdate = ServerUpdateInfo(
            current: config.currentVersion ?? "?",
            latest: latest,
            channel: config.updateChannel
        )
    }

    private func startSystemSocket() {
        guard systemSocket == nil else { return }
        let socket = WandSocket(baseURL: serverURL)
        socket.onEvent = { incoming in
            guard incoming.type == "notification", let data = incoming.data else { return }
            handleSystemNotification(data)
        }
        socket.connect()
        systemSocket = socket
    }

    private func handleSystemNotification(_ data: WsData) {
        switch data.kind {
        case "update":
            guard let current = data.current, let latest = data.latest else { return }
            serverUpdate = ServerUpdateInfo(current: current, latest: latest, channel: nil)
            updateBannerMessage = "点击下方按钮一键更新"
            updateError = nil
        case "auto-update-start":
            installingUpdate = true
            if let current = data.current, let latest = data.latest {
                serverUpdate = ServerUpdateInfo(current: current, latest: latest, channel: nil)
            }
            updateBannerMessage = "服务端正在下载并安装新版"
            updateError = nil
        case "auto-update-restart", "restart":
            installingUpdate = false
            updateBannerMessage = "更新完成，服务端正在重启"
            updateError = nil
        case "auto-update-failed":
            installingUpdate = false
            updateError = data.error ?? "更新失败，请到网页版设置中查看详情"
        default:
            break
        }
    }

    private func installUpdate() {
        guard !installingUpdate else { return }
        installingUpdate = true
        updateError = nil
        updateBannerMessage = "服务端正在下载并安装新版"
        Task {
            do {
                try await api.installServerUpdate()
                updateBannerMessage = "更新命令已发送，服务端即将重启"
            } catch {
                updateError = error.localizedDescription
            }
            installingUpdate = false
        }
    }
}
