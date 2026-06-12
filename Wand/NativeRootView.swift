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
                        Button("重新连接") { store.disconnect() }
                            .buttonStyle(WandSecondaryButtonStyle())
                    }
                    .padding(32)
                    .navigationTitle("Wand")
                case .ready:
                    SessionListView(api: api)
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
        // 「打开网页版」快捷操作归本视图消费；登录完成前先挂起，ready 后再接。
        .onReceive(quickActions.$pending) { _ in
            handleQuickAction()
        }
        .onChange(of: phase) { _ in
            handleQuickAction()
        }
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
                case .failure(let err):
                    phase = .failed(err.userMessage)
                }
            }
        }
    }
}
