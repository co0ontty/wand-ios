import Foundation
import XCTest
@testable import Wand

final class TaskCommentsTests: XCTestCase {
    func testCommentContractDecodesWithoutExtraFields() throws {
        let response = try JSONDecoder().decode(WandTaskCommentsResponse.self, from: Data(#"{"comments":[{"id":"c1","taskId":"a","authorName":"小王","body":"【小王】也遇到了相同的问题。","createdAt":"2026-10-16T01:02:03Z"}]}"#.utf8))
        XCTAssertEqual(response.comments.first?.authorName, "小王")
        XCTAssertEqual(response.comments.first?.body, "【小王】也遇到了相同的问题。")
        XCTAssertEqual(response.comments.first?.taskId, "a")
        XCTAssertTrue(try JSONDecoder().decode(WandTaskCommentsResponse.self, from: Data(#"{"comments":[]}"#.utf8)).comments.isEmpty)
    }

    func testLateResponsesCannotLeakAcrossTaskSelectionOrReopenedTask() {
        var state = WandTaskCommentState()
        let a = state.begin(taskId: "a")
        let b = state.begin(taskId: "b")
        let commentA = WandTaskComment(id: "ca", taskId: "a", authorName: "A", body: "A body", createdAt: "now")
        let commentB = WandTaskComment(id: "cb", taskId: "b", authorName: "B", body: "B body", createdAt: "now")
        state.accept([commentA], taskId: "a", requestId: a)
        XCTAssertTrue(state.visible(taskId: "b").isEmpty)
        state.accept([commentB, commentA], taskId: "b", requestId: b)
        XCTAssertEqual(state.visible(taskId: "b"), [commentB])
        XCTAssertTrue(state.visible(taskId: "a").isEmpty)
        let reopened = state.begin(taskId: "a")
        state.accept([commentA], taskId: "a", requestId: a)
        XCTAssertTrue(state.comments.isEmpty)
        state.accept([commentA], taskId: "a", requestId: reopened)
        XCTAssertEqual(state.visible(taskId: "a"), [commentA])
        let refresh = state.begin(taskId: "a")
        state.accept([], taskId: "a", requestId: refresh)
        XCTAssertTrue(state.visible(taskId: "a").isEmpty)
    }
}
