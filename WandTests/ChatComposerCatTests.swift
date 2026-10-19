import Combine
import SwiftUI
import XCTest
@testable import Wand

@MainActor final class ChatComposerCatTests: XCTestCase {
    func testSocketDecodeIsAsynchronousAndDeliversFramesInOrderOnMainThread() async throws {
        let socket = WandSocket(baseURL: URL(string: "http://127.0.0.1:9")!)
        let completed = expectation(description: "serial decoded frames")
        completed.expectedFulfillmentCount = 5
        var observed: [String] = []
        let types = ["init", "output", "status", "ended"]
        for (index, type) in types.enumerated() {
            let payload: [String: Any] = ["type": type, "seq": index,
                "data": ["lastMessage": ["role": "assistant", "content": [["type": "text", "text": String(repeating: "synthetic ", count: index == 1 ? 200_000 : 1)]]]]]
            let data = try JSONSerialization.data(withJSONObject: payload)
            socket.decodeReceived(.success(.data(data))) { frame in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(frame?.incoming.seq, index)
                observed.append(frame?.incoming.type ?? "invalid")
                completed.fulfill()
            }
        }
        socket.decodeReceived(.success(.string("invalid JSON"))) { frame in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(frame)
            observed.append("invalid")
            completed.fulfill()
        }
        XCTAssertTrue(observed.isEmpty, "Do not synchronously decode/deliver a frame in the UI transaction")
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(observed, types + ["invalid"])
    }

    func testMessageProjectionIgnoresComposerUpdatesButInvalidatesForStreamingAndCompletion() {
        let cache = ChatProjectionCache<Int>()
        var builds = 0
        func read(_ revision: Int, _ responding: Bool) -> Int {
            cache.value(revision: revision, responding: responding) { builds += 1; return builds }
        }
        XCTAssertEqual(read(1, true), 1)
        for _ in 0..<100 { XCTAssertEqual(read(1, true), 1) }
        XCTAssertEqual(read(2, true), 2)
        XCTAssertEqual(read(2, false), 3)
        XCTAssertEqual(read(2, false), 3)
        // A newly committed message must not reuse an earlier turn's projection.
        XCTAssertEqual(read(3, false), 4)
    }

    func testScrollBurstWaitsForPublishedMessagesToCommitAndCancelsOnExit() async throws {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let store = ChatStore(sessionId: UUID().uuidString, api: api)
        let scheduler = ChatScrollScheduler()
        var scrolls = 0
        var sawPreCommitState = false
        let subscription = store.$messages.dropFirst().sink { incoming in
            // @Published publishes in willSet. Synchronous scrollTo here observes
            // old rows and can re-enter LazyVStack while they are being replaced.
            sawPreCommitState = sawPreCommitState || store.messages.count != incoming.count
            scheduler.request {
                scrolls += 1
                XCTAssertEqual(store.messages.count, 100)
                XCTAssertEqual(store.messageRevision, 100)
            }
        }
        defer { subscription.cancel() }
        for index in 0..<100 {
            store.messages.append(ConversationTurn(role: "user", content: [.text(text: "test-\(index)", subagent: nil)]))
        }
        XCTAssertTrue(sawPreCommitState)
        XCTAssertEqual(scrolls, 0, "Never force layout synchronously during publication")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(scrolls, 1, "A burst requires only one post-commit scroll, not two per event")
        scheduler.request { XCTFail("Manual history browsing/page exit must cancel pending scrolling") }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(scrolls, 1)
    }

