import SwiftUI
import WebKit

/// HTML runs in an opaque origin and a new ephemeral WebKit store. Only the resolved
/// artifact tree can use the native session cookie; there is no native script bridge.
@MainActor
final class ArtifactPreviewStore: NSObject, ObservableObject, WKNavigationDelegate {
    let api: WandAPI
    let url: URL
    @Published private(set) var webView: WKWebView?
    @Published private(set) var localFile: URL?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var preparation: Task<Void, Never>?
    private var revision = 0
    private var resourceRoot: URL?

    init(url: URL, api: WandAPI) { self.url = url; self.api = api }

    static func isolatedHTML(_ response: HTTPURLResponse) -> Bool {
        let directives = (response.value(forHTTPHeaderField: "Content-Security-Policy") ?? "")
            .lowercased().split(separator: ";").map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        guard response.mimeType?.lowercased() == "text/html",
              let sandbox = directives.first(where: { $0.first == "sandbox" }),
              Set(sandbox.dropFirst()).isSubset(of: ["allow-scripts", "allow-forms"]),
              directives.contains(["form-action", "'none'"]), directives.contains(["connect-src", "'none'"]) else { return false }
        return true
    }

    static func previewRoot(_ url: URL, baseURL: URL) -> URL? {
        guard let route = WandMessageLink.endpointRoute(url, baseURL: baseURL) else { return nil }
        let parts = route.percentEncodedPath.split(separator: "/")
        let count: Int
        if parts.count >= 3, parts[0] == "api", parts[1] == "local-file" { count = 3 }
        else if parts.count >= 4, parts[0] == "api", parts[1] == "local-preview" { count = 4 }
        else { return nil }
        return WandEndpoint.url(baseURL: baseURL, route: "/" + parts.prefix(count).joined(separator: "/") + "/")
    }

    static func nonHTMLDownload(_ response: HTTPURLResponse, baseURL: URL) -> URL? {
        guard (200..<300).contains(response.statusCode), response.mimeType?.lowercased() != "text/html",
              let url = response.url, let route = WandMessageLink.endpointRoute(url, baseURL: baseURL) else { return nil }
        if route.percentEncodedPath.hasPrefix("/api/local-preview/") { return url }
        guard route.percentEncodedPath.hasPrefix("/api/local-file/") else { return nil }
        return WandMessageLink.withFileAction(url, action: "download")
    }

