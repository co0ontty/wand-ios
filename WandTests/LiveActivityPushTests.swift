import XCTest
@testable import Wand

final class LiveActivityPushTests: XCTestCase {
    func testServerContentDecodesUsingProductionSwiftDefaultDateStrategy() throws {
        let data: Data
        if let path = ProcessInfo.processInfo.environment["WAND_ACTIVITY_FIXTURE"] {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = Data(#"{"aps":{"timestamp":1800000000,"event":"update","content-state":{"sessions":[{"id":"wire-session","serverID":"server_a","title":"当前任务","providerRaw":"pi","stateRaw":"responding","queuedCount":0,"startedAt":821692770,"engineRaw":"core"},{"id":"wire-done","serverID":"server_a","title":"已完成","providerRaw":"pi","stateRaw":"done","queuedCount":0,"finishedAt":821692800}],"updatedAt":821692800}}}"#.utf8)
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try XCTUnwrap(root["aps"] as? [String: Any])
        let stateData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(aps["content-state"]))
        let decoded = try JSONDecoder().decode(SessionActivityAttributes.ContentState.self, from: stateData)
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, 1_800_000_000, accuracy: 0.001)
        let running = try XCTUnwrap(decoded.sessions.first)
        XCTAssertEqual(running.id, "wire-session")
        XCTAssertEqual(running.serverID, "server_a")
        XCTAssertEqual(try XCTUnwrap(running.startedAt).timeIntervalSince1970, 1_799_999_970, accuracy: 0.001)
        XCTAssertEqual(running.stateRaw, "responding")
        let finished = try XCTUnwrap(decoded.sessions.first { $0.id == "wire-done" })
        XCTAssertEqual(try XCTUnwrap(finished.finishedAt).timeIntervalSince1970, 1_800_000_000, accuracy: 0.001)
        XCTAssertLessThanOrEqual(data.count, 4096)
    }

    func testLegacyAttributesRemainDecodableAndNewMarkerIsImmutableOwnerMetadata() throws {
        let legacy = try JSONDecoder().decode(SessionActivityAttributes.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.serverID)
        XCTAssertNil(legacy.remoteUpdates)
        XCTAssertNil(legacy.connectionIdentity)
        let current = SessionActivityAttributes(serverID: "server_a", remoteUpdates: true, connectionIdentity: "server_a:fingerprint")
        let restored = try JSONDecoder().decode(SessionActivityAttributes.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored.serverID, "server_a")
        XCTAssertEqual(restored.remoteUpdates, true)
        XCTAssertEqual(restored.connectionIdentity, "server_a:fingerprint")
    }

    func testActivityOwnershipCannotFollowLateTokenAcrossServerCredentialOrToggleChanges() {
        XCTAssertTrue(LiveActivityPushPolicy.owns(activityServerID: "A", activityIdentity: "A:one", currentServerID: "A", origin: "A:one", currentIdentity: "A:one", enabled: true))
        XCTAssertFalse(LiveActivityPushPolicy.owns(activityServerID: "A", activityIdentity: "A:one", currentServerID: "B", origin: "A:one", currentIdentity: "B:two", enabled: true))
        XCTAssertFalse(LiveActivityPushPolicy.owns(activityServerID: "A", activityIdentity: "A:one", currentServerID: "A", origin: "A:one", currentIdentity: "A:two", enabled: true))
        XCTAssertFalse(LiveActivityPushPolicy.owns(activityServerID: "A", activityIdentity: "A:one", currentServerID: nil, origin: "A:one", currentIdentity: nil, enabled: true))
        XCTAssertFalse(LiveActivityPushPolicy.owns(activityServerID: "A", activityIdentity: "A:one", currentServerID: "A", origin: "A:one", currentIdentity: "A:one", enabled: false))
        // No Keychain binding exists yet: after a process restart a freshly-created Observation must not adopt an old Activity.
        XCTAssertFalse(LiveActivityPushPolicy.owns(activityServerID: "A", activityIdentity: "A:one", currentServerID: "A", origin: "A:two", currentIdentity: "A:two", enabled: true))
        XCTAssertFalse(LiveActivityPushPolicy.owns(activityServerID: "A", activityIdentity: nil, currentServerID: "A", origin: "A:two", currentIdentity: "A:two", enabled: true))
    }

    func testRestoredCompletionGraceCannotBeRenewedForeverOrExtendedByClockSkew() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(LiveActivityPushPolicy.remainingLinger(since: t, now: t.addingTimeInterval(5), duration: 12), 7)
        XCTAssertEqual(LiveActivityPushPolicy.remainingLinger(since: t, now: t.addingTimeInterval(90), duration: 12), 0)
        XCTAssertEqual(LiveActivityPushPolicy.remainingLinger(since: t, now: t.addingTimeInterval(-60), duration: 30), 30)
        let completed = SessionActivityAttributes.SessionEntry(id: "A", serverID: "server_a", title: "A", providerRaw: "pi", stateRaw: "done", queuedCount: 0, finishedAt: t)
        let aggregate = SessionActivityAttributes.ContentState(sessions: [completed], updatedAt: t.addingTimeInterval(8))
        XCTAssertEqual(LiveActivityPushPolicy.remainingLinger(since: aggregate.sessions[0].finishedAt, now: t.addingTimeInterval(13), duration: 12), 0, "other aggregate updates never renew A")
        XCTAssertEqual(LiveActivityPushPolicy.remainingLinger(since: nil, now: t, duration: 12), 0, "legacy entries without a completion anchor are cleared, not guessed")
    }

    func testRevocationPersistenceHasNoActivityTokenOrLoginCredential() throws {
        let binding = LiveActivityPushBinding(activityID: "activity-one", serverID: "server_a", endpoint: URL(string: "https://localhost:8181")!,
            connectionIdentity: "server_a:fingerprint", secret: String(repeating: "a", count: 64),
            leaseUntil: Date(timeIntervalSince1970: 1_800_000_000), confirmed: false)
        let data = try JSONEncoder().encode(binding)
        XCTAssertEqual(try JSONDecoder().decode(LiveActivityPushBinding.self, from: data), binding)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("activityToken"))
        XCTAssertFalse(text.contains("appToken"))
        XCTAssertEqual(LiveActivityPushPolicy.path, "/api/push/apns/live-activity")
    }
}
