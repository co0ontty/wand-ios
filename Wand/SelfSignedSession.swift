import Foundation

/// Endpoint-scoped native networking session: self-signed certificate trust plus an
/// in-memory cookie jar that is never shared with another canonical Wand endpoint.
///
/// Cookie matching intentionally cannot be the isolation seam: RFC cookies do not include
/// ports, so two Wand servers on `host:3000` and `host:4000` would otherwise share login
/// state. REST, WebSocket, auth, and resource callers must obtain the instance for their
/// base URL through `forEndpoint(_:)`.
final class SelfSignedSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private final class EndpointPool: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: SelfSignedSession] = [:]

        func value(for key: String, baseURL: URL) -> SelfSignedSession {
            lock.lock()
            defer { lock.unlock() }
            if let existing = entries[key] { return existing }
            let created = SelfSignedSession(baseURL: baseURL)
            entries[key] = created
            return created
        }

        func removeValue(for key: String) -> SelfSignedSession? {
            lock.lock()
            defer { lock.unlock() }
            return entries.removeValue(forKey: key)
        }

        func removeAll() -> [SelfSignedSession] {
            lock.lock()
            defer { lock.unlock() }
            let values = Array(entries.values)
            entries.removeAll()
            return values
        }
    }

    private static let endpointPool = EndpointPool()

    /// Compatibility instance for callers not yet carrying an endpoint. New code must use
    /// `forEndpoint(_:)`; keeping this avoids a flag-day migration of unrelated image code.
    static let shared = SelfSignedSession(baseURL: nil)

    static func forEndpoint(_ baseURL: URL) -> SelfSignedSession {
        let key = endpointKey(for: baseURL)
        return endpointPool.value(for: key, baseURL: baseURL)
    }

    /// Retires every task and cookie for one endpoint. A later lookup creates a clean session.
    static func resetEndpoint(_ baseURL: URL) {
        let key = endpointKey(for: baseURL)
        let retired = endpointPool.removeValue(for: key)
        retired?.retire()
    }

    static func resetAllEndpoints() {
        let retired = endpointPool.removeAll()
        retired.forEach { $0.retire() }
    }

    private static func endpointKey(for baseURL: URL) -> String {
        (try? ServerProfiles.canonicalBaseURL(baseURL.absoluteString).absoluteString)
            ?? baseURL.absoluteString
    }

    /// `URLSessionConfiguration.ephemeral` creates a distinct in-memory cookie storage for
    /// each configuration. Exposing it lets auth recover multiple `Set-Cookie` headers.
    var cookieStorage: HTTPCookieStorage? { session.configuration.httpCookieStorage }

    private let lifecycleLock = NSLock()
    private var retired = false
    /// Keeps authenticated resource caches scoped to this exact credential lifetime.
    let resourceCacheNamespace = UUID().uuidString

    /// A retained endpoint client must fail closed after its profile is removed or its
    /// credentials are replaced. Only a new client may look up the replacement pool entry.
    var isRetired: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return retired
    }

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let endpointScope: WandEndpointScope?

    private init(baseURL: URL?) {
        self.endpointScope = baseURL.flatMap(WandEndpointScope.init)
        super.init()
    }

    private func retire() {
        lifecycleLock.lock()
        guard !retired else {
            lifecycleLock.unlock()
            return
        }
        retired = true
        lifecycleLock.unlock()

        if let cookies = cookieStorage?.cookies {
            for cookie in cookies {
                cookieStorage?.deleteCookie(cookie)
            }
        }
        session.invalidateAndCancel()
    }

    // MARK: - URLSessionDelegate

    // Wand is a LAN/self-hosted service and its generated HTTPS certificate is self-signed.
    // The exception applies only to the exact endpoint that owns this session.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              endpointScope?.usesHTTPS == true,
              endpointScope?.matches(challenge.protectionSpace) == true,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// URLSession follows redirects automatically. Keep every REST/auth/resource task inside
    /// its endpoint so a response cannot carry the endpoint cookie to another port or path.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              endpointScope?.contains(target) == true else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
