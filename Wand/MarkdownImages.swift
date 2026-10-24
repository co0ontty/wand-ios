import Foundation

/// Inline image parsing shared by reply rendering and the conversation gallery.
/// Fenced code is excluded by MarkdownText.parseBlocks before calling this scanner.
enum MarkdownImagePiece: Equatable {
    case text(String)
    case image(alt: String, source: String)
}

func splitMarkdownImages(_ raw: String) -> [MarkdownImagePiece] {
    let chars = Array(raw)
    var result: [MarkdownImagePiece] = []
    var start = 0
    var index = 0
    while index < chars.count {
        if chars[index] == "\\" {
            // Escaping an image marker must not turn its remaining [label] into a preview link.
            if index + 1 < chars.count, chars[index + 1] == "!", let image = parseMarkdownImage(chars, at: index + 1) {
                index = image.end
            } else { index += min(2, chars.count - index) }
            continue
        }
        if chars[index] == "`" {
            var end = index
            while end < chars.count, chars[end] == "`" { end += 1 }
            let count = end - index
            var cursor = end
            var closing: Int?
            while cursor < chars.count {
                if chars[cursor] != "`" { cursor += 1; continue }
                let run = cursor
                while cursor < chars.count, chars[cursor] == "`" { cursor += 1 }
                if cursor - run == count { closing = cursor; break }
            }
            index = closing ?? end
            continue
        }
        if let image = parseMarkdownImage(chars, at: index) {
            if start < index { result.append(.text(String(chars[start..<index]))) }
            result.append(.image(alt: image.alt, source: image.source))
            index = image.end
            start = index
        } else { index += 1 }
    }
    if start < chars.count { result.append(.text(String(chars[start...]))) }
    return result.isEmpty ? [.text(raw)] : result
}

private func parseMarkdownImage(_ chars: [Character], at start: Int) -> (alt: String, source: String, end: Int)? {
    let explicitImage = chars[start] == "!"
    let bracket = start + (explicitImage ? 1 : 0)
    guard bracket < chars.count, chars[bracket] == "[" else { return nil }
    var index = bracket + 1
    var depth = 1
    var alt = ""
    while index < chars.count {
        let ch = chars[index]
        if ch == "\\", index + 1 < chars.count { alt.append(chars[index + 1]); index += 2; continue }
        if ch == "[" { depth += 1 }
        if ch == "]" { depth -= 1; if depth == 0 { break } }
        alt.append(ch)
        index += 1
    }
    guard depth == 0, index + 1 < chars.count, chars[index + 1] == "(" else { return nil }
    index += 2
    while index < chars.count, chars[index].isWhitespace { index += 1 }
    var source = ""
    if index < chars.count, chars[index] == "<" {
        index += 1
        while index < chars.count, chars[index] != ">" {
            if chars[index] == "\n" { return nil }
            if chars[index] == "\\", index + 1 < chars.count { index += 1 }
            source.append(chars[index]); index += 1
        }
        guard index < chars.count else { return nil }
        index += 1
    } else {
        depth = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count { source.append(chars[index + 1]); index += 2; continue }
            if ch == ")", depth == 0 { break }
            if ch.isWhitespace, depth == 0 { break }
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            source.append(ch); index += 1
        }
        guard depth == 0 else { return nil }
    }
    guard !source.isEmpty else { return nil }
    let beforeSpace = index
    while index < chars.count, chars[index].isWhitespace { index += 1 }
    if index > beforeSpace, index < chars.count, (chars[index] == "\"" || chars[index] == "'") {
        let quote = chars[index]
        index += 1
        while index < chars.count, chars[index] != quote {
            if chars[index] == "\\", index + 1 < chars.count { index += 1 }
            index += 1
        }
        guard index < chars.count else { return nil }
        index += 1
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }
    guard index < chars.count, chars[index] == ")" else { return nil }
    guard explicitImage || markdownLinkIsImage(source) else { return nil }
    return (alt, source, index + 1)
}

/// Absolute filesystem paths refer to the connected server, never the phone.
/// Relative paths without a source-session context and unsafe URL schemes are rejected.
func markdownImagePage(_ raw: String) -> WandImagePage? {
    let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty, !source.unicodeScalars.contains(where: { $0.value < 32 }), !source.hasPrefix("//") else { return nil }
    let lower = source.lowercased()
    if lower.hasPrefix("data:image/"), lower.contains(";base64,") { return WandImagePage(source: "data:" + source.dropFirst(5), directSource: true) }
    if source.hasPrefix("/api/") { return WandImagePage(source: source, directSource: true) }
    if source.hasPrefix("/") {
        return WandImagePage(source: source.removingPercentEncoding ?? source, directSource: false)
    }
    guard let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
    return WandImagePage(source: source, directSource: true)
}

/// Classify the link destination, never its label. Keep documents and unknown web pages as links.
private func markdownLinkIsImage(_ source: String) -> Bool {
    guard let page = markdownImagePage(source) else { return false }
    if page.source.lowercased().hasPrefix("data:image/") { return true }
    if !page.directSource { return isImagePath(page.source) }
    guard let url = URLComponents(string: page.source) else { return false }
    if url.path == "/api/file-raw", let path = url.queryItems?.first(where: { $0.name == "path" })?.value {
        return isImagePath(path)
    }
    return isImagePath(url.path)
}
