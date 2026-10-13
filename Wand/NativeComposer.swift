import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ComposerMetrics {
    static let actionVisualSize: CGFloat = 34
    static let actionTouchSize: CGFloat = 48
    static let actionSpacing: CGFloat = 0
    /// Chat expands naturally; the full draft editor handles longer documents.
    static let expandedInputMaxHeight: CGFloat = 180
    static let voiceCancelDistance: CGFloat = 60
}

enum ComposerSendPhase: Equatable {
    case idle, sending, sent, failed
}

/// UI visibility only; submission ownership remains in ComposerDraftState/ChatStore.
func catComposerExpanded(editing: Bool, focused: Bool, keyboard: Bool, failed: Bool, unconfirmed: Bool) -> Bool {
    editing || focused || keyboard || failed || unconfirmed
}

struct CatInputPressState {
    static let holdDelay: TimeInterval = 0.3
    private(set) var holding = false
    private(set) var moved = false
    private(set) var attempted = false
    private(set) var cancelling = false
    private(set) var dragX: CGFloat = 0
    private(set) var dragging = false
    mutating func move(x: CGFloat, y: CGFloat) {
        if holding { cancelling = y < -ComposerMetrics.voiceCancelDistance }
        else if abs(x) + abs(y) > 12 {
            moved = true; dragging = abs(x) > abs(y); dragX = x
        }
    }
    mutating func beginHold() -> Bool {
        guard !moved, !attempted else { return false }
        attempted = true; holding = true
        return true
    }
    enum End: Equatable { case tap, voice(cancelled: Bool), drag(CGFloat), none }
    mutating func end() -> End {
        let result: End = holding ? .voice(cancelled: cancelling) : dragging ? .drag(dragX) : moved || attempted ? .none : .tap
        self = Self()
        return result
    }
}

/// One recognizer arbitrates short press and hold. Permission callbacks never own the pointer.
struct CatInputGesture: ViewModifier {
    let onTap: () -> Void
    let onHold: () -> Void
    let onMove: (Bool) -> Void
    let onRelease: (Bool) -> Void
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDrop: (CGFloat) -> Void = { _ in }
    @State private var pointer = CatInputPressState()
    @State private var work: DispatchWorkItem?
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                pointer.move(x: value.translation.width, y: value.translation.height)
                if pointer.moved { work?.cancel(); work = nil }
                if work == nil && !pointer.holding && !pointer.moved && !pointer.attempted {
                    let pending = DispatchWorkItem {
                        work = nil
                        if pointer.beginHold() { onHold() }
                    }
                    work = pending
                    DispatchQueue.main.asyncAfter(deadline: .now() + CatInputPressState.holdDelay, execute: pending)
                }
                if pointer.holding { onMove(pointer.cancelling) }
                else if pointer.dragging { onDrag(pointer.dragX) }
            }.onEnded { _ in
                work?.cancel(); work = nil
                switch pointer.end() {
                case .tap: onTap()
                case .voice(let cancelled): onRelease(cancelled)
                case .drag(let x): onDrop(x)
                case .none: break
                }
            })
            .accessibilityElement().accessibilityAddTraits(.isButton)
            .accessibilityLabel("发消息，或按住说话")
            .accessibilityHint("轻点打字；按住300毫秒说话，上滑取消，松手后编辑草稿")
            .accessibilityAction { onTap() }
            .accessibilityAction(named: "开始语音输入") { onHold() }
            .accessibilityAction(named: "结束语音，填入草稿") { onRelease(false) }
            .accessibilityAction(named: "取消语音输入") { onRelease(true) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in cancel() }
            .onDisappear { cancel() }
    }
    private func cancel() {
        work?.cancel(); work = nil
        if pointer.holding { onRelease(true) }
        pointer = CatInputPressState()
        onDrag(0)
    }
}

