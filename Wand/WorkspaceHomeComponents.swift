import SwiftUI
import UIKit

/// One native search treatment for all four landing surfaces; keep the clear target stable.
struct HomeSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var identifier = "home-search-input"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .font(.subheadline).focused(focused)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .accessibilityLabel(placeholder).accessibilityIdentifier(identifier)
            Button { text = ""; focused.wrappedValue = true } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: WandLayout.controlTouch, height: WandLayout.controlTouch)
            }
            .buttonStyle(.plain).disabled(text.isEmpty)
            .opacity(text.isEmpty ? 0 : 1).accessibilityHidden(text.isEmpty)
            .accessibilityLabel("清空搜索")
        }
        .padding(.leading, WandLayout.fieldGap)
        .frame(minHeight: WandLayout.controlTouch)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension HomeExecutionState {
    var tint: Color {
        switch self {
        case .running: return Theme.success
        case .queued: return Theme.info
        case .needsYou: return Theme.warning
        case .failed: return Theme.danger
        case .completed: return Theme.brand
        case .idle, .archived: return Theme.textSecondary
        }
    }
}

struct HomeExecutionBadge: View {
    let state: HomeExecutionState
    var compact = false

    var body: some View {
        Group {
            if compact {
                label
            } else {
                label
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .wandGlassCapsule(tint: state.tint)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("执行状态：" + state.label)
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol).accessibilityHidden(true)
            Text(state.label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(state.tint)
    }
}

struct HomeRowAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var tint: Color = Theme.brand
    let perform: () -> Void
}

/// Reuses the board's bounded, velocity-aware reveal contract; swiping never executes an action.
struct HomeSwipeRow<Content: View>: View {
    let id: String
    @Binding var revealedID: String?
    let actions: [HomeRowAction]
    var enabled = true
    var surface: Color = Theme.background
    @ViewBuilder let content: () -> Content
    @State private var dragTranslation: CGFloat = 0
    @State private var draggingHorizontally = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var revealed: Bool { enabled && revealedID == id }
    private var width: CGFloat { CGFloat(actions.count) * 60 }
    private var offset: CGFloat {
        guard enabled else { return 0 }
        return min(0, max(-width, (revealed ? -width : 0) + (draggingHorizontally ? dragTranslation : 0)))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            content()
                .background(surface)
                .overlay {
                    if revealed { Color.clear.contentShape(Rectangle()).onTapGesture { close() } }
                }
                .offset(x: offset)
            HStack(spacing: 4) {
                ForEach(actions) { item in
                    Button {
                        close()
                        item.perform()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol).font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(item.tint, in: Circle())
                            Text(item.title).font(.caption2).foregroundStyle(item.tint).lineLimit(1)
                        }.frame(width: 56).frame(minHeight: 64).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(item.title)
                    .accessibilityIdentifier("swipe-" + id + "-" + item.id)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(width: max(0, -offset), alignment: .trailing).clipped()
            .allowsHitTesting(revealed || draggingHorizontally).accessibilityHidden(!revealed)
        }
        .clipped()
        .animation(reduceMotion ? nil : WandMotion.expansion, value: revealed)
        .gesture(HomeHorizontalPanGesture(enabled: enabled && !actions.isEmpty, allowsRightward: revealed,
            onChanged: { translation in
                draggingHorizontally = true; dragTranslation = translation
            }, onEnded: { translation, velocity, cancelled in
                let settled = min(0, max(-width, (revealed ? -width : 0) + translation))
                withAnimation(reduceMotion ? nil : WandMotion.expansion) {
                    dragTranslation = 0; draggingHorizontally = false
                    if !cancelled {
                        if wandBoardSwipeShouldReveal(offset: settled, revealWidth: width, velocity: velocity) {
                            revealedID = id
                        } else if revealedID == id { revealedID = nil }
                    }
                }
            }))
        .onChange(of: enabled) { _, value in if !value { dragTranslation = 0; draggingHorizontally = false; close() } }
        .onDisappear { dragTranslation = 0; draggingHorizontally = false; if revealedID == id { revealedID = nil } }
        .onKeyPress(.escape) { if revealed { close(); return .handled }; return .ignored }
        .accessibilityActions {
            ForEach(actions) { item in Button(item.title) { close(); item.perform() } }
        }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : WandMotion.expansion) {
            if revealedID == id { revealedID = nil }
        }
    }
}

extension View {
    func homeSwipeActions(id: String, revealedID: Binding<String?>, actions: [HomeRowAction], enabled: Bool = true, surface: Color = Theme.background) -> some View {
        HomeSwipeRow(id: id, revealedID: revealedID, actions: actions, enabled: enabled, surface: surface) { self }
    }

    func homeSwipeDismissal(_ revealedID: Binding<String?>) -> some View {
        onScrollPhaseChange { _, phase in
            if phase == .interacting { revealedID.wrappedValue = nil }
        }
    }
}

