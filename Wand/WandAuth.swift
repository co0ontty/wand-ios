import Foundation

/// Token-based login against wand 服务端 `/api/login`，与 macOS 端完全一致（纯 Foundation，跨平台共享逻辑）。
///
/// 服务端不接受 `?token=` query 参数（`requireAuth` 只读 cookie），所以原生壳必须
/// 用 appToken 走一次 `/api/login`，拿到 `Set-Cookie` 头里的 session cookie 注入 `WKHTTPCookieStore`，
/// 然后 WebView 加载 SPA 时才会带着已认证的 cookie。
///
/// 服务端按 scheme 发不同名字的 cookie（详见 src/auth.ts SESSION_COOKIE_*）：
///   - HTTPS：`__Host-wand_session` + 兼容 `wand_session`
///   - HTTP：`wand_session_local`
/// 这里按"任一即可"的策略匹配，以兼容服务端版本演进。
enum WandAuth {

    /// 服务端可能发送的所有 session cookie 名字。任一存在即视为登录成功。
    static let sessionCookieNames: Set<String> = [
        "__Host-wand_session",
        "wand_session_local",
        "wand_session",
    ]

    enum Failure: Error {
        case invalidURL
        case network(String)
        case unauthorized
        case rateLimited
        case server(Int)
        case noCookie

        var userMessage: String {
            switch self {
            case .invalidURL: return "无效的服务器地址"
            case .network(let m): return "无法连接到服务器：\(m)"
            case .unauthorized: return "认证失败，连接码可能已过期（密码已更改），请重新获取连接码"
            case .rateLimited: return "登录尝试次数过多，请稍后再试"
            case .server(let code): return "服务器返回异常状态码：\(code)"
            case .noCookie: return "服务器未返回 session cookie"
            }
        }
    }

    final class ConnectionAttempt {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cleanup: (() -> Void)?
        private var cancelled = false
        private var finished = false

        func setTask(_ task: URLSessionTask?) {
            lock.lock()
            if cancelled || finished {
                lock.unlock()
                task?.cancel()
                return
            }
            self.task = task
            lock.unlock()
        }

        func setCleanup(_ cleanup: @escaping () -> Void) {
            lock.lock()
            if cancelled {
                lock.unlock()
                cleanup()
                return
            }
            self.cleanup = cleanup
            lock.unlock()
        }

        func isCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        /// 只有第一个未取消的终态回调可以提交 cookie 并通知 UI。
        func finish(commit: () -> Void = {}) -> Bool {
            lock.lock()
            guard !cancelled, !finished else {
                lock.unlock()
                return false
            }
            // commit 与取消共用同一把锁，消除“已 finish 但尚未写 cookie”的窗口。
            commit()
            finished = true
            task = nil
            cleanup = nil
            lock.unlock()
            return true
        }

        func cancel() {
            lock.lock()
            guard !cancelled, !finished else {
                lock.unlock()
                return
            }
            cancelled = true
            let task = task
            let cleanup = cleanup
            self.task = nil
            self.cleanup = nil
            lock.unlock()
            task?.cancel()
            cleanup?()
        }
    }

