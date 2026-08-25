import UIKit
import WebKit

/// JS → 原生消息处理 + 自签名证书 + WKWebView 委托。导航状态通过 `WebViewModel`
/// 驱动 SwiftUI 覆盖层（加载中 / 出错）。对称 macOS 的 WebBridge，但去掉了应用内
/// 自动更新（DmgInstaller / UpdateChecker / NSAlert）——iOS 自签名应用无法自我安装更新。
final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private let model: WebViewModel
    private weak var webView: WKWebView?
    private var serverURL: URL?
    private var serverID: String?
    private var endpointScope: WandEndpointScope?
    private var attachmentGeneration = 0
    private var hasLoadedOnce = false
    private var keyboardObservers: [NSObjectProtocol] = []

    init(model: WebViewModel) {
        self.model = model
    }

    @discardableResult
    func attach(webView: WKWebView, serverURL: URL) -> Int {
        attachmentGeneration &+= 1
        self.webView = webView
        self.serverURL = serverURL
        self.serverID = ServerProfiles.stableID(for: serverURL)
        self.endpointScope = WandEndpointScope(serverURL)
        self.model.webView = webView
        installKeyboardObservers()
        return attachmentGeneration
    }

    func isCurrentAttachment(webView: WKWebView, generation: Int) -> Bool {
        self.webView === webView && attachmentGeneration == generation
    }

    func detach(webView: WKWebView) {
        guard self.webView === webView else { return }
        attachmentGeneration &+= 1
        self.webView = nil
        serverURL = nil
        serverID = nil
        endpointScope = nil
        if model.webView === webView { model.webView = nil }
    }

    deinit {
        for observer in keyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func installKeyboardObservers() {
        guard keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(
                forName: UIResponder.keyboardDidShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.dispatchKeyboardState("shown")
            },
            center.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.dispatchKeyboardState("hidden")
            },
        ]
    }

    private func dispatchKeyboardState(_ state: String) {
        webView?.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('wand-ios-ime-state',{detail:{state:'\(state)'}}));"
        )
    }

    /// 切换到错误覆盖层（主线程）。token 登录失败时由 WebViewRepresentable 调用。
    func fail(title: String, message: String, canRetry: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.model.phase = .failed(title: title, message: message, canRetry: canRetry)
        }
    }

    // MARK: - JS → Native

    /// 前端可能发 downloadUpdate 等消息；iOS 端没有应用内更新通道，统一忽略，
    /// 仅保留通道以兼容前端共用代码，不报错。
    func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let dict = msg.body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "backToNative":
            DispatchQueue.main.async { [weak self] in
                self?.model.requestClose?()
            }
        case "requestNotificationPermission":
            SessionNotificationController.shared.requestAuthorization()
        case "sendNotification":
            let title = dict["title"] as? String ?? "Wand"
            let body = dict["body"] as? String ?? ""
            let tag = dict["tag"] as? String ?? ""
            SessionNotificationController.shared.sendWebNotification(
                title: title,
                body: body,
                tag: tag,
                serverID: serverID
            )
        default:
            wlog("web", "ignored native message type=\(type) (no-op on iOS)")
        }
    }

    // MARK: - Self-signed HTTPS / Auth challenge

    /// 仅对当前 Wand endpoint 的自签名证书放行。外部导航或同主机其他端口不得
    /// 继承这个例外。
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let method = space.authenticationMethod
        let host = space.host

        if method == NSURLAuthenticationMethodServerTrust,
           endpointScope?.usesHTTPS == true,
           endpointScope?.matches(space) == true {
            if let trust = space.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                wlog("web", "auth challenge: serverTrust nil host=\(host) — 回退默认处理")
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        wlog("web", "auth challenge: 非 ServerTrust method=\(method) host=\(host) — 默认处理")
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: - Endpoint navigation boundary

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if isSafeLocalDocumentURL(url) || endpointScope?.contains(url) == true {
            decisionHandler(.allow)
            return
        }

        // An iframe must never leave the selected endpoint. Main-frame external links are
        // handed to the system browser, whose cookie jar does not contain Wand credentials.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame {
            openExternal(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }
        if endpointScope?.contains(url) == true {
            webView.load(navigationAction.request)
        } else if !isSafeLocalDocumentURL(url) {
            openExternal(url)
        }
        return nil
    }

    private func isSafeLocalDocumentURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "about" || scheme == "data" || scheme == "blob"
    }

    private func openExternal(_ url: URL) {
        guard UIApplication.shared.canOpenURL(url) else {
            wlog("web", "系统无法打开外部链接 scheme=\(url.scheme ?? "?")")
            return
        }
        UIApplication.shared.open(url)
    }

    /// Installs the subresource boundary before the first authentication cookie enters
    /// WebKit. Failing to compile is fail-closed: the caller keeps the error overlay visible.
    func installEndpointContentBoundary(
        in userController: WKUserContentController,
        serverURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let json = WandEndpointContentBoundary.contentRuleListJSON(baseURL: serverURL) else {
            completion(.failure(NSError(
                domain: "com.wand.app.web-content-boundary",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法生成服务器网络边界"]
            )))
            return
        }
        let identifier = "wand-endpoint-boundary-v1-\(ServerProfiles.stableID(for: serverURL))"
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        ) { ruleList, error in
            DispatchQueue.main.async {
                if let ruleList {
                    userController.add(ruleList)
                    completion(.success(()))
                } else {
                    completion(.failure(error ?? NSError(
                        domain: "com.wand.app.web-content-boundary",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "无法启用服务器网络边界"]
                    )))
                }
            }
        }
    }

    // MARK: - Navigation lifecycle / diagnostics

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 仅首屏加载（或显式重试）显示加载层；会话中途的局部跳转不打扰用户。
        if !hasLoadedOnce {
            model.phase = .loading
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return } // 被新导航/reload 打断，不算错误
        let url = webView.url?.absoluteString ?? serverURL?.absoluteString ?? "?"
        wlog("web", "首屏导航失败 url=\(url) domain=\(ns.domain) code=\(ns.code) reason=\(ns.localizedDescription)")
        showLoadError(error: ns, url: url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        wlog("web", "导航失败 domain=\(ns.domain) code=\(ns.code) reason=\(ns.localizedDescription)")
        showLoadError(error: ns, url: webView.url?.absoluteString ?? serverURL?.absoluteString ?? "?")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {}

    private func showLoadError(error: NSError, url: String) {
        let message = """
        \(url)
        \(error.localizedDescription)（\(error.domain) #\(error.code)）

        请确认 wand 服务正在运行，并检查地址是否正确。
        """
        model.phase = .failed(title: "无法加载 wand 服务器", message: message, canRetry: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        wlog("web", "WebContent 进程已终止，自动重新加载 url=\(webView.url?.absoluteString ?? "?")")
        hasLoadedOnce = false
        model.phase = .loading
        if webView.url != nil {
            webView.reload()
        } else if let serverURL {
            webView.load(URLRequest(url: serverURL))
        } else {
            model.phase = .failed(
                title: "无法恢复网页内容",
                message: "服务器地址已失效，请返回后重新打开。",
                canRetry: false
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoadedOnce = true
        model.phase = .ready
        // WebContent 进程重建会换一个新的 WKContentView，键盘顶栏会复活，
        // 每次导航完成后重申一次（幂等）。
        webView.wandHideKeyboardAccessoryBar()
        // 旧版网页没有 __wandNativeBackHooked 标记（侧边栏没有「返回App」按钮），
        // 此时回退显示壳自带的顶部返回栏，避免用户被困在网页版里。
        webView.evaluateJavaScript("!!(window.__wandNativeBackHooked)") { [weak self] result, _ in
            let hooked = (result as? Bool) ?? false
            self?.model.needsLegacyChrome = !hooked
        }
        model.refreshEmbeddedTerminalScaleLabel()
    }
}