/// Reject vertical intent before .began; ignoring dy in a SwiftUI DragGesture is too late.
func homeSwipeShouldBegin(velocity: CGPoint, allowsRightward: Bool) -> Bool {
    abs(velocity.x) > abs(velocity.y) * 1.2 && (velocity.x < 0 || allowsRightward)
}

private struct HomeHorizontalPanGesture: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let allowsRightward: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = context.coordinator
        updateUIGestureRecognizer(pan, context: context)
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.allowsRightward = allowsRightward
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: onChanged(translation)
        case .ended: onEnded(translation, recognizer.velocity(in: recognizer.view).x, false)
        case .cancelled, .failed: onEnded(0, 0, true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var allowsRightward = false
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return homeSwipeShouldBegin(velocity: pan.velocity(in: pan.view), allowsRightward: allowsRightward)
        }
    }
}

/// The same List owns every row; explicit insets keep labels moving inward at each level.
enum WorkspaceTreeLevel: CGFloat {
    case directory = 16, task = 20, session = 32
}

extension View {
    func workspaceTreeRow(_ level: WorkspaceTreeLevel) -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: level.rawValue, bottom: 4, trailing: 12))
            .listRowBackground(Theme.surface)
            .listRowSeparator(.hidden)
    }
}

struct WorkspaceDirectoryLabel: View {
    let group: TaskDirectoryGroup
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var sessions: [WorkspaceSessionSummary] { group.tasks.flatMap(\.sessions) + group.standaloneSessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
                Text(group.workspaceName.isEmpty ? "任务目录" : group.workspaceName)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace-name-" + group.id)
                if !group.isGlobal, let path = TaskListPresentation.directoryPathCaption(name: group.workspaceName, cwd: group.workspaceCwd) {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(group.workspaceCwd)
                }
                Text("\(group.tasks.count) 个任务 · " + HomePresentation.sessionSummary(sessions))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}

struct WorkspaceSessionLabel: View {
    let session: WorkspaceSessionSummary
    let title: String
    let selected: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(session.providerLabel + (session.sessionKind == "pty" ? " · 终端" : ""))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if dynamicTypeSize.isAccessibilitySize { status }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !dynamicTypeSize.isAccessibilitySize { status }
        }
        .multilineTextAlignment(.leading)
    }

    private var status: some View {
        HomeExecutionBadge(state: HomePresentation.executionState(session))
    }
}

struct HomeSectionHeader: View {
    let title: String
    @Binding var foldRaw: String
    var onCreate: (() -> Void)? = nil
    var creatingExpanded = false
    var disabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                titleLabel.fixedSize()
                Spacer(minLength: 4)
                foldPicker.frame(width: 166)
                createButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { titleLabel; Spacer(minLength: 4); createButton }
                foldPicker
            }
        }
        .padding(.top, 16).padding(.bottom, 8)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var titleLabel: some View {
        Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
    }

    private var foldPicker: some View {
        Picker("\(title)显示方式", selection: $foldRaw) {
            ForEach(HomeFoldMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }
        .pickerStyle(.segmented)
        .disabled(disabled)
    }

    @ViewBuilder private var createButton: some View {
        if let onCreate {
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .rotationEffect(.degrees(creatingExpanded ? 45 : 0))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.brand)
                .disabled(disabled)
                .accessibilityLabel(creatingExpanded ? "收起新建工作区" : "新建工作区")
                .animation(reduceMotion ? nil : WandMotion.stateSwap, value: creatingExpanded)
        }
    }
}

struct HomeRecentGroupHeader: View {
    let group: HomeRecentGroup
    let expanded: Bool
    let onToggle: (() -> Void)?
    var onCreate: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let onToggle {
                Button(action: onToggle) {
                    headerContent(showsDisclosure: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title)，\(group.conversations.count) 个会话，\(expanded ? "收起" : "展开")")
            } else {
                headerContent(showsDisclosure: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(group.title)，\(group.conversations.count) 个会话")
            }
            if let onCreate {
                Button(action: onCreate) { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundColor(Theme.brand).accessibilityLabel("新建空白终端")
            }
        }.padding(.vertical, 8)
    }

    private func headerContent(showsDisclosure: Bool) -> some View {
        HStack(spacing: 10) {
            avatar
            Text(group.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text("\(group.conversations.count)").font(.caption).foregroundColor(Theme.textMuted)
            Spacer(minLength: 2)
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
        }
        .foregroundColor(Theme.textPrimary)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var avatar: some View {
        if group.kind == .employee || group.kind == .team {
            ContactAvatar(
                id: group.employeeId ?? group.id,
                avatar: group.avatar ?? "",
                systemKey: group.employeeSystemKey,
                team: group.kind == .team,
                size: 28
            )
        } else if group.kind == .cli {
            BrandLogo(provider: group.conversations.first?.session.provider ?? "terminal", color: Theme.brand)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: group.kind == .team ? "person.3" : (group.kind == .employee ? "person.crop.circle" : "terminal"))
                .foregroundColor(Theme.brand).frame(width: 32, height: 32)
                .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
