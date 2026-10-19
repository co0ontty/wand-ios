import SwiftUI

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
struct FocusComposerSurface<Editor: View, Add: View, Send: View, Settings: View>: View {
    let expanded: Bool
    let hasDraft: Bool
    let onFocus: () -> Void
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let add: () -> Add
    @ViewBuilder let send: () -> Send
    @ViewBuilder let settings: () -> Settings
    var actionCount = 0
    var accessory: AnyView? = nil
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        VStack(spacing: 4) {
            if let accessory { accessory }
            ZStack(alignment: .bottomTrailing) {
                capsule
                if actionCount > 0 { send().frame(width: actionWidth, height: 48).padding(.trailing, 4) }
            }
        }.padding(.horizontal, 12).padding(.bottom, 6)
    }
    private var capsule: some View {
        VStack(spacing: 0) {
            editor().padding(.horizontal, 12).padding(.top, expanded ? 10 : 0)
                .frame(height: expanded ? nil : 0).clipped()
                .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
            ComposerCapsuleToolbarLayout(expanded: expanded, actionInset: actionInset) {
                add()
                settings().frame(maxWidth: expanded ? .infinity : nil)
                    .frame(width: expanded ? nil : 0, height: expanded ? nil : 0).clipped()
                    .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
                    Button(action: onFocus) {
                        HStack(spacing: 4) {
                            if hasDraft { Circle().fill(Theme.brand).frame(width: 6, height: 6) }
                            Text(hasDraft ? "草稿 · 未发送" : "发消息…").font(.subheadline).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(hasDraft ? "编辑未发送草稿及附件" : "展开文字输入")
                        .frame(height: expanded ? 0 : nil).clipped()
                        .opacity(expanded ? 0 : 1).allowsHitTesting(!expanded).accessibilityHidden(expanded)
            }.padding(.horizontal, 4)
        }
        .foregroundStyle(Theme.textSecondary)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: expanded ? 20 : 24))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 20 : 24).stroke(Theme.border, lineWidth: 0.8))
        // The editor uses full width; only the bottom toolbar reserves the send slot.
        .frame(maxWidth: .infinity)
        .animation(reduced ? nil : WandMotion.disclosure, value: expanded)
    }
    private var actionWidth: CGFloat { CGFloat(actionCount) * ComposerMetrics.actionTouchSize }
    private var actionInset: CGFloat { actionCount > 0 ? actionWidth + 4 : 0 }
}

/// Pure slot resolution for the capsule toolbar, independent of SwiftUI's subview storage.
///
/// The settings slot is a `@ViewBuilder` branch. An empty branch (for example
/// `settings: { EmptyView() }`) collapses to zero subviews, so slots must follow the real
/// child count — indexing `subviews[2]` unconditionally traps in `LayoutSubviews.subscript`.
struct ComposerCapsuleSlots: Equatable {
    let add: Int
    let settings: Int?
    let prompt: Int
    /// `nil` when there is no prompt lane to place (fewer than two real children).
    init?(childCount: Int) {
        guard childCount >= 2 else { return nil }
        let hasSettings = childCount >= 3
        add = 0
        settings = hasSettings ? 1 : nil
        prompt = hasSettings ? 2 : 1
    }
}

/// Native layout changes placement without replacing the editor or settings sheet owner.
private struct ComposerCapsuleToolbarLayout: Layout {
    let expanded: Bool
    let actionInset: CGFloat
    private let touch: CGFloat = 48

    private struct Metrics {
        let settingsWidth: CGFloat
        let settingsHeight: CGFloat
        let rowHeight: CGFloat
        let stacked: Bool
    }
    private func metrics(width: CGFloat, slots: ComposerCapsuleSlots?, subviews: Subviews) -> Metrics {
        let stacked = expanded && width - actionInset < touch * 4
        let settingsWidth = stacked ? width : max(0, width - actionInset - touch)
        let settingsHeight = expanded
            ? slots.flatMap { $0.settings.map { subviews[$0] } }?
                .sizeThatFits(ProposedViewSize(width: settingsWidth, height: nil)).height ?? 0 : 0
        return Metrics(settingsWidth: settingsWidth, settingsHeight: stacked ? settingsHeight : 0,
            rowHeight: max(touch, stacked ? 0 : settingsHeight), stacked: stacked)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let layout = metrics(width: width, slots: ComposerCapsuleSlots(childCount: subviews.count), subviews: subviews)
        return CGSize(width: width, height: layout.settingsHeight + layout.rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let slots = ComposerCapsuleSlots(childCount: subviews.count) else { return }
        let layout = metrics(width: bounds.width, slots: slots, subviews: subviews)
        let y = bounds.minY + layout.settingsHeight + (layout.rowHeight - touch) / 2
        subviews[slots.add].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: touch, height: touch))
        if let settings = slots.settings {
            subviews[settings].place(at: CGPoint(x: bounds.minX + (layout.stacked ? 0 : touch), y: bounds.minY + (layout.stacked ? 0 : (layout.rowHeight - touch) / 2)),
                anchor: .topLeading, proposal: ProposedViewSize(width: expanded ? layout.settingsWidth : 0, height: expanded ? touch : 0))
        }
        subviews[slots.prompt].place(at: CGPoint(x: bounds.minX + touch, y: y), anchor: .topLeading,
            proposal: ProposedViewSize(width: expanded ? 0 : max(0, bounds.width - touch - actionInset), height: expanded ? 0 : touch))
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

/// Shared scalable metrics keep identity text and the reading viewport in agreement.
struct ChatIdentityLayoutMetrics: DynamicProperty {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .caption) var titleLine: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) var statusLine: CGFloat = 14
    init() {}
    var compact: Bool { verticalSizeClass == .compact }
    var faceSize: CGFloat { compact ? 48 : 56 }
    var textHeight: CGFloat { titleLine * 2 + 2 + statusLine }
    var clearance: CGFloat { max(ChatTopLayout.controlsClearance, compact ? textHeight + 8 : 4 + faceSize + 4 + textHeight + 4) }
}

