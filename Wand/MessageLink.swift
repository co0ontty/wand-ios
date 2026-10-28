import Foundation

/// The message's immutable source, never the currently selected conversation.
struct WandMessageFileContext: Equatable {
    var sessionID: String? = nil
    var cwd: String? = nil
}

enum WandMessageLinkDestination: Equatable {
    case download(URL, name: String)
    case preview(URL, title: String)
    case external(URL)
    case unavailable(String)
}

enum WandMessageLink {
    private static let invalid = WandMessageLinkDestination.unavailable("链接格式无效或不支持，无法安全打开。")
    private static let missingSource = WandMessageLinkDestination.unavailable("这条相对文件链接缺少来源会话，请使用原会话中的链接或完整服务器路径。")
    private static let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"]

    static func resolve(_ raw: String, baseURL: URL, context: WandMessageFileContext = .init()) -> WandMessageLinkDestination {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty, !hasControls(value), !value.hasPrefix("//") else { return invalid }
        if value.range(of: "^(?:localhost|127\\.0\\.0\\.1|\\[::1\\]):[0-9]+(?:[/#?]|$)", options: [.regularExpression, .caseInsensitive]) != nil {
            value = "http://" + value
        }
        guard let parts = URLComponents(string: value), parts.user == nil, parts.password == nil else { return invalid }
        let scheme = parts.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            guard let url = parts.url, parts.host?.isEmpty == false else { return invalid }
            if let route = endpointRoute(url, baseURL: baseURL), isArtifactRoute(route.percentEncodedPath) {
                return resolveAPI(route, baseURL: baseURL)
            }
            if scheme == "http", loopback.contains(parts.host?.lowercased() ?? "") {
                let host = parts.host?.contains(":") == true ? "::1" : "127.0.0.1"
                let port = parts.port ?? 80
                guard (1...65535).contains(port),
                      let target = WandEndpoint.url(baseURL: baseURL, route: "/api/local-preview/\(host)/\(port)" + (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath) + suffix(parts)) else { return invalid }
                return .preview(target, title: "本地网页预览")
            }
            return .external(url)
        }
        if scheme == "mailto", let url = parts.url { return .external(url) }
        if scheme == "file" {
            guard parts.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true else { return invalid }
            return file(parts.percentEncodedPath.removingPercentEncoding ?? parts.percentEncodedPath,
                search: parts.percentEncodedQuery, fragment: parts.percentEncodedFragment, baseURL: baseURL, context: .init())
        }
        if value.hasPrefix("/api/") { return resolveAPI(parts, baseURL: baseURL) }
        guard scheme == nil || isRelativeLocation(value), !value.hasPrefix("#") else { return invalid }
        // Delimiters are URI syntax only before decoding. %23/%3F stay filename bytes.
        let fragmentParts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let queryParts = fragmentParts[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(queryParts[0])
        return file(path.removingPercentEncoding ?? path,
            search: queryParts.count > 1 ? String(queryParts[1]) : nil,
            fragment: fragmentParts.count > 1 ? String(fragmentParts[1]) : nil,
            baseURL: baseURL, context: context)
    }

    private static func resolveAPI(_ parts: URLComponents, baseURL: URL) -> WandMessageLinkDestination {
        let route = parts.percentEncodedPath
        guard WandEndpoint.isSafePercentEncodedPath(route), !hasControls(route) else { return invalid }
        if route == "/api/file-raw" || route == "/api/file-preview" {
            guard let path = singleQuery("path", parts), (path.hasPrefix("/") || path.hasPrefix("~/")), !path.hasPrefix("//") else { return invalid }
            return file(path, search: navigationSearch(parts), fragment: parts.percentEncodedFragment, baseURL: baseURL, context: .init())
        }
        if route.hasPrefix("/api/session-file/") {
            let segments = route.split(separator: "/")
            guard segments.count == 3, let session = String(segments[2]).removingPercentEncoding,
                  !session.isEmpty, !session.contains("/"), !hasControls(session),
                  let path = singleQuery("path", parts), !path.hasPrefix("/") else { return invalid }
            return file(path, search: navigationSearch(parts), fragment: parts.percentEncodedFragment,
                baseURL: baseURL, context: .init(sessionID: session))
        }
        if route.hasPrefix("/api/local-file/") {
            let segments = route.split(separator: "/", omittingEmptySubsequences: true)
            guard segments.count >= 3, let root = decodeRoot(String(segments[2])), (root.hasPrefix("/") || root.hasPrefix("~/")), !hasControls(root),
                  let url = WandEndpoint.url(baseURL: baseURL, route: route + suffix(parts)) else { return invalid }
            if segments.count == 3 {
                // Existing preview roots can be a directory, so preserve preview intent.
                return .preview(url, title: (root as NSString).lastPathComponent)
            }
            let name = parts.path.components(separatedBy: "/").last ?? "文件"
            if isHTML(name) || route.hasSuffix("/") { return .preview(url, title: name.isEmpty ? "HTML 预览" : name) }
            guard let downloadURL = withFileAction(url, action: "download") else { return invalid }
            return .download(downloadURL, name: name)
        }
        if route.hasPrefix("/api/local-preview/") {
            let segments = route.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count >= 5, loopback.contains(String(segments[3]).lowercased()),
                  let port = Int(segments[4]), (1...65535).contains(port),
                  let url = WandEndpoint.url(baseURL: baseURL, route: route + (segments.count == 5 ? "/" : "") + suffix(parts)) else { return invalid }
            return .preview(url, title: "本地网页预览")
        }
        return invalid
    }

