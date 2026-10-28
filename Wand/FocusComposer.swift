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

/// One detail viewport for pending and running conversations. Creation supplies only
/// its options and submit action; it does not own a second page or keyboard layout.
struct ChatDetailLayout<Content: View, Composer: View>: View {
    var topClearance: CGFloat = 0
    var keyboardLift: CGFloat = 0
    var onReadingTap: () -> Void = {}
    @ViewBuilder let content: () -> Content
    @ViewBuilder let composer: () -> Composer

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .padding(.top, topClearance)
                .contentShape(Rectangle())
                .onTapGesture(perform: onReadingTap)
            composer()
                .padding(.bottom, keyboardLift)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.workspaceReading)
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
    var surfaceColor: Color? = nil
    // The dock may own outer spacing; it must not remove the text-field surface.
    var isEmbeddedInDock = false
    var isFocused = false
    var actionCount = 0
    var accessory: AnyView? = nil
    var placeholder = "发消息…"
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        VStack(spacing: 4) {
            if let accessory { accessory }
            ZStack(alignment: .bottomTrailing) {
                capsule
                if actionCount > 0 { send().frame(width: actionWidth, height: 48).padding(.trailing, 4) }
            }
        }.padding(.horizontal, isEmbeddedInDock ? 0 : 12)
            .padding(.bottom, isEmbeddedInDock ? 0 : 6)
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
                            Text(hasDraft ? "草稿 · 未发送" : placeholder).font(.body).lineLimit(1)
                        }.padding(.leading, 8).padding(.trailing, 12)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(hasDraft ? "编辑未发送草稿及附件" : "展开文字输入")
                        .frame(height: expanded ? 0 : nil).clipped()
                        .opacity(expanded ? 0 : 1).allowsHitTesting(!expanded).accessibilityHidden(expanded)
            }.padding(.horizontal, 4)
        }
        .foregroundStyle(Theme.textSecondary)
        .wandInputSurface(focused: isFocused, cornerRadius: expanded ? 20 : 24,
            fill: surfaceColor ?? Theme.surface)
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

/// Default is centered between the back and consolidated menu controls.
func topCompanionCenter(width: CGFloat, size: CGFloat, side: CatComposerSide, drag: CGFloat) -> CGFloat {
    let minimum = ChatTopLayout.backInset + ChatTopLayout.controlRowInset + size / 2
    let maximum = max(minimum, width - ChatTopLayout.actionsInset - ChatTopLayout.controlRowInset - size / 2)
    let center = (minimum + maximum) / 2
    let resting = side == .left ? center : min(maximum, center + 24)
    return min(maximum, max(minimum, resting + drag))
}

