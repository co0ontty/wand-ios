import SwiftUI
import WebKit

/// WebView 的加载状态，由 WebBridge（导航委托）更新，驱动 SwiftUI 覆盖层。
final class WebViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(title: String, message: String, canRetry: Bool)
    }

    @Published var phase: Phase = .loading
    /// 旧版网页（侧边栏没有「返回原生界面」按钮）：壳回退显示自己的顶部返回栏，
    /// 避免用户被困在网页版里。由 WebBridge 在 didFinish 时检测后回填。
    @Published var needsLegacyChrome = false
    /// WebBridge 收到 backToNative 消息时调用，由容器视图注入（关闭 fullScreenCover）。
    var requestClose: (() -> Void)?
    /// WebBridge attach 时回填，供"重试"调用 reload()。
    weak var webView: WKWebView?

    func retry() {
        phase = .loading
        webView?.reload()
    }
}

/// 对外的容器视图：底层是 WKWebView，加载中/出错时盖上不透明的主题覆盖层。
/// 对称 macOS 的 WebContainerView，把 NSViewRepresentable 换成 UIViewRepresentable。
struct WebContainerView: View {
    let serverURL: URL
    let token: String?
    var sessionId: String? = nil
    /// 「返回原生界面」回调（网页版兜底入口传入）；触发途径：网页侧边栏的
    /// 「返回App」按钮 → backToNative 消息，或加载中/出错覆盖层上的逃生按钮。
    var onRequestClose: (() -> Void)? = nil

    @EnvironmentObject private var store: ServerStore
    @StateObject private var model = WebViewModel()

    private var displayHost: String {
        if let host = serverURL.host {
            if let port = serverURL.port { return "\(host):\(port)" }
            return host
        }
        return serverURL.absoluteString
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            webContent
            overlay
            escapeButton
        }
        .onAppear { model.requestClose = onRequestClose }
    }

    @ViewBuilder private var webContent: some View {
        if model.needsLegacyChrome, let onRequestClose {
            // 旧版网页：保留壳自带的顶部返回栏（网页里没有返回按钮）。
            VStack(spacing: 0) {
                legacyTopBar(onClose: onRequestClose)
                Divider()
                WebViewRepresentable(serverURL: serverURL, token: token, sessionId: sessionId, model: model)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        } else {
            // 新版网页：侧边栏自带「返回App」按钮，WebView 全屏贴到状态栏/灵动岛下，
            // 顶部间距由网页用 env(safe-area-inset-top) 自己排（viewport-fit=cover）。
            WebViewRepresentable(serverURL: serverURL, token: token, sessionId: sessionId, model: model)
                .ignoresSafeArea(.container, edges: .all)
        }
    }

    @ViewBuilder private var overlay: some View {
        switch model.phase {
        case .loading:
            LoadingOverlay(host: displayHost)
        case .failed(let title, let message, let canRetry):
            ErrorOverlay(
                title: title,
                message: message,
                canRetry: canRetry,
                onRetry: { model.retry() },
                onReconnect: { store.disconnect() }
            )
        case .ready:
            EmptyView()
        }
    }

    /// 加载中/出错覆盖层上的逃生口：此时网页侧的返回按钮还不可用。
    @ViewBuilder private var escapeButton: some View {
        if model.phase != .ready, let onRequestClose {
            VStack {
                HStack {
                    Button(action: onRequestClose) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text("返回")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(Theme.brand)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.brand.opacity(0.12)))
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
    }

    private func legacyTopBar(onClose: @escaping () -> Void) -> some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("返回原生界面")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(Theme.brand)
            }
            Spacer()
            Text("网页版")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.background)
    }
}

// MARK: - 覆盖层

private struct LoadingOverlay: View {
    let host: String

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 18) {
                WandBrandMark(size: 56)
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.brand)
                VStack(spacing: 4) {
                    Text("正在连接")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(host)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorOverlay: View {
    let title: String
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Theme.danger.opacity(0.12))
                        .frame(width: 62, height: 62)
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(Theme.danger)
                }
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    if canRetry {
                        Button(action: onRetry) {
                            Text("重试").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(WandPrimaryButtonStyle())
                    }
                    Button(action: onReconnect) {
                        Text("重新连接").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WandSecondaryButtonStyle())
                }
                .frame(maxWidth: 280)
                .padding(.top, 4)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 键盘 accessory bar 移除

/// 仅用于借一份「返回 nil 的 inputAccessoryView getter」实现，灌给动态子类。
private final class WandNoAccessoryStub: NSObject {
    @objc var inputAccessoryView: UIView? { nil }
}

