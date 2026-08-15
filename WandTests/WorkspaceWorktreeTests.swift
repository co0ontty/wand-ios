import XCTest
@testable import Wand

@MainActor
final class WorkspaceWorktreeTests: XCTestCase {
    // MARK: - Decoding

    func testWorktreeOverviewDecodesStatesCommitsAndDerivedCopy() throws {
        let overview = try decode(
            WorkspaceWorktreeOverview.self,
            from: """
            {
              "workspaceId": "ws-1",
              "repoRoot": "/repo",
              "targetBranch": "main",
              "worktrees": [
                {
                  "taskId": "task-a",
                  "taskName": "修复登录",
                  "taskStatus": "active",
                  "branch": "wand/fix-login-a1b2",
                  "path": "/repo/.wand-worktrees/wand-fix-login-a1b2",
                  "baseRef": "main",
                  "state": "ready",
                  "actionable": true,
                  "reason": "",
                  "aheadCount": 3,
                  "hasUncommittedChanges": false,
                  "hasConflicts": false,
                  "commits": [
                    { "hash": "aaaa", "shortHash": "aaaa111", "subject": "修复令牌刷新" },
                    { "hash": "bbbb", "shortHash": "bbbb222", "subject": "补充测试" }
                  ]
                },
                {
                  "taskId": "task-b",
                  "taskName": "重构导航",
                  "taskStatus": "active",
                  "branch": "wand/nav-c3d4",
                  "path": "/repo/.wand-worktrees/wand-nav-c3d4",
                  "baseRef": "",
                  "state": "dirty",
                  "actionable": true,
                  "reason": "",
                  "aheadCount": 0,
                  "hasUncommittedChanges": true,
                  "hasConflicts": false,
                  "commits": []
                },
                {
                  "taskId": "task-c",
                  "taskName": "已同步任务",
                  "taskStatus": "done",
                  "branch": "wand/done-e5f6",
                  "path": "/repo/.wand-worktrees/wand-done-e5f6",
                  "baseRef": "",
                  "state": "empty",
                  "actionable": false,
                  "reason": "",
                  "aheadCount": 0,
                  "hasUncommittedChanges": false,
                  "hasConflicts": false,
                  "commits": []
                },
                {
                  "taskId": "task-d",
                  "taskName": "坏掉的",
                  "taskStatus": "active",
                  "branch": "wand/broken",
                  "path": "/gone",
                  "baseRef": "",
                  "state": "unavailable",
                  "actionable": false,
                  "reason": "worktree 目录不存在",
                  "aheadCount": 0,
                  "hasUncommittedChanges": false,
                  "hasConflicts": false,
                  "commits": []
                }
              ]
            }
            """
        )

        XCTAssertEqual(overview.targetBranch, "main")
        XCTAssertEqual(overview.worktrees.count, 4)
        XCTAssertEqual(overview.actionableWorktrees.map(\.taskId), ["task-a", "task-b"])

        let ready = overview.worktrees[0]
        XCTAssertEqual(ready.stateLabel, "待合并")
        XCTAssertEqual(ready.summary, "修复登录 · 修复令牌刷新")
        XCTAssertEqual(ready.details, "3 commits")
        XCTAssertEqual(ready.commits.count, 2)

        let dirty = overview.worktrees[1]
        XCTAssertEqual(dirty.stateLabel, "有未提交改动")
        // 无 commit 时 summary 退化为任务名。
        XCTAssertEqual(dirty.summary, "重构导航")
        XCTAssertEqual(dirty.details, "工作区有改动")

        XCTAssertEqual(overview.worktrees[2].stateLabel, "已同步")
        XCTAssertEqual(overview.worktrees[2].details, "没有新的待合并改动")
        XCTAssertEqual(overview.worktrees[3].stateLabel, "不可用")
        XCTAssertEqual(overview.worktrees[3].details, "worktree 目录不存在")
    }

    func testWorkspaceDecodesOptionalCounts() throws {
        let withCounts = try decode(
            Workspace.self,
            from: #"{"id":"ws","name":"Wand","cwd":"/repo","defaultProvider":"claude","layout":null,"createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null,"worktreeCount":4,"sessionCount":9}"#
        )
        XCTAssertEqual(withCounts.worktreeCount, 4)
        XCTAssertEqual(withCounts.sessionCount, 9)

        let legacy = try decode(
            Workspace.self,
            from: #"{"id":"ws","name":"Wand","cwd":"/repo","defaultProvider":"claude","layout":null,"createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null}"#
        )
        XCTAssertNil(legacy.worktreeCount)
        XCTAssertNil(legacy.sessionCount)
    }

