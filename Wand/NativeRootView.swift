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
#if DEBUG
    @State private var didApplyDebugSettingsLaunch = false
#endif
    @ObservedObject private var quickActions = QuickActionCoordinator.shared
    /// 当前选中的会话身份 + 完整快照：由 SessionListView 写入，驱动 SplitView detail 栏
    /// / NavigationStack push。提升到根视图是因为 detail 内容由根容器直接承载，
    /// 不再走隐藏 NavigationLink（在 .columns 双栏下不可靠）。
    @State private var selectedSessionID: String?
    @State private var selectedSnapshot: SessionSnapshot?
    /// iPhone push 动画期间的会话身份。列表只允许这一次打开落入状态机，避免双击/连点
    /// 把 navigationDestination(isPresented:) 推进半截时再次改写 selection。
    @State private var openingSessionID: String?

    private enum Phase: Equatable {
        case authenticating
        case ready
        case failed(String)
    }

    private var api: WandAPI {
        WandAPI(baseURL: serverURL, token: token)
    }

    var body: some View {
        AdaptiveNavigationContainer(
            selection: $selectedSessionID,
            sidebar: { sidebarContent },
            detail: { detailContent }
        )
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
#if DEBUG
            handleDebugSettingsLaunch()
#endif
            handleQuickAction()
        }
        // NavigationStack 的系统返回手势只会把 selection 置空；同步释放详情快照，确保
        // 下次进入（包括同一会话）创建干净的 destination，而不是复用已 shutdown 的页面。
        .onChange(of: selectedSessionID) { _, sessionID in
            guard let sessionID else {
                selectedSnapshot = nil
                openingSessionID = nil
                return
            }
            releaseSessionOpenGateAfterTransition(for: sessionID)
        }
        .wandKeyboardShortcuts(rootKeyboardShortcuts)
    }

    private var rootKeyboardShortcuts: [WandKeyboardShortcutAction] {
        guard phase == .ready else { return [] }
        return [
            WandKeyboardShortcutAction(
                id: "new-session",
                title: "新建会话",
                key: "n",
                modifiers: .command
            ) {
                openNewSessionFromKeyboard()
            },
            WandKeyboardShortcutAction(
                id: "show-settings",
                title: "设置",
                key: ",",
                modifiers: .command,
                isEnabled: !showSettings
            ) {
                showWebFallback = false
                showSettings = true
            },
            WandKeyboardShortcutAction(
                id: "show-sessions",
                title: "显示会话列表",
                key: "1",
                modifiers: .command,
                isEnabled: selectedSessionID != nil || showWebFallback
            ) {
                showSettings = false
                showWebFallback = false
                selectedSessionID = nil
                selectedSnapshot = nil
            },
            WandKeyboardShortcutAction(
                id: "close-active-surface",
                title: "关闭当前页",
                key: "w",
                modifiers: .command,
                isEnabled: selectedSessionID != nil || showWebFallback || showSettings
            ) {
                closeActiveSurfaceFromKeyboard()
            },
        ]
    }

    private func openNewSessionFromKeyboard() {
        showSettings = false
        showWebFallback = false
        QuickActionCoordinator.shared.enqueue(.newSession)
    }

    private func closeActiveSurfaceFromKeyboard() {
        if showWebFallback {
            showWebFallback = false
        } else if showSettings {
            showSettings = false
        } else if selectedSessionID != nil {
            selectedSessionID = nil
            selectedSnapshot = nil
        }
    }

    /// 侧边栏：登录/失败/就绪三种阶段共用同一栏。ready 时承载会话列表及其 toolbar。
    @ViewBuilder private var sidebarContent: some View {
        ZStack {
            WandAmbientBackground()
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
                    Button { authenticate() } label: {
                        Text("重试").frame(maxWidth: .infinity)
                    }
                        .buttonStyle(WandPrimaryButtonStyle())
                    if LocalNetworkPermission.isLikelyLanHost(serverURL.host) {
                        Button {
                            LocalNetworkPermission.openSettings()
                        } label: {
                            Text("打开 Wand 设置").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(WandSecondaryButtonStyle())
                    }
                    Button { store.disconnect() } label: {
                        Text("重新连接").frame(maxWidth: .infinity)
                    }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
                .frame(maxWidth: 420)
                .padding(24)
                .wandGlassCard(cornerRadius: 18)
                .padding(16)
                .navigationTitle("Wand")
            case .ready:
                VStack(spacing: 0) {
                    if shouldShowUpdateBanner {
                        updateBanner
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 6)
                    }
                    SessionListView(
                        api: api,
                        selection: $selectedSessionID,
                        selectedSnapshot: $selectedSnapshot,
                        openingSessionID: $openingSessionID
                    )
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

    /// 详情内容：选中会话后渲染聊天/终端；未选中或快照未到时显示占位。
    /// 快照可能在异步拉取中（长按图标打开非列表内会话），先给身份再回填，
    /// 此期间显示加载态。
    @ViewBuilder private var detailContent: some View {
        if let session = selectedSnapshot {
            // 所有会话共用 detail 入口，按 session.id 绑定身份：避免 SwiftUI 复用上一个会话的
            // ChatStore（其 @StateObject 只在首次身份创建时求值，导致串数据）。
            SessionDestinationView(session: session, api: api)
                .id(session.id)
        } else if selectedSessionID != nil {
            ProgressView().tint(Theme.brand)
        } else {
            emptyDetailPlaceholder
        }
    }

    private var emptyDetailPlaceholder: some View {
        VStack(spacing: 12) {
            WandBrandMark(size: 48)
            Text("选择一个会话")
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WandAmbientBackground() }
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
        .wandGlassCard(cornerRadius: 14)
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
        } else if quickActions.consume(where: { $0 == .showSessions }) != nil {
            showSettings = false
            showWebFallback = false
        }
    }

    /// SwiftUI 没有为 navigationDestination(isPresented:) 提供转场完成回调。用一个短暂、
    /// 可验证的输入锁覆盖 iPhone 默认 push 动画窗口；若期间返回或换会话，identity 检查会
    /// 让旧任务自然失效。这样既拦住重复打开，也不会把 iPad 双栏永久锁死。
    private func releaseSessionOpenGateAfterTransition(for sessionID: String) {
        guard openingSessionID == sessionID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard selectedSessionID == sessionID,
                  openingSessionID == sessionID else { return }
            openingSessionID = nil
        }
    }

#if DEBUG
    private func handleDebugSettingsLaunch() {
        guard !didApplyDebugSettingsLaunch,
              phase == .ready,
              ProcessInfo.processInfo.arguments.contains("--wand-open-settings") else { return }
        didApplyDebugSettingsLaunch = true
        showSettings = true
    }
#endif

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

/// iPhone、窄分屏保持单栏返回栈；iPad 横屏和足够大的自由窗口使用系统双栏导航。
/// 只依据当前可用尺寸，旋转和 Stage Manager 改窗后会自动重新选择布局。
///
/// 宽屏用 NavigationSplitView(selection:)：selection 绑定驱动 detail 栏，选中即显示，
/// 这是双栏下可靠的程序化跳转方式（旧实现用 .columns + 隐藏 NavigationLink 在 iPad 上失效）。
/// 窄屏用 NavigationStack + navigationDestination(isPresented:)：点行 push 详情页。
private struct AdaptiveNavigationContainer<Sidebar: View, Detail: View>: View {
    @Binding var selection: String?
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        GeometryReader { geometry in
            if usesWideListDetail(width: geometry.size.width, height: geometry.size.height) {
                wideLayout
            } else {
                narrowLayout
            }
        }
    }

    private var wideLayout: some View {
        NavigationSplitView {
            sidebar()
        } detail: {
            detail()
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var narrowLayout: some View {
        NavigationStack {
            sidebar()
                .navigationDestination(isPresented: isDetailPresented) {
                    detail()
                }
        }
    }

    /// NavigationStack 的呈现绑定：selection 有值即 push detail，置空即 pop。
    private var isDetailPresented: Binding<Bool> {
        Binding(
            get: { selection != nil },
            set: { presented in if !presented { selection = nil } }
        )
    }
}

func usesWideListDetail(width: CGFloat, height: CGFloat) -> Bool {
    width >= 640 && height >= 480
}
