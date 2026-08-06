import Foundation
import SwiftUI

private let terminalEscape = "\u{1B}"

enum TerminalModifier: String, CaseIterable, Codable, Hashable, Identifiable {
    case control
    case alt
    case shift

    var id: String { rawValue }

    var label: String {
        switch self {
        case .control: return "Ctrl"
        case .alt: return "Alt"
        case .shift: return "Shift"
        }
    }
}

struct TerminalKeyBinding: Codable, Hashable {
    let key: String
    let modifiers: Set<TerminalModifier>

    init(_ key: String, modifiers: Set<TerminalModifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

struct TerminalShortcut: Identifiable, Hashable {
    let id: String
    let label: String
    let accessibilityLabel: String
    let binding: TerminalKeyBinding
    let builtIn: Bool
    let repeatable: Bool

    var bytes: String { encodeTerminalKey(binding) ?? "" }
}

struct TerminalShortcutSnapshot: Equatable {
    let visibleBuiltInIDs: Set<String>
    let customShortcuts: [TerminalShortcut]
    let hasSeenGuide: Bool

    var visibleShortcuts: [TerminalShortcut] {
        builtInTerminalShortcuts.filter { visibleBuiltInIDs.contains($0.id) } + customShortcuts
    }
}

struct TerminalSpecialKey: Identifiable, Hashable {
    let id: String
    let label: String
    let accessibilityLabel: String
}

let terminalSpecialKeys: [TerminalSpecialKey] = [
    TerminalSpecialKey(id: "escape", label: "Esc", accessibilityLabel: "Escape"),
    TerminalSpecialKey(id: "tab", label: "Tab", accessibilityLabel: "Tab"),
    TerminalSpecialKey(id: "enter", label: "Enter", accessibilityLabel: "Enter"),
    TerminalSpecialKey(id: "backspace", label: "⌫", accessibilityLabel: "退格"),
    TerminalSpecialKey(id: "delete", label: "Del", accessibilityLabel: "向前删除"),
    TerminalSpecialKey(id: "arrowLeft", label: "←", accessibilityLabel: "左方向键"),
    TerminalSpecialKey(id: "arrowUp", label: "↑", accessibilityLabel: "上方向键"),
    TerminalSpecialKey(id: "arrowDown", label: "↓", accessibilityLabel: "下方向键"),
    TerminalSpecialKey(id: "arrowRight", label: "→", accessibilityLabel: "右方向键"),
    TerminalSpecialKey(id: "home", label: "Home", accessibilityLabel: "行首"),
    TerminalSpecialKey(id: "end", label: "End", accessibilityLabel: "行尾"),
    TerminalSpecialKey(id: "pageUp", label: "PgUp", accessibilityLabel: "向上翻页"),
    TerminalSpecialKey(id: "pageDown", label: "PgDn", accessibilityLabel: "向下翻页"),
    TerminalSpecialKey(id: "space", label: "Space", accessibilityLabel: "空格"),
]

let builtInTerminalShortcuts: [TerminalShortcut] = [
    builtInTerminalShortcut("escape", TerminalKeyBinding("escape")),
    builtInTerminalShortcut("tab", TerminalKeyBinding("tab")),
    builtInTerminalShortcut("arrowLeft", TerminalKeyBinding("arrowLeft"), repeatable: true),
    builtInTerminalShortcut("arrowUp", TerminalKeyBinding("arrowUp"), repeatable: true),
    builtInTerminalShortcut("arrowDown", TerminalKeyBinding("arrowDown"), repeatable: true),
    builtInTerminalShortcut("arrowRight", TerminalKeyBinding("arrowRight"), repeatable: true),
    builtInTerminalShortcut(
        "ctrlC", TerminalKeyBinding("c", modifiers: [.control]), accessibilityLabel: "中断当前任务"
    ),
    builtInTerminalShortcut(
        "ctrlD", TerminalKeyBinding("d", modifiers: [.control]), accessibilityLabel: "发送 EOF"
    ),
    builtInTerminalShortcut(
        "ctrlL", TerminalKeyBinding("l", modifiers: [.control]), accessibilityLabel: "清空终端画面"
    ),
    builtInTerminalShortcut(
        "ctrlR", TerminalKeyBinding("r", modifiers: [.control]), accessibilityLabel: "反向搜索历史"
    ),
    builtInTerminalShortcut(
        "ctrlA", TerminalKeyBinding("a", modifiers: [.control]), accessibilityLabel: "移动到行首"
    ),
    builtInTerminalShortcut(
        "ctrlE", TerminalKeyBinding("e", modifiers: [.control]), accessibilityLabel: "移动到行尾"
    ),
    builtInTerminalShortcut(
        "ctrlW", TerminalKeyBinding("w", modifiers: [.control]), accessibilityLabel: "删除前一个单词"
    ),
    builtInTerminalShortcut(
        "ctrlU", TerminalKeyBinding("u", modifiers: [.control]), accessibilityLabel: "清除光标前内容"
    ),
    builtInTerminalShortcut(
        "ctrlZ", TerminalKeyBinding("z", modifiers: [.control]), accessibilityLabel: "挂起当前进程"
    ),
    builtInTerminalShortcut(
        "shiftTab", TerminalKeyBinding("tab", modifiers: [.shift]), accessibilityLabel: "反向 Tab"
    ),
    builtInTerminalShortcut("enter", TerminalKeyBinding("enter")),
    builtInTerminalShortcut("backspace", TerminalKeyBinding("backspace"), repeatable: true),
    builtInTerminalShortcut("delete", TerminalKeyBinding("delete"), repeatable: true),
    builtInTerminalShortcut("home", TerminalKeyBinding("home"), repeatable: true),
    builtInTerminalShortcut("end", TerminalKeyBinding("end"), repeatable: true),
    builtInTerminalShortcut("pageUp", TerminalKeyBinding("pageUp"), repeatable: true),
    builtInTerminalShortcut("pageDown", TerminalKeyBinding("pageDown"), repeatable: true),
]

let defaultVisibleTerminalShortcutIDs: Set<String> = [
    "escape",
    "tab",
    "arrowLeft",
    "arrowUp",
    "arrowDown",
    "arrowRight",
    "ctrlC",
    "ctrlD",
    "ctrlL",
]

let maxCustomTerminalShortcuts = 12

func buildTerminalShortcut(
    _ binding: TerminalKeyBinding,
    id: String = "custom-\(UUID().uuidString)",
    builtIn: Bool = false,
    accessibilityLabel: String? = nil
) -> TerminalShortcut? {
    guard let normalized = normalizedTerminalBinding(binding),
          encodeTerminalKey(normalized) != nil else {
        return nil
    }
    let label = terminalShortcutLabel(normalized)
    let repeatableKeys: Set<String> = [
        "arrowLeft", "arrowUp", "arrowDown", "arrowRight",
        "backspace", "delete", "home", "end", "pageUp", "pageDown",
    ]
    return TerminalShortcut(
        id: id,
        label: label,
        accessibilityLabel: accessibilityLabel ?? terminalShortcutAccessibilityLabel(normalized),
        binding: normalized,
        builtIn: builtIn,
        repeatable: repeatableKeys.contains(normalized.key)
    )
}

func normalizeTerminalKeyInput(_ raw: String) -> String? {
    guard let scalar = raw.unicodeScalars.first(where: { scalar in
        scalar != "\n" && scalar != "\r" && scalar != "\t"
    }), (32...126).contains(Int(scalar.value)) else {
        return nil
    }
    return String(Character(String(scalar))).lowercased()
}

func terminalShortcutLabel(_ binding: TerminalKeyBinding) -> String {
    guard let normalized = normalizedTerminalBinding(binding) else { return "" }
    let modifierLabels = TerminalModifier.allCases
        .filter { normalized.modifiers.contains($0) }
        .map(\.label)
    let keyLabel = terminalSpecialKeys.first(where: { $0.id == normalized.key })?.label
        ?? normalized.key.uppercased()
    return (modifierLabels + [keyLabel]).joined(separator: "+")
}

/// Encodes the xterm control sequences that are safe to write directly to a PTY.
func encodeTerminalKey(_ binding: TerminalKeyBinding) -> String? {
    guard let normalized = normalizedTerminalBinding(binding) else { return nil }
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
        let parameter = xtermModifierParameter(modifiers)
        return parameter == 1
            ? "\(terminalEscape)[\(final)"
            : "\(terminalEscape)[1;\(parameter)\(final)"
    }

    let csiTilde: [String: Int] = [
        "delete": 3,
        "pageUp": 5,
        "pageDown": 6,
    ]
    if let value = csiTilde[key] {
        let parameter = xtermModifierParameter(modifiers)
        return parameter == 1
            ? "\(terminalEscape)[\(value)~"
            : "\(terminalEscape)[\(value);\(parameter)~"
    }

    switch key {
    case "tab":
        if modifiers == [.shift] { return "\(terminalEscape)[Z" }
        return prefixAlt("\t", modifiers: modifiers)
    case "escape":
        return prefixAlt(terminalEscape, modifiers: modifiers)
    case "enter":
        return prefixAlt("\r", modifiers: modifiers)
    case "backspace":
        return prefixAlt(modifiers.contains(.control) ? "\u{8}" : "\u{7F}", modifiers: modifiers)
    case "space":
        return encodePrintable(" ", modifiers: modifiers)
    default:
        guard key.unicodeScalars.count == 1,
              let scalar = key.unicodeScalars.first,
              (32...126).contains(Int(scalar.value)) else {
            return nil
        }
        return encodePrintable(Character(String(scalar)), modifiers: modifiers)
    }
}

@MainActor
final class TerminalShortcutPreferences: ObservableObject {
    private enum Key {
        static let visibleBuiltIns = "wand.terminal-shortcuts.visible-built-ins.v1"
        static let customShortcuts = "wand.terminal-shortcuts.custom.v1"
        static let guideSeen = "wand.terminal-shortcuts.quick-guide-seen.v1"
    }

