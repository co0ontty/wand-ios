import XCTest
@testable import Wand

final class ConversationListFiltersTests: XCTestCase {
    private func facts(_ stage: ConversationTaskStage = .review, workspace: String = "wand", archived: Bool = false, active: Bool = false, text: String = "修复搜索", employee: String = "none") -> ConversationFilterFacts {
        ConversationFilterFacts(stage: stage, workspace: .workspace(workspace), archived: archived, active: active, searchText: text, employee: employee)
    }

    func testStatusAndWorkspaceMustMatchTheSameSession() {
        let filters = ConversationListFilters(stage: .review, workspace: .workspace("wand"))
        let siblings = [facts(.review, workspace: "other"), facts(.doing, workspace: "wand")]
        XCTAssertTrue(siblings.contains { $0.stage == .review })
        XCTAssertTrue(siblings.contains { $0.workspace == .workspace("wand") })
        XCTAssertTrue(siblings.filter { filters.matches($0) }.isEmpty)
        let matching = siblings + [facts()]
        XCTAssertEqual(matching.filter { filters.matches($0) }.count, 1)
    }

    func testSearchAndActivityAlsoUseTheSameSession() {
        let filters = ConversationListFilters(stage: .review, workspace: .workspace("wand"), activeOnly: true)
        let siblings = [facts(active: false), facts(.doing, active: true), facts(active: true, text: "另一个标题")]
        XCTAssertFalse(siblings.contains { filters.matches($0, query: "修复") })
        XCTAssertTrue(filters.matches(facts(active: true), query: "修复 搜索"))
    }

    func testBusinessStagesAndLegacyDoneNeverUseWorkspaceLifecycle() {
        XCTAssertEqual(ConversationTaskStage.businessStatus("done"), .review)
        for stage in ["backlog", "todo", "doing", "review", "ready", "archived"] {
            XCTAssertEqual(ConversationTaskStage.businessStatus(stage).rawValue, stage)
        }
        XCTAssertEqual(ConversationTaskStage.businessStatus("active"), .unknown)
        XCTAssertEqual(ConversationTaskStage.businessStatus(nil), .unknown)
        XCTAssertEqual(ConversationTaskStage.businessStatus("none"), .unknown)
        XCTAssertFalse(ConversationTaskStage.options.contains(.unknown))
    }

    func testUnknownContainersAndExplicitStandaloneAreDifferent() {
        XCTAssertEqual(ConversationTaskStage.resolve(boardStatus: nil, hasTaskContainer: true, workspaceTaskId: "task"), .unknown)
        XCTAssertEqual(ConversationTaskStage.resolve(boardStatus: nil, hasTaskContainer: false, workspaceTaskId: "task"), .unknown)
        XCTAssertEqual(ConversationTaskStage.resolve(boardStatus: nil, hasTaskContainer: false, workspaceTaskId: nil), .none)
        let filters = ConversationListFilters(stage: .none)
        XCTAssertFalse(filters.matches(facts(.unknown)))
        XCTAssertTrue(filters.matches(facts(.none)))
        // A failed or not-yet-loaded association has no explicit standalone facts.
        let unavailable: [ConversationFilterFacts] = []
        XCTAssertFalse(unavailable.contains { filters.matches($0) })
    }

    func testDefaultArchiveScopeIsCurrentAndDoesNotCountAsAFilter() {
        let filters = ConversationListFilters()
        XCTAssertEqual(filters.archive, .current)
        XCTAssertEqual(filters.count, 0)
        XCTAssertTrue(filters.isDefault)
        XCTAssertTrue(filters.matches(facts()))
        XCTAssertFalse(filters.matches(facts(archived: true)))
        let all = ConversationListFilters(archive: .all)
        XCTAssertEqual(all.count, 1)
        XCTAssertFalse(all.isDefault)
        XCTAssertTrue(all.matches(facts()))
        XCTAssertTrue(all.matches(facts(archived: true)))
    }

    func testTaskArchiveIsIndependentOfConversationArchive() {
        var filters = ConversationListFilters(stage: .archived, archive: .current)
        XCTAssertTrue(filters.matches(facts(.archived)))
        XCTAssertFalse(filters.matches(facts(.archived, archived: true)))
        filters.archive = .archived
        XCTAssertFalse(filters.matches(facts(.archived)))
        XCTAssertTrue(filters.matches(facts(.archived, archived: true)))
        XCTAssertFalse(filters.matches(facts(.review, archived: true)))
        filters.archive = .all
        XCTAssertTrue(filters.matches(facts(.archived)))
        XCTAssertTrue(filters.matches(facts(.archived, archived: true)))
    }

    func testWorkspaceIdentityNeverUsesNamesOrPaths() {
        XCTAssertEqual(ConversationWorkspaceFilter.resolve(id: "wand-global"), .unassigned)
        XCTAssertEqual(ConversationWorkspaceFilter.resolve(id: "synthetic", synthetic: true), .unassigned)
        XCTAssertEqual(ConversationWorkspaceFilter.resolve(id: "global", global: true), .unassigned)
        XCTAssertEqual(ConversationWorkspaceFilter.resolve(id: nil), .unknown)
        XCTAssertEqual(ConversationWorkspaceFilter.resolve(id: "stable-id"), .workspace("stable-id"))
        let unassigned = ConversationFilterFacts(stage: .none, workspace: .unassigned, archived: false, active: false, searchText: "Wand /work/wand")
        XCTAssertTrue(ConversationListFilters().matches(unassigned))
        XCTAssertTrue(ConversationListFilters(workspace: .unassigned).matches(unassigned))
        XCTAssertFalse(ConversationListFilters(workspace: .workspace("wand")).matches(unassigned))
        XCTAssertFalse(ConversationListFilters(workspace: .workspace("deleted-id")).matches(facts()))
    }

    func testEmployeeFilterMatchesByEmployeeId() {
        let e1 = facts(text: "员工1", employee: "emp-1")
        let e2 = facts(text: "员工2", employee: "emp-2")
        let unassigned = facts(text: "未分配", employee: "none")
        let filters = ConversationListFilters(employees: ["emp-1"])
        XCTAssertTrue(filters.matches(e1))
        XCTAssertFalse(filters.matches(e2))
        XCTAssertFalse(filters.matches(unassigned))
        let multi = ConversationListFilters(employees: ["emp-1", "none"])
        XCTAssertTrue(multi.matches(e1))
        XCTAssertFalse(multi.matches(e2))
        XCTAssertTrue(multi.matches(unassigned))
        XCTAssertEqual(filters.count, 1)
    }

    func testDraftResetAndCancelDoNotMutateAppliedFilters() {
        let applied = ConversationListFilters(stage: .review, workspace: .workspace("wand"), archive: .current, activeOnly: true)
        var draft = applied
        draft = ConversationListFilters()
        XCTAssertTrue(draft.isDefault)
        XCTAssertEqual(applied.count, 3, "the default archive scope is never an active filter")
        draft = applied // reopening discards the previous draft
        XCTAssertEqual(draft, applied)
    }
}
