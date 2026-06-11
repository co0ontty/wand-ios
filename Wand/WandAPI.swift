import Foundation

/// wand 服务端 REST 客户端。复用 SelfSignedSession（自签证书放行 + 共享
/// cookieStorage），所以 WandAuth.loginWithToken 拿到的 session cookie 在这里
/// 的每个请求上自动携带；遇到 401 时用存储的 appToken 重新登录一次再重试。
final class WandAPI {
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
            throw APIError.network(error.localizedDescription)
        }
    }

    /// 带 401 自动重登的请求入口。
    private func requestData(method: String, path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Data {
        let req = try makeRequest(method: method, path: path, body: body, timeout: timeout)
        var (data, http) = try await perform(req)
        if http.statusCode == 401, let token, !token.isEmpty {
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
            if http.statusCode == 401 { throw APIError.unauthorized }
            var message = "服务器返回 \(http.statusCode)"
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String, !err.isEmpty {
                message = err
            }
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

    // MARK: - 会话

    func listSessions() async throws -> [SessionSnapshot] {
        try await request([SessionSnapshot].self, method: "GET", path: "/api/sessions")
    }

    func getSession(id: String) async throws -> SessionSnapshot {
        try await request(SessionSnapshot.self, method: "GET", path: "/api/sessions/\(id)?format=chat")
    }

    @discardableResult
    func sendInput(id: String, input: String, view: String? = nil, shortcutKey: String? = nil) async throws -> SessionSnapshot {
        var body: [String: Any] = ["input": input]
        if let view { body["view"] = view }
        if let shortcutKey { body["shortcutKey"] = shortcutKey }
        return try await request(SessionSnapshot.self, method: "POST", path: "/api/sessions/\(id)/input", body: body)
    }

    @discardableResult
    func stopSession(id: String) async throws -> SessionSnapshot {
        try await request(SessionSnapshot.self, method: "POST", path: "/api/sessions/\(id)/stop", body: [:])
    }

    func deleteSession(id: String) async throws {
        _ = try await requestData(method: "DELETE", path: "/api/sessions/\(id)")
    }

    @discardableResult
    func resumeSession(id: String) async throws -> SessionSnapshot {
        try await request(SessionSnapshot.self, method: "POST", path: "/api/sessions/\(id)/resume", body: [:])
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
    func createStructuredSession(provider: String, cwd: String, mode: String?, prompt: String?) async throws -> SessionSnapshot {
        var body: [String: Any] = [
            "provider": provider,
            "runner": provider == "codex" ? "codex-cli-exec" : "claude-cli-print",
            "cwd": cwd,
        ]
        if let mode, !mode.isEmpty { body["mode"] = mode }
        if let prompt, !prompt.isEmpty { body["prompt"] = prompt }
        return try await request(SessionSnapshot.self, method: "POST", path: "/api/structured-sessions", body: body)
    }

    /// PTY 会话：POST /api/commands，command 与 provider 保持一致。
    @discardableResult
    func createPtySession(provider: String, cwd: String, mode: String?, initialInput: String?) async throws -> SessionSnapshot {
        var body: [String: Any] = ["command": provider, "provider": provider, "cwd": cwd]
        if let mode, !mode.isEmpty { body["mode"] = mode }
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
}