    private struct StoredShortcut: Codable {
        let id: String
        let key: String
        let modifiers: [TerminalModifier]
    }

    @Published private(set) var snapshot: TerminalShortcutSnapshot

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshot = Self.readSnapshot(from: defaults)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func reload() {
        let next = Self.readSnapshot(from: defaults)
        if next != snapshot { snapshot = next }
    }

    func setBuiltInVisible(_ id: String, visible: Bool) {
        guard builtInTerminalShortcuts.contains(where: { $0.id == id }) else { return }
        var next = snapshot.visibleBuiltInIDs
        if visible {
            next.insert(id)
        } else {
            next.remove(id)
        }
        defaults.set(Array(next).sorted(), forKey: Key.visibleBuiltIns)
        reload()
    }

    func resetBuiltIns() {
        defaults.removeObject(forKey: Key.visibleBuiltIns)
        reload()
    }

    @discardableResult
    func addCustomShortcut(_ binding: TerminalKeyBinding) -> TerminalShortcut? {
        guard let shortcut = buildTerminalShortcut(binding) else { return nil }
        let next = Array((snapshot.customShortcuts + [shortcut]).suffix(maxCustomTerminalShortcuts))
        writeCustomShortcuts(next)
        reload()
        return shortcut
    }

    func deleteCustomShortcut(_ id: String) {
        writeCustomShortcuts(snapshot.customShortcuts.filter { $0.id != id })
        reload()
    }

