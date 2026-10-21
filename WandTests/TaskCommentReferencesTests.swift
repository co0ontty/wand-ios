import Foundation
import XCTest
@testable import Wand

/// `#TASK-133` 引用解析：与服务端 `src/task-comment-references.ts` 是同一套规则。
final class TaskCommentReferencesTests: XCTestCase {
    func testRecognisesTaskReferenceTokens() {
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("看下 #TASK-133 的进度"), ["TASK-133"])
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("#TASK-133"), ["TASK-133"])
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("a #TASK-1 和 #TASK-2"), ["TASK-1", "TASK-2"])
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("重复 #TASK-133 又 #TASK-133"), ["TASK-133"])
        XCTAssertEqual(TaskCommentReference.count("重复 #TASK-133 又 #TASK-133", identifier: "TASK-133"), 2)
        XCTAssertTrue(TaskCommentReference.contains("见 #TASK-133", identifier: "TASK-133"))
        XCTAssertFalse(TaskCommentReference.contains("见 #TASK-134", identifier: "TASK-133"))
    }

    func testMarkdownHeadingIsNotAReference() {
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("## 今日进展").isEmpty)
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("# 标题").isEmpty)
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("### TASK-133").isEmpty)
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("####TASK-133").isEmpty)
    }

    func testHashInsideOrdinaryWordIsNotAReference() {
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("a#TASK-133").isEmpty)
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("C#TASK-133").isEmpty)
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("issue#TASK-133").isEmpty)
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("#TASK-133x").isEmpty)
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("#TASK-133-").isEmpty)
    }

    /// `#` 前面必须是行首、空白或开括号（`(` `（` `【` `「` `《`）；
    /// 其它字符（尤其是 URL 片段里的 `doc#TASK-5`）不是合法边界。
    func testStrictReferenceBoundary() {
        // 粘贴的 URL 片段不是引用：否则服务端会以「引用的任务不存在」拒绝整条评论。
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("https://x/doc#TASK-5").isEmpty)
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("http://x/#TASK-133").isEmpty)
        XCTAssertTrue(TaskCommentReference.segments("https://x/doc#TASK-5").map(\.identifier).allSatisfy { $0 == nil })
        // 紧贴文字的 `#` 仍不是引用。
        XCTAssertTrue(TaskCommentReference.parseIdentifiers("a#TASK-133").isEmpty)
        // 行首、空白与开括号是合法边界。
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("（#TASK-133）"), ["TASK-133"])
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("(#TASK-133)"), ["TASK-133"])
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("「#TASK-133」"), ["TASK-133"])
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("《#TASK-133》"), ["TASK-133"])
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("【#TASK-133】"), ["TASK-133"])
        // 同一段里只有真正的那一个引用。
        XCTAssertEqual(TaskCommentReference.parseIdentifiers("看 https://x/doc#TASK-5 后写 #TASK-133"), ["TASK-133"])
        let segments = TaskCommentReference.segments("看 https://x/doc#TASK-5 后写 #TASK-133")
        XCTAssertEqual(segments.map(\.text), ["看 https://x/doc#TASK-5 后写 ", "#TASK-133"])
        XCTAssertEqual(segments.map { $0.identifier ?? "" }, ["", "TASK-133"])
    }

    func testInsertKeepsIdentifierAndAddsTrailingSpace() {
        let inserted = TaskCommentReference.insert(body: "看下 #TASK", caret: "看下 #TASK".count, identifier: "TASK-133")
        XCTAssertEqual(inserted.body, "看下 #TASK-133 ")
        XCTAssertEqual(inserted.caret, inserted.body.count)
        let plain = TaskCommentReference.insert(body: "直接插入", caret: 4, identifier: "TASK-133")
        XCTAssertEqual(plain.body, "直接插入#TASK-133 ")
        // 后面已经紧跟空白时不再补空格，否则正文里会多出一个空格。
        let followed = TaskCommentReference.insert(body: "写 #TASK-13 帮我看看", caret: 10, identifier: "TASK-133")
        XCTAssertEqual(followed.body, "写 #TASK-133 帮我看看")
        XCTAssertEqual(followed.caret, "写 #TASK-133".count)
    }

    func testQueryOnlyOpensAfterWhitespaceOrLineStart() {
        XCTAssertEqual(TaskCommentReference.query(in: "看下 #TASK", caret: "看下 #TASK".count)?.query, "TASK")
        XCTAssertEqual(TaskCommentReference.query(in: "#TASK", caret: "#TASK".count)?.start, 0)
        XCTAssertNil(TaskCommentReference.query(in: "#TASK", caret: 0))
        XCTAssertNil(TaskCommentReference.query(in: "a#TASK", caret: "a#TASK".count))
        XCTAssertNil(TaskCommentReference.query(in: "看下 #TASK 后面", caret: "看下 #TASK 后面".count))
        XCTAssertNil(TaskCommentReference.query(in: "看下 #task", caret: "看下 #task".count))
        // 开括号也是合法边界。
        XCTAssertEqual(TaskCommentReference.query(in: "（#TASK", caret: 3)?.start, 1)
        // URL 片段里的 `#` 不开选择器。
        XCTAssertNil(TaskCommentReference.query(in: "看 https://x/doc#TASK-5 后写 #TASK", caret: 21))
        XCTAssertEqual(TaskCommentReference.query(in: "看 https://x/doc#TASK-5 后写 #TASK-133", caret: 29)?.start, 26)
    }

    func testSegmentsSplitReferenceTokensFromPlainText() {
        let segments = TaskCommentReference.segments("先看 #TASK-133 再看 #TASK-134 结束")
        XCTAssertEqual(segments.map(\.text), ["先看 ", "#TASK-133", " 再看 ", "#TASK-134", " 结束"])
        XCTAssertEqual(segments.map(\.identifier), [nil, "TASK-133", nil, "TASK-134", nil])
        let plain = TaskCommentReference.segments("没有引用")
        XCTAssertEqual(plain.map(\.text), ["没有引用"])
        XCTAssertEqual(plain.map(\.identifier), [nil])
    }

    func testResolveOnlyAcceptsDirectChildren() {
        let children = [
            TaskReferenceTarget(id: "c1", identifier: "TASK-133", title: "去重"),
            TaskReferenceTarget(id: "c2", identifier: "TASK-134", title: "按需挂载")
        ]
        XCTAssertEqual(TaskCommentReference.resolve("做 #TASK-133", children: children).map(\.id), ["c1"])
        XCTAssertEqual(TaskCommentReference.resolve("做 #TASK-133 和 #TASK-134", children: children).map(\.identifier), ["TASK-133", "TASK-134"])
        XCTAssertTrue(TaskCommentReference.resolve("没有引用", children: children).isEmpty)
        XCTAssertEqual(TaskCommentReference.unknownIdentifiers("做 #TASK-999", children: children), ["TASK-999"])
        XCTAssertTrue(TaskCommentReference.unknownIdentifiers("做 #TASK-133", children: children).isEmpty)
    }

    /// 与服务端 `src/task-comment-references.ts` 共享的契约样例（样例由该实现生成）。
    func testMatchesTheSharedServerContractSamples() {
        let samples: [(body: String, identifiers: [String], segments: [String], segmentIdentifiers: [String])] = [
            ("看下 #TASK-133 的进度", ["TASK-133"], ["看下 ", "#TASK-133", " 的进度"], ["", "TASK-133", ""]),
            ("#TASK-133", ["TASK-133"], ["#TASK-133"], ["TASK-133"]),
            ("a #TASK-1 和 #TASK-2", ["TASK-1", "TASK-2"], ["a ", "#TASK-1", " 和 ", "#TASK-2"], ["", "TASK-1", "", "TASK-2"]),
            ("重复 #TASK-133 又 #TASK-133", ["TASK-133"], ["重复 ", "#TASK-133", " 又 ", "#TASK-133"], ["", "TASK-133", "", "TASK-133"]),
            ("## 今日进展", [], ["## 今日进展"], [""]),
            ("# 标题", [], ["# 标题"], [""]),
            ("### TASK-133", [], ["### TASK-133"], [""]),
            ("####TASK-133", [], ["####TASK-133"], [""]),
            ("a#TASK-133", [], ["a#TASK-133"], [""]),
            ("C#TASK-133", [], ["C#TASK-133"], [""]),
            ("issue#TASK-133", [], ["issue#TASK-133"], [""]),
            ("#TASK-133x", [], ["#TASK-133x"], [""]),
            ("#TASK-133-", [], ["#TASK-133-"], [""]),
            ("先看 #TASK-133 再看 #TASK-134 结束", ["TASK-133", "TASK-134"], ["先看 ", "#TASK-133", " 再看 ", "#TASK-134", " 结束"], ["", "TASK-133", "", "TASK-134", ""]),
            ("（#TASK-133）", ["TASK-133"], ["（", "#TASK-133", "）"], ["", "TASK-133", ""]),
            ("(#TASK-133)", ["TASK-133"], ["(", "#TASK-133", ")"], ["", "TASK-133", ""]),
            ("「#TASK-133」", ["TASK-133"], ["「", "#TASK-133", "」"], ["", "TASK-133", ""]),
            ("《#TASK-133》", ["TASK-133"], ["《", "#TASK-133", "》"], ["", "TASK-133", ""]),
            ("【#TASK-133】", ["TASK-133"], ["【", "#TASK-133", "】"], ["", "TASK-133", ""]),
            ("=#TASK-133", [], ["=#TASK-133"], [""]),
            ("a b#TASK-133", [], ["a b#TASK-133"], [""]),
            ("https://x/doc#TASK-5", [], ["https://x/doc#TASK-5"], [""]),
            ("http://x/#TASK-133", [], ["http://x/#TASK-133"], [""]),
            ("看 https://x/doc#TASK-5 后写 #TASK-133", ["TASK-133"], ["看 https://x/doc#TASK-5 后写 ", "#TASK-133"], ["", "TASK-133"]),
            ("#TASK-1#TASK-2", ["TASK-1"], ["#TASK-1", "#TASK-2"], ["TASK-1", ""]),
            ("换行\n#TASK-133", ["TASK-133"], ["换行\n", "#TASK-133"], ["", "TASK-133"]),
            ("尾随 #TASK-133", ["TASK-133"], ["尾随 ", "#TASK-133"], ["", "TASK-133"]),
            ("#TASK-133 #TASK-134", ["TASK-133", "TASK-134"], ["#TASK-133", " ", "#TASK-134"], ["TASK-133", "", "TASK-134"]),
            ("普通文本没有引用", [], ["普通文本没有引用"], [""]),
            ("abc#TASK-133", [], ["abc#TASK-133"], [""]),
            ("TASK-133", [], ["TASK-133"], [""]),
            ("小写#task-133", [], ["小写#task-133"], [""]),
            ("#TASK-abc", [], ["#TASK-abc"], [""]),
            ("#t-1", [], ["#t-1"], [""]),
            ("#TASK-133 后面 #TASK-134", ["TASK-133", "TASK-134"], ["#TASK-133", " 后面 ", "#TASK-134"], ["TASK-133", "", "TASK-134"]),
        ]
        for sample in samples {
            XCTAssertEqual(TaskCommentReference.parseIdentifiers(sample.body), sample.identifiers, sample.body)
            XCTAssertEqual(TaskCommentReference.segments(sample.body).map(\.text), sample.segments, sample.body)
            XCTAssertEqual(TaskCommentReference.segments(sample.body).map { $0.identifier ?? "" }, sample.segmentIdentifiers, sample.body)
        }
    }

    /// 光标查询与插入：与服务端 `src/task-comment-references.ts` 共享的契约样例。
    func testQueryAndInsertMatchTheSharedServerContractSamples() {
        let samples: [(body: String, caret: Int, queryStart: Int?, queryText: String?, inserted: String, insertedCaret: Int)] = [
            ("", 0, nil, nil, "#TASK-133 ", 10),
            ("#TASK", 0, nil, nil, "#TASK-133 #TASK", 10),
            ("#TASK", 5, 0, "TASK", "#TASK-133 ", 10),
            ("look #TASK", 10, 5, "TASK", "look #TASK-133 ", 15),
            ("look #TASK tail", 14, nil, nil, "look #TASK tai#TASK-133 l", 24),
            ("look #task", 10, nil, nil, "look #task#TASK-133 ", 20),
            ("a#TASK", 6, nil, nil, "a#TASK#TASK-133 ", 16),
            ("( #TASK", 8, 2, "TASK", "( #TASK-133 ", 12),
            ("\n#TASK", 6, 1, "TASK", "\n#TASK-133 ", 11),
            ("x #TASK-13", 10, 2, "TASK-13", "x #TASK-133 ", 12),
            ("写 #TASK-13 帮我看看", 10, 2, "TASK-13", "写 #TASK-133 帮我看看", 11),
            ("（#TASK", 3, 1, "T", "（#TASK-133 ASK", 11),
            ("看 https://x/doc#TASK-5 后写 #TASK", 21, nil, nil, "看 https://x/doc#TASK-#TASK-133 5 后写 #TASK", 31),
            ("看 https://x/doc#TASK-5 后写 #TASK-133", 29, 26, "TA", "看 https://x/doc#TASK-5 后写 #TASK-133 SK-133", 36),
        ]
        for sample in samples {
            let query = TaskCommentReference.query(in: sample.body, caret: sample.caret)
            XCTAssertEqual(query?.start, sample.queryStart, sample.body)
            XCTAssertEqual(query?.query, sample.queryText, sample.body)
            let inserted = TaskCommentReference.insert(body: sample.body, caret: sample.caret, identifier: "TASK-133")
            XCTAssertEqual(inserted.body, sample.inserted, sample.body)
            XCTAssertEqual(inserted.caret, sample.insertedCaret, sample.body)
        }
    }
}

