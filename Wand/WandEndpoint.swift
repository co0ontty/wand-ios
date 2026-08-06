import Foundation

/// Resolves an API/WebSocket route without discarding a configured endpoint base path.
/// `URL(string: "/api/...", relativeTo:)` resets that path, which would make two profiles
/// with different reverse-proxy prefixes route to the same server root.
enum WandEndpoint {
    static func url(
        baseURL: URL,
        route: String,
        queryItems: [URLQueryItem]? = nil
    ) -> URL? {
        guard var base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let relative = URLComponents(string: route),
              isSafePercentEncodedPath(base.percentEncodedPath),
              isSafePercentEncodedPath(relative.percentEncodedPath) else { return nil }

        let basePath = base.percentEncodedPath.trimmingTrailingSlashes
        let routePath = relative.percentEncodedPath.hasPrefix("/")
            ? relative.percentEncodedPath
            : "/\(relative.percentEncodedPath)"
        base.percentEncodedPath = basePath + routePath
        if let queryItems {
            guard let encodedQuery = percentEncodedQuery(queryItems) else { return nil }
            base.percentEncodedQuery = encodedQuery
        } else {
            base.percentEncodedQuery = relative.percentEncodedQuery
        }
        base.percentEncodedFragment = relative.percentEncodedFragment
        return base.url
    }

    static func webSocketURL(baseURL: URL, route: String = "/ws") -> URL? {
        guard let resolved = url(baseURL: baseURL, route: route),
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        return components.url
    }

    /// Rejects path forms that a reverse proxy can reinterpret outside the configured
    /// namespace. The check is repeated because some proxy stacks decode more than once;
    /// backslashes are treated as separators for compatibility with URL normalizers.
    static func isSafePercentEncodedPath(_ path: String) -> Bool {
        var candidate = path
        for _ in 0..<8 {
            let segments = candidate
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: false)
            guard !segments.contains(where: { $0 == "." || $0 == ".." }) else {
                return false
            }

            guard candidate.contains("%"),
                  let decoded = candidate.removingPercentEncoding,
                  decoded != candidate else {
                return true
            }
            candidate = decoded
        }

        // Excessively nested escaping is ambiguous across proxy implementations.
        return false
    }

    /// URLComponents intentionally leaves `+` unescaped, but many HTTP query parsers treat
    /// it as a space. Encode names and values using only RFC 3986 unreserved characters so
    /// paths, revision ids, and other opaque values survive a server round trip exactly.
    static func percentEncodedQuery(_ items: [URLQueryItem]) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var encodedItems: [String] = []
        encodedItems.reserveCapacity(items.count)
        for item in items {
            guard let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return nil
            }
            guard let value = item.value else {
                encodedItems.append(name)
                continue
            }
            guard let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return nil
            }
            encodedItems.append("\(name)=\(encodedValue)")
        }
        return encodedItems.joined(separator: "&")
    }
}

/// Security boundary for one configured Wand endpoint. URL cookies do not include a port,
/// and reverse-proxy deployments can also host more than one Wand instance under different
/// path prefixes, so both the effective origin and the base-path boundary are significant.
struct WandEndpointScope: Equatable {
    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int?

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased(),
                  !host.isEmpty else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = Self.effectivePort(scheme: scheme, explicitPort: url.port)
        }

        init?(protectionSpace: URLProtectionSpace) {
            guard let scheme = protectionSpace.protocol?.lowercased(),
                  !protectionSpace.host.isEmpty else { return nil }
            self.scheme = scheme
            self.host = protectionSpace.host.lowercased()
            self.port = Self.effectivePort(
                scheme: scheme,
                explicitPort: protectionSpace.port > 0 ? protectionSpace.port : nil
            )
        }

        private static func effectivePort(scheme: String, explicitPort: Int?) -> Int? {
            if let explicitPort { return explicitPort }
            switch scheme {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }
    }

    private let origin: Origin
    private let basePath: String

    init?(_ baseURL: URL) {
        guard let origin = Origin(baseURL),
              (origin.scheme == "http" || origin.scheme == "https"),
              let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              WandEndpoint.isSafePercentEncodedPath(components.percentEncodedPath) else {
            return nil
        }
        self.origin = origin
        self.basePath = components.percentEncodedPath.trimmingTrailingSlashes
    }

    var usesHTTPS: Bool { origin.scheme == "https" }

    /// Allows only this endpoint's origin and reverse-proxy path namespace.
    func contains(_ url: URL) -> Bool {
        guard Origin(url) == origin,
              let path = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )?.percentEncodedPath,
              WandEndpoint.isSafePercentEncodedPath(path) else { return false }
        return basePath.isEmpty || path == basePath || path.hasPrefix(basePath + "/")
    }

    /// Certificate challenges have no URL path, so restrict them to the exact configured
    /// scheme, host, and effective port. A challenge reached after an external redirect must
    /// never inherit Wand's self-signed-certificate exception.
    func matches(_ protectionSpace: URLProtectionSpace) -> Bool {
        Origin(protectionSpace: protectionSpace) == origin
    }
}

