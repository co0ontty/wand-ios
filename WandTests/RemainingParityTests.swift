import XCTest
import SwiftUI
import SwiftTerm
import UIKit
@testable import Wand

@MainActor
private final class TerminalSocketStub: PtySocketTransport {
    var onEvent: ((WsIncoming) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onResync: (() -> Void)?
    var onError: ((String) -> Void)?
    var inputs: [(String, Bool, String?)] = []
    var sizes: [(Int, Int)] = []
    var acks: [Int] = []
    var supportsAck = false
    var connected = false
    func connect() { connected = true }
    func close() { connected = false }
    func subscribe(sessionId: String, ptyAck: Bool) { supportsAck = ptyAck }
    func requestResync() { onResync?() }
    func sendPtyInput(_ text: String, userInput: Bool, shortcutKey: String?) -> Bool { inputs.append((text, userInput, shortcutKey)); return connected }
    func resizePty(cols: Int, rows: Int) { sizes.append((cols, rows)) }
    func acknowledgePty(bytes: Int) { acks.append(bytes) }
    func reconnectForForeground() { onResync?() }
}

@MainActor
final class RemainingParityTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(type, from: Data(json.utf8)) }
    private func event(_ type: String, data: [String: Any] = [:], seq: Int = 1, bytes: Int = 0) throws -> WsIncoming {
        try JSONDecoder().decode(WsIncoming.self, from: JSONSerialization.data(withJSONObject: ["type": type, "sessionId": "pty-test", "seq": seq, "ptyBytes": bytes, "data": data]))
    }
    private func visible(_ view: NativeTerminalView) -> String {
        (0..<view.getTerminal().rows).compactMap { view.getTerminal().getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) }.joined(separator: "\n")
    }
    func testResourceNoticeIsReadOnlyBoundedAndMalformedNoticeDoesNotDropTheTurn() throws {
        let turn = try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"text","text":"answer"}],"resourceSelection":{"label":"  本轮选用 Skills A、MCP B  ","status":"selected"}}"#)
        XCTAssertEqual(turn.resourceSelection?.label, "本轮选用 Skills A、MCP B")
        XCTAssertEqual(turn.resourceSelection?.status, "selected")
        XCTAssertEqual(ResourceSelectionNotice(label: String(repeating: "x", count: 9000), status: nil).label.count, 1024)
        let malformed = try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"text","text":"answer"}],"resourceSelection":{"label":" "}}"#)
        XCTAssertNil(malformed.resourceSelection); XCTAssertEqual(malformed.content.count, 1)
    }
    func testSettledResourceNoticeDoesNotRegressOrLeakIntoAnotherRound() {
        let settled = ConversationTurn(role: "assistant", content: [], createdAt: "round-1", resourceSelection: ResourceSelectionNotice(label: "已选用 A", status: "selected"))
        let selecting = ConversationTurn(role: "assistant", content: [], createdAt: "round-1", resourceSelection: ResourceSelectionNotice(label: "正在选择", status: "selecting"))
        XCTAssertEqual(mergeConversationTurnTimes(previous: settled, incoming: selecting).resourceSelection?.label, "已选用 A")
        XCTAssertEqual(mergeConversationTurnTimes(previous: settled, incoming: ConversationTurn(role: "assistant", content: [], createdAt: "round-1")).resourceSelection?.label, "已选用 A")
        XCTAssertNil(mergeConversationTurnTimes(previous: settled, incoming: ConversationTurn(role: "assistant", content: [], createdAt: "round-2")).resourceSelection)
        XCTAssertNil(mergeConversationTurnTimes(previous: settled, incoming: ConversationTurn(role: "user", content: [])).resourceSelection)
    }
    func testCompactMergeAndToolPairProjectionPreserveResourceNotice() throws {
        let local = try decode(ConversationTurn.self, #"{"role":"assistant","createdAt":"r1","content":[{"type":"thinking","thinking":"long thinking body"}],"resourceSelection":{"label":"选择 A","status":"selected"}}"#)
        let compact = try decode(ConversationTurn.self, #"{"role":"assistant","createdAt":"r1","content":[{"type":"thinking","thinking":"x"}]}"#)
        let merged = applyingIncrementalMessage(compact, expectedCount: 1, to: SessionMessageWindow(messages: [local], loadedOffset: 0, messageTotal: 1, leadingBlockOffset: 0, leadingBlockTotal: 1))
        XCTAssertEqual(merged.messages[0].resourceSelection, local.resourceSelection)
        XCTAssertEqual(toolPairedDisplayTurns(merged.messages)[0].resourceSelection, local.resourceSelection)
        XCTAssertEqual(stampLiveTurnTime(local).resourceSelection, local.resourceSelection)
    }
    func testNativeCheckpointReplaysPendingGeometryAndSuppressesHistoricalReplies() throws {
        let view = NativeTerminalView(); var sent: [String] = []; view.onInput = { text, _, _ in sent.append(text) }
        let data = try XCTUnwrap(event("init", data: ["output": "DO NOT REPLAY", "terminalState": ["version": 1, "cols": 8, "rows": 4, "data": "\u{1b}[?1049h\u{1b}[?2004h\u{1b}[H1234567\u{1b}[6n", "pending": [["type": "resize", "cols": 12, "rows": 4], ["type": "data", "data": "XY"]]]]).data)
        XCTAssertTrue(view.restore(data)); XCTAssertTrue(visible(view).hasPrefix("1234567XY"))
        XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate); XCTAssertTrue(view.getTerminal().bracketedPasteMode)
        XCTAssertFalse(visible(view).contains("DO NOT")); XCTAssertTrue(sent.isEmpty)
    }
    func testNativeUnknownSnapshotIsRejectedWithoutOverwritingPaintedScreen() throws {
        let view = NativeTerminalView(); view.feedOutput("KEEP")
        let data = try XCTUnwrap(event("init", data: ["output": "NOT A FALLBACK", "terminalState": ["version": 2, "cols": 80, "rows": 24, "data": "BAD", "pending": []]]).data)
        XCTAssertFalse(view.restore(data)); XCTAssertTrue(visible(view).contains("KEEP")); XCTAssertFalse(visible(view).contains("BAD"))
        XCTAssertTrue(view.restore(try XCTUnwrap(event("init", data: ["output": "LEGACY"]).data)))
        XCTAssertTrue(visible(view).hasPrefix("LEGACY")); XCTAssertFalse(visible(view).contains("KEEP"))
    }
    func testMalformedCheckpointPendingOperationIsNotSilentlyLegacy() throws {
        let data = try XCTUnwrap(event("init", data: ["output": "unsafe fallback", "terminalState": ["version": 1, "cols": 80, "rows": 24, "data": "screen", "pending": [["type": "resize", "cols": 0, "rows": 2]]]]).data)
        XCTAssertNotNil(data.terminalState); XCTAssertFalse(data.terminalState?.isReplayable ?? true)
        XCTAssertFalse(NativeTerminalView().restore(data))
    }
    func testNativePasteIsSingleBoundedEventAndDoesNotAppendReturn() {
        let view = NativeTerminalView(); view.provider = "codex"; var input: [(String, Bool, String?)] = []
        view.onInput = { input.append(($0, $1, $2)) }; view.pasteText("first\nsecond\u{1b}")
        XCTAssertEqual(input.count, 1); XCTAssertEqual(input[0].2, "paste"); XCTAssertTrue(input[0].1)
        XCTAssertEqual(input[0].0, "\u{1b}[200~first\rsecond\u{241b}\u{1b}[201~")
        let chunks = PtyTerminalInput.chunks(String(repeating: "中文🙂", count: 8000))
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 16384 }); XCTAssertEqual(chunks.joined(), String(repeating: "中文🙂", count: 8000))
    }
    func testNativeIMEPreeditIsNotSentAndCommittedTextIsSeparateFromReturn() {
        let view = NativeTerminalView(); var input: [String] = []; view.onInput = { text, _, _ in input.append(text) }
        view.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0)); XCTAssertTrue(input.isEmpty)
        view.insertText("中文"); view.insertText("\n")
        XCTAssertEqual(input, ["中文", "\r"])
    }
    func testProgrammaticNativeBlurDoesNotCommitPreeditRemotely() {
        let view = NativeTerminalView(); var input: [String] = []; view.onInput = { text, _, _ in input.append(text) }
        view.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0)); view.blurTerminal()
        XCTAssertTrue(input.isEmpty); XCTAssertNil(view.markedTextRange)
    }
    func testRemoteClipboardCannotReadOrWriteAndLiveDeviceReplyIsNotUserInput() {
        let view = NativeTerminalView(); var input: [(String, Bool)] = []; view.onInput = { text, user, _ in input.append((text, user)) }
        UIPasteboard.general.string = "PRIVATE CLIPBOARD"
        view.feedOutput("\u{1b}]52;c;cmVtb3Rl\u{7}\u{1b}[6n")
        XCTAssertEqual(UIPasteboard.general.string, "PRIVATE CLIPBOARD"); XCTAssertNil(view.clipboardRead(source: view))
        XCTAssertTrue(input.contains { !$0.1 && $0.0.hasPrefix("\u{1b}[") })
        UIPasteboard.general.string = nil
    }
    func testNativeStreamingDoesNotPullReaderOrCancelManualSelection() {
        let view = NativeTerminalView(); view.feedOutput((0..<100).map { "line-\($0)\r\n" }.joined()); view.scroll(toPosition: 0)
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        let text = view.selection.getSelectedText(); view.feedOutput("NEW\r\n")
        XCTAssertEqual(view.scrollPosition, 0); XCTAssertTrue(view.selection.active); XCTAssertEqual(view.selection.getSelectedText(), text)
        view.scroll(toPosition: 1); view.feedOutput("LATEST\r\n"); XCTAssertEqual(view.scrollPosition, 1)
    }
    func testNativeGeometryAndScaleMatchAndroidQuarterStepRange() throws {
        let view = NativeTerminalView(); view.frame = CGRect(x: 0, y: 0, width: 390, height: 600); view.layoutIfNeeded()
        XCTAssertTrue(view.restore(try XCTUnwrap(event("init", data: ["terminalState": ["version": 1, "cols": 80, "rows": 24, "data": "\u{1b}[?1049h\u{1b}[?2004h", "pending": []]]).data)))
        view.setScale(1.5); XCTAssertTrue(view.getTerminal().bracketedPasteMode); XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate)
        XCTAssertEqual(normalizedTerminalScale(3), 2); XCTAssertEqual(normalizedTerminalScale(-1), 0.5); XCTAssertEqual(normalizedTerminalScale(.nan), 1)
        XCTAssertEqual(normalizedTerminalScale(1.14), 1.25)
    }
    func testNativeStoreAcksOnlyAfterConsumeAndDoesNotResendInputAfterResync() throws {
        let socket = TerminalSocketStub(); let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let store = PtyTerminalStore(sessionId: "pty-test", api: api, socket: socket, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.start(); XCTAssertTrue(socket.supportsAck)
        socket.onEvent?(try event("init", data: ["output": "ready"])); XCTAssertTrue(store.ready)
        socket.onEvent?(try event("output", data: ["chunk": "XYZ"], seq: 2, bytes: 3)); XCTAssertEqual(socket.acks, [3]); XCTAssertTrue(visible(store.terminal).contains("XYZ"))
        XCTAssertTrue(store.send("text")); socket.onResync?(); XCTAssertFalse(store.ready)
        XCTAssertFalse(store.send("do not send")); XCTAssertEqual(socket.inputs.count, 1)
        store.shutdown(); store.start(); XCTAssertEqual(socket.inputs.count, 1)
    }
    func testSocketRejectsDuplicateGapAndForeignFramesWithoutNetworking() throws {
        let socket = WandSocket(baseURL: URL(string: "http://127.0.0.1:9")!); socket.subscribe(sessionId: "pty-test", ptyAck: true)
        var seqs: [Int] = []; var resyncs = 0; socket.onEvent = { seqs.append($0.seq ?? 0) }; socket.onResync = { resyncs += 1 }
        func send(_ seq: Int, type: String = "output", id: String = "pty-test") throws {
            let data = try JSONSerialization.data(withJSONObject: ["type": type, "sessionId": id, "seq": seq, "data": ["chunk": "x"]]); socket.handle(data)
        }
        try send(1, type: "init"); try send(2); try send(2); try send(3, id: "foreign"); try send(4); try send(5)
        XCTAssertEqual(seqs, [1, 2]); XCTAssertEqual(resyncs, 1)
        let payload = try XCTUnwrap(socket.subscriptionPayload()); XCTAssertEqual((payload["capabilities"] as? [String: Bool])?["ptyAck"], true)
    }
}
