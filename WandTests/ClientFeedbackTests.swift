import Foundation
import XCTest
@testable import Wand

final class ClientFeedbackTests: XCTestCase {
    private struct CapturedError: LocalizedError, ClientFeedbackStackProviding {
        let errorDescription: String? = "Original provider failed: token=hidden"
        let feedbackStack: String? = "providerOperation at original.swift:17\nBearer private-key"
    }
    private enum RawError: Error { case originalFailure }

    func testNSErrorDiagnosticsPreserveOriginalMessageWithoutUserInfoDump() {
        let underlying = NSError(domain: "Disk", code: 28, userInfo: [NSLocalizedDescriptionKey: "No space left"])
        let error = NSError(domain: "OTA", code: 12, userInfo: [
            NSLocalizedDescriptionKey: "Original OTA failure /tmp/package.ipa",
            NSLocalizedFailureReasonErrorKey: "Integrity mismatch",
            NSLocalizedRecoverySuggestionErrorKey: "Download again",
            NSUnderlyingErrorKey: underlying,
            "requestBody": "PRIVATE CHAT BODY",
        ])
        let diagnostic = ClientFeedbackError(error)
        XCTAssertEqual(diagnostic.name, "OTA")
        XCTAssertEqual(diagnostic.code, "12")
        XCTAssertTrue(diagnostic.message.contains("Original OTA failure /tmp/package.ipa"))
        XCTAssertTrue(diagnostic.message.contains("Integrity mismatch"))
        XCTAssertTrue(diagnostic.message.contains("Download again"))
        XCTAssertTrue(diagnostic.message.contains("No space left"))
        XCTAssertFalse(diagnostic.message.contains("PRIVATE CHAT BODY"))
        XCTAssertNil(diagnostic.stack, "The reporting thread is not the exception's original stack")
        XCTAssertTrue(ClientFeedbackError(RawError.originalFailure).message.contains("originalFailure"))
    }

    func testOnlyActualErrorStackIsSentAndCredentialsAreRedacted() {
        let error = ClientFeedbackError(CapturedError())
        XCTAssertTrue(error.message.contains("Original provider failed"))
        XCTAssertFalse(error.message.contains("hidden"))
        XCTAssertTrue(error.stack?.contains("original.swift:17") == true)
        XCTAssertFalse(error.stack?.contains("private-key") == true)
        let clean = ClientFeedbackError.clean("known-secret\nAuthorization: Bearer abc\nCookie: sid=def\npassword=ghi api_key=jkl token=xyz\nhttps://u:p@host/path", secrets: ["known-secret"], maxBytes: 8192)
        for secret in ["known-secret", "abc", "def", "ghi", "jkl", "xyz", "u:p"] { XCTAssertFalse(clean.contains(secret)) }
        XCTAssertTrue(clean.contains("host/path"))
        XCTAssertEqual(ClientFeedbackError.clean("unchanged 原始诊断", secrets: [], maxBytes: 8192), "unchanged 原始诊断")
    }

    func testUTF8BoundsAndReportSchemaExcludeUsernameAndAbsentStack() throws {
        let message = String(repeating: "诊断", count: 10000)
        let error = ClientFeedbackError(NSError(domain: "Native", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        XCTAssertLessThanOrEqual(error.message.utf8.count, 8192)
        XCTAssertFalse(error.message.contains("�"))
        let report = ClientFeedbackReport(event: "update_failed", version: "4.99.0-beta.1", feature: "app_update", error: error)
        let encoded = try JSONEncoder().encode(report)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["schema", "source", "event", "version", "feature", "error"]))
        XCTAssertEqual(json["schema"] as? Int, 1)
        XCTAssertEqual(json["source"] as? String, "ios")
        XCTAssertNil((json["error"] as? [String: Any])?["stack"])
        XCTAssertLessThanOrEqual(encoded.count, 32768)
    }

    func testHTTPSOrExactLoopbackOnly() {
        for raw in ["https://wand.example", "http://localhost:3000", "http://127.0.0.1:3000", "http://[::1]:3000"] {
            XCTAssertTrue(ClientFeedbackReport.allows(URL(string: raw)!))
        }
        for raw in ["http://192.168.1.2:3000", "http://wand.example", "http://localhost.evil", "https://user:pass@wand.example", "ftp://localhost"] {
            XCTAssertFalse(ClientFeedbackReport.allows(URL(string: raw)!))
        }
    }