    static func contentRules(root: URL) throws -> String {
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^" + NSRegularExpression.escapedPattern(for: root.absoluteString)], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^blob:"], "action": ["type": "ignore-previous-rules"]]
        ]
        return String(data: try JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
    }

    static func probe(_ url: URL, session: URLSession) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"; request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WandAPI.APIError.network("文件响应无效。") }
        guard [405, 501].contains(http.statusCode) else { return http }
        request.httpMethod = "GET"
        // Some development servers only implement GET. Consume headers, then cancel the
        // transfer immediately; a readiness check must never buffer an unbounded body.
        let (bytes, fallback) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let fallback = fallback as? HTTPURLResponse else { throw WandAPI.APIError.network("文件响应无效。") }
        return fallback
    }

    func load() {
        close(); loading = true; error = nil
        let generation = revision
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                guard !api.endpointSession.isRetired,
                      let route = WandMessageLink.endpointRoute(url, baseURL: api.baseURL),
                      WandMessageLink.isArtifactRoute(route.percentEncodedPath) else { throw WandAPI.APIError.invalidURL }
                _ = try await api.serverConfig() // Native API owner refreshes an expired login once.
                let http = try await Self.probe(url, session: api.endpointSession.session)
                if let downloadURL = Self.nonHTMLDownload(http, baseURL: api.baseURL) {
                    let name = http.suggestedFilename ?? http.url?.lastPathComponent ?? "文件"
                    let file = try await WandServerFileLink.download(url: downloadURL, suggestedName: name, api: api)
                    guard !Task.isCancelled, revision == generation, !api.endpointSession.isRetired else {
                        try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); return
                    }
                    localFile = file; loading = false; return
                }
                try validate(http)
                guard let finalURL = http.url, let root = Self.previewRoot(finalURL, baseURL: api.baseURL) else {
                    throw WandAPI.APIError.network("服务器没有返回可隔离的 HTML 预览，请更新 Wand 服务。")
                }
                let json = try Self.contentRules(root: root)
                guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "wand-artifact-boundary-v1", encodedContentRuleList: json) else {
                    throw WandAPI.APIError.network("无法初始化预览隔离规则。")
                }
                guard !Task.isCancelled, revision == generation, !api.endpointSession.isRetired else { return }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.userContentController.add(rules)
                configuration.applicationNameForUserAgent = "WandApp/iOS WandPlatform/iOS"
                let cookies = (api.endpointSession.cookieStorage?.cookies(for: finalURL) ?? [])
                    .filter { WandAuth.sessionCookieNames.contains($0.name) }
                for cookie in cookies { await configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
                guard !Task.isCancelled, revision == generation, !api.endpointSession.isRetired else { return }
                var target = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)!
                if target.percentEncodedFragment == nil { target.percentEncodedFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment }
                let view = WKWebView(frame: .zero, configuration: configuration)
                view.navigationDelegate = self; view.isOpaque = false; view.backgroundColor = Theme.uiBackground
                resourceRoot = root; webView = view
                view.load(URLRequest(url: target.url!))
            } catch {
                guard !Task.isCancelled, revision == generation else { return }
                loading = false; self.error = error.localizedDescription
            }
        }
    }

    private func validate(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = response.statusCode == 401 || response.statusCode == 403 ? "没有文件访问权限或登录已失效，请重新连接。" : response.statusCode == 404 ? "文件或页面不存在，可能已移动。" : response.statusCode == 502 ? "本地预览服务未启动，请启动后重试。" : "预览加载失败（HTTP \(response.statusCode)）。"
            throw WandAPI.APIError.network(message)
        }
        guard let target = response.url, WandEndpointScope(api.baseURL)?.contains(target) == true,
              Self.isolatedHTML(response) else { throw WandAPI.APIError.network("此页面未提供安全的 HTML 隔离策略，请更新 Wand 服务。") }
    }
    func close() {
        revision += 1; preparation?.cancel(); preparation = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        loading = false; resourceRoot = nil
        if let localFile { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        localFile = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !api.endpointSession.isRetired, let target = action.request.url, let root = resourceRoot,
              target.user == nil, target.password == nil, WandEndpointScope(api.baseURL)?.contains(target) == true,
              target.absoluteString.hasPrefix(root.absoluteString) else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, let target = action.request.url,
               target.user == nil, target.password == nil,
               WandEndpointScope(api.baseURL)?.contains(target) != true,
               ["https", "http", "mailto"].contains(target.scheme?.lowercased() ?? "") { UIApplication.shared.open(target) }
            return
        }
        guard action.targetFrame?.isMainFrame == true else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard response.isForMainFrame, let http = response.response as? HTTPURLResponse else { decisionHandler(.cancel); return }
        do { try validate(http); decisionHandler(.allow) }
        catch { loading = false; self.error = error.localizedDescription; decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) { if (error as NSError).code != NSURLErrorCancelled { loading = false; self.error = error.localizedDescription } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading = false; error = "预览页面已暂停，请重试。" }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !api.endpointSession.isRetired, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              WandEndpointScope(api.baseURL)?.matches(challenge.protectionSpace) == true,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct ArtifactPreviewView: View {
    @StateObject private var store: ArtifactPreviewStore
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.dismiss) private var dismiss
    private let title: String
    private let connectionIdentity: String?
    init(url: URL, title: String, api: WandAPI) {
        _store = StateObject(wrappedValue: ArtifactPreviewStore(url: url, api: api))
        self.title = title; connectionIdentity = ServerStore.shared.activeProfile?.connectionIdentity
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.loading { ProgressView("正在加载预览…").padding() }
                if let error = store.error { Text(error).font(.callout).foregroundStyle(Theme.danger).padding() }
                if let view = store.webView { ArtifactBrowser(view: view) }
                else if let file = store.localFile { ServerFileQuickLook(fileURL: file) }
                else { Spacer() }
            }
            .background(Theme.background).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.frame(minHeight: WandLayout.controlTouch) }
                ToolbarItem(placement: .primaryAction) {
                    if let file = store.localFile { ShareLink(item: file) { Label("分享文件", systemImage: "square.and.arrow.up").labelStyle(.iconOnly) } }
                    else {
                    Button { store.load() } label: { Label("重试", systemImage: "arrow.clockwise").labelStyle(.iconOnly).frame(width: WandLayout.controlTouch, height: WandLayout.controlTouch) }
                    .disabled(store.loading)
                    }
                }
            }
        }
        .task { store.load() }.onDisappear { store.close() }
        .onChange(of: servers.activeProfile?.connectionIdentity) { _, identity in
            if identity != connectionIdentity { store.close(); dismiss() }
        }
        .wandPreferredAppearance()
    }
}
private struct ArtifactBrowser: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
