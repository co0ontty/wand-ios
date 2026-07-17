import SwiftUI

enum ComposerMetrics {
    static let actionVisualSize: CGFloat = 34
    static let actionTouchSize: CGFloat = 44
    static let actionSpacing: CGFloat = 0
}

struct ComposerInputHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NativeComposerShell<CollapsedLeading: View, InputContent: View, CollapsedTrailing: View, ExpandedControls: View>: View {
    let expanded: Bool
    let focused: Bool
    let onFocusInput: () -> Void
    @ViewBuilder let collapsedLeading: () -> CollapsedLeading
    @ViewBuilder let inputContent: () -> InputContent
    @ViewBuilder let collapsedTrailing: () -> CollapsedTrailing
    @ViewBuilder let expandedControls: () -> ExpandedControls

    var body: some View {
        let cornerRadius: CGFloat = expanded ? 18 : 24
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            HStack(alignment: expanded ? .bottom : .center, spacing: ComposerMetrics.actionSpacing) {
                if !expanded {
                    collapsedLeading()
                }
                inputContent()
                if !expanded {
                    collapsedTrailing()
                }
            }
            if expanded {
                expandedControls()
            }
        }
        .padding(.horizontal, expanded ? 8 : 9)
        .padding(.vertical, expanded ? 7 : 4)
        .background(.ultraThinMaterial, in: shape)
        .background {
            shape
                .fill(Theme.surface.opacity(expanded ? 0.58 : 0.48))
        }
        .overlay {
            shape
                .stroke(Theme.border.opacity(expanded ? 0.42 : 0.32), lineWidth: 0.8)
        }
        .overlay(alignment: .top) {
            shape
                .stroke(Color.white.opacity(expanded ? 0.36 : 0.28), lineWidth: 0.7)
                .blendMode(.screen)
        }
        .overlay {
            if focused {
                shape
                    .stroke(Theme.brand.opacity(0.28), lineWidth: 1)
            }
        }
        .contentShape(shape)
        .simultaneousGesture(
            TapGesture().onEnded {
                onFocusInput()
            }
        )
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }
}

func composerShouldExpand(focused: Bool, voiceMode: Bool, contentNeedsSpace: Bool = false) -> Bool {
    focused || voiceMode || contentNeedsSpace
}

struct WandKeyboardShortcutAction: Identifiable {
    let id: String
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let isEnabled: Bool
    let action: () -> Void

    init(
        id: String,
        title: String,
        key: KeyEquivalent,
        modifiers: EventModifiers,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.isEnabled = isEnabled
        self.action = action
    }
}

private struct WandKeyboardShortcutHost: View {
    let shortcuts: [WandKeyboardShortcutAction]

    var body: some View {
        ZStack {
            ForEach(shortcuts.filter { $0.isEnabled }) { shortcut in
                Button(shortcut.title, action: shortcut.action)
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 1, height: 1)
        .clipped()
        .accessibilityHidden(true)
    }
}

extension View {
    func wandKeyboardShortcuts(_ shortcuts: [WandKeyboardShortcutAction]) -> some View {
        overlay(alignment: .topLeading) {
            WandKeyboardShortcutHost(shortcuts: shortcuts)
        }
    }

    func wandSubmitOnHardwareReturn(
        isEnabled: @escaping () -> Bool = { true },
        perform action: @escaping () -> Void
    ) -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard wandShouldSubmitHardwareReturn(modifiers: press.modifiers) else {
                return .ignored
            }
            guard isEnabled() else { return .handled }
            action()
            return .handled
        }
    }
}

func wandShouldSubmitHardwareReturn(modifiers: EventModifiers) -> Bool {
    !modifiers.contains(.shift)
        && !modifiers.contains(.option)
        && !modifiers.contains(.control)
        && !modifiers.contains(.command)
}
