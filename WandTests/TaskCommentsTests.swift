import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Wand

final class TaskCommentsTests: XCTestCase {
    @MainActor
    func testSubmitRowKeepsAllReceiptStatesTheSameSizeAndDoesNotClipHints() {
        let labels = [("idle", "发表评论"), ("sending", "正在提交…"), ("saved", "评论已保存"),
                      ("failed", "提交失败"), ("unknown", "送达待核对")]
        let hint = "正文里没有选中的 @员工时，不会启动执行。"
        for width: CGFloat in [320, 420] {
            for largeType in [false, true] {
                var sizes: [CGSize] = []
                for phase in labels.map(\.0) {
                    let row = TaskCommentSubmitRow(phase: phase, labels: labels, hint: hint, disabled: false, onSubmit: {})
                        .environment(\.dynamicTypeSize, largeType ? .accessibility3 : .large)
                    let host = UIHostingController(rootView: row)
                    let category: UIContentSizeCategory = largeType ? .accessibilityExtraLarge : .large
                    host.traitOverrides.preferredContentSizeCategory = category
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
                    sizes.append(size)
                    let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                    let availableHintWidth = largeType ? width : width - 128 - WandLayout.fieldGap
                    let expectedHintHeight = (hint as NSString).boundingRect(
                        with: CGSize(width: availableHintWidth, height: 2000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
                    let minimumHeight = largeType ? WandLayout.controlTouch + WandLayout.fieldGap + expectedHintHeight : max(WandLayout.controlTouch, expectedHintHeight)
                    XCTAssertGreaterThanOrEqual(size.height + 1, minimumHeight, "Full hint must contribute to the Form row height")
                    XCTAssertLessThanOrEqual(size.width, width + 1)
                }
                for size in sizes.dropFirst() {
                    XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5, "Receipt changes must not move or resize the button")
                    XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5)
                }
            }
        }
    }

    @MainActor
    func testMentionCandidatesAreIndependentAccessibilityButtonsInsideForm() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = MentionAccessibilityHarnessState()
        let names = ["勤劳的初二", "赛博虎妞", "石一", "嘟嘟", "石二", "华杰", "瑞辰", "香菜", "小试"]
        let employees = names.enumerated().map { (id: "employee-\($0.offset)", name: $0.element) }
        let host = UIHostingController(rootView: MentionAccessibilityHarness(state: state, employees: employees))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        // SwiftUI builds scroll-content AX nodes only when an accessibility client
        // attaches. The dedicated idb runner performs that public, external query.
        print("TASK140_PICKER_READY")
        var nodes = mentionAccessibilityDescendants(host.view)
        for _ in 0..<100 where !nodes.contains(where: { $0.accessibilityLabel == "@勤劳的初二" }) {
            try await Task.sleep(for: .milliseconds(50))
            nodes = mentionAccessibilityDescendants(host.view)
        }
        guard nodes.contains(where: { $0.accessibilityLabel == "@勤劳的初二" }) else {
            throw XCTSkip("需要活动的 AX 客户端；运行 scripts/test-mention-accessibility.py，不以普通 XCTest 跳过代替无障碍验收")
        }
        // Let the external snapshot finish before activating and closing the picker.
        try await Task.sleep(for: .seconds(1))
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "task-140-mention-form"
        attachment.lifetime = .keepAlways
        add(attachment)
        for employee in employees {
            let candidate = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "@\(employee.name)" }, "Missing candidate \(employee.name)")
            XCTAssertTrue(candidate.isAccessibilityElement)
            XCTAssertTrue(candidate.accessibilityTraits.contains(.button))
            XCTAssertEqual(candidate.accessibilityHint, "插入提及并选择此员工为本轮派发对象")
            XCTAssertFalse(candidate.accessibilityTraits.contains(.selected))
        }
        let chosen = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "@赛博虎妞" })
        XCTAssertTrue(chosen.accessibilityActivate(), "VoiceOver activation must call the same choose action as a touch")
        try await Task.sleep(for: .milliseconds(200))
        nodes = mentionAccessibilityDescendants(host.view)
        XCTAssertEqual(state.selectedEmployeeId, "employee-1")
        XCTAssertEqual(state.chosenName, "赛博虎妞")
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "@勤劳的初二" }, "Choosing must close the picker")
        state.showPicker = true
        try await Task.sleep(for: .milliseconds(200))
        nodes = mentionAccessibilityDescendants(host.view)
        for employee in employees {
            let candidate = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "@\(employee.name)" })
            XCTAssertEqual(candidate.accessibilityTraits.contains(.selected), employee.name == "赛博虎妞")
        }
        let replacement = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "@勤劳的初二" })
        XCTAssertTrue(replacement.accessibilityActivate())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.selectedEmployeeId, "employee-0")
        XCTAssertEqual(state.chosenName, "勤劳的初二")
    }

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
        XCTAssertEqual(inserted.caret, inserted.body.count)
    }

}

