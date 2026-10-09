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

final class ComposerToolParityTests: XCTestCase {
    func testIdleInputHoldToTalkPreservesEditingAndKeyboardStates() {
        XCTAssertTrue(composerHoldToTalkEligible(text: "", focused: false, keyboardVisible: false))
        XCTAssertFalse(composerHoldToTalkEligible(text: "", focused: true, keyboardVisible: false))
        XCTAssertFalse(composerHoldToTalkEligible(text: "", focused: false, keyboardVisible: true))
        XCTAssertFalse(composerHoldToTalkEligible(text: "草稿", focused: false, keyboardVisible: false))
        XCTAssertFalse(composerHoldToTalkEligible(text: " ", focused: false, keyboardVisible: false))
        XCTAssertFalse(composerShouldExpand(focused: false, voiceMode: true))
    }

    func testServerSpeechWavUsesCanonicalPCM16HeaderAndBounds() throws {
        let pcm = Data(repeating: 12, count: 3200)
        let wav = try SpeechWav.encode(pcm)
        XCTAssertEqual(wav.count, 3244)
        XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<16), encoding: .ascii), "WAVEfmt ")
        XCTAssertEqual(wav.subdata(in: 44..<wav.count), pcm)
        XCTAssertEqual(Array(wav[20..<24]), [1, 0, 1, 0])
        XCTAssertEqual(Array(wav[24..<28]), [128, 62, 0, 0])
        XCTAssertEqual(Array(wav[34..<36]), [16, 0])
        for count in [0, 100, 3201, SpeechWav.maxPCMBytes + 2] {
            XCTAssertThrowsError(try SpeechWav.encode(Data(repeating: 0, count: count)))
        }
    }
    func testServerSpeechStatusDecodesReadyAndRecoveryReason() throws {
        let status = try JSONDecoder().decode(ServerSpeechStatus.self, from: Data("""
        {"ready":false,"reason":"模型未下载","settings":{"model":"base"},"runtime":{"backend":"cpu"}}
        """.utf8))
        XCTAssertFalse(status.ready)
        XCTAssertEqual(status.reason, "模型未下载")
        XCTAssertEqual(status.settings.model, "base")
        XCTAssertEqual(status.runtime.backend, "cpu")
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

    @MainActor
    func testVoiceAndOptimizationIgnoreClosedOrNewerDrafts() {
        let buffer = ComposerDraftState(sessionId: "one", api: api, defaults: defaults())
        buffer.text = "initial"
        let revision = buffer.textRevision
        let lifecycle = buffer.lifecycleRevision
        buffer.deactivate()
        buffer.activate()
        buffer.appendVoice("late speech", ifUnchangedSince: revision, lifecycle: lifecycle)
        XCTAssertEqual(buffer.text, "initial")
        XCTAssertFalse(buffer.applyOptimized("late optimized", revision: revision, lifecycle: lifecycle))
        let currentLifecycle = buffer.lifecycleRevision
        buffer.text = "newer"
        XCTAssertFalse(buffer.applyOptimized("old result", revision: revision, lifecycle: currentLifecycle))
        XCTAssertEqual(buffer.text, "newer")
        XCTAssertTrue(buffer.applyOptimized("current result", revision: buffer.textRevision, lifecycle: currentLifecycle))
        XCTAssertEqual(buffer.text, "current result")
    }

    @MainActor
    func testAsyncOptimizationKeepsEditsMadeWhileWaiting() async {
        let buffer = ComposerDraftState(sessionId: "one", api: api, defaults: defaults())
        buffer.text = "original"
        let started = expectation(description: "Optimization began")
        let finished = expectation(description: "Optimization finished")
        var continuation: CheckedContinuation<String, Never>?
        let subscription = buffer.$isOptimizing.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        buffer.optimize { text in
            XCTAssertEqual(text, "original")
            return await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        buffer.text = "typed while optimizing"
        continuation?.resume(returning: "optimized old input")
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(buffer.text, "typed while optimizing")
        XCTAssertEqual(buffer.optimizationMessage, "输入已更新，保留当前内容")
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

    @MainActor
    func testRepeatedActivationDoesNotInvalidatePendingOptimizationOrVoice() {
        let buffer = ComposerDraftState(sessionId: "one", api: api, defaults: defaults())
        buffer.text = "initial"
        let revision = buffer.textRevision
        let lifecycle = buffer.lifecycleRevision
        buffer.activate()
        buffer.activate()
        XCTAssertEqual(buffer.lifecycleRevision, lifecycle)
        buffer.appendVoice("voice", ifUnchangedSince: revision, lifecycle: lifecycle)
        XCTAssertEqual(buffer.text, "initial voice")
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