enum CatComposerSide: String {
    case left, right
    static let preferenceKey = "wand.catComposer.side.v1"
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .left
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.preferenceKey) }
    func dropped(translation: CGFloat) -> Self {
        translation > 48 ? .right : translation < -48 ? .left : self
    }
}

/// The capsule rule deliberately keys off text, never attachment count or execution alone.
func catCapsuleShowsThirdAction(text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func composerPrimaryActionStops(phase: ComposerSendPhase, turnRunning: Bool, hasDraft: Bool) -> Bool {
    phase == .idle && turnRunning && !hasDraft
}

/// The same button instance carries Send/Stop/loading/result in a fixed slot.
struct NativeComposerActionButton: View {
    let phase: ComposerSendPhase
    let turnRunning: Bool
    let hasDraft: Bool
    let canSubmit: Bool
    let message: String?
    let onSend: () -> Void
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stopping: Bool {
        composerPrimaryActionStops(phase: phase, turnRunning: turnRunning, hasDraft: hasDraft)
    }
    private var tint: Color {
        switch phase {
        case .sent: return Theme.success
        case .failed: return Theme.danger
        case .sending: return Theme.brand
        case .idle: return canSubmit || stopping ? Theme.textPrimary : Theme.textSecondary.opacity(0.16)
        }
    }
    private var label: String {
        switch phase {
        case .sending: return "发送中"
        case .sent: return "已送达"
        case .failed: return message ?? "发送失败"
        case .idle: return stopping ? "停止任务" : "发送"
        }
    }

    var body: some View {
        Button {
            if stopping { onStop() } else { onSend() }
        } label: {
            ZStack {
                symbol("arrow.up", visible: phase == .idle && !stopping)
                symbol("stop.fill", visible: stopping)
                symbol("checkmark", visible: phase == .sent)
                symbol("exclamationmark", visible: phase == .failed)
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.surface)
                    .opacity(phase == .sending ? 1 : 0)
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(phase == .idle && !canSubmit && !stopping ? Theme.textSecondary : Theme.surface)
            .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
            .background(Circle().fill(tint))
            .animation(reduceMotion ? nil : WandMotion.stateSwap, value: phase)
            .animation(reduceMotion ? nil : WandMotion.stateSwap, value: stopping)
            .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase == .sending || (!canSubmit && !stopping))
        .accessibilityLabel(label)
        .overlay(alignment: .bottomTrailing) {
            if phase == .failed, let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .padding(8)
                    .frame(width: 240, alignment: .leading)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -ComposerMetrics.actionTouchSize)
                    .allowsHitTesting(false)
            }
        }
    }

    private func symbol(_ name: String, visible: Bool) -> some View {
        Image(systemName: name)
            .opacity(visible ? 1 : 0)
            .scaleEffect(reduceMotion || visible ? 1 : 0.9)
    }
}

