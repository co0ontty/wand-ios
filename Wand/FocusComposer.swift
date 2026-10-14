import SwiftUI
import Combine

/// Presentation state only. Drafts, attachments and delivery stay with their existing owners.
@MainActor final class ComposerFocusController: ObservableObject {
    @Published var focused = false
    @Published var editing = false
    private(set) var borrowers: Set<String> = []
    private var restore = false
    func focus() { editing = true; focused = true }
    func collapse() { restore = false; focused = false; editing = false }
    func borrow(_ owner: String, open: Bool = false) {
        restore = restore || focused || open
        if open { editing = true }
        borrowers.insert(owner)
        focused = false
    }
    func resume(_ owner: String) {
        guard borrowers.remove(owner) != nil, borrowers.isEmpty else { return }
        let shouldRestore = restore && editing
        restore = false
        if shouldRestore { focused = true }
    }
    func keyboardHidden() {
        guard borrowers.isEmpty else { return }
        collapse()
    }
}

/// The text view stays mounted, including while the small capsule hides its editing area.
struct FocusComposerSurface<Editor: View, Add: View, Voice: View, Send: View, Settings: View>: View {
    let expanded: Bool
    let hasDraft: Bool
    let onFocus: () -> Void
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let add: () -> Add
    @ViewBuilder let voice: () -> Voice
    @ViewBuilder let send: () -> Send
    @ViewBuilder let settings: () -> Settings
    var primaryVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            capsule.padding(.trailing, expanded ? 0 : 52)
            send().frame(width: 48, height: 48).padding(.bottom, 2)
                .opacity(primaryVisible ? 1 : 0).allowsHitTesting(primaryVisible).accessibilityHidden(!primaryVisible)
                .animation(reduced ? nil : WandMotion.stateSwap, value: primaryVisible)
        }.padding(.horizontal, 12).padding(.bottom, 6)
    }
    private var capsule: some View {
        VStack(spacing: 0) {
            editor().padding(.horizontal, 12).padding(.top, expanded ? 10 : 0)
                .frame(height: expanded ? nil : 0).clipped()
                .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
            settings().padding(.horizontal, 8)
                .frame(height: expanded ? nil : 0).clipped()
                .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
            HStack(spacing: 0) {
                add()
                if expanded { Spacer(minLength: 0) }
                else {
                    Button(action: onFocus) {
                        HStack(spacing: 4) {
                            if hasDraft { Circle().fill(Theme.brand).frame(width: 6, height: 6) }
                            Text(hasDraft ? "草稿 · 未发送" : "发消息…").font(.subheadline).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(hasDraft ? "编辑未发送草稿及附件" : "展开文字输入")
                }
                voice()
            }.padding(.horizontal, 4).padding(.trailing, expanded ? 52 : 0)
        }
        .foregroundStyle(Theme.textSecondary)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: expanded ? 20 : 26))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 20 : 26).stroke(Theme.border, lineWidth: 0.8))
        // The editor uses full width; only the bottom toolbar reserves the send slot.
        .frame(maxWidth: .infinity)
        .animation(reduced ? nil : WandMotion.disclosure, value: expanded)
    }
}

/// Default is the middle of the free slot between back and the two trailing controls.
func topCompanionCenter(width: CGFloat, size: CGFloat, side: CatComposerSide, drag: CGFloat) -> CGFloat {
    let minimum = 64 + size / 2
    let maximum = max(minimum, width - 116 - size / 2)
    let center = (minimum + maximum) / 2
    let resting = side == .left ? center : min(maximum, center + 24)
    return min(maximum, max(minimum, resting + drag))
}

/// One shared boundary for chat, IM and previews; independent of drafts and the keyboard.
enum ChatTopLayout {
    static let controlTouch: CGFloat = 48
    static let controlRowInset: CGFloat = 4
    static let controlsClearance = controlTouch + controlRowInset * 2
    static func clearance(compact: Bool) -> CGFloat {
        max(controlsClearance, compact ? 56 : 100)
    }
}

