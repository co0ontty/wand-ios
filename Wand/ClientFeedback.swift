import Foundation

/// A stack is sent only when captured by the failing operation itself, never from the reporter's thread.
protocol ClientFeedbackStackProviding: Error {
    var feedbackStack: String? { get }
}

struct ClientFeedbackError: Codable, Equatable {
    let name: String
    let message: String
    let code: String?
    let stack: String?

    init(_ error: Error, secrets: [String] = []) {
        let native = error as NSError
        name = Self.clean(native.domain, secrets: secrets, maxBytes: 512)
        code = String(native.code)
        var details = [native.localizedDescription, "Domain: \(native.domain); code: \(native.code)"]
        if !(type(of: error) is NSError.Type), !(error is LocalizedError) {
            details.insert(String(describing: error), at: 0)
        }
        if let reason = native.localizedFailureReason { details.append(reason) }
        if let suggestion = native.localizedRecoverySuggestion { details.append(suggestion) }
        // Do not serialize userInfo: it can contain URLs, requests, or application content.
        if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("Underlying: \(underlying.domain) (\(underlying.code)): \(underlying.localizedDescription)")
        }
        message = Self.clean(details.joined(separator: "\n"), secrets: secrets, maxBytes: 8192)
        stack = (error as? ClientFeedbackStackProviding)?.feedbackStack.map {
            Self.clean($0, secrets: secrets, maxBytes: 16384)
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let native = error as NSError
        return native.domain == NSURLErrorDomain && native.code == NSURLErrorCancelled
    }

    static func clean(_ value: String, secrets: [String], maxBytes: Int) -> String {
        var result = value
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        for pattern in [
            #"(?i)\b(authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+"#,
            #"(?i)\b(bearer)\s+[^\s,;\"']+"#,
            #"(?i)([\"']?(?:password|passwd|token|appToken|access_token|refresh_token|api[_-]?key|secret)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;&}\]]+)"#,
            #"(?i)(https?://)[^/@\s]+:[^/@\s]+@"#,
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1[REDACTED]")
        }
        // Decode a complete UTF-8 prefix without inserting replacement characters at the boundary.
        var bytes = Array(result.utf8.prefix(maxBytes))
        while String(bytes: bytes, encoding: .utf8) == nil && !bytes.isEmpty { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

struct ClientFeedbackReport: Encodable {
    let schema = 1
    let source = "ios"
    let event: String
    let version: String
    let feature: String
    let error: ClientFeedbackError

    static func allows(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        let host = url.host?.lowercased()
        return url.scheme?.lowercased() == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]")
    }

    /// Feedback never follows a redirect, including a same-origin redirect. Other native requests keep their existing policy.
    static func permitsRedirect(originalURL: URL?) -> Bool {
        !isFeedbackRequest(originalURL)
    }

    static func isFeedbackRequest(_ url: URL?) -> Bool {
        url?.path.hasSuffix("/api/feedback/client") == true
    }

    /// Mirrors main src/feedback-feature-map.ts FEEDBACK_API_FEATURES; checked by scripts/test-feedback.sh.
    static let apiFeatures: [String: String] = [
        "sessions": "sessions", "structured-sessions": "sessions", "commands": "sessions", "session-list": "sessions", "session-directories": "sessions",
        "conversations": "conversations",
        "wand-tasks": "tasks", "wand-task-agent-defaults": "tasks", "tasks": "tasks", "workspace-tasks": "tasks", "workspaces": "tasks", "wand-milestones": "tasks", "missions": "tasks", "scheduled-tasks": "tasks",
        "files": "files", "upload": "files", "directory": "files", "session-files": "files", "file-preview": "files", "file-read": "files", "file-write": "files", "recent-paths": "files",
        "settings": "settings", "config": "settings", "user-profile": "settings", "auto-update": "settings", "update-channel": "settings",
        "models": "models", "model-groups": "models", "local-models": "models",
        "login": "authentication", "logout": "authentication", "app-login": "authentication", "session-check": "authentication", "set-password": "authentication",
        "update": "server_update", "update-status": "server_update", "check-update": "server_update",
        "android-apk-update": "app_update", "android-apk": "app_update", "macos-app-update": "app_update", "macos-dmg-update": "app_update", "macos-dmg": "app_update", "ios-ipa-update": "app_update", "ios-ipa": "app_update",
        "provider-cli-updates": "provider_update", "daemon-maintenance": "daemon_update", "storage-cleanup": "storage",
        "git": "repository", "github": "repository",
    ]

    /// Explicit route families only; no IDs, paths, queries, or error text become features.
    static func feature(path: String) -> String {
        let components = path.components(separatedBy: "?")[0].components(separatedBy: "/")
        let family = components.count > 2 ? components[2] : ""
        return apiFeatures[family] ?? "api"
    }
}

/// Shared across transient API/view/socket instances: no queue, at most two sends, ten/minute,
/// and one matching error per endpoint/event/feature in five minutes. Failed reports are dropped.
final class ClientFeedbackLimiter: @unchecked Sendable {
    static let shared = ClientFeedbackLimiter()
    private let lock = NSLock()
    private var active = 0
    private var sent: [Date] = []
    private var recent: [String: Date] = [:]

    func begin(key: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        sent.removeAll { now.timeIntervalSince($0) >= 60 }
        recent = recent.filter { now.timeIntervalSince($0.value) < 300 }
        guard active < 2, sent.count < 10, recent[key] == nil else { return false }
        active += 1; sent.append(now); recent[key] = now
        return true
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        active = max(0, active - 1)
    }
}
