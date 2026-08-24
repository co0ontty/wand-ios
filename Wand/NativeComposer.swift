import Foundation
import SwiftUI
import UIKit

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
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onFocusInput)
                    inputContent()
                }
                .frame(maxWidth: .infinity)
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

func composerShouldApplyExternalText(_ incoming: String, current: String, isComposing: Bool) -> Bool {
    !isComposing && incoming != current
}

func composerShouldSubmitReturn(isComposing: Bool) -> Bool {
    !isComposing
}

func composerDraftIsSendable(_ draft: String, hasAttachments: Bool, isComposing: Bool) -> Bool {
    !isComposing && (
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments
    )
}

/// SwiftUI 刷新时 `isFocused` 可能仍是旧值，不能因为「当前不是 focused」就立刻 resign。
/// 只在 SwiftUI 明确经历过 true → false 时收键盘，避免点输入框刚成为 first responder
/// 就被同一帧的 updateUIView 打回去。
func composerShouldRequestFocus(isFocused: Bool, isFirstResponder: Bool) -> Bool {
    isFocused && !isFirstResponder
}

func composerShouldResignFocus(isFocused: Bool, wasFocused: Bool, isFirstResponder: Bool) -> Bool {
    !isFocused && wasFocused && isFirstResponder
}

/// UITextView 走 UIKit 的 marked-text 管线。SwiftUI TextField 在中文输入法组字时会把
/// 半成品写进 Binding，父视图一刷新就重置组字，表现为「输不进去」或候选确认后重复插入。
/// 对齐 macOS IMEAwareComposerTextView：组字期间不回写 Binding，也不把确认键当成发送。
struct IMEAwareComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isFocused: Bool
    var disableAutocorrect: Bool = false
    let onFocusChange: (Bool) -> Void
    let onCompositionChange: (Bool) -> Void
    let onSubmit: () -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.placeholder = placeholder
        textView.onMarkedTextChange = { active in
            context.coordinator.publishComposition(active)
        }
        textView.backgroundColor = .clear
        textView.textColor = UIColor.label
        textView.tintColor = UIColor(Theme.brand)
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.keyboardDismissMode = .none
        textView.returnKeyType = .send
        textView.enablesReturnKeyAutomatically = false
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        if disableAutocorrect {
            textView.autocorrectionType = .no
            textView.autocapitalizationType = .none
            textView.spellCheckingType = .no
        }
        textView.adjustsFontForContentSizeCategory = true
        textView.delaysContentTouches = false
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.accessibilityLabel = "消息输入"
        context.coordinator.reportHeight(for: textView)
        return textView
    }

    func updateUIView(_ textView: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        textView.placeholder = placeholder
        textView.onMarkedTextChange = { active in
            context.coordinator.publishComposition(active)
        }
        textView.tintColor = UIColor(Theme.brand)

        let composing = textView.markedTextRange != nil
        context.coordinator.publishComposition(composing)
        if composerShouldApplyExternalText(text, current: textView.text ?? "", isComposing: composing) {
            let selected = textView.selectedRange
            context.coordinator.isApplyingBinding = true
            textView.text = text
            context.coordinator.isApplyingBinding = false
            let maxLocation = (text as NSString).length
            if selected.location <= maxLocation {
                let length = min(selected.length, maxLocation - selected.location)
                textView.selectedRange = NSRange(location: selected.location, length: length)
            }
            textView.refreshPlaceholder()
            context.coordinator.reportHeight(for: textView)
        }

        let coordinator = context.coordinator
        if composerShouldRequestFocus(isFocused: isFocused, isFirstResponder: textView.isFirstResponder) {
            // 不能只调一次 becomeFirstResponder：抽屉转场动画中段、或从
            // WKWebView 手里抢 first responder 时，单次调用会静默失败，
            // 键盘永远弹不出来。交给带重试的聚焦（见 Coordinator）。
            coordinator.requestFocus(textView)
        } else if composerShouldResignFocus(
            isFocused: isFocused,
            wasFocused: coordinator.lastKnownFocused,
            isFirstResponder: textView.isFirstResponder
        ) {
            coordinator.cancelFocusRetry()
            textView.resignFirstResponder()
        }
        coordinator.lastKnownFocused = isFocused
    }

    static func dismantleUIView(_ textView: ComposerUITextView, coordinator: Coordinator) {
        coordinator.cancelFocusRetry()
        textView.onMarkedTextChange = nil
        textView.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IMEAwareComposerTextView
        var isApplyingBinding = false
        var lastKnownFocused = false
        private var lastReportedHeight: CGFloat = 0
        private var lastComposing = false
        /// 带重试的聚焦任务列表：覆盖抽屉 .move 转场（~0.22s）、WKWebView 让出
        /// first responder 的跨进程间隙等一次性失败场景。
        private var focusRetryWorks: [DispatchWorkItem] = []
        private static let focusRetryDelays: [TimeInterval] = [0, 0.08, 0.18, 0.32, 0.5, 0.75]

        init(parent: IMEAwareComposerTextView) {
            self.parent = parent
        }

        /// 在多个时间点上反复尝试成为 first responder，直到成功、外部取消聚焦
        /// （isFocused 变 false）或视图脱离窗口为止。幂等：重复调用会先取消旧批次。
        func requestFocus(_ textView: UITextView) {
            cancelFocusRetry()
            for delay in Self.focusRetryDelays {
                let work = DispatchWorkItem { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    guard self.parent.isFocused, textView.window != nil else { return }
                    guard !textView.isFirstResponder else { return }
                    textView.becomeFirstResponder()
                }
                focusRetryWorks.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        func cancelFocusRetry() {
            for work in focusRetryWorks { work.cancel() }
            focusRetryWorks.removeAll()
        }

        func publishComposition(_ active: Bool) {
            guard active != lastComposing else { return }
            lastComposing = active
            parent.onCompositionChange(active)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused {
                parent.onFocusChange(true)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            publishComposition(false)
            if parent.isFocused {
                parent.onFocusChange(false)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            let composing = textView.markedTextRange != nil
            publishComposition(composing)
            (textView as? ComposerUITextView)?.refreshPlaceholder()
            if !isApplyingBinding, !composing {
                parent.text = textView.text ?? ""
            }
            reportHeight(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            publishComposition(textView.markedTextRange != nil)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if textView.markedTextRange != nil {
                return true
            }
            if text == "\n" {
                guard composerShouldSubmitReturn(isComposing: false) else { return true }
                parent.onSubmit()
                return false
            }
            return true
        }

        func reportHeight(for textView: UITextView) {
            let width = textView.bounds.width > 0 ? textView.bounds.width : 280
            let fitted = textView.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            )
            let height = min(112, max(24, ceil(fitted.height)))
            textView.isScrollEnabled = fitted.height > 112
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            DispatchQueue.main.async { [weak self] in
                self?.parent.onHeightChange(height)
            }
        }
    }
}

final class ComposerUITextView: UITextView {
    var onMarkedTextChange: ((Bool) -> Void)?
    private let placeholderLabel = UILabel()

    override var canBecomeFirstResponder: Bool { true }

    var placeholder = "" {
        didSet {
            placeholderLabel.text = placeholder
            refreshPlaceholder()
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 1
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        onMarkedTextChange?(markedTextRange != nil)
        refreshPlaceholder()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?(false)
        refreshPlaceholder()
    }

    func refreshPlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty || markedTextRange != nil
    }
}