    func testFeedbackNeverRedirectsAndBusinessPolicyIsUnchanged() {
        for raw in ["https://wand.example/api/feedback/client", "http://127.0.0.1:3000/prefix/api/feedback/client?ignored=1"] {
            XCTAssertFalse(ClientFeedbackReport.permitsRedirect(originalURL: URL(string: raw)))
        }
        XCTAssertTrue(ClientFeedbackReport.permitsRedirect(originalURL: URL(string: "https://wand.example/api/sessions")))
        XCTAssertTrue(ClientFeedbackReport.permitsRedirect(originalURL: nil))
    }

    func testCancellationAndExplicitFeatureMapping() {
        XCTAssertTrue(ClientFeedbackError.isCancellation(CancellationError()))
        XCTAssertTrue(ClientFeedbackError.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(ClientFeedbackError.isCancellation(URLError(.timedOut)))
        XCTAssertEqual(ClientFeedbackReport.feature(path: "/api/ios-ipa-update"), "app_update")
        XCTAssertEqual(ClientFeedbackReport.feature(path: "/api/wand-tasks/private-id/comments"), "tasks")
        XCTAssertEqual(ClientFeedbackReport.feature(path: "/api/sessions/id/input"), "sessions")
        XCTAssertEqual(ClientFeedbackReport.feature(path: "/api/unknown/token-looking-path"), "api")
    }

    func testCanonicalAPIRouteFamiliesTable() {
        let families: [String: [String]] = [
            "sessions": ["sessions", "structured-sessions", "commands", "session-list", "session-directories"],
            "conversations": ["conversations"],
            "tasks": ["wand-tasks", "wand-task-agent-defaults", "tasks", "workspace-tasks", "workspaces", "wand-milestones", "missions", "scheduled-tasks"],
            "files": ["files", "upload", "directory", "session-files", "file-preview", "file-read", "file-write", "recent-paths"],
            "settings": ["settings", "config", "user-profile", "auto-update", "update-channel"],
            "models": ["models", "model-groups", "local-models"],
            "authentication": ["login", "logout", "app-login", "session-check", "set-password"],
            "server_update": ["update", "update-status", "check-update"],
            "app_update": ["android-apk-update", "android-apk", "macos-app-update", "macos-dmg-update", "macos-dmg", "ios-ipa-update", "ios-ipa"],
            "provider_update": ["provider-cli-updates"],
            "daemon_update": ["daemon-maintenance"],
            "storage": ["storage-cleanup"],
            "repository": ["git", "github"],
        ]
        XCTAssertEqual(ClientFeedbackReport.apiFeatures.count, families.values.reduce(0) { $0 + $1.count })
        for (feature, routes) in families {
            for route in routes {
                for path in ["/api/\(route)", "/api/\(route)/private-id", "/api/\(route)?private=not-sent"] {
                    XCTAssertEqual(ClientFeedbackReport.feature(path: path), feature, path)
                }
            }
        }
        for path in ["", "/api", "/api/", "/api/unknown", "/api/update-looking-error-text", "/api/unknown?path=/api/update", "/api/toString"] {
            XCTAssertEqual(ClientFeedbackReport.feature(path: path), "api", path)
        }
    }

    func testBoundedConcurrencyRateAndDeduplication() {
        let limiter = ClientFeedbackLimiter(), start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(limiter.begin(key: "a", now: start))
        XCTAssertFalse(limiter.begin(key: "a", now: start))
        XCTAssertTrue(limiter.begin(key: "b", now: start))
        XCTAssertFalse(limiter.begin(key: "c", now: start))
        limiter.finish(); limiter.finish()
        for index in 0..<8 { XCTAssertTrue(limiter.begin(key: "key\(index)", now: start)); limiter.finish() }
        XCTAssertFalse(limiter.begin(key: "rate", now: start))
        XCTAssertTrue(limiter.begin(key: "rate", now: start.addingTimeInterval(61))); limiter.finish()
        XCTAssertFalse(limiter.begin(key: "a", now: start.addingTimeInterval(61)))
        XCTAssertTrue(limiter.begin(key: "a", now: start.addingTimeInterval(301))); limiter.finish()
    }
}