    func markGuideSeen(_ seen: Bool = true) {
        defaults.set(seen, forKey: Key.guideSeen)
        reload()
    }

    private func writeCustomShortcuts(_ shortcuts: [TerminalShortcut]) {
        let stored = shortcuts.map { shortcut in
            StoredShortcut(
                id: shortcut.id,
                key: shortcut.binding.key,
                modifiers: TerminalModifier.allCases.filter { shortcut.binding.modifiers.contains($0) }
            )
        }
        defaults.set(try? JSONEncoder().encode(stored), forKey: Key.customShortcuts)
    }

    private static func readSnapshot(from defaults: UserDefaults) -> TerminalShortcutSnapshot {
        let builtInIDs = Set(builtInTerminalShortcuts.map(\.id))
        let visibleIDs: Set<String>
        if defaults.object(forKey: Key.visibleBuiltIns) == nil {
            visibleIDs = defaultVisibleTerminalShortcutIDs
        } else if let rawIDs = defaults.array(forKey: Key.visibleBuiltIns) as? [String] {
            visibleIDs = Set(rawIDs).intersection(builtInIDs)
        } else {
            visibleIDs = defaultVisibleTerminalShortcutIDs
        }

        let customShortcuts: [TerminalShortcut]
        if let data = defaults.data(forKey: Key.customShortcuts),
           let stored = try? JSONDecoder().decode([StoredShortcut].self, from: data) {
            customShortcuts = stored.compactMap { item in
                guard !item.id.isEmpty else { return nil }
                return buildTerminalShortcut(
                    TerminalKeyBinding(item.key, modifiers: Set(item.modifiers)),
                    id: item.id
                )
            }.prefix(maxCustomTerminalShortcuts).map { $0 }
        } else {
            customShortcuts = []
        }

        return TerminalShortcutSnapshot(
            visibleBuiltInIDs: visibleIDs,
            customShortcuts: customShortcuts,
            hasSeenGuide: defaults.bool(forKey: Key.guideSeen)
        )
    }
}

/// Serializes shortcut requests so a long press cannot reorder terminal input on a slow server.
@MainActor
final class TerminalShortcutSender: ObservableObject {
    private struct PendingInput {
        let shortcut: TerminalShortcut
        let onError: (String) -> Void
    }