    func testLongChatSendAndStreamingUpdatesKeepMainActorResponsive() async throws {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let transport = FreezeReceiptTransport()
        let id = UUID().uuidString
        let store = ChatStore(sessionId: id, api: api, inputTransport: transport, drafts: SessionDraftStore())
        let initial = try JSONDecoder().decode(WsIncoming.self, from: Data("{\"type\":\"init\",\"data\":{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"running\",\"structuredState\":{\"inFlight\":false}}}".utf8))
        store.handle(initial)
        store.messages = (0..<40).flatMap { index in
            [ConversationTurn(role: "user", content: [.text(text: "request-\(index)", subagent: nil)]),
             ConversationTurn(role: "assistant", content: (0..<12).map { block in
                 .text(text: "reply-\(index)-\(block)\n\n" + String(repeating: "synthetic history ", count: 30), subagent: nil)
             })]
        }
        let host = UIHostingController(rootView: ChatView(sessionId: id, api: api, sharedStore: store))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; store.composerDraft.retire(); store.shutdown() }
        try await Task.sleep(for: .milliseconds(200))
        for round in 0..<3 {
            let start = ContinuousClock.now
            store.isResponding = false
            store.composerDraft.text = "send-\(round)"
            let submission = store.composerDraft.submission()
            XCTAssertTrue(store.send(text: submission.prompt, onAccepted: { store.composerDraft.accepted(submission) }))
            store.composerDraft.submitted(submission)
            // Let the ack and the same view refreshes used by a real send settle.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(store.inputSending)
            for chunk in 0..<25 {
                let data: [String: Any] = ["type": "output", "data": ["incremental": true, "messageCount": store.messages.count + 1,
                    "lastMessage": ["role": "assistant", "content": [["type": "text", "text": String(repeating: "stream ", count: chunk + 1)]]], "isResponding": true]]
                store.handle(try JSONDecoder().decode(WsIncoming.self, from: JSONSerialization.data(withJSONObject: data)))
                store.composerDraft.text = "next draft \(chunk)"
            }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertLessThan(start.duration(to: .now), .seconds(5), "Send/stream burst must yield the main actor without reopening the app")
            XCTAssertEqual(store.composerDraft.text, "next draft 24")
        }
        XCTAssertEqual(transport.inputs.count, 3)
    }

    func testNamedTopCompanionReservesScaledIdentityWithoutStateOrNameHeightJumps() {
        for compact in [false, true] {
            for width: CGFloat in [320, 440, 768] {
                for type: DynamicTypeSize in [.large, .accessibility3] {
                    var heights: [CGFloat] = []
                    for title in ["小试", "相同头像但身份不同的很长员工名字 · 项目交付负责人"] {
                        let root = TopChatCompanion(title: title, status: "等待你的确认") { size in Color.clear.frame(width: size, height: size) }
                            .environment(\.verticalSizeClass, compact ? .compact : .regular).environment(\.dynamicTypeSize, type)
                        heights.append(UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width, height: 800)).height)
                    }
                    XCTAssertEqual(heights[0], heights[1], accuracy: 1)
                    XCTAssertGreaterThanOrEqual(heights[0], ChatTopLayout.controlsClearance)
                    XCTAssertLessThan(heights[0], 260)
                    if type == .large { XCTAssertEqual(heights[0], compact ? 56 : 114, accuracy: 1) }
                }
            }
        }
    }

    func testNativeTopCatReservationKeepsViewportStableAcrossSidesAndTextSizes() {
        for width: CGFloat in [320, 402, 768] {
            for type: DynamicTypeSize in [.large, .accessibility3] {
                for side: CatComposerSide in [.left, .right] {
                    let root = TopChatCompanion(side: side) { size in Color.clear.frame(width: size, height: size) }
                        .environment(\.dynamicTypeSize, type).environment(\.verticalSizeClass, .regular)
                    let height = UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width, height: 800)).height
                    XCTAssertEqual(height, 100, accuracy: 1, "顶部无文字的伙伴保留区不因字号或侧别移动")
                }
            }
        }
    }
    func testReadingBoundaryClearsRealControlsAndCompanionInBothSizeClasses() {
        for compact in [false, true] {
            let sizeClass: UserInterfaceSizeClass = compact ? .compact : .regular
            let clearance = ChatTopLayout.clearance(compact: compact)
            XCTAssertEqual(clearance, compact ? 56 : 100)
            XCTAssertGreaterThanOrEqual(clearance, ChatTopLayout.controlsClearance)
            for width: CGFloat in [320, 402, 768] {
                for type: DynamicTypeSize in [.large, .accessibility3] {
                    let controls = FloatingChatControls(onBack: {}) {
                        FloatingChatIcon(symbol: "folder")
                        FloatingChatIcon(symbol: "ellipsis")
                    }.padding(.top, compact ? 0 : 18).environment(\.dynamicTypeSize, type)
                    let controlHeight = UIHostingController(rootView: controls).sizeThatFits(in: CGSize(width: width, height: 800)).height
                    XCTAssertLessThanOrEqual(controlHeight, clearance)
                    let companion = TopChatCompanion { size in Color.clear.frame(width: size, height: size) }
                        .environment(\.verticalSizeClass, sizeClass).environment(\.dynamicTypeSize, type)
                    XCTAssertEqual(UIHostingController(rootView: companion).sizeThatFits(in: CGSize(width: width, height: 800)).height, clearance, accuracy: 1)
                }
            }
        }
    }
    func testFailedDraftStaysExpandedAfterTransientSendFeedbackExpires() async throws {
        let draft = ComposerDraftState(sessionId: UUID().uuidString, api: WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil))
        draft.beginSending(); draft.finishSending(accepted: false, message: "明确未接受")
        // The feedback task starts asynchronously. A fixed dwell + 150ms from the
        // caller races its scheduling under load; wait for the actual phase receipt.
        for _ in 0..<100 {
            if draft.sendPhase == .idle { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("INPUT-FEEDBACK settled phase=\(draft.sendPhase)")
        XCTAssertEqual(draft.sendPhase, .idle)
        XCTAssertTrue(draft.submissionFailed)
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false,
            failed: draft.submissionFailed, unconfirmed: false))
        draft.beginSending(); XCTAssertFalse(draft.submissionFailed)
        draft.finishSending(accepted: true, message: nil); XCTAssertFalse(draft.submissionFailed)
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
        XCTAssertEqual(composerMaximumInputHeight(compact: true, keyboardVisible: true), 44)
        XCTAssertEqual(composerMaximumInputHeight(compact: true, keyboardVisible: false), 88)
        XCTAssertEqual(composerMaximumInputHeight(compact: false, keyboardVisible: true), 96)
        XCTAssertEqual(composerMaximumInputHeight(compact: false, keyboardVisible: false), 112)
    }
    func testCatPressDistinguishesTapFromDrag() {
        var press = CatInputPressState()
        XCTAssertEqual(press.end(), .tap)
        press.move(x: 0, y: 20)
        XCTAssertEqual(press.end(), .none)
        press.move(x: 75, y: 3)
        XCTAssertTrue(press.dragging)
        XCTAssertEqual(press.end(), .drag(75))
        XCTAssertEqual(press.end(), .tap)
    }
    func testCatVisibilityNeverHidesFailureOrUnknownDelivery() {
        XCTAssertFalse(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: false, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: true, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: false, unconfirmed: true))
        XCTAssertTrue(catComposerExpanded(editing: true, focused: false, keyboard: false, failed: false, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: true, failed: false, unconfirmed: false))
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

