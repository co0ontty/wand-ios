import Foundation
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let expanded: Bool
    let focused: Bool
    let onFocusInput: () -> Void
    @ViewBuilder let collapsedLeading: () -> CollapsedLeading
    @ViewBuilder let inputContent: () -> InputContent
    @ViewBuilder let collapsedTrailing: () -> CollapsedTrailing
    @ViewBuilder let expandedControls: () -> ExpandedControls

    var body: some View {
        // iPhone 保留聚焦后露出控制行，但表面本身保持同一圆角、材质与阴影。
        // 键盘已经提供空间变化动画，composer 不再叠加第二套弹性缩放。
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        VStack(alignment: .leading, spacing: expanded ? 6 : 0) {
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(reduceTransparency ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(.ultraThinMaterial), in: shape)
        .background {
            shape
                .fill(Theme.surface.opacity(0.56))
        }
        .overlay {
            shape
                .stroke(
                    focused ? Theme.brand.opacity(contrast == .increased ? 1 : 0.62) : Theme.border.opacity(contrast == .increased ? 1 : 0.46),
                    lineWidth: contrast == .increased ? 2 : (focused ? 1.25 : 0.8)
                )
        }
        .overlay(alignment: .top) {
            shape
                .stroke(Color.white.opacity(0.32), lineWidth: 0.7)
                .blendMode(.screen)
        }
        .contentShape(shape)
        .simultaneousGesture(
            TapGesture().onEnded {
                onFocusInput()
            }
        )
        .compositingGroup()
        .shadow(
            color: focused ? Theme.brand.opacity(0.12) : Color.black.opacity(0.05),
            radius: 8,
            x: 0,
            y: 3
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

func composerShouldExpand(focused: Bool, voiceMode: Bool, contentNeedsSpace: Bool = false) -> Bool {
    focused || voiceMode || contentNeedsSpace
}

func appendingVoiceTranscript(_ transcript: String, to draft: String) -> String {
    let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else { return draft }

    var draft = draft
    while let last = draft.unicodeScalars.last,
          CharacterSet.whitespacesAndNewlines.contains(last) {
        draft.unicodeScalars.removeLast()
    }
    return draft.isEmpty ? transcript : draft + " " + transcript
}

@MainActor
final class ComposerAttachmentController: ObservableObject {
    @Published var showFileImporter = false
    @Published var showPhotoPicker = false
    @Published private(set) var isUploading = false
    @Published var attachments: [UploadedFile] = []

    private let sessionId: String
    private let api: WandAPI
    private var showToast: (String) -> Void = { _ in }

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
    }

    func setToastHandler(_ handler: @escaping (String) -> Void) {
        showToast = handler
    }

    func remove(_ file: UploadedFile) {
        attachments.removeAll { $0.savedPath == file.savedPath }
    }

    func handleFileSelection(_ result: Result<[URL], Error>) {
        handleSelection(result, cleanupAfterUpload: false)
    }

    func handlePhotoSelection(_ result: Result<[URL], Error>) {
        handleSelection(result, cleanupAfterUpload: true)
    }

    private func handleSelection(_ result: Result<[URL], Error>, cleanupAfterUpload: Bool) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { showToast(error.localizedDescription) }
            return
        }
        upload(urls, cleanupAfterUpload: cleanupAfterUpload)
    }

    private func upload(_ urls: [URL], cleanupAfterUpload: Bool) {
        isUploading = true
        Task {
            defer {
                isUploading = false
                if cleanupAfterUpload {
                    for url in urls {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            do {
                let uploaded = try await api.uploadAttachments(id: sessionId, urls: urls)
                attachments = Array((attachments + uploaded).suffix(5))
                showToast("已上传 \(uploaded.count) 个附件")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }
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
