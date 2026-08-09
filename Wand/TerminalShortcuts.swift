import Foundation

/// 终端快捷键定义与 xterm 按键序列编码，对称 Android `ui/terminal/TerminalShortcuts.kt`。
/// PTY 会话底部快捷栏复用这套定义：点击某个快捷键，把编码后的字节通过
/// `WandAPI.sendInput(view: "terminal", shortcutKey:)` 直接灌进 PTY。

enum TerminalModifier: String, CaseIterable {
    case ctrl = "ctrl"
    case alt = "alt"
    case shift = "shift"

    var label: String {
        switch self {
        case .ctrl: return "Ctrl"
        case .alt: return "Alt"
        case .shift: return "Shift"
        }
    }
}

struct TerminalKeyBinding: Hashable {
    let key: String
    let modifiers: Set<TerminalModifier>
}

struct TerminalShortcut: Identifiable, Hashable {
    let id: String
    let label: String
    let accessibilityLabel: String
    let binding: TerminalKeyBinding
    let builtIn: Bool
    let repeatable: Bool

    /// 编码后的 PTY 字节（点击该快捷键时发送的内容）。
    var bytes: String { TerminalKeyEncoding.encode(binding) ?? "" }
}

struct TerminalShortcuts {
    /// 默认底部快捷栏：Esc / Ctrl+C / Tab / Shift+Tab / 方向键 / Enter。
    /// 与 Android `DefaultTerminalShortcuts` 保持一致，方便两端观感统一。
    static let defaults: [TerminalShortcut] = [
        TerminalShortcut(
            id: "escape",
            label: "Esc",
            accessibilityLabel: "Escape",
            binding: TerminalKeyBinding(key: "escape", modifiers: []),
            builtIn: true,
            repeatable: false
        ),
        TerminalShortcut(
            id: "ctrl-c",
            label: "⌃C",
            accessibilityLabel: "Control C",
            binding: TerminalKeyBinding(key: "c", modifiers: [.ctrl]),
            builtIn: true,
            repeatable: false
        ),
        TerminalShortcut(
            id: "tab",
            label: "Tab",
            accessibilityLabel: "Tab",
            binding: TerminalKeyBinding(key: "tab", modifiers: []),
            builtIn: true,
            repeatable: false
        ),
        TerminalShortcut(
            id: "shift-tab",
            label: "⇧Tab",
            accessibilityLabel: "Shift Tab",
            binding: TerminalKeyBinding(key: "tab", modifiers: [.shift]),
            builtIn: true,
            repeatable: false
        ),
        TerminalShortcut(
            id: "arrow-left",
            label: "←",
            accessibilityLabel: "左方向键",
            binding: TerminalKeyBinding(key: "arrowLeft", modifiers: []),
            builtIn: true,
            repeatable: true
        ),
        TerminalShortcut(
            id: "arrow-up",
            label: "↑",
            accessibilityLabel: "上方向键",
            binding: TerminalKeyBinding(key: "arrowUp", modifiers: []),
            builtIn: true,
            repeatable: true
        ),
        TerminalShortcut(
            id: "arrow-down",
            label: "↓",
            accessibilityLabel: "下方向键",
            binding: TerminalKeyBinding(key: "arrowDown", modifiers: []),
            builtIn: true,
            repeatable: true
        ),
        TerminalShortcut(
            id: "arrow-right",
            label: "→",
            accessibilityLabel: "右方向键",
            binding: TerminalKeyBinding(key: "arrowRight", modifiers: []),
            builtIn: true,
            repeatable: true
        ),
        TerminalShortcut(
            id: "enter",
            label: "⏎",
            accessibilityLabel: "Enter",
            binding: TerminalKeyBinding(key: "enter", modifiers: []),
            builtIn: true,
            repeatable: false
        ),
    ]
}

/// xterm 按键序列编码子集，覆盖快捷栏需要的安全按键。
enum TerminalKeyEncoding {
    private static let escape = "\u{001B}"