struct TopChatCompanion<Face: View>: View {
    var side: CatComposerSide = .left
    var dragOffset: CGFloat = 0
    var title: String? = nil
    var status: String = ""
    @ViewBuilder let face: (CGFloat) -> Face
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var identityMetrics = ChatIdentityLayoutMetrics()
    var body: some View {
        GeometryReader { area in
            let size: CGFloat = title == nil ? (verticalSizeClass == .compact ? 48 : 88) : identityMetrics.faceSize
            let footprint = title != nil && identityMetrics.compact ? max(48, area.size.width - 180) : size
            let center = topCompanionCenter(width: area.size.width, size: footprint, side: side, drag: dragOffset)
            if title != nil && identityMetrics.compact {
                HStack(spacing: 8) {
                    face(size).frame(width: size, height: size)
                    identityText.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: max(48, area.size.width - 180), height: identityMetrics.clearance)
                    .position(x: center, y: identityMetrics.clearance / 2)
            } else {
                face(size).frame(width: size, height: size).position(x: center, y: size / 2 + 4)
                if title != nil {
                    identityText.frame(width: max(48, min(center - 16, area.size.width - 16 - center) * 2))
                        .position(x: center, y: 4 + size + 4 + identityMetrics.textHeight / 2)
                }
            }
        }.frame(height: title == nil ? ChatTopLayout.clearance(compact: verticalSizeClass == .compact) : identityMetrics.clearance)
    }
    private var identityText: some View {
        VStack(alignment: identityMetrics.compact ? .leading : .center, spacing: 2) {
            Text(title ?? "当前会话").font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                .lineLimit(2).truncationMode(.tail).multilineTextAlignment(identityMetrics.compact ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: identityMetrics.compact ? .leading : .center)
                .frame(height: identityMetrics.titleLine * 2)
            Text(status).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .frame(height: identityMetrics.statusLine)
        }.frame(height: identityMetrics.textHeight).allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel((title ?? "当前会话") + "，" + status)
            .accessibilityIdentifier("chat-visible-identity")
    }
}

struct ComposerSettingLabel: View {
    let title: String
    var symbol: String? = nil
    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 44, height: 48)
            } else {
                HStack(spacing: 3) {
                    Text(title).font(.caption).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.frame(minWidth: 44, maxWidth: .infinity, minHeight: 48)
            }
        }.contentShape(Rectangle())
    }
}

/// Reuse native buttons; narrow toolbars keep the model name and two independent icons.
struct ComposerSettingsStrip: View {
    let model: String
    let mode: String
    let thinking: String
    let onModel: () -> Void
    let onMode: () -> Void
    let onThinking: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                setting(model, accessibility: "模型：\(model)", action: onModel)
                setting(mode, accessibility: "权限模式：\(mode)", action: onMode)
                setting(thinking, accessibility: "思考深度：\(thinking)", action: onThinking)
            }.fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 0) {
                setting(model, accessibility: "模型：\(model)", action: onModel)
                setting(mode, symbol: "lock", accessibility: "权限模式：\(mode)", action: onMode)
                setting(thinking, symbol: "brain", accessibility: "思考深度：\(thinking)", action: onThinking)
            }
        }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
    }
    private func setting(_ label: String, symbol: String? = nil, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ComposerSettingLabel(title: label, symbol: symbol) }
            .accessibilityLabel(accessibility).accessibilityHint("打开完整选项")
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
        ComposerSettingsStrip(model: modelLabel, mode: modeLabel, thinking: thinkingLabel,
            onModel: { open(.model) }, onMode: { open(.mode) }, onThinking: { open(.thinking) })
        .disabled(store.loading || store.loadError != nil || store.providerSwitching || store.directoryChanging)
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
    private func open(_ value: Setting) {
        focus.borrow("settings", open: true); picker = value
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
