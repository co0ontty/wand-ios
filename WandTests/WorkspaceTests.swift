import Foundation
import XCTest
import SwiftUI
import UIKit
@testable import Wand

@MainActor
final class WorkspaceTests: XCTestCase {
    func testWorkspaceTaskNavigationChromeAvoidsDuplicateNames() {
        XCTAssertEqual(workspaceTaskNavigationChrome(taskName: "修顶栏", workspaceName: "wand").title, "修顶栏")
        XCTAssertEqual(workspaceTaskNavigationChrome(taskName: "修顶栏", workspaceName: "wand").subtitle, "wand")
        XCTAssertEqual(workspaceTaskNavigationChrome(taskName: "wand", workspaceName: "wand").title, "wand")
        XCTAssertNil(workspaceTaskNavigationChrome(taskName: "wand", workspaceName: "wand").subtitle)
        XCTAssertEqual(workspaceTaskNavigationChrome(taskName: "  ", workspaceName: "wand").title, "wand")
        XCTAssertNil(workspaceTaskNavigationChrome(taskName: "  ", workspaceName: "wand").subtitle)
        XCTAssertEqual(workspaceTaskNavigationChrome(taskName: "", workspaceName: "").title, "任务")
        XCTAssertEqual(workspaceTaskNavigationChrome(taskName: "修顶栏", workspaceName: "全局").title, "修顶栏")
        XCTAssertNil(workspaceTaskNavigationChrome(taskName: "修顶栏", workspaceName: "全局").subtitle)
        XCTAssertNil(emptyTaskWorkspaceCaption(""))
        XCTAssertNil(emptyTaskWorkspaceCaption("全局"))
        XCTAssertEqual(emptyTaskWorkspaceCaption("wand"), "WAND")
    }

