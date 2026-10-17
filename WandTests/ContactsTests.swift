import Foundation
import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Wand

@MainActor
final class ContactsTests: XCTestCase {
    func testPlushIdentityMatchesWebAndPreservesExplicitLegacyAvatars() {
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "e1", name: "测试", avatar: ""), "plush_round_lavender_ink_beret")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "😀员工", name: "测试", avatar: ""), "plush_round_blue_none_beret")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "  stable-id  ", name: "测试", avatar: ""), "plush_square_blue_ink_none")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "", name: "测试", avatar: ""), "plush_capsule_cream_ink_none")
        XCTAssertNil(PlushAvatarIdentity.asset(id: "e1", avatar: "cat:7"))
        XCTAssertNil(PlushAvatarIdentity.asset(id: "e1", avatar: "data:image/png;base64,eA=="))
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "e1", avatar: "plush-cat:v1:silver"), "plush_cat_silver")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "e1", avatar: "plush-cat:v1:orange"), "plush_cat_orange")
        for invalid in ["plush:v2:round:blue:none:none", "plush:v1:wrong:blue:none:none", "plush-cat:v1:unknown"] {
            XCTAssertEqual(PlushAvatarIdentity.asset(id: "e1", avatar: invalid), PlushAvatarIdentity.asset(id: "e1", avatar: ""))
        }
    }
    func testAllPlushPortraitsAreBundledForOfflineDisplay() {
        for shape in PlushAvatarIdentity.shapes { for color in PlushAvatarIdentity.colors {
            for glasses in PlushAvatarIdentity.glasses { for hat in PlushAvatarIdentity.hats {
                let key = "plush_\(shape)_\(color)_\(glasses)_\(hat)"
                XCTAssertEqual(PlushAvatarIdentity.asset(id: "", avatar: "plush:v1:\(shape):\(color):\(glasses):\(hat)"), key)
                XCTAssertNotNil(UIImage(named: key), key)
            } }
        } }
        XCTAssertNotNil(UIImage(named: "plush_cat_silver"))
        XCTAssertNotNil(UIImage(named: "plush_cat_orange"))
    }
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    private func employee(id: String = "e1", name: String = "Équipe", system: String? = nil, archived: Bool = false, createdAt: String = "") throws -> SiliconEmployee {
        let object: [String: Any] = ["id": id, "name": name, "duty": "验证 软件", "prompt": "private role",
                                    "agents": [["provider": "pi", "model": "default"]], "tags": ["开发"], "createdAt": createdAt,
                                    "systemKey": system as Any? ?? NSNull(), "archivedAt": archived ? "2026-10-01" : NSNull()]
        return try JSONDecoder().decode(SiliconEmployee.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func workspace(_ id: String = "w1", cwd: String = "/repo", last: String = "2026-10-01") -> Workspace {
        Workspace(id: id, name: id, cwd: cwd, defaultProvider: nil, layout: nil, createdAt: "2026-01-01", lastOpenedAt: last)
    }
    func testReservedTagsProjectFromStableSystemIdentity() throws {
        XCTAssertEqual(try employee(system: "wand-ops").displayTags, ["系统用户"])
        XCTAssertEqual(try employee(system: "wand-default").displayTags, ["默认用户"])
        XCTAssertEqual(try employee().displayTags, ["开发"])
        XCTAssertTrue(try employee(system: "wand-ops").builtin)
        XCTAssertFalse(try employee().builtin)
    }
    func testBuiltinEmployeeMutationContainsOnlyCandidates() throws {
        var draft = EmployeeDraft(try employee(system: "wand-default"))
        draft.name = "not a permitted rename"; draft.prompt = "never submit a locked field"
        let body = draft.body(builtin: true)
        XCTAssertEqual(Set(body.keys), ["agents"])
        XCTAssertNil(draft.validationError(builtin: true))
        let agents = try XCTUnwrap(body["agents"] as? [[String: Any]])
        XCTAssertEqual(agents[0]["kind"] as? String, "structured")
    }
    func testEmployeeTagNormalizationAndValidationMatchAndroid() throws {
        var draft = EmployeeDraft(try employee())
        draft.tagInput = " 开发，开发、 测试\n分析 "
        XCTAssertEqual(draft.tags, ["开发", "测试", "分析"])
        XCTAssertNil(draft.validationError(builtin: false))
        draft.tagInput = "系统用户"
        XCTAssertNotNil(draft.validationError(builtin: false))
        draft.tagInput = String(repeating: "😀", count: 11)
        XCTAssertNotNil(draft.validationError(builtin: false), "20 UTF-16 units, not 20 graphemes")
        draft.tagInput = "bad\tlabel"
        XCTAssertNotNil(draft.validationError(builtin: false))
    }
    func testCandidateSafetyRejectsPtyUnknownProvidersAndDuplicates() {
        var candidate = ContactCandidate()
        XCTAssertNil(contactCandidateError([candidate]))
        candidate.kind = "pty"; XCTAssertNotNil(contactCandidateError([candidate]))
        candidate.kind = "structured"; candidate.provider = "future"; XCTAssertNotNil(contactCandidateError([candidate]))
        candidate.provider = "pi"; XCTAssertNotNil(contactCandidateError([candidate, candidate]))
        XCTAssertNotNil(contactCandidateError([]))
    }
    func testContactSearchIsUnicodeMultiTermAndDoesNotReadPersona() async throws {
        let service = ContactDirectoryStub()
        service.people = [try employee(), try employee(id: "old", name: "Archived", archived: true)]
        let store = ContactsStore(service: service)
        store.activate()
        await store.refresh()
        XCTAssertEqual(store.employees(matching: "éQUIPE 软件").map(\.id), ["e1"])
        XCTAssertTrue(store.employees(matching: "private role").isEmpty)
        XCTAssertTrue(store.employees(matching: "Archived").isEmpty)
    }
    func testEmployeeConversationUsesDefaultDirectoryWithoutOldTaskOrCli() {
        let workspaces = [workspace("wand-global", cwd: "/scratch"), workspace("w1", cwd: "/repo/")]
        let binding = contactConversationBinding(defaultCwd: "/repo", workspaces: workspaces)
        XCTAssertEqual(binding?.workspaceId, "w1")
        let body = employeeConversationBody(employeeId: "e1", binding: binding!)
        XCTAssertEqual(Set(body.keys), ["employeeId", "cwd", "workspaceId"])
        XCTAssertNil(body["workspaceTaskId"]); XCTAssertNil(body["provider"]); XCTAssertNil(body["prompt"])
        XCTAssertNil(contactConversationBinding(defaultCwd: nil, workspaces: [workspace("wand-global")]))
        XCTAssertEqual(contactConversationBinding(defaultCwd: nil, workspaces: [workspace(last: "2026-09-01"), workspace("new", cwd: "/new", last: "2026-10-01")])?.cwd, "/new")
    }
    func testTeamDecodeSupportsSingleAgentAndPreservesExplicitEmployeeUnbinding() throws {
        let member = try decode(ContactTeamMember.self, #"{"id":"m1","name":"A","duty":"work","isLeader":true,"avatar":"cat:3","role":"verify","agent":{"provider":"pi"},"employeeId":"e1"}"#)
        XCTAssertEqual(member.agents.count, 1)
        var unbound = member; unbound.employeeId = nil
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unbound)) as! [String: Any]
        XCTAssertTrue(encoded["employeeId"] is NSNull)
        XCTAssertEqual(encoded["role"] as? String, "verify")
        XCTAssertEqual(encoded["avatar"] as? String, "cat:3")
        XCTAssertNil(encoded["agent"])
    }
    func testTeamDraftRequiresUniqueLeaderAndRetainsMemberIds() throws {
        var draft = ContactTeamDraft()
        draft.name = "QA"
        draft.members = [ContactTeamMember(employee: try employee(), leader: true),
                         ContactTeamMember(employee: try employee(id: "e2", name: "Reviewer"), leader: false)]
        XCTAssertNil(draft.validationError)
        let ids = draft.members.map(\.id)
        draft.description = "renamed description"
        let members = try XCTUnwrap(try draft.body()["members"] as? [[String: Any]])
        XCTAssertEqual(members.compactMap { $0["id"] as? String }, ids)
        draft.members[1].isLeader = true; XCTAssertNotNil(draft.validationError)
        draft.members[1].isLeader = false; draft.maxSteps = 201; XCTAssertNotNil(draft.validationError)
    }
    func testContactNavigationRetainsDirectoryAndRunWhenOpeningMembers() {
        XCTAssertEqual(contactNavigationPath(parents: [], selection: "session"), ["session"])
        XCTAssertEqual(contactNavigationPath(parents: ["wand:contacts"], selection: nil), ["wand:contacts"])
        XCTAssertEqual(contactNavigationPath(parents: ["wand:contacts", "wand:team-run:r"], selection: "member"),
                       ["wand:contacts", "wand:team-run:r", "member"])
    }
    func testTeamRelayUsesStableAuthorAndFrozenReportPreview() throws {
        let turn = try decode(ContactChatTurn.self, #"{"role":"assistant","content":[],"author":{"id":"m1","name":"historic"},"reportFile":{"stepId":"s","path":"report.md","name":"report.md","size":7,"preview":{"title":"Result","excerpt":"Done"}}}"#)
        XCTAssertEqual(turn.author?.id, "m1")
        XCTAssertEqual(turn.reportFile?.preview?.excerpt, "Done")
        XCTAssertEqual(turn.text, "")
    }
    func testDirectoryPartialFailureKeepsPriorContent() async throws {
        let service = ContactDirectoryStub()
        service.people = [try employee()]; service.projects = [workspace()]
        let store = ContactsStore(service: service); store.activate(); await store.refresh()
        service.failure = WandAPI.APIError.network("offline")
        await store.refresh()
        XCTAssertEqual(store.employees.map(\.id), ["e1"])
        XCTAssertEqual(store.workspaces.map(\.id), ["w1"])
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.loading)
    }
    func testLateDirectoryLoadCannotReplaceNewerRefresh() async throws {
        let service = ContactDirectoryStub()
        service.people = [try employee(id: "new")]; service.delayFirstPeople = true
        let store = ContactsStore(service: service); store.activate()
        let began = expectation(description: "first request began")
        service.peopleBegan = { began.fulfill() }
        let old = Task { await store.refresh() }
        await fulfillment(of: [began], timeout: 2)
        await store.refresh()
        service.peopleGate?.resume(returning: [try employee(id: "old")])
        await old.value
        XCTAssertEqual(store.employees.map(\.id), ["new"])
    }
    func testClosingDirectoryInvalidatesPendingLoadAndDoesNotFetchHidden() async throws {
        let service = ContactDirectoryStub(); service.delayFirstPeople = true
        let store = ContactsStore(service: service); store.activate()
        let began = expectation(description: "first request began"); service.peopleBegan = { began.fulfill() }
        let old = Task { await store.refresh() }
        await fulfillment(of: [began], timeout: 2)
        store.close(); store.refreshIfVisible()
        service.peopleGate?.resume(returning: [try employee()]); await old.value
        XCTAssertTrue(store.employees.isEmpty); XCTAssertEqual(service.peopleRequests, 1)
    }
    func testUnknownEmployeeCreationCannotBlindlyRepeatAfterRefresh() async throws {
        let service = ContactDirectoryStub(); service.people = [try employee()]; service.projects = [workspace()]
        service.creationFailure = WandAPI.APIError.server(status: 409, message: "unknown")
        let store = ContactsStore(service: service); store.activate(); await store.refresh()
        let done = expectation(description: "creation resolved")
        let subscription = store.$busyContact.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        store.openEmployee("e1") { _ in XCTFail("Unknown delivery is not a created conversation") }
        store.openEmployee("e1") { _ in XCTFail("Concurrent create") }
        await fulfillment(of: [done], timeout: 2)
        withExtendedLifetime(subscription) {}
        await store.refresh()
        store.openEmployee("e1") { _ in XCTFail("Blind retry") }
        XCTAssertEqual(service.creations, 1)
        XCTAssertTrue(store.unconfirmedActions.contains("employee:e1"))
    }
    func testDefiniteEmployeeCreationRejectionAllowsExplicitNewAttempt() async throws {
        let service = ContactDirectoryStub(); service.people = [try employee()]; service.projects = [workspace()]
        service.creationFailure = WandAPI.APIError.server(status: 400, message: "rejected")
        let store = ContactsStore(service: service); store.activate(); await store.refresh()
        let done = expectation(description: "rejected")
        let subscription = store.$busyContact.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        store.openEmployee("e1") { _ in XCTFail() }
        await fulfillment(of: [done], timeout: 2); withExtendedLifetime(subscription) {}
        XCTAssertFalse(store.unconfirmedActions.contains("employee:e1")); XCTAssertEqual(service.creations, 1)
    }
    func testLateEmployeeSaveKeepsNewInputAndUsesCapturedDraft() async throws {
        let current = try employee()
        let service = EmployeeEditingStub(employee: current)
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        let model = EmployeeProfileStore(id: current.id, api: api, service: service)
        await model.load()
        model.draft.duty = "submitted duty"
        let began = expectation(description: "save began")
        service.saveBegan = { began.fulfill() }
        let done = expectation(description: "save completed")
        model.save(onBusy: { if !$0 { done.fulfill() } }, onSaved: { _ in }, onUnconfirmed: { XCTFail() })
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(service.submitted?.duty, "submitted duty")
        model.draft.duty = "typed during save"
        var saved = current; saved.duty = "submitted duty"
        service.saveGate?.resume(returning: saved)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(model.draft.duty, "typed during save")
        XCTAssertEqual(model.employee?.duty, "submitted duty")
        XCTAssertEqual(model.phase, .sent)
        XCTAssertTrue(model.message?.contains("新输入") == true)
    }
    private func team(id: String = "t1", createdAt: String = "") throws -> ContactTeam {
        try decode(ContactTeam.self, "{\"id\":\"\(id)\",\"name\":\"Team\",\"members\":[],\"createdAt\":\"\(createdAt)\"}")
    }
    private func runDetail(id: String = "r1", status: String = "running", updated: String = "2026-10-01T00:00:00.000Z",
                     title: String = "Work任务处理群", titleUpdated: String = "2026-10-01T00:00:00.000Z",
                     delivery: [String: Any]? = nil) throws -> ContactRunDetail {
        var object: [String: Any] = ["run": ["id": id, "teamId": "t1", "taskId": "task", "status": status,
                                                           "updatedAt": updated, "chatSessionId": "chat", "stepsUsed": 1],
                                       "steps": [], "chatTurns": [], "chatTitle": title, "chatTitleUpdatedAt": titleUpdated]
        if let delivery { object["delivery"] = delivery }
        return try JSONDecoder().decode(ContactRunDetail.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func delivery(_ date: String = "2026-10-01T00:00:00.000Z", excerpt: String = "Frozen report", total: Int = 1) -> [String: Any] {
        ["runId": "r1", "updatedAt": date, "headline": "交付", "totalFiles": total, "totalHandoffs": 0, "handoffs": [],
         "files": [["stepId": "s1", "seq": 1, "title": "Report", "memberId": "m1", "memberName": "historic",
                    "file": ["stepId": "s1", "name": "report.md", "path": "report.md", "size": 8,
                             "preview": ["title": "Result", "excerpt": excerpt]]]]]
    }
    func testDirectoryOrdersByCreationTimeThenStableIdentityAndMissingDatesLast() throws {
        let people = [try employee(id: "missing"), try employee(id: "new", createdAt: "2026-10-01"),
                      try employee(id: "b", createdAt: "2026-09-01"), try employee(id: "a", createdAt: "2026-09-01")]
        XCTAssertEqual(contactOrderedEmployees(people).map(\.id), ["a", "b", "new", "missing"])
        XCTAssertEqual(try contactOrderedTeams([team(id: "missing"), team(id: "new", createdAt: "2026-10-01"), team(id: "old", createdAt: "2026-09-01")]).map(\.id), ["old", "new", "missing"])
    }
    func testNewTeamMemberIdentityMatchesServerPreservationContract() throws {
        let member = ContactTeamMember(employee: try employee(), leader: true)
        XCTAssertNotNil(member.id.range(of: #"^m_[A-Za-z0-9]{1,32}$"#, options: .regularExpression))
        var draft = ContactTeamDraft(); draft.name = "Team"
        draft.members = [member, ContactTeamMember(employee: try employee(id: "e2", name: "Other"), leader: false)]
        XCTAssertNil(draft.validationError)
        draft.members[1].employeeId = member.employeeId
        XCTAssertNotNil(draft.validationError)
        XCTAssertNotNil(contactEmployeeInviteError(try employee(), members: draft.members, replacingID: nil))
        XCTAssertNil(contactEmployeeInviteError(try employee(id: "e3", name: "Third"), members: draft.members, replacingID: nil))
    }
    func testDeliveryMergeKeepsFrozenFilesAndClearsWhenExplicitlyNewerSourceOmitsProjection() throws {
        let old = try runDetail(delivery: delivery(total: 20))
        let partial = try runDetail(delivery: delivery(excerpt: "", total: 1))
        let merged = try XCTUnwrap(mergeContactRunDetail(previous: old, incoming: partial, expectedRunID: "r1"))
        XCTAssertEqual(merged.delivery?.totalFiles, 20)
        XCTAssertEqual(merged.delivery?.files.first?.file.preview?.excerpt, "Frozen report")
        let missingSame = try runDetail()
        XCTAssertNotNil(mergeContactRunDetail(previous: old, incoming: missingSame, expectedRunID: "r1")?.delivery)
        let missingNew = try runDetail(updated: "2026-10-02T00:00:00.000Z")
        XCTAssertNil(mergeContactRunDetail(previous: old, incoming: missingNew, expectedRunID: "r1")?.delivery)
        XCTAssertEqual(mergeContactRunDetail(previous: old, incoming: try runDetail(id: "foreign"), expectedRunID: "r1")?.run.id, "r1")
    }
    func testRunAndChatTitleHaveIndependentFreshnessAndMalformedDeliveryFallsBack() throws {
        let old = try runDetail(status: "done", updated: "2026-10-02T00:00:00.000Z", delivery: delivery())
        let renamedOldRun = try runDetail(status: "running", title: "Renamed任务处理群", titleUpdated: "2026-10-03T00:00:00.000Z")
        let merged = try XCTUnwrap(mergeContactRunDetail(previous: old, incoming: renamedOldRun, expectedRunID: "r1"))
        XCTAssertEqual(merged.run.status, "done"); XCTAssertEqual(merged.title, "Renamed任务处理群")
        XCTAssertNil(try runDetail(delivery: delivery("invalid date")).delivery)
        var foreign = delivery(); foreign["runId"] = "r2"
        XCTAssertNil(try runDetail(delivery: foreign).delivery)
        let file = try decode(ContactReportFile.self, #"{"stepId":"s","path":"report.md","name":"report.md","size":1}"#)
        XCTAssertNil(contactReportPath(file, cwd: nil)); XCTAssertEqual(contactReportPath(file, cwd: "/repo"), "/repo/report.md")
    }
    func testTeamRefreshRetainsEditedDraftAndLateSaveRetainsNewInput() async throws {
        let service = ContactTeamStub(info: ContactTeamInfo(team: try team(), runs: []))
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        let model = ContactTeamProfileStore(id: "t1", api: api, service: service)
        await model.load(); model.draft.description = "typed description"
        await model.load(); XCTAssertEqual(model.draft.description, "typed description")
        let directory = ContactsStore(service: ContactDirectoryStub())
        model.draft.members = [ContactTeamMember(employee: try employee(), leader: true),
                               ContactTeamMember(employee: try employee(id: "e2", name: "Other"), leader: false)]
        // Legacy unbound members remain valid and retain their IDs.
        model.draft.members[0].employeeId = nil; model.draft.members[1].employeeId = nil
        let began = expectation(description: "team save began"); service.saveBegan = { began.fulfill() }
        let finished = expectation(description: "team save finished")
        let subscription = model.$phase.dropFirst().filter { $0 == .sent }.sink { _ in finished.fulfill() }
        model.save(directory: directory); await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(service.savedDraft?.description, "typed description")
        model.draft.description = "new unsaved input"
        service.saveGate?.resume(returning: try team())
        await fulfillment(of: [finished], timeout: 2); withExtendedLifetime(subscription) {}
        XCTAssertEqual(model.draft.description, "new unsaved input"); XCTAssertTrue(model.hasUnsavedChanges)
    }
    func testRunChatUsesRelayAcrossRunningAndPreservesConcurrentNewDraft() async throws {
        let service = ContactRunStub(detail: try runDetail())
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        let model = ContactRunStore(runId: "r1", api: api, service: service)
        model.activate(); await model.refresh(); model.text = "submitted message"
        let began = expectation(description: "relay send began"); service.sendBegan = { began.fulfill() }
        let sent = expectation(description: "relay accepted")
        let subscription = model.$phase.dropFirst().filter { $0 == .sent }.sink { _ in sent.fulfill() }
        model.send(); await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(service.sentInput, "submitted message"); XCTAssertEqual(service.sentSessionID, "chat")
        model.text = "new input"
        service.sendGate?.resume(returning: try decode(SessionSnapshot.self, #"{"id":"chat","sessionKind":"structured","status":"idle"}"#))
        await fulfillment(of: [sent], timeout: 2); withExtendedLifetime(subscription) {}
        XCTAssertEqual(model.text, "new input"); XCTAssertEqual(service.actions, [])
    }
    func testUnknownRelaySendStaysBlockedAcrossRefreshAndClosing() async throws {
        let service = ContactRunStub(detail: try runDetail())
        service.sendFailure = WandAPI.APIError.server(status: 409, message: "unknown")
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        let model = ContactRunStore(runId: "r1", api: api, service: service)
        model.activate(); await model.refresh(); model.text = "message"
        let failed = expectation(description: "relay unconfirmed")
        let subscription = model.$phase.dropFirst().filter { $0 == .failed }.sink { _ in failed.fulfill() }
        model.send(); await fulfillment(of: [failed], timeout: 2); withExtendedLifetime(subscription) {}
        await model.refresh(); model.send(); XCTAssertEqual(service.sendCount, 1); XCTAssertTrue(model.unconfirmed)
        model.close(); model.activate(); model.send(); XCTAssertEqual(service.sendCount, 1)
    }
    func testStoppedRunCannotUseContinueEndpointAndFollowsNewRunOnSameChat() async throws {
        let service = ContactRunStub(detail: try runDetail(status: "stopped"))
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        let model = ContactRunStore(runId: "r1", api: api, service: service)
        model.activate(); await model.refresh(); model.action("continue", body: ["extraSteps": 10])
        XCTAssertEqual(service.actions, []); XCTAssertEqual(model.phase, .failed)
        service.newDetail = try runDetail(id: "r2", updated: "2026-10-02T00:00:00.000Z")
        await model.refresh(); XCTAssertEqual(model.currentRunID, "r2"); XCTAssertEqual(model.detail?.run.id, "r2")
    }
    func testEmployeeSessionRequestPinsRealTaskIdentityAndImmediateAckWithoutCliOverrides() {
        let body = contactEmployeeSessionBody(employeeID: "e1", cwd: "/repo", workspaceID: "w1", workspaceTaskID: "wt1", prompt: " Work ")
        XCTAssertEqual(Set(body.keys), ["employeeId", "cwd", "workspaceId", "workspaceTaskId", "prompt", "respondImmediately"])
        XCTAssertEqual(body["prompt"] as? String, "Work"); XCTAssertEqual(body["respondImmediately"] as? Bool, true)
        XCTAssertNil(body["provider"]); XCTAssertNil(body["runner"]); XCTAssertNil(body["systemPrompt"])
        let blank = contactEmployeeSessionBody(employeeID: "e1", cwd: "/repo", workspaceTaskID: "wt1")
        XCTAssertNil(blank["prompt"]); XCTAssertNil(blank["respondImmediately"])
    }
    func testTaskSubjectDispatchUsesAtomicServerOwnerAndNeverRequestsPty() throws {
        let subject = ContactExecutionSubject(type: "employee", id: "e1")
        let body = contactTaskSubjectBody(subject: subject, prompt: "Do work")
        XCTAssertEqual(body["kind"] as? String, "structured")
        XCTAssertEqual(body["subject"] as? [String: String], ["type": "employee", "id": "e1"])
        XCTAssertNil(body["agent"]); XCTAssertNil(body["employeeId"])
        let task = try decode(WandBoardTask.self, #"{"id":"t","executionSubject":{"type":"team","id":"team1"},"workspaceTaskId":"wt1"}"#)
        XCTAssertEqual(task.executionSubject?.type, "team"); XCTAssertEqual(task.executionSubject?.id, "team1")
        XCTAssertEqual(task.workspaceTaskId, "wt1")
        XCTAssertNil(try decode(WandBoardTask.self, #"{"id":"legacy"}"#).executionSubject)
    }
    func testTeamDispatchReceiptDecodesRelayAndRunWithoutFabricatedProvider() throws {
        let result = try decode(WandBoardDispatchResult.self, #"{"ok":true,"taskId":"t","session":{"id":"chat","sessionKind":"structured"},"teamRun":{"run":{"id":"r","teamId":"team1","taskId":"t","status":"running","updatedAt":"2026-10-04T00:00:00.000Z","chatSessionId":"chat"},"steps":[],"chatTurns":[]}}"#)
        XCTAssertEqual(result.sessionId, "chat"); XCTAssertEqual(result.provider, "")
        XCTAssertEqual(result.teamRun?.run.id, "r"); XCTAssertEqual(result.teamRun?.run.chatSessionId, result.sessionId)
    }
    func testCreationReceiptGuardDistinguishesUnsentAcceptedAndUnknownRequests() {
        let network = WandAPI.APIError.network("connection lost")
        XCTAssertFalse(contactCreationNeedsReview(attempted: false, error: network))
        XCTAssertFalse(contactCreationNeedsReview(attempted: true, accepted: true, error: network))
        XCTAssertFalse(contactCreationNeedsReview(attempted: true, error: WandAPI.APIError.server(status: 400, message: "rejected")))
        for error in [network, WandAPI.APIError.server(status: 409, message: "uncertain"), WandAPI.APIError.server(status: 500, message: "uncertain")] {
            XCTAssertTrue(contactCreationNeedsReview(attempted: true, error: error))
        }
    }
    /// External idb driver taps the real directory's name, whitespace, arrow and avatar.
    /// Kept opt-in so ordinary CI never waits for manual input or touches a live server.
    func testDirectoryTouchTargets() async throws {
        guard ProcessInfo.processInfo.environment["WAND_DIRECTORY_TOUCH_TEST"] == "1" else {
            throw XCTSkip("Requires the isolated simulator idb touch driver")
        }
        let service = ContactDirectoryStub()
        service.people = [try decode(SiliconEmployee.self, #"{"id":"touch-employee","name":"点按测试","avatar":"cat:2"}"#)]
        service.groups = [try decode(ContactTeam.self, #"{"id":"touch-team","name":"团队点按测试","members":[]}"#)]
        let store = ContactsStore(service: service)
        let employee = expectation(description: "name, whitespace and arrow open employee")
        employee.expectedFulfillmentCount = 3
        employee.assertForOverFulfill = true
        let team = expectation(description: "name, whitespace and arrow open team")
        team.expectedFulfillmentCount = 3
        team.assertForOverFulfill = true
        var employeeCalls = 0, teamCalls = 0
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        window.rootViewController = UIHostingController(rootView:
            ContactsView(api: api, store: store, onBack: {}, onOpenSession: { _ in XCTFail("Must use stable IM identity") },
                onOpenRun: { _ in XCTFail("Must use team conversation callback") },
                onOpenConversation: { id in
                    XCTAssertEqual(id, ConversationStore.employeeID("touch-employee"))
                    employeeCalls += 1; employee.fulfill()
                }, onTeamConversation: { id in
                    XCTAssertEqual(id, "touch-team")
                    teamCalls += 1; team.fulfill()
                }, embedded: true))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await fulfillment(of: [employee, team], timeout: 90)
        // Driver also opens the independent profile avatar after the six conversation taps.
        try await Task.sleep(for: .seconds(5))
        XCTAssertEqual(employeeCalls, 3)
        XCTAssertEqual(teamCalls, 3)
        XCTAssertEqual(service.creations, 0, "Touching stable IM routes must not create legacy sessions")
    }

    func testHomeDockFitsNarrowSidebarAndFeedbackKeepsFixedSize() {
        for width: CGFloat in [280, 320, 768] {
            let dock = UIHostingController(rootView: HomeMenuPill(mode: .sessions, onMode: { _ in }, onContacts: {}))
            XCTAssertLessThanOrEqual(dock.sizeThatFits(in: CGSize(width: width, height: 100)).width, width)
        }
        for phase: ComposerSendPhase in [.idle, .sending, .sent, .failed] {
            let host = UIHostingController(rootView: ContactActionButton(title: "保存", phase: phase, action: {}))
            let size = host.sizeThatFits(in: CGSize(width: 320, height: 100))
            XCTAssertEqual(size.width, 112, accuracy: 1); XCTAssertEqual(size.height, 44, accuracy: 1)
        }
    }
}

@MainActor
private final class EmployeeEditingStub: EmployeeEditingService {
    let employee: SiliconEmployee
    var submitted: EmployeeDraft?
    var saveBegan: (() -> Void)?
    var saveGate: CheckedContinuation<SiliconEmployee, Never>?
    init(employee: SiliconEmployee) { self.employee = employee }
    func models() async throws -> ModelsResponse {
        try JSONDecoder().decode(ModelsResponse.self, from: Data("{}".utf8))
    }
    func contactEmployee(_ id: String) async throws -> SiliconEmployee { employee }
    func saveContactEmployee(id: String?, draft: EmployeeDraft, builtin: Bool) async throws -> SiliconEmployee {
        submitted = draft
        return await withCheckedContinuation { saveGate = $0; saveBegan?() }
    }
    func manageContactEmployee(id: String, action: String) async throws {}
}

@MainActor
private final class ContactDirectoryStub: ContactDirectoryService {
    var people: [SiliconEmployee] = []
    var groups: [ContactTeam] = []
    var projects: [Workspace] = []
    var failure: Error?
    var creationFailure: Error?
    var creations = 0
    var delayFirstPeople = false
    var peopleRequests = 0
    var peopleBegan: (() -> Void)?
    var peopleGate: CheckedContinuation<[SiliconEmployee], Never>?
    func listContactEmployees() async throws -> [SiliconEmployee] {
        peopleRequests += 1
        if delayFirstPeople && peopleRequests == 1 {
            return await withCheckedContinuation { continuation in peopleGate = continuation; peopleBegan?() }
        }
        if let failure { throw failure }; return people
    }
    func listContactTeams() async throws -> [ContactTeam] { if let failure { throw failure }; return groups }
    func listWorkspaces() async throws -> [Workspace] { if let failure { throw failure }; return projects }
    func contactDefaultCwd() async throws -> String? { if let failure { throw failure }; return "/repo" }
    func createEmployeeConversation(employeeId: String, binding: ContactConversationBinding) async throws -> SessionSnapshot {
        creations += 1; await Task.yield()
        if let creationFailure { throw creationFailure }
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data("{\"id\":\"session\",\"employeeId\":\"\(employeeId)\",\"sessionKind\":\"structured\",\"status\":\"idle\"}".utf8))
    }
    func startContactTeam(teamId: String, workspaceId: String) async throws -> ContactRunDetail {
        throw WandAPI.APIError.server(status: 400, message: "not used by employee tests")
    }
}

@MainActor
private final class ContactTeamStub: ContactTeamService {
    var info: ContactTeamInfo
    var savedDraft: ContactTeamDraft?
    var saveBegan: (() -> Void)?
    var saveGate: CheckedContinuation<ContactTeam, Never>?
    init(info: ContactTeamInfo) { self.info = info }
    func models() async throws -> ModelsResponse { try JSONDecoder().decode(ModelsResponse.self, from: Data("{}".utf8)) }
    func contactTeam(_ id: String) async throws -> ContactTeamInfo { info }
    func saveContactTeam(id: String?, draft: ContactTeamDraft) async throws -> ContactTeam {
        savedDraft = draft
        return await withCheckedContinuation { saveGate = $0; saveBegan?() }
    }
    func deleteContactTeam(_ id: String) async throws {}
    func startContactTeam(teamId: String, workspaceId: String, note: String) async throws -> ContactRunDetail { throw WandAPI.APIError.server(status: 400, message: "not used") }
}
@MainActor
private final class ContactRunStub: ContactRunService {
    var detail: ContactRunDetail
    var newDetail: ContactRunDetail?
    var sentInput: String?
    var sentSessionID: String?
    var sendBegan: (() -> Void)?
    var sendGate: CheckedContinuation<SessionSnapshot, Never>?
    var sendFailure: Error?
    var sendCount = 0
    var actions: [String] = []
    init(detail: ContactRunDetail) { self.detail = detail }
    func contactRun(_ id: String) async throws -> ContactRunDetail { newDetail?.run.id == id ? newDetail! : detail }
    func contactRunAction(_ id: String, action: String, body: [String: Any]) async throws -> ContactRunDetail { actions.append(action); return detail }
    func sendStructuredInput(id: String, input: String) async throws -> SessionSnapshot {
        sendCount += 1; sentSessionID = id; sentInput = input
        if let sendFailure { throw sendFailure }
        return await withCheckedContinuation { sendGate = $0; sendBegan?() }
    }
    func contactTaskRuns(_ taskId: String) async throws -> [ContactTeamRun] { [detail.run] + (newDetail.map { [$0.run] } ?? []) }
    func contactLive(_ id: String) async throws -> ContactLiveUpdate { ContactLiveUpdate(runId: id, steps: []) }
}