/// Shared hold-to-talk control. Keyboard/speech callbacks remain bound to the starting draft revision.
struct ComposerVoiceControl: View {
    @ObservedObject var draft: ComposerDraftState
    @ObservedObject var speech: SpeechRecognizerService
    var inputSurface = false
    var onTap: (() -> Void)? = nil
    var onPressChanged: (Bool, Bool) -> Void = { _, _ in }
    let notice: (String) -> Void
    @State private var work: DispatchWorkItem?
    @State private var pressed = false
    @State private var canceling = false
    @State private var pointerMoved = false
    @State private var attempted = false
    @State private var revision = 0
    @State private var lifecycle = 0
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        Group {
            if inputSurface { Color.clear }
            else {
                ZStack {
                    Image(systemName: "mic").opacity(pressed || speech.isRecording || speech.isProcessing ? 0 : 1)
                    Image(systemName: "stop.circle").opacity(pressed || speech.isRecording || speech.isProcessing ? 1 : 0)
                }.font(.body).frame(width: 44, height: 44)
            }
        }.contentShape(Rectangle())
            .animation(reduced ? nil : WandMotion.stateSwap, value: pressed || speech.isRecording || speech.isProcessing)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if work == nil && !pressed && !pointerMoved && !attempted {
                    let pending = DispatchWorkItem { work = nil; attempted = true; begin() }; work = pending
                    DispatchQueue.main.asyncAfter(deadline: .now() + WandMotion.voiceHoldDelay, execute: pending)
                }
                if !pressed && abs(value.translation.width) + abs(value.translation.height) > 12 {
                    work?.cancel(); work = nil; pointerMoved = true
                }
                if pressed {
                    canceling = value.translation.height < -ComposerMetrics.voiceCancelDistance
                    onPressChanged(true, canceling)
                }
            }.onEnded { _ in
                attempted = false
                if pointerMoved && !pressed { pointerMoved = false; return }
                pointerMoved = false
                if let work {
                    work.cancel(); self.work = nil
                    if let onTap { onTap() } else { notice("按住说话，上滑取消") }
                    return
                }
                if pressed { finish(cancelled: canceling) }
            })
            .accessibilityElement().accessibilityAddTraits(.isButton).accessibilityLabel(inputSurface ? "发消息或按住说话" : "语音输入")
            .accessibilityValue(canceling ? "松开取消" : speech.isProcessing ? "识别中" : speech.isRecording ? "正在录音" : "轻点打字，长按说话")
            .accessibilityAction { if let onTap { onTap() } else if speech.isProcessing { finish(cancelled: true) } else if speech.isRecording { finish(cancelled: false) } else { begin() } }
            .accessibilityAction(named: "语音输入") { if speech.isRecording { finish(cancelled: false) } else { begin() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                work?.cancel(); work = nil; pointerMoved = false; attempted = false
                if pressed || speech.isRecording || speech.isProcessing { finish(cancelled: true) }
            }
            .onDisappear {
                work?.cancel(); work = nil; pointerMoved = false; attempted = false
                if pressed { speech.stop(cancelled: true) }
                pressed = false; canceling = false; onPressChanged(false, false)
            }
    }
    private func begin() {
        revision = draft.textRevision; lifecycle = draft.lifecycleRevision; pressed = true; canceling = false
        onPressChanged(true, false)
        speech.start(api: draft.speechAPI) { notice($0); pressed = false; canceling = false; onPressChanged(false, false) }
    }
    private func finish(cancelled: Bool) {
        pressed = false; canceling = false; onPressChanged(false, false)
        let capturedRevision = revision, capturedLifecycle = lifecycle
        speech.stop(cancelled: cancelled) { draft.appendVoice($0, ifUnchangedSince: capturedRevision, lifecycle: capturedLifecycle) }
    }
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
    var avatarLaneInset: CGFloat = 0
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
                    .frame(maxWidth: .infinity)
                    // 点击层跟随内容尺寸，不能作为 ZStack 子项占满剩余高度。
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onFocusInput)
                    }
                if !expanded {
                    collapsedTrailing()
                }
            }
            .padding(.leading, expanded ? 0 : avatarLaneInset)
            .padding(.top, expanded && avatarLaneInset > 0 ? 14 : 0)
            if expanded {
                expandedControls()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.surface, in: shape)
        .overlay {
            shape
                .stroke(
                    focused ? Theme.brand.opacity(contrast == .increased ? 1 : 0.62) : Theme.border.opacity(contrast == .increased ? 1 : 0.46),
                    lineWidth: contrast == .increased ? 2 : (focused ? 1.25 : 0.8)
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct ComposerContextLabel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17))
            } else {
                Label("上下文", systemImage: "slider.horizontal.3").font(.caption)
            }
        }.foregroundStyle(Theme.textSecondary).frame(minWidth: 48, minHeight: 48)
    }
}

/// Small visual islands with native 48pt targets, without a full-width navigation surface.
struct FloatingChatIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 36, height: 36)
            .background(Theme.surface, in: Circle())
            .overlay(Circle().stroke(Theme.border.opacity(0.55), lineWidth: 0.8))
            .frame(width: ChatTopLayout.controlTouch, height: ChatTopLayout.controlTouch).contentShape(Rectangle())
    }
}