/// One shared boundary for chat, IM and previews; independent of drafts and the keyboard.
enum ChatTopLayout {
    static let horizontalInset: CGFloat = 12
    static let controlTouch: CGFloat = 48
    static let controlRowInset: CGFloat = 4
    static let controlsClearance = controlTouch + controlRowInset * 2
    static func clearance(compact: Bool) -> CGFloat {
        max(controlsClearance, compact ? 56 : 100)
    }
    /// 顶栏身份区可用的水平带子：左侧让开返回键，右侧让开合并后的更多按钮，
    /// 与 Android `FloatingControlsBackInset` / `FloatingControlsActionsInset` 同一份几何。
    static let backInset = horizontalInset + controlTouch
    static let actionsInset = horizontalInset + controlTouch
    static func identityBand(width: CGFloat) -> (center: CGFloat, width: CGFloat) {
        let usable = max(48, width - backInset - actionsInset)
        return (backInset + usable / 2, usable)
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
    /// 无头像版的两行身份区高度，只剩文字，不再为头像占位。
    var identityClearance: CGFloat { max(ChatTopLayout.controlsClearance, textHeight + 8) }
}

/// 顶部身份区的运行态文案（对齐 Android `companionWorkStatus`）：能看出在读还是在写就说
/// 在读还是在写；已经有待办进度条或子 Agent 状态坞在承载细粒度进度时留空，不再重复一句
/// 「正在处理」。整个会话只有一个运行态文案，输入区不另写一份。
func identityWorkStatus(activity: AvatarFileActivity, hasDetailedProgress: Bool) -> String {
    switch activity {
    case .reading: return "正在读文件"
    case .writing: return "正在写文件"
    case .idle: return hasDetailedProgress ? "" : "正在处理"
    }
}

/// 顶栏目录缩写：只留最后一段路径名（与 macOS `SessionHeaderView` 的 basename 显示同语义）。
/// 绝对路径整条塞进小字行会把员工名挤掉，根目录或空路径则不显示。
func abbreviatedDirectory(_ cwd: String?) -> String {
    let raw = (cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "" }
    let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    let name = (trimmed as NSString).lastPathComponent
    return name == "/" ? "" : name
}

/// 会话顶栏身份两行：主标题优先任务名，没有归属任务（独立会话、IM 执行会话）时回落会话标题；
/// 小字为「员工名 · 目录缩写」，缺项自动省掉分隔符。
func chatTopIdentity(taskTitle: String?, sessionTitle: String, employeeName: String?, cwd: String?)
    -> (title: String, subtitle: String) {
    func clean(_ value: String?) -> String { value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    let task = clean(taskTitle)
    let title = task.isEmpty ? clean(sessionTitle) : task
    let subtitle = [clean(employeeName), abbreviatedDirectory(cwd)].filter { !$0.isEmpty }
        .joined(separator: " · ")
    return (title.isEmpty ? "当前会话" : title, subtitle)
}

/// 顶栏状态点的语义档位。由会话的真实状态位判定，不从展示文案反推。
enum ChatTopAttention: Equatable {
    case quiet, running, needsYou, fault

    static func resolve(connected: Bool, blocked: Bool, sending: Bool, responding: Bool, status: String) -> ChatTopAttention {
        if !connected || status == "failed" { return .fault }
        if blocked { return .needsYou }
        if sending || responding { return .running }
        return .quiet
    }

    var color: Color {
        switch self {
        case .quiet: return Color.clear
        case .running: return Theme.brand
        case .needsYou: return Theme.permission
        case .fault: return Theme.danger
        }
    }
}

/// 顶栏的读屏播报：视觉上只剩标题、小字和一个状态点，完整信息仍要能被读出来。
func chatTopReadback(title: String, subtitle: String, status: String) -> String {
    [title, subtitle, status].filter { !$0.isEmpty }.joined(separator: "，")
}

/// 会话顶栏身份区：胶囊里左侧是圆圈头像，右侧主标题是任务名，小字是「员工名 · 目录缩写」。
/// 运行与异常只以一个状态点呈现，具体文案交给权限卡、连接横幅和进度条，这条栏不再重复说话。
struct ChatTopIdentityBar: View {
    let title: String
    let subtitle: String
    let attention: ChatTopAttention
    /// 读屏仍播报完整状态，视觉做减法不代表信息丢失。
    var statusText: String = ""
    /// 胶囊左侧头像的身份；没有员工时用默认伙伴。
    var avatarID: String = "e_wand_default"
    var avatarName: String = ""
    var avatarValue: String = ""
    /// 头像活动效果：思考落定、查看文件、编写文件（与 Web `fileActivity` / `thinking` 同口径）。
    var activity: AvatarFileActivity = .idle
    var thinking = false
    var speaking = false
    private var identityMetrics = ChatIdentityLayoutMetrics()

    var body: some View {
        GeometryReader { area in
            let band = ChatTopLayout.identityBand(width: area.size.width)
            HStack(spacing: 6) {
                if attention != .quiet { dot }
                TopCapsuleTitle(title: title, subtitle: subtitle,
                    avatarID: avatarID, avatarName: avatarName, avatarValue: avatarValue,
                    avatarSize: 30, titleSize: 13, subtitleSize: 11,
                    titleWidth: max(48, band.width - 67),
                    activity: activity, thinking: thinking, speaking: speaking)
            }
            // 身份文字只在返回键与右侧两枚按钮之间的带子里排布，长标题省略号不会压到按钮。
            .frame(width: band.width)
            .position(x: band.center, y: identityMetrics.identityClearance / 2)
        }
        .frame(height: identityMetrics.identityClearance)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chatTopReadback(title: title, subtitle: subtitle, status: statusText))
        .accessibilityIdentifier("chat-visible-identity")
    }

    /// 状态点复用全局节奏 token 呼吸，不自己起一个定时器；关闭动效时静止。
    private var dot: some View {
        Circle().fill(attention.color).frame(width: 6, height: 6)
            .topicTitleRhythm(attention == .running)
            .accessibilityHidden(true)
    }
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
            let footprint = title != nil && identityMetrics.compact ? max(48, ChatTopLayout.identityBand(width: area.size.width).width - ChatTopLayout.controlRowInset * 2) : size
            let center = topCompanionCenter(width: area.size.width, size: footprint, side: side, drag: dragOffset)
            if title != nil && identityMetrics.compact {
                HStack(spacing: 8) {
                    face(size).frame(width: size, height: size)
                    identityText.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: max(48, ChatTopLayout.identityBand(width: area.size.width).width - ChatTopLayout.controlRowInset * 2), height: identityMetrics.clearance)
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
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            .lineLimit(1).truncationMode(.tail)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 48)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Closed options show only their current values; full labels belong to the picker.
struct ComposerSettingsStrip: View {
    let model: String
    let mode: String
    let thinking: String
    let onModel: () -> Void
    let onMode: () -> Void
    let onThinking: () -> Void
    var modeName: String = "权限模式"
    var body: some View {
        HStack(spacing: 4) {
            setting(model, accessibility: "模型：\(model)", action: onModel)
            setting(mode, accessibility: "\(modeName)：\(mode)", action: onMode)
            setting(thinking, accessibility: "思考深度：\(thinking)", action: onThinking)
        }.buttonStyle(WandQuietButtonStyle(tint: Theme.textSecondary))
    }
    private func setting(_ label: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ComposerSettingLabel(title: label) }
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
