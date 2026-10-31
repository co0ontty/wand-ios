#!/usr/bin/env python3
"""Run the production workspace protocol and creation state machine without a simulator.

Named source seams keep SwiftUI/UIKit out of this Foundation harness. The endpoint,
request, response decoder and coordinator code are copied verbatim. UI interaction
and draft adoption still require the normal iOS XCTest target.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent


def source(name):
    return (root / "Wand" / name).read_text()


def seam(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def method(text, name):
    # Top-level members use four-space method declarations in these test files.
    start = text.index("    func " + name + "(")
    if text[:start].endswith("    @MainActor\n"):
        start -= len("    @MainActor\n")
    end = text.index("\n    }", start) + len("\n    }")
    return text[start:end]


with tempfile.TemporaryDirectory(prefix="wand-workspace-creation-", dir=os.environ.get("TMPDIR")) as directory:
    package = Path(directory)
    sources = package / "Sources/Wand"
    tests = package / "Tests/WandTests"
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WandWorkspaceCreationTests", targets: [
    .target(name: "Wand"),
    .testTarget(name: "WandTests", dependencies: ["Wand"]),
])
''')
    for filename in ["WorkspaceAPI.swift", "WorkspaceModels.swift", "WorkspaceWorktreeModels.swift",
                     "WandModels.swift", "WandEndpoint.swift", "SelfSignedSession.swift", "ClientFeedback.swift",
                     "NewConversation.swift", "SessionInputProtocol.swift", "PtyInputProtocol.swift"]:
        (sources / filename).write_text(source(filename))
    api = source("WandAPI.swift")
    api_core = seam(api, "    enum APIError:", "    // MARK: - 会话")
    api_config = method(api, "serverConfig")
    (sources / "WandAPI.swift").write_text('''import Foundation
final class WandAPI {
    let baseURL: URL
    let token: String?
    let endpointSession: SelfSignedSession
    let taskChanges = HarnessTaskChanges()
    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL; self.token = token
        endpointSession = SelfSignedSession.forEndpoint(baseURL)
    }
''' + api_core + api_config + "\n" + method(api, "createSession") + "\n}\n")
    auth = source("WandAuth.swift")
    auth_parts = seam(auth, "    static let sessionCookieNames:", "    final class ConnectionAttempt")
    # ConnectionAttempt is UI lifecycle support; login itself is Foundation-only.
    auth_login = seam(auth, "    @discardableResult\n    static func loginWithToken", "\n    ///")
    (sources / "WandAuth.swift").write_text("import Foundation\nenum WandAuth {\n" + auth_parts + auth_login + "\n}\n")
    dependencies = "import Foundation\n"
    dependencies += seam(source("SessionCapabilities.swift"), "enum WandAgentTool:", "\nfunc canChangeBlankSessionDirectory")
    dependencies += "\n" + seam(source("NativeTerminal.swift"), "struct PtyTerminalSnapshot:", "\nenum PtyTerminalInput")
    dependencies += '''
struct HarnessTaskChanges { func send() {} }
func wlog(_ category: String, _ text: String) {}
enum ServerProfiles {
    static func canonicalBaseURL(_ value: String) throws -> URL { URL(string: value)! }
}
extension WandAPI {
    func reportHTTPFailure(status: Int, data: Data, path: String) {}
}
// Draft owner is outside this harness. No tested path is allowed to call it.
@MainActor final class ComposerDraftState {
    func adoptInitialDraft(text: String, expectedSourceRevision: Int, expectedText: String,
                           attachments: [UploadedFile]) -> Bool {
        preconditionFailure("Draft adoption requires the iOS XCTest target")
    }
}
'''
    (sources / "Dependencies.swift").write_text(dependencies)
    workspace_tests = (root / "WandTests/WorkspaceTests.swift").read_text()
    tests_source = "import Foundation\nimport XCTest\n@testable import Wand\n\n@MainActor final class WorkspaceCreationProtocolTests: XCTestCase {\n"
    tests_source += seam(workspace_tests, "    private var archiveTaskGroupsJSON:", "\n    func testTaskGroupsAPIIncludesArchived")
    for name in ["testTaskGroupsAPIIncludesArchivedOnInitialAndRevisionRequestsWithoutChangingLegacyPickerScope",
                 "testTaskGroupsPageDecodesArrayAndRevisionEnvelope",
                 "testNewWorkspaceTaskCreatesOneSessionWithCanonicalBinding"]:
        tests_source += "\n" + method(workspace_tests, name)
    tests_source += "\n}\n" + workspace_tests[workspace_tests.index("private final class WorkspaceTaskGroupsURLProtocol:"):]
    new_tests = (root / "WandTests/NewConversationTests.swift").read_text()
    tests_source += "\nfinal class CreationStateTests: XCTestCase {\n"
    for name in ["testUnknownCreateCannotBeRetried", "testUnknownCreateRemainsLockedAcrossCoordinatorRecreationAndManualCheck",
                 "testDefiniteRejectionClearsPersistedInflightMarker", "testUnknownSessionWithTaskIDCannotBeRetried",
                 "testUnknownSessionWithTaskIDCannotBeAcknowledgedIntoRetry",
                 "testChoosingExistingTaskRecoversUnknownTaskWithoutRepeatingCreation",
                 "testTaskSelectionCannotUnlockUnknownSessionCreation",
                 "testAbandonAcceptedSessionKeepsSessionAccepted", "testTaskCreationPersistsUnknownBeforeOperationAndBlocksAfterRecreation",
                 "testSessionCreationPersistsUnknownBeforeOperationAndBlocksAfterRecreation"]:
        tests_source += "\n" + method(new_tests, name)
    tests_source += "\n" + seam(new_tests, "    @MainActor\n    private func makeCoordinator", "\n}\n") + "\n}\n"
    tests_source += '''
final class InstalledWorkspaceSnapshotTests: XCTestCase {
    func testInstalledSnapshotFirstReadAndRevalidation() async throws {
        guard ProcessInfo.processInfo.environment["WAND_VERIFY_INSTALLED_SNAPSHOT"] == "1" else {
            throw XCTSkip("Read-only installed-service acceptance is opt-in")
        }
        struct Connection: Decodable { let serverURL: String; let connectionCode: String }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wand/acceptance-connection.json")
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: path))
        var encoded = connection.connectionCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        let text = try XCTUnwrap(String(data: decoded, encoding: .utf8))
        let token = try XCTUnwrap(text.split(separator: "#").last).description
        let api = WandAPI(baseURL: try XCTUnwrap(URL(string: connection.serverURL)), token: token)
        defer { SelfSignedSession.resetEndpoint(api.baseURL) }
        let initial = try await api.listTaskGroupsPage(revision: nil)
        XCTAssertFalse(initial.unchanged)
        let revision = try XCTUnwrap(initial.revision)
        XCTAssertFalse(revision.isEmpty)
        let next = try await api.listTaskGroupsPage(revision: revision)
        XCTAssertNotNil(next.revision)
        if next.unchanged { XCTAssertEqual(next.revision, revision); XCTAssertTrue(next.groups.isEmpty) }
        else { XCTAssertNotEqual(next.revision, revision) }
    }
}
'''
    (tests / "WorkspaceCreationTests.swift").write_text(tests_source)
    subprocess.run(["swift", "test", "--package-path", str(package), "--jobs", "2"], check=True, timeout=180)
