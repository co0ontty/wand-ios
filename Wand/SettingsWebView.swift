import SwiftUI
import WebKit

/// The server's existing WebView grant is scoped to the current live client session.
/// Obtain it in an isolated, no-redirect session; never elevate the native API cookie jar.
@MainActor
enum SettingsWebAuthentication {
    static func cookies(api: WandAPI) async throws -> [HTTPCookie] {
        _ = try await api.serverConfig() // Existing native owner handles one expired-login refresh.
        guard !api.endpointSession.isRetired,
              let url = WandEndpoint.url(baseURL: api.baseURL, route: "/api/settings/webview-session") else {
            throw WandAPI.APIError.unauthorized
        }
        let native = (api.endpointSession.cookieStorage?.cookies(for: url) ?? [])
            .filter { WandAuth.sessionCookieNames.contains($0.name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: SettingsAuthBoundary(baseURL: api.baseURL), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPCookie.requestHeaderFields(with: native)["Cookie"], forHTTPHeaderField: "Cookie")
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard !api.endpointSession.isRetired, let response = response as? HTTPURLResponse,
              response.url == url else { throw WandAPI.APIError.unauthorized }
        return try validatedCookies(native: native, response: response)
    }

    static func validatedCookies(native: [HTTPCookie], response: HTTPURLResponse) throws -> [HTTPCookie] {
        if response.statusCode == 401 { throw WandAPI.APIError.unauthorized }
        if response.statusCode == 404 { throw WandAPI.APIError.network("服务器不支持客户端认证的完整设置，请更新 Wand 服务") }
        guard (200..<300).contains(response.statusCode), let url = response.url else {
            throw WandAPI.APIError.network("无法打开完整设置，请稍后重试")
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
        }
        let proof = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            .filter { $0.name == "wand_settings_access" && !$0.value.isEmpty }
        guard !proof.isEmpty else { throw WandAPI.APIError.network("服务器没有返回客户端设置登录态，请更新 Wand 服务") }
        return native.filter { WandAuth.sessionCookieNames.contains($0.name) } + proof
    }
}

private final class SettingsAuthBoundary: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let scope: WandEndpointScope?
    init(baseURL: URL) { scope = WandEndpointScope(baseURL) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              scope?.matches(challenge.protectionSpace) == true,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// One ephemeral browser per connection lifetime. Cookies never enter URLs, JavaScript,
/// shared WebKit storage or a different server's origin/port/reverse-proxy namespace.
@MainActor
final class SettingsWebStore: NSObject, ObservableObject, WKNavigationDelegate {
    let api: WandAPI
    @Published private(set) var webView: WKWebView?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var revision = 0
    private var preparation: Task<Void, Never>?

    private let initialSection: String?
    init(api: WandAPI, initialSection: String? = nil) { self.api = api; self.initialSection = initialSection == "connectors" ? initialSection : nil }

    static func startURL(_ baseURL: URL, section: String? = nil) -> URL? {
        var query = [URLQueryItem(name: "client", value: "app")]
        if section == "connectors" { query.append(URLQueryItem(name: "section", value: "connectors")) }
        return WandEndpoint.url(baseURL: baseURL, route: "/settings", queryItems: query)
    }

    static func accepts(_ url: URL, baseURL: URL) -> Bool {
        url.user == nil && url.password == nil && WandEndpointScope(baseURL)?.contains(url) == true
    }

    func load() {
        close()
        let request = revision
        loading = true; error = nil
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                guard !api.endpointSession.isRetired,
                      let url = Self.startURL(api.baseURL, section: initialSection),
                      let json = WandEndpointContentBoundary.contentRuleListJSON(baseURL: api.baseURL) else {
                    throw WandAPI.APIError.invalidURL
                }
                let cookies = try await SettingsWebAuthentication.cookies(api: api)
                guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "wand-settings-boundary-v1", encodedContentRuleList: json) else {
                    throw WandAPI.APIError.network("设置页面的端点隔离规则未能载入")
                }
                guard !Task.isCancelled, request == revision, !api.endpointSession.isRetired else { return }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.userContentController.add(rules)
                configuration.applicationNameForUserAgent = "WandApp/iOS WandPlatform/iOS"
                for cookie in cookies {
                    await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
                guard !Task.isCancelled, request == revision, !api.endpointSession.isRetired else { return }
                let view = WKWebView(frame: .zero, configuration: configuration)
                view.navigationDelegate = self
                view.isOpaque = false
                view.backgroundColor = Theme.uiBackground
                webView = view
                view.load(URLRequest(url: url))
            } catch {
                guard !Task.isCancelled, request == revision else { return }
                loading = false
                self.error = "设置未能打开：" + error.localizedDescription
            }
        }
    }

    func close() {
        revision += 1
        preparation?.cancel(); preparation = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        loading = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !api.endpointSession.isRetired, let url = navigationAction.request.url,
              Self.accepts(url, baseURL: api.baseURL) else {
            decisionHandler(.cancel)
            if api.endpointSession.isRetired { close(); error = "服务器连接已改变，请返回设置后重新打开。" }
            else if navigationAction.navigationType == .linkActivated,
                    let external = navigationAction.request.url,
                    ["https", "http"].contains(external.scheme?.lowercased() ?? ""),
                    external.user == nil, external.password == nil {
                UIApplication.shared.open(external)
            }
            return
        }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel); webView.load(navigationAction.request)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            loading = false
            error = response.statusCode == 404 ? "服务器尚不支持完整设置页面，请更新 Wand 服务。" : "设置页面加载失败，请重新读取。"
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        loading = false; error = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, error: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, error: error)
    }
    private func navigationFailed(_ view: WKWebView, error: Error) {
        guard webView === view, (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false; self.error = "设置未能打开：" + error.localizedDescription
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        loading = false; error = "设置页面已暂停，请重新读取。"
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !api.endpointSession.isRetired,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              WandEndpointScope(api.baseURL)?.matches(challenge.protectionSpace) == true,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct SettingsWebView: View {
    @StateObject private var store: SettingsWebStore
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.dismiss) private var dismiss
    private let connectionIdentity: String?

    init(api: WandAPI, section: String? = nil, connectionIdentity: String? = ServerStore.shared.activeProfile?.connectionIdentity) {
        _store = StateObject(wrappedValue: SettingsWebStore(api: api, initialSection: section))
        self.connectionIdentity = connectionIdentity
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.loading { ProgressView("正在读取设置…").padding() }
                if let error = store.error {
                    Text(error).font(.callout).foregroundStyle(Theme.danger).padding()
                }
                if let webView = store.webView { SettingsBrowser(view: webView) }
                else { Spacer() }
            }
            .background(Theme.background)
            .navigationTitle("完整 Web 设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() }.frame(minHeight: WandLayout.controlTouch) }
                ToolbarItem(placement: .primaryAction) {
                    Button { store.load() } label: {
                        Label("重新读取", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                            .frame(width: WandLayout.controlTouch, height: WandLayout.controlTouch)
                    }.disabled(store.loading)
                }
            }
        }
        .task { store.load() }
        .onDisappear { store.close() }
        .onChange(of: servers.activeProfile?.connectionIdentity) { _, identity in
            guard identity != connectionIdentity else { return }
            store.close(); dismiss()
        }
        .wandPreferredAppearance()
    }
}

private struct SettingsBrowser: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
