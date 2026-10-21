import Foundation

/// 任务引用（`#TASK-133`）的解析契约，与服务端 `src/task-comment-references.ts` 是同一套规则。
///
/// 规则（Web / iOS / Android 必须一致）：
/// - `#` 紧跟任务编号构成引用标记；`#` 单独出现不是引用，也不匹配 Markdown 标题
///   （ATX 标题要求 `#` 后有空格）。
/// - `#` 前面必须是行首、空白或开括号（`(` `（` `【` `「` `《`）。这样 `做 #TASK-133`、
///   `（#TASK-133）` 是引用，而 `a#TASK-133`、`https://x/doc#TASK-5` 里的 URL 片段不是
///   ——后者会被误当成引用，让服务端以「引用的任务不存在」拒绝整条评论。
/// - 引用只认当前任务的直接子任务；其他编号一律非法（服务端返回 400，客户端不负责判定）。
/// - 同一段正文里可以出现多个引用，也可以和任意多个 `@员工` 混排。
/// - 解析只做「切词」，不判断任务是否存在。
///
/// 与 TypeScript 版本的对应关系（改规则时两边一起改）：
/// - `TASK_REFERENCE_PATTERN` → `referencePattern`
/// - `parseTaskReferenceIds` → `parseIdentifiers`
/// - `commentReferenceQuery` → `query(in:caret:)`
/// - `insertCommentReference` → `insert(body:caret:identifier:)`
/// - `taskReferenceSegments` → `segments(_:)`

/// 一个可被引用的子任务：编号 + 标题 + 状态。
struct TaskReferenceTarget: Equatable, Identifiable, Hashable {
    let id: String
    let identifier: String
    var title: String = ""
    var status: String = ""
}

enum TaskCommentReference {
    struct Segment: Equatable {
        let text: String
        /// 引用片段指向的任务编号；普通文本为 nil。
        let identifier: String?
    }

    struct Query: Equatable {
        /// `#` 在正文（按字符计）中的位置。
        let start: Int
        /// `#` 与光标之间已经输入的查询文本。
        let query: String
    }

    /// 与 TS `TASK_REFERENCE_PATTERN` 等价。
    /// JS 的 `\w`/`\d` 只含 ASCII；ICU 默认按 Unicode 解释，这里显式写出 ASCII 集合保持一致。
    /// 边界组与 TS 的 `(^|[\s(（【「《])` 等价：行首、空白或开括号，其余字符（如 URL 片段
    /// `doc#TASK-5` 里的 `c`）都不是合法边界。
    private static let referencePattern = "(^|[\\t\\n\\u000B\\u000C\\r\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF(（【「《])#([A-Z][A-Z0-9]*-[0-9]+)(?![A-Za-z0-9_-])"
    private static let referenceRegex = try! NSRegularExpression(pattern: referencePattern)
    /// 与 TS `commentReferenceQuery` 里的 `/^[A-Z][A-Z0-9-]*$/` 等价。
    private static let queryRegex = try! NSRegularExpression(pattern: "^[A-Z][A-Z0-9-]*$")

    /// JS `\s` 的等价集合：ECMAScript 的 `\s` 是 White_Space 再加上 U+FEFF（BOM），
    /// 不含 U+0085（NEL）。这里显式列出，避免 Swift `Character.isWhitespace` 与 JS 差一格。
    private static let whitespaceCharacters: Set<Character> = [
        "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
        "\u{00A0}", "\u{1680}",
        "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
        "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}",
        "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
    ]

    /// 与 JS 的 `\s` 判定一致。
    private static func isWhitespaceLike(_ character: Character) -> Bool {
        whitespaceCharacters.contains(character)
    }

    /// `#` 前面允许出现的字符（行首、空白或成对符号），与 TS 的 `/[\s(（【「《]/` 等价。
    private static func isReferenceBoundary(_ character: Character) -> Bool {
        if isWhitespaceLike(character) { return true }
        return "(（【「《".contains(character)
    }

    /// 正文里出现的任务引用编号，按首次出现顺序去重。
    static func parseIdentifiers(_ body: String) -> [String] {
        var identifiers: [String] = []
        for match in referenceMatches(body) {
            let identifier = match.identifier
            if !identifiers.contains(identifier) { identifiers.append(identifier) }
        }
        return identifiers
    }

