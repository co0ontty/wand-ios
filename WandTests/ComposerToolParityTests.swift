import Combine
import Foundation
import XCTest
@testable import Wand

@MainActor
private final class ComposerTransportStub: SessionInputTransport {
    var inputs: [String] = []
    let receipt: SessionSnapshot
    var failure: Error?
    init(receipt: SessionSnapshot, failure: Error? = nil) {
        self.receipt = receipt
        self.failure = failure
    }
    func sendStructuredInput(id: String, input: String) async throws -> SessionSnapshot {
        inputs.append(input)
        await Task.yield()
        if let failure { throw failure }
        return receipt
    }
    func sendPtyInputChunk(id: String, input: String, view: String, shortcutKey: String?) async throws {}
}

@MainActor
private final class QueueRetrievalStub: QueueRetrievalTransport {
    var calls: [(String, Int, String)] = []
    var resume: CheckedContinuation<SessionSnapshot, Error>?
    func deleteQueued(id: String, index: Int, expectedText: String) async throws -> SessionSnapshot {
        calls.append((id, index, expectedText))
        return try await withCheckedThrowingContinuation { resume = $0 }
    }
}

final class ComposerToolParityTests: XCTestCase {
    @MainActor
    func testStagedUploadPreservesInputRevisionAndDoesNotRepeatAcceptedBatch() async throws {
        let controller = ComposerAttachmentController(sessionId: UUID().uuidString, api: api)
        controller.stageFileSelection(.success([URL(fileURLWithPath: "/tmp/first")]), cleanupAfterUpload: false)
        let revision = controller.stagedInputRevision
        var calls = 0
        try await controller.uploadStaged(to: "accepted") { _, urls, started in
            calls += 1
            started()
            XCTAssertEqual(urls.count, 1)
            return [self.file("/work/uploaded")]
        }
        XCTAssertEqual(controller.stagedInputRevision, revision)
        XCTAssertEqual(controller.stagedAttachmentCount, 0)
        XCTAssertEqual(controller.attachments.map(\.savedPath), ["/work/uploaded"])
        try await controller.uploadStaged(to: "accepted") { _, _, _ in
            calls += 1
            return []
        }
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testStagedUploadAcceptsNewBatchForSameSession() async throws {
        let controller = ComposerAttachmentController(sessionId: UUID().uuidString, api: api)
        var calls = 0
        for name in ["first", "second"] {
            controller.stageFileSelection(.success([URL(fileURLWithPath: "/tmp/" + name)]), cleanupAfterUpload: false)
            try await controller.uploadStaged(to: "accepted") { _, _, started in
                calls += 1
                started()
                return [self.file("/work/" + name)]
            }
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.attachments.map(\.savedPath), ["/work/first", "/work/second"])
    }

    @MainActor
    func testLateStagedUploadCannotRestoreRemovedAttachment() async throws {
        let pendingID = UUID().uuidString
        let controller = ComposerAttachmentController(sessionId: pendingID, api: api)
        controller.stageFileSelection(.success([URL(fileURLWithPath: "/tmp/first")]), cleanupAfterUpload: false)
        do {
            try await controller.uploadStaged(to: "late") { _, _, started in
                started()
                controller.removeStaged(at: 0)
                return [self.file("/work/removed")]
            }
            XCTFail("Removed selection must not be adopted")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(controller.attachments.isEmpty)
        XCTAssertEqual(controller.stagedAttachmentCount, 0)
        let key = "wand.pending-upload.v1." + ServerProfiles.stableID(for: api.baseURL) + "." + pendingID
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        let reopened = ComposerAttachmentController(sessionId: pendingID, api: api)
        reopened.stageFileSelection(.success([URL(fileURLWithPath: "/tmp/next")]), cleanupAfterUpload: false)
        try await reopened.uploadStaged(to: "late") { _, urls, started in
            started()
            XCTAssertEqual(urls.map(\.lastPathComponent), ["next"])
            return [self.file("/work/next")]
        }
        XCTAssertEqual(reopened.attachments.map(\.savedPath), ["/work/next"])
    }

    @MainActor
    func testSuccessfulStaleUploadDrainsOnlyAcceptedSelectionsAndKeepsNewBatch() async throws {
        let controller = ComposerAttachmentController(sessionId: UUID().uuidString, api: api)
        controller.stageFileSelection(.success([URL(fileURLWithPath: "/tmp/accepted")]), cleanupAfterUpload: false)
        do {
            try await controller.uploadStaged(to: "same-session") { _, _, started in
                started()
                controller.stageFileSelection(.success([URL(fileURLWithPath: "/tmp/new")]), cleanupAfterUpload: false)
                return [self.file("/work/accepted")]
            }
            XCTFail("Changed input must not adopt the stale result")
        } catch is CancellationError {}
        XCTAssertEqual(controller.attachments.map(\.savedPath), ["/work/accepted"])
        XCTAssertEqual(controller.stagedAttachmentCount, 1)
        XCTAssertEqual(controller.stagedAttachments.map(\.name), ["new"])
        let revision = controller.stagedInputRevision
        try await controller.uploadStaged(to: "same-session") { _, urls, started in
            started()
            XCTAssertEqual(urls.map(\.lastPathComponent), ["new"])
            return [self.file("/work/new")]
        }
        XCTAssertEqual(controller.stagedInputRevision, revision)
        XCTAssertEqual(controller.attachments.map(\.savedPath), ["/work/accepted", "/work/new"])
    }

    @MainActor
    func testSuccessfulUploadAfterDeactivationSettlesBatchWithoutAdoptionOrRetry() async throws {
        let pendingID = UUID().uuidString
        let controller = ComposerAttachmentController(sessionId: pendingID, api: api)
        controller.stageFileSelection(.success([URL(fileURLWithPath: "/tmp/accepted")]), cleanupAfterUpload: false)
        do {
            try await controller.uploadStaged(to: "inactive-session") { _, _, started in
                started()
                controller.deactivate()
                return [self.file("/work/accepted")]
            }
            XCTFail("Inactive owner must not adopt a late result")
        } catch is CancellationError {}
        XCTAssertTrue(controller.attachments.isEmpty)
        XCTAssertEqual(controller.stagedAttachmentCount, 0)
        let key = "wand.pending-upload.v1." + ServerProfiles.stableID(for: api.baseURL) + "." + pendingID
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        controller.activate()
        var retried = false
        try await controller.uploadStaged(to: "inactive-session") { _, _, _ in
            retried = true
            return []
        }
        XCTAssertFalse(retried)
    }

    @MainActor
    func testStagedUploadDefiniteRejectionAndLocalFailureCanRetry() async throws {
        let controller = ComposerAttachmentController(sessionId: UUID().uuidString, api: api)
        controller.stageFileSelection(.success([URL(fileURLWithPath: "/tmp/first")]), cleanupAfterUpload: false)
        for requestStarted in [false, true] {
            do {
                try await controller.uploadStaged(to: "rejected") { _, _, started in
                    if requestStarted { started() }
                    throw WandAPI.APIError.server(status: 400, message: "rejected")
                }
                XCTFail("Expected rejection")
            } catch {}
        }
        try await controller.uploadStaged(to: "rejected") { _, _, started in
            started()
            return [self.file("/work/retry")]
        }
        XCTAssertEqual(controller.stagedAttachmentCount, 0)
    }

    @MainActor
    func testStagedUploadUnknownBlocksRetryAcrossControllerRecreation() async throws {
        let pendingID = UUID().uuidString
        let sessionID = UUID().uuidString
        let url = URL(fileURLWithPath: "/tmp/first")
        let controller = ComposerAttachmentController(sessionId: pendingID, api: api)
        controller.stageFileSelection(.success([url]), cleanupAfterUpload: false)
        do {
            try await controller.uploadStaged(to: sessionID) { _, _, started in
                started()
                throw WandAPI.APIError.network("receipt lost")
            }
            XCTFail("Expected unknown delivery")
        } catch {}
        let restored = ComposerAttachmentController(sessionId: pendingID, api: api)
        restored.stageFileSelection(.success([url]), cleanupAfterUpload: false)
        var retried = false
        do {
            try await restored.uploadStaged(to: sessionID) { _, _, _ in
                retried = true
                return []
            }
            XCTFail("Unknown upload must remain locked")
        } catch {}
        XCTAssertFalse(retried)
        XCTAssertEqual(restored.stagedAttachmentCount, 1)
        let key = "wand.pending-upload.v1." + ServerProfiles.stableID(for: api.baseURL) + "." + pendingID
        UserDefaults.standard.removeObject(forKey: key)
    }

    @MainActor
    func testQueueRetrievalWaitsForDeleteAndRequiresAdoptionIntoLatestDraft() async throws {
        let transport = QueueRetrievalStub()
        let store = ChatStore(sessionId: "queue", api: api, drafts: SessionDraftStore(), queueRetrievalTransport: transport)
        store.queuedMessages = ["queued original"]
        store.composerDraft.text = "existing"
        store.composerDraft.attachments.attachments = [file("/work/keep")]
        let request = Task { await store.retrieveQueued(index: 0) }
        while transport.resume == nil { await Task.yield() }
        XCTAssertEqual(store.queuedMessages, ["queued original"])
        XCTAssertEqual(store.composerDraft.text, "existing")
        XCTAssertEqual(transport.calls.first?.0, "queue")
        XCTAssertEqual(transport.calls.first?.1, 0)
        XCTAssertEqual(transport.calls.first?.2, "queued original")
        store.composerDraft.text = "new typing"
        store.composerDraft.attachments.attachments.append(file("/work/new"))
        let snapshot = try decode(SessionSnapshot.self, #"{"id":"queue","sessionKind":"structured","status":"idle","queuedMessages":[]}"#)
        transport.resume?.resume(returning: snapshot)
        let confirmed = await request.value
        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.composerDraft.text, "new typing")
        XCTAssertEqual(store.composerDraft.queueRecoveryPhase, .ready)
        XCTAssertEqual(store.composerDraft.queueRecoveryText, "queued original")
        XCTAssertTrue(store.composerDraft.restoreQueuedOriginal())
        XCTAssertEqual(store.composerDraft.text, "new typing\n\nqueued original")
        XCTAssertFalse(store.composerDraft.restoreQueuedOriginal())
        XCTAssertEqual(store.composerDraft.attachments.attachments.map(\.savedPath), ["/work/keep", "/work/new"])
        XCTAssertTrue(store.queuedMessages.isEmpty)
        XCTAssertNil(store.composerDraft.queueRecoveryText)
    }

    @MainActor
    func testQueueReceiptAppliesDuringUnrelatedOutputButNeverOverwritesQueuePush() async throws {
        for queuePayload in ["", ",\"queuedMessages\":[\"newer queued message\"]", ",\"queuedMessages\":[]"] {
            let transport = QueueRetrievalStub()
            let store = ChatStore(sessionId: "queue", api: api, drafts: SessionDraftStore(), queueRetrievalTransport: transport)
            store.queuedMessages = ["original", "remaining"]
            let request = Task { await store.retrieveQueued(index: 0) }
            while transport.resume == nil { await Task.yield() }
            store.handle(try decode(WsIncoming.self,
                "{\"type\":\"output\",\"sessionId\":\"queue\",\"data\":{\"title\":\"Still responding\"" + queuePayload + "}}"))
            transport.resume?.resume(returning: try decode(SessionSnapshot.self,
                #"{"id":"queue","sessionKind":"structured","status":"running","queuedMessages":["remaining"]}"#))
            let confirmed = await request.value
            XCTAssertTrue(confirmed)
            let expected = queuePayload.isEmpty ? ["remaining"] : queuePayload.contains("newer") ? ["newer queued message"] : []
            XCTAssertEqual(store.queuedMessages, expected)
            XCTAssertFalse(store.queueMutationPending)
        }
    }

    @MainActor
    func testUnknownQueueDeleteKeepsSourceAndNeverRetriesOrRefills() async {
        let transport = QueueRetrievalStub()
        let store = ChatStore(sessionId: "unknown-queue", api: api, drafts: SessionDraftStore(), queueRetrievalTransport: transport)
        store.queuedMessages = ["possibly removed"]
        store.composerDraft.text = "keep current"
        let request = Task { await store.retrieveQueued(index: 0) }
        while transport.resume == nil { await Task.yield() }
        transport.resume?.resume(throwing: WandAPI.APIError.network("lost receipt"))
        let confirmed = await request.value
        XCTAssertFalse(confirmed)
        XCTAssertEqual(store.composerDraft.text, "keep current")
        XCTAssertEqual(store.composerDraft.queueRecoveryText, "possibly removed")
        let retried = await store.retrieveQueued(index: 0)
        XCTAssertFalse(retried)
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertFalse(store.composerDraft.queueRetrievalPending)
        XCTAssertEqual(store.composerDraft.queueRecoveryPhase, .unconfirmed)
        XCTAssertFalse(store.composerDraft.restoreQueuedOriginal())
        XCTAssertTrue(store.composerDraft.restoreQueuedOriginal(confirmedNotExecuted: true))
        XCTAssertEqual(store.composerDraft.text, "keep current\n\npossibly removed")
        XCTAssertNil(store.composerDraft.queueRecoveryText)
    }

    @MainActor
    func testQueueRecoveryBelongsToServerAndSessionAndCannotReviveRetiredDraft() {
        let drafts = SessionDraftStore()
        let original = drafts.draft(sessionId: "recovery", api: api)
        original.text = "local"
        XCTAssertTrue(original.beginQueueRetrieval("queued"))
        XCTAssertFalse(original.beginQueueRetrieval("another"))
        XCTAssertNil(drafts.draft(sessionId: "other", api: api).queueRecoveryText)
        let otherServer = WandAPI(baseURL: URL(string: "http://127.0.0.1:2")!, token: nil)
        XCTAssertNil(drafts.draft(sessionId: "recovery", api: otherServer).queueRecoveryText)
        original.retire()
        original.finishQueueRetrieval(confirmed: true)
        XCTAssertEqual(original.text, "")
        XCTAssertNil(original.queueRecoveryText)
    }

    @MainActor
    func testLateQueueRetrievalAcrossViewLifecycleRequiresExplicitAdoption() {
        let buffer = ComposerDraftState(sessionId: "lifecycle", api: api, defaults: defaults())
        XCTAssertTrue(buffer.beginQueueRetrieval("source"))
        buffer.deactivate()
        buffer.activate()
        buffer.text = "reopened typing"
        buffer.finishQueueRetrieval(confirmed: true)
        XCTAssertEqual(buffer.text, "reopened typing")
        XCTAssertEqual(buffer.queueRecoveryPhase, .ready)
        XCTAssertTrue(buffer.restoreQueuedOriginal())
        XCTAssertEqual(buffer.text, "reopened typing\n\nsource")
    }
    @MainActor
    func testQueueRetrievalOnlyAutoFillsUnchangedActiveEmptyDraft() {
        let buffer = ComposerDraftState(sessionId: UUID().uuidString, api: api, defaults: defaults())
        XCTAssertTrue(buffer.beginQueueRetrieval("first"))
        buffer.finishQueueRetrieval(confirmed: true)
        XCTAssertEqual(buffer.text, "first"); XCTAssertNil(buffer.queueRecoveryPhase)
        buffer.text = ""
        XCTAssertTrue(buffer.beginQueueRetrieval("second"))
        buffer.text = "typed"; buffer.text = ""
        buffer.finishQueueRetrieval(confirmed: true)
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.queueRecoveryPhase, .ready)
        XCTAssertTrue(buffer.restoreQueuedOriginal())
        XCTAssertEqual(buffer.text, "second")
    }

    @MainActor
    func testRejectedRetrievalCannotBeAdoptedAndSendingGuardsReadyRecovery() {
        let buffer = ComposerDraftState(sessionId: UUID().uuidString, api: api, defaults: defaults())
        XCTAssertTrue(buffer.beginQueueRetrieval("not removed"))
        buffer.finishQueueRetrieval(confirmed: false, rejected: true)
        XCTAssertEqual(buffer.queueRecoveryPhase, .rejected)
        XCTAssertFalse(buffer.restoreQueuedOriginal(confirmedNotExecuted: true))
        buffer.dismissQueueRecovery()
        buffer.text = "existing"
        XCTAssertTrue(buffer.beginQueueRetrieval("removed"))
        buffer.finishQueueRetrieval(confirmed: true)
        buffer.beginSending()
        XCTAssertFalse(buffer.restoreQueuedOriginal())
        XCTAssertEqual(buffer.text, "existing")
        buffer.deactivate()
        XCTAssertFalse(buffer.restoreQueuedOriginal())
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    private func justCompleted(_ session: SessionSnapshot?) -> Bool {
        guard let session else { return false }
        return SessionCompletion.isJustCompleted(completion: session.completionRevision,
            viewed: session.viewedCompletionRevision, status: session.status, archived: session.archived,
            ptyBusy: session.ptyBusy, inFlight: session.structuredState?.inFlight,
            permissionBlocked: session.permissionBlocked, pendingEscalation: session.pendingEscalation != nil,
            providerCliExitCode: session.providerCliExitCode)
    }
    private var api: WandAPI { WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil) }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "wand.composer-tests." + UUID().uuidString)! }
    private func file(_ path: String) -> UploadedFile {
        UploadedFile(originalName: "file.txt", savedPath: path, size: 10, mimeType: "text/plain")
    }
    @MainActor
    func testUnsentDraftRestoresPerServerAndSession() {
        let preferences = defaults()
        let first = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        first.text = "unsent"
        first.attachments.attachments = [file("/work/attachment")]
        let restored = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        XCTAssertEqual(restored.text, "unsent")
        XCTAssertEqual(restored.attachments.attachments.map(\.savedPath), ["/work/attachment"])
        XCTAssertEqual(ComposerDraftState(sessionId: "two", api: api, defaults: preferences).text, "")
        let other = WandAPI(baseURL: URL(string: "http://127.0.0.1:2")!, token: nil)
        XCTAssertEqual(ComposerDraftState(sessionId: "one", api: other, defaults: preferences).text, "")
    }

    @MainActor
    func testPendingAndUnknownDraftCannotRestoreButNewInputCan() {
        let preferences = defaults()
        let buffer = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        buffer.text = "possibly delivered"
        buffer.attachments.attachments = [file("/work/submitted")]
        let sent = buffer.submission()
        buffer.submitted(sent)
        let pending = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        XCTAssertEqual(pending.text, "")
        XCTAssertTrue(pending.attachments.attachments.isEmpty)
        XCTAssertEqual(buffer.text, "possibly delivered", "Unknown input remains available only in memory")
        buffer.text = "new input"
        buffer.attachments.attachments.append(file("/work/new"))
        let newer = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        XCTAssertEqual(newer.text, "new input")
        XCTAssertEqual(newer.attachments.attachments.map(\.savedPath), ["/work/new"])
        buffer.accepted(sent)
        XCTAssertEqual(buffer.text, "new input")
        XCTAssertEqual(buffer.attachments.attachments.map(\.savedPath), ["/work/new"])
    }

    @MainActor
    func testDefiniteRejectionRestoresSafePersistence() {
        let preferences = defaults()
        let buffer = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        buffer.text = "rejected before acceptance"
        buffer.attachments.attachments = [file("/work/rejected")]
        let sent = buffer.submission()
        buffer.submitted(sent)
        buffer.rejected(sent)
        let restored = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        XCTAssertEqual(restored.text, buffer.text)
        XCTAssertEqual(restored.attachments.attachments.map(\.savedPath), ["/work/rejected"])
    }

    @MainActor
    func testReopenedStoreSharesSubmitLockAndUnknownFingerprint() async throws {
        let id = UUID().uuidString
        let receipt = try decode(SessionSnapshot.self, "{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"idle\"}")
        let transport = ComposerTransportStub(receipt: receipt, failure: WandAPI.APIError.network("lost receipt"))
        let drafts = SessionDraftStore()
        let first = ChatStore(sessionId: id, api: api, inputTransport: transport, drafts: drafts)
        let second = ChatStore(sessionId: id, api: api, inputTransport: transport, drafts: drafts)
        let finished = expectation(description: "Unknown receipt projected to both destinations")
        let subscription = second.$inputSending.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        XCTAssertTrue(first.send(text: "submit once"))
        XCTAssertTrue(second.inputSending)
        XCTAssertFalse(second.send(text: "submit twice"))
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(transport.inputs, ["submit once"])
        let reopened = ChatStore(sessionId: id, api: api, inputTransport: transport, drafts: drafts)
        XCTAssertEqual(reopened.unconfirmedInput, "submit once")
        XCTAssertFalse(reopened.send(text: "submit once"))
        drafts.remove(sessionId: id, api: api)
    }

    func testToolPreviewUsesServerProjectionAndBoundsOldHistory() throws {
        let use = try decode(ContentBlock.self, #"{"type":"tool_use","id":"t","name":"Read","preview":"server excerpt","input":{"file_path":"original/path"}}"#)
        guard case .toolUse(_, _, _, let input, _) = use else { return XCTFail("Expected invocation") }
        XCTAssertEqual(input["file_path"]?.stringValue, "original/path")
        XCTAssertEqual(toolInputPreview(input), "server excerpt")
        XCTAssertEqual(toolInputPreview(["command": .string(String(repeating: "x", count: 400))]).count, 180)
        let result = try decode(ContentBlock.self, #"{"type":"tool_result","tool_use_id":"t","content":"","preview":"bounded result","_truncated":true}"#)
        guard case .toolResult(_, let text, _, _, _, _, let projection) = result else { return XCTFail("Expected result") }
        XCTAssertEqual(toolResultPreview(text: text, projection: projection), "bounded result")
    }

    func testActivitySummaryUsesProjectionWithoutExposingBridgeMetadata() throws {
        func input(_ json: String) throws -> [String: JSONValue] {
            guard case .toolUse(_, _, _, let input, _) = try decode(ContentBlock.self, json) else {
                throw NSError(domain: "Expected tool invocation", code: 1)
            }
            return input
        }
        let projected = try input(#"{"type":"tool_use","id":"t","name":"Bash","preview":"Build completed","activity":{"kind":"command"},"input":{}}"#)
        XCTAssertEqual(activityToolSummary(description: nil, input: projected), "Build completed")
        XCTAssertEqual(toolInputDetail(projected), "")
        let metadataOnly = try input(#"{"type":"tool_use","id":"t","name":"Bash","occurredAt":"2026-10-23T01:00:00Z","input":{}}"#)
        XCTAssertEqual(activityToolSummary(description: nil, input: metadataOnly), "")
        let realArgument = try input(#"{"type":"tool_use","id":"t","name":"Custom","activity":{"kind":"other"},"input":{"value":"__wandToolActivity is user content"}}"#)
        XCTAssertEqual(activityToolSummary(description: nil, input: realArgument), "value: __wandToolActivity is user content")
        XCTAssertTrue(toolInputDetail(realArgument).contains("__wandToolActivity is user content"))
    }

    /// 时间线时钟的取值顺序与 Android 一致：activity 自带时间优先，其次块级 occurredAt，两者都没有时不造假。
    func testToolClockFallsBackToBlockTimestampWithoutFabricatingOne() throws {
        func clock(_ json: String) -> [String: JSONValue]? {
            guard case let .toolUse(_, _, _, input, _) = try? decode(ContentBlock.self, json) else { return nil }
            return input["__wandToolActivity"]?.objectValue
        }
        let withBoth = clock(#"{"type":"tool_use","id":"t","name":"Read","occurredAt":"2026-10-19T01:02:03Z","activity":{"kind":"read_file","occurredAt":"2026-10-19T00:00:00Z"},"input":{}}"#)
        XCTAssertEqual(withBoth?["occurredAt"]?.stringValue, "2026-10-19T00:00:00Z")
        XCTAssertEqual(withBoth?["kind"]?.stringValue, "read_file")
        let blockOnly = clock(#"{"type":"tool_use","id":"t","name":"Read","occurredAt":"2026-10-19T01:02:03Z","input":{}}"#)
        XCTAssertEqual(blockOnly?["occurredAt"]?.stringValue, "2026-10-19T01:02:03Z")
        let withoutTime = clock(#"{"type":"tool_use","id":"t","name":"Read","input":{}}"#)
        XCTAssertNil(withoutTime?["occurredAt"])
        XCTAssertNil(withoutTime?["kind"])
    }

    @MainActor
    func testLateDecisionResultRetainsStandaloneIdentityAndExplicitExpansion() throws {
        let result = try decode(ContentBlock.self, #"{"type":"tool_result","tool_use_id":"decision","content":"","_truncated":true,"semantic":{"kind":"decision","summary":{"label":"采用方案 B","outcome":"B"}}}"#)
        guard case .toolResult(let id, _, _, _, _, _, let projection) = result else { return XCTFail("Expected result") }
        XCTAssertTrue(projection?.isDecision == true)
        XCTAssertEqual(projection?.decisionLabel, "采用方案 B")
        XCTAssertFalse(isCollapsibleActivityTool(name: "Bash", input: [:], projection: projection))
        let state = DecisionCardExpansionState()
        XCTAssertFalse(state.isExpanded(id))
        state.toggle(id)
        XCTAssertTrue(state.isExpanded(id))
        XCTAssertFalse(state.isExpanded("other"))
        state.toggle(id)
        XCTAssertFalse(state.isExpanded(id))
    }

    @MainActor
    func testGroupingUsesPurposeRatherThanActivityMetadata() throws {
        let question = try decode(ContentBlock.self, #"{"type":"tool_use","id":"q","name":"functions.request_user_input","input":{},"activity":{"kind":"other","label":"question"},"semantic":{"kind":"question_request","questions":[{"question":"继续吗","multiSelect":false,"options":[{"label":"继续"}]}]}}"#)
        guard case .toolUse(_, let name, _, let input, _) = question else { return XCTFail("Expected question") }
        XCTAssertFalse(isCollapsibleActivityTool(name: name, input: input))
        XCTAssertFalse(isCollapsibleActivityTool(name: "Read", input: ["file_path": .string("chart.png")]))
        XCTAssertFalse(isCollapsibleActivityTool(name: "Task", input: [:]))
        XCTAssertTrue(isCollapsibleActivityTool(name: "Pi/todo", input: [:]))
        XCTAssertTrue(isCollapsibleActivityTool(name: "Bash", input: ["command": .string("cat decision-tool.md")]), "Reading decision documentation is an ordinary activity")
    }

    func testCompactSnapshotAddsLateDecisionWithoutDiscardingFullResult() throws {
        let local = try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"d","content":"complete locally loaded result"}]}"#)
        let incoming = try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"d","content":"","_truncated":true,"semantic":{"kind":"decision","summary":{"label":"选择 B","outcome":"B"}}}]}"#)
        let merged = applyingIncrementalMessage(incoming, expectedCount: 1, to: SessionMessageWindow(messages: [local], loadedOffset: 0, messageTotal: 1, leadingBlockOffset: 0, leadingBlockTotal: 1))
        guard case .toolResult(_, let text, _, let truncated, _, _, let projection) = merged.messages[0].content[0] else { return XCTFail("Expected result") }
        XCTAssertEqual(text, "complete locally loaded result")
        XCTAssertFalse(truncated)
        XCTAssertEqual(projection?.decisionLabel, "选择 B")
    }
    @MainActor
    func testCompletionSnapshotTracksBusyPermissionAndMonotonicRevisions() throws {
        let id = UUID().uuidString
        let store = ChatStore(sessionId: id, api: api, drafts: SessionDraftStore())
        store.handle(try decode(WsIncoming.self, "{\"type\":\"init\",\"sessionId\":\"\(id)\",\"data\":{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"running\",\"completionRevision\":4,\"viewedCompletionRevision\":2,\"structuredState\":{\"inFlight\":true},\"permissionBlocked\":true}}"))
        XCTAssertFalse(justCompleted(store.snapshot))
        store.handle(try decode(WsIncoming.self, "{\"type\":\"status\",\"sessionId\":\"\(id)\",\"data\":{\"status\":\"idle\",\"completionRevision\":3,\"viewedCompletionRevision\":1,\"structuredState\":{\"inFlight\":false},\"permissionBlocked\":false}}"))
        XCTAssertEqual(store.snapshot?.completionRevision, 4)
        XCTAssertEqual(store.snapshot?.viewedCompletionRevision, 2)
        XCTAssertEqual(store.snapshot?.status, "idle")
        XCTAssertTrue(justCompleted(store.snapshot))
        store.handle(try decode(WsIncoming.self, "{\"type\":\"output\",\"sessionId\":\"\(id)\",\"data\":{\"isResponding\":true,\"structuredState\":{\"inFlight\":true}}}"))
        XCTAssertTrue(store.snapshot?.isResponding == true)
        XCTAssertFalse(justCompleted(store.snapshot))
    }

    @MainActor
    func testRejectingNewDraftCannotPersistOldUnknownAttachment() {
        let preferences = defaults()
        let buffer = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        buffer.text = "unknown first submission"
        buffer.attachments.attachments = [file("/work/unknown")]
        buffer.submitted(buffer.submission())
        buffer.text = "new submission"
        buffer.attachments.attachments.append(file("/work/new"))
        let newer = buffer.submission()
        buffer.submitted(newer)
        buffer.rejected(newer)
        let restored = ComposerDraftState(sessionId: "one", api: api, defaults: preferences)
        XCTAssertEqual(restored.text, "new submission")
        XCTAssertEqual(restored.attachments.attachments.map(\.savedPath), ["/work/new"])
    }

    func testEqualBodySnapshotRetainsKnownDecisionAndImages() throws {
        let local = try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"d","content":[{"type":"text","text":"body"},{"type":"image","source":{"type":"url","url":"/image.png"}}],"semantic":{"kind":"decision","summary":{"label":"选择 B","outcome":"B"}}}]}"#)
        let incoming = try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"d","content":"body"}]}"#)
        let merged = applyingIncrementalMessage(incoming, expectedCount: 1, to: SessionMessageWindow(messages: [local], loadedOffset: 0, messageTotal: 1, leadingBlockOffset: 0, leadingBlockTotal: 1))
        guard case .toolResult(_, let text, _, _, let images, _, let projection) = merged.messages[0].content[0] else { return XCTFail("Expected result") }
        XCTAssertEqual(text, "body")
        XCTAssertEqual(images, ["/image.png"])
        XCTAssertEqual(projection?.decisionLabel, "选择 B")
    }

    @MainActor
    func testFetchedToolContentPreservesImageDecisionAndFullCommand() throws {
        let id = UUID().uuidString
        let store = ChatStore(sessionId: id, api: api, drafts: SessionDraftStore())
        store.messages = [try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_use","id":"d","name":"Bash","input":{},"preview":"short command","semantic":{"kind":"decision","summary":{"label":"选择 B","outcome":"B"}}},{"type":"tool_result","tool_use_id":"d","content":"","_truncated":true,"semantic":{"kind":"decision","summary":{"label":"选择 B","outcome":"B"}}}]}"#)]
        let loaded = try decode(ToolContentResponse.self, #"{"tool_use_id":"d","input":{"command":"the full original command"},"content":[{"type":"text","text":"full output"},{"type":"image","source":{"type":"url","url":"/image.png"}}],"is_error":true}"#)
        store.applyLoadedToolContent(loaded)
        guard case .toolUse(_, _, _, let input, _) = store.messages[0].content[0],
              case .toolResult(_, let text, let isError, let truncated, let images, _, let projection) = store.messages[0].content[1] else { return XCTFail("Expected invocation and result") }
        XCTAssertEqual(input["command"]?.stringValue, "the full original command")
        XCTAssertTrue(isDecisionTool(input: input))
        XCTAssertEqual(text, "full output")
        XCTAssertTrue(isError)
        XCTAssertFalse(truncated)
        XCTAssertEqual(images, ["/image.png"])
        XCTAssertEqual(projection?.decisionLabel, "选择 B")
    }

    @MainActor
    func testDeletedDraftCannotBeResurrectedByLateRejection() {
        let preferences = defaults()
        let buffer = ComposerDraftState(sessionId: "deleted", api: api, defaults: preferences)
        buffer.text = "submitted"
        buffer.attachments.attachments = [file("/work/submitted")]
        let submission = buffer.submission()
        buffer.submitted(submission)
        buffer.retire()
        buffer.rejected(submission)
        buffer.accepted(submission)
        buffer.activate()
        buffer.text = "late callback"
        let restored = ComposerDraftState(sessionId: "deleted", api: api, defaults: preferences)
        XCTAssertEqual(restored.text, "")
        XCTAssertTrue(restored.attachments.attachments.isEmpty)
        XCTAssertFalse(buffer.active)
    }

    func testUserAnswerResultPairsWithEarlierQuestionWithoutRewritingHistory() throws {
        let question = try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_use","id":"q","name":"AskUserQuestion","input":{"questions":[{"question":"继续吗","options":[{"label":"继续"}]}]}}]}"#)
        let answer = try decode(ConversationTurn.self, #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"q","content":"继续"}]}"#)
        let displayed = toolPairedDisplayTurns([question, answer])
        XCTAssertEqual(question.content.count, 1)
        XCTAssertEqual(answer.role, "user")
        XCTAssertEqual(answer.content.count, 1)
        XCTAssertEqual(displayed.count, 2, "Preserve absolute turn positions used by paging and history disclosure")
        XCTAssertEqual(displayed[0].content.count, 2)
        guard case .toolResult(let id, let text, _, _, _, _, _) = displayed[0].content[1] else { return XCTFail("Expected paired answer") }
        XCTAssertEqual(id, "q")
        XCTAssertEqual(text, "继续")
        XCTAssertTrue(displayed[1].content.isEmpty, "The result is rendered once beside its question")
    }

    func testResultsOnlyHistoryPageRemainsVisibleWithoutInvocation() throws {
        let answer = try decode(ConversationTurn.self, #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"old-decision","content":"done","semantic":{"kind":"decision","summary":{"label":"选择 B","outcome":"B"}}}]}"#)
        let displayed = toolPairedDisplayTurns([answer])
        XCTAssertEqual(displayed[0].role, "assistant")
        XCTAssertEqual(displayed[0].content.count, 1)
        guard case .toolResult(let id, _, _, _, _, _, let projection) = displayed[0].content[0] else { return XCTFail("Expected standalone result") }
        XCTAssertEqual(id, "old-decision")
        XCTAssertEqual(projection?.decisionLabel, "选择 B")
    }

}