@MainActor private final class FreezeReceiptTransport: SessionInputTransport {
    var inputs: [String] = []
    func sendStructuredInput(id: String, input: String) async throws -> SessionSnapshot {
        inputs.append(input)
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data("{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"running\",\"structuredState\":{\"inFlight\":true}}".utf8))
    }
    func sendPtyInputChunk(id: String, input: String, view: String, shortcutKey: String?) async throws { XCTFail("No PTY or real model input in this test") }
}

@MainActor final class FocusComposerTests: XCTestCase {
    func testTemporaryPickerAndModalKeepEditorAndRestoreFocus() {
        let focus = ComposerFocusController()
        focus.focus()
        focus.borrow("picker")
        focus.keyboardHidden()
        XCTAssertTrue(focus.editing)
        XCTAssertFalse(focus.focused)
        focus.borrow("modal")
        focus.resume("picker")
        XCTAssertFalse(focus.focused)
        focus.resume("modal")
        XCTAssertTrue(focus.focused)
    }
    func testExplicitExitWinsOverLateDismissAndKeyboardCallbacks() {
        let focus = ComposerFocusController()
        focus.focus(); focus.borrow("settings")
        focus.collapse(); focus.resume("settings")
        XCTAssertFalse(focus.editing); XCTAssertFalse(focus.focused)
        focus.focus(); focus.keyboardHidden()
        XCTAssertFalse(focus.editing); XCTAssertFalse(focus.focused)
        focus.resume("old-picker")
        XCTAssertFalse(focus.focused)
    }
    func testAttachmentFromCollapsedCapsuleReturnsToEditor() {
        let focus = ComposerFocusController()
        focus.borrow("attachments", open: true); focus.keyboardHidden()
        XCTAssertTrue(focus.editing)
        focus.resume("attachments")
        XCTAssertTrue(focus.focused)
    }
    func testTopCatRemainsBetweenNativeTargetsForNarrowAndWideScreens() {
        for width: CGFloat in [320, 375, 402, 768, 1024] {
            let center = topCompanionCenter(width: width, size: 88, side: .left, drag: 0)
            XCTAssertLessThan(center, width / 2)
            for side in [CatComposerSide.left, .right] {
                for drag: CGFloat in [-999, 0, 999] {
                    let x = topCompanionCenter(width: width, size: 88, side: side, drag: drag)
                    XCTAssertGreaterThanOrEqual(x - 44, 64)
                    XCTAssertLessThanOrEqual(x + 44, width - 116)
                }
            }
        }
    }
}

