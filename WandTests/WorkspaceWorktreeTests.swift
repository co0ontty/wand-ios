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

    func testCreateTaskWorktreeFlagOmitsByDefaultAndSendsFalseExplicitly() {
        // 缺省不传 worktree，交由服务端默认（git 仓库自动隔离）。
        let defaultTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "默认任务",
            baseRef: nil,
            worktree: nil
        )
        XCTAssertNil(defaultTask.body["worktree"])

        let enabledTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "隔离任务",
            baseRef: nil,
            worktree: true
        )
        XCTAssertNil(enabledTask.body["worktree"])

        // 显式 false 必须传 worktree:false，跳过隔离。
        let sharedTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "共享目录任务",
            baseRef: nil,
            worktree: false
        )
        XCTAssertEqual(sharedTask.body["worktree"], .bool(false))
    }

    func testTaskDirectoryGroupsDecodeAggregateShape() throws {
        // GET /api/tasks 的目录组形状：任务带运行期字段，未分组会话归 standaloneSessions。
        let json = """
        [{
          "workspaceId": "ws-1",
          "workspaceName": "Wand",
          "workspaceCwd": "/repo",
          "tasks": [{
            "id": "task-1",
            "workspaceId": "ws-1",
            "name": "修复登录",
            "worktree": {"branch": "wand/login", "path": "/wt/login"},
            "layout": null,
            "status": "active",
            "createdAt": "2026-08-23T00:00:00.000Z",
            "lastOpenedAt": null,
            "cwd": "/wt/login",
            "isolated": true,
            "sessions": [{"id": "s1", "provider": "claude", "title": "登录会话"}]
          }],
          "standaloneSessions": [{"id": "s2", "sessionKind": "pty"}],
          "synthetic": false
        },
        {
          "workspaceId": "cwd:/loose",
          "workspaceName": "loose",
          "workspaceCwd": "/loose",
          "synthetic": true,
          "tasks": [],
          "standaloneSessions": []
        }]
        """
        let groups = try JSONDecoder().decode([TaskDirectoryGroup].self, from: Data(json.utf8))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].workspaceName, "Wand")
        XCTAssertFalse(groups[0].isSynthetic)
        XCTAssertEqual(groups[0].tasks.count, 1)
        XCTAssertTrue(groups[0].tasks[0].isIsolated)
        XCTAssertEqual(groups[0].tasks[0].cwd, "/wt/login")
        XCTAssertEqual(groups[0].tasks[0].sessions.first?.title, "登录会话")
        XCTAssertEqual(groups[0].standaloneSessions.count, 1)
        XCTAssertTrue(groups[1].isSynthetic)
        XCTAssertTrue(groups[1].tasks.isEmpty)
    }

    func testTaskDirectoryWorkspaceResolutionPreservesConfiguredProvider() throws {
        let group = try taskGroup(workspaceId: "ws-provider", taskName: "Task")
        let configured = try workspace(id: "ws-provider", defaultProviderJSON: #""codex""#)

        let resolved = workspaceForTaskGroup(group, workspaces: [configured])
        let fallback = workspaceForTaskGroup(group, workspaces: [])

        XCTAssertEqual(resolved.defaultProvider, .codex)
        XCTAssertNil(fallback.defaultProvider)
        XCTAssertEqual(fallback.cwd, "/repo")
    }

    func testCreateTaskValidatesAndNormalizesDirectoryAndKeepsLocalAggregateOnRefreshFailure() async throws {
        XCTAssertEqual(normalizeWorkspaceDirectory(" /repo/// "), "/repo")
        XCTAssertEqual(normalizeWorkspaceDirectory("/"), "/")

        let service = MockWorktreeMergeService()
        service.workspaceList = [try workspace(id: "ws-a")]
        let store = WorkspaceStore(api: service, serverID: "server-task-first")
        await store.loadWorkspaceIndex()

        do {
            _ = try await store.createTask(name: "Invalid", directory: "   ", worktree: nil)
            XCTFail("Blank directories must fail before any network mutation")
        } catch is WorkspaceTaskCreationError {
            XCTAssertTrue(service.createTaskRequests.isEmpty)
        }

        service.failTaskGroups = true
        let outcome = try await store.createTask(
            name: "修复登录",
            directory: " /repo/// ",
            worktree: false
        )

        XCTAssertEqual(outcome.workspace.id, "ws-a")
        XCTAssertEqual(service.createTaskRequests.count, 1)
        XCTAssertEqual(service.createTaskRequests[0].workspaceId, "ws-a")
        XCTAssertEqual(service.createTaskRequests[0].worktree, false)
        XCTAssertEqual(store.taskGroups.first?.tasks.map(\.id), ["task-created"])
    }

    func testTaskAggregateUpdatesImmediatelyAfterRenameAndDelete() async throws {
        let service = MockWorktreeMergeService()
        service.taskGroups = [try taskGroup(workspaceId: "ws-a", taskName: "旧名称")]
        service.updatedTask = try decode(
            WorkspaceTask.self,
            from: #"{"id":"task-1","workspaceId":"ws-a","name":"新名称","worktree":null,"layout":null,"status":"active","createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null}"#
        )
        let store = WorkspaceStore(api: service, serverID: "server-aggregate")
        await store.loadTaskGroups()

        _ = try await store.renameWorkspaceTask(
            workspaceId: "ws-a",
            taskId: "task-1",
            name: "新名称"
        )
        XCTAssertEqual(store.taskGroups.first?.tasks.first?.name, "新名称")

        try await store.deleteWorkspaceTask(workspaceId: "ws-a", taskId: "task-1")
        XCTAssertTrue(store.taskGroups.first?.tasks.isEmpty == true)
    }

    func testTaskAggregateRejectsRefreshStartedBeforeRename() async throws {
        let service = MockWorktreeMergeService()
        let oldGroup = try taskGroup(workspaceId: "ws-a", taskName: "旧名称")
        service.taskGroups = [oldGroup]
        service.updatedTask = try decode(
            WorkspaceTask.self,
            from: #"{"id":"task-1","workspaceId":"ws-a","name":"新名称","worktree":null,"layout":null,"status":"active","createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null}"#
        )
        let store = WorkspaceStore(api: service, serverID: "server-refresh-race")
        await store.loadTaskGroups()

        service.suspendTaskGroups = true
        let staleRefresh = Task { await store.loadTaskGroups(force: true) }
        while !service.taskGroupsRequestStarted { await Task.yield() }

        _ = try await store.renameWorkspaceTask(
            workspaceId: "ws-a",
            taskId: "task-1",
            name: "新名称"
        )
        service.resolveTaskGroups(with: [oldGroup])
        await staleRefresh.value

        XCTAssertEqual(store.taskGroups.first?.tasks.first?.name, "新名称")
        XCTAssertFalse(store.taskGroupsLoading)
    }

    func testStandaloneSessionRequestCannotRepopulateCacheAfterIndexRefresh() async throws {
        let service = MockWorktreeMergeService()
        service.suspendWorkspaceDetail = true
        let store = WorkspaceStore(api: service, serverID: "server-standalone-race")

        let staleLoad = Task {
            await store.loadWorkspaceSessions(workspaceId: "ws-a")
        }
        while !service.workspaceDetailRequestStarted { await Task.yield() }

        await store.loadWorkspaceIndex()
        let staleDetail = try decode(
            WorkspaceDetail.self,
            from: #"{"id":"ws-a","name":"Wand","cwd":"/repo","defaultProvider":null,"layout":null,"createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null,"sessions":[{"id":"stale-session","provider":"claude"}]}"#
        )
        service.resolveWorkspaceDetail(with: staleDetail)
        await staleLoad.value

        XCTAssertNil(store.standaloneSessions["ws-a"])
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

    private func taskGroup(workspaceId: String, taskName: String) throws -> TaskDirectoryGroup {
        try decode(
            TaskDirectoryGroup.self,
            from: #"{"workspaceId":"\#(workspaceId)","workspaceName":"Wand","workspaceCwd":"/repo","synthetic":false,"tasks":[{"id":"task-1","workspaceId":"\#(workspaceId)","name":"\#(taskName)","worktree":null,"layout":null,"status":"active","createdAt":"2026-08-09T00:00:00Z","lastOpenedAt":null,"cwd":"/repo","isolated":false,"worktreeError":null,"sessions":[]}],"standaloneSessions":[]}"#
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
        var worktree: Bool?
    }

    enum MockError: LocalizedError {
        case unavailable

        var errorDescription: String? { "Unavailable" }
    }

    var defaultProvider: WandProvider = .claude
    var workspaceList: [Workspace] = []
    var tasks: [WorkspaceTask] = []
    var taskGroups: [TaskDirectoryGroup] = []
    var failTaskGroups = false
    var updatedTask: WorkspaceTask?
    var suspendTaskGroups = false
    var taskGroupsRequestStarted = false
    private var taskGroupsContinuation: CheckedContinuation<[TaskDirectoryGroup], Never>?
    var suspendWorkspaceDetail = false
    var workspaceDetailRequestStarted = false
    private var workspaceDetailContinuation: CheckedContinuation<WorkspaceDetail, Never>?
    var capturedProviders: [WandProvider] = []
    var capturedPrompts: [String] = []
    var createTaskRequests: [CreateTaskRequest] = []

    private func mergeSnapshot() throws -> SessionSnapshot {
        try JSONDecoder().decode(
            SessionSnapshot.self,
            from: Data(#"{"id":"merge-agent","sessionKind":"pty","provider":"grok","cwd":"/repo","workspaceId":"ws-merge"}"#.utf8)
        )
    }

    func listWorkspaces() async throws -> [Workspace] { workspaceList }

    func listWorkspaceTasks(workspaceId: String) async throws -> [WorkspaceTask] { tasks }

    func updateWorkspaceTask(taskId: String, name: String?) async throws -> WorkspaceTask {
        guard let updatedTask else { throw MockError.unavailable }
        return updatedTask
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
        binding: WorkspaceBinding,
        kind: WorkspaceSessionKind
    ) async throws -> SessionSnapshot {
        throw MockError.unavailable
    }

    func getSession(id: String, blockBudget: Int) async throws -> SessionSnapshot {
        try mergeSnapshot()
    }

    func workspaceDefaultProvider() async throws -> WandProvider { defaultProvider }

    func getWorkspaceDetail(workspaceId: String) async throws -> WorkspaceDetail {
        if suspendWorkspaceDetail {
            workspaceDetailRequestStarted = true
            return await withCheckedContinuation { workspaceDetailContinuation = $0 }
        }
        throw MockError.unavailable
    }

    func resolveWorkspaceDetail(with detail: WorkspaceDetail) {
        suspendWorkspaceDetail = false
        workspaceDetailContinuation?.resume(returning: detail)
        workspaceDetailContinuation = nil
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
        baseRef: String?,
        worktree: Bool? = nil
    ) async throws -> WorkspaceTaskCreation {
        createTaskRequests.append(
            CreateTaskRequest(workspaceId: workspaceId, name: name, baseRef: baseRef, worktree: worktree)
        )
        return try JSONDecoder().decode(
            WorkspaceTaskCreation.self,
            from: Data(#"{"id":"task-created","workspaceId":"\#(workspaceId)","name":"\#(name)","worktree":{"branch":"wand/new","path":"/repo/.wand-worktrees/new","baseRef":"main","repoRoot":"/repo"},"status":"active","cwd":"/repo/.wand-worktrees/new","isolated":true,"worktreeError":null}"#.utf8)
        )
    }

    func deleteWorkspaceSessions(sessionIds: [String]) async throws -> Int {
        sessionIds.count
    }

    func listTaskGroups() async throws -> [TaskDirectoryGroup] {
        if failTaskGroups { throw MockError.unavailable }
        if suspendTaskGroups {
            taskGroupsRequestStarted = true
            return await withCheckedContinuation { taskGroupsContinuation = $0 }
        }
        return taskGroups
    }

    func resolveTaskGroups(with groups: [TaskDirectoryGroup]) {
        suspendTaskGroups = false
        taskGroupsContinuation?.resume(returning: groups)
        taskGroupsContinuation = nil
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