    /// POST /api/login with `{ "appToken": ... }`，回调返回解析出的 `wand_session` cookie。
    /// 使用 `SelfSignedSession` 以放行自签名证书。
    @discardableResult
    static func loginWithToken(serverURL: URL,
                               appToken: String,
                               timeout: TimeInterval = 15,
                               endpointSession: SelfSignedSession? = nil,
                               completion: @escaping (Result<[HTTPCookie], Failure>) -> Void) -> URLSessionDataTask? {
        guard let loginURL = WandEndpoint.url(baseURL: serverURL, route: "/api/login") else {
            completion(.failure(.invalidURL))
            return nil
        }

        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["appToken": appToken])
        } catch {
            completion(.failure(.network(error.localizedDescription)))
            return nil
        }

        let sessionHandle = endpointSession ?? SelfSignedSession.forEndpoint(serverURL)
        guard !sessionHandle.isRetired else {
            completion(.failure(.network("服务器连接已关闭")))
            return nil
        }
        let task = sessionHandle.session.dataTask(with: req) { _, response, error in
            guard !sessionHandle.isRetired else {
                completion(.failure(.network("服务器连接已关闭")))
                return
            }
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("无效响应")))
                return
            }
            switch http.statusCode {
            case 200:
                // 优先从 SelfSignedSession 自带的 cookieStorage 拿——URLSession 已经把
                // 所有 Set-Cookie 头都解析完丢进去，不会因 Set-Cookie 合并/覆盖丢失。
                // 兜底再从 header 解析一次（防止 cookieStorage 因 Secure 标记跨 scheme 被滤掉）。
                let storageCookies = sessionHandle.cookieStorage?.cookies(for: loginURL) ?? []
                var headerFields: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let k = key as? String, let v = value as? String { headerFields[k] = v }
                }
                let headerCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: loginURL)
                // 用 name 去重合并两源
                var merged: [String: HTTPCookie] = [:]
                for c in storageCookies { merged[c.name] = c }
                for c in headerCookies where merged[c.name] == nil { merged[c.name] = c }
                let sessionCookies = merged.values.filter { sessionCookieNames.contains($0.name) }
                if !sessionCookies.isEmpty {
                    completion(.success(sessionCookies))
                } else {
                    completion(.failure(.noCookie))
                }
            case 401:
                completion(.failure(.unauthorized))
            case 429:
                completion(.failure(.rateLimited))
            default:
                completion(.failure(.server(http.statusCode)))
            }
        }
        task.resume()
        return task
    }

    // MARK: - 连接码解码

    /// 解码连接码：base64(url#token)。服务端用标准 base64（src/server.ts encodeConnectCode），
    /// 也兼容 URL-safe、无 padding 的变体；token 是 HMAC-SHA256 的 64 位 hex，长度足够。
    static func decodeConnectCode(_ code: String) -> (url: URL, token: String)? {
        guard let decoded = ServerProfiles.decodeConnectCode(code),
              let token = decoded.token else { return nil }
        return (decoded.baseURL, token)
    }

    // MARK: - 智能解析 + 连接

    /// 解析用户输入并验证可达性，得到最终要连接的目标。
    /// - 连接码：走 `/api/login` 校验 token（token 失效会立刻报"连接码已过期"）。
    /// - 裸地址：按 http→https 顺序探测 `/api/session-check`（wand 默认 HTTP，所以 http 优先），
    ///   命中即用该 scheme。
    struct ConnectTarget {
        let url: URL
        let token: String?
    }

    @discardableResult
    static func resolve(
        rawInput: String,
        completion: @escaping (Result<ConnectTarget, Failure>) -> Void
    ) -> ConnectionAttempt {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let attempt = ConnectionAttempt()
            _ = attempt.finish()
            completion(.failure(.invalidURL))
            return attempt
        }

        if let decoded = decodeConnectCode(trimmed) {
            return authenticate(serverURL: decoded.url, appToken: decoded.token) { result in
                completion(result.map {
                    ConnectTarget(url: decoded.url, token: decoded.token)
                })
            }
        }

        // Compatibility with the old recent-connections screen: it now displays only a
        // canonical endpoint, never the token-bearing connection code. Resolve the credential
        // from the endpoint-scoped profile before falling back to an unauthenticated probe.
        if let saved = ServerStore.shared.profile(matching: trimmed),
           let savedToken = saved.token {
            return authenticate(serverURL: saved.baseURL, appToken: savedToken) { result in
                completion(result.map {
                    ConnectTarget(url: saved.baseURL, token: savedToken)
                })
            }
        }

        let candidates = candidateURLs(from: trimmed)
        guard !candidates.isEmpty else {
            let attempt = ConnectionAttempt()
            _ = attempt.finish()
            completion(.failure(.invalidURL))
            return attempt
        }
        let attempt = ConnectionAttempt()
        probeSequential(candidates, index: 0, attempt: attempt, completion: completion)
        return attempt
    }

    /// Token 连接先在临时 cookie jar 中校验；只有未取消的成功尝试才提交到正式端点。
    @discardableResult
    static func authenticate(
        serverURL: URL,
        appToken: String,
        targetEndpointSession: SelfSignedSession? = nil,
        completion: @escaping (Result<Void, Failure>) -> Void
    ) -> ConnectionAttempt {
        let attempt = ConnectionAttempt()
        let temporarySession = SelfSignedSession.temporary(forEndpoint: serverURL)
        attempt.setCleanup { temporarySession.invalidate() }
        let task = loginWithToken(
            serverURL: serverURL,
            appToken: appToken,
            endpointSession: temporarySession
        ) { result in
            defer { temporarySession.invalidate() }
            switch result {
            case .success(let cookies):
                let endpointSession = targetEndpointSession
                    ?? SelfSignedSession.forEndpoint(serverURL)
                var committed = false
                guard attempt.finish(commit: {
                    committed = endpointSession.storeCookiesIfActive(cookies)
                }) else { return }
                guard committed else {
                    completion(.failure(.network("服务器连接已关闭")))
                    return
                }
                completion(.success(()))
            case .failure(let error):
                guard attempt.finish() else { return }
                completion(.failure(error))
            }
        }
        attempt.setTask(task)
        return attempt
    }

    /// 把裸输入展开成规范化候选 URL：已带 scheme 只尝试该地址，否则 http→https。
    static func candidateURLs(from input: String) -> [URL] {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return [] }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return (try? ServerProfiles.canonicalBaseURL(value)).map { [$0] } ?? []
        }
        return ["http://\(value)", "https://\(value)"].compactMap {
            try? ServerProfiles.canonicalBaseURL($0)
        }
    }

    @discardableResult
    static func probeConnection(
        url: URL,
        completion: @escaping (Bool) -> Void
    ) -> ConnectionAttempt {
        let attempt = ConnectionAttempt()
        let task = probe(url: url) { reachable in
            guard attempt.finish() else { return }
            completion(reachable)
        }
        attempt.setTask(task)
        return attempt
    }

    private static func probeSequential(
        _ urls: [URL],
        index: Int,
        attempt: ConnectionAttempt,
        completion: @escaping (Result<ConnectTarget, Failure>) -> Void
    ) {
        guard !attempt.isCancelled() else { return }
        guard index < urls.count else {
            guard attempt.finish() else { return }
            completion(.failure(.network(
                "无法连接到服务器，请确认地址和端口，以及 wand 服务是否在运行"
            )))
            return
        }
        let url = urls[index]
        let task = probe(url: url) { reachable in
            guard !attempt.isCancelled() else { return }
            if reachable {
                guard attempt.finish() else { return }
                completion(.success(ConnectTarget(url: url, token: nil)))
            } else {
                probeSequential(
                    urls,
                    index: index + 1,
                    attempt: attempt,
                    completion: completion
                )
            }
        }
        attempt.setTask(task)
    }

    /// 公开探测必须返回 Wand 契约 `{"authed": Bool}`，且最终响应仍位于同一端点。
    @discardableResult
    static func probe(
        url: URL,
        timeout: TimeInterval = 6,
        completion: @escaping (Bool) -> Void
    ) -> URLSessionDataTask? {
        guard let checkURL = WandEndpoint.url(baseURL: url, route: "/api/session-check") else {
            completion(false)
            return nil
        }
        var req = URLRequest(url: checkURL)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let task = SelfSignedSession.forEndpoint(url).session.dataTask(with: req) { data, response, error in
            completion(error == nil && isValidSessionCheckResponse(
                data: data,
                response: response,
                baseURL: url
            ))
        }
        task.resume()
        return task
    }

    static func isValidSessionCheckResponse(
        data: Data?,
        response: URLResponse?,
        baseURL: URL
    ) -> Bool {
        guard let data,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let finalURL = http.url,
              WandEndpointScope(baseURL)?.contains(finalURL) == true,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["authed"] is Bool else { return false }
        return true
    }
}