/// Builds a WebKit content blocker that allows document/subresource traffic only inside one
/// Wand endpoint. Navigation delegates do not see fetch/XHR/script/image requests, and WebKit
/// cookies ignore ports, so this is the network boundary for embedded web content.
enum WandEndpointContentBoundary {
    static func contentRuleListJSON(baseURL: URL) -> String? {
        guard let prefixes = resourcePrefixes(baseURL: baseURL), !prefixes.isEmpty else { return nil }
        var rules: [[String: Any]] = [
            [
                "trigger": ["url-filter": ".*"],
                "action": ["type": "block"],
            ],
        ]
        for filter in prefixes.flatMap(allowedURLFilters(prefix:)) + ["^about:", "^blob:", "^data:"] {
            rules.append([
                "trigger": [
                    "url-filter": filter,
                    "url-filter-is-case-sensitive": false,
                ],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        // These rules intentionally follow the allow rules. WebKit applies a later block
        // after ignore-previous-rules, so an allowed origin cannot smuggle a traversal path.
        for filter in prefixes.flatMap(unsafePathFilters(prefix:)) {
            rules.append([
                "trigger": [
                    "url-filter": filter,
                    "url-filter-is-case-sensitive": false,
                ],
                "action": ["type": "block"],
            ])
        }
        guard JSONSerialization.isValidJSONObject(rules),
              let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    static func allowedURLFilters(baseURL: URL) -> [String]? {
        resourcePrefixes(baseURL: baseURL)?.flatMap(allowedURLFilters(prefix:))
    }

    private static func resourcePrefixes(baseURL: URL) -> [String]? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        components.query = nil
        components.fragment = nil
        components.percentEncodedPath = components.percentEncodedPath.trimmingTrailingSlashes
        guard WandEndpoint.isSafePercentEncodedPath(components.percentEncodedPath) else {
            return nil
        }

        let webSocketScheme = scheme == "https" ? "wss" : "ws"
        return [scheme, webSocketScheme].compactMap { allowedScheme in
            var allowed = components
            allowed.scheme = allowedScheme
            return allowed.url?.absoluteString
        }
    }

    /// WebKit content blockers support a deliberately small regex subset and reject
    /// disjunctions. Multiple simple rules cover exact, query/fragment, and path forms.
    private static func allowedURLFilters(prefix: String) -> [String] {
        let prefix = NSRegularExpression.escapedPattern(for: prefix)
        return ["^\(prefix)$", "^\(prefix)[?#]", "^\(prefix)/"]
    }

    /// Limit the checks to bytes before `?`/`#`, so opaque query values such as an encoded
    /// absolute file path remain valid. `%25` is rejected in a URL path to prevent a second
    /// decoder from revealing one of the other dangerous escapes.
    private static func unsafePathFilters(prefix: String) -> [String] {
        let prefix = NSRegularExpression.escapedPattern(for: prefix)
        return [
            "^\(prefix)[^?#]*%25",
            "^\(prefix)[^?#]*%2e",
            "^\(prefix)[^?#]*%2f",
            "^\(prefix)[^?#]*%5c",
            #"^\#(prefix)[^?#]*\\"#,
            #"^\#(prefix)[^?#]*/\.\.?/"#,
            #"^\#(prefix)[^?#]*/\.\.?$"#,
            #"^\#(prefix)[^?#]*/\.\.?\?"#,
            #"^\#(prefix)[^?#]*/\.\.?#"#,
        ]
    }
}

private extension String {
    var trimmingTrailingSlashes: String {
        var result = self
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