    /// 正文里是否引用了某个任务编号。
    static func contains(_ body: String, identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        return parseIdentifiers(body).contains(identifier)
    }

    /// 正文中某个引用编号的出现次数。
    static func count(_ body: String, identifier: String) -> Int {
        guard !identifier.isEmpty else { return 0 }
        return referenceMatches(body).filter { $0.identifier == identifier }.count
    }

    /// 把正文里的引用解析成本任务可引用的子任务（只认直接子任务）。
    static func resolve(_ body: String, children: [TaskReferenceTarget]) -> [TaskReferenceTarget] {
        let wanted = parseIdentifiers(body)
        guard !wanted.isEmpty else { return [] }
        let byIdentifier = Dictionary(children.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        return wanted.compactMap { byIdentifier[$0] }
    }

    /// 正文里引用了但不在给定子任务集合中的编号（服务端会以 400 拒绝）。
    static func unknownIdentifiers(_ body: String, children: [TaskReferenceTarget]) -> [String] {
        let known = Set(children.map(\.identifier))
        return parseIdentifiers(body).filter { !known.contains($0) }
    }

    /// 光标处的引用 token：前面必须是行首或空白，避免把 `a#TASK-1` 当成引用。
    static func query(in body: String, caret: Int) -> Query? {
        let characters = Array(body)
        let index = min(max(caret, 0), characters.count)
        guard index > 0 else { return nil }
        guard let at = characters[..<index].lastIndex(of: "#") else { return nil }
        if at > 0 && !isReferenceBoundary(characters[at - 1]) { return nil }
        let text = String(characters[(at + 1)..<index])
        if text.contains(where: { isWhitespaceLike($0) }) { return nil }
        if !text.isEmpty && queryRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { return nil }
        return Query(start: at, query: text)
    }

    /// 插入选中的引用编号；编号本身留在正文里，不额外编码。
    /// 末尾已经紧跟空白时不再补空格，否则正文里会多出一个空格（与 TS `insertCommentReference` 一致）。
    static func insert(body: String, caret: Int, identifier: String) -> (body: String, caret: Int) {
        let characters = Array(body)
        let index = min(max(caret, 0), characters.count)
        let start = query(in: body, caret: index)?.start ?? index
        let followsWhitespace = index < characters.count && isWhitespaceLike(characters[index])
        let token = Array(followsWhitespace ? "#\(identifier)" : "#\(identifier) ")
        return (String(characters[..<start] + token + characters[index...]), start + token.count)
    }

    /// 渲染用：把正文切成「引用 token」与「普通文本」两类片段。
    static func segments(_ body: String) -> [Segment] {
        let source = body as NSString
        var segments: [Segment] = []
        var cursor = 0
        for match in referenceMatches(body) {
            let start = match.tokenStart
            if start > cursor {
                segments.append(Segment(text: source.substring(with: NSRange(location: cursor, length: start - cursor)), identifier: nil))
            }
            segments.append(Segment(text: "#\(match.identifier)", identifier: match.identifier))
            cursor = start + match.identifier.utf16.count + 1
        }
        if cursor < source.length {
            segments.append(Segment(text: source.substring(from: cursor), identifier: nil))
        }
        return segments.isEmpty ? [Segment(text: body, identifier: nil)] : segments
    }

    // MARK: - 内部

    private struct ReferenceMatch {
        /// 引用 token 的 `#` 在 UTF-16 下的位置。
        let tokenStart: Int
        let identifier: String
    }

    private static func referenceMatches(_ body: String) -> [ReferenceMatch] {
        let source = body as NSString
        let range = NSRange(location: 0, length: source.length)
        return referenceRegex.matches(in: body, range: range).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let identifier = source.substring(with: match.range(at: 2))
            guard !identifier.isEmpty else { return nil }
            // 匹配整体包含前缀字符（行首分支为空），token 从 `#` 开始。
            let prefixLength = match.numberOfRanges > 1 ? match.range(at: 1).length : 0
            return ReferenceMatch(tokenStart: match.range.location + prefixLength, identifier: identifier)
        }
    }
}