struct TopChatCompanion<Face: View>: View {
    var side: CatComposerSide = .left
    var dragOffset: CGFloat = 0
    @ViewBuilder let face: (CGFloat) -> Face
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        GeometryReader { area in
            let size: CGFloat = verticalSizeClass == .compact ? 48 : 88
            face(size).frame(width: size, height: size)
                .position(x: topCompanionCenter(width: area.size.width, size: size, side: side, drag: dragOffset), y: size / 2 + 4)
        }.frame(height: ChatTopLayout.clearance(compact: verticalSizeClass == .compact))
    }
}

struct ComposerSettingLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 3) {
            Text(title).font(.subheadline).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
    }
}

/// One voice owner for the top companion and microphone; both write only to the captured draft.
@MainActor final class DraftVoiceController: ObservableObject {
    let speech = SpeechRecognizerService()
    @Published private(set) var holding = false
    @Published var cancelling = false
    @Published var notice: String?
    private var observation: AnyCancellable?
    private var draft: ComposerDraftState?
    private weak var focus: ComposerFocusController?
    private var revision = 0
    private var lifecycle = 0
    init() { observation = speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    func begin(draft: ComposerDraftState, focus: ComposerFocusController) {
        guard !holding, !speech.isProcessing, !speech.isRecording, draft.sendPhase != .sending, !draft.attachments.isUploading else { return }
        self.draft = draft; self.focus = focus; revision = draft.textRevision; lifecycle = draft.lifecycleRevision
        holding = true; cancelling = false; notice = nil
        focus.borrow("voice", open: focus.editing)
        speech.start(api: draft.speechAPI) { [weak self] message in
            guard let self else { return }; notice = message; holding = false; cancelling = false; focus.resume("voice")
        }
    }
    func finish(cancelled: Bool) {
        guard holding || speech.isRecording || speech.isProcessing else { return }
        holding = false; cancelling = false
        let captured = draft, revision = revision, lifecycle = lifecycle
        speech.stop(cancelled: cancelled) { [weak self] text in
            guard let self else { return }
            captured?.appendVoice(text, ifUnchangedSince: revision, lifecycle: lifecycle)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notice = "没有听到声音，草稿已保留" }
            focus?.resume("voice")
        }
        if cancelled { notice = "已取消，草稿保留"; focus?.resume("voice") }
        else if !speech.isProcessing { focus?.resume("voice") }
    }
    func gesture(draft: ComposerDraftState, focus: ComposerFocusController,
                 onDrag: @escaping (CGFloat) -> Void = { _ in }, onDrop: @escaping (CGFloat) -> Void = { _ in }) -> CatInputGesture {
        CatInputGesture(onTap: { focus.focus() }, onHold: { self.begin(draft: draft, focus: focus) },
            onMove: { self.cancelling = $0 }, onRelease: { self.finish(cancelled: $0) }, onDrag: onDrag, onDrop: onDrop)
    }
}

