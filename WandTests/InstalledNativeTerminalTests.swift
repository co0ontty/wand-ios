import XCTest
import Foundation
import SwiftTerm
@testable import Wand

/// Explicit acceptance input only. Never executes an AI provider or guesses/deletes user sessions.
@MainActor
final class InstalledNativeTerminalTests: XCTestCase {
    func testInstalledServerNativePTYUsesRealReplayInputAndAck() async throws {
        let pointer = URL(fileURLWithPath: "/tmp/wand-ios-continued-acceptance-profile-path")
        guard let path = try? String(contentsOf: pointer, encoding: .utf8) else { throw XCTSkip("Requires an explicitly prepared private installed-service profile") }
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
