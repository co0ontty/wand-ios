import Foundation

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

/// wand 服务端 REST 客户端。复用 SelfSignedSession（自签证书放行 + 共享
/// cookieStorage），所以 WandAuth.loginWithToken 拿到的 session cookie 在这里
/// 的每个请求上自动携带；遇到 401 时用存储的 appToken 重新登录一次再重试。
final class WandAPI {
    /// 聊天块级窗口默认预算：打开会话只拉最近这么多个内容块，更早的滚动到顶时按需翻页。
    static let chatBlockWindow = 60
    /// 刷新模型会重新探测多个 CLI，可能超过普通请求的 30 秒窗口。
    static let modelRefreshTimeout: TimeInterval = 180

    let baseURL: URL
    let token: String?

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    enum APIError: LocalizedError {
        case invalidURL
        case server(status: Int, message: String)
        case network(String)
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无效的请求地址"
            case .server(_, let message): return message
            case .network(let m): return "网络错误：\(m)"
            case .unauthorized: return "登录已失效，请重新连接"
            }
        }
    }

    // MARK: - 基础请求

    private func makeRequest(method: String, path: String, body: [String: Any]?, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await SelfSignedSession.shared.session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.network("无效响应")
            }
            return (data, http)
        } catch let err as APIError {
            throw err
        } catch {
            wlog("api", "网络错误 \(req.httpMethod ?? "?") \(req.url?.path ?? "?"): \(error.localizedDescription)")
            throw APIError.network(error.localizedDescription)
        }
    }

    /// 带 401 自动重登的请求入口。
    private func requestData(method: String, path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Data {
        let req = try makeRequest(method: method, path: path, body: body, timeout: timeout)
        var (data, http) = try await perform(req)
        if http.statusCode == 401, let token, !token.isEmpty {
            wlog("api", "401 \(method) \(path)，用 appToken 重新登录后重试")
            // session cookie 过期：用 appToken 重新登录一次，cookie 注入共享存储后重试。
            let relogged = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                WandAuth.loginWithToken(serverURL: baseURL, appToken: token) { result in
                    if case .success = result { cont.resume(returning: true) }
                    else { cont.resume(returning: false) }
                }
            }
            guard relogged else { throw APIError.unauthorized }
            (data, http) = try await perform(req)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                wlog("api", "401 \(method) \(path)（重登后仍失败）")
                throw APIError.unauthorized
            }
            var message = "服务器返回 \(http.statusCode)"
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String, !err.isEmpty {
                message = err
            }
            wlog("api", "\(http.statusCode) \(method) \(path): \(message)")
            throw APIError.server(status: http.statusCode, message: message)
        }
        return data
    }

    private func request<T: Decodable>(_ type: T.Type, method: String, path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> T {
        let data = try await requestData(method: method, path: path, body: body, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.network("响应解析失败：\(error.localizedDescription)")
        }
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// 路径参数不能使用 urlPathAllowed（其包含 `/`），否则 tool use id 中的
    /// 分隔符可能改变 endpoint 路径层级。
    private func percentEncodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=:%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 会话

    func listSessions() async throws -> [SessionSnapshot] {
        try await request([SessionSnapshot].self, method: "GET", path: "/api/sessions")
    }

    /// 块级窗口：带 blockBudget 时服务端只回最近这么多个内容块（必要时切掉最旧 turn 的头部），
    /// 根治「单条 turn 上百块/1MB」长任务的打开慢。blockBudget=0 退回 turn 级窗口。
    func getSession(id: String, blockBudget: Int = WandAPI.chatBlockWindow) async throws -> SessionSnapshot {
        var path = "/api/sessions/\(id)?format=chat"
        if blockBudget > 0 { path += "&blockBudget=\(blockBudget)" }
        return try await request(SessionSnapshot.self, method: "GET", path: path)
    }

    /// 历史消息分页：返回完整历史的 [offset, offset+limit) 这一段。
    func fetchMessages(id: String, offset: Int, limit: Int) async throws -> MessagesPage {
        try await request(MessagesPage.self, method: "GET",
                          path: "/api/sessions/\(id)/messages?offset=\(offset)&limit=\(limit)")
    }

    /// 块级翻页：取某条 turn 的 [start, blockOffset) 段内容块（start = max(0, blockOffset - blockLimit)）。
    func fetchEarlierBlocks(id: String, turn: Int, blockOffset: Int, blockLimit: Int) async throws -> BlocksPage {
        try await request(BlocksPage.self, method: "GET",
                          path: "/api/sessions/\(id)/messages?turn=\(turn)&blockOffset=\(blockOffset)&blockLimit=\(blockLimit)")
    }

    /// 按需取回被消息窗口截断的完整 tool_result 内容。
    func fetchToolContent(id: String, toolUseId: String) async throws -> ToolContentResponse {
        try await request(
            ToolContentResponse.self,
            method: "GET",
            path: "/api/sessions/\(percentEncodePathComponent(id))/tool-content/\(percentEncodePathComponent(toolUseId))"
        )
    }

    func models() async throws -> ModelsResponse {
        try await request(ModelsResponse.self, method: "GET", path: "/api/models")
    }

    /// 重新探测各 CLI 的可用模型，并返回刷新后的统一模型目录。
    ///
    /// 与 `models()` 保持独立，避免普通页面加载每次都触发耗时的 CLI 探测。
    func refreshModels() async throws -> ModelsResponse {
        try await request(
            ModelsResponse.self,
            method: "POST",
            path: "/api/models/refresh",
            timeout: Self.modelRefreshTimeout
        )
    }

    @discardableResult
    func setModel(id: String, model: String?) async throws -> SessionSnapshot {
        try await request(
            SessionSnapshot.self,
            method: "POST",
            path: "/api/sessions/\(id)/model",
            body: ["model": model ?? NSNull()]
        )
    }

    @discardableResult
    func setThinkingEffort(id: String, thinkingEffort: String) async throws -> SessionSnapshot {
        try await request(
            SessionSnapshot.self,
            method: "POST",
            path: "/api/sessions/\(id)/thinking-effort",
            body: ["thinkingEffort": thinkingEffort]
        )
    }

    @discardableResult
    func setMode(id: String, mode: String) async throws -> SessionSnapshot {
        try await request(
            SessionSnapshot.self,
            method: "POST",
            path: "/api/sessions/\(id)/mode",
            body: ["mode": mode]
        )
    }

    func uploadAttachments(id: String, urls: [URL]) async throws -> [UploadedFile] {
        let boundary = "WandBoundary-\(UUID().uuidString)"
        var body = Data()
        for url in urls.prefix(5) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 10 * 1024 * 1024 else {
                throw APIError.network("\(url.lastPathComponent) 超过 10 MB")
            }
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(url.lastPathComponent)\"\r\n")
            body.append("Content-Type: application/octet-stream\r\n\r\n")
            body.append(data)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")

        guard let url = URL(string: "/api/sessions/\(id)/upload", relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, http) = try await perform(req)
        guard (200...299).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, message: "附件上传失败")
        }
        return try JSONDecoder().decode(UploadResponse.self, from: data).files
    }

    @discardableResult
    func sendInput(
        id: String,
        input: String,
        view: String? = nil,
        shortcutKey: String? = nil,
        respondImmediately: Bool = false
    ) async throws -> SessionSnapshot {
        var body: [String: Any] = ["input": input]
        if let view { body["view"] = view }
        if let shortcutKey { body["shortcutKey"] = shortcutKey }
        if respondImmediately { body["respondImmediately"] = true }
        return try await request(SessionSnapshot.self, method: "POST", path: "/api/sessions/\(id)/input", body: body)
    }

    @discardableResult
    func stopSession(id: String) async throws -> SessionSnapshot {
        try await request(SessionSnapshot.self, method: "POST", path: "/api/sessions/\(id)/stop", body: [:])
    }

    // MARK: - 排队消息（仅结构化会话）

    /// 由服务端按 index 摘掉队列项并立即发送，避免客户端与自动 flush 重复发送。
    @discardableResult
    func promoteQueued(id: String, index: Int, expectedText: String) async throws -> SessionSnapshot {
        let body: [String: Any] = [
            "expectedText": expectedText,
            "idempotencyKey": UUID().uuidString,
        ]
        return try await request(
            SessionSnapshot.self,
            method: "POST",
            path: "/api/structured-sessions/\(id)/queued/\(index)/promote",
            body: body
        )
    }

    /// 删除第 index 条排队消息。
    func deleteQueued(id: String, index: Int) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/api/structured-sessions/\(id)/queued/\(index)"
        )
    }

    /// 清空全部排队消息。
    func clearQueued(id: String) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/api/structured-sessions/\(id)/queued"
        )
    }

    func deleteSession(id: String) async throws {
        _ = try await requestData(method: "DELETE", path: "/api/sessions/\(id)")
    }

    @discardableResult
    func resumeSession(id: String) async throws -> SessionSnapshot {
        try await request(SessionSnapshot.self, method: "POST", path: "/api/sessions/\(id)/resume", body: [:])
    }

    // MARK: - 历史会话

    func listClaudeHistory() async throws -> [HistorySession] {
        try await request([HistorySession].self, method: "GET", path: "/api/claude-history")
    }

    func listCodexHistory() async throws -> [HistorySession] {
        try await request([HistorySession].self, method: "GET", path: "/api/codex-history")
    }

    @discardableResult
    func resumeHistory(_ history: HistorySession) async throws -> SessionSnapshot {
        let provider = history.provider == "codex" ? "codex" : "claude"
        return try await request(
            SessionSnapshot.self,
            method: "POST",
            path: "/api/\(provider)-sessions/\(percentEncode(history.claudeSessionId))/resume",
            body: ["cwd": history.cwd]
        )
    }

    func deleteHistory(_ history: HistorySession) async throws {
        let provider = history.provider == "codex" ? "codex" : "claude"
        _ = try await requestData(
            method: "DELETE",
            path: "/api/\(provider)-history/\(percentEncode(history.claudeSessionId))"
        )
    }

    func deleteHistoryBatch(provider: String, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await requestData(
            method: "POST",
            path: "/api/\(provider)-history/batch-delete",
            body: ["claudeSessionIds": ids]
        )
    }

    // MARK: - 权限

    @discardableResult
    func resolveEscalation(sessionId: String, requestId: String, resolution: String) async throws -> SessionSnapshot {
        try await request(
            SessionSnapshot.self,
            method: "POST",
            path: "/api/sessions/\(sessionId)/escalations/\(percentEncode(requestId))/resolve",
            body: ["resolution": resolution]
        )
    }

    @discardableResult
    func approvePermission(sessionId: String) async throws -> SessionSnapshot {
        try await request(SessionSnapshot.self, method: "POST", path: "/api/sessions/\(sessionId)/approve-permission", body: [:])
    }

    @discardableResult
    func denyPermission(sessionId: String) async throws -> SessionSnapshot {
        try await request(SessionSnapshot.self, method: "POST", path: "/api/sessions/\(sessionId)/deny-permission", body: [:])
    }

    // MARK: - 新建会话

    /// 结构化会话（非 PTY）：POST /api/structured-sessions。
    @discardableResult
    func createStructuredSession(
        provider: String,
        cwd: String,
        mode: String?,
        model: String?,
        thinkingEffort: String?,
        prompt: String?
    ) async throws -> SessionSnapshot {
        let normalizedProvider = WandProvider(normalizing: provider)
        var body: [String: Any] = [
            "provider": normalizedProvider.rawValue,
            "runner": normalizedProvider.structuredRunner,
            "cwd": cwd,
        ]
        if let mode, !mode.isEmpty { body["mode"] = mode }
        if let model, !model.isEmpty { body["model"] = model }
        if let thinkingEffort, !thinkingEffort.isEmpty { body["thinkingEffort"] = thinkingEffort }
        if let prompt, !prompt.isEmpty { body["prompt"] = prompt }
        return try await request(SessionSnapshot.self, method: "POST", path: "/api/structured-sessions", body: body)
    }

    /// PTY 会话：POST /api/commands。Qoder 的 provider ID 与可执行命令名称不同。
    @discardableResult
    func createPtySession(
        provider: String,
        cwd: String,
        mode: String?,
        model: String?,
        thinkingEffort: String?,
        initialInput: String?
    ) async throws -> SessionSnapshot {
        let normalizedProvider = WandProvider(normalizing: provider).rawValue
        let command = normalizedProvider == WandProvider.qoder.rawValue ? "qodercli" : normalizedProvider
        var body: [String: Any] = ["command": command, "provider": normalizedProvider, "cwd": cwd]
        if let mode, !mode.isEmpty { body["mode"] = mode }
        if let model, !model.isEmpty { body["model"] = model }
        if let thinkingEffort, !thinkingEffort.isEmpty { body["thinkingEffort"] = thinkingEffort }
        if let initialInput, !initialInput.isEmpty { body["initialInput"] = initialInput }
        return try await request(SessionSnapshot.self, method: "POST", path: "/api/commands", body: body)
    }

    // MARK: - Git 快速提交

    func gitStatus(sessionId: String) async throws -> GitStatusResult {
        try await request(GitStatusResult.self, method: "GET", path: "/api/sessions/\(sessionId)/git-status")
    }

    /// 快速提交：message 留空（customMessage = nil）时服务端用 AI 根据 staged diff 生成；
    /// `autoTag` 时再让 AI 推荐下一个语义化版本号。AI 链路服务端单次最长 60s
    /// （message + tag 两次）+ push 30s，所以请求超时放宽到 180s。
    func quickCommit(
        sessionId: String,
        customMessage: String?,
        tag: String?,
        autoTag: Bool,
        push: Bool,
        submodule: Bool
    ) async throws -> QuickCommitResult {
        var body: [String: Any] = [
            "autoMessage": customMessage == nil,
            "autoTag": autoTag,
            "push": push,
            "submodule": submodule,
        ]
        if let customMessage { body["customMessage"] = customMessage }
        if let tag, !tag.isEmpty { body["tag"] = tag }
        return try await request(
            QuickCommitResult.self,
            method: "POST",
            path: "/api/sessions/\(sessionId)/quick-commit",
            body: body,
            timeout: 180
        )
    }

    /// AI 预生成 commit message 与推荐 tag（只生成不提交，对应网页版「AI」按钮）。
    func generateCommitMessage(sessionId: String) async throws -> GenerateCommitMessageResult {
        try await request(
            GenerateCommitMessageResult.self,
            method: "POST",
            path: "/api/sessions/\(sessionId)/generate-commit-message",
            body: [:],
            timeout: 180
        )
    }

    /// 补推送：把已有 commit / tag 推到远端；submodule 为 true 时递归推送各 submodule。
    func gitPush(
        sessionId: String,
        pushCommits: Bool,
        pushTags: Bool,
        submodule: Bool,
        tag: String?
    ) async throws -> GitPushResult {
        var body: [String: Any] = [
            "pushCommits": pushCommits,
            "pushTags": pushTags,
            "submodule": submodule,
        ]
        if let tag, !tag.isEmpty { body["tag"] = tag }
        return try await request(
            GitPushResult.self,
            method: "POST",
            path: "/api/sessions/\(sessionId)/git/push",
            body: body,
            timeout: 180
        )
    }

    // MARK: - 目录与配置

    func listDirectory(_ query: String) async throws -> DirectoryListing {
        try await request(DirectoryListing.self, method: "GET", path: "/api/directory?q=\(percentEncode(query))")
    }

    func recentPaths() async throws -> [RecentPath] {
        try await request([RecentPath].self, method: "GET", path: "/api/recent-paths")
    }

    func serverConfig() async throws -> ServerConfigInfo {
        try await request(ServerConfigInfo.self, method: "GET", path: "/api/config")
    }

    func installServerUpdate() async throws {
        _ = try await requestData(method: "POST", path: "/api/update", body: [:], timeout: 180)
    }

    func updateNewSessionDefaults(
        mode: String? = nil,
        model: String? = nil,
        provider: String = "claude",
        thinkingEffort: String? = nil,
        defaultProvider: String? = nil,
        defaultSessionKind: String? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let mode { body["defaultMode"] = mode }
        if let model {
            switch WandProvider(normalizing: provider) {
            case .codex:
                body["defaultCodexModel"] = model
                body["defaultModels"] = ["codex": model]
            case .opencode:
                body["defaultOpenCodeModel"] = model
                body["defaultModels"] = ["opencode": model]
            case .grok:
                break
            case .qoder:
                body["defaultQoderModel"] = model
                body["defaultModels"] = ["qoder": model]
            case .claude:
                body["defaultModel"] = model
                body["defaultModels"] = ["claude": model]
            }
        }
        if let thinkingEffort { body["defaultThinkingEffort"] = thinkingEffort }
        if let defaultProvider { body["defaultProvider"] = defaultProvider }
        if let defaultSessionKind { body["defaultSessionKind"] = defaultSessionKind }
        _ = try await requestData(method: "POST", path: "/api/settings/config", body: body)
    }
}
