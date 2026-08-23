import Foundation
import XCTest
@testable import Wand

@MainActor
final class WorkspaceTests: XCTestCase {
    func testTaskListPresentationShortensPathsAndAvoidsSharedDirectoryLabel() {
        XCTAssertEqual(
            TaskListPresentation.shortenWorkspacePath("/Users/me/Self/vibe_coding/wand"),
            "…/vibe_coding/wand"
        )
        XCTAssertEqual(
            TaskListPresentation.directoryPathCaption(name: "wand", cwd: "/Users/me/Self/vibe_coding/wand"),
            "…/vibe_coding/wand"
        )
        XCTAssertEqual(TaskListPresentation.taskIsolationCaption(isolated: false), "共享")
        XCTAssertEqual(
            TaskListPresentation.listSessionLabel(
                title: "wand",
                providerLabel: "Pi",
                cwd: "/Users/me/wand",
                index: 0,
                parentNames: ["wand"]
            ),
            "Pi 1"
        )
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
            XCTAssertEqual(pty.path, "/api/commands")
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
                XCTAssertEqual(structured.path, "/api/structured-sessions")
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

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(json.data(using: .utf8)))
    }
}

@MainActor
private final class MockWorkspaceService: WorkspaceServing {
    struct CreateRequest {
        let target: WorkspaceSessionTarget
        let binding: WorkspaceBinding
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
    var tasks: [String: [WorkspaceTask]] = [:]
    var taskDetails: [String: WorkspaceTaskDetail] = [:]
    var taskDelays: [String: UInt64] = [:]
    var taskRequestIds: [String] = []
    var sessions: [String: SessionSnapshot] = [:]
    var createRequests: [CreateRequest] = []
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
        kind: WorkspaceSessionKind
    ) async throws -> SessionSnapshot {
        createRequests.append(CreateRequest(target: target, binding: binding))
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
        worktree: Bool?
    ) async throws -> WorkspaceTaskCreation {
        throw MockError.createUnavailable
    }

    func listTaskGroups() async throws -> [TaskDirectoryGroup] {
        []
    }

    func deleteWorkspaceSessions(sessionIds: [String]) async throws -> Int {
        sessionIds.count
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