struct FloatingChatControls<Actions: View>: View {
    let onBack: () -> Void
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        HStack(spacing: 4) {
            Button(action: onBack) { FloatingChatIcon(symbol: "chevron.left") }
                .buttonStyle(.plain).accessibilityLabel("返回会话列表")
            Spacer(minLength: 0)
            actions()
        }.padding(.horizontal, 12).padding(.top, ChatTopLayout.controlRowInset)
    }
}

/// Full-height editing uses the same draft binding: dismissing never commits, sends or clears it.
struct ComposerDraftEditor: View {
    @Binding var text: String
    let onCompositionChange: (Bool) -> Void
    var onPasteImages: (([(data: Data, name: String?, mimeType: String?)]) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var focused = true
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                IMEAwareComposerTextView(text: $text, placeholder: "输入消息", isFocused: focused,
                    maximumHeight: max(100, geometry.size.height - 32), submitOnReturn: false,
                    onPasteImages: onPasteImages, onFocusChange: { focused = $0 },
                    onCompositionChange: onCompositionChange, onSubmit: {}, onHeightChange: { _ in })
                    .padding(16)
            }
            .background(Theme.surface).navigationTitle("编辑消息").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { focused = false; dismiss() } } }
        }
    }
}

func composerMaximumInputHeight(compact: Bool, keyboardVisible: Bool) -> CGFloat {
    compact ? (keyboardVisible ? 44 : 88) : (keyboardVisible ? 96 : 112)
}

func composerOffersExpandedEditor(text: String, measuredHeight: CGFloat,
                                 maximumHeight: CGFloat = ComposerMetrics.expandedInputMaxHeight) -> Bool {
    text.count >= 240 || text.filter { $0 == "\n" }.count >= 5 || measuredHeight >= maximumHeight - 2
}

func composerUsesRestingSurface(acknowledged: Bool, focused: Bool, hasDraft: Bool,
                               hasAttachments: Bool, composing: Bool,
                               phase: ComposerSendPhase, unconfirmed: Bool) -> Bool {
    acknowledged && !focused && !hasDraft && !hasAttachments && !composing &&
        phase != .failed && phase != .sending && !unconfirmed
}

func composerShouldExpand(focused: Bool, voiceMode: Bool, contentNeedsSpace: Bool = false) -> Bool {
    // Holding the idle input must not move the trigger by revealing a keyboard toolbar.
    focused || contentNeedsSpace
}