/// Three separate settings, using the session's real catalog and mutation queue.
struct SessionComposerSettings: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var focus: ComposerFocusController
    @State private var picker: Setting?
    @State private var proposedMode: String?
    @State private var confirmMode = false
    private enum Setting: String, Identifiable { case model, mode, thinking; var id: String { rawValue } }
    private var provider: WandProvider { WandProvider(rawValue: store.snapshot?.provider ?? "claude") ?? .claude }
    private var selectedModel: String { store.selectedModel.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 } ?? store.defaultModel ?? "default" }
    private var modelLabel: String { if store.loading { return "模型加载中…" }; return store.availableModels.first { $0.id == selectedModel }?.label ?? (selectedModel == "default" ? "默认模型" : selectedModel) }
    private var options: [ThinkingEffortOption]? {
        dynamicThinkingEffortOptions(provider: provider.rawValue, selectedModel: store.selectedModel, defaultModel: store.defaultModel,
            models: store.availableModels, providerEfforts: store.availableThinkingEfforts)
    }
    private var thinkingLabel: String { options?.first { $0.id == store.thinkingEffort }?.label ?? (store.thinkingEffort == "off" ? "自动" : store.thinkingEffort) }
    private let modes = [("default", "标准 · 按需确认"), ("auto-edit", "自动编辑 · 写入文件自动批准"), ("full-access", "全权限 · 自动批准工具操作"), ("managed", "托管 · 由托管规则处理确认"), ("native", "原生 · 由执行工具管理权限")]
    private var modeLabel: String { ["default": "标准", "auto-edit": "自动编辑", "full-access": "全权限", "managed": "托管", "native": "原生"][store.mode] ?? store.mode }
    var body: some View {
        HStack(spacing: 2) {
            setting(.model, label: modelLabel, accessibility: "模型：\(modelLabel)")
            setting(.mode, label: modeLabel, accessibility: "权限模式：\(modeLabel)")
            setting(.thinking, label: "思考：\(thinkingLabel)", accessibility: "思考深度：\(thinkingLabel)")
        }
        .sheet(item: $picker, onDismiss: {
            if proposedMode == nil { focus.resume("settings") }
            else { confirmMode = true }
        }) { selection in
            settingsSheet(selection)
        }
        .confirmationDialog("更改当前会话权限", isPresented: $confirmMode, titleVisibility: .visible) {
            Button("应用到当前会话", role: .destructive) {
                if let mode = proposedMode { store.setMode(mode) }
                proposedMode = nil; focus.resume("settings")
            }
            Button("取消", role: .cancel) { proposedMode = nil; focus.resume("settings") }
        } message: {
            Text(modes.first { $0.0 == proposedMode }?.1 ?? "")
        }
    }
    private func setting(_ value: Setting, label: String, accessibility: String) -> some View {
        Button { focus.borrow("settings", open: true); picker = value } label: { ComposerSettingLabel(title: label) }
            .buttonStyle(.plain).accessibilityLabel(accessibility).accessibilityHint("打开完整选项")
            .disabled(store.loading || store.loadError != nil || store.providerSwitching || store.directoryChanging)
    }
    @ViewBuilder private func settingsSheet(_ selection: Setting) -> some View {
        if selection == .thinking && (options == nil || options!.count <= 1) {
            NavigationStack {
                Text(options == nil ? "当前模型的思考能力尚未返回；保留现有选择，稍后重试。" : "当前模型不提供可调整的思考深度，将使用模型默认值。")
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                    .navigationTitle("思考深度").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { picker = nil } } }
            }.presentationDetents([.medium])
        } else if selection == .mode && provider == .codex {
            NavigationStack {
                Text("当前 Codex 会话权限固定为\(modeLabel)。更改需要创建新会话；此处不会提升权限。")
                    .padding(24).navigationTitle("权限模式").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { picker = nil } } }
            }.presentationDetents([.medium])
        } else {
            SearchableChoiceSheet(title: selection == .model ? "模型" : selection == .mode ? "权限模式" : "思考深度", sections: [section(selection)]) { _, value in
                switch selection {
                case .model: store.setModel(value.isEmpty ? nil : value)
                case .thinking: store.setThinkingEffort(value)
                case .mode:
                    if ["full-access", "managed", "auto-edit"].contains(value), value != store.mode { proposedMode = value }
                    else { store.setMode(value) }
                }
            }
        }
    }
    private func section(_ selection: Setting) -> SearchableChoiceSection {
        switch selection {
        case .model:
            return SearchableChoiceSection(id: "model", items: [SearchableChoiceItem(id: "", label: "默认 · \(store.defaultModel ?? "跟随服务端")")] + store.availableModels.filter { $0.id != "default" }.map { SearchableChoiceItem(id: $0.id, label: $0.label) }, selectedId: store.selectedModel ?? "", searchable: true)
        case .mode:
            return SearchableChoiceSection(id: "mode", items: modes.filter { provider.supportedModeIDs.contains($0.0) }.map { SearchableChoiceItem(id: $0.0, label: $0.1) }, selectedId: store.mode)
        case .thinking:
            return SearchableChoiceSection(id: "thinking", items: (options ?? []).map { SearchableChoiceItem(id: $0.id, label: $0.menuLabel) }, selectedId: store.thinkingEffort)
        }
    }
}

func composerModeName(_ value: String) -> String {
    ["default": "标准（按需确认）", "auto-edit": "自动编辑", "full-access": "全权限", "managed": "托管", "native": "原生权限"][value] ?? value
}
func composerThinkingName(_ value: String) -> String {
    ["off": "自动", "standard": "低", "deep": "中", "max": "高"][value] ?? value
}
