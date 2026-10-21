import XCTest
import Foundation
import SwiftTerm
@testable import Wand

/// Explicit acceptance input only. Never executes an AI provider or guesses/deletes user sessions.
@MainActor
final class InstalledNativeTerminalTests: XCTestCase {
    func testNativeRefitKeepsTerminalModesAndViewGeometryInSync() {
        let view = NativeTerminalView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        view.layoutIfNeeded()
        view.feedOutput("\u{1b}[?1049h\u{1b}[?2004h")
        XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate)
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)

        view.frame = CGRect(x: 0, y: 0, width: 260, height: 400)
        view.refit()

        XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate)
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)
        XCTAssertEqual(view.contentSize.width, view.getOptimalFrameSize().width, accuracy: 0.5)
        XCTAssertEqual(view.contentSize.height, view.getOptimalFrameSize().height, accuracy: 0.5)
    }

    func testNativeStreamingKeepsFollowingAndPreservesManualHistory() async throws {
        let view = NativeTerminalView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        view.layoutIfNeeded(); view.refit()
        view.feedOutput((0..<100).map { "line \($0)\r\n" }.joined())
        try await Task.sleep(nanoseconds: 50_000_000)
        let terminal = view.getTerminal()
        XCTAssertGreaterThan(terminal.buffer.yDisp, 0)
        XCTAssertEqual(view.scrollPosition, 1)
        view.scrollTo(row: 5, notifyAccessibility: false)
        view.feedOutput((100..<120).map { "line \($0)\r\n" }.joined())
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(terminal.buffer.yDisp, 5, "live output must not steal the history viewport")
        view.scrollTo(row: Int.max, notifyAccessibility: false)
        view.feedOutput("tail\r\n")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(view.scrollPosition, 1)
    }

    func testInstalledServerNativePTYUsesRealReplayInputAndAck() async throws {
        let pointer = URL(fileURLWithPath: "/tmp/wand-ios-continued-acceptance-profile-path")
        guard let path = ProcessInfo.processInfo.environment["WAND_PTY_ACCEPTANCE_PROFILE"]
            ?? (try? String(contentsOf: pointer, encoding: .utf8)) else { throw XCTSkip("Requires an explicitly prepared private installed-service profile") }
        struct Profile: Decodable { let baseUrl: String; let token: String; let cwd: String }
        let data = try Data(contentsOf: URL(fileURLWithPath: path)); XCTAssertLessThan(data.count, 16384)
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        let api = WandAPI(baseURL: try XCTUnwrap(URL(string: profile.baseUrl)), token: profile.token)
        let session = try await api.createSession(kind: "pty", cwd: profile.cwd, shell: true)
        XCTAssertFalse(session.id.isEmpty); XCTAssertFalse(session.isStructured)
        let store = PtyTerminalStore(sessionId: session.id, api: api, defaults: UserDefaults(suiteName: "NativePTYAcceptance." + UUID().uuidString)!)
        store.start()
        do {
            try await wait { store.ready }
            let firstSize = (store.terminal.getTerminal().cols, store.terminal.getTerminal().rows)
            XCTAssertTrue(PtyTerminalSnapshot.validSize(cols: firstSize.0, rows: firstSize.1))
            // This is a local shell fixture, not model inference. Text and Return remain separate frames.
            XCTAssertTrue(store.send("printf '\\137WAND_IOS_NATIVE_PTY_OK\\137\\137\\n'", shortcutKey: "enter_text"))
            XCTAssertTrue(store.send("\r", shortcutKey: "enter_text"))
            try await wait { self.screen(store.terminal).contains("_WAND_IOS_NATIVE_PTY_OK__") }
            store.refresh(); try await wait { store.ready && self.screen(store.terminal).contains("_WAND_IOS_NATIVE_PTY_OK__") }
            store.terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600); store.terminal.layoutIfNeeded(); store.terminal.refit()
            store.adjustScale(0.25); XCTAssertEqual(store.scale, 1.25)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertTrue(store.ready)
            store.shutdown()
            try await api.deleteSession(id: session.id) // Exact ID created above, never pre-existing history.
        } catch {
            store.shutdown()
            try? await api.deleteSession(id: session.id)
            throw error
        }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("Native PTY acceptance did not settle within the bounded window")
        throw WandAPI.APIError.network("Native acceptance timed out")
    }
    private func screen(_ view: NativeTerminalView) -> String {
        (0..<view.getTerminal().rows).compactMap { view.getTerminal().getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) }.joined(separator: "\n")
    }
}