final class Task141MentionTests: XCTestCase {
    @MainActor
    func testNativeMentionEditorKeepsIMEAndAppliesTheActualSelection() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let probe = Task141EditorProbe()
        let host = UIHostingController(rootView: Task141EditorHarness(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(180))
        func find(_ view: UIView) -> ComposerUITextView? {
            if let editor = view as? ComposerUITextView { return editor }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let editor = try XCTUnwrap(find(host.view))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertEqual(probe.text, "👩🏽‍💻 @赛博虎妞 ", "Marked text must never overwrite the committed draft")
        editor.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0)); editor.unmarkText()
        XCTAssertEqual(probe.text, "👩🏽‍💻 @赛博虎妞 你")
        probe.text = "@石一 "
        probe.selection = NSRange(location: (probe.text as NSString).length, length: 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.text, probe.text)
        XCTAssertEqual(editor.selectedRange, probe.selection)
        editor.insertText("核对")
        XCTAssertEqual(probe.text, "@石一 核对", "Continuing after choosing must follow the inserted mention, not the old caret")
        editor.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertEqual(probe.selection.location, 0, "A touch/selection-only move must reach the draft owner")
    }

    func testNativeCaretUsesCharacterOffsetsAndRejectsAnOldLongerSelection() {
        let text = "👩🏽‍💻 请 @赛博虎妞"
        let index = text.index(text.startIndex, offsetBy: 5)
        XCTAssertEqual(TaskCommentMention.caretOffset(in: text, at: index), 5)
        XCTAssertNil(TaskCommentMention.caretOffset(in: "@石一 ", at: text.endIndex))
        let chosen = TaskCommentMention.insert(body: text, caret: 5, name: "石一")
        XCTAssertEqual(chosen.body, "👩🏽‍💻 请 @石一 ")
    }

    func testMentionReplacementConsumesTheWholeTokenAndCompactsOnlyThePreamble() {
        let name = "赛博虎妞"
        let middle = "👩🏽‍💻 请 @赛博虎妞 核对 #TASK-133"
        let caret = "👩🏽‍💻 请 @赛".count
        let inserted = TaskCommentMention.insert(body: middle, caret: caret, name: name)
        XCTAssertEqual(inserted.body, middle)
        XCTAssertEqual(inserted.caret, "👩🏽‍💻 请 @赛博虎妞 ".count)
        XCTAssertNil(TaskCommentMention.query(in: inserted.body, caret: inserted.caret))
        let duplicate = "@赛博虎妞 @ @赛博虎妞 @赛博虎妞 重跑本任务：保留邮箱 a@b.test 与 `@示例`"
        XCTAssertEqual(TaskCommentMention.submissionBody(duplicate, name: name), "@赛博虎妞 重跑本任务：保留邮箱 a@b.test 与 `@示例`")
        let chosen = TaskCommentMention.insert(body: "@赛博虎妞 @ @", caret: "@赛博虎妞 @ @".count, name: name)
        XCTAssertEqual(chosen.body, "@赛博虎妞 ")
        XCTAssertEqual(chosen.caret, chosen.body.count)
        let switched = TaskCommentMention.insert(body: "@赛博虎妞 @", caret: "@赛博虎妞 @".count, name: "石一", replacingName: name)
        XCTAssertEqual(switched.body, "@石一 ")
        let continuing = "@赛博虎妞 请核对 #TASK-133 @"
        let repeated = TaskCommentMention.insert(body: continuing, caret: continuing.count, name: name, replacingName: name)
        XCTAssertEqual(repeated.body, "@赛博虎妞 请核对 #TASK-133 ")
        XCTAssertEqual(repeated.caret, repeated.body.count)
        let replaced = TaskCommentMention.insert(body: continuing, caret: continuing.count, name: "石一", replacingName: name)
        XCTAssertEqual(replaced.body, "@石一 请核对 #TASK-133 ")
        XCTAssertEqual(replaced.caret, replaced.body.count)
        XCTAssertEqual(TaskCommentMention.insert(body: "@A B @", caret: "@A B @".count, name: "石一", replacingName: "A B").body, "@石一 ")
        XCTAssertNil(TaskCommentMention.validationMessage("@A B 执行", name: "A B"))
        let stale = TaskCommentMention.insert(body: "已写正文", caret: 4, name: name)
        XCTAssertEqual(stale.body, "已写正文", "A stale candidate must never append an @")
    }

    func testInvalidMentionsCannotBecomePlainCommentsOrEmptyInstructions() {
        for text in ["@", "@ @", " \n@\t@ ", "@赛博虎妞", "@赛博虎妞 请执行"] {
            XCTAssertNotNil(TaskCommentMention.validationMessage(text, name: ""), text)
        }
        for text in ["@赛博虎妞", "@赛博虎妞 @ @赛博虎妞", "@赛博虎妞 执行 @", "@赛博虎妞 执行 @赛博虎妞"] {
            XCTAssertNotNil(TaskCommentMention.validationMessage(text, name: "赛博虎妞"), text)
        }
        for text in ["普通评论", "a@b.test 的问题", "`@注解` 示例"] {
            XCTAssertNil(TaskCommentMention.validationMessage(text, name: ""), text)
        }
        XCTAssertNil(TaskCommentMention.validationMessage("@赛博虎妞 @ @赛博虎妞 修复 #TASK-133 👨‍👩‍👧‍👦", name: "赛博虎妞"))
        XCTAssertNil(TaskCommentMention.validationMessage("👩🏽‍💻 请 @赛博虎妞 核对", name: "赛博虎妞"))
        XCTAssertEqual(TaskCommentMention.submissionBody("普通评论\n保留正文  和空格", name: ""), "普通评论\n保留正文  和空格")
    }

    @MainActor
    func testUnselectedMentionIsRejectedBeforeTheTransportCanSend() async {
        // Nothing listens here: reaching the transport produces a connection error,
        // not the explicit local 400 below. No task/comment can be created.
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        for body in ["@", "@ @", "@赛博虎妞 请执行"] {
            do {
                _ = try await api.postBoardTaskComment(id: "must-not-write", requestId: UUID().uuidString,
                    body: body, employeeId: nil, sourceCommentId: nil)
                XCTFail("Invalid comment reached transport")
            } catch WandAPI.APIError.server(let status, let message) {
                XCTAssertEqual(status, 400)
                XCTAssertTrue(message.contains("选择员工"))
            } catch { XCTFail("Expected local rejection, got \(error)") }
        }
    }

    @MainActor
    func testValidDispatchAndPlainCommentStillReachTheIsolatedTransport() async throws {
        let base = URL(string: "https://task141-transport.example")!
        let api = WandAPI(baseURL: base, token: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Task141ReplyProtocol.self]
        api.endpointSession.session = URLSession(configuration: configuration, delegate: api.endpointSession, delegateQueue: nil)
        defer { Task141ReplyProtocol.handler = nil; SelfSignedSession.resetEndpoint(base) }
        for employee in [nil, "stable-employee"] as [String?] {
            let body = employee == nil ? "普通评论" : TaskCommentMention.submissionBody("@赛博虎妞 @ @赛博虎妞 核对 #TASK-133", name: "赛博虎妞")
            Task141ReplyProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/wand-tasks/task/comments")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let payload = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                XCTAssertEqual(payload["body"] as? String, body)
                XCTAssertEqual(payload["requestId"] as? String, "stable-request")
                XCTAssertEqual(payload["employeeId"] as? String, employee)
                XCTAssertEqual(payload["sourceCommentId"] as? String, "source")
                return try! JSONSerialization.data(withJSONObject: ["comment": ["id": "saved", "taskId": "task", "authorName": "用户", "body": body, "createdAt": "now"]])
            }
            let saved = try await api.postBoardTaskComment(id: "task", requestId: "stable-request", body: body, employeeId: employee, sourceCommentId: "source")
            XCTAssertEqual(saved.id, "saved")
        }
    }

    @MainActor
    func testProductionComposerRejectsBareMentionsAndReplacesTheChosenPreamble() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = Task141ComposerHarnessState()
        let host = UIHostingController(rootView: Task141ComposerHarness(state: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        state.source = "first"
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        var nodes = mentionAccessibilityDescendants(host.view)
        print("TASK141_NODES", nodes.compactMap { node -> String? in
            let id = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
            return id.hasPrefix("task-comment") ? "\(id):\(node.accessibilityLabel ?? ""):\(node.accessibilityValue ?? "")" : nil
        })
        guard nodes.contains(where: { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier?.hasPrefix("task-comment") == true }) else {
            throw XCTSkip("In-process SwiftUI AX tree unavailable on this simulator; production interaction requires external accessibility automation.")
        }
        let submit = try XCTUnwrap(nodes.first { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == "task-comment-submit" }, "Missing production submit button")
        XCTAssertTrue(submit.accessibilityTraits.contains(.notEnabled), "Bare @ must not become a plain comment")
        let first = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "@赛博虎妞" }, "Missing first production mention")
        XCTAssertTrue(first.accessibilityActivate())
        try await Task.sleep(for: .milliseconds(250))
        nodes = mentionAccessibilityDescendants(host.view)
        XCTAssertTrue(nodes.contains { ($0.accessibilityLabel ?? "").contains("请在 @员工 后填写本轮指令") })
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "@石一" })
        state.source = "second"
        try await Task.sleep(for: .milliseconds(250))
        nodes = mentionAccessibilityDescendants(host.view)
        let second = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "@石一" }, "Missing second production mention")
        XCTAssertTrue(second.accessibilityActivate())
        try await Task.sleep(for: .milliseconds(250))
        nodes = mentionAccessibilityDescendants(host.view)
        let values = nodes.compactMap { ($0 as? UITextField)?.text ?? ($0 as? UITextView)?.text ?? $0.accessibilityValue }
        XCTAssertTrue(values.contains("@石一 "), "Expected one selected mention, got \(values)")
        XCTAssertFalse(values.contains { $0.contains("@赛博虎妞") }, "Old mention and trigger @ must be removed")
    }

}

