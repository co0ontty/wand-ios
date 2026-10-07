import XCTest
@testable import Wand

final class HomeParityTests: XCTestCase {
    func testTemporaryExpansionOverridesCollapseAndRunningWithoutChangingDefault() throws {
        let idle = try summary(#"{"id":"idle","status":"idle"}"#)
        let running = try summary(#"{"id":"running","status":"running","inFlight":true}"#)
        for original in [HomeFoldMode.collapse, .running] {
            let expanded = HomePresentation.recentGroupFold(original, temporarilyExpanded: true)
            XCTAssertEqual(expanded, .expand)
            XCTAssertEqual(HomePresentation.sessions([idle, running], fold: expanded).count, 2)
            XCTAssertTrue(HomePresentation.recentGroupExpandsContent(expanded, visibleConversationCount: 2))
            XCTAssertEqual(HomePresentation.recentGroupFold(original, temporarilyExpanded: false), original)
        }
        let group = try XCTUnwrap(HomePresentation.recentGroups([try group([
            #"{"id":"s","employeeId":"real-id","employeeAvatar":"cat:2"}"#
        ])], employees: [], teams: []).first)
        XCTAssertEqual(group.employeeId, "real-id")
        XCTAssertFalse(HomePresentation.recentGroupShowsHeader(group, sectionFold: .expand, visibleConversationCount: 1))
        XCTAssertTrue(HomePresentation.recentGroupShowsHeader(group, sectionFold: .running, visibleConversationCount: 0))
        XCTAssertTrue(HomePresentation.recentGroupShowsHeader(group, sectionFold: .collapse, visibleConversationCount: 1))
    }

    func testCurrentEmptyAvatarMustNotReviveAnOldSnapshot() throws {
        let source = try group([#"{"id":"s","employeeId":"e","employeeAvatar":"cat:7"}"#])
        let employee = try decode(SiliconEmployee.self, #"{"id":"e","name":"员工","avatar":""}"#)
        XCTAssertEqual(HomePresentation.recentGroups([source], employees: [employee], teams: []).first?.avatar, "")
    }

    func testPixelCatMatchesAndroidPaletteAndStableUtf16Seed() {
        XCTAssertEqual(ContactCatAvatar.coatIndex(id: "any", avatar: "cat:9"), 1)
        XCTAssertEqual(ContactCatAvatar.coatIndex(id: "", avatar: ""), 6)
        XCTAssertEqual(ContactCatAvatar.grid(coat: 0)[2][1], 0xF0923A)
        XCTAssertEqual(ContactCatAvatar.grid(coat: 4)[3][3], 0x3F7FD8)
        XCTAssertEqual(ContactCatAvatar.grid(coat: 7)[5][4], 0xF28B9A)
        XCTAssertNil(ContactCatAvatar.grid(coat: 0)[0][0])
        XCTAssertEqual(ContactCatAvatar.rows.count, 10)
        XCTAssertTrue(ContactCatAvatar.rows.allSatisfy { $0.count == 10 })
        XCTAssertEqual(ContactCatAvatar.grid(coat: -1), ContactCatAvatar.grid(coat: 7))
    }

    func testEmployeeIdentityWinsOverTeamStepAndPty() throws {
        let session = try summary(#"{"id":"member","employeeId":"employee","sessionKind":"pty","provider":"pi","teamStep":{"runId":"run","title":"交付"}}"#)
        XCTAssertEqual(HomePresentation.identity(session).0, "employee:employee")
        XCTAssertEqual(HomePresentation.identity(session).1, .employee)
    }

    func testTeamsUseStableTeamIdAndLegacyRunFallback() throws {
        XCTAssertEqual(HomePresentation.identity(try summary(#"{"id":"chat","teamChat":{"runId":"run","teamId":"team"}}"#)).0, "team:team")
        XCTAssertEqual(HomePresentation.identity(try summary(#"{"id":"chat","teamChat":{"runId":"run"}}"#)).0, "team:run")
        XCTAssertEqual(HomePresentation.identity(try summary(#"{"id":"step","teamStep":{"runId":"run"}}"#)).0, "team-run:run")
    }

    func testRecentWindowDoesNotLoseOldOrRunningTerminals() throws {
        let sessions = (0..<12).map { #"{"id":"s\#($0)","employeeId":"e\#($0)","startedAt":"2026-10-04T10:\#(String(format: "%02d", $0)):00Z","sessionKind":"structured"}"# }
            + [#"{"id":"old-pty","sessionKind":"pty","provider":"pi","startedAt":"2020-01-01","ptyBusy":true,"status":"running"}"#]
        let groups = HomePresentation.recentGroups([try group(sessions)], employees: [], teams: [])
        XCTAssertEqual(groups.filter { $0.kind == .employee }.count, 8)
        XCTAssertEqual(groups.first { $0.kind == .pty }?.conversations.map(\.id), ["old-pty"])
        XCTAssertEqual(groups.last?.kind, .blankTerminal)
    }

    func testRecentIdentitySurvivesRenameAndDefinitionDeletion() throws {
        let source = try group([#"{"id":"s","employeeId":"e","employeeName":"旧名","employeeAvatar":"cat:2","startedAt":"2026"}"#])
        let person = try decode(SiliconEmployee.self, #"{"id":"e","name":"新名","avatar":"cat:3"}"#)
        let current = HomePresentation.recentGroups([source], employees: [person], teams: []).first
        let historical = HomePresentation.recentGroups([source], employees: [], teams: []).first
        XCTAssertEqual(current?.id, historical?.id)
        XCTAssertEqual(current?.title, "新名")
        XCTAssertEqual(current?.avatar, "cat:3")
        XCTAssertEqual(historical?.title, "旧名")
    }

    func testCompletionIsKeptInActivityButNotRunningCount() throws {
        let done = try summary(#"{"id":"done","status":"idle","completionRevision":2,"viewedCompletionRevision":1}"#)
        XCTAssertTrue(HomePresentation.isActive(done))
        XCTAssertEqual(HomePresentation.pulse(done), .quiet)
        let groups = [try group([#"{"id":"done","status":"idle","completionRevision":2,"viewedCompletionRevision":1}"#])]
        XCTAssertEqual(HomePresentation.counts(groups).running, 0)
        XCTAssertEqual(HomePresentation.sessions([done], fold: .running).map(\.id), ["done"])
        XCTAssertTrue(HomePresentation.sessions([done], fold: .running, attentionOnly: true).isEmpty)
    }

    func testPermissionAndFailureNeedUserAndArchiveNeverCounts() throws {
        let sessions = [#"{"id":"permission","status":"idle","permissionBlocked":true}"#,
                        #"{"id":"failed","status":"failed"}"#,
                        #"{"id":"archived","status":"running","inFlight":true,"archived":true}"#]
        let counts = HomePresentation.counts([try group(sessions)])
        XCTAssertEqual(counts.needsYou, 2)
        XCTAssertEqual(counts.running, 0)
        XCTAssertFalse(HomePresentation.isActive(try summary(sessions[2])))
    }

    func testPtyIdleShellDoesNotCountAsRunning() throws {
        let session = try summary(#"{"id":"idle","sessionKind":"pty","provider":"pi","status":"running","ptyBusy":false,"providerCliActive":false}"#)
        XCTAssertEqual(HomePresentation.pulse(session), .quiet)
    }

    func testSearchRetainsTaskAndWorkspaceContext() throws {
        let source = try decode(TaskDirectoryGroup.self, #"{"workspaceId":"w","workspaceName":"Wand","workspaceCwd":"/work","tasks":[{"id":"task","workspaceId":"w","name":"修复上传","status":"active","createdAt":"","cwd":"/work","sessions":[{"id":"s1","employeeName":"虎妞","title":"保留草稿"},{"id":"s2","title":"别的"}]}],"standaloneSessions":[]}"#)
        let matched = HomePresentation.visibleGroups([source], query: "虎妞", attentionOnly: false)
        XCTAssertEqual(matched.first?.tasks.first?.sessions.map(\.id), ["s1"])
        XCTAssertEqual(matched.first?.tasks.first?.name, "修复上传")
        XCTAssertEqual(HomePresentation.visibleGroups([source], query: "修复上传", attentionOnly: false).first?.tasks.first?.sessions.count, 2)
        XCTAssertTrue(HomePresentation.visibleGroups([source], query: "没有的内容", attentionOnly: false).isEmpty)
    }

    func testRecentArchiveExclusionAndDeterministicEqualTimeOrder() throws {
        let source = try group([#"{"id":"b","startedAt":"2026"}"#, #"{"id":"a","startedAt":"2026"}"#, #"{"id":"hidden","startedAt":"2027","archived":true}"#])
        XCTAssertEqual(HomePresentation.conversations([source, source]).map(\.id), ["a", "b"])
    }

    func testWorkspaceCreationUsesNormalizedInputAndValidation() {
        var draft = WorkspaceCreateDraft()
        XCTAssertEqual(draft.validationError, "请填写工作区名称。")
        draft.name = "  Wand  "
        XCTAssertEqual(draft.validationError, "请选择工作目录。")
        draft.cwd = " /work/// "
        XCTAssertNil(draft.validationError)
        XCTAssertEqual(draft.normalizedName, "Wand")
        XCTAssertEqual(draft.normalizedCwd, "/work")
        draft.name = "Wand\n项目"
        XCTAssertNotNil(draft.validationError)
    }

    private func summary(_ json: String) throws -> WorkspaceSessionSummary { try decode(WorkspaceSessionSummary.self, json) }
    private func group(_ sessions: [String]) throws -> TaskDirectoryGroup {
        try decode(TaskDirectoryGroup.self, "{\"workspaceId\":\"w\",\"workspaceName\":\"Wand\",\"workspaceCwd\":\"/work\",\"tasks\":[],\"standaloneSessions\":[" + sessions.joined(separator: ",") + "]}")
    }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(json.data(using: .utf8)))
    }
}
