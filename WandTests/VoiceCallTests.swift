import Combine
import SwiftUI
import XCTest
@testable import Wand

@MainActor private final class CallRecognitionFake: CallRecognition {
    let updates = PassthroughSubject<String, Never>()
    var transcriptUpdates: AnyPublisher<String, Never> { updates.eraseToAnyPublisher() }
    var requiresFinalResult = false
    var started = 0
    var cancelled = 0
    var commit: ((String) -> Void)?
    var error: ((String) -> Void)?
    func start(api: WandAPI?, onError: @escaping (String) -> Void) { started += 1; error = onError }
    func stop(cancelled: Bool, commit: ((String) -> Void)?) { if cancelled { self.cancelled += 1 }; self.commit = commit }
}
@MainActor private final class CallSpeakerFake: CallTextSpeaker {
    let playback = PassthroughSubject<Bool, Never>()
    var playbackUpdates: AnyPublisher<Bool, Never> { playback.eraseToAnyPublisher() }
    var texts: [String] = []
    var stopped = 0
    var done: (() -> Void)?
    func speak(_ text: String, finished: @escaping () -> Void) throws { texts.append(text); done = finished }
    func stop() { stopped += 1; playback.send(false) }
}
@MainActor private final class CallSessionFake: CallSession {
    var isStructured = true
    var snapshot: SessionSnapshot? = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(#"{"id":"fixture","command":"test","cwd":"/work","status":"idle","employeeId":"e_fixture","sessionKind":"structured"}"#.utf8))
    var loading = false
    var loadError: String?
    var permissionBlocked = false
    var pendingEscalation: EscalationRequest?
    var isResponding = false
    var connected = true
    var status = "idle"
    var messages: [ConversationTurn] = []
    var unconfirmedInput: String?
    var inputFeedbackMessage: String?
    let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
    var sent: [String] = []
    var accepted: (() -> Void)?
    var failure: (() -> Void)?
    func callSend(text: String, onAccepted: @escaping () -> Void, onFailure: @escaping () -> Void) -> Bool {
        sent.append(text); accepted = onAccepted; failure = onFailure
        messages.append(ConversationTurn(role: "user", content: [.text(text: text, subagent: nil)]))
        isResponding = true; return true
    }
}

@MainActor final class VoiceCallTests: XCTestCase {
    func testNativeCatReservationKeepsViewportStableAcrossSidesAndStates() {
        for width: CGFloat in [320, 402, 768] {
            var regularHeight: CGFloat = 0
            for type: DynamicTypeSize in [.large, .accessibility3] {
                var reference: CGFloat?
                for side: CatComposerSide in [.left, .right] {
                    for status in ["", "正在听 · 上滑取消", "处理中", "正在朗读", "没有听到声音，请再试一次"] {
                        let root = CatComposerSurface(expanded: false, hasDraft: !status.isEmpty,
                            statusVisible: !status.isEmpty, side: side,
                            face: { size in Color.clear.frame(width: size, height: size) },
                            status: { Text(status).font(.caption) }, editor: { EmptyView() },
                            tools: { EmptyView() }, actions: {
                                HStack(spacing: 0) {
                                    Image(systemName: "mic").frame(width: 48, height: 48)
                                    Image(systemName: "keyboard").frame(width: 48, height: 48)
                                }
                            }).environment(\.dynamicTypeSize, type)
                        let height = UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width, height: 800)).height
                        if let reference { XCTAssertEqual(height, reference, accuracy: 1, "状态与侧别不得改变消息视口") }
                        else { reference = height }
                    }
                }
                if type == .large { regularHeight = reference ?? 0 }
                else { XCTAssertGreaterThan(reference ?? 0, regularHeight, "无障碍字号需要更多固定状态空间") }
            }
        }
    }
    func testFailedDraftStaysExpandedAfterTransientSendFeedbackExpires() async throws {
        let draft = ComposerDraftState(sessionId: UUID().uuidString, api: WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil))
        draft.beginSending(); draft.finishSending(accepted: false, message: "明确未接受")
        try await Task.sleep(nanoseconds: WandMotion.failedDwell + 150_000_000)
        XCTAssertEqual(draft.sendPhase, .idle)
        XCTAssertTrue(draft.submissionFailed)
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false,
            failed: draft.submissionFailed, unconfirmed: false))
        draft.beginSending(); XCTAssertFalse(draft.submissionFailed)
        draft.finishSending(accepted: true, message: nil); XCTAssertFalse(draft.submissionFailed)
    }
    func testCycleAndInterruptDropsLateTTSCompletion() {
        let recognition = CallRecognitionFake(), speaker = CallSpeakerFake(), session = CallSessionFake()
        let call = VoiceCallController(recognition: recognition, speaker: speaker)
        call.start(store: session)
        XCTAssertEqual(call.phase, .listening)
        recognition.updates.send("检查文件")
        call.finishListening(); recognition.commit?("检查文件")
        XCTAssertEqual(session.sent, ["检查文件"])
        session.accepted?(); XCTAssertEqual(call.phase, .waiting)
        session.messages.append(ConversationTurn(role: "assistant", content: [.text(text: "已检查。```swift\nsecret code\n```", subagent: nil)], completedAt: "now"))
        session.isResponding = false; call.update()
        XCTAssertEqual(call.phase, .speaking)
        XCTAssertFalse(call.isSpeaking)
        speaker.playback.send(true); XCTAssertTrue(call.isSpeaking)
        XCTAssertFalse(speaker.texts[0].contains("secret code"))
        let late = speaker.done
        call.interrupt(); XCTAssertEqual(call.phase, .listening)
        XCTAssertFalse(call.isSpeaking)
        speaker.playback.send(true); XCTAssertFalse(call.isSpeaking)
        let starts = recognition.started
        late?(); XCTAssertEqual(recognition.started, starts)
        call.end(); XCTAssertEqual(call.phase, .off)
    }
    func testUnknownDeliveryStopsAndNeverRepeats() {
        let recognition = CallRecognitionFake(), session = CallSessionFake()
        let call = VoiceCallController(recognition: recognition, speaker: CallSpeakerFake())
        call.start(store: session); call.finishListening(); recognition.commit?("输入")
        session.unconfirmedInput = "输入"; call.update()
        XCTAssertEqual(call.phase, .error)
        session.accepted?(); call.update()
        XCTAssertEqual(call.phase, .error)
        XCTAssertEqual(session.sent.count, 1)
    }
    func testApprovalAndBackgroundInvalidateRecognition() {
        let recognition = CallRecognitionFake(), session = CallSessionFake()
        let call = VoiceCallController(recognition: recognition, speaker: CallSpeakerFake())
        call.start(store: session); call.finishListening()
        let late = recognition.commit
        session.permissionBlocked = true; call.update()
        XCTAssertEqual(call.phase, .approval)
        late?("不得发送"); XCTAssertTrue(session.sent.isEmpty)
        session.permissionBlocked = false; call.resume()
        call.pause("后台"); recognition.updates.send("迟到")
        XCTAssertEqual(call.phase, .paused); XCTAssertTrue(session.sent.isEmpty)
    }
    func testMicrophoneFailurePreservesTextChatAndSummaryBounds() {
        let recognition = CallRecognitionFake(), session = CallSessionFake()
        let call = VoiceCallController(recognition: recognition, speaker: CallSpeakerFake())
        call.start(store: session); recognition.error?("权限被拒绝")
        XCTAssertEqual(call.phase, .error); XCTAssertEqual(call.notice, "权限被拒绝")
        XCTAssertTrue(session.sent.isEmpty)
        XCTAssertLessThan(callSpokenSummary(String(repeating: "长", count: 2000)).count, 1000)
    }
    func testChangedTargetCannotReceiveLateFinalTranscript() throws {
        let recognition = CallRecognitionFake(), session = CallSessionFake()
        let call = VoiceCallController(recognition: recognition, speaker: CallSpeakerFake())
        call.start(store: session); call.finishListening()
        session.snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(#"{"id":"other","command":"test","cwd":"/other","status":"idle","employeeId":"e_other","sessionKind":"structured"}"#.utf8))
        recognition.commit?("原会话的转写")
        XCTAssertEqual(call.phase, .error)
        XCTAssertTrue(session.sent.isEmpty)
        XCTAssertEqual(call.transcript, "原会话的转写")
    }
    func testAcknowledgedComposerOnlyRestsWithNoEditingOrUncertainInput() {
        func rests(_ focused: Bool = false, _ draft: Bool = false, _ attachments: Bool = false,
                   _ composing: Bool = false, _ phase: ComposerSendPhase = .idle, _ uncertain: Bool = false) -> Bool {
            composerUsesRestingSurface(acknowledged: true, focused: focused, hasDraft: draft,
                hasAttachments: attachments, composing: composing, phase: phase, unconfirmed: uncertain)
        }
        XCTAssertTrue(rests())
        XCTAssertTrue(rests(false, false, false, false, .sent))
        XCTAssertFalse(rests(true)); XCTAssertFalse(rests(false, true))
        XCTAssertFalse(rests(false, false, true)); XCTAssertFalse(rests(false, false, false, true))
        XCTAssertFalse(rests(false, false, false, false, .failed))
        XCTAssertFalse(rests(false, false, false, false, .sending))
        XCTAssertFalse(rests(false, false, false, false, .idle, true))
        XCTAssertFalse(composerUsesRestingSurface(acknowledged: false, focused: false, hasDraft: false,
            hasAttachments: false, composing: false, phase: .idle, unconfirmed: false))
    }
    func testLongDraftExpansionAffordance() {
        XCTAssertEqual(composerMaximumInputHeight(compact: true, keyboardVisible: true), 64)
        XCTAssertEqual(composerMaximumInputHeight(compact: true, keyboardVisible: false), 132)
        XCTAssertEqual(composerMaximumInputHeight(compact: false, keyboardVisible: true), 180)
        XCTAssertTrue(composerOffersExpandedEditor(text: "短屏多行", measuredHeight: 64, maximumHeight: 64))
        XCTAssertFalse(composerOffersExpandedEditor(text: "短消息", measuredHeight: 34))
        XCTAssertTrue(composerOffersExpandedEditor(text: String(repeating: "长", count: 852), measuredHeight: 180))
        XCTAssertTrue(composerOffersExpandedEditor(text: "1\n2\n3\n4\n5\n6", measuredHeight: 100))
        XCTAssertTrue(composerOffersExpandedEditor(text: "多行", measuredHeight: 180))
    }
    func testCatPressTapHoldCancelAndInterruptedPointer() {
        XCTAssertEqual(CatInputPressState.holdDelay, 0.3)
        var press = CatInputPressState()
        XCTAssertEqual(press.end(), .tap)
        XCTAssertTrue(press.beginHold())
        XCTAssertFalse(press.beginHold())
        press.move(x: 0, y: -61)
        XCTAssertEqual(press.end(), .voice(cancelled: true))
        press.move(x: 0, y: 20)
        XCTAssertFalse(press.beginHold())
        XCTAssertEqual(press.end(), .none)
        XCTAssertTrue(press.beginHold())
        press.move(x: 0, y: -61)
        press.move(x: 0, y: -10)
        XCTAssertEqual(press.end(), .voice(cancelled: false))
        XCTAssertEqual(press.end(), .tap)
    }
    func testCatVisibilityNeverHidesFailureOrUnknownDelivery() {
        XCTAssertFalse(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: false, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: true, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: false, unconfirmed: true))
        XCTAssertTrue(catComposerExpanded(editing: true, focused: false, keyboard: false, failed: false, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: true, failed: false, unconfirmed: false))
    }
    func testCatDragNeverStartsRecordingAndRecordingNeverMovesSide() {
        var press = CatInputPressState()
        press.move(x: 75, y: 3)
        XCTAssertFalse(press.beginHold())
        XCTAssertEqual(press.end(), .drag(75))
        XCTAssertTrue(press.beginHold())
        press.move(x: 170, y: -80)
        XCTAssertFalse(press.dragging)
        XCTAssertEqual(press.end(), .voice(cancelled: true))
    }
    func testCatSideIsSharedLocallyAcrossChatsAndReloads() throws {
        let name = "wand.cat-side.test.\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { first.removePersistentDomain(forName: name) }
        XCTAssertEqual(CatComposerSide.load(first), .left)
        CatComposerSide.left.dropped(translation: 80).save(first)
        XCTAssertEqual(CatComposerSide.load(try XCTUnwrap(UserDefaults(suiteName: name))), .right)
        XCTAssertEqual(CatComposerSide.right.dropped(translation: -30), .right)
        XCTAssertEqual(CatComposerSide.right.dropped(translation: -80), .left)
        first.set("invalid", forKey: CatComposerSide.preferenceKey)
        XCTAssertEqual(CatComposerSide.load(first), .left)
    }
    func testCapsuleThirdActionOnlyUsesTextAndThinkingEndsAtStreaming() {
        XCTAssertFalse(catCapsuleShowsThirdAction(text: " \n "))
        XCTAssertTrue(catCapsuleShowsThirdAction(text: "待发送"))
        var messages = [ConversationTurn(role: "user", content: [.text(text: "test", subagent: nil)]),
                        ConversationTurn(role: "assistant", content: [.thinking(thinking: "thinking", subagent: nil)])]
        XCTAssertTrue(avatarIsThinking(messages: messages, executing: true))
        messages[1] = ConversationTurn(role: "assistant", content: messages[1].content + [.text(text: "reply", subagent: nil)])
        XCTAssertFalse(avatarIsThinking(messages: messages, executing: true))
        messages.append(ConversationTurn(role: "user", content: [.text(text: "next", subagent: nil)]))
        XCTAssertFalse(avatarIsThinking(messages: messages, executing: true))
        XCTAssertFalse(avatarIsThinking(messages: messages, executing: false))
    }
    func testFileActivityRetiresErrorsAndUsesLatestCurrentTurn() throws {
        let data = Data(#"[{"role":"user","content":[{"type":"text","text":"test"}]},{"role":"assistant","content":[{"type":"tool_use","id":"r","name":"read","activity":{"kind":"read_file"}},{"type":"tool_use","id":"w","name":"write","activity":{"kind":"edit_file"}},{"type":"tool_result","tool_use_id":"w","content":"failed","is_error":true}]}]"#.utf8)
        let messages = try JSONDecoder().decode([ConversationTurn].self, from: data)
        XCTAssertEqual(avatarFileActivity(messages: messages, executing: true), .reading)
        XCTAssertEqual(avatarFileActivity(messages: messages, executing: false), .idle)
        let next = messages + [ConversationTurn(role: "user", content: [.text(text: "next", subagent: nil)])]
        XCTAssertEqual(avatarFileActivity(messages: next, executing: true), .idle)
    }
}