    func testWorkspaceTaskCreationUsesPendingConversationAndOpensCreatedSession() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Wand/WorkspaceListView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("NewConversationView("))
        XCTAssertTrue(source.contains("serverID: ServerProfiles.stableID(for: api.baseURL)"))
        XCTAssertTrue(source.contains("workspaceID: newTaskSheetWorkspaceId"))
        XCTAssertTrue(source.contains("onOpenTaskSession(workspace, summary.asTask(), session)"))
        XCTAssertFalse(source.contains("WorkspaceNewTaskSheet(api:"))
    }

    func testTaskListPresentationShortensPathsAndAvoidsSharedDirectoryLabel() {
        XCTAssertEqual(
            TaskListPresentation.shortenWorkspacePath("/Users/me/Self/vibe_coding/wand"),
            "…/vibe_coding/wand"
        )
        XCTAssertEqual(
            TaskListPresentation.directoryPathCaption(name: "wand", cwd: "/Users/me/Self/vibe_coding/wand"),
            "…/vibe_coding/wand"
        )
        XCTAssertNil(TaskListPresentation.taskIsolationCaption(isolated: false))
        XCTAssertEqual(TaskListPresentation.taskIsolationCaption(isolated: true), "隔离")
        XCTAssertEqual(
            TaskListPresentation.listSessionLabel(
                title: "wand",
                providerLabel: "Pi",
                cwd: "/Users/me/wand",
                index: 0
            ),
            "Pi 1"
        )
        // 任务名重复的标题照显示：最新会话的标题常常正好等于任务首行。
        XCTAssertEqual(
            TaskListPresentation.listSessionLabel(
                title: "重构会话恢复流程",
                providerLabel: "Pi",
                cwd: "/Users/me/wand",
                index: 0
            ),
            "重构会话恢复流程"
        )
    }

    func testManagedSelectionArchivesTasksAndDeletesSelectedSessions() throws {
        let group = try decode(
            TaskDirectoryGroup.self,
            from: """
            {"workspaceId":"workspace-1","workspaceName":"Wand","workspaceCwd":"/work","synthetic":false,"tasks":[{"id":"task-1","workspaceId":"workspace-1","name":"修复侧栏","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/work","isolated":false,"worktreeError":null,"sessions":[{"id":"session-1"},{"id":"session-2"}],"totalSessions":2}],"standaloneSessions":[{"id":"loose-1"}]}
            """
        )
        let selection = TaskListPresentation.ManageSelection(
            taskIds: ["task-1", "gone-task"],
            sessionIds: ["session-1", "loose-1", "gone-session"]
        )
        // 选中项已不可见（另一端删掉了）要剪掉，否则会把不存在的 ID 交给服务端。
        let pruned = TaskListPresentation.pruneManagedSelection(selection, groups: [group])
        XCTAssertEqual(pruned.taskIds, ["task-1"])
        XCTAssertEqual(pruned.sessionIds, ["session-1", "loose-1"])
        // 任务内的会话被选上也算破坏性操作——归档任务不会连带停掉它的终端。
        XCTAssertTrue(TaskListPresentation.managedSelectionIsDestructive(pruned))
        XCTAssertFalse(
            TaskListPresentation.managedSelectionIsDestructive(
                TaskListPresentation.ManageSelection(taskIds: ["task-1"], sessionIds: [])
            )
        )
        XCTAssertEqual(TaskListPresentation.describeManagedAction(pruned), "归档任务并删除终端")
        XCTAssertEqual(
            TaskListPresentation.describeManagedAction(
                TaskListPresentation.ManageSelection(taskIds: ["task-1"], sessionIds: [])
            ),
            "归档任务"
        )
        XCTAssertEqual(
            TaskListPresentation.describeManagedAction(
                TaskListPresentation.ManageSelection(taskIds: [], sessionIds: ["s"])
            ),
            "删除终端"
        )
        XCTAssertEqual(
            TaskListPresentation.describeManagedResult(
                TaskListPresentation.ManageSelection(taskIds: ["a", "b"], sessionIds: ["s"])
            ),
            "归档 2 个任务、删除 1 个终端"
        )
        XCTAssertEqual(
            TaskListPresentation.describeManagedResult(
                TaskListPresentation.ManageSelection(taskIds: [], sessionIds: ["s"])
            ),
            "删除 1 个终端"
        )
        XCTAssertEqual(
            TaskListPresentation.describeManagedResult(
                TaskListPresentation.ManageSelection(taskIds: ["a"], sessionIds: [])
            ),
            "归档 1 个任务"
        )
    }

    func testTaskDirectoryGroupTreatsGlobalWorkspaceAsUnbindable() throws {
        let global = try decode(
            TaskDirectoryGroup.self,
            from: """
            {"workspaceId":"wand-global","workspaceName":"全局","workspaceCwd":"/scratch","global":true,"synthetic":false,"tasks":[],"standaloneSessions":[]}
            """
        )
        XCTAssertTrue(global.isGlobal)
        XCTAssertFalse(global.isBindableProject)
        XCTAssertFalse(global.isSynthetic)
    }

    func testTaskDetailIsSessionDirectoryAndDoesNotDependOnATabSelection() {
        let sessions = [summary(id: "session-1", startedAt: "2026-08-09T00:00:01Z"),
                        summary(id: "session-2", startedAt: "2026-08-09T00:00:02Z")]
        XCTAssertEqual(workspaceTaskVisibleSessions(sessions).map(\.id), ["session-1", "session-2"])
        XCTAssertTrue(workspaceTaskVisibleSessions([]).isEmpty)
    }

    func testNewTaskRoutingMatchesAndroidForEmptyPromptsEmployeesAndRegisteredDirectories() {
        XCTAssertTrue(newTaskStartsUngroupedSession(name: "", startFirstSession: true, parentTaskID: nil, teamSelected: false))
        XCTAssertTrue(newTaskStartsUngroupedSession(name: "  ", startFirstSession: true, parentTaskID: "", teamSelected: false))
        XCTAssertFalse(newTaskStartsUngroupedSession(name: "named", startFirstSession: true, parentTaskID: nil, teamSelected: false))
        XCTAssertFalse(newTaskStartsUngroupedSession(name: "", startFirstSession: false, parentTaskID: nil, teamSelected: false))
        XCTAssertFalse(newTaskStartsUngroupedSession(name: "", startFirstSession: true, parentTaskID: "parent", teamSelected: false))
        XCTAssertFalse(newTaskStartsUngroupedSession(name: "", startFirstSession: true, parentTaskID: nil, teamSelected: true))
    }

    func testCreationRetryNeverReplaysAcceptedOrUnknownLaunch() {
        XCTAssertTrue(newTaskMayRetryLaunch(accepted: false, unknown: false))
        XCTAssertFalse(newTaskMayRetryLaunch(accepted: true, unknown: false))
        XCTAssertFalse(newTaskMayRetryLaunch(accepted: false, unknown: true))
        XCTAssertFalse(newTaskMayRetryLaunch(accepted: true, unknown: true))
    }

    func testNewTaskParentIsPassedAtomicallyAndAbsentParentIsOmitted() {
        let grouped = createWorkspaceTaskRequest(workspaceId: "w", name: "child", baseRef: nil, description: "goal", parentTaskId: "parent")
        XCTAssertEqual(grouped.body["parentTaskId"], .string("parent"))
        XCTAssertEqual(createStandaloneTaskRequest(name: "child", parentTaskId: "parent").body["parentTaskId"], .string("parent"))
        XCTAssertNil(createStandaloneTaskRequest(name: "child").body["parentTaskId"])
    }

    func testTaskListKeepsCreatedOrderWithNewItemsFirst() throws {
        let older = try group(
            id: "older",
            cwd: "/repo/older",
            taskID: "older-task",
            createdAt: "2026-01-01T00:00:00Z",
            lastOpenedAt: "2026-06-01T00:00:00Z"
        )
        let newer = try group(
            id: "newer",
            cwd: "/repo/newer",
            taskID: "newer-task",
            createdAt: "2026-05-01T00:00:00Z",
            lastOpenedAt: "2026-02-01T00:00:00Z"
        )
        let running = try group(
            id: "running",
            cwd: "/repo/running",
            taskID: "running-task",
            createdAt: "2026-03-01T00:00:00Z",
            lastOpenedAt: "2026-04-01T00:00:00Z",
            sessionStatus: "running"
        )

        XCTAssertEqual(
            TaskListPresentation.orderedDirectoryGroups([older, newer, running]).map(\.id),
            ["older", "newer", "running"]
        )
        XCTAssertEqual(
            TaskListPresentation.orderedTaskSummaries(older.tasks + newer.tasks).map(\.id),
            ["older-task", "newer-task"]
        )
    }

    func testTaskListExpansionStorageRoundTripsCollapsedIds() {
        let defaults = UserDefaults(suiteName: "wand.taskList.expansion.test")!
        defaults.removePersistentDomain(forName: "wand.taskList.expansion.test")
        TaskListExpansionStorage.setCollapsedIds(["folder-b", "folder-a"], kind: "groups", defaults: defaults)
        XCTAssertEqual(TaskListExpansionStorage.collapsedIds(kind: "groups", defaults: defaults), ["folder-a", "folder-b"])
        defaults.removePersistentDomain(forName: "wand.taskList.expansion.test")
    }

    // ── 任务层级对齐（Android a1c7cb3 / 6886012 / 1b37959 / 99ccef9 + 服务端 249c98c）──

    func testDirectoryGroupsHideDoneTasksRenameGlobalAndKeepItLast() throws {
        let project = try decode(
            TaskDirectoryGroup.self,
            from: """
            {"workspaceId":"ws-1","workspaceName":"Wand","workspaceCwd":"/repo","synthetic":false,"tasks":[{"id":"active-1","workspaceId":"ws-1","name":"在做","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/repo","isolated":false,"worktreeError":null,"sessions":[],"totalSessions":0},{"id":"done-1","workspaceId":"ws-1","name":"已归档","worktree":null,"layout":null,"status":"done","createdAt":"","lastOpenedAt":null,"cwd":"/repo","isolated":false,"worktreeError":null,"sessions":[],"totalSessions":0}],"standaloneSessions":[]}
            """
        )
        let global = try decode(
            TaskDirectoryGroup.self,
            from: """
            {"workspaceId":"wand-global","workspaceName":"全局","workspaceCwd":"/scratch","global":true,"synthetic":false,"tasks":[{"id":"loose-task","workspaceId":"wand-global","name":"无归属","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/scratch","isolated":false,"worktreeError":null,"sessions":[],"totalSessions":0}],"standaloneSessions":[{"id":"loose-session"}]}
            """
        )
        let emptyGlobal = try decode(
            TaskDirectoryGroup.self,
            from: """
            {"workspaceId":"wand-global","workspaceName":"全局","workspaceCwd":"/scratch","global":true,"synthetic":false,"tasks":[],"standaloneSessions":[]}
            """
        )

        let ordered = TaskListPresentation.orderedDirectoryGroups([global, project, emptyGlobal])

        XCTAssertEqual(ordered.map(\.workspaceId), ["wand-global", "ws-1"])
        // 侧栏不展示已完成任务（归档任务只在看板里看）。
        XCTAssertEqual(ordered[1].tasks.map(\.id), ["active-1"])
        // 全局空间使用可读名称，顺序仍以服务端已保存的用户排序为准。
        XCTAssertEqual(ordered[0].workspaceName, TaskListPresentation.unassignedWorkspaceName)
        XCTAssertEqual(ordered[0].standaloneSessions.map(\.id), ["loose-session"])
    }

    func testGlobalGroupIsRecognisedByFlagOrLegacyId() throws {
        let flagged = try decode(
            TaskDirectoryGroup.self,
            from: #"{"workspaceId":"wp-1","workspaceName":"全局","workspaceCwd":"/s","global":true,"synthetic":false,"tasks":[],"standaloneSessions":[]}"#
        )
        let legacy = try decode(
            TaskDirectoryGroup.self,
            from: #"{"workspaceId":"wand-global","workspaceName":"全局","workspaceCwd":"/s","synthetic":false,"tasks":[],"standaloneSessions":[]}"#
        )
        let real = try decode(
            TaskDirectoryGroup.self,
            from: #"{"workspaceId":"ws-1","workspaceName":"Wand","workspaceCwd":"/repo","synthetic":false,"tasks":[],"standaloneSessions":[]}"#
        )

        XCTAssertTrue(flagged.isGlobal)
        XCTAssertFalse(flagged.isBindableProject)
        // 老服务端不给 global 字段，只给 wand-global 这个 ID。
        XCTAssertTrue(legacy.isGlobal)
        XCTAssertFalse(legacy.isBindableProject)
        XCTAssertFalse(real.isGlobal)
        XCTAssertTrue(real.isBindableProject)
    }

    func testSessionMoveTargetsDedupeFilterAndKeepCurrentLast() throws {
        let project = try decode(
            TaskDirectoryGroup.self,
            from: """
            {"workspaceId":"ws-1","workspaceName":"Wand","workspaceCwd":"/repo","synthetic":false,"tasks":[{"id":"task-current","workspaceId":"ws-1","name":"当前任务","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/repo","isolated":false,"worktreeError":null,"sessions":[{"id":"s-1"}],"totalSessions":1},{"id":"task-other","workspaceId":"ws-1","name":"目标任务","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/repo","isolated":false,"worktreeError":null,"sessions":[],"totalSessions":0}],"standaloneSessions":[]}
            """
        )
        let global = try decode(
            TaskDirectoryGroup.self,
            from: """
            {"workspaceId":"wand-global","workspaceName":"全局","workspaceCwd":"/scratch","global":true,"synthetic":false,"tasks":[{"id":"task-loose","workspaceId":"wand-global","name":"无归属任务","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/scratch","isolated":false,"worktreeError":null,"sessions":[],"totalSessions":0}],"standaloneSessions":[]}
            """
        )
        // 同一任务出现在两个目录组里（合成组 + 真实项目组）只能列一次。
        let targets = SessionMovePresentation.targets(
            groups: [project, project, global],
            sessionId: "s-1"
        )
        XCTAssertEqual(targets.map(\.id), ["task-current", "task-other", "task-loose"])
        XCTAssertTrue(targets.first(where: { $0.id == "task-current" })?.current == true)
        XCTAssertEqual(
            targets.first(where: { $0.id == "task-loose" })?.workspace,
            TaskListPresentation.unassignedWorkspaceName
        )
        // 可选目标在上，源任务（禁用）在下。
        XCTAssertEqual(
            SessionMovePresentation.ordered(targets).map(\.id),
            ["task-other", "task-loose", "task-current"]
        )
        // 搜索命中的工作区名与任务名都能过滤，未归属用重命名后的名字。
        XCTAssertEqual(
            SessionMovePresentation.targets(groups: [project, global], sessionId: "s-1", query: "未归属")
                .map(\.id),
            ["task-loose"]
        )
        XCTAssertEqual(
            SessionMovePresentation.targets(groups: [project, global], sessionId: "s-1", query: "目标")
                .map(\.id),
            ["task-other"]
        )
        XCTAssertTrue(
            SessionMovePresentation.targets(groups: [project, global], sessionId: "s-1", query: "没有这个")
                .isEmpty
        )
    }

    func testSessionMoveSubtitleDisambiguatesDuplicateNames() throws {
        let group = try decode(
            TaskDirectoryGroup.self,
            from: """
            {"workspaceId":"ws-1","workspaceName":"Wand","workspaceCwd":"/repo","synthetic":false,"tasks":[{"id":"task-a","workspaceId":"ws-1","name":"修复登录","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/repo","isolated":false,"worktreeError":null,"sessions":[],"totalSessions":0},{"id":"task-b","workspaceId":"ws-1","name":"修复登录","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/repo","isolated":false,"worktreeError":null,"sessions":[],"totalSessions":0},{"id":"task-c","workspaceId":"ws-1","name":"别的事","worktree":null,"layout":null,"status":"active","createdAt":"","lastOpenedAt":null,"cwd":"/repo","isolated":false,"worktreeError":null,"sessions":[],"totalSessions":0}],"standaloneSessions":[]}
            """
        )
        let targets = SessionMovePresentation.targets(groups: [group], sessionId: "s-1")
        let ambiguous = SessionMovePresentation.ambiguousKeys(targets)

        XCTAssertEqual(ambiguous.count, 1)
        XCTAssertEqual(
            targets.filter { ambiguous.contains($0.key) }.map(\.id),
            ["task-a", "task-b"]
        )
        XCTAssertEqual(
            targets.first(where: { $0.id == "task-a" })?.subtitle(ambiguous: true),
            "Wand · task-a"
        )
        XCTAssertEqual(targets.first(where: { $0.id == "task-c" })?.subtitle(ambiguous: false), "Wand")
        XCTAssertEqual(targets.first(where: { $0.id == "task-c" })?.subtitle(ambiguous: true), "Wand · task-c")
    }

    func testTaskHierarchyMutationFilterIgnoresReadsAndLayoutWrites() {
        XCTAssertFalse(changesTaskHierarchy(method: "GET", path: "/api/tasks"))
        // 布局自动保存不能反过来触发重拉，否则会自激。
        XCTAssertFalse(changesTaskHierarchy(method: "PUT", path: "/api/workspace-tasks/task-1/layout"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/workspace-tasks/task-1/sessions"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/workspace-tasks/task-1/archive"))
        XCTAssertTrue(changesTaskHierarchy(method: "PATCH", path: "/api/workspace-tasks/task-1"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/tasks"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/tasks/organize-by-title"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/workspaces/ws-1/tasks"))
        XCTAssertTrue(changesTaskHierarchy(method: "DELETE", path: "/api/workspaces/ws-1"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/wand-tasks/task-1"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/sessions"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/sessions?source=new-session"))
        XCTAssertFalse(changesTaskHierarchy(method: "POST", path: "/api/commands"))
        XCTAssertFalse(changesTaskHierarchy(method: "POST", path: "/api/structured-sessions"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/sessions/batch-delete"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/sessions/batch-archive"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/sessions/s1/archive"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/sessions/s1/unarchive"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/sessions/s1/provider"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/sessions/s1/completion/view"))
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/ai-teams/t1/runs"))
        XCTAssertFalse(changesTaskHierarchy(method: "POST", path: "/api/sessions/s1/input"))
        // 查询串不能影响判定。
        XCTAssertTrue(changesTaskHierarchy(method: "POST", path: "/api/tasks?revision=1"))
        XCTAssertFalse(changesTaskHierarchy(method: "POST", path: "/api/unknown"))
    }

    func testTaskCreationRequestsCarryOptionalDescription() {
        let project = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "未命名任务",
            baseRef: nil,
            worktree: false,
            cwd: "/repo",
            description: "把侧栏重构一遍",
            creationRequestId: "task-request-1"
        )
        XCTAssertEqual(project.path, "/api/workspaces/ws-1/tasks")
        XCTAssertEqual(project.body["description"], .string("把侧栏重构一遍"))
        XCTAssertEqual(project.body["worktree"], .bool(false))
        XCTAssertEqual(project.body["cwd"], .string("/repo"))
        XCTAssertEqual(project.body["creationRequestId"], .string("task-request-1"))

        let standalone = createStandaloneTaskRequest(
            name: "未命名任务",
            cwd: "/scratch",
            worktree: false,
            description: "写个脚本",
            creationRequestId: "standalone-request-1"
        )
        XCTAssertEqual(standalone.path, "/api/tasks")
        XCTAssertEqual(standalone.body["description"], .string("写个脚本"))
        XCTAssertEqual(standalone.body["worktree"], .bool(false))
        XCTAssertEqual(standalone.body["creationRequestId"], .string("standalone-request-1"))

        // 空/全空白描述不占位，避免服务端拿空字符串去总结标题。
        XCTAssertNil(createStandaloneTaskRequest(name: "任务", description: "   ").body["description"])
        XCTAssertNil(createStandaloneTaskRequest(name: "任务").body["description"])
    }

    func testTaskWindowRequestSendsPromptOnlyForStructuredSessions() {
        let binding = WorkspaceBinding(
            workspaceId: "ws-1",
            workspaceTaskId: "task-1",
            cwd: "/repo"
        )
        let structured = workspaceTaskWindowRequest(
            target: .claude,
            binding: binding,
            kind: .structured,
            prompt: " 修好登录 ",
            mode: "managed",
            model: "claude-sonnet",
            thinkingEffort: "deep"
        )
        XCTAssertEqual(structured.path, "/api/sessions")
        XCTAssertEqual(structured.body["kind"], .string("structured"))
        XCTAssertEqual(structured.body["prompt"], .string("修好登录"))
        XCTAssertNil(structured.body["initialInput"])
        XCTAssertEqual(structured.body["workspaceTaskId"], .string("task-1"))
        XCTAssertEqual(structured.body["mode"], .string("managed"))
        XCTAssertEqual(structured.body["model"], .string("claude-sonnet"))
        XCTAssertEqual(structured.body["thinkingEffort"], .string("deep"))

        let pty = workspaceTaskWindowRequest(
            target: .claude,
            binding: binding,
            kind: .pty,
            prompt: "修好登录"
        )
        XCTAssertEqual(pty.path, "/api/sessions")
        XCTAssertEqual(pty.body["kind"], .string("pty"))
        XCTAssertNil(pty.body["mode"])
        XCTAssertNil(pty.body["model"])
        XCTAssertNil(pty.body["thinkingEffort"])
        XCTAssertEqual(pty.body["initialInput"], .string("修好登录"))
        XCTAssertNil(pty.body["prompt"])

        let shell = workspaceTaskWindowRequest(
            target: .shell,
            binding: binding,
            kind: .pty,
            prompt: "修好登录"
        )
        XCTAssertEqual(shell.path, "/api/sessions")
        XCTAssertEqual(shell.body["kind"], .string("pty"))
        XCTAssertEqual(shell.body["shell"], .bool(true))
        XCTAssertNil(shell.body["provider"])
        XCTAssertNil(shell.body["initialInput"])
    }

    func testSyntheticDirectoryRenameUsesSessionDirectoryEndpoint() async throws {
        let service = MockWorkspaceService()
        let store = WorkspaceStore(api: service, serverID: "server-rename")

        try await store.renameDirectory(cwd: "/repo/loose", name: "  临时目录  ")

        XCTAssertEqual(service.directoryRenames.map(\.path), ["/repo/loose"])
        XCTAssertEqual(service.directoryRenames.map(\.name), ["  临时目录  "])
    }

    func testMoveAndArchiveStoreMutationsHitServerAndDropLocalState() async throws {
        let service = MockWorkspaceService()
        let source = try workspace(id: "ws-source")
        let target = try workspace(id: "ws-target")
        let sourceTask = try task(id: "task-source", workspaceId: source.id)
        let targetTask = try task(id: "task-target", workspaceId: target.id)
        service.taskDetails[sourceTask.id] = try taskDetail(
            id: sourceTask.id,
            workspaceId: source.id,
            sessions: [summary(id: "s-1", startedAt: "2026-08-09T00:00:01Z")]
        )
        service.taskDetails[targetTask.id] = try taskDetail(
            id: targetTask.id,
            workspaceId: target.id,
            sessions: []
        )
        let store = WorkspaceStore(api: service, serverID: "server-move")

        try await store.moveSession(sessionId: "s-1", toTaskId: targetTask.id)

        XCTAssertEqual(service.moveRequests.map(\.sessionId), ["s-1"])
        XCTAssertEqual(service.moveRequests.map(\.taskId), [targetTask.id])

        // 打开目标任务再归档：当前任务与可见会话都要跟着清掉。
        await store.openTask(workspace: target, task: targetTask)
        try await store.archiveWorkspaceTask(taskId: targetTask.id, workspaceId: target.id)

        XCTAssertEqual(service.archiveRequests, [targetTask.id])
        XCTAssertNil(store.currentTask)
        XCTAssertNil(store.currentWorkspace)
        XCTAssertNil(store.visibleSessionID)
    }

    func testTaskTreeHidesNeedlessCaretsAndKeepsTerminalsOpen() {
        XCTAssertFalse(TaskListPresentation.showsTaskSessionDisclosure(sessionCount: 0))
        XCTAssertFalse(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: false, sessionCount: 0))
        XCTAssertTrue(TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: false, sessionCount: 0, isOnlyTask: true
        ))
        XCTAssertFalse(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: true, sessionCount: 2))
        XCTAssertTrue(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: false, sessionCount: 2))
    }

    func testWorkspaceDetailAndRecursiveLayoutDecodeUnknownTabs() throws {
        let detail = try decode(
            WorkspaceTaskDetail.self,
            from: #"""
            {
              "id":"task-1","workspaceId":"workspace-1","name":"Adapt iOS",
              "worktree":{"branch":"wand/task","path":"/repo/.wand-worktrees/task","baseRef":"main","repoRoot":"/repo"},
              "layout":{"type":"windows","windows":[{"id":"window-1","activeTabId":"future-1","layout":{
                "type":"split","dir":"h","ratio":0.6,"children":[
                  {"type":"pane","tabs":[{"id":"future-1","kind":"diff","path":"src/a.swift","side":"new"}],"active":0},
                  {"type":"pane","tabs":[{"id":"session-s1","kind":"session","sessionId":"s1"}],"active":0}
                ]
              }}],"activeWindowId":"window-1"},
              "status":"active","createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null,
              "cwd":"/repo/.wand-worktrees/task","sessions":[{"id":"s1","provider":"claude","startedAt":"2026-08-09T00:00:01Z"}]
            }
            """#
        )

        XCTAssertTrue(detail.isIsolated)
        XCTAssertEqual(detail.cwd, "/repo/.wand-worktrees/task")
        let tabs = try XCTUnwrap(detail.layout?.windows.first).layout
        let flattened = WorkspaceLayoutReconciler.tabs(in: tabs)
        XCTAssertEqual(flattened.count, 2)
        guard case .unknown(let id, let kind, let payload) = flattened[0] else {
            return XCTFail("Future tab should decode as a retained placeholder")
        }
        XCTAssertEqual(id, "future-1")
        XCTAssertEqual(kind, "diff")
        XCTAssertEqual(payload["side"], .string("new"))

        let roundTrip = try JSONDecoder().decode(
            TaskWindowLayout.self,
            from: JSONEncoder().encode(try XCTUnwrap(detail.layout))
        )
        XCTAssertEqual(roundTrip, detail.layout)
    }

    func testTaskLayoutRejectsUnknownWindowWithoutClearingValidWindows() {
        let json = #"""
        {
          "type":"windows",
          "windows":[
            {"id":"valid","layout":{"type":"pane","tabs":[],"active":0}},
            {"id":"future","layout":{"type":"grid","children":[]}}
          ],
          "activeWindowId":"valid"
        }
        """#

        XCTAssertThrowsError(try decode(TaskWindowLayout.self, from: json))
    }

    func testSessionSnapshotDecodesWorkspaceBindingOptionally() throws {
        let bound = try decode(
            SessionSnapshot.self,
            from: #"{"id":"s1","workspaceId":"w1","workspaceTaskId":"t1"}"#
        )
        let legacy = try decode(SessionSnapshot.self, from: #"{"id":"legacy"}"#)

        XCTAssertEqual(bound.workspaceId, "w1")
        XCTAssertEqual(bound.workspaceTaskId, "t1")
        XCTAssertEqual(WorkspaceSessionSummary(snapshot: bound).workspaceTaskId, "t1")
        XCTAssertNil(legacy.workspaceId)
        XCTAssertNil(legacy.workspaceTaskId)
    }

    func testEveryWorkspaceTargetBuildsBoundPtyOrShellRequest() {
        let binding = WorkspaceBinding(
            workspaceId: "workspace-id",
            workspaceTaskId: "task-id",
            cwd: "/task/worktree"
        )

        for target in WorkspaceSessionTarget.allCases {
            let pty = workspaceTaskWindowRequest(target: target, binding: binding, kind: .pty)
            if target == .wandAgent {
                XCTAssertEqual(pty.path, "/api/sessions")
                XCTAssertEqual(pty.body["kind"], .string("structured"))
                XCTAssertEqual(pty.body["provider"], .string("pi"))
                XCTAssertEqual(pty.body["engine"], .string("sdk"))
                XCTAssertEqual(pty.body["workspaceTaskId"], .string("task-id"))
                XCTAssertNil(pty.body["command"])
                continue
            }
            XCTAssertEqual(pty.path, "/api/sessions")
            XCTAssertEqual(pty.body["kind"], .string("pty"))
            XCTAssertEqual(pty.body["cwd"], .string("/task/worktree"))
            XCTAssertEqual(pty.body["workspaceId"], .string("workspace-id"))
            XCTAssertEqual(pty.body["workspaceTaskId"], .string("task-id"))
            if target == .shell {
                XCTAssertEqual(pty.body["shell"], .bool(true))
                XCTAssertNil(pty.body["provider"])
                XCTAssertNil(pty.body["command"])
            } else {
                XCTAssertEqual(pty.body["provider"], .string(target.rawValue))
                XCTAssertEqual(
                    pty.body["command"],
                    .string(target == .qoder ? "qodercli" : target.rawValue)
                )
                XCTAssertNil(pty.body["shell"])

                let structured = workspaceTaskWindowRequest(target: target, binding: binding, kind: .structured)
                XCTAssertEqual(structured.path, "/api/sessions")
                XCTAssertEqual(structured.body["kind"], .string("structured"))
                XCTAssertEqual(structured.body["provider"], .string(target.rawValue))
                XCTAssertNotNil(structured.body["runner"])
                XCTAssertNil(structured.body["command"])
            }
        }
    }

    func testSessionOrderingActiveSelectionAndReconcilePreserveSplitAndContentTabs() throws {
        let sessions = [
            summary(id: "late", startedAt: "2026-08-09T00:00:03Z"),
            summary(id: "early", startedAt: "2026-08-09T00:00:01Z"),
            summary(id: "missing-time", startedAt: nil),
        ]
        XCTAssertEqual(
            WorkspaceLayoutReconciler.orderedSessions(sessions).map(\.id),
            ["early", "late", "missing-time"]
        )

        let persisted = try decode(
            TaskWindowLayout.self,
            from: #"""
            {"type":"windows","windows":[
              {"id":"split-window","activeTabId":"tab-early","layout":{"type":"split","dir":"v","ratio":0.4,"children":[
                {"type":"pane","tabs":[{"id":"editor-1","kind":"editor","path":"README.md"}],"active":0},
                {"type":"pane","tabs":[{"id":"tab-early","kind":"session","sessionId":"early"}],"active":0}
              ]}},
              {"id":"duplicate","layout":{"type":"pane","tabs":[{"id":"another-early","kind":"session","sessionId":"early"}],"active":0}},
              {"id":"stale","layout":{"type":"pane","tabs":[{"id":"tab-stale","kind":"session","sessionId":"stale"}],"active":0}}
            ],"activeWindowId":"split-window"}
            """#
        )
        let reconciled = WorkspaceLayoutReconciler.reconcile(
            persisted: persisted,
            sessionIds: ["early", "late"],
            preferredSessionId: "late"
        )

        XCTAssertEqual(
            reconciled.windows.flatMap { WorkspaceLayoutReconciler.sessionIds(in: $0.layout) }
                .filter { $0 == "early" }.count,
            1
        )
        XCTAssertFalse(
            reconciled.windows.flatMap { WorkspaceLayoutReconciler.sessionIds(in: $0.layout) }
                .contains("stale")
        )
        XCTAssertTrue(
            reconciled.windows.flatMap { WorkspaceLayoutReconciler.tabs(in: $0.layout) }
                .contains { if case .editor = $0 { return true }; return false }
        )
        guard case .split = reconciled.windows.first?.layout else {
            return XCTFail("The original split should remain intact")
        }
        XCTAssertEqual(
            WorkspaceLayoutReconciler.activeSessionId(
                in: reconciled,
                validSessionIds: ["early", "late"]
            ),
            "late"
        )
        XCTAssertEqual(
            reconciled.windows.flatMap { WorkspaceLayoutReconciler.sessionIds(in: $0.layout) }
                .filter { $0 == "late" }.count,
            1
        )
    }

    func testOpeningEmptyTaskPerformsNoCreateRequest() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-empty")
        let task = try task(id: "task-empty", workspaceId: workspace.id)
        service.taskDetails[task.id] = try taskDetail(
            id: task.id,
            workspaceId: workspace.id,
            sessions: []
        )
        let store = WorkspaceStore(api: service, serverID: "server-empty")

        await store.openTask(workspace: workspace, task: task)

        guard case .empty(let detail) = store.taskState else {
            return XCTFail("An empty task must remain in its welcome state")
        }
        XCTAssertTrue(detail.sessions.isEmpty)
        XCTAssertEqual(service.createRequests.count, 0)
        XCTAssertNil(store.visibleSessionID)
    }

    func testTaskAutoSelectionSkipsArchivedSessions() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-archive")
        let task = try task(id: "task-archive", workspaceId: workspace.id)
        let archived = try decode(WorkspaceSessionSummary.self, from: #"{"id":"archived","startedAt":"2020","archived":true}"#)
        let active = try decode(WorkspaceSessionSummary.self, from: #"{"id":"active","startedAt":"2026"}"#)
        service.taskDetails[task.id] = try taskDetail(id: task.id, workspaceId: workspace.id, sessions: [archived, active])
        service.sessions["active"] = try decode(SessionSnapshot.self, from: #"{"id":"active","sessionKind":"structured","status":"idle"}"#)
        let store = WorkspaceStore(api: service, serverID: "archive")

        await store.openTask(workspace: workspace, task: task)

        XCTAssertEqual(store.visibleSessionID, "active")
        XCTAssertEqual(store.taskState.detail?.sessions.count, 2, "Archived identities remain available for restore")
    }

    func testAllArchivedTaskStaysEmptyUntilExplicitArchivedSelection() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-archive")
        let task = try task(id: "task-archive", workspaceId: workspace.id)
        let archived = try decode(WorkspaceSessionSummary.self, from: #"{"id":"archived","archived":true}"#)
        service.taskDetails[task.id] = try taskDetail(id: task.id, workspaceId: workspace.id, sessions: [archived])
        service.sessions["archived"] = try decode(SessionSnapshot.self, from: #"{"id":"archived","sessionKind":"structured","archived":true,"status":"idle"}"#)
        let store = WorkspaceStore(api: service, serverID: "archive")

        await store.openTask(workspace: workspace, task: task)
        guard case .empty = store.taskState else { return XCTFail("Archived-only tasks must not auto-open hidden sessions") }
        XCTAssertNil(store.visibleSessionID)
        await store.openTask(workspace: workspace, task: task, preferredSessionId: "archived")
        XCTAssertEqual(store.visibleSessionID, "archived", "Explicit archived selection remains readable")
    }

    func testRapidTaskSwitchDropsOlderResponse() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-race")
        let slow = try task(id: "task-slow", workspaceId: workspace.id)
        let fast = try task(id: "task-fast", workspaceId: workspace.id)
        service.taskDetails[slow.id] = try taskDetail(
            id: slow.id,
            workspaceId: workspace.id,
            sessions: [summary(id: "slow-session", startedAt: nil)]
        )
        service.taskDetails[fast.id] = try taskDetail(
            id: fast.id,
            workspaceId: workspace.id,
            sessions: []
        )
        service.taskDelays[slow.id] = 120_000_000
        let store = WorkspaceStore(api: service, serverID: "server-race")

        let first = Task { await store.openTask(workspace: workspace, task: slow) }
        while !service.taskRequestIds.contains(slow.id) { await Task.yield() }
        await store.openTask(workspace: workspace, task: fast)
        await first.value

        XCTAssertEqual(store.currentTask?.id, fast.id)
        guard case .empty(let detail) = store.taskState else {
            return XCTFail("The fast task response should own the final state")
        }
        XCTAssertEqual(detail.id, fast.id)
        XCTAssertNil(store.visibleSessionID)
    }

    func testLayoutSaveFailureKeepsCreatedSessionAndWarning() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-create")
        let task = try task(id: "task-create", workspaceId: workspace.id)
        service.taskDetails[task.id] = try taskDetail(
            id: task.id,
            workspaceId: workspace.id,
            sessions: []
        )
        service.createdSnapshot = try decode(
            SessionSnapshot.self,
            from: #"{"id":"created","sessionKind":"pty","provider":"qoder","cwd":"/task/worktree","workspaceId":"workspace-create","workspaceTaskId":"task-create"}"#
        )
        service.saveError = MockWorkspaceService.MockError.layoutDenied
        let store = WorkspaceStore(api: service, serverID: "server-create")
        await store.openTask(workspace: workspace, task: task)
        store.presentTargetPicker()
        store.selectedTarget = .qoder

        await store.createSelectedWindow(expectedTaskId: task.id)

        XCTAssertEqual(service.createRequests.first?.target, .qoder)
        XCTAssertEqual(service.createRequests.first?.binding.workspaceId, workspace.id)
        XCTAssertEqual(service.createRequests.first?.binding.workspaceTaskId, task.id)
        XCTAssertEqual(service.createRequests.first?.binding.cwd, "/task/worktree")
        XCTAssertEqual(store.visibleSessionID, "created")
        XCTAssertEqual(store.visibleSnapshot?.id, "created")
        XCTAssertNotNil(store.layoutWarning)
        XCTAssertNil(store.creationError)
        guard case .ready(let detail) = store.taskState else {
            return XCTFail("A layout PUT failure must not roll back the created session")
        }
        XCTAssertEqual(detail.sessions.map(\.id), ["created"])
    }

    func testTargetPickerSelectsShellAndCreatesPtyWindow() async throws {
        // 「空白终端」曾是死按钮：rememberCreationChoice 为不覆盖服务端默认 CLI 而跳过 shell，
        // 连带本地 selectedTarget 也不更新，目标选择器里点它没有任何反应。
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-shell")
        let task = try task(id: "task-shell", workspaceId: workspace.id)
        service.taskDetails[task.id] = try taskDetail(
            id: task.id,
            workspaceId: workspace.id,
            sessions: []
        )
        service.createdSnapshot = try decode(
            SessionSnapshot.self,
            from: #"{"id":"shell-window","sessionKind":"pty","provider":"","cwd":"/task/worktree","workspaceId":"workspace-shell","workspaceTaskId":"task-shell"}"#
        )
        let store = WorkspaceStore(api: service, serverID: "server-shell")
        await store.openTask(workspace: workspace, task: task)
        store.presentTargetPicker()

        store.rememberCreationChoice(provider: .shell, kind: .structured)
        XCTAssertEqual(store.selectedTarget, .shell)
        XCTAssertEqual(store.selectedKind, .structured)

        await store.createSelectedWindow(expectedTaskId: task.id)

        XCTAssertEqual(service.createRequests.first?.target, .shell)
        XCTAssertEqual(service.createRequests.first?.kind, .pty)
        XCTAssertEqual(store.visibleSessionID, "shell-window")
    }

    func testRememberCreationChoiceKeepsNonShellProvider() async throws {
        let service = MockWorkspaceService()
        let store = WorkspaceStore(api: service, serverID: "server-choice")

        store.rememberCreationChoice(provider: .grok, kind: .pty)
        XCTAssertEqual(store.selectedTarget, .grok)
        XCTAssertEqual(store.selectedKind, .pty)
    }

    func testCreateFirstTaskWindowSendsPromptAndActivatesSessionOnOpen() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-first")
        let task = try task(id: "task-first", workspaceId: workspace.id)
        service.taskDetails[task.id] = try taskDetail(
            id: task.id,
            workspaceId: workspace.id,
            sessions: []
        )
        service.createdSnapshot = try decode(
            SessionSnapshot.self,
            from: #"{"id":"first-window","sessionKind":"structured","provider":"codex","cwd":"/task/worktree","workspaceId":"workspace-first","workspaceTaskId":"task-first"}"#
        )
        let store = WorkspaceStore(api: service, serverID: "server-first")

        let created = try await store.createFirstTaskWindow(
            taskId: task.id,
            target: .codex,
            kind: .structured,
            prompt: "把侧栏重构一遍"
        )

        XCTAssertEqual(created.id, "first-window")
        XCTAssertEqual(service.createRequests.count, 1)
        XCTAssertEqual(service.createRequests.first?.target, .codex)
        XCTAssertEqual(service.createRequests.first?.binding.workspaceTaskId, task.id)
        XCTAssertEqual(service.createRequests.first?.binding.cwd, "/task/worktree")
        XCTAssertEqual(service.createRequests.first?.prompt, "把侧栏重构一遍")
        // 首个会话必须成为任务里的活动窗口，打开任务时直接落在它身上。
        let savedLayout = service.taskDetails[task.id]?.layout
        let activeWindow = savedLayout?.windows.first { $0.id == savedLayout?.activeWindowId }
        XCTAssertEqual(
            activeWindow.map { WorkspaceLayoutReconciler.sessionIds(in: $0.layout) } ?? [],
            ["first-window"]
        )

        await store.openTask(workspace: workspace, task: task)
        XCTAssertEqual(store.visibleSessionID, "first-window")
        XCTAssertEqual(store.visibleSnapshot?.id, "first-window")
        XCTAssertEqual(service.createRequests.count, 1)
    }

    func testOpenTaskNeverCreatesSessionsImplicitly() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-existing")
        let task = try task(id: "task-existing", workspaceId: workspace.id)
        service.taskDetails[task.id] = try taskDetail(
            id: task.id,
            workspaceId: workspace.id,
            sessions: [summary(id: "already-open", startedAt: "2026-08-09T00:00:01Z")]
        )
        service.sessions["already-open"] = try decode(
            SessionSnapshot.self,
            from: #"{"id":"already-open","sessionKind":"structured","provider":"claude"}"#
        )
        let store = WorkspaceStore(api: service, serverID: "server-existing")

        await store.openTask(workspace: workspace, task: task)

        // 新建任务才会启动首个会话；打开已有任务不该再凭空造一个终端。
        XCTAssertTrue(service.createRequests.isEmpty)
        XCTAssertEqual(store.visibleSessionID, "already-open")
        XCTAssertEqual(store.visibleSnapshot?.id, "already-open")
    }

    func testScheduledSessionSelectionAppliesOnNextOpenOfThatTaskOnly() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-schedule")
        let task = try task(id: "task-schedule", workspaceId: workspace.id)
        service.taskDetails[task.id] = try taskDetail(
            id: task.id,
            workspaceId: workspace.id,
            sessions: [
                summary(id: "window-a", startedAt: "2026-08-09T00:00:01Z"),
                summary(id: "window-b", startedAt: "2026-08-09T00:00:02Z"),
            ]
        )
        service.sessions["window-a"] = try decode(
            SessionSnapshot.self,
            from: #"{"id":"window-a","sessionKind":"structured","provider":"claude"}"#
        )
        service.sessions["window-b"] = try decode(
            SessionSnapshot.self,
            from: #"{"id":"window-b","sessionKind":"structured","provider":"claude"}"#
        )
        let store = WorkspaceStore(api: service, serverID: "server-schedule")
        store.scheduleAutoSelectSession(taskId: "another-task", sessionId: "window-b")

        // 给别的任务排的选择不能影响这次打开。
        await store.openTask(workspace: workspace, task: task)
        XCTAssertEqual(store.visibleSessionID, "window-a")

        store.scheduleAutoSelectSession(taskId: task.id, sessionId: "window-b")
        await store.openTask(workspace: workspace, task: task)
        XCTAssertEqual(store.visibleSessionID, "window-b")
        XCTAssertEqual(store.visibleSnapshot?.id, "window-b")
        XCTAssertTrue(service.createRequests.isEmpty)
    }

    func testTaskGroupsPageDecodesArrayAndRevisionEnvelope() throws {
        let arrayJSON = "[{\"workspaceId\":\"ws\",\"workspaceName\":\"Wand\",\"workspaceCwd\":\"/repo\",\"synthetic\":false,\"tasks\":[],\"standaloneSessions\":[]}]"
        let arrayPage = try TaskGroupsPage.decode(from: Data(arrayJSON.utf8))
        XCTAssertEqual(arrayPage.groups.count, 1)
        XCTAssertFalse(arrayPage.unchanged)
        XCTAssertNil(arrayPage.revision)

        let unchanged = try TaskGroupsPage.decode(from: Data("{\"unchanged\":true,\"revision\":\"rev-2\",\"groups\":[]}".utf8))
        XCTAssertTrue(unchanged.unchanged)
        XCTAssertEqual(unchanged.revision, "rev-2")
        XCTAssertTrue(unchanged.groups.isEmpty)
    }

    func testTaskWorkspaceBindingPrefersTaskIdOverSyntheticGroup() throws {
        let summary = try decode(
            WorkspaceTaskSummary.self,
            from: "{\"id\":\"task-1\",\"workspaceId\":\"real-ws\",\"name\":\"Task\",\"worktree\":null,\"layout\":null,\"status\":\"active\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"lastOpenedAt\":null,\"cwd\":\"/repo/task\",\"isolated\":false,\"worktreeError\":null,\"sessions\":[]}"
        )
        XCTAssertEqual(summary.asTask().workspaceId, "real-ws")
    }

    func testReopeningTaskKeepsTheLastActiveWindowWithoutCreatingSessions() async throws {
        let service = MockWorkspaceService()
        let workspace = try workspace(id: "workspace-dup")
        let task = try task(id: "task-dup", workspaceId: workspace.id)
        service.taskDetails[task.id] = try taskDetail(
            id: task.id,
            workspaceId: workspace.id,
            sessions: [summary(id: "dup-window", startedAt: "2026-08-09T00:00:01Z")]
        )
        service.sessions["dup-window"] = try decode(
            SessionSnapshot.self,
            from: #"{"id":"dup-window","sessionKind":"structured","provider":"claude"}"#
        )
        let store = WorkspaceStore(api: service, serverID: "server-dup")

        await store.openTask(workspace: workspace, task: task)
        await store.openTask(workspace: workspace, task: task)

        XCTAssertTrue(service.createRequests.isEmpty)
        XCTAssertEqual(store.visibleSessionID, "dup-window")
        XCTAssertEqual(store.visibleSnapshot?.sessionKind, "structured")
        XCTAssertTrue(store.visibleSnapshot?.isStructured == true)
    }

    private func workspace(id: String) throws -> Workspace {
        try decode(
            Workspace.self,
            from: "{\"id\":\"\(id)\",\"name\":\"Wand\",\"cwd\":\"/repo\",\"defaultProvider\":\"claude\",\"layout\":null,\"createdAt\":\"2026-08-09T00:00:00Z\",\"lastOpenedAt\":null}"
        )
    }

    private func task(id: String, workspaceId: String) throws -> WorkspaceTask {
        try decode(
            WorkspaceTask.self,
            from: "{\"id\":\"\(id)\",\"workspaceId\":\"\(workspaceId)\",\"name\":\"Task\",\"worktree\":null,\"layout\":null,\"status\":\"active\",\"createdAt\":\"2026-08-09T00:00:00Z\",\"lastOpenedAt\":null}"
        )
    }

    private func taskDetail(
        id: String,
        workspaceId: String,
        sessions: [WorkspaceSessionSummary]
    ) throws -> WorkspaceTaskDetail {
        let sessionData = try JSONEncoder().encode(sessions)
        let sessionJSON = String(data: sessionData, encoding: .utf8) ?? "[]"
        return try decode(
            WorkspaceTaskDetail.self,
            from: "{\"id\":\"\(id)\",\"workspaceId\":\"\(workspaceId)\",\"name\":\"Task\",\"worktree\":null,\"layout\":null,\"status\":\"active\",\"createdAt\":\"2026-08-09T00:00:00Z\",\"lastOpenedAt\":null,\"cwd\":\"/task/worktree\",\"sessions\":\(sessionJSON)}"
        )
    }

    private func summary(id: String, startedAt: String?) -> WorkspaceSessionSummary {
        let timestamp = startedAt.map { "\"\($0)\"" } ?? "null"
        return try! decode(
            WorkspaceSessionSummary.self,
            from: "{\"id\":\"\(id)\",\"provider\":\"claude\",\"startedAt\":\(timestamp)}"
        )
    }

    private func group(
        id: String,
        cwd: String,
        taskID: String,
        createdAt: String = "2026-01-01T00:00:00Z",
        lastOpenedAt: String?,
        sessionStatus: String? = nil
    ) throws -> TaskDirectoryGroup {
        let session = sessionStatus.map { status in
            "{\"id\":\"session-\(taskID)\",\"provider\":\"claude\",\"sessionKind\":\"structured\",\"status\":\"\(status)\",\"inFlight\":true}"
        } ?? "{\"id\":\"session-\(taskID)\",\"provider\":\"claude\"}"
        let opened = lastOpenedAt.map { "\"\($0)\"" } ?? "null"
        return try decode(
            TaskDirectoryGroup.self,
            from: "{\"workspaceId\":\"\(id)\",\"workspaceName\":\"\(id)\",\"workspaceCwd\":\"\(cwd)\",\"createdAt\":\"\(createdAt)\",\"synthetic\":false,\"tasks\":[{\"id\":\"\(taskID)\",\"workspaceId\":\"\(id)\",\"name\":\"Task\",\"worktree\":null,\"layout\":null,\"status\":\"active\",\"createdAt\":\"\(createdAt)\",\"lastOpenedAt\":\(opened),\"cwd\":\"\(cwd)\",\"isolated\":false,\"worktreeError\":null,\"sessions\":[\(session)],\"totalSessions\":1}],\"standaloneSessions\":[]}"
        )
    }


    func testDirectorySummaryUsesLiveStateAndDoesNotCountArchivedActivity() throws {
        let sessions = try decode([WorkspaceSessionSummary].self, from: #"[{"id":"run","inFlight":true},{"id":"run","inFlight":true},{"id":"wait","permissionBlocked":true},{"id":"old","inFlight":true,"archived":true}]"#)
        XCTAssertEqual(HomePresentation.sessionSummary(sessions), "3 个会话 · 1 在跑 · 1 等你")
        XCTAssertEqual(HomePresentation.sessionSummary(sessions, total: 9), "9 个会话 · 1 在跑 · 1 等你")
        XCTAssertEqual(HomePresentation.sessionSummary([]), "0 个会话")
    }

    /// Renders the actual List and owns no real session or model execution.
    func testWorkspaceDirectoryLayout() async throws {
        let service = MockWorkspaceService()
        let fixture = #"[{"workspaceId":"layout-w","workspaceName":"Wand 移动端","workspaceCwd":"/Users/example/Projects/wand","tasks":[{"id":"layout-task","workspaceId":"layout-w","name":"优化目录与会话层级，保留长标题的可读性","cwd":"/Users/example/Projects/wand","status":"active","createdAt":"","totalSessions":3,"sessions":[{"id":"layout-session","title":"验证目录展开与状态显示","provider":"codex","sessionKind":"structured","inFlight":true},{"id":"layout-wait","title":"等待确认的会话","provider":"pi","sessionKind":"pty","permissionBlocked":true},{"id":"layout-archive","title":"已归档的历史会话","provider":"pi","archived":true}]},{"id":"layout-empty-task","workspaceId":"layout-w","name":"第二个任务","cwd":"/Users/example/Projects/wand","status":"active","createdAt":"","sessions":[]}],"standaloneSessions":[{"id":"layout-loose","title":"未分组的独立会话","provider":"codex","sessionKind":"structured"}]},{"workspaceId":"layout-other","workspaceName":"Wand 移动端","workspaceCwd":"/Volumes/Other/Archive/wand","tasks":[],"standaloneSessions":[]},{"workspaceId":"wand-global","workspaceName":"global","workspaceCwd":"/private/internal","global":true,"tasks":[],"standaloneSessions":[{"id":"layout-global","title":"未归属的会话","provider":"pi"}]}]"#
        service.directoryGroups = try decode([TaskDirectoryGroup].self, from: fixture)
        service.workspaces = service.directoryGroups.filter(\.isBindableProject).map {
            Workspace(id: $0.id, name: $0.workspaceName, cwd: $0.workspaceCwd, defaultProvider: nil, layout: nil, createdAt: "", lastOpenedAt: nil)
        }
        var api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        var store = WorkspaceStore(api: service, serverID: "layout-fixture")
        await store.loadWorkspaceIndex(); await store.loadTaskGroups(force: true)
        let collapseKinds = ["groups", "tasks", "loose"]
        let priorCollapsed = collapseKinds.map { TaskListExpansionStorage.collapsedIds(kind: $0) }
        for kind in collapseKinds { TaskListExpansionStorage.setCollapsedIds([], kind: kind) }
        let keys = ["wand.homeFold.recent", "wand.homeFold.workspaces"]
        let prior = keys.map { UserDefaults.standard.object(forKey: $0) }
        UserDefaults.standard.set("collapse", forKey: keys[0]); UserDefaults.standard.set("expand", forKey: keys[1])
        defer {
            store.stopTaskGroupsSync()
            for (kind, ids) in zip(collapseKinds, priorCollapsed) { TaskListExpansionStorage.setCollapsedIds(ids, kind: kind) }
            for (key, value) in zip(keys, prior) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        var openedTasks = 0, openedSessions = 0, openedTaskSessions = 0, newSessions = 0
        let touching = ProcessInfo.processInfo.environment["WAND_DIRECTORY_TOUCH"] == "1"
        let installed = ProcessInfo.processInfo.environment["WAND_DIRECTORY_INSTALLED"] == "1"
        let installedPointer = URL(fileURLWithPath: "/tmp/wand-ios-directory-installed-profile-path")
        if installed {
            struct Profile: Decodable { let serverURL: String; let connectionCode: String }
            let path = try String(contentsOf: installedPointer, encoding: .utf8)
            let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let connection = try XCTUnwrap(WandAuth.decodeConnectCode(profile.connectionCode))
            api = WandAPI(baseURL: connection.url, token: connection.token)
            store = WorkspaceStore(api: api, serverID: "layout-installed-read-only")
            await store.loadWorkspaceIndex(); await store.loadTaskGroups(force: true)
            XCTAssertFalse(store.taskGroups.isEmpty)
        }
        let variants: [(String, CGSize, ColorScheme, ContentSizeCategory)] = touching || installed
            ? [(touching ? "touch" : "installed", CGSize(width: 440, height: 956), .light, .large)]
            : [("phone-light", CGSize(width: 390, height: 1000), .light, .large),
               ("phone-dark", CGSize(width: 390, height: 1000), .dark, .large),
               ("narrow", CGSize(width: 320, height: 1000), .light, .large),
               ("large-type", CGSize(width: 390, height: 1100), .light, .accessibilityExtraExtraLarge),
               ("tablet", CGSize(width: 768, height: 1100), .light, .large)]
        for (name, size, scheme, type) in variants {
            let list = WorkspaceListView(store: store, api: api, selectedTaskId: "layout-task", selectedSessionId: "layout-session",
                hidesHomeChrome: true, isSelecting: .constant(false), onOpenTask: { _, _ in openedTasks += 1 },
                onOpenSession: { _, _ in openedSessions += 1 }, onOpenTaskSession: { _, _, _ in openedTaskSessions += 1 },
                onRequestNewSession: { _, _ in newSessions += 1 })
            let host = UIHostingController(rootView: ScrollViewReader { proxy in
                NavigationStack { list }
                    .task {
                        try? await Task.sleep(for: .milliseconds(180))
                        if let first = TaskListPresentation.orderedDirectoryGroups(store.taskGroups).first { proxy.scrollTo("workspace-directory-" + first.id, anchor: .top) }
                    }
            }.environment(\.colorScheme, scheme).environment(\.sizeCategory, type))
            host.traitOverrides.horizontalSizeClass = size.width > 600 ? .regular : .compact
            host.traitOverrides.userInterfaceStyle = scheme == .dark ? .dark : .light
            host.traitOverrides.preferredContentSizeCategory = type == .accessibilityExtraExtraLarge ? .accessibilityExtraExtraLarge : .large
            let window: UIWindow
            if touching || installed {
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                window = UIWindow(windowScene: scene)
            } else {
                window = UIWindow(frame: CGRect(origin: .zero, size: size))
            }
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(450))
            if touching {
                let done = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/directory-touch-done")
                try? FileManager.default.removeItem(at: done)
                for _ in 0..<120 {
                    if FileManager.default.fileExists(atPath: done.path) { break }
                    try await Task.sleep(for: .seconds(1))
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "External native touch driver did not finish")
                XCTAssertEqual(openedTasks, 1); XCTAssertEqual(openedSessions, 1)
                XCTAssertEqual(openedTaskSessions, 1); XCTAssertEqual(newSessions, 1)
            }
            let image = UIGraphicsImageRenderer(size: size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "directory-layout-" + name; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(image.size, size)
            window.isHidden = true
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(json.data(using: .utf8)))
    }
}

@MainActor
private final class MockWorkspaceService: WorkspaceServing {
    /// 归档 / 刚完成确认的记录：这两类调用不能靠返回值推断，只能看实际请求。
    var archivedSessionRequests: [(ids: [String], archived: Bool)] = []
    var completionViewRequests: [(sessionId: String, revision: Int)] = []
    struct CreateRequest {
        let target: WorkspaceSessionTarget
        let binding: WorkspaceBinding
        let kind: WorkspaceSessionKind
        let prompt: String?
    }

    struct MoveRequest {
        let taskId: String
        let sessionId: String
    }

    enum MockError: LocalizedError {
        case missingTask
        case missingSession
        case createUnavailable
        case layoutDenied

        var errorDescription: String? {
            switch self {
            case .missingTask: return "Task missing"
            case .missingSession: return "Session missing"
            case .createUnavailable: return "Create unavailable"
            case .layoutDenied: return "Layout denied"
            }
        }
    }

    var workspaces: [Workspace] = []
    var directoryGroups: [TaskDirectoryGroup] = []
    var tasks: [String: [WorkspaceTask]] = [:]
    var taskDetails: [String: WorkspaceTaskDetail] = [:]
    var taskDelays: [String: UInt64] = [:]
    var taskRequestIds: [String] = []
    var sessions: [String: SessionSnapshot] = [:]
    var createRequests: [CreateRequest] = []
    var moveRequests: [MoveRequest] = []
    var archiveRequests: [String] = []
    var directoryRenames: [(path: String, name: String)] = []
    var createdSnapshot: SessionSnapshot?
    var saveError: Error?

    func listWorkspaces() async throws -> [Workspace] { workspaces }

    func listWorkspaceTasks(workspaceId: String) async throws -> [WorkspaceTask] {
        tasks[workspaceId] ?? []
    }

    func updateWorkspaceTask(taskId: String, name: String?) async throws -> WorkspaceTask {
        for (workspaceId, list) in tasks {
            if let index = list.firstIndex(where: { $0.id == taskId }) {
                let current = list[index]
                let updated = WorkspaceTask(
                    id: current.id,
                    workspaceId: current.workspaceId,
                    name: name ?? current.name,
                    worktree: current.worktree,
                    layout: current.layout,
                    status: current.status,
                    createdAt: current.createdAt,
                    lastOpenedAt: current.lastOpenedAt
                )
                tasks[workspaceId]?[index] = updated
                return updated
            }
        }
        throw MockError.missingTask
    }

    func deleteWorkspaceTask(taskId: String) async throws {
        for (workspaceId, list) in tasks {
            if list.contains(where: { $0.id == taskId }) {
                tasks[workspaceId] = list.filter { $0.id != taskId }
                taskDetails.removeValue(forKey: taskId)
                return
            }
        }
    }

    func getWorkspaceTask(taskId: String) async throws -> WorkspaceTaskDetail {
        taskRequestIds.append(taskId)
        if let delay = taskDelays[taskId] { try await Task.sleep(nanoseconds: delay) }
        guard let detail = taskDetails[taskId] else { throw MockError.missingTask }
        return detail
    }

    func saveWorkspaceTaskLayout(
        taskId: String,
        layout: TaskWindowLayout?
    ) async throws -> TaskWindowLayout? {
        if let saveError { throw saveError }
        if let detail = taskDetails[taskId] {
            taskDetails[taskId] = detail.replacing(layout: layout)
        }
        return layout
    }

    func createWorkspaceTaskWindow(
        target: WorkspaceSessionTarget,
        binding: WorkspaceBinding,
        kind: WorkspaceSessionKind,
        prompt: String?,
        mode: String?,
        model: String?,
        thinkingEffort: String?
    ) async throws -> SessionSnapshot {
        createRequests.append(
            CreateRequest(target: target, binding: binding, kind: kind, prompt: prompt)
        )
        guard let createdSnapshot else { throw MockError.createUnavailable }
        sessions[createdSnapshot.id] = createdSnapshot
        if let detail = taskDetails[binding.workspaceTaskId] {
            var summaries = detail.sessions
            summaries.append(WorkspaceSessionSummary(snapshot: createdSnapshot))
            taskDetails[binding.workspaceTaskId] = detail.replacing(
                layout: detail.layout,
                sessions: summaries
            )
        }
        return createdSnapshot
    }

    func archiveWorkspaceTask(taskId: String) async throws -> WorkspaceTask {
        archiveRequests.append(taskId)
        guard let detail = taskDetails[taskId] else { throw MockError.missingTask }
        for (workspaceId, list) in tasks {
            if let index = list.firstIndex(where: { $0.id == taskId }) {
                tasks[workspaceId]?.remove(at: index)
                break
            }
        }
        taskDetails.removeValue(forKey: taskId)
        return WorkspaceTask(
            id: detail.id,
            workspaceId: detail.workspaceId,
            name: detail.name,
            worktree: detail.worktree,
            layout: detail.layout,
            status: "done",
            createdAt: detail.createdAt,
            lastOpenedAt: detail.lastOpenedAt
        )
    }

    func renameSessionDirectory(path: String, name: String) async throws {
        directoryRenames.append((path, name))
    }

    func moveWorkspaceSession(taskId: String, sessionId: String) async throws {
        moveRequests.append(MoveRequest(taskId: taskId, sessionId: sessionId))
        guard let target = taskDetails[taskId] else { throw MockError.missingTask }
        var moved: WorkspaceSessionSummary?
        for (id, detail) in taskDetails where id != taskId {
            guard let summary = detail.sessions.first(where: { $0.id == sessionId }) else { continue }
            moved = summary
            taskDetails[id] = detail.replacing(
                layout: detail.layout,
                sessions: detail.sessions.filter { $0.id != sessionId }
            )
            break
        }
        guard let moved else { throw MockError.missingSession }
        var sessions = target.sessions.filter { $0.id != sessionId }
        sessions.append(moved)
        taskDetails[taskId] = target.replacing(layout: target.layout, sessions: sessions)
    }

    func getSession(id: String, blockBudget: Int) async throws -> SessionSnapshot {
        guard let session = sessions[id] else { throw MockError.missingSession }
        return session
    }

    func workspaceDefaultProvider() async throws -> WandProvider { .claude }

    func getWorkspaceDetail(workspaceId: String) async throws -> WorkspaceDetail {
        throw MockError.missingTask
    }

    func createWorkspace(
        name: String,
        cwd: String,
        defaultProvider: WandProvider?
    ) async throws -> Workspace {
        throw MockError.createUnavailable
    }

    func updateWorkspace(workspaceId: String, name: String) async throws -> Workspace {
        throw MockError.missingTask
    }

    func deleteWorkspace(workspaceId: String) async throws {
        throw MockError.missingTask
    }

    func createWorkspaceTask(
        workspaceId: String,
        name: String,
        baseRef: String?,
        worktree: Bool?,
        cwd: String?,
        description: String?,
        parentTaskId: String?,
        creationRequestId: String?
    ) async throws -> WorkspaceTaskCreation {
        throw MockError.createUnavailable
    }

    func createStandaloneTask(
        name: String,
        cwd: String?,
        worktree: Bool?,
        description: String?,
        parentTaskId: String?,
        creationRequestId: String?
    ) async throws -> WorkspaceTaskCreation {
        throw MockError.createUnavailable
    }

    func listTaskGroups() async throws -> [TaskDirectoryGroup] {
        directoryGroups
    }

    func listTaskGroupsPage(revision: String?) async throws -> TaskGroupsPage {
        TaskGroupsPage(groups: directoryGroups, revision: revision, unchanged: false)
    }

    func deleteWorkspaceSessions(sessionIds: [String]) async throws -> Int {
        sessionIds.count
    }

    func batchArchiveWorkspaceSessions(sessionIds: [String], archived: Bool) async throws -> [String] {
        archivedSessionRequests.append((sessionIds, archived))
        return []
    }

    func archiveWorkspaceSession(sessionId: String, archived: Bool) async throws {
        archivedSessionRequests.append(([sessionId], archived))
    }

    func markSessionCompletionViewed(
        sessionId: String,
        completionRevision: Int
    ) async throws -> SessionCompletionResponse {
        completionViewRequests.append((sessionId, completionRevision))
        return SessionCompletionResponse(completionRevision: completionRevision, viewedCompletionRevision: completionRevision)
    }

    func workspaceWorktreeOverview(workspaceId: String) async throws -> WorkspaceWorktreeOverview {
        throw MockError.missingTask
    }

    func startWorktreeMergeAgent(
        workspace: Workspace,
        provider: WandProvider,
        prompt: String
    ) async throws -> SessionSnapshot {
        throw MockError.createUnavailable
    }
}