func composerHoldToTalkEligible(text: String, focused: Bool, keyboardVisible: Bool) -> Bool {
    text.isEmpty && !focused && !keyboardVisible
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

struct ComposerDraftSubmission {
    let text: String
    let attachments: [UploadedFile]
    let textRevision: Int
    var prompt: String { buildAttachmentPrompt(attachments, body: text) }
}

/// One session-owned in-memory buffer; pages only bind/project it. Retain content
/// until a receipt, and never persist an uncertain submission or clear newer input.
@MainActor
final class ComposerDraftState: ObservableObject {
    private let storageKey: String
    private let defaults: UserDefaults
    private(set) var active = true
    private(set) var retired = false
    private(set) var lifecycleRevision = 0
    private var consumers = Set<UUID>()
    func acquire(_ consumer: UUID) { consumers.insert(consumer); activate() }
    func release(_ consumer: UUID) { consumers.remove(consumer); if consumers.isEmpty { deactivate() } }
    private var unconfirmedTextRevision: Int?
    private var unconfirmedAttachments: [String: Set<Int>] = [:]
    private var unconfirmedInputs = Set<String>()
    var unconfirmedInput: String? {
        didSet { if let unconfirmedInput { unconfirmedInputs.insert(unconfirmedInput) } }
    }
    func isUnconfirmed(_ input: String) -> Bool { unconfirmedInputs.contains(input) }
    func resolveUnconfirmedInput() {
        if let unconfirmedInput { unconfirmedInputs.remove(unconfirmedInput) }
        unconfirmedInput = nil
    }
    @Published private(set) var sendPhase = ComposerSendPhase.idle
    @Published private(set) var sendFeedback: String?
    @Published private(set) var submissionFailed = false
    private var sendFeedbackTask: Task<Void, Never>?

    func beginSending() {
        guard !retired else { return }
        submissionFailed = false
        sendFeedbackTask?.cancel()
        sendFeedback = nil
        sendPhase = .sending
    }

    func finishSending(accepted: Bool, message: String?) {
        sendFeedbackTask?.cancel()
        submissionFailed = !accepted
        let phase: ComposerSendPhase = accepted ? .sent : .failed
        sendFeedback = message
        sendPhase = phase
        sendFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: accepted ? WandMotion.submittedDwell : WandMotion.failedDwell) }
            catch { return }
            guard let self, sendPhase == phase else { return }
            sendPhase = .idle
            sendFeedback = nil
        }
    }
    @Published private(set) var isOptimizing = false
    @Published private(set) var optimizationMessage: String?
    private var optimizationTask: Task<Void, Never>?
    @Published var text = "" {
        didSet {
            textRevision += 1
            persist()
        }
    }
    private(set) var textRevision = 0
    let attachments: ComposerAttachmentController
    private(set) var speechAPI: WandAPI
    func bind(api: WandAPI) { speechAPI = api; attachments.bind(api: api) }

    init(sessionId: String, api: WandAPI, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.speechAPI = api
        storageKey = "wand.composer.v1." + ServerProfiles.stableID(for: api.baseURL) + "." + sessionId
        attachments = ComposerAttachmentController(sessionId: sessionId, api: api)
        if let saved = defaults.data(forKey: storageKey),
           let draft = try? JSONDecoder().decode(SavedDraft.self, from: saved) {
            text = draft.text
            attachments.attachments = draft.attachments
        }
        attachments.onChange = { [weak self] in self?.persist() }
    }

    private struct SavedDraft: Codable {
        let text: String
        let attachments: [UploadedFile]
    }

    func activate() {
        guard !retired else { return }
        guard !active else { attachments.activate(); return }
        active = true
        lifecycleRevision += 1
        attachments.activate()
    }

    func deactivate() {
        active = false
        lifecycleRevision += 1
        attachments.deactivate()
        optimizationTask?.cancel()
        optimizationTask = nil
        isOptimizing = false
    }

    func retire() {
        retired = true
        deactivate()
        sendFeedbackTask?.cancel()
        text = ""
        attachments.attachments = []
    }

    var canEvict: Bool { !active && sendPhase != .sending && unconfirmedInput == nil }

    func optimize(operation: @escaping (String) async throws -> String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !isOptimizing, !attachments.isUploading, !prompt.isEmpty else { return }
        let revision = textRevision
        let lifecycle = lifecycleRevision
        isOptimizing = true
        optimizationMessage = nil
        optimizationTask = Task { [weak self] in
            guard let self else { return }
            defer { if lifecycleRevision == lifecycle { isOptimizing = false } }
            do {
                let optimized = try await operation(prompt)
                guard !Task.isCancelled, active, lifecycleRevision == lifecycle else { return }
                if applyOptimized(optimized, revision: revision, lifecycle: lifecycle) {
                    optimizationMessage = "提示词已优化"
                } else {
                    optimizationMessage = "输入已更新，保留当前内容"
                }
            } catch {
                guard !Task.isCancelled, active, lifecycleRevision == lifecycle else { return }
                optimizationMessage = error.localizedDescription
            }
        }
    }

    func submitted(_ submission: ComposerDraftSubmission) {
        guard !retired else { return }
        unconfirmedTextRevision = submission.textRevision
        for file in submission.attachments {
            unconfirmedAttachments[file.savedPath, default: []].insert(submission.textRevision)
        }
        persist()
    }

    func rejected(_ submission: ComposerDraftSubmission) {
        guard !retired else { return }
        if unconfirmedTextRevision == submission.textRevision { unconfirmedTextRevision = nil }
        for file in submission.attachments {
            unconfirmedAttachments[file.savedPath]?.remove(submission.textRevision)
            if unconfirmedAttachments[file.savedPath]?.isEmpty == true { unconfirmedAttachments.removeValue(forKey: file.savedPath) }
        }
        persist()
    }

    private func persist() {
        guard !retired else { return }
        let saved = SavedDraft(
            text: unconfirmedTextRevision == textRevision ? "" : text,
            attachments: attachments.attachments.filter { unconfirmedAttachments[$0.savedPath] == nil }
        )
        if saved.text.isEmpty, saved.attachments.isEmpty { defaults.removeObject(forKey: storageKey) }
        else if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: storageKey) }
    }

    func submission() -> ComposerDraftSubmission {
        ComposerDraftSubmission(text: text, attachments: attachments.attachments, textRevision: textRevision)
    }

    func accepted(_ submission: ComposerDraftSubmission) {
        guard !retired else { return }
        if textRevision == submission.textRevision { text = "" }
        let paths = Set(submission.attachments.map(\.savedPath))
        attachments.attachments.removeAll { paths.contains($0.savedPath) }
        paths.forEach { unconfirmedAttachments.removeValue(forKey: $0) }
        rejected(submission)
    }

    func applyOptimized(_ text: String, revision: Int, lifecycle: Int) -> Bool {
        guard active, textRevision == revision, lifecycleRevision == lifecycle else { return false }
        self.text = text
        return true
    }

    func appendVoice(_ transcript: String, ifUnchangedSince startedRevision: Int, lifecycle: Int? = nil) {
        guard active, lifecycle == nil || lifecycle == lifecycleRevision, textRevision == startedRevision,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = appendingVoiceTranscript(transcript, to: text)
    }
}

