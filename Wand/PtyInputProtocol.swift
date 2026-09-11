import Foundation
import UniformTypeIdentifiers

struct PtyInputChunk: Equatable {
    let input: String
    let view: String
    let shortcutKey: String?
}

struct PtyInputSubmission: Equatable {
    let text: PtyInputChunk
    let enter: PtyInputChunk
}

func ptyInputSubmission(text: String, view: String) -> PtyInputSubmission {
    PtyInputSubmission(
        text: PtyInputChunk(input: text, view: view, shortcutKey: "enter_text"),
        enter: PtyInputChunk(input: "\r", view: view, shortcutKey: "enter_text")
    )
}

private let bracketedPasteStart = "\u{001b}[200~"
private let bracketedPasteEnd = "\u{001b}[201~"

/// Encode clipboard text as one terminal paste event.
/// Writing the text as ordinary keystrokes skips Codex image-path attach.
func buildTerminalPasteSequence(_ text: String, bracketed: Bool = true) -> String {
    guard !text.isEmpty else { return "" }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\r")
        .replacingOccurrences(of: "\n", with: "\r")
    guard bracketed else { return normalized }
    let sanitized = normalized.replacingOccurrences(of: "\u{001b}", with: "\u{241b}")
    return "\(bracketedPasteStart)\(sanitized)\(bracketedPasteEnd)"
}

func quoteTerminalPath(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+,=-")
    if path.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return path }
    return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func buildTerminalPathPasteSequence(_ path: String, bracketed: Bool = true) -> String {
    buildTerminalPasteSequence(quoteTerminalPath(path), bracketed: bracketed)
}

func shouldBracketPtyPaste(provider: String?) -> Bool {
    (provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex"
}

func isClipboardImageMimeType(_ type: String?) -> Bool {
    guard let type, !type.isEmpty else { return false }
    return type.lowercased().hasPrefix("image/")
}

func clipboardImageExtension(type: String?) -> String {
    switch (type ?? "").lowercased() {
    case "image/jpeg", "image/jpg": return ".jpg"
    case "image/gif": return ".gif"
    case "image/webp": return ".webp"
    case "image/bmp": return ".bmp"
    case "image/svg+xml": return ".svg"
    default: return ".png"
    }
}

func clipboardImageFileName(originalName: String?, mimeType: String?, index: Int = 0) -> String {
    let fallback = "clipboard-image-\(Int(Date().timeIntervalSince1970 * 1000))-\(index + 1)\(clipboardImageExtension(type: mimeType))"
    let original = (originalName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !original.isEmpty, original.lowercased() != "blob" else { return fallback }
    let hasImageExtension = original.range(of: "\\.(?:png|jpe?g|gif|webp|bmp|svg)$", options: .regularExpression) != nil
    if isClipboardImageMimeType(mimeType), !hasImageExtension { return fallback }
    return original
}

func writeClipboardImageToTemporaryFile(
    data: Data,
    originalName: String?,
    mimeType: String?,
    index: Int = 0
) throws -> URL {
    let name = clipboardImageFileName(originalName: originalName, mimeType: mimeType, index: index)
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try data.write(to: destination, options: .atomic)
    return destination
}

func mimeTypeForPasteItem(typeIdentifier: String) -> String {
    if let type = UTType(typeIdentifier), let mime = type.preferredMIMEType {
        return mime
    }
    if typeIdentifier.hasPrefix("public.") {
        return "image/png"
    }
    return "application/octet-stream"
}