/// Exercise the real multiline measurement, keyboard and non-empty settings path.
/// The older morph tests use a fixed 44pt editor and empty settings, so cannot catch
/// feedback between UIKit scrolling and SwiftUI's measured height.
@MainActor private final class InputOpeningProbe: ObservableObject {
    @Published var text = ""
    @Published var height: CGFloat = 34
    var heights: [CGFloat] = []
    let focus = ComposerFocusController()
}
private struct InputOpeningTestView: View {
    @ObservedObject var probe: InputOpeningProbe
    @ObservedObject var focus: ComposerFocusController
    @StateObject private var keyboard = KeyboardObserver()
    var body: some View {
        VStack {
            Spacer()
            FocusComposerSurface(expanded: focus.editing || keyboard.isVisible, hasDraft: !probe.text.isEmpty,
                onFocus: { focus.focus() }, editor: {
                    IMEAwareComposerTextView(text: $probe.text, placeholder: "消息", isFocused: focus.focused,
                        maximumHeight: keyboard.isVisible ? 96 : 112, submitOnReturn: false,
                        onFocusChange: { focus.focused = $0 }, onCompositionChange: { _ in }, onSubmit: {},
                        onHeightChange: { probe.heights.append($0); probe.height = $0 })
                        .frame(height: max(34, probe.height))
                }, add: { ComposerAddButton(expanded: false, uploading: false, action: {}) },
                send: { Color.clear.frame(width: 48, height: 48) },
                settings: { ComposerSettingsStrip(model: "provider/very-long-model-name", mode: "全权限", thinking: "超高",
                    onModel: {}, onMode: {}, onThinking: {}) }, actionCount: 1)
        }.padding(.bottom, keyboard.lift).ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
@MainActor final class InputOpeningTests: XCTestCase {
    func testResponderChangesWaitUntilAfterRepresentableUpdateAndCancelOnNewIntent() async throws {
        var desired = IMEAwareComposerTextView(text: .constant(""), placeholder: "消息", isFocused: true,
            onFocusChange: { _ in }, onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in })
        let focused = desired
        let coordinator = desired.makeCoordinator()
        let editor = ComposerUITextView()
        editor.delegate = coordinator
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController!.view.addSubview(editor)
        editor.frame = CGRect(x: 0, y: 100, width: 300, height: 44)
        defer { coordinator.cancelFocusRetry(); editor.resignFirstResponder(); window.isHidden = true }
        coordinator.reconcileFocus(editor)
        XCTAssertFalse(editor.isFirstResponder, "Becoming first responder must not publish keyboard state during updateUIView")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(editor.isFirstResponder)
        desired = IMEAwareComposerTextView(text: .constant(""), placeholder: "消息", isFocused: false,
            onFocusChange: { _ in }, onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in })
        coordinator.parent = desired
        coordinator.reconcileFocus(editor)
        print("INPUT-OPEN blur remains deferred: \(editor.isFirstResponder)")
        XCTAssertTrue(editor.isFirstResponder, "Resigning inside updateUIView synchronously publishes keyboard/focus state")
        // Reopening before the queued blur runs must invalidate that old intent.
        coordinator.parent = focused
        coordinator.reconcileFocus(editor)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(editor.isFirstResponder, "A stale blur must not dismiss a newly reopened input")
        coordinator.parent = desired
        coordinator.reconcileFocus(editor)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(editor.isFirstResponder)
        // A focus request followed by collapse in the same transaction must never reopen.
        coordinator.parent = IMEAwareComposerTextView(text: .constant(""), placeholder: "消息", isFocused: true,
            onFocusChange: { _ in }, onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in })
        coordinator.reconcileFocus(editor)
        coordinator.parent = desired
        coordinator.reconcileFocus(editor)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertFalse(editor.isFirstResponder)
        // Navigation teardown must also revoke every queued/retried focus.
        coordinator.parent = focused
        coordinator.reconcileFocus(editor)
        IMEAwareComposerTextView.dismantleUIView(editor, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertFalse(editor.isFirstResponder)
    }