@MainActor
final class ComposerAttachmentController: ObservableObject {
    @Published var showFileImporter = false
    @Published var showPhotoPicker = false
    @Published private(set) var isUploading = false
    @Published var attachments: [UploadedFile] = [] { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private var active = true
    private var generation = 0
    private var uploadTask: Task<Void, Never>?

    func activate() { active = true }
    func deactivate() {
        active = false
        generation += 1
        uploadTask?.cancel()
        uploadTask = nil
        isUploading = false
        pasteIntoPty = nil
        showToast = { _ in }
    }

    private let sessionId: String
    /// IM attachment uploads prepare a real execution channel without changing the draft's stable identity.
    var prepareUpload: (() async throws -> String)?
    private var api: WandAPI
    func bind(api: WandAPI) { self.api = api }
    private var showToast: (String) -> Void = { _ in }
    private var pasteIntoPty: (([UploadedFile]) async throws -> Void)?

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
    }

    func setToastHandler(_ handler: @escaping (String) -> Void) {
        showToast = handler
    }

    func setPtyPasteHandler(_ handler: (([UploadedFile]) async throws -> Void)?) {
        pasteIntoPty = handler
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

    func handlePastedImageData(_ items: [(data: Data, name: String?, mimeType: String?)]) {
        guard !items.isEmpty else { return }
        var urls: [URL] = []
        do {
            for (index, item) in items.enumerated() {
                urls.append(try writeClipboardImageToTemporaryFile(
                    data: item.data,
                    originalName: item.name,
                    mimeType: item.mimeType,
                    index: index
                ))
            }
        } catch {
            showToast(error.localizedDescription)
            return
        }
        upload(urls, cleanupAfterUpload: true, preferPtyPaste: true)
    }

    private func handleSelection(_ result: Result<[URL], Error>, cleanupAfterUpload: Bool) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { showToast(error.localizedDescription) }
            return
        }
        upload(urls, cleanupAfterUpload: cleanupAfterUpload, preferPtyPaste: pasteIntoPty != nil)
    }

    private func upload(_ urls: [URL], cleanupAfterUpload: Bool, preferPtyPaste: Bool) {
        guard active, !isUploading else {
            if cleanupAfterUpload { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            return
        }
        let remaining = 5 - attachments.count
        guard remaining > 0 else {
            showToast("最多添加 5 个附件，请先移除已有附件")
            if cleanupAfterUpload { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            return
        }
        let selected = Array(urls.prefix(remaining))
        let uploadAPI = api
        let prepare = prepareUpload
        generation += 1
        let requestGeneration = generation
        let pasteHandler = preferPtyPaste ? pasteIntoPty : nil
        isUploading = true
        uploadTask = Task {
            defer {
                if generation == requestGeneration { isUploading = false }
                if cleanupAfterUpload {
                    for url in urls {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            do {
                let uploadSessionID = try await prepare?() ?? sessionId
                guard active, generation == requestGeneration, !Task.isCancelled else { return }
                let uploaded = try await uploadAPI.uploadAttachments(id: uploadSessionID, urls: selected)
                guard active, generation == requestGeneration, !Task.isCancelled else { return }
                if let pasteIntoPty = pasteHandler {
                    let imageCount = uploaded.filter { isClipboardImageMimeType($0.mimeType) }.count
                    showToast(imageCount == uploaded.count ? "正在粘贴图片…" : "正在上传附件…")
                    try await pasteIntoPty(uploaded)
                    let countLabel = imageCount == uploaded.count
                        ? "\(uploaded.count) 张图片"
                        : "\(uploaded.count) 个附件"
                    showToast("已将 \(countLabel)粘贴到 CLI 输入区。")
                } else {
                    let existing = Set(attachments.map(\.savedPath))
                    attachments += uploaded.filter { !existing.contains($0.savedPath) }.prefix(max(0, 5 - attachments.count))
                    showToast("已上传 \(uploaded.count) 个附件")
                }
            } catch {
                if active, generation == requestGeneration, !Task.isCancelled { showToast(error.localizedDescription) }
            }
        }
    }
}

/// Detail destinations can be destroyed when moving between sessions. Keep each
/// server/session buffer in memory and persist only content known to be unsent.
@MainActor
final class SessionDraftStore {
    static let shared = SessionDraftStore()
    private var drafts: [String: ComposerDraftState] = [:]
    private var accessOrder: [String] = []
    private let cacheLimit = 100
    func draft(sessionId: String, api: WandAPI) -> ComposerDraftState {
        let key = ServerProfiles.stableID(for: api.baseURL) + "." + sessionId
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        if let draft = drafts[key] {
            draft.bind(api: api)
            return draft
        }
        let draft = ComposerDraftState(sessionId: sessionId, api: api)
        drafts[key] = draft
        while drafts.count > cacheLimit, let oldest = accessOrder.first(where: { drafts[$0]?.canEvict == true }) {
            drafts.removeValue(forKey: oldest)
            accessOrder.removeAll { $0 == oldest }
        }
        return draft
    }
    func remove(sessionId: String, api: WandAPI) {
        let key = ServerProfiles.stableID(for: api.baseURL) + "." + sessionId
        drafts.removeValue(forKey: key)?.retire()
        accessOrder.removeAll { $0 == key }
        UserDefaults.standard.removeObject(forKey: "wand.composer.v1." + key)
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
    var maximumHeight: CGFloat = ComposerMetrics.expandedInputMaxHeight
    var submitOnReturn: Bool = true
    var onPasteImages: (([(data: Data, name: String?, mimeType: String?)]) -> Void)? = nil
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
        // 折叠/展开控制行可能重建 representable；UIKit 默认把新视图的光标放到
        // 开头，会把正在连续输入的后续文字插到第一个字符之前。
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        textView.placeholder = placeholder
        textView.onMarkedTextChange = { [weak textView, weak coordinator = context.coordinator] active in
            guard let textView, let coordinator else { return }
            if !active { coordinator.commitText(from: textView) }
            coordinator.publishComposition(active)
        }
        textView.onPasteImages = { items in
            context.coordinator.parent.onPasteImages?(items)
        }
        textView.backgroundColor = .clear
        textView.textColor = UIColor.label
        textView.tintColor = UIColor(Theme.brand)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.onLayoutSizeChange = { [weak coordinator = context.coordinator] textView in
            coordinator?.reportHeight(for: textView)
        }
        textView.keyboardDismissMode = .none
        textView.returnKeyType = submitOnReturn ? .send : .default
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
        textView.onMarkedTextChange = { [weak textView, weak coordinator = context.coordinator] active in
            guard let textView, let coordinator else { return }
            if !active { coordinator.commitText(from: textView) }
            coordinator.publishComposition(active)
        }
        textView.onPasteImages = { items in
            context.coordinator.parent.onPasteImages?(items)
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
            let location = min(selected.location, maxLocation)
            let length = min(selected.length, maxLocation - location)
            textView.selectedRange = NSRange(location: location, length: length)
            textView.refreshPlaceholder()
            context.coordinator.reportHeight(for: textView)
        }

        context.coordinator.reportHeight(for: textView)
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
        textView.onLayoutSizeChange = nil
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
            if !composing { commitText(from: textView) }
            reportHeight(for: textView)
        }

        func commitText(from textView: UITextView) {
            guard !isApplyingBinding, textView.markedTextRange == nil else { return }
            let committed = textView.text ?? ""
            if parent.text != committed { parent.text = committed }
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
            if text == "\n", parent.submitOnReturn {
                guard composerShouldSubmitReturn(isComposing: false) else { return true }
                parent.onSubmit()
                return false
            }
            return true
        }

        func reportHeight(for textView: UITextView) {
            // 首次挂载、抽屉展开与旋转都会改变真实宽度；不能用猜测的 280pt
            // 测量一次后沿用，否则换行数和可滚动状态会停留在旧布局。
            guard textView.bounds.width > 0 else { return }
            let fitted = textView.sizeThatFits(
                CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
            )
            let height = min(parent.maximumHeight, max(24, ceil(fitted.height)))
            textView.isScrollEnabled = fitted.height > parent.maximumHeight
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            DispatchQueue.main.async { [weak self] in
                self?.parent.onHeightChange(height)
            }
        }
    }
}

final class ComposerUITextView: UITextView {
    var onLayoutSizeChange: ((ComposerUITextView) -> Void)?
    private var lastLayoutSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        onLayoutSizeChange?(self)
        if isFirstResponder, markedTextRange == nil {
            scrollRangeToVisible(selectedRange)
        }
    }

    var onMarkedTextChange: ((Bool) -> Void)?
    var onPasteImages: (([(data: Data, name: String?, mimeType: String?)]) -> Void)?
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
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = Theme.textPlaceholderUI
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

    override func paste(_ sender: Any?) {
        if consumePastedImages() { return }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), clipboardContainsImage() {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    private func clipboardContainsImage() -> Bool {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages { return true }
        return pasteboard.itemProviders.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
    }

    private func consumePastedImages() -> Bool {
        guard let onPasteImages else { return false }
        let pasteboard = UIPasteboard.general
        var items: [(data: Data, name: String?, mimeType: String?)] = []
        if let images = pasteboard.images, !images.isEmpty {
            for (index, image) in images.enumerated() {
                guard let data = image.pngData() else { continue }
                items.append((data, "clipboard-image-\(index + 1).png", "image/png"))
            }
        } else if let image = pasteboard.image, let data = image.pngData() {
            items.append((data, "clipboard-image.png", "image/png"))
        }
        guard !items.isEmpty else { return false }
        onPasteImages(items)
        return true
    }
}