    static func encode(_ raw: TerminalKeyBinding) -> String? {
        guard let normalized = normalize(raw) else { return nil }
        let key = normalized.key
        let modifiers = normalized.modifiers

        let csiFinal: [String: String] = [
            "arrowUp": "A",
            "arrowDown": "B",
            "arrowRight": "C",
            "arrowLeft": "D",
            "home": "H",
            "end": "F",
        ]
        if let final = csiFinal[key] {
            let parameter = xtermParameter(modifiers)
            return parameter == 1 ? "\(escape)[\(final)" : "\(escape)[1;\(parameter)\(final)"
        }

        let csiTilde: [String: Int] = [
            "delete": 3,
            "pageUp": 5,
            "pageDown": 6,
        ]
        if let code = csiTilde[key] {
            let parameter = xtermParameter(modifiers)
            return parameter == 1 ? "\(escape)[\(code)~" : "\(escape)[\(code);\(parameter)~"
        }

        switch key {
        case "tab":
            return modifiers == [.shift] ? "\(escape)[Z" : prefixAlt("\t", modifiers)
        case "escape":
            return prefixAlt(escape, modifiers)
        case "enter":
            return prefixAlt("\r", modifiers)
        case "backspace":
            let body = modifiers.contains(.ctrl) ? "\u{08}" : "\u{7F}"
            return prefixAlt(body, modifiers)
        case "space":
            return encodePrintable(" ", modifiers)
        default:
            if key.count == 1, let scalar = key.unicodeScalars.first, (32...126).contains(scalar.value) {
                return encodePrintable(Character(scalar), modifiers)
            }
            return nil
        }
    }

    private static func normalize(_ binding: TerminalKeyBinding) -> TerminalKeyBinding? {
        let specials: Set<String> = [
            "escape", "tab", "enter", "backspace", "delete",
            "arrowUp", "arrowDown", "arrowLeft", "arrowRight",
            "home", "end", "pageUp", "pageDown", "space",
        ]
        let normalizedKey: String
        if specials.contains(binding.key) {
            normalizedKey = binding.key
        } else if binding.key.count == 1,
                  let scalar = binding.key.unicodeScalars.first,
                  (32...126).contains(scalar.value) {
            normalizedKey = String(scalar).lowercased()
        } else {
            return nil
        }
        let ordered = TerminalModifier.allCases.filter { binding.modifiers.contains($0) }
        return TerminalKeyBinding(key: normalizedKey, modifiers: Set(ordered))
    }

    private static func prefixAlt(_ bytes: String, _ modifiers: Set<TerminalModifier>) -> String {
        modifiers.contains(.alt) ? escape + bytes : bytes
    }

    private static func xtermParameter(_ modifiers: Set<TerminalModifier>) -> Int {
        1
            + (modifiers.contains(.shift) ? 1 : 0)
            + (modifiers.contains(.alt) ? 2 : 0)
            + (modifiers.contains(.ctrl) ? 4 : 0)
    }

    private static func encodePrintable(_ raw: Character, _ modifiers: Set<TerminalModifier>) -> String? {
        let shifted = modifiers.contains(.shift) ? applyShift(raw) : raw
        let bytes: String
        if modifiers.contains(.ctrl) {
            guard let control = controlCharacter(shifted) else { return nil }
            bytes = String(control)
        } else {
            bytes = String(shifted)
        }
        return prefixAlt(bytes, modifiers)
    }

    private static func controlCharacter(_ key: Character) -> Character? {
        let lower = Character(key.lowercased())
        if ("a"..."z").contains(lower) {
            guard let scalar = UnicodeScalar(Int(lower.asciiValue ?? 0) - 96) else { return nil }
            return Character(scalar)
        }
        switch key {
        case " ", "@", "`": return Character(UnicodeScalar(0))
        case "[", "{": return Character(UnicodeScalar(27))
        case "\\", "|": return Character(UnicodeScalar(28))
        case "]", "}": return Character(UnicodeScalar(29))
        case "^", "~": return Character(UnicodeScalar(30))
        case "_": return Character(UnicodeScalar(31))
        case "?": return Character(UnicodeScalar(127))
        default: return nil
        }
    }

    private static func applyShift(_ key: Character) -> Character {
        if ("a"..."z").contains(key) {
            return Character(key.uppercased())
        }
        let map: [Character: Character] = [
            "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_",
            "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"",
            ",": "<", ".": ">", "/": "?",
        ]
        return map[key] ?? key
    }
}