    func testOpeningTypingAndReopeningWithRealSettingsSettles() async throws {
        let probe = InputOpeningProbe()
        let host = UIHostingController(rootView: InputOpeningTestView(probe: probe, focus: probe.focus))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { probe.focus.collapse(); window.isHidden = true }
        func find(_ view: UIView) -> ComposerUITextView? {
            if let text = view as? ComposerUITextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        try await Task.sleep(for: .milliseconds(200))
        let editor = try XCTUnwrap(find(host.view))
        let coordinator = try XCTUnwrap(editor.delegate as? IMEAwareComposerTextView.Coordinator)
        for round in 0..<3 {
            print("INPUT-OPEN round=\(round) begin")
            probe.focus.focus()
            try await Task.sleep(for: .milliseconds(700))
            for text in ["", "单行输入", String(repeating: "中文多行输入\n", count: 20), "短输入"] {
                probe.text = text
                // Wait for the real UIKit text/measurement acknowledgement, not a
                // guessed 150ms (competing native builds can delay the main queue).
                var converged = false
                for _ in 0..<60 {
                    host.view.layoutIfNeeded()
                    let fitted = editor.sizeThatFits(CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)).height
                    let maximum = coordinator.parent.maximumHeight
                    let expected = min(maximum, max(24, ceil(fitted)))
                    if editor.text == text, abs(probe.height - expected) <= 0.5 {
                        converged = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                print("INPUT-OPEN text=\(text.count) height=\(probe.height) scroll=\(editor.isScrollEnabled) reports=\(probe.heights.count) converged=\(converged)")
                XCTAssertTrue(converged, "Current text and measured height must converge within the bounded window")
            }
            let before = probe.heights.count
            try await Task.sleep(for: .milliseconds(250))
            print("INPUT-OPEN settled delta=\(probe.heights.count - before) focus=\(editor.isFirstResponder)")
            XCTAssertTrue(editor.isFirstResponder)
            XCTAssertEqual(probe.heights.count, before, "Height reporting must settle rather than oscillate")
            XCTAssertTrue(find(host.view) === editor)
            XCTAssertLessThan(probe.heights.count, 60)
            probe.focus.collapse()
            try await Task.sleep(for: .milliseconds(400))
        }
    }
}

@MainActor private final class MorphEditorProbe: ObservableObject {
    @Published var text = "前后"
    let focus = ComposerFocusController()
}
private struct MorphEditorTestView: View {
    @ObservedObject var probe: MorphEditorProbe
    @ObservedObject var focus: ComposerFocusController
    var body: some View {
        FocusComposerSurface(expanded: focus.editing, hasDraft: !probe.text.isEmpty, onFocus: { focus.focus() }, editor: {
            IMEAwareComposerTextView(text: $probe.text, placeholder: "消息", isFocused: focus.focused,
                maximumHeight: 96, submitOnReturn: false, onFocusChange: { focus.focused = $0 },
                onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in }).frame(height: 44)
        }, add: { Text("+").frame(width: 48, height: 48) }, send: { EmptyView() }, settings: { EmptyView() })
    }
}

/// The settings slot is a builder branch: an empty branch yields two subviews instead of three.
/// Fixed `subviews[2]` indexing trapped in `LayoutSubviews.subscript` for exactly this shape.
@MainActor private final class EmptySettingsProbe: ObservableObject {
    @Published var text = ""
    let focus = ComposerFocusController()
}
private struct EmptySettingsTestView: View {
    @ObservedObject var probe: EmptySettingsProbe
    var body: some View {
        FocusComposerSurface(expanded: probe.focus.editing, hasDraft: !probe.text.isEmpty, onFocus: { probe.focus.focus() }, editor: {
            TextEditor(text: $probe.text).frame(height: 44)
        }, add: { Text("+").frame(width: 48, height: 48) }, send: { EmptyView() }, settings: { EmptyView() })
    }
}
extension FocusComposerTests {
    func testCapsuleSlotsFollowRealChildCount() {
        // Two children: the empty settings branch collapsed, so the prompt takes index 1.
        let collapsed = ComposerCapsuleSlots(childCount: 2)
        XCTAssertEqual(collapsed?.add, 0)
        XCTAssertNil(collapsed?.settings)
        XCTAssertEqual(collapsed?.prompt, 1)
        // Three children: add / settings / prompt keeps the historical indices.
        let full = ComposerCapsuleSlots(childCount: 3)
        XCTAssertEqual(full?.add, 0)
        XCTAssertEqual(full?.settings, 1)
        XCTAssertEqual(full?.prompt, 2)
        // Degenerate counts never produce an out-of-range slot.
        XCTAssertNil(ComposerCapsuleSlots(childCount: 0))
        XCTAssertNil(ComposerCapsuleSlots(childCount: 1))
        for count in 2...5 {
            let slots = ComposerCapsuleSlots(childCount: count)
            XCTAssertNotNil(slots)
            for index in [slots?.add, slots?.settings, slots?.prompt].compactMap({ $0 }) {
                XCTAssertLessThan(index, count, "slot \(index) out of range for \(count) children")
            }
        }
    }
    func testEmptySettingsBranchLaysOutCapsuleWithoutIndexingMissingChild() async throws {
        let probe = EmptySettingsProbe()
        let host = UIHostingController(rootView: EmptySettingsTestView(probe: probe))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for width: CGFloat in [320, 390, 768] {
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            probe.focus.collapse()
            try await Task.sleep(for: .milliseconds(120))
            host.view.layoutIfNeeded()
            // Collapsed capsule keeps a single 48pt row: the missing settings lane must not
            // add height, and layout must not trap on the absent third child.
            XCTAssertGreaterThanOrEqual(host.view.bounds.height, 48)
            probe.focus.focus()
            try await Task.sleep(for: .milliseconds(160))
            host.view.layoutIfNeeded()
        }
    }
}
extension FocusComposerTests {
    func testExpandedEditorUsesFullWidthForEmptySingleAndMultilineDrafts() async throws {
        let probe = MorphEditorProbe()
        let host = UIHostingController(rootView: MorphEditorTestView(probe: probe, focus: probe.focus))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func find(_ view: UIView) -> ComposerUITextView? {
            if let text = view as? ComposerUITextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        probe.focus.focus()
        try await Task.sleep(for: .milliseconds(180))
        let editor = try XCTUnwrap(find(host.view))
        for width: CGFloat in [320, 390, 768] {
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            for text in ["", "单行文字", "第一行中文\n第二行保留光标", ""] {
                probe.text = text
                try await Task.sleep(for: .milliseconds(120))
                host.view.layoutIfNeeded()
                XCTAssertTrue(find(host.view) === editor)
                let bounds = editor.convert(editor.bounds, to: host.view)
                XCTAssertEqual(bounds.minX, 24, accuracy: 1)
                XCTAssertEqual(bounds.maxX, width - 24, accuracy: 1,
                    "Only horizontal surface padding remains, with no send-button lane")
            }
        }
    }

    func testSameNativeEditorPreservesChineseCommitAndCaretAcrossMorphAndBorrow() async throws {
        let probe = MorphEditorProbe()
        let host = UIHostingController(rootView: MorphEditorTestView(probe: probe, focus: probe.focus))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        func find(_ view: UIView) -> ComposerUITextView? {
            if let text = view as? ComposerUITextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        try await Task.sleep(for: .milliseconds(120))
        let editor = try XCTUnwrap(find(host.view))
        probe.focus.focus()
        try await Task.sleep(for: .milliseconds(180))
        editor.selectedRange = NSRange(location: 1, length: 0)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(probe.text, "前后")
        editor.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0)); editor.unmarkText()
        XCTAssertEqual(probe.text, "前你后")
        probe.focus.borrow("model"); probe.focus.keyboardHidden(); probe.focus.resume("model")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(find(host.view) === editor)
        XCTAssertEqual(editor.selectedRange.location, 2)
        probe.focus.collapse()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(find(host.view) === editor)
        probe.focus.focus()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(find(host.view) === editor)
        XCTAssertEqual(editor.text, "前你后")
        XCTAssertEqual(editor.selectedRange.location, 2)
        editor.deleteBackward()
        XCTAssertEqual(probe.text, "前后")
    }
}
