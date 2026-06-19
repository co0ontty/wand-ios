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
    @Published var terminalScaleLabel = "100%"
    /// WebBridge 收到 backToNative 消息时调用，由容器视图注入（关闭 fullScreenCover）。
    var requestClose: (() -> Void)?
    /// WebBridge attach 时回填，供"重试"调用 reload()。
    weak var webView: WKWebView?

    func retry() {
        phase = .loading
        webView?.reload()
    }

    func adjustEmbeddedTerminalScale(delta: Double) {
        runTerminalControlScript(clickElementId: delta < 0 ? "terminal-scale-down-top" : "terminal-scale-up-top")
    }

    func refreshEmbeddedTerminal() {
        runTerminalControlScript(clickElementId: "page-refresh-btn")
    }

    func refreshEmbeddedTerminalScaleLabel() {
        runTerminalControlScript(clickElementId: nil)
    }

    private func runTerminalControlScript(clickElementId: String?) {
        let clickExpression = clickElementId.map { "'\($0)'" } ?? "null"
        let script = """
        (function() {
          var clickId = \(clickExpression);
          if (clickId) {
            var button = document.getElementById(clickId);
            if (button && typeof button.click === "function") button.click();
          }
          var label = document.getElementById("terminal-scale-label-top");
          if (label && label.textContent) return label.textContent.trim();
          var raw = "1";
          try { raw = localStorage.getItem("wand-terminal-scale") || "1"; } catch (e) {}
          var scale = Number(raw);
          if (!Number.isFinite(scale)) scale = 1;
          return Math.round(scale * 100) + "%";
        })();
        """
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView else { return }
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let label = result as? String, !label.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.terminalScaleLabel = label
                }
            }
        }
    }
}

/// 对外的容器视图：底层是 WKWebView，加载中/出错时盖上不透明的主题覆盖层。
/// 对称 macOS 的 WebContainerView，把 NSViewRepresentable 换成 UIViewRepresentable。
struct WebContainerView: View {
    let serverURL: URL
    let token: String?
    var sessionId: String? = nil
    /// 嵌入终端模式：URL 带 ?embed=terminal，网页只渲染终端黑窗。
    /// 用于把 PTY 会话套进原生导航头（见 PtySessionView）。此模式下不显示
    /// 壳自带的顶部返回栏与加载覆盖层逃生按钮——返回交给原生导航条。
    var embedTerminal: Bool = false
    /// PTY 原生输入栏模式：URL 额外带 ?nativeInput=1，网页隐藏自己的 input-panel。
    var embedNativeInput: Bool = false
    /// 「返回原生界面」回调（网页版兜底入口传入）；触发途径：网页侧边栏的
    /// 「返回App」按钮 → backToNative 消息，或加载中/出错覆盖层上的逃生按钮。
    var onRequestClose: (() -> Void)? = nil

    @EnvironmentObject private var store: ServerStore
    @StateObject private var model: WebViewModel

    init(
        serverURL: URL,
        token: String?,
        sessionId: String? = nil,
        embedTerminal: Bool = false,
        embedNativeInput: Bool = false,
        webViewModel: WebViewModel? = nil,
        onRequestClose: (() -> Void)? = nil
    ) {
        self.serverURL = serverURL
        self.token = token
        self.sessionId = sessionId
        self.embedTerminal = embedTerminal
        self.embedNativeInput = embedNativeInput
        self.onRequestClose = onRequestClose
        _model = StateObject(wrappedValue: webViewModel ?? WebViewModel())
    }

    private var displayHost: String {
        if let host = serverURL.host {
            if let port = serverURL.port { return "\(host):\(port)" }
            return host
        }
        return serverURL.absoluteString
    }

    private var containerBackground: Color {
        embedTerminal ? Color(red: 0.090, green: 0.071, blue: 0.059) : Theme.background
    }

    var body: some View {
        ZStack {
            containerBackground.ignoresSafeArea()
            webContent
            overlay
            escapeButton
        }
        .onAppear { model.requestClose = onRequestClose }
    }

