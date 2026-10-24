import XCTest
@testable import Wand

final class APNsTests: XCTestCase {
    func testEnvironmentFollowsSigningProfileNotBuildFlavor() {
        XCTAssertEqual(RemoteNotificationPolicy.environment("development"), "sandbox")
        XCTAssertEqual(RemoteNotificationPolicy.environment("production"), "production")
        XCTAssertNil(RemoteNotificationPolicy.environment(nil))
        XCTAssertNil(RemoteNotificationPolicy.environment(""), "unsigned/local builds must not claim APNs capability")
        XCTAssertNil(RemoteNotificationPolicy.environment("$(WAND_APNS_ENVIRONMENT)"))
    }

    func testRemoteNavigationOnlyUsesSavedServerAndBoundedSessionID() {
        let info: [AnyHashable: Any] = ["sessionId": "session-A", "serverId": "known", "eventId": String(repeating: "a", count: 64)]
        let target = RemoteNotificationPolicy.target(info, knownServerIDs: ["known"])
        XCTAssertEqual(target?.sessionID, "session-A")
        XCTAssertEqual(target?.serverID, "known")
        XCTAssertNil(RemoteNotificationPolicy.target(info, knownServerIDs: []))
        for invalid in ["", "line\nbreak", String(repeating: "x", count: 257)] {
            var changed = info; changed["sessionId"] = invalid
            XCTAssertNil(RemoteNotificationPolicy.target(changed, knownServerIDs: ["known"]))
        }
        var changed = info; changed["eventId"] = "not-an-event"
        XCTAssertNil(RemoteNotificationPolicy.target(changed, knownServerIDs: ["known"]))
        changed = info; changed["serverId"] = "https://unknown.example"
        XCTAssertNil(RemoteNotificationPolicy.target(changed, knownServerIDs: ["known"]))
    }

    func testUnknownRegistrationResponseDoesNotTurnOnDuplicateLocalNotifications() {
        for status in [408, 409, 429, 500, 502, 503] {
            XCTAssertFalse(RemoteNotificationPolicy.registrationRejected(status: status, code: nil))
        }
        for status in [400, 401, 403, 404, 405] {
            XCTAssertTrue(RemoteNotificationPolicy.registrationRejected(status: status, code: nil))
        }
        XCTAssertTrue(RemoteNotificationPolicy.registrationRejected(status: 503, code: "apns_unavailable"))
    }

    func testBindingIsolationAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let binding = RemoteNotificationBinding(serverID: "A", endpoint: URL(string: "https://localhost:8181")!,
            connectionIdentity: "A:credential-one", secret: String(repeating: "a", count: 64),
            leaseUntil: now.addingTimeInterval(60), confirmed: false)
        XCTAssertTrue(binding.suppressesLocal(serverID: "A", identity: "A:credential-one", now: now), "unknown accepted registration is still potentially remote")
        XCTAssertFalse(binding.suppressesLocal(serverID: "B", identity: "A:credential-one", now: now))
        XCTAssertFalse(binding.suppressesLocal(serverID: "A", identity: "A:credential-two", now: now))
        XCTAssertFalse(binding.suppressesLocal(serverID: "A", identity: "A:credential-one", now: now.addingTimeInterval(61)))
        let data = try JSONEncoder().encode(binding)
        XCTAssertEqual(try JSONDecoder().decode(RemoteNotificationBinding.self, from: data), binding)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("appToken"), "revocation persistence does not retain old login credentials")
    }
}