    private let sessionID: String
    private let api: WandAPI
    private var pending: [PendingInput] = []
    private var currentTask: Task<Void, Never>?
    private var generation = 0

    init(sessionID: String, api: WandAPI) {
        self.sessionID = sessionID
        self.api = api
    }

    func send(_ shortcut: TerminalShortcut, onError: @escaping (String) -> Void) {
        guard !shortcut.bytes.isEmpty else { return }
        if pending.count >= 12 { pending.removeFirst() }
        pending.append(PendingInput(shortcut: shortcut, onError: onError))
        drainIfNeeded()
    }

    func cancelAll() {
        generation += 1
        pending.removeAll()
        currentTask?.cancel()
        currentTask = nil
    }

    private func drainIfNeeded() {
        guard currentTask == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        let input = next.shortcut.bytes
        let shortcutKey = "ios-\(String(next.shortcut.id.prefix(60)))"
        let taskGeneration = generation
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await api.sendInput(
                    id: sessionID,
                    input: input,
                    view: "terminal",
                    shortcutKey: shortcutKey
                )
            } catch where !Task.isCancelled {
                next.onError(error.localizedDescription)
            } catch {
                // Cancellation intentionally drops the remaining result and continues cleanup.
            }
            guard generation == taskGeneration else { return }
            currentTask = nil
            drainIfNeeded()
        }
    }
}

struct PtyTerminalShortcutBar: View {
    let shortcuts: [TerminalShortcut]
    let enabled: Bool
    let keyboardVisible: Bool
    let onShortcut: (TerminalShortcut) -> Void
    let onDismissKeyboard: () -> Void
    let onShowGuide: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if keyboardVisible {
                    utilityButton(
                        systemName: "keyboard.chevron.compact.down",
                        accessibilityLabel: "收起软键盘",
                        action: onDismissKeyboard
                    )
                }
                ForEach(shortcuts) { shortcut in
                    Button { onShortcut(shortcut) } label: {
                        Text(shortcut.label)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(TerminalKeycapButtonStyle(custom: !shortcut.builtIn))
                    .buttonRepeatBehavior(shortcut.repeatable ? .enabled : .disabled)
                    .disabled(!enabled)
                    .accessibilityLabel(shortcut.accessibilityLabel)
                    .accessibilityHint(shortcut.repeatable ? "长按可连续触发" : "立即发送到当前终端")
                }
                utilityButton(
                    systemName: "questionmark.circle",
                    accessibilityLabel: "查看 PTY 快速上手",
                    action: onShowGuide
                )
                utilityButton(
                    systemName: "slider.horizontal.3",
                    accessibilityLabel: "设置终端快捷键",
                    action: onOpenSettings
                )
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 52)
        .wandGlassSurface()
        .overlay(alignment: .top) { Divider().opacity(0.7) }
        .accessibilityElement(children: .contain)
    }

    private func utilityButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct TerminalKeycapButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let custom: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.textSecondary : Theme.textMuted.opacity(0.45))
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Theme.textPrimary.opacity(0.14)
                            : (custom ? Theme.brand.opacity(0.12) : Theme.surface.opacity(0.88))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(custom ? Theme.brand.opacity(0.38) : Theme.border, lineWidth: 0.8)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct TerminalShortcutSettingsView: View {
    @ObservedObject var preferences: TerminalShortcutPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TerminalShortcutSettingsSections(preferences: preferences)
            }
            .navigationTitle("终端快捷键")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.brand)
        .wandPreferredAppearance()
    }
}

