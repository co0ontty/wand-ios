import Foundation
import XCTest
@testable import Wand

final class TaskCommentsTests: XCTestCase {
    func testMentionQueryFollowsTheCaretAndOnlyTheChosenTokenStaysBound() {
        XCTAssertEqual(TaskCommentMention.query(in: "literal @name", caret: "literal @name".count)?.text, "name")
        XCTAssertNil(TaskCommentMention.query(in: "mail@host", caret: 9))
        XCTAssertEqual(TaskCommentMention.query(in: "@瑞辰 已写完", caret: 2)?.text, "瑞")
        XCTAssertNil(TaskCommentMention.query(in: "@瑞辰 已写完", caret: 4))
        XCTAssertNil(TaskCommentMention.query(in: "@开头", caret: 0))
        let inserted = TaskCommentMention.insert(body: "请 @虎", caret: 5, name: "赛博虎妞")
        XCTAssertEqual(inserted.body, "请 @赛博虎妞 ")
        XCTAssertTrue(TaskCommentMention.holds(inserted.body, name: "赛博虎妞"))
        XCTAssertFalse(TaskCommentMention.holds("@赛博", name: "赛博虎妞"))
        XCTAssertFalse(TaskCommentMention.holds("@瑞辰同学", name: "瑞辰"))
        XCTAssertEqual(TaskCommentMention.caretOffset(from: "请", to: "请@"), 2)
    }

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

extension TaskCommentsTests {

    func testTaskCommentDispatchDecodesTrustedIdentityAndStatus() throws {
        let data = Data(#"{"id":"c","taskId":"task","authorName":"用户","body":"@赛博虎妞 本轮","createdAt":"now","sourceCommentId":"source","dispatch":{"employeeId":"stable-id","employeeName":"赛博虎妞","state":"accepted","sessionId":"exact-session","status":"stopped","error":null}}"#.utf8)
        let comment = try JSONDecoder().decode(WandTaskComment.self, from: data)
        XCTAssertEqual(comment.sourceCommentId, "source")
        XCTAssertEqual(comment.dispatch?.employeeId, "stable-id")
        XCTAssertEqual(comment.dispatch?.sessionId, "exact-session")
        XCTAssertEqual(comment.dispatch?.label, "已停止")
        let plain = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"old","taskId":"task","authorName":"用户","body":"@文本不派发","createdAt":"now"}"#.utf8))
        XCTAssertNil(plain.dispatch)
    }
}

extension TaskCommentsTests {

    func testUnknownReceiptRetainsIdentityAcrossRefreshAndEditingOtherDrafts() throws {
        let name = "task-comment-review-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = TaskCommentRequestIdentity(taskId: "task", body: "old instruction", employeeId: "stable", sourceCommentId: "source", defaults: defaults)
        let unknown = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"task","authorName":"用户","body":"old instruction","createdAt":"now","dispatch":{"employeeId":"stable","employeeName":"员工","state":"unknown","sessionId":"exact","status":"unknown","error":null}}"#.utf8))
        first.settle(unknown)
        let refreshed = TaskCommentRequestIdentity(taskId: "task", body: "old instruction", employeeId: "stable", sourceCommentId: "source", defaults: defaults)
        XCTAssertEqual(first.requestId, refreshed.requestId)
        let other = TaskCommentRequestIdentity(taskId: "task", body: "new instruction", employeeId: "stable", sourceCommentId: "source", defaults: defaults)
        XCTAssertNotEqual(first.requestId, other.requestId)
        other.settle(WandTaskComment(id: "plain", taskId: "task", authorName: "用户", body: "new instruction", createdAt: "now"))
        XCTAssertNil(defaults.string(forKey: other.key))
        let returned = TaskCommentRequestIdentity(taskId: "task", body: "old instruction", employeeId: "stable", sourceCommentId: "source", defaults: defaults)
        XCTAssertEqual(first.requestId, returned.requestId, "a newer accepted draft must not release the older unknown identity")
        XCTAssertTrue(unknown.dispatch!.deliveryUncertain)
    }
}

extension TaskCommentsTests {
    func testSameTaskReversePollingResponsesCannotReplaceNewerState() {
        var state = WandTaskCommentState()
        let older = state.begin(taskId: "same")
        let newer = state.begin(taskId: "same")
        let latest = WandTaskComment(id: "new", taskId: "same", authorName: "用户", body: "newer", createdAt: "now")
        state.accept([latest], taskId: "same", requestId: newer)
        state.accept([WandTaskComment(id: "old", taskId: "same", authorName: "用户", body: "stale", createdAt: "before")], taskId: "same", requestId: older)
        XCTAssertEqual(state.visible(taskId: "same"), [latest])
    }
}
