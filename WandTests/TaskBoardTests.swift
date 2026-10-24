import Foundation
import XCTest
import SwiftUI
@testable import Wand

final class TaskBoardTests: XCTestCase {
    func testServerOverviewBelongsToBoardListNotRootOrDetail() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Wand")
        let root = try String(contentsOf: directory.appendingPathComponent("NativeRootView.swift"), encoding: .utf8)
        let board = try String(contentsOf: directory.appendingPathComponent("TaskBoardView.swift"), encoding: .utf8)
        XCTAssertTrue(root.contains("if homeListMode == .sessions {\n                        InlineHomeChrome { homeOverviewBar.disabled(homeMutationBusy) }"))
        XCTAssertFalse(root.contains("if homeListMode == .sessions || showingBoard"))
        XCTAssertTrue(root.contains("overviewBar: homeOverviewBar"))
        XCTAssertTrue(board.contains("if selected == nil && (!embedded || !usesSystemNavigation) { overviewBar }"))
        XCTAssertTrue(board.contains("if usesSystemNavigation && selected == nil {"), "System list toolbar must leave when a board detail opens")
        XCTAssertTrue(board.contains(".navigationTitle(overviewBar?.title ?? \"任务\")"))
        XCTAssertTrue(board.contains("ToolbarOverflowMenu"))
        XCTAssertTrue(board.contains("if !embedded || !usesSystemNavigation {"), "The system toolbar owns the list create action; ordinary phone keeps its inline action")
        XCTAssertTrue(board.contains("else if usesSystemNavigation, let selected {"), "Embedded task details also use the system navigation region")
        XCTAssertTrue(board.contains(".navigationTitle(selected.title.isEmpty ? \"任务详情\" : selected.title)"))
        XCTAssertTrue(board.contains("Button(\"返回\", systemImage: \"chevron.left\", action: closeTaskDetail)"), "Native return must preserve the parent-task stack")
        XCTAssertTrue(board.contains("if embedded && !usesSystemNavigation {"), "Custom detail chrome belongs only to the inline fallback")
        XCTAssertTrue(board.contains("boardDetailChrome(title:"))
        XCTAssertTrue(board.contains(".homeNavigationHidden(selected != nil)"), "Embedded detail projects chrome visibility from its own selection")
        XCTAssertFalse(board.contains("onDetailPresentationChanged"), "详情状态不应复制到根视图才能隐藏列表入口")
    }

    /// 外部原生触控驱动使用已安装服务，只读任务；不会派发或修改任务。
    @MainActor
    func testEmbeddedBoardServerSwitchIsolation() async throws {
        guard let path = ProcessInfo.processInfo.environment["WAND_BOARD_TOUCH_CONNECTION"] else {
            throw XCTSkip("Requires installed service and native touch driver")
        }
        let connection = try JSONDecoder().decode(Task144Connection.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let url = try XCTUnwrap(URL(string: connection.serverURL))
        let decoded = try XCTUnwrap(WandAuth.decodeConnectCode(connection.connectionCode))
        let api = WandAPI(baseURL: url, token: decoded.token)
        let store = WorkspaceStore(api: api, serverID: "task-144-read-only")
        let finished = expectation(description: "list, detail, child, return and explicit switch checks")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Task144TouchHarness(api: api, store: store) { count in
            XCTAssertEqual(count, 2, "只有列表上的两次显式点击可以触发切换")
            finished.fulfill()
        })
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        print("TASK144_BOARD_READY")
        await fulfillment(of: [finished], timeout: 180)
    }

    @MainActor
    func testQueuedExecutionIsVisibleAndStillAnActiveTask() throws {
        let card = try JSONDecoder().decode(WandBoardTask.self, from: Data("""
        {"id":"queued","status":"doing","executionStatus":"queued","queuedExecutionCount":2,"sessions":[]}
        """.utf8))
        XCTAssertEqual(card.status, "doing")
        XCTAssertEqual(card.displayStatusLabel, "排队中")
        XCTAssertEqual(card.pendingExecutionCount, 2)
        let summary = try JSONDecoder().decode(WorkspaceTaskSummary.self, from: Data("""
        {"id":"queued","workspaceId":"w","name":"排队任务","status":"active","createdAt":"2026-01-01","cwd":"/tmp","sessions":[],"executionStatus":"queued","queuedExecutionCount":2}
        """.utf8))
        XCTAssertTrue(summary.hasActiveExecution)
        XCTAssertTrue(summary.hasQueuedExecution)
        let pending = try JSONDecoder().decode(WorkspaceSessionSummary.self, from: Data("""
        {"id":"pending","sessionKind":"structured","status":"idle","executionStatus":"queued"}
        """.utf8))
        XCTAssertEqual(pending.activityStatus, "queued")
        XCTAssertTrue(HomePresentation.isActive(pending))
        let copied = HomePresentation.replacing(summary, sessions: [])
        XCTAssertTrue(copied.hasQueuedExecution)
        XCTAssertEqual(HomePresentation.statusLabel(pending.activityStatus), "排队中")
    }

    @MainActor
    func testCreateFromPresentedSheet() async throws {
        guard let raw = ProcessInfo.processInfo.environment["WAND_CREATE_TOUCH_URL"],
              let url = URL(string: raw), url.host == "127.0.0.1" else {
            throw XCTSkip("Requires isolated local fixture and simulator touch driver")
        }
        let api = WandAPI(baseURL: url, token: nil)
        let store = WorkspaceStore(api: api, serverID: "create-touch-fixture")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: TaskBoardView(api: api, workspaceStore: store, onOpenSession: { _ in }))
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<90 {
            try await Task.sleep(for: .seconds(1))
            let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("probe"))
            let state = try JSONSerialization.jsonObject(with: data) as? [String: Int]
            if state?["verified"] == 1 {
                XCTAssertEqual(state?["creates"], 1)
                XCTAssertEqual(state?["attempts"], 2)
                return
            }
        }
        XCTFail("Tapping create in the presented form did not submit exactly one request")
    }

    func testBoardTaskCreationUsesPendingConversationAndRetainsWorkspaceContext() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Wand/TaskBoardView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("onRequestNewConversation(cwd, selectedWorkspace?.id)"))
        XCTAssertFalse(source.contains(".sheet(isPresented: $showCreate"))
        let root = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Wand/NativeRootView.swift"), encoding: .utf8)
        XCTAssertTrue(root.contains("beginPendingConversation(cwd: cwd, workspaceID: workspaceID, createsTask: true)"))
        XCTAssertTrue(source.contains("onOpenBoundSession"))
        XCTAssertFalse(source.contains("api.createBoardTask("))
    }

    func testBoardTaskDecodesWorkspaceTaskBindingAndTerminalLabels() throws {
        // 看板卡片靠 workspaceTaskId 才能带着任务上下文打开会话。
        let bound = try JSONDecoder().decode(
            WandBoardTask.self,
            from: Data(
                #"{"id":"t-1","title":"修顶栏","status":"doing","workspaceTaskId":"wt-1","sessions":[]}"#.utf8
            )
        )
        XCTAssertEqual(bound.workspaceTaskId, "wt-1")

        // 旧服务端不返回该字段，或者返回空串：都当“未绑定”。
        let unbound = try JSONDecoder().decode(
            WandBoardTask.self,
            from: Data(#"{"id":"t-2","title":"无归属","status":"todo","workspaceTaskId":""}"#.utf8)
        )
        XCTAssertNil(unbound.workspaceTaskId)
        let missing = try JSONDecoder().decode(
            WandBoardTask.self,
            from: Data(#"{"id":"t-3","title":"旧数据","status":"todo"}"#.utf8)
        )
        XCTAssertNil(missing.workspaceTaskId)
        XCTAssertEqual(WandBoardStatus.allCases.map(\.rawValue), ["backlog", "todo", "doing", "done"])
        XCTAssertEqual(WandBoardStatus.backlog.label, "待立项")

        // 空白终端的 provider 是 shell/session，不能把内部标识当工具名印在卡片上。
        XCTAssertEqual(wandBoardProviderLabel("shell"), "终端")
        XCTAssertEqual(wandBoardProviderLabel("session"), "终端")
        XCTAssertEqual(wandBoardProviderLabel("pi"), "Pi")
        XCTAssertEqual(wandBoardProviderLabel(""), "Agent")
    }

    func testBoardTaskDecoderReadsWorkspaceAgentAndSessions() throws {
        let json = """
        {
          "id": "task-1",
          "workspaceId": "ws-1",
          "identifier": "TASK-1",
          "title": "修顶栏",
          "description": "对齐 iOS",
          "status": "doing",
          "priority": "high",
          "labels": ["ui"],
          "sortOrder": 2,
          "agent": { "provider": "codex", "model": "default", "thinkingEffort": "deep" },
          "sessionIds": ["sess-1"],
          "sessions": [{
            "id": "sess-1",
            "provider": "codex",
            "sessionKind": "structured",
            "title": "修顶栏",
            "status": "running",
            "cwd": "/repo",
            "model": "gpt-5",
            "thinkingEffort": "deep"
          }],
          "workspace": { "id": "ws-1", "name": "wand", "cwd": "/repo" }
        }
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertEqual(task.id, "task-1")
        XCTAssertEqual(task.workspaceId, "ws-1")
        XCTAssertEqual(task.status, "doing")
        XCTAssertEqual(task.agent?.provider, "codex")
        // 服务端未返回 mode：按 provider 支持范围夹取（codex 只有 full-access）。
        XCTAssertEqual(task.agent?.mode, "full-access")
        XCTAssertEqual(task.workspace?.name, "wand")
        XCTAssertEqual(task.sessions.first?.id, "sess-1")
        XCTAssertTrue(task.sessions.first?.isStructured == true)
    }

    func testParallelTurnQueueAndPermissionPrecedence() throws {
        let task = try decodeTask(#"""
        {"id":"parallel","status":"doing","sessions":[
          {"id":"a","status":"exited"},
          {"id":"b","status":"idle","inFlight":true,"queuedMessageCount":1},
          {"id":"c","status":"idle","inFlight":true,"permissionBlocked":true}
        ]}
        """#)
        XCTAssertEqual(task.sessions.map(\.activityLabel), ["已结束", "运行中", "等待授权"])
        XCTAssertTrue(wandBoardSessionSummary(task.sessions).contains("等待授权 1"))
        XCTAssertEqual(wandBoardTaskStats([task]).accepted, 0)
    }

    func testTaskAcceptanceIsIndependentFromSessionLifecycle() throws {
        let task = try decodeTask(#"{"id":"t-accept","title":"交付","status":"done","acceptance":{"evidence":"PR #12","blocker":"","acceptedAt":null},"sessions":[{"id":"s","provider":"claude","title":"执行","status":"exited","cwd":"/repo","employeeName":"员工甲","purpose":"修复登录"}]}"#)
        XCTAssertEqual(task.acceptance?.evidence, "PR #12")
        XCTAssertNil(task.acceptance?.acceptedAt)
        XCTAssertEqual(task.sessions.first?.displayPurpose, "修复登录")
        XCTAssertEqual(task.sessions.first?.employeeName, "员工甲")
        XCTAssertEqual(task.sessions.first?.activityLabel, "已结束")
        XCTAssertEqual(wandBoardTaskStats([task]).accepted, 0, "done 不得自动计为验收")

        let accepted = try decodeTask(#"{"id":"t-accepted","status":"archived","acceptance":{"evidence":"截图","blocker":"","acceptedAt":"2026-01-01T00:00:00Z"}}"#)
        XCTAssertEqual(wandBoardTaskStats([accepted]).accepted, 1)
    }

    func testSessionSummaryKeepsQueuedRunningIdleAndFailedDistinct() throws {
        let task = try decodeTask(#"""
        {"id":"t","sessions":[
          {"id":"q","status":"idle","executionStatus":"queued","queuedMessageCount":1,"cwd":"/q","title":"并行"},
          {"id":"r","status":"running","inFlight":true,"cwd":"/r","title":"继续"},
          {"id":"f","status":"failed","cwd":"/f","title":"失败"}
        ]}
        """#)
        XCTAssertEqual(task.sessions.map(\.activityLabel), ["排队中", "运行中", "失败"])
        XCTAssertEqual(task.sessions.map(\.cwd), ["/q", "/r", "/f"])
    }

    func testBoardTaskDecoderAllowsUnassignedProjectAndAgent() throws {
        let json = #"{"id":"task-2","title":"草稿"}"#.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertNil(task.workspaceId)
        XCTAssertNil(task.agent)
        XCTAssertEqual(task.status, "todo")
        XCTAssertEqual(task.priority, "none")
        XCTAssertTrue(task.sessions.isEmpty)
        // 老服务端不返回 titleSource，按用户手写处理。
        XCTAssertEqual(task.titleSource, "user")
    }

    func testBoardTaskDecoderReadsAutoGeneratedTitleSource() throws {
        let json = #"{"id":"task-3","title":"根据描述生成的标题","titleSource":"auto"}"#.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertEqual(task.titleSource, "auto")
    }

    func testAgentModeDefaultsAndClamps() {
        XCTAssertEqual(wandBoardNormalizedMode(provider: "codex", mode: "managed"), "full-access")
        XCTAssertEqual(wandBoardNormalizedMode(provider: "claude", mode: "bogus"), "default")
        XCTAssertEqual(wandBoardSupportedModes("codex"), ["full-access"])
        XCTAssertEqual(wandBoardModeLabel("managed"), "托管")
        XCTAssertEqual(wandBoardModeLabel("full-access"), "全权限")
        XCTAssertEqual(wandBoardModeLabel("default"), "标准")
        let agent = WandBoardTaskAgent(provider: "claude", model: "default", thinkingEffort: "off", mode: "managed")
        XCTAssertEqual(agent.jsonObject()["mode"] as? String, "managed")
        XCTAssertEqual(agent.mode, "managed")
    }

    func testBoardLabelsCoverColumns() {
        XCTAssertEqual(WandBoardStatus.todo.label, "待办")
        XCTAssertEqual(WandBoardStatus.doing.label, "进行中")
        XCTAssertEqual(WandBoardStatus.done.label, "等你确认")
        XCTAssertEqual(WandBoardPriority.urgent.label, "紧急")
        XCTAssertEqual(wandBoardProviderLabel("pi"), "Pi")
        XCTAssertEqual(wandBoardEffortLabel("deep"), "深入")
    }

    func testUnassignedBoardGroupsProjectSearchAndCanonicalFilters() throws {
        let json = """
        [
          {"workspaceId":"ws-a","workspaceName":"自定义目录","workspaceCwd":"/repo/a/","tasks":[],"standaloneSessions":[
            {"id":"a-1","title":"修 iOS 看板","provider":"claude","status":"running","cwd":"/repo/a"},
            {"id":"archived","title":"已归档","archived":true,"cwd":"/repo/a"},
            {"id":"team","title":"团队聊天","teamChat":{"runId":"run-1"},"cwd":"/repo/a"},
            {"id":"employee","title":"员工执行","employeeId":"e-1","employeeName":"员工虎妞","cwd":"/repo/a"},
            {"id":"formal-s","title":"重复","cwd":"/repo/a"}
          ]},
          {"workspaceId":"cwd:/repo/b","workspaceName":"别的自定义名","workspaceCwd":"/repo/b","synthetic":true,"tasks":[],"standaloneSessions":[{"id":"b-1","title":"修 Android","cwd":"/repo/b"}]},
          {"workspaceId":"wand-global","workspaceName":"全局","workspaceCwd":"/scratch","global":true,"tasks":[],"standaloneSessions":[{"id":"global-1","title":"全局会话","cwd":"/scratch"}]}
        ]
        """
        let groups = try JSONDecoder().decode([TaskDirectoryGroup].self, from: Data(json.utf8))
        let all = wandBoardUnassignedGroups(groups: groups, formalSessionIDs: ["formal-s"])
        XCTAssertEqual(all.map(\.id), ["ws-a", "cwd:/repo/b", "wand-global"])
        XCTAssertEqual(all[0].title, "自定义目录 - 未分组任务")
        XCTAssertEqual(all[0].sessions.map(\.id), ["a-1", "employee"])
        XCTAssertFalse(all.flatMap(\.sessions).contains { $0.id == "archived" || $0.id == "team" || $0.id == "formal-s" })
        XCTAssertEqual(wandBoardUnassignedGroups(groups: groups, formalSessionIDs: [], workspaceID: "cwd:/repo/b").first?.sessions.map(\.id), ["b-1"])
        XCTAssertEqual(wandBoardUnassignedGroups(groups: groups, formalSessionIDs: [], query: "员工虎妞").flatMap(\.sessions).map(\.id), ["employee"])
        XCTAssertEqual(wandBoardUnassignedGroups(groups: groups, formalSessionIDs: ["formal-s"], query: "repo/a").first?.sessions.map(\.id), ["a-1", "employee"])
    }


    func testUnassignedGroupsKeepWorkStepsAndRemoveNewTaskMembership() throws {
        let data = Data(#"[{"workspaceId":"a","workspaceName":"wand","workspaceCwd":"/repo","tasks":[],"standaloneSessions":[{"id":"step","teamStep":{"runId":"run","memberName":"成员"}},{"id":"bound","workspaceTaskId":"task"},{"id":"work","employeeId":"e","employeeName":"虎妞"}]},{"workspaceId":"b","workspaceName":"同目录另项目","workspaceCwd":"/repo","tasks":[],"standaloneSessions":[{"id":"other"}]}]"#.utf8)
        let groups = try JSONDecoder().decode([TaskDirectoryGroup].self, from: data)
        let initial = wandBoardUnassignedGroups(groups: groups, formalSessionIDs: [], workspaceID: "a")
        XCTAssertEqual(initial.first?.title, "wand - 未分组任务")
        XCTAssertEqual(initial.flatMap(\.sessions).map(\.id), ["step", "work"])
        XCTAssertEqual(wandBoardUnassignedGroups(groups: groups, formalSessionIDs: [], query: "虎妞").flatMap(\.sessions).map(\.id), ["work"])
        XCTAssertTrue(wandBoardUnassignedGroups(groups: groups, formalSessionIDs: ["step", "work"], workspaceID: "a").isEmpty,
                      "归类进入正式任务后默认组消失，不创建空的持久卡片")
        XCTAssertEqual(wandBoardUnassignedGroups(groups: groups, formalSessionIDs: [], query: "未分组任务").count, 2)
    }

    /// 空白终端会话的 provider 是空串：必须落进「终端」(session) 分组，否则看板详情只会
    /// 渲染「默认执行参数 · 尚无关联会话」，会话行的「移动会话到其他任务」按钮永远拿不到。
    func testSessionsWithoutProviderLandInTerminalGroup() throws {
        let json = """
        {
          "id": "task-pty",
          "title": "空白终端",
          "sessions": [
            { "id": "pty-1", "provider": "", "sessionKind": "pty", "title": "/bin/zsh", "status": "running" },
            { "id": "sh-2", "provider": "shell", "sessionKind": "pty", "title": "终端", "status": "running" },
            { "id": "c-3", "provider": "claude", "sessionKind": "structured", "title": "修登录", "status": "idle" }
          ]
        }
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        let groups = wandBoardSessionGroups(sessions: task.sessions, assigned: task.agent)
        XCTAssertEqual(groups.map(\.provider), ["session", "shell", "claude"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["pty-1"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["sh-2"])
        XCTAssertEqual(groups[2].sessions.map(\.id), ["c-3"])
        XCTAssertEqual(groups[0].sessions.count, 1, "空 provider 的会话不能落进空分组")
        XCTAssertEqual(wandBoardAgentTitle(groups[0].provider, groups[0].agent), "终端")
        XCTAssertNil(wandBoardAgentLabels(sessions: [], assigned: nil))
    }

    func testSessionsGroupByTheAgentsThatRan() {
        let json = """
        {
          "id": "task-9",
          "title": "多 Agent",
          "agent": { "provider": "claude", "model": "opus", "thinkingEffort": "deep" },
          "sessions": [
            { "id": "s1", "provider": "claude", "title": "修登录", "status": "running", "model": "opus", "thinkingEffort": "deep" },
            { "id": "s2", "provider": "claude", "title": "补测试", "status": "exited", "model": "sonnet", "thinkingEffort": "off" },
            { "id": "s3", "provider": "codex", "title": "实现 API", "status": "idle", "model": "gpt-5", "thinkingEffort": "standard" }
          ]
        }
        """.data(using: .utf8)!
        let task = try! JSONDecoder().decode(WandBoardTask.self, from: json)
        let groups = wandBoardSessionGroups(sessions: task.sessions, assigned: task.agent)
        XCTAssertEqual(groups.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["s3"])
        let pending = wandBoardSessionGroups(
            sessions: [],
            assigned: WandBoardTaskAgent(provider: "pi", model: "default", thinkingEffort: "off")
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.provider, "pi")
        XCTAssertTrue(pending.first?.sessions.isEmpty == true)
    }

    func testSwipeActionsFollowAndroidStatusContract() {
        XCTAssertEqual(wandBoardSwipeAction(for: "todo"), .start)
        XCTAssertEqual(wandBoardSwipeAction(for: "doing"), .complete)
        XCTAssertEqual(wandBoardSwipeAction(for: "done"), .archive)
        XCTAssertNil(wandBoardSwipeAction(for: "archived"))
        XCTAssertEqual(wandBoardSwipeTargetStatus(.start), "doing")
        XCTAssertEqual(wandBoardSwipeTargetStatus(.complete), "done")
        XCTAssertNil(wandBoardSwipeTargetStatus(.archive))
        XCTAssertEqual(wandBoardSwipeActionTitle(.start), "开始任务？")
        XCTAssertEqual(wandBoardToggledStatus("doing"), "done")
        XCTAssertEqual(wandBoardToggledStatus("done"), "todo")
    }

    /// 划开动作条必须比右下角悬浮的「新建任务」（56pt）宽，否则被悬浮按钮盖住的
    /// 那一段点下去会变成新建任务。
    func testSwipeActionWidthStaysWiderThanFloatingButton() {
        XCTAssertGreaterThanOrEqual(wandBoardSwipeActionWidth, 100)
    }

    /// 松手判定与 Android `boardTaskSwipeShouldReveal` 一致：速度优先，速度过小才看位移过半。
    func testSwipeSettleDecisionPrefersVelocityThenHalfWidth() {
        let width: CGFloat = 104
        // 快速左划：哪怕只拖了一点也划开；快速右划：哪怕已经拖过一半也收起。
        XCTAssertTrue(wandBoardSwipeShouldReveal(offset: -10, revealWidth: width, velocity: -600))
        XCTAssertFalse(wandBoardSwipeShouldReveal(offset: -100, revealWidth: width, velocity: 600))
        // 速度不够时看位移是否过半。
        XCTAssertTrue(wandBoardSwipeShouldReveal(offset: -52, revealWidth: width, velocity: -100))
        XCTAssertFalse(wandBoardSwipeShouldReveal(offset: -51, revealWidth: width, velocity: 100))
        // 没有动作条时永远不划开。
        XCTAssertFalse(wandBoardSwipeShouldReveal(offset: -100, revealWidth: 0, velocity: -900))
    }

    func testProcessingAndAgentRunningLabels() throws {
        let json = """
        {
          "id": "task-run",
          "title": "",
          "description": "项目：wand\\n修登录",
          "status": "doing",
          "sessions": [{ "id": "s1", "provider": "claude", "status": "running" }]
        }
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertEqual(wandBoardCardTitle(task), "修登录")
        XCTAssertEqual(wandBoardProcessingLabel(task), "正在处理...")
        XCTAssertTrue(wandBoardAgentRunning(task))
        XCTAssertEqual(wandBoardAgentLabels(sessions: task.sessions, assigned: task.agent), "Claude")
    }

    func testBoardTaskStatsCountRemainingAndPriority() throws {
        let json = """
        [
          {"id":"a","status":"todo","priority":"urgent"},
          {"id":"b","status":"doing","priority":"none"},
          {"id":"c","status":"done","priority":"high"},
          {"id":"d","status":"archived","priority":"low"}
        ]
        """.data(using: .utf8)!
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: json)
        let stats = wandBoardTaskStats(tasks)
        XCTAssertEqual(stats.total, 4)
        XCTAssertEqual(stats.todo, 1)
        XCTAssertEqual(stats.doing, 1)
        XCTAssertEqual(stats.done, 1)
        XCTAssertEqual(stats.remaining, 2)
        XCTAssertEqual(stats.high, 2)
    }

    // MARK: - 卡片展示模型（与 Android BoardTaskCardModel 同一套规则）

    func testCardModelCapsLabelsAndSessionsWithExplicitOverflow() throws {
        let task = try decodeTask("""
        {
          "id": "t-1", "identifier": "WAND-7", "title": "修看板卡片", "status": "todo",
          "priority": "high", "labels": ["ui", "ios", "extra", "more"],
          "workspace": { "id": "ws-1", "name": "wand", "cwd": "/repo" },
          "milestone": { "id": "m-1", "name": "  1.2 看板重构  " },
          "sessions": [
            { "id": "s1", "provider": "claude", "title": "修看板", "status": "idle" },
            { "id": "s2", "provider": "codex", "title": "补接口", "status": "running" },
            { "id": "s3", "provider": "pi", "title": "写测试", "status": "running" },
            { "id": "s4", "provider": "grok", "title": "跑回归", "status": "running" }
          ]
        }
        """)
        let model = wandBoardCardModel(task, showWorkspace: true)
        XCTAssertEqual(model.identifier, "WAND-7")
        XCTAssertEqual(model.labels, ["ui", "ios"])
        XCTAssertEqual(model.extraLabelCount, 2)
        XCTAssertEqual(model.sessions.map(\.label), ["修看板", "补接口", "写测试"])
        XCTAssertEqual(model.extraSessionCount, 1)
        XCTAssertEqual(model.milestoneName, "1.2 看板重构")
        XCTAssertTrue(model.hasChips)
        XCTAssertTrue(model.running)
        // 会话标题缺少时就退回工具名，避免出现空行。
        XCTAssertEqual(
            wandBoardSessionCardLabel(
                WandBoardTaskSession.fixture(id: "s5", provider: "claude", title: "claude")
            ),
            "Claude"
        )
    }

    func testCardModelCarriesDueStampAndOverdueFlag() throws {
        let task = try decodeTask("""
        { "id": "t-2", "title": "交周报", "status": "doing", "dueDate": "2026-03-20" }
        """)
        let overdue = wandBoardCardModel(task, showWorkspace: true, today: "2026-03-25")
        XCTAssertEqual(overdue.due?.label, "逾期 · 3/20")
        XCTAssertEqual(overdue.due?.overdue, true)
        // 描述摘要只在没有会话/指派时出现，有状态行时卡片已经有内容了。
        XCTAssertEqual(overdue.processingLabel, "等待派发")

        let future = wandBoardCardModel(task, showWorkspace: true, today: "2026-03-11")
        XCTAssertEqual(future.due?.label, "3/20")
        XCTAssertEqual(future.due?.overdue, false)
        XCTAssertNil(wandBoardCardDue("", status: "doing", today: "2026-03-25"))
        XCTAssertNil(wandBoardCardDue("下周", status: "doing", today: "2026-03-25"))
    }

    func testClosedTasksNeverReadAsOverdue() throws {
        let done = try decodeTask(
            #"{ "id": "t-3", "title": "做完了", "status": "done", "dueDate": "2026-03-20" }"#
        )
        XCTAssertEqual(wandBoardCardModel(done, showWorkspace: true, today: "2026-03-25").due?.overdue, false)
        let archived = try decodeTask(
            #"{ "id": "t-4", "title": "归档了", "status": "archived", "dueDate": "2026-03-20" }"#
        )
        XCTAssertEqual(
            wandBoardCardModel(archived, showWorkspace: true, today: "2026-03-25").due?.overdue,
            false
        )
    }

    func testCardBodyFallsBackToDescriptionWithoutDuplicatingTheTitle() throws {
        // 描述里的换行要写成 JSON 转义，所以这里用原始字符串 `#"..."#` 包住。
        let task = try decodeTask(
            #"{"id":"t-5","title":"把登录页修好","status":"todo","description":"项目：wand\n把登录页修好\n目录：/repo\n第一个可点区域不能是登录按钮\n再加一个错误提示"}"#
        )
        let model = wandBoardCardModel(task, showWorkspace: false)
        XCTAssertEqual(model.body, "第一个可点区域不能是登录按钮\n再加一个错误提示")

        // 已经有会话的任务不再堆描述，卡片的重点在会话行。
        let withSession = try decodeTask("""
        {
          "id": "t-6", "title": "把登录页修好", "status": "doing", "description": "补充说明",
          "sessions": [{ "id": "s1", "provider": "claude", "title": "修登录", "status": "running" }]
        }
        """)
        XCTAssertNil(wandBoardCardModel(withSession, showWorkspace: false).body)
    }

    func testCardModelHidesWorkspaceChipWhenWorkspaceIsNotShown() throws {
        let task = try decodeTask("""
        {
          "id": "t-7", "title": "独立任务", "status": "todo",
          "workspace": { "id": "ws-1", "name": "wand", "cwd": "/repo" }
        }
        """)
        let hidden = wandBoardCardModel(task, showWorkspace: false)
        XCTAssertNil(hidden.workspaceName)
        XCTAssertFalse(hidden.hasChips)
        XCTAssertEqual(wandBoardCardModel(task, showWorkspace: true).workspaceName, "wand")
    }

    private func decodeTask(_ json: String) throws -> WandBoardTask {
        try JSONDecoder().decode(WandBoardTask.self, from: Data(json.utf8))
    }
}

private struct Task144Connection: Decodable {
    let serverURL: String
    let connectionCode: String
}

private struct Task144TouchHarness: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    let finished: (Int) -> Void
    @State private var switchCount = 0

    var body: some View {
        VStack(spacing: 0) {
            TaskBoardView(api: api, workspaceStore: store, onOpenSession: { _ in }, embedded: true,
                overviewBar: HomeOverviewBar(serverDisplayName: "TASK-144 只读验收", showNewTask: false,
                    onNewTask: {}, onOpenSettings: {}, onSwitchServer: { switchCount += 1 }))
            Text("服务器切换次数：\(switchCount)").accessibilityIdentifier("task144-switch-count")
            Button("完成顶栏验收") { finished(switchCount) }.frame(minHeight: 44)
        }
    }
}

private extension WandBoardTaskSession {
    /// 直接构造一个会话，省得为一行标签再拼一段 JSON。
    static func fixture(id: String, provider: String, title: String, status: String = "idle") -> Self {
        let json = """
        { "id": "\(id)", "provider": "\(provider)", "title": "\(title)", "status": "\(status)" }
        """
        return try! JSONDecoder().decode(WandBoardTaskSession.self, from: Data(json.utf8))
    }
}