    func testWorkspaceDetailFiltersStandaloneSessions() throws {
        let detail = try decode(
            WorkspaceDetail.self,
            from: """
            {
              "id": "ws", "name": "Wand", "cwd": "/repo", "defaultProvider": null,
              "layout": null, "createdAt": "2026-08-09T00:00:00Z", "lastOpenedAt": null,
              "worktreeCount": 1, "sessionCount": 3,
              "sessions": [
                { "id": "s1", "provider": "claude", "workspaceTaskId": "task-1" },
                { "id": "s2", "provider": "codex" },
                { "id": "s3", "provider": "qoder", "workspaceTaskId": null },
                { "id": "s4", "provider": "grok" }
              ]
            }
            """
        )
        // 与 web 端一致：过滤掉绑定任务的会话，再倒序展示。
        XCTAssertEqual(detail.standaloneSessions.map(\.id), ["s4", "s3", "s2"])
    }

    // MARK: - Merge prompt

    func testMergePromptFiltersActionableAndKeepsServerRefs() throws {
        let overview = try mergeOverview()
        let workspace = try workspace()
        var selected: Set<String> = ["task-ready", "task-empty", "task-unknown"]
        let prompt = try buildWorkspaceMergeAgentPrompt(
            workspace: workspace,
            overview: overview,
            selectedTaskIds: selected
        )

        XCTAssertTrue(prompt.contains("你是 Wand 为项目「Wand」启动的 Worktree 合并 Agent。"))
        XCTAssertTrue(prompt.contains("唯一目标分支：main"))
        XCTAssertTrue(prompt.contains("项目主工作区：/repo"))
        XCTAssertTrue(prompt.contains("只把清单中的分支合并到 main"))
        // 仅 actionable 的任务进入清单，未知 id 被忽略。
        XCTAssertTrue(prompt.contains(#""task" : "修复登录""#))
        XCTAssertFalse(prompt.contains("已同步任务"))
        XCTAssertTrue(prompt.contains(#""branch" : "wand/fix-login""#))
        XCTAssertTrue(prompt.contains(#""worktreePath" : "/repo/.wand-worktrees/fix""#))
        XCTAssertTrue(prompt.contains(#""commitsAhead" : 3"#))
        XCTAssertTrue(prompt.contains(#""uncommittedChanges" : false"#))
        XCTAssertTrue(prompt.contains(#""修复令牌刷新""#))
        XCTAssertTrue(prompt.contains(#""补充测试""#))
        XCTAssertTrue(prompt.contains("6. 最后汇报每个 Worktree 的提交/合并结果、测试结果，以及任何仍需人工处理的问题。"))

        // 空选择抛出（清掉唯一可合并项）。
        selected = []
        XCTAssertThrowsError(try buildWorkspaceMergeAgentPrompt(
            workspace: workspace,
            overview: overview,
            selectedTaskIds: selected
        ))
    }

    func testMergePromptRequiresTargetBranch() throws {
        var overview = try mergeOverview()
        overview = WorkspaceWorktreeOverview(
            workspaceId: overview.workspaceId,
            repoRoot: overview.repoRoot,
            targetBranch: "",
            worktrees: overview.worktrees
        )
        XCTAssertThrowsError(try buildWorkspaceMergeAgentPrompt(
            workspace: try workspace(),
            overview: overview,
            selectedTaskIds: ["task-ready"]
        )) { error in
            XCTAssertEqual(
                (error as? WorkspaceWorktreeMergeError)?.errorDescription,
                "无法识别项目默认分支。"
            )
        }
    }

    // MARK: - Request construction

    func testWorktreeMergeAgentRequestMatchesManagedCommand() throws {
        let workspace = try workspace()
        let request = worktreeMergeAgentRequest(
            workspace: workspace,
            provider: .qoder,
            prompt: "合并任务书"
        )
        XCTAssertEqual(request.path, "/api/commands")
        XCTAssertEqual(request.body["command"], .string("qodercli"))
        XCTAssertEqual(request.body["provider"], .string("qoder"))
        XCTAssertEqual(request.body["cwd"], .string("/repo"))
        XCTAssertEqual(request.body["mode"], .string("managed"))
        XCTAssertEqual(request.body["initialInput"], .string("合并任务书"))
        XCTAssertEqual(request.body["sessionSource"], .string("interactive"))
        XCTAssertEqual(request.body["workspaceId"], .string("ws-merge"))
        XCTAssertNil(request.body["workspaceTaskId"])
    }

    func testCreateWorkspaceAndTaskRequestConstruction() {
        let createWorkspace = createWorkspaceRequest(
            name: "Wand",
            cwd: "/repo",
            defaultProvider: .grok
        )
        XCTAssertEqual(createWorkspace.path, "/api/workspaces")
        XCTAssertEqual(createWorkspace.body["name"], .string("Wand"))
        XCTAssertEqual(createWorkspace.body["cwd"], .string("/repo"))
        XCTAssertEqual(createWorkspace.body["defaultProvider"], .string("grok"))

        let bareWorkspace = createWorkspaceRequest(name: "Bare", cwd: "/tmp", defaultProvider: nil)
        XCTAssertNil(bareWorkspace.body["defaultProvider"])

        let createTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "修复登录",
            baseRef: nil
        )
        XCTAssertEqual(createTask.path, "/api/workspaces/ws-1/tasks")
        XCTAssertEqual(createTask.body["name"], .string("修复登录"))
        XCTAssertNil(createTask.body["baseRef"])

        let basedTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "修复登录",
            baseRef: "main"
        )
        XCTAssertEqual(basedTask.body["baseRef"], .string("main"))
    }

    // MARK: - Store flows

    func testStartWorktreeMergeAgentPrefersWorkspaceProviderThenServerDefault() async throws {
        let service = MockWorktreeMergeService()
        service.defaultProvider = .opencode
        let store = WorkspaceStore(api: service, serverID: "server-merge")
        // 先加载索引，让 store 记住服务器默认 provider。
        await store.loadWorkspaceIndex()

        let overview = try mergeOverview()
        let withProvider = try workspace(id: "ws-a", defaultProviderJSON: #""grok""#)
        _ = try await store.startWorktreeMergeAgent(
            workspace: withProvider,
            overview: overview,
            selectedTaskIds: ["task-ready"]
        )
        XCTAssertEqual(service.capturedProviders, [.grok])
        XCTAssertTrue(service.capturedPrompts[0].contains("唯一目标分支：main"))

        let withoutProvider = try workspace(id: "ws-b", defaultProviderJSON: "null")
        _ = try await store.startWorktreeMergeAgent(
            workspace: withoutProvider,
            overview: overview,
            selectedTaskIds: ["task-ready"]
        )
        XCTAssertEqual(service.capturedProviders, [.grok, .opencode])
    }

    func testCreateWorkspaceTaskRefreshesTaskListAndReturnsOpenableTask() async throws {
        let service = MockWorktreeMergeService()
        // 刷新后的任务列表里包含新创建的任务（同 id）。
        service.tasks = [try task(id: "task-created", workspaceId: "ws-a")]
        let store = WorkspaceStore(api: service, serverID: "server-task")

        let outcome = try await store.createWorkspaceTask(workspaceId: "ws-a", name: "修复登录")

        XCTAssertEqual(service.createTaskRequests.count, 1)
        XCTAssertEqual(service.createTaskRequests[0].workspaceId, "ws-a")
        XCTAssertEqual(service.createTaskRequests[0].name, "修复登录")
        XCTAssertTrue(outcome.creation.isIsolated)
        XCTAssertEqual(outcome.task.id, "task-created")
        XCTAssertEqual(store.tasks(for: "ws-a").map(\.id), ["task-created"])
    }

    // MARK: - Fixtures

    private func workspace(
        id: String = "ws-merge",
        defaultProviderJSON: String = #""claude""#
    ) throws -> Workspace {
        try decode(
            Workspace.self,
            from: #"{"id":"\#(id)","name":"Wand","cwd":"/repo","defaultProvider":\#(defaultProviderJSON),"layout":null,"createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null}"#
        )
    }

    private func task(id: String, workspaceId: String) throws -> WorkspaceTask {
        try decode(
            WorkspaceTask.self,
            from: #"{"id":"\#(id)","workspaceId":"\#(workspaceId)","name":"修复登录","worktree":{"branch":"wand/fix-login","path":"/repo/.wand-worktrees/fix","baseRef":"main","repoRoot":"/repo"},"layout":null,"status":"active","createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null}"#
        )
    }

    private func mergeOverview() throws -> WorkspaceWorktreeOverview {
        try decode(
            WorkspaceWorktreeOverview.self,
            from: """
            {
              "workspaceId": "ws-merge",
              "repoRoot": "/repo",
              "targetBranch": "main",
              "worktrees": [
                {
                  "taskId": "task-ready",
                  "taskName": "修复登录",
                  "taskStatus": "active",
                  "branch": "wand/fix-login",
                  "path": "/repo/.wand-worktrees/fix",
                  "baseRef": "main",
                  "state": "ready",
                  "actionable": true,
                  "reason": "",
                  "aheadCount": 3,
                  "hasUncommittedChanges": false,
                  "hasConflicts": false,
                  "commits": [
                    { "hash": "aaaa", "shortHash": "aaaa111", "subject": "修复令牌刷新" },
                    { "hash": "bbbb", "shortHash": "bbbb222", "subject": "补充测试" }
                  ]
                },
                {
                  "taskId": "task-empty",
                  "taskName": "已同步任务",
                  "taskStatus": "done",
                  "branch": "wand/done",
                  "path": "/repo/.wand-worktrees/done",
                  "baseRef": "",
                  "state": "empty",
                  "actionable": false,
                  "reason": "",
                  "aheadCount": 0,
                  "hasUncommittedChanges": false,
                  "hasConflicts": false,
                  "commits": []
                }
              ]
            }
            """
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(json.data(using: .utf8)))
    }
}

@MainActor
private final class MockWorktreeMergeService: WorkspaceServing {
    struct CreateTaskRequest {
        let workspaceId: String
        let name: String
        let baseRef: String?
    }

    enum MockError: LocalizedError {
        case unavailable

        var errorDescription: String? { "Unavailable" }
    }

    var defaultProvider: WandProvider = .claude
    var tasks: [WorkspaceTask] = []
    var capturedProviders: [WandProvider] = []
    var capturedPrompts: [String] = []
    var createTaskRequests: [CreateTaskRequest] = []

    private func mergeSnapshot() throws -> SessionSnapshot {
        try JSONDecoder().decode(
            SessionSnapshot.self,
            from: Data(#"{"id":"merge-agent","sessionKind":"pty","provider":"grok","cwd":"/repo","workspaceId":"ws-merge"}"#.utf8)
        )
    }

    func listWorkspaces() async throws -> [Workspace] { [] }

    func listWorkspaceTasks(workspaceId: String) async throws -> [WorkspaceTask] { tasks }

    func updateWorkspaceTask(taskId: String, name: String?) async throws -> WorkspaceTask {
        throw MockError.unavailable
    }

    func deleteWorkspaceTask(taskId: String) async throws {}

    func getWorkspaceTask(taskId: String) async throws -> WorkspaceTaskDetail {
        throw MockError.unavailable
    }

    func saveWorkspaceTaskLayout(
        taskId: String,
        layout: TaskWindowLayout?
    ) async throws -> TaskWindowLayout? { layout }

    func createWorkspaceTaskWindow(
        target: WorkspaceSessionTarget,
        binding: WorkspaceBinding
    ) async throws -> SessionSnapshot {
        throw MockError.unavailable
    }

    func getSession(id: String, blockBudget: Int) async throws -> SessionSnapshot {
        try mergeSnapshot()
    }

    func workspaceDefaultProvider() async throws -> WandProvider { defaultProvider }

    func getWorkspaceDetail(workspaceId: String) async throws -> WorkspaceDetail {
        throw MockError.unavailable
    }

    func createWorkspace(
        name: String,
        cwd: String,
        defaultProvider: WandProvider?
    ) async throws -> Workspace {
        throw MockError.unavailable
    }

    func updateWorkspace(workspaceId: String, name: String) async throws -> Workspace {
        throw MockError.unavailable
    }

    func deleteWorkspace(workspaceId: String) async throws {}

    func createWorkspaceTask(
        workspaceId: String,
        name: String,
        baseRef: String?
    ) async throws -> WorkspaceTaskCreation {
        createTaskRequests.append(
            CreateTaskRequest(workspaceId: workspaceId, name: name, baseRef: baseRef)
        )
        return try JSONDecoder().decode(
            WorkspaceTaskCreation.self,
            from: Data(#"{"id":"task-created","workspaceId":"\#(workspaceId)","name":"\#(name)","worktree":{"branch":"wand/new","path":"/repo/.wand-worktrees/new","baseRef":"main","repoRoot":"/repo"},"status":"active","cwd":"/repo/.wand-worktrees/new","isolated":true,"worktreeError":null}"#.utf8)
        )
    }

    func workspaceWorktreeOverview(workspaceId: String) async throws -> WorkspaceWorktreeOverview {
        throw MockError.unavailable
    }

    func startWorktreeMergeAgent(
        workspace: Workspace,
        provider: WandProvider,
        prompt: String
    ) async throws -> SessionSnapshot {
        capturedProviders.append(provider)
        capturedPrompts.append(prompt)
        return try mergeSnapshot()
    }
}