    private static func file(_ original: String, search: String?, fragment: String?, baseURL: URL,
                             context: WandMessageFileContext) -> WandMessageLinkDestination {
        guard !original.isEmpty, !hasControls(original), !original.hasPrefix("//"),
              !["/api", "/android", "/ios", "/macos"].contains(where: { original == $0 || original.hasPrefix($0 + "/") }) else { return invalid }
        var path = original
        let html = isHTML(path) || path.hasSuffix("/")
        let fragment = fragment.flatMap { $0.range(of: "^L[0-9]+(?:C[0-9]+)?$", options: [.regularExpression, .caseInsensitive]) == nil ? $0 : nil }
        let title = (path as NSString).lastPathComponent
        if !path.hasPrefix("/"), !path.hasPrefix("~/") {
            guard URLComponents(string: path)?.scheme == nil || isRelativeLocation(path) else { return invalid }
            if let session = context.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                guard !hasControls(session), let encoded = session.addingPercentEncoding(withAllowedCharacters: allowed) else { return invalid }
                var items = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "mode", value: html ? "preview" : "download")]
                if html, let search, !search.isEmpty { items.append(URLQueryItem(name: "search", value: "?" + search)) }
                guard var url = WandEndpoint.url(baseURL: baseURL, route: "/api/session-file/" + encoded, queryItems: items) else { return invalid }
                if html { guard let withFragment = addingNavigation(url, search: nil, fragment: fragment) else { return invalid }; url = withFragment }
                return html ? .preview(url, title: title) : .download(url, name: title)
            }
            guard let cwd = context.cwd, cwd.hasPrefix("/"), !hasControls(cwd) else { return missingSource }
            var relative: [String] = []
            for segment in path.split(separator: "/") {
                if segment == "." { continue }
                if segment == ".." { guard !relative.isEmpty else { return invalid }; relative.removeLast() }
                else { relative.append(String(segment)) }
            }
            let normalizedCwd = (cwd as NSString).standardizingPath
            path = (normalizedCwd.hasSuffix("/") ? normalizedCwd : normalizedCwd + "/") + relative.joined(separator: "/")
            if original.hasSuffix("/"), !path.hasSuffix("/") { path += "/" }
        }
        if html {
            let encoded = Data(path.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            guard let url = WandEndpoint.url(baseURL: baseURL, route: "/api/local-file/\(encoded)/"),
                  let navigable = addingNavigation(url, search: search, fragment: fragment) else { return invalid }
            return .preview(navigable, title: title)
        }
        guard let url = WandEndpoint.url(baseURL: baseURL, route: "/api/file-raw", queryItems: [URLQueryItem(name: "path", value: path), URLQueryItem(name: "download", value: "1")]) else { return invalid }
        return .download(url, name: title)
    }

    static func endpointRoute(_ url: URL, baseURL: URL) -> URLComponents? {
        guard url.user == nil, url.password == nil, WandEndpointScope(baseURL)?.contains(url) == true,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = base.percentEncodedPath.hasSuffix("/") ? String(base.percentEncodedPath.dropLast()) : base.percentEncodedPath
        parts.scheme = nil; parts.host = nil; parts.port = nil
        parts.percentEncodedPath = String(parts.percentEncodedPath.dropFirst(prefix.count))
        return parts
    }

    static func isArtifactRoute(_ route: String) -> Bool {
        ["/api/file-raw", "/api/file-preview"].contains(route) || ["/api/local-file/", "/api/session-file/", "/api/local-preview/"].contains(where: route.hasPrefix)
    }

    private static func addingNavigation(_ url: URL, search: String?, fragment: String?) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // URLComponents(string:) safely normalizes literal spaces without decoding %23/%3F.
        guard let navigation = URLComponents(string: "https://wand.invalid/" + (search.map { "?" + $0 } ?? "") + (fragment.map { "#" + $0 } ?? "")) else { return nil }
        if search != nil { parts.percentEncodedQuery = navigation.percentEncodedQuery }
        parts.percentEncodedFragment = navigation.percentEncodedFragment
        return parts.url
    }

    /// Add the transport action without re-encoding an application's query bytes.
    static func withFileAction(_ url: URL, action: String) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var fields = (parts.percentEncodedQuery ?? "").split(separator: "&").map(String.init).filter {
            let name = $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding != "__wand_file_action"
        }
        fields.append("__wand_file_action=" + action)
        parts.percentEncodedQuery = fields.joined(separator: "&")
        return parts.url
    }

    private static func singleQuery(_ name: String, _ parts: URLComponents) -> String? {
        var form = parts
        form.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let values = form.queryItems?.filter { $0.name == name } ?? []
        return values.count == 1 ? values[0].value : nil
    }
    private static func navigationSearch(_ parts: URLComponents) -> String? {
        guard let value = singleQuery("search", parts), value.hasPrefix("?"), !hasControls(value) else { return nil }
        return String(value.dropFirst())
    }
    private static func suffix(_ parts: URLComponents) -> String {
        (parts.percentEncodedQuery.map { "?" + $0 } ?? "") + (parts.percentEncodedFragment.map { "#" + $0 } ?? "")
    }
    private static func hasControls(_ value: String) -> Bool { value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    private static func isHTML(_ value: String) -> Bool { value.range(of: "\\.html?(?::[0-9]+(?::[0-9]+)?)?$", options: [.regularExpression, .caseInsensitive]) != nil }
    private static func isRelativeLocation(_ value: String) -> Bool { value.range(of: "^[^:/?#]+\\.[^:/?#]+:[0-9]+(?::[0-9]+)?(?:[?#]|$)", options: .regularExpression) != nil }
    private static func decodeRoot(_ value: String) -> String? {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }
}
