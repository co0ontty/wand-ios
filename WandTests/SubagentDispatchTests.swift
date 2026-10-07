import Foundation
import XCTest
@testable import Wand

/// 回归：pi `subagent` 的 workflow 形态派发（名字是 `Pi/subagent`、没有 `agent`/`task`，
/// 也没有 `subagent_type`）必须被认成派发块，从正文活动轨迹里跳过——否则同一块既进
/// 正文又进子 Agent 状态坞，界面上重复显示。
final class SubagentDispatchTests: XCTestCase {
    private func workflowMeta() -> SubagentMeta {
        SubagentMeta(taskId: "call-wf", agentType: "workflow", taskDescription: "continuation.js")
    }

    func testWorkflowDispatchBlockIsClaimedByTheAgentRun() {
        XCTAssertTrue(isSubagentDispatchBlock(id: "call-wf", subagent: workflowMeta()))
    }

    func testClaudeDispatchBlockIsClaimedByTheAgentRun() {
        XCTAssertTrue(isSubagentDispatchBlock(
            id: "task-1",
            subagent: SubagentMeta(taskId: "task-1", agentType: "Explore", taskDescription: "查看依赖"),
        ))
    }

    func testInnerCallsOfASubagentStayInTheTranscript() {
        XCTAssertFalse(isSubagentDispatchBlock(id: "read-1", subagent: workflowMeta()))
        XCTAssertFalse(isSubagentDispatchBlock(id: "bash-1", subagent: workflowMeta()))
    }

    func testUnstampedOrEmptyIdentityIsNotADispatch() {
        XCTAssertFalse(isSubagentDispatchBlock(id: "call-wf", subagent: nil))
        XCTAssertFalse(isSubagentDispatchBlock(
            id: "call-wf",
            subagent: SubagentMeta(taskId: "", agentType: nil, taskDescription: nil),
        ))
        XCTAssertFalse(isSubagentDispatchBlock(
            id: "",
            subagent: SubagentMeta(taskId: "call-wf", agentType: nil, taskDescription: nil),
        ))
        XCTAssertFalse(isSubagentDispatchBlock(
            id: "call-wf",
            subagent: SubagentMeta(taskId: nil, agentType: "workflow", taskDescription: nil),
        ))
    }
}
