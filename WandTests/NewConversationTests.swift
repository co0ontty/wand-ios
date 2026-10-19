import Foundation
import XCTest
@testable import Wand

final class NewConversationTests: XCTestCase {
    @MainActor
    func testUnknownCreateCannotBeRetried() async {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        var attempts = 0

        let first = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            throw WandAPI.APIError.network("timeout")
        }
        let second = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            throw WandAPI.APIError.network("retry")
        }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(coordinator.canSubmit)
        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("Expected unknown delivery") }
    }

    @MainActor
    func testUnknownCreateRemainsLockedAcrossCoordinatorRecreationAndManualCheck() async {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let key = "wand.new-conversation.unknown.test"
        let coordinator = NewConversationCoordinator(storageKey: key, defaults: defaults)
        var attempts = 0

        _ = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            throw WandAPI.APIError.network("timeout")
        }
        let reopened = NewConversationCoordinator(storageKey: key, defaults: defaults)
        XCTAssertFalse(reopened.canSubmit)
        reopened.acknowledgeDeliveryUnknown(confirmedChecked: false)
        reopened.acknowledgeDeliveryUnknown(confirmedChecked: true)
        let retry = await reopened.create {
            attempts += 1
            return try self.decodeSnapshot(id: "confirmed-retry-\(UUID().uuidString)")
        }

        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 1)
        if case .deliveryUnknown = reopened.phase { } else { XCTFail("Unknown delivery must stay locked") }
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testAcceptedCreateCanAdoptOnlyIntoEmptyDraftForAcceptedSession() async throws {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = try decodeSnapshot(id: "new-conversation-\(UUID().uuidString)")
        let accepted = await coordinator.create { snapshot }
        XCTAssertEqual(accepted?.id, snapshot.id)

        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:8477")!, token: nil)
        let draft = SessionDraftStore.shared.draft(sessionId: snapshot.id, api: api)
        XCTAssertEqual(coordinator.adopt("first message", targetSessionID: snapshot.id, into: draft), .adopted)
        XCTAssertEqual(draft.text, "first message")
        XCTAssertEqual(coordinator.adopt("other", targetSessionID: "another-session", into: draft), .targetAlreadyHasContent)

        draft.requestInitialSend()
        XCTAssertTrue(draft.claimInitialSend())
        XCTAssertFalse(draft.claimInitialSend())
        draft.finishInitialSend()
        XCTAssertFalse(draft.claimInitialSend())
        SessionDraftStore.shared.remove(sessionId: snapshot.id, api: api)
    }

    @MainActor
    func testAdoptionPreservesExistingTargetDraft() async throws {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = try decodeSnapshot(id: "existing-target-\(UUID().uuidString)")
        _ = await coordinator.create { snapshot }
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:8478")!, token: nil)
        let draft = SessionDraftStore.shared.draft(sessionId: snapshot.id, api: api)
        draft.text = "existing"

        XCTAssertEqual(coordinator.adopt("new", targetSessionID: snapshot.id, into: draft), .targetAlreadyHasContent)
        XCTAssertEqual(draft.text, "existing")
        SessionDraftStore.shared.remove(sessionId: snapshot.id, api: api)
    }

    @MainActor
    func testUnknownSessionWithTaskIDCannotBeRetried() async {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        coordinator.markTaskAccepted("accepted-task")
        var attempts = 0

        let first = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            throw UnknownSessionDeliveryError(sessionID: "uncertain-session", cause: WandAPI.APIError.network("timeout"))
        }
        let retry = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            return try self.decodeSnapshot(id: "duplicate")
        }

        XCTAssertNil(first)
        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(coordinator.unknownSessionID, "uncertain-session")
        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("Expected unknown delivery") }
    }

    @MainActor
    func testUnknownSessionWithTaskIDCannotBeAcknowledgedIntoRetry() async {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        coordinator.markTaskAccepted("accepted-task")
        _ = await coordinator.create { () async throws -> SessionSnapshot in
            throw UnknownSessionDeliveryError(sessionID: "uncertain-session", cause: WandAPI.APIError.network("timeout"))
        }

        coordinator.acknowledgeDeliveryUnknown(confirmedChecked: true)
        var attempts = 0
        let retry = await coordinator.create {
            attempts += 1
            return try self.decodeSnapshot(id: "duplicate")
        }

        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(coordinator.unknownOperation, .session)
        XCTAssertEqual(coordinator.unknownSessionID, "uncertain-session")
        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("Unknown session delivery must stay locked") }
    }

    @MainActor
    func testAbandonAcceptedSessionKeepsSessionAccepted() async throws {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        coordinator.markTaskAccepted("accepted-task")
        let accepted = try decodeSnapshot(id: "accepted-once")
        _ = await coordinator.create { accepted }

        coordinator.abandonAcceptedSession(sessionID: accepted.id)

        XCTAssertEqual(coordinator.phase, .accepted(sessionID: accepted.id, taskID: "accepted-task"))
        let reopened = NewConversationCoordinator(storageKey: "wand.new-conversation.unknown.test", defaults: defaults)
        XCTAssertEqual(reopened.phase, .accepted(sessionID: accepted.id, taskID: "accepted-task"))
        var attempts = 0
        let duplicate = await reopened.create {
            attempts += 1
            return try self.decodeSnapshot(id: "duplicate")
        }

        XCTAssertNil(duplicate)
        XCTAssertEqual(attempts, 0)
    }

    @MainActor
    func testTaskCreationPersistsUnknownBeforeOperationAndBlocksAfterRecreation() async {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "wand.new-conversation.in-flight.task"
        let coordinator = NewConversationCoordinator(storageKey: key, defaults: defaults)
        let started = expectation(description: "task operation started")
        var attempts = 0
        var resumeOperation: CheckedContinuation<String, Error>?

        let creation = Task { @MainActor in
            await coordinator.createTask(requestID: "task-request") {
                attempts += 1
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation in
                    resumeOperation = continuation
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)

        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("In-flight task must be represented as unknown") }
        let saved = defaults.dictionary(forKey: key)
        XCTAssertEqual(saved?["phase"] as? String, "deliveryUnknown")
        XCTAssertEqual(saved?["operation"] as? String, "task")
        XCTAssertEqual(saved?["requestID"] as? String, "task-request")
        let reopened = NewConversationCoordinator(storageKey: key, defaults: defaults)
        let retry = await reopened.createTask {
            attempts += 1
            return "duplicate-task"
        }
        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 1)

        resumeOperation?.resume(throwing: WandAPI.APIError.network("closed"))
        _ = await creation.value
    }

    @MainActor
    func testSessionCreationPersistsUnknownBeforeOperationAndBlocksAfterRecreation() async throws {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "wand.new-conversation.in-flight.session"
        let coordinator = NewConversationCoordinator(storageKey: key, defaults: defaults)
        let started = expectation(description: "session operation started")
        var attempts = 0
        var resumeOperation: CheckedContinuation<SessionSnapshot, Error>?

        let creation = Task { @MainActor in
            await coordinator.create(requestID: "session-request") {
                attempts += 1
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation in
                    resumeOperation = continuation
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)

        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("In-flight session must be represented as unknown") }
        let saved = defaults.dictionary(forKey: key)
        XCTAssertEqual(saved?["phase"] as? String, "deliveryUnknown")
        XCTAssertEqual(saved?["operation"] as? String, "session")
        XCTAssertEqual(saved?["requestID"] as? String, "session-request")
        let reopened = NewConversationCoordinator(storageKey: key, defaults: defaults)
        let retry = await reopened.create {
            attempts += 1
            return try self.decodeSnapshot(id: "duplicate")
        }
        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 1)

        resumeOperation?.resume(returning: try decodeSnapshot(id: "accepted-after-resume"))
        _ = await creation.value
    }

    @MainActor
    private func makeCoordinator() -> (NewConversationCoordinator, UserDefaults, String) {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        return (NewConversationCoordinator(storageKey: "wand.new-conversation.unknown.test", defaults: UserDefaults(suiteName: suite)!), UserDefaults(suiteName: suite)!, suite)
    }

    private func decodeSnapshot(id: String) throws -> SessionSnapshot {
        let data = Data(#"{"id":"\#(id)","sessionKind":"structured","provider":"claude","selectedModel":null,"thinkingEffort":null,"claudeSessionId":null}"#.utf8)
        return try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