    @ViewBuilder private var webContent: some View {
        if embedTerminal {
            // 嵌入终端：原生导航条已消费顶部安全区，WebView 贴在头部下沿，
            // nativeInput 模式下底部由原生输入栏占位；旧模式仍向 home indicator 延伸。
            let webView = WebViewRepresentable(
                serverURL: serverURL,
                token: token,
                sessionId: sessionId,
                embedTerminal: true,
                embedNativeInput: embedNativeInput,
                model: model
            )
            if embedNativeInput {
                webView
            } else {
                webView.ignoresSafeArea(.container, edges: .bottom)
            }
        } else if model.needsLegacyChrome, let onRequestClose {
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
        if !embedTerminal, model.phase != .ready, let onRequestClose {
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
    var embedTerminal: Bool = false
    var embedNativeInput: Bool = false
    let model: WebViewModel
    @Environment(\.colorScheme) private var colorScheme

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
            window.WandNative = {
              getPermission: function() { return "granted"; },
              requestPermission: function() {
                try { window.webkit.messageHandlers.wandNative.postMessage({ type: "requestNotificationPermission" }); } catch (e) {}
              },
              sendNotification: function(title, body, tag) {
                try {
                  window.webkit.messageHandlers.wandNative.postMessage({
                    type: "sendNotification",
                    title: String(title || "Wand"),
                    body: String(body || ""),
                    tag: String(tag || "")
                  });
                } catch (e) {}
              }
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        if embedTerminal {
            userController.addUserScript(WKUserScript(
                source: Self.terminalNativeUserScriptSource,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
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
        webView.isOpaque = false
        applyAppearance(to: webView)

        // UA 标记：让前端识别这是 iOS 原生壳
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 WandApp/\(version) WandPlatform/iOS"

        let targetURL = sessionURL()
        context.coordinator.attach(webView: webView, serverURL: targetURL)

        // 有 token：先调 /api/login 拿 session cookie 注入 WKHTTPCookieStore，再加载主页。
        // 没有 token：当成裸 URL（ConnectView 已探测过可达性），直接加载。
        let cookieStore = cfg.websiteDataStore.httpCookieStore
        if let token, !token.isEmpty {
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
                            wlog("web", "注入 \(cookies.count) 个 cookie，加载网页版 \(serverURL.absoluteString)")
                            webView.load(URLRequest(url: targetURL))
                        }
                    }
                case .failure(let err):
                    wlog("web", "网页版 token 登录失败: \(err.userMessage)")
                    context.coordinator.fail(
                        title: "无法登录 wand 服务器",
                        message: err.userMessage,
                        canRetry: false
                    )
                }
            }
        } else {
            wlog("web", "无 token，直接加载网页版 \(serverURL.absoluteString)")
            webView.load(URLRequest(url: targetURL))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        applyAppearance(to: uiView)
    }

    private func applyAppearance(to webView: WKWebView) {
        let webBackground = embedTerminal
            ? UIColor(red: 0.090, green: 0.071, blue: 0.059, alpha: 1)
            : Theme.uiBackground
        webView.overrideUserInterfaceStyle = embedTerminal
            ? .dark
            : (colorScheme == .dark ? .dark : .light)
        webView.backgroundColor = webBackground
        webView.scrollView.backgroundColor = webBackground
        webView.underPageBackgroundColor = webBackground
    }

    private func sessionURL() -> URL {
        guard let sessionId, !sessionId.isEmpty,
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "session" || $0.name == "embed" || $0.name == "nativeInput" }
        items.append(URLQueryItem(name: "session", value: sessionId))
        if embedTerminal {
            items.append(URLQueryItem(name: "embed", value: "terminal"))
            if embedNativeInput {
                items.append(URLQueryItem(name: "nativeInput", value: "1"))
            }
        }
        components.queryItems = items
        return components.url ?? serverURL
    }

    private static let terminalNativeUserScriptSource = """
    (function() {
      try {
        var root = document.documentElement;
        root.classList.add('is-wand-app-native-insets');
        root.style.setProperty('--app-inset-top', '0px');
        root.style.setProperty('--app-inset-bottom', '0px');
        root.style.setProperty('--app-inset-left', '0px');
        root.style.setProperty('--app-inset-right', '0px');

        if (!document.getElementById('wand-native-terminal-compact-style')) {
          var style = document.createElement('style');
          style.id = 'wand-native-terminal-compact-style';
          style.textContent = `
            .is-wand-embed-terminal .wand-joystick-root{z-index:120;}
            .is-wand-embed-terminal .wand-joystick-root.visible{opacity:1!important;visibility:visible!important;}
            .is-wand-embed-terminal .wand-joystick-ball{opacity:1!important;transform:none;}
            .is-wand-embed-terminal .wand-joystick-panel{z-index:124;}
            .is-wand-embed-terminal .terminal-scroll-wrap{
              padding:8px 4px 8px!important;
              --term-font-family:"SFMono-Regular","Menlo","Monaco","Noto Sans Symbols 2","Noto Sans Symbols",monospace!important;
              --term-font-size:10px!important;
              --term-row-height:15px!important;
            }
            .is-wand-embed-terminal .input-panel{display:none!important;}
            .is-wand-embed-terminal .notification-bubble.update-card{display:none!important;}
            .is-wand-embed-terminal .terminal-container{
              margin:0!important;
              border-left:0!important;
              border-right:0!important;
              border-radius:0!important;
              box-shadow:none!important;
            }
          `;
          document.head.appendChild(style);
        }

        if (!window.__wandNativeJoystickFocusGuard) {
          window.__wandNativeJoystickFocusGuard = true;
          function blurJoystickFocus() {
            try {
              var active = document.activeElement;
              if (active && typeof active.blur === 'function') active.blur();
              setTimeout(function() {
                try {
                  var next = document.activeElement;
                  if (next && typeof next.blur === 'function') next.blur();
                } catch (e) {}
              }, 0);
            } catch (e) {}
          }
          ['pointerdown', 'pointerup', 'touchstart', 'touchend', 'click'].forEach(function(type) {
            document.addEventListener(type, function(event) {
              try {
                var target = event.target;
                if (target && target.closest && target.closest('.wand-joystick-root')) {
                  blurJoystickFocus();
                }
              } catch (e) {}
            }, true);
          });
        }

        function fitTerminal() {
          try {
            window.dispatchEvent(new Event('resize'));
            var output = document.getElementById('output');
            if (output) {
              var width = output.style.width;
              output.style.width = 'calc(100% - 0.01px)';
              void output.offsetWidth;
              output.style.width = width;
            }
          } catch (e) {}
        }
        [0, 80, 220, 520].forEach(function(delay) {
          setTimeout(fitTerminal, delay);
        });
      } catch (e) {}
    })();
    """
}