extension TaskCommentsTests {
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

    /// 执行状态文案必须与服务端 `src/task-comment-status.ts` 的词表逐字一致（Web / iOS / Android 同一份）。
    func testExecutionStatusWordingMatchesTheSharedTable() {
        let expected: [String: String] = [
            "queued": "排队中",
            "pending": "等待确认", "accepted": "已创建执行", "running": "执行中", "blocked": "等待审批",
            "idle": "本轮已结束", "exited": "会话已退出", "stopped": "已停止", "failed": "执行失败",
            "done": "已完成", "unknown": "送达未知 · 不会重放", "history": "历史会话", "unavailable": "会话不可用",
        ]
        XCTAssertEqual(TaskCommentStatusLabels.labels, expected, "iOS 状态词表与服务端 src/task-comment-status.ts 漂移")
        XCTAssertEqual(TaskCommentStatusLabels.unknown, "状态未确认")
        for (status, wording) in expected {
            let dispatch = WandTaskCommentDispatch(employeeId: "e", employeeName: "员工", state: "accepted",
                                                   sessionId: nil, status: status, error: nil)
            XCTAssertEqual(dispatch.statusKey, status)
            XCTAssertEqual(dispatch.label, wording, "状态 \(status) 的文案漂移")
        }
        // 状态键优先于派发状态；派发状态只在没有运行状态时接管。
        let pendingState = WandTaskCommentDispatch(employeeId: "e", employeeName: "员工", state: "pending",
                                                    sessionId: nil, status: nil, error: nil)
        XCTAssertEqual(pendingState.statusKey, "pending")
        XCTAssertEqual(pendingState.label, "等待确认")
        // 表里没有的状态统一回落成「状态未确认」，不猜。
        let unknownStatus = WandTaskCommentDispatch(employeeId: "e", employeeName: "员工", state: "accepted",
                                                    sessionId: nil, status: "not-a-status", error: nil)
        XCTAssertEqual(unknownStatus.label, "状态未确认")
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

@MainActor
private final class MentionAccessibilityHarnessState: ObservableObject {
    @Published var selectedEmployeeId = ""
    @Published var chosenName = ""
    @Published var showPicker = true
}

private struct MentionAccessibilityHarness: View {
    @ObservedObject var state: MentionAccessibilityHarnessState
    let employees: [(id: String, name: String)]
    var body: some View {
        Form {
            Section("评论与员工派发") {
                VStack {
                    if state.showPicker {
                        TaskCommentMentionPicker(employees: employees, selectedEmployeeId: state.selectedEmployeeId) { employee in
                            state.selectedEmployeeId = employee.id
                            state.chosenName = employee.name
                            state.showPicker = false
                        }
                    }
                    TextField("评论", text: .constant("@"))
                    Button("发表评论") {}
                }
            }
        }
    }
}

private final class Task141ReplyProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class Task141EditorProbe: ObservableObject {
    @Published var text = "👩🏽‍💻 @赛博虎妞 "
    @Published var selection = NSRange(location: ("👩🏽‍💻 @赛博虎妞 " as NSString).length, length: 0)
}

private struct Task141EditorHarness: View {
    @ObservedObject var probe: Task141EditorProbe
    var body: some View {
        IMEAwareComposerTextView(text: $probe.text, placeholder: "评论", isFocused: true, disableAutocorrect: true,
            submitOnReturn: false, selection: $probe.selection, onFocusChange: { _ in },
            onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in }).frame(height: 100)
    }
}

@MainActor
private final class Task141ComposerHarnessState: ObservableObject {
    @Published var source: String?
}

private struct Task141ComposerHarness: View {
    @ObservedObject var state: Task141ComposerHarnessState
    @State private var taskId = UUID().uuidString
    @State private var replyDispatches = true
    private let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)

    var body: some View {
        ScrollView {
            TaskCommentComposer(api: api, taskId: taskId, employees: [(id: "tiger", name: "赛博虎妞"), (id: "shi", name: "石一")],
                                sourceCommentId: $state.source, replyDispatches: $replyDispatches, onSaved: {})
        }
    }
}

@MainActor
private func mentionAccessibilityDescendants(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func visit(_ object: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        var result = [object]
        if let view = object as? UIView {
            for child in view.subviews { result += visit(child) }
        }
        // SwiftUI content groups can supply an elements array instead of implementing
        // the indexed UIAccessibilityContainer methods. Traverse both representations.
        for child in object.accessibilityElements ?? [] {
            if let child = child as? NSObject { result += visit(child) }
        }
        let count = object.accessibilityElementCount()
        // UIKit uses NSNotFound for objects that are not accessibility containers.
        if count > 0 && count != NSNotFound {
            for index in 0..<min(count, 1000) {
                if let child = object.accessibilityElement(at: index) as? NSObject { result += visit(child) }
            }
        }
        return result
    }
    return visit(root)
}