struct TerminalShortcutSettingsSections: View {
    @ObservedObject var preferences: TerminalShortcutPreferences

    @State private var builtInsExpanded = false
    @State private var showEditor = false
    @State private var showGuide = false

    var body: some View {
        builtInSection
        customSection
            .sheet(isPresented: $showEditor) {
                TerminalShortcutEditorView { binding in
                    preferences.addCustomShortcut(binding) != nil
                }
            }
        guideSection
            .sheet(isPresented: $showGuide) {
                PtyQuickStartGuideView(
                    onDismiss: { showGuide = false },
                    onFinished: {
                        preferences.markGuideSeen()
                        showGuide = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }

    private var builtInSection: some View {
        Section {
            DisclosureGroup(isExpanded: $builtInsExpanded) {
                ForEach(builtInTerminalShortcuts) { shortcut in
                    Toggle(
                        isOn: Binding(
                            get: { preferences.snapshot.visibleBuiltInIDs.contains(shortcut.id) },
                            set: { preferences.setBuiltInVisible(shortcut.id, visible: $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.label)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                            if shortcut.accessibilityLabel != shortcut.label.replacingOccurrences(of: "+", with: " ") {
                                Text(shortcut.accessibilityLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(Theme.brand)
                    .accessibilityLabel("显示 \(shortcut.accessibilityLabel)")
                }
            } label: {
                HStack {
                    Label("快捷键条", systemImage: "keyboard")
                    Spacer()
                    Text("\(preferences.snapshot.visibleBuiltInIDs.count)/\(builtInTerminalShortcuts.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button("恢复推荐按键", systemImage: "arrow.counterclockwise") {
                preferences.resetBuiltIns()
            }
        } header: {
            Text("终端快捷键")
        } footer: {
            Text("选择 PTY 快捷键条显示的内置按键。方向键和编辑键支持长按连发。")
        }
    }

    private var customSection: some View {
        Section {
            if preferences.snapshot.customShortcuts.isEmpty {
                Text("还没有自定义按键")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(preferences.snapshot.customShortcuts) { shortcut in
                    HStack(spacing: 12) {
                        Text(shortcut.label)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Theme.border, lineWidth: 0.8)
                            )
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            preferences.deleteCustomShortcut(shortcut.id)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除 \(shortcut.label)")
                    }
                }
            }
            Button("添加自定义按键", systemImage: "plus") {
                showEditor = true
            }
            .disabled(preferences.snapshot.customShortcuts.count >= maxCustomTerminalShortcuts)
        } header: {
            Text("自定义映射")
        } footer: {
            Text("组合字符或特殊键与 Ctrl、Alt、Shift；最多保存 \(maxCustomTerminalShortcuts) 个。")
        }
    }

    private var guideSection: some View {
        Section {
            Button {
                showGuide = true
            } label: {
                HStack {
                    Label("查看 PTY 快速上手", systemImage: "questionmark.circle")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text("重新了解输入栏、快捷键和硬件键盘操作。")
        }
    }
}

private struct TerminalShortcutEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (TerminalKeyBinding) -> Bool

    @State private var typedKey = ""
    @State private var selectedSpecialKey: String?
    @State private var modifiers: Set<TerminalModifier> = []

    private var binding: TerminalKeyBinding? {
        let key = selectedSpecialKey ?? normalizeTerminalKeyInput(typedKey)
        return key.map { TerminalKeyBinding($0, modifiers: modifiers) }
    }

    private var preview: TerminalShortcut? {
        binding.flatMap { buildTerminalShortcut($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("修饰键") {
                    ForEach(TerminalModifier.allCases) { modifier in
                        Toggle(
                            modifier.label,
                            isOn: Binding(
                                get: { modifiers.contains(modifier) },
                                set: { selected in
                                    if selected { modifiers.insert(modifier) }
                                    else { modifiers.remove(modifier) }
                                }
                            )
                        )
                        .tint(Theme.brand)
                    }
                }
                Section {
                    TextField("例如 C、K 或 /", text: $typedKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(selectedSpecialKey != nil)
                        .onChange(of: typedKey) { _, value in
                            guard !value.isEmpty else { return }
                            let last = String(value.suffix(1))
                            typedKey = normalizeTerminalKeyInput(last) ?? ""
                        }
                    Picker("特殊键", selection: $selectedSpecialKey) {
                        Text("使用字符键").tag(String?.none)
                        ForEach(terminalSpecialKeys) { key in
                            Text(key.accessibilityLabel).tag(Optional(key.id))
                        }
                    }
                } header: {
                    Text("按键")
                } footer: {
                    Text("组合会按 xterm 规则编码后直接写入 PTY。")
                }
                Section("预览") {
                    LabeledContent("快捷键") {
                        Text(preview?.label ?? "请选择有效组合")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(preview == nil ? Theme.textMuted : Theme.textPrimary)
                    }
                }
            }
            .navigationTitle("添加自定义按键")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        guard let binding, onSave(binding) else { return }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(preview == nil)
                }
            }
        }
        .tint(Theme.brand)
    }
}

private struct PtyGuideStep {
    let title: String
    let body: String
    let tip: String
    let systemImage: String
    let previewKeys: [String]
}

private let ptyGuideSteps: [PtyGuideStep] = [
    PtyGuideStep(
        title: "先写好，再发送",
        body: "底部输入栏适合完整的提示词和命令。内容会先留在本机草稿里，点发送后才写入当前 PTY。",
        tip: "适合长文本，也能继续使用附件和语音输入。",
        systemImage: "terminal",
        previewKeys: ["输入…", "↑"]
    ),
    PtyGuideStep(
        title: "快捷键直接控制 PTY",
        body: "快捷键条会绕过草稿，立即把终端控制序列写入 PTY。方向键可移动光标、切换历史或选择 TUI 菜单。",
        tip: "按住方向键、退格、删除、Home 或 End 可以连续触发。",
        systemImage: "keyboard",
        previewKeys: ["Esc", "Tab", "←", "↑", "↓", "→"]
    ),
    PtyGuideStep(
        title: "按你的习惯映射",
        body: "在系统设置的“终端快捷键”里，可以隐藏内置键，并组合 Ctrl、Alt、Shift 与字符或特殊键。",
        tip: "外接键盘仍可直接操作网页终端；快捷键条适合触控时补齐控制键。",
        systemImage: "slider.horizontal.3",
        previewKeys: ["Ctrl+C", "Alt+←", "Shift+Tab"]
    ),
]

struct PtyQuickStartGuideView: View {
    let onDismiss: () -> Void
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stepIndex = 0

    private var step: PtyGuideStep { ptyGuideSteps[stepIndex] }
    private var isLastStep: Bool { stepIndex == ptyGuideSteps.count - 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: step.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 42, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.brand.opacity(0.12))
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(.title3.weight(.semibold))
                            Text("第 \(stepIndex + 1) 步，共 \(ptyGuideSteps.count) 步")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(step.body)
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(step.previewKeys, id: \.self) { label in
                                Text(label)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Theme.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(Theme.border, lineWidth: 0.8)
                                    )
                            }
                        }
                    }
                    Text(step.tip)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Theme.textSecondary.opacity(0.08))
                        )
                    HStack(spacing: 7) {
                        ForEach(ptyGuideSteps.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == stepIndex ? Theme.brand : Theme.border)
                                .frame(width: index == stepIndex ? 20 : 7, height: 7)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
                .id(stepIndex)
                .transition(.opacity)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("PTY 快速上手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stepIndex == 0 ? "稍后再看" : "关闭", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isLastStep ? "开始使用" : "下一步") {
                        if isLastStep {
                            onFinished()
                        } else if reduceMotion {
                            stepIndex += 1
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) { stepIndex += 1 }
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.brand)
        .wandPreferredAppearance()
    }
}

private func builtInTerminalShortcut(
    _ id: String,
    _ binding: TerminalKeyBinding,
    accessibilityLabel: String? = nil,
    repeatable: Bool = false
) -> TerminalShortcut {
    let shortcut = buildTerminalShortcut(
        binding,
        id: id,
        builtIn: true,
        accessibilityLabel: accessibilityLabel
    )!
    if repeatable && !shortcut.repeatable {
        return TerminalShortcut(
            id: shortcut.id,
            label: shortcut.label,
            accessibilityLabel: shortcut.accessibilityLabel,
            binding: shortcut.binding,
            builtIn: shortcut.builtIn,
            repeatable: true
        )
    }
    return shortcut
}

private func normalizedTerminalBinding(_ binding: TerminalKeyBinding) -> TerminalKeyBinding? {
    let specialKey = terminalSpecialKeys.contains(where: { $0.id == binding.key })
    let normalizedKey: String
    if specialKey {
        normalizedKey = binding.key
    } else {
        guard binding.key.unicodeScalars.count == 1,
              let scalar = binding.key.unicodeScalars.first,
              (32...126).contains(Int(scalar.value)) else {
            return nil
        }
        normalizedKey = binding.key.lowercased()
    }
    return TerminalKeyBinding(
        normalizedKey,
        modifiers: Set(TerminalModifier.allCases.filter { binding.modifiers.contains($0) })
    )
}

private func terminalShortcutAccessibilityLabel(_ binding: TerminalKeyBinding) -> String {
    let modifierLabels = TerminalModifier.allCases
        .filter { binding.modifiers.contains($0) }
        .map(\.label)
    let keyLabel = terminalSpecialKeys.first(where: { $0.id == binding.key })?.accessibilityLabel
        ?? binding.key.uppercased()
    return (modifierLabels + [keyLabel]).joined(separator: " ")
}

private func prefixAlt(_ bytes: String, modifiers: Set<TerminalModifier>) -> String {
    modifiers.contains(.alt) ? terminalEscape + bytes : bytes
}

private func xtermModifierParameter(_ modifiers: Set<TerminalModifier>) -> Int {
    1
        + (modifiers.contains(.shift) ? 1 : 0)
        + (modifiers.contains(.alt) ? 2 : 0)
        + (modifiers.contains(.control) ? 4 : 0)
}

private func encodePrintable(_ raw: Character, modifiers: Set<TerminalModifier>) -> String? {
    let shifted = modifiers.contains(.shift) ? applyTerminalShift(raw) : raw
    let bytes: String
    if modifiers.contains(.control) {
        guard let control = terminalControlCharacter(shifted) else { return nil }
        bytes = String(control)
    } else {
        bytes = String(shifted)
    }
    return prefixAlt(bytes, modifiers: modifiers)
}

private func terminalControlCharacter(_ key: Character) -> Character? {
    guard let scalar = String(key).unicodeScalars.first else { return nil }
    let value = Int(scalar.value)
    if (65...90).contains(value) {
        return Character(String(UnicodeScalar(value - 64)!))
    }
    if (97...122).contains(value) {
        return Character(String(UnicodeScalar(value - 96)!))
    }
    let controlValue: Int?
    switch key {
    case " ", "@", "`": controlValue = 0
    case "[", "{": controlValue = 27
    case "\\", "|": controlValue = 28
    case "]", "}": controlValue = 29
    case "^", "~": controlValue = 30
    case "_": controlValue = 31
    case "?": controlValue = 127
    default: controlValue = nil
    }
    return controlValue.map { Character(String(UnicodeScalar($0)!)) }
}

private func applyTerminalShift(_ key: Character) -> Character {
    guard let scalar = String(key).unicodeScalars.first else { return key }
    let value = Int(scalar.value)
    if (97...122).contains(value) {
        return Character(String(UnicodeScalar(value - 32)!))
    }
    let shifted: [Character: Character] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_",
        "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"",
        ",": "<", ".": ">", "/": "?",
    ]
    return shifted[key] ?? key
}