extension WKWebView {
    /// 去掉系统给网页输入框配的键盘顶栏（「∧ ∨ 完成」那条）。原生聊天 App 都没有
    /// 这条栏，它还会把键盘整体垫高 ~44pt，导致页面按 visualViewport 排版后输入框
    /// 被它盖住半截。做法是经典 swizzle：找到 scrollView 里的 WKContentView，
    /// 动态派生一个 inputAccessoryView 返回 nil 的子类并替换 isa。
    /// 幂等：重复调用（didFinish 每次导航都会触发）不会叠加派生。
    func wandHideKeyboardAccessoryBar() {
        guard let target = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }) else { return }
        guard let currentClass = object_getClass(target) else { return }
        let currentName = NSStringFromClass(currentClass)
        if currentName.hasSuffix("_WandNoAccessory") { return }

        let newName = currentName + "_WandNoAccessory"
        let newClass: AnyClass
        if let cached = NSClassFromString(newName) {
            newClass = cached
        } else {
            guard let allocated = objc_allocateClassPair(currentClass, newName, 0) else { return }
            let selector = #selector(getter: UIResponder.inputAccessoryView)
            if let stub = class_getInstanceMethod(
                WandNoAccessoryStub.self,
                #selector(getter: WandNoAccessoryStub.inputAccessoryView)
            ) {
                class_addMethod(
                    allocated,
                    selector,
                    method_getImplementation(stub),
                    method_getTypeEncoding(stub)
                )
            }
            objc_registerClassPair(allocated)
            newClass = allocated
        }
        object_setClass(target, newClass)
        // 若键盘已弹出，刷新一次输入视图让顶栏立刻消失。
        target.reloadInputViews()
    }
}

// MARK: - WKWebView 桥接

struct WebViewRepresentable: UIViewRepresentable {
    let serverURL: URL
    let token: String?
    let sessionId: String?
    let model: WebViewModel

    func makeCoordinator() -> WebBridge {
        WebBridge(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "wandNative")
        // 暴露「返回原生界面」入口给网页：新版网页检测到这个函数后会在侧边栏
        // 渲染「返回App」按钮（macOS 壳和浏览器里没有该函数，不会显示按钮）。
        userController.addUserScript(WKUserScript(
            source: """
            window.__wandIosNative = true;
            window.__wandBackToNative = function() {
              try { window.webkit.messageHandlers.wandNative.postMessage({ type: "backToNative" }); } catch (e) {}
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        cfg.userContentController = userController
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // 聊天 App 式键盘手感：向下拖动内容即收起键盘；整页不做橡皮筋回弹
        //（页面自身是 fixed 布局，回弹只会拖出底色）。
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.bounces = false
        // 去掉键盘上方系统自带的「∧ ∨ 完成」工具栏。
        webView.wandHideKeyboardAccessoryBar()
        webView.backgroundColor = Theme.uiBackground
        webView.scrollView.backgroundColor = Theme.uiBackground
        webView.isOpaque = false
        webView.underPageBackgroundColor = Theme.uiBackground

        // UA 标记：让前端识别这是 iOS 原生壳
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 WandApp/\(version) WandPlatform/iOS"

        let targetURL = sessionURL()
        context.coordinator.attach(webView: webView, serverURL: targetURL)

        // 有 token：先调 /api/login 拿 session cookie 注入 WKHTTPCookieStore，再加载主页。
        // 没有 token：当成裸 URL（ConnectView 已探测过可达性），直接加载。
        let cookieStore = cfg.websiteDataStore.httpCookieStore
        if let token, !token.isEmpty {
            NSLog("[Wand] token-login before load: %@", serverURL.absoluteString)
            WandAuth.loginWithToken(serverURL: serverURL, appToken: token) { result in
                switch result {
                case .success(let cookies):
                    DispatchQueue.main.async {
                        let group = DispatchGroup()
                        for cookie in cookies {
                            group.enter()
                            cookieStore.setCookie(cookie) { group.leave() }
                        }
                        group.notify(queue: .main) {
                            NSLog("[Wand] %d cookie(s) injected, loading %@", cookies.count, serverURL.absoluteString)
                            webView.load(URLRequest(url: targetURL))
                        }
                    }
                case .failure(let err):
                    NSLog("[Wand] token-login FAILED: %@", err.userMessage)
                    context.coordinator.fail(
                        title: "无法登录 wand 服务器",
                        message: err.userMessage,
                        canRetry: false
                    )
                }
            }
        } else {
            NSLog("[Wand] no token; loading %@ directly", serverURL.absoluteString)
            webView.load(URLRequest(url: targetURL))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func sessionURL() -> URL {
        guard let sessionId, !sessionId.isEmpty,
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "session" }
        items.append(URLQueryItem(name: "session", value: sessionId))
        components.queryItems = items
        return components.url ?? serverURL
    }
}