/// 执行卡片上的「目标 #TASK-133」芯片：展示编号（用户写进正文的句柄），不是内部 UUID。
final class TaskCommentReferenceTargetsTests: XCTestCase {
    /// 子任务：内部 ID 与编号是两回事，界面只能用编号。
    private let children = [
        TaskReferenceTarget(id: "child-uuid-1", identifier: "TASK-133", title: "去重"),
        TaskReferenceTarget(id: "child-uuid-2", identifier: "TASK-134", title: "按需挂载"),
    ]

    /// 服务端在评论投影里给了编号：直接用。
    func testUsesServerProvidedIdentifiers() throws {
        let comment = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"t","authorName":"用户","body":"@员工 看 #TASK-133","createdAt":"now","referencedTaskIdentifiers":["TASK-133"]}"#.utf8))
        XCTAssertEqual(TaskCommentReferenceTargets.identifiers(for: comment, children: children), ["TASK-133"])
    }

    /// 只有内部 ID 时，用本任务的子任务列表把 ID 换回编号。
    func testResolvesIdentifiersFromChildTasksWhenOnlyIdsAreKnown() throws {
        let comment = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"t","authorName":"用户","body":"@员工 看 #TASK-133","createdAt":"now","referencedTaskIds":["child-uuid-1"]}"#.utf8))
        let identifiers = TaskCommentReferenceTargets.identifiers(for: comment, children: children)
        XCTAssertEqual(identifiers, ["TASK-133"])
        XCTAssertFalse(identifiers.contains("child-uuid-1"), "内部 UUID 不能进界面")
    }

    /// 派发记录里的内部 ID 同样能换回编号。
    func testResolvesIdentifiersFromDispatchReferencedIds() throws {
        let comment = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"t","authorName":"用户","body":"@员工 看 #TASK-134","createdAt":"now","dispatch":{"employeeId":"e","employeeName":"员工","state":"accepted","sessionId":"s","status":"idle","error":null,"referencedTaskIds":["child-uuid-2"]}}"#.utf8))
        XCTAssertEqual(TaskCommentReferenceTargets.identifiers(for: comment, children: children), ["TASK-134"])
    }

    /// 多个引用按正文出现顺序都展示。
    func testKeepsEveryReferencedIdentifierInOrder() throws {
        let comment = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"t","authorName":"用户","body":"@员工 看 #TASK-133 和 #TASK-134","createdAt":"now","referencedTaskIdentifiers":["TASK-133","TASK-134"]}"#.utf8))
        XCTAssertEqual(TaskCommentReferenceTargets.identifiers(for: comment, children: children), ["TASK-133", "TASK-134"])
    }

    /// 没有引用就不显示这一行；换不到编号的内部 ID 也不显示（不猜、不漏 UUID）。
    func testWithoutReferencesNothingIsShown() throws {
        let plain = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"t","authorName":"用户","body":"@员工 干活","createdAt":"now"}"#.utf8))
        XCTAssertTrue(TaskCommentReferenceTargets.identifiers(for: plain, children: children).isEmpty)
        let unknown = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"t","authorName":"用户","body":"@员工 干活","createdAt":"now","referencedTaskIds":["not-a-child"]}"#.utf8))
        XCTAssertTrue(TaskCommentReferenceTargets.identifiers(for: unknown, children: children).isEmpty)
    }
}

extension TaskCommentReferenceTargetsTests {
    /// 同一个引用只展示一次：界面用编号做 identity，重复会撞。
    func testDeduplicatesRepeatedIdentifiers() throws {
        let comment = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"t","authorName":"用户","body":"@员工 看 #TASK-133","createdAt":"now","referencedTaskIdentifiers":["TASK-133","TASK-133"]}"#.utf8))
        XCTAssertEqual(TaskCommentReferenceTargets.identifiers(for: comment, children: children), ["TASK-133"])
    }
}
