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

    private func makeRequest(method: String, path: String, body: [String: Any]?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
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
    private func requestData(method: String, path: String, body: [String: Any]? = nil) async throws -> Data {
        let req = try makeRequest(method: method, path: path, body: body)
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

    private func request<T: Decodable>(_ type: T.Type, method: String, path: String, body: [String: Any]? = nil) async throws -> T {
        let data = try await requestData(method: method, path: path, body: body)
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
    func createStructuredSession(cwd: String, mode: String?, prompt: String?) async throws -> SessionSnapshot {
        var body: [String: Any] = ["cwd": cwd]
        if let mode, !mode.isEmpty { body["mode"] = mode }
        if let prompt, !prompt.isEmpty { body["prompt"] = prompt }
        return try await request(SessionSnapshot.self, method: "POST", path: "/api/structured-sessions", body: body)
    }

    /// PTY 会话：POST /api/commands（command 固定 claude，由服务端解析别名）。
    @discardableResult
    func createPtySession(cwd: String, mode: String?, initialInput: String?) async throws -> SessionSnapshot {
        var body: [String: Any] = ["command": "claude", "cwd": cwd]
        if let mode, !mode.isEmpty { body["mode"] = mode }
        if let initialInput, !initialInput.isEmpty { body["initialInput"] = initialInput }
        return try await request(SessionSnapshot.self, method: "POST", path: "/api/commands", body: body)
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
