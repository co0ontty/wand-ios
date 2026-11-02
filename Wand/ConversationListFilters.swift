import Foundation
import SwiftUI

struct HomeFeatureMenu: View {
    let onMode: (HomeListMode) -> Void
    let onSettings: () -> Void
    let onSwitchServer: () -> Void

    var body: some View {
        Menu {
            Section {
                Button("知识库", systemImage: "doc.text") { onMode(.knowledge) }
                Button("任务", systemImage: "square.grid.2x2") { onMode(.board) }
            }
            Section {
                Button("设置", systemImage: "gearshape", action: onSettings)
                Button("切换服务器", systemImage: "server.rack", action: onSwitchServer)
            }
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("功能菜单")
        .accessibilityIdentifier("home-feature-menu")
    }
}

/// Business stages come only from wand_tasks, never workspace_tasks.status or runner state.
enum ConversationTaskStage: String, CaseIterable {
    case all, backlog, todo, doing, review, ready, archived, none, unknown
    static var options: [Self] { allCases.filter { $0 != .unknown } }
    static func businessStatus(_ value: String?) -> Self {
        if value == "done" { return .review }
        guard let value, let stage = Self(rawValue: value), ![.all, .none, .unknown].contains(stage) else { return .unknown }
        return stage
    }
    static func resolve(boardStatus: String?, hasTaskContainer: Bool, workspaceTaskId: String?) -> Self {
        if hasTaskContainer { return businessStatus(boardStatus) }
        return workspaceTaskId == nil ? .none : .unknown
    }
    var title: String {
        switch self {
        case .all: return "全部状态"
        case .backlog: return "待立项"
        case .todo: return "等待认领"
        case .doing: return "执行中"
        case .review: return "待验收"
        case .ready: return "待归档"
        case .archived: return "已归档"
        case .none: return "未关联任务"
        case .unknown: return "任务状态未知"
        }
    }
}

enum ConversationWorkspaceFilter: Hashable {
    case all, unassigned, workspace(String), unknown
    static func resolve(id: String?, synthetic: Bool = false, global: Bool = false) -> Self {
        if synthetic || global || id == "wand-global" { return .unassigned }
        guard let id, !id.isEmpty else { return .unknown }
        return .workspace(id)
    }
}

/// `.current` is the baseline projection: archived sessions stay out of the list until the
/// user explicitly picks another scope, and only then count as an active filter.
enum ConversationArchiveScope: String, CaseIterable {
    case current, all, archived
    var title: String {
        switch self { case .current: return "未归档"; case .all: return "全部含已归档"; case .archived: return "已归档" }
    }
}

enum ConversationRuntime: String, CaseIterable {
    case confirmation, running, queued, idle, finished, failed
    static var options: [Self] { [.confirmation, .running, .queued, .idle, .finished, .failed] }
    var title: String {
        switch self {
        case .confirmation: return "需要我确认"
        case .running: return "运行中"
        case .queued: return "排队中"
        case .idle: return "空闲"
        case .finished: return "已结束"
        case .failed: return "运行失败"
        }
    }
    var symbol: String {
        switch self {
        case .confirmation: return "exclamationmark.bubble"
        case .running: return "waveform.path.ecg"
        case .queued: return "clock"
        case .idle: return "circle"
        case .finished: return "stop.circle"
        case .failed: return "xmark.circle"
        }
    }
    static func resolve(_ session: WorkspaceSessionSummary) -> Self {
        if session.activityStatus == "failed" { return .failed }
        guard session.archived != true else { return .idle }
        if ["permission", "permission-blocked", "waiting-input", "waiting_input"].contains(session.activityStatus) { return .confirmation }
        if session.activityStatus == "queued" { return .queued }
        if session.isJustCompleted || ["running", "thinking"].contains(session.activityStatus) { return .running }
        if ["exited", "stopped"].contains(session.activityStatus) { return .finished }
        return .idle
    }
    /// 归档行不参与“当前状态”筛选，只有运行失败与已结束能把它找回来（与 Web/macOS 同一口径）。
    static func resolveArchived(_ session: WorkspaceSessionSummary) -> Self? {
        if session.activityStatus == "failed" { return .failed }
        if ["exited", "stopped"].contains(session.activityStatus) { return .finished }
        return nil
    }
}

struct ConversationFilterFacts: Equatable {
    let stage: ConversationTaskStage
    let workspace: ConversationWorkspaceFilter
    let archived: Bool
    let active: Bool
    let searchText: String
    var runtime: ConversationRuntime? = .idle
    /// Server employee ID; "none" is the explicit unassigned value.
    var employee = "none"
}

struct ConversationListFilters: Equatable {
    var runtimes: Set<ConversationRuntime> = []
    var workspaces: Set<ConversationWorkspaceFilter> = []
    var employees: Set<String> = []
    var stage: ConversationTaskStage = .all
    var workspace: ConversationWorkspaceFilter = .all
    var archive: ConversationArchiveScope = .current
    var activeOnly = false
    var count: Int { (runtimes.isEmpty ? 0 : 1) + (workspaces.isEmpty ? 0 : 1) + (employees.isEmpty ? 0 : 1) + (stage == .all ? 0 : 1) + (workspace == .all ? 0 : 1) + (archive == .current ? 0 : 1) + (activeOnly ? 1 : 0) }
    var isDefault: Bool { count == 0 }

    /// All predicates run against one association; never combine different siblings' matches.
    func matches(_ facts: ConversationFilterFacts, query: String = "") -> Bool {
        (runtimes.isEmpty || (facts.runtime.map(runtimes.contains) ?? false))
            && (workspaces.isEmpty || workspaces.contains(facts.workspace))
            && (employees.isEmpty || employees.contains(facts.employee))
            && (stage == .all || stage == facts.stage)
            && (workspace == .all || workspace == facts.workspace)
            && (archive == .all || facts.archived == (archive == .archived))
            && (!activeOnly || facts.active)
            && query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { facts.searchText.localizedCaseInsensitiveContains(String($0)) }
    }
}

struct ConversationWorkspaceOption: Identifiable {
    let id: String
    let title: String
}

struct ConversationEmployeeOption: Identifiable {
    let id: String
    let title: String
}

enum ConversationFilterDimension {
    case runtime, workspace, employee
    var title: String {
        switch self { case .runtime: return "运行状态"; case .workspace: return "工作区"; case .employee: return "员工" }
    }
    var symbol: String {
        switch self { case .runtime: return "waveform.path.ecg"; case .workspace: return "folder"; case .employee: return "person" }
    }
    var identifier: String {
        switch self { case .runtime: return "conversation-runtime-expand"; case .workspace: return "conversation-workspace-expand"; case .employee: return "conversation-employee-expand" }
    }
}

/// The trigger stays mounted while its native popover owns multi-selection and dismissal.
struct ConversationFilterCapsule: View {
    let dimension: ConversationFilterDimension
    @Binding var filters: ConversationListFilters
    let workspaces: [ConversationWorkspaceOption]
    var employees: [ConversationEmployeeOption] = []
    let vertical: Bool
    var showsTitle = true
    var onAddWorkspace: (() -> Void)? = nil
    var onExpand: (() -> Void)? = nil
    var isExpanded = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var open = false
    @State private var query = ""
    // Presentation hints only; clearing a filter never silently reapplies these choices.
    @State private var lastRuntime = ConversationRuntime.running
    @State private var lastWorkspace: ConversationWorkspaceFilter?
    @State private var lastEmployee: String?
    @FocusState private var searchFocused: Bool

    private var selectedWorkspaces: Set<ConversationWorkspaceFilter> {
        filters.workspaces.isEmpty && filters.workspace != .all ? [filters.workspace] : filters.workspaces
    }
    private var selectedCount: Int {
        switch dimension {
        case .runtime: return filters.runtimes.count
        case .workspace: return selectedWorkspaces.count
        case .employee: return filters.employees.count
        }
    }
    private var selectionSummary: String {
        switch dimension {
        case .runtime:
            let values = ConversationRuntime.allCases.filter { filters.runtimes.contains($0) }
            return values.isEmpty ? "全部运行状态" : values.map(\.title).joined(separator: "、")
        case .employee:
            return filters.employees.isEmpty ? "全部员工" : filters.employees.map(employeeTitle).sorted().joined(separator: "、")
        case .workspace:
            return selectedWorkspaces.isEmpty ? "全部工作区" : selectedWorkspaces.map(title).sorted().joined(separator: "、")
        }
    }
    private struct CapsuleOption: Equatable {
        let title: String
        let symbol: String
        var monogram: String? = nil
    }
    private var currentOption: CapsuleOption {
        switch dimension {
        case .runtime:
            let value = ConversationRuntime.allCases.first { filters.runtimes.contains($0) } ?? lastRuntime
            return CapsuleOption(title: value.title, symbol: value.symbol)
        case .workspace:
            let ordered: [ConversationWorkspaceFilter] = [.unassigned] + workspaces.map { .workspace($0.id) }
            let remembered = lastWorkspace.flatMap { ordered.contains($0) ? $0 : nil }
            let value = ordered.first { selectedWorkspaces.contains($0) }
                ?? selectedWorkspaces.sorted { title($0) < title($1) }.first
                ?? remembered ?? workspaces.first.map { .workspace($0.id) } ?? .unassigned
            return CapsuleOption(title: title(value), symbol: dimension.symbol, monogram: value == .unassigned ? nil : initials(title(value)))
        case .employee:
            let ordered = ["none"] + employees.map(\.id)
            let remembered = lastEmployee.flatMap { ordered.contains($0) ? $0 : nil }
            let value = ordered.first { filters.employees.contains($0) } ?? filters.employees.sorted().first
                ?? remembered ?? employees.first?.id ?? "none"
            return CapsuleOption(title: employeeTitle(value), symbol: dimension.symbol, monogram: value == "none" ? nil : initials(employeeTitle(value)))
        }
    }
    private var allSymbol: String {
        switch dimension {
        case .runtime: return "square.3.layers.3d"
        case .workspace: return "square.stack"
        case .employee: return "person.2"
        }
    }
    private func employeeTitle(_ id: String) -> String {
        id == "none" ? "未分配员工" : employees.first { $0.id == id }?.title ?? "员工不可用"
    }
    private func initials(_ value: String) -> String {
        let words = value.components(separatedBy: CharacterSet(charactersIn: " _-/")).filter { !$0.isEmpty }
        return (words.count > 1 ? words.prefix(2).map { String($0.prefix(1)) }.joined() : String(value.prefix(2))).uppercased()
    }

    var body: some View {
        if vertical {
            capsule
        } else {
            capsule
                .popover(isPresented: $open, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    panel.presentationCompactAdaptation(.popover)
                }
                .onDisappear { open = false }
                .onChange(of: enabled) { _, value in if !value { open = false } }
                .onChange(of: open) { _, value in if !value { query = ""; searchFocused = false } }
                .onKeyPress(.escape) {
                    guard open else { return .ignored }
                    open = false
                    return .handled
                }
        }
    }

    private var capsule: some View {
        Button {
            if let onExpand { onExpand() }
            else { open.toggle() }
        } label: {
            VStack(spacing: 4) {
                if showsTitle {
                    Text(dimension.title).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                layout {
                    ZStack {
                        Image(systemName: allSymbol).opacity(isExpanded ? 0 : 1)
                        Image(systemName: "xmark").opacity(isExpanded ? 1 : 0)
                            .rotationEffect(.degrees(reducedMotion || isExpanded ? 0 : -90))
                    }
                        .font(.title3)
                        .frame(width: WandLayout.controlTouch, height: WandLayout.controlTouch)
                        .background(selectedCount == 0 ? Theme.brandSoft : Color.clear, in: Circle())
                    let option = currentOption
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: option.symbol)
                            .font(.title3)
                            .contentTransition(reducedMotion ? .identity : .symbolEffect(.replace))
                            .frame(width: 28, height: 28)
                        if let monogram = option.monogram {
                            Text(monogram)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 2)
                                .padding(.vertical, 0.5)
                                .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .stroke(Theme.border.opacity(0.65), lineWidth: 0.5)
                                )
                                .offset(x: 2, y: 2)
                        }
                    }
                    .frame(width: WandLayout.controlTouch, height: WandLayout.controlTouch)
                    .background(selectedCount > 0 ? Theme.brandSoft : Color.clear, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if selectedCount > 1 {
                            Text("\(selectedCount)")
                                .font(.system(size: 8.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 0.5)
                                .background(Theme.brand, in: Capsule())
                                .offset(x: 2, y: -2)
                        }
                    }
                    .animation(reducedMotion ? nil : WandMotion.stateSwap, value: option)
                    .animation(reducedMotion ? nil : WandMotion.stateSwap, value: selectedCount)
                }
                .padding(2)
                .wandGlassCapsule()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.brand)
        .contentShape(Rectangle())
        .fixedSize()
        .accessibilityLabel(dimension.title + "筛选")
        .accessibilityValue(selectedCount == 0 ? selectionSummary + "；常用选项：" + currentOption.title : selectionSummary)
        .accessibilityHint("点击展开选项，可多选")
        .accessibilityIdentifier(dimension.identifier)
    }

    private func clearDimension() {
        switch dimension {
        case .runtime: filters.runtimes = []; filters.activeOnly = false
        case .workspace: filters.workspaces = []; filters.workspace = .all
        case .employee: filters.employees = []
        }
        open = false
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dimension.title).font(.headline)
                Spacer()
                Button("完成") { open = false }.frame(minWidth: 44, minHeight: 44)
            }
            if dimension == .runtime {
                Text("可多选；运行中含刚完成未查看，已结束含进程退出与被停止；「全部」不含已归档会话")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                panelChoice("全部运行状态", selected: filters.runtimes.isEmpty, action: clearDimension)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(ConversationRuntime.options, id: \.self) { value in
                            panelChoice(value.title, symbol: value.symbol, selected: filters.runtimes.contains(value)) { toggle(value) }
                        }
                    }
                }.frame(maxHeight: 320)
            } else if dimension == .employee {
                HomeSearchField(placeholder: "搜索员工", text: $query, focused: $searchFocused)
                ScrollView {
                    VStack(spacing: 4) {
                        panelChoice("全部员工", selected: filters.employees.isEmpty, action: clearDimension)
                        panelChoice("未分配员工", symbol: "person", selected: filters.employees.contains("none")) { toggle("none") }
                        ForEach(employees.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { employee in
                            panelChoice(employee.title, symbol: "person", selected: filters.employees.contains(employee.id)) {
                                toggle(employee.id)
                            }
                        }
                    }
                }.frame(maxHeight: 320)
            } else {
                HomeSearchField(placeholder: "搜索工作区", text: $query, focused: $searchFocused)
                ScrollView {
                    VStack(spacing: 4) {
                        panelChoice("全部工作区", selected: selectedWorkspaces.isEmpty, action: clearDimension)
                        panelChoice("未分配工作区", symbol: "folder", selected: selectedWorkspaces.contains(.unassigned)) { toggle(.unassigned) }
                        ForEach(workspaces.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { workspace in
                            panelChoice(workspace.title, symbol: "folder", selected: selectedWorkspaces.contains(.workspace(workspace.id))) {
                                toggle(.workspace(workspace.id))
                            }
                        }
                        if let onAddWorkspace {
                            Button("添加工作区", systemImage: "plus") {
                                searchFocused = false
                                open = false
                                onAddWorkspace()
                            }
                        }
                    }
                }.frame(maxHeight: 320)
            }
        }
        .padding()
        .frame(width: 280)
        .background(Theme.surface)
    }

    private func panelChoice(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).frame(width: 22) }
                Text(title).lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "checkmark").opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: WandLayout.controlTouch, alignment: .leading)
            .foregroundStyle(selected ? Theme.brand : Theme.textPrimary)
            .background(selected ? Theme.brand.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ value: ConversationRuntime) {
        filters.activeOnly = false
        if !filters.runtimes.insert(value).inserted { filters.runtimes.remove(value) }
        else { lastRuntime = value }
    }
    private func toggle(_ value: ConversationWorkspaceFilter) {
        filters.workspace = .all
        if !filters.workspaces.insert(value).inserted { filters.workspaces.remove(value) }
        else { lastWorkspace = value }
    }
    private func toggle(_ value: String) {
        if !filters.employees.insert(value).inserted { filters.employees.remove(value) }
        else { lastEmployee = value }
    }
    private func title(_ value: ConversationWorkspaceFilter) -> String {
        switch value {
        case .workspace(let id): return workspaces.first { $0.id == id }?.title ?? "工作区不可用"
        case .unassigned: return "未分配工作区"
        case .all: return "全部工作区"
        case .unknown: return "工作区未知"
        }
    }
}

/// The whole rail has one native slot, so expanding never creates an overflow menu.
struct ConversationHomeToolbar: ViewModifier {
    @ObservedObject var store: ConversationStore
    let groups: [TaskDirectoryGroup]
    let enabled: Bool
    let showsFilters: Bool
    let showsListActions: Bool
    let onCreate: () -> Void
    let onSettings: () -> Void
    let onSwitchServer: () -> Void
    let onMode: (HomeListMode) -> Void
    var inDetailColumn = false
    var showsCreate = true
    var showsReturnToSessions = false
    private enum RailSlot: Int, CaseIterable { case create, more, runtime, workspace, employee }
    @State private var expanded: RailSlot?
    @State private var railTop: CGFloat = 0
    @State private var contentBottom: CGFloat = 0
    @State private var labelActions: [String: (frame: CGRect, action: () -> Void)] = [:]
    @State private var addingWorkspace = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.isEnabled) private var controlsEnabled
    @Environment(\.systemHomeToolbarInDetail) private var toolbarInDetail
    @Environment(\.systemHomeVerticalBarVisible) private var verticalBarVisible
    @Environment(\.usesSystemHomeNavigation) private var usesSystemNavigation
    @Environment(\.systemHomeSidebarToggle) private var sidebarToggle
    @Environment(\.systemHomeSidebarCollapsed) private var sidebarCollapsed

    private var workspaces: [ConversationWorkspaceOption] {
        var seen = Set<String>()
        return groups.filter { $0.isBindableProject && seen.insert($0.workspaceId).inserted }
            .map { ConversationWorkspaceOption(id: $0.workspaceId, title: $0.workspaceName) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var employees: [ConversationEmployeeOption] {
        var seen = Set<String>()
        return HomePresentation.conversations(groups, includeArchived: true).compactMap { item -> ConversationEmployeeOption? in
            guard let id = item.session.employeeId, seen.insert(id).inserted else { return nil }
            let name = (item.session.employeeName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversationEmployeeOption(id: id, title: name.isEmpty ? store.employees.first { $0.id == id }?.name ?? "员工" : name)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var slots: [RailSlot] {
        (showsListActions ? (showsCreate ? [.create, .more] : [.more]) : []) +
            (showsFilters ? [.runtime, .workspace, .employee] : [])
    }
    private let railSpacing: CGFloat = 12
    private func controlHeight(_ slot: RailSlot) -> CGFloat {
        slot == .create || slot == .more ? WandLayout.controlTouch : WandLayout.controlTouch * 2 + 4
    }
    private var railHeight: CGFloat {
        // Reserve one option row even below the last capsule, within the native slot.
        let naturalHeight = slots.reduce(WandLayout.controlTouch) { $0 + controlHeight($1) + railSpacing }
        return contentBottom > railTop && railTop > 0
            ? min(naturalHeight, max(WandLayout.controlTouch, contentBottom - railTop))
            : naturalHeight
    }
    private var expansionHeight: CGFloat {
        guard let expanded else { return 0 }
        return max(0, railHeight - controlHeight(expanded) - railSpacing)
    }
    private var selectedWorkspaces: Set<ConversationWorkspaceFilter> {
        store.listFilters.workspaces.isEmpty && store.listFilters.workspace != .all
            ? [store.listFilters.workspace] : store.listFilters.workspaces
    }
    private func expand(_ slot: RailSlot?) {
        withAnimation(reducedMotion ? nil : WandMotion.expansion) { expanded = expanded == slot ? nil : slot }
    }
    private func perform(_ action: () -> Void) {
        expand(nil)
        action()
    }

    func body(content: Content) -> some View {
        toolbarContent(content)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                if abs(contentBottom - bottom) > 1 { contentBottom = bottom }
            }
            .overlay {
                if expanded != nil {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .global) { point in
                            // Labels extend into the content area; retain the row's own action there.
                            if point.y >= railTop + railHeight - expansionHeight,
                               point.y < railTop + railHeight,
                               let hit = labelActions.values.first(where: { $0.frame.contains(point) }) {
                                hit.action()
                            } else { expand(nil) }
                        }
                }
            }
            .sheet(isPresented: $addingWorkspace) {
                WorkspaceAddDialog(api: store.api) { workspace in
                    store.listFilters.workspace = .all
                    store.listFilters.workspaces = [.workspace(workspace.id)]
                    addingWorkspace = false
                }
            }
            .onDisappear { expanded = nil; labelActions = [:] }
            .onChange(of: enabled && controlsEnabled) { _, value in if !value { expanded = nil } }
            .onChange(of: verticalBarVisible) { _, _ in expanded = nil; railTop = 0 }
            .onChange(of: showsFilters) { _, _ in expanded = nil }
            .onChange(of: showsListActions) { _, _ in expanded = nil }
            .onKeyPress(.escape) {
                guard expanded != nil else { return .ignored }
                expand(nil)
                return .handled
            }
    }

    private var verticalRail: some View {
        VStack(spacing: 0) {
            if let expanded {
                // Render only the active slot: hidden fixed-size capsules must not
                // participate in the native toolbar's vertical layout.
                railControl(expanded)
                    .frame(height: controlHeight(expanded))
                ScrollView(.vertical) {
                    VStack(spacing: 8) { railChoices }
                }
                .id(expanded)
                .scrollBounceBehavior(.basedOnSize)
                .scrollClipDisabled()
                .frame(height: expansionHeight)
                .clipShape(ConversationRailScrollClip())
                .padding(.top, railSpacing)
                .accessibilityIdentifier("home-rail-options")
                .transition(reducedMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            } else {
                ForEach(slots, id: \.self) { slot in
                    railControl(slot)
                        .frame(height: controlHeight(slot))
                        .padding(.bottom, railSpacing)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 48, height: railHeight, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
            if abs(railTop - top) > 1 { railTop = top }
        }
        .foregroundStyle(Theme.brand)
    }

    @ViewBuilder private func railControl(_ slot: RailSlot) -> some View {
        switch slot {
        case .create:
            Button(action: onCreate) {
                Image(systemName: "plus").font(.title3).frame(width: 44, height: 44).wandGlassCapsule()
            }.buttonStyle(.plain).accessibilityLabel("新建会话").accessibilityIdentifier("unified-new-session")
        case .more:
            Button { expand(.more) } label: {
                ZStack {
                    Image(systemName: "ellipsis").opacity(expanded == .more ? 0 : 1)
                    Image(systemName: "xmark").opacity(expanded == .more ? 1 : 0)
                        .rotationEffect(.degrees(reducedMotion || expanded == .more ? 0 : -90))
                }.font(.title3).frame(width: 44, height: 44).wandGlassCapsule()
            }.buttonStyle(.plain).accessibilityLabel(expanded == .more ? "收起功能菜单" : "更多")
                .accessibilityIdentifier("home-sidebar-actions")
        case .runtime, .workspace, .employee:
            ConversationFilterCapsule(dimension: slot == .runtime ? .runtime : slot == .workspace ? .workspace : .employee,
                filters: $store.listFilters, workspaces: workspaces, employees: employees, vertical: true, showsTitle: false,
                onAddWorkspace: { addingWorkspace = true }, onExpand: { expand(slot) }, isExpanded: expanded == slot)
        }
    }

    @ViewBuilder private var railChoices: some View {
        switch expanded {
        case .more:
            if sidebarCollapsed, let sidebarToggle { railAction("显示会话列表", symbol: "sidebar.left") { perform(sidebarToggle) } }
            if showsReturnToSessions { railAction("返回工作区", symbol: "arrow.left") { perform { onMode(.sessions) } } }
            railAction("知识库", symbol: "doc.text") { perform { onMode(.knowledge) } }
            railAction("任务", symbol: "square.grid.2x2") { perform { onMode(.board) } }
            railAction("设置", symbol: "gearshape") { perform(onSettings) }
            railAction("切换服务器", symbol: "server.rack") { perform(onSwitchServer) }
        case .runtime:
            railAction("全部运行状态", symbol: "square.3.layers.3d", selected: store.listFilters.runtimes.isEmpty) {
                perform { store.listFilters.runtimes = []; store.listFilters.activeOnly = false }
            }
            ForEach(ConversationRuntime.options, id: \.self) { value in
                railAction(value.title, symbol: value.symbol, selected: store.listFilters.runtimes.contains(value)) {
                    store.listFilters.activeOnly = false
                    if !store.listFilters.runtimes.insert(value).inserted { store.listFilters.runtimes.remove(value) }
                }
            }
        case .workspace:
            railAction("全部工作区", symbol: "square.stack", selected: selectedWorkspaces.isEmpty) {
                perform { store.listFilters.workspaces = []; store.listFilters.workspace = .all }
            }
            railAction("未分配工作区", symbol: "folder", selected: selectedWorkspaces.contains(.unassigned)) { toggleWorkspace(.unassigned) }
            ForEach(workspaces) { workspace in
                railAction(workspace.title, symbol: "folder", identifier: workspace.id, monogram: String(workspace.title.prefix(2)).uppercased(),
                    selected: selectedWorkspaces.contains(.workspace(workspace.id))) { toggleWorkspace(.workspace(workspace.id)) }
            }
            railAction("添加工作区", symbol: "plus") { perform { addingWorkspace = true } }
        case .employee:
            railAction("全部员工", symbol: "person.2", selected: store.listFilters.employees.isEmpty) {
                perform { store.listFilters.employees = [] }
            }
            railAction("未分配员工", symbol: "person", selected: store.listFilters.employees.contains("none")) { toggleEmployee("none") }
            ForEach(employees) { employee in
                railAction(employee.title, symbol: "person", identifier: employee.id, monogram: String(employee.title.prefix(2)).uppercased(),
                    selected: store.listFilters.employees.contains(employee.id)) { toggleEmployee(employee.id) }
            }
        case .create, nil: EmptyView()
        }
    }
    private func toggleWorkspace(_ value: ConversationWorkspaceFilter) {
        var values = selectedWorkspaces
        if !values.insert(value).inserted { values.remove(value) }
        store.listFilters.workspace = .all
        store.listFilters.workspaces = values
    }
    private func toggleEmployee(_ id: String) {
        if !store.listFilters.employees.insert(id).inserted { store.listFilters.employees.remove(id) }
    }
    private func railAction(_ title: String, symbol: String, identifier: String? = nil, monogram: String? = nil, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).padding(.horizontal, 12).frame(minHeight: 36)
                    .wandGlassCapsule(tint: selected ? Theme.brandSoft : nil)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        labelActions[identifier ?? title] = (frame, action)
                    }
                    .onDisappear { labelActions.removeValue(forKey: identifier ?? title) }
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: symbol).font(.title3).frame(width: 44, height: 44)
                    if let monogram { Text(monogram).font(.caption2).padding(2).background(Theme.surfaceSoft, in: Capsule()) }
                    if selected { Image(systemName: "checkmark.circle.fill").font(.caption).background(Theme.surface, in: Circle()) }
                }
                .foregroundStyle(Theme.brand)
                .wandGlassCapsule(tint: selected ? Theme.brandSoft : nil)
            }
            .fixedSize()
            .contentShape(Rectangle())
            .frame(width: 44, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "已选中" : "未选中")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
    }

    @ViewBuilder private func toolbarContent(_ content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *), enabled && usesSystemNavigation, inDetailColumn == toolbarInDetail {
            content.toolbar(.visible, for: .navigationBar).toolbar {
                if verticalBarVisible {
                    ToolbarItem(placement: .primaryAction) { verticalRail }
                        .axisBehavior(.verticalPreferred)
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    if showsListActions {
                        if showsCreate {
                            ToolbarItem(placement: .primaryAction) {
                                Button("新建会话", systemImage: "plus", action: onCreate).accessibilityIdentifier("unified-new-session")
                            }
                        }
                        ToolbarOverflowMenu {
                            if sidebarCollapsed, let sidebarToggle { Button("显示会话列表", systemImage: "sidebar.left", action: sidebarToggle) }
                            if showsReturnToSessions { Button("返回工作区", systemImage: "chevron.left") { onMode(.sessions) } }
                            Section {
                                Button("知识库", systemImage: "doc.text") { onMode(.knowledge) }
                                Button("任务", systemImage: "square.grid.2x2") { onMode(.board) }
                            }
                            Section {
                                Button("设置", systemImage: "gearshape", action: onSettings)
                                Button("切换服务器", systemImage: "server.rack", action: onSwitchServer)
                            }
                        }
                    }
                    if showsFilters {
                        ToolbarItem(placement: .bottomBar) {
                            ConversationFilterCapsule(dimension: .runtime, filters: $store.listFilters, workspaces: workspaces, vertical: false)
                        }.sharedBackgroundVisibility(.hidden)
                        ToolbarItem(placement: .bottomBar) {
                            ConversationFilterCapsule(dimension: .workspace, filters: $store.listFilters, workspaces: workspaces, vertical: false,
                                onAddWorkspace: { addingWorkspace = true })
                        }.sharedBackgroundVisibility(.hidden)
                        ToolbarItem(placement: .bottomBar) {
                            ConversationFilterCapsule(dimension: .employee, filters: $store.listFilters, workspaces: workspaces, employees: employees, vertical: false)
                        }.sharedBackgroundVisibility(.hidden)
                    }
                }
            }
        } else { content }
        #else
        content
        #endif
    }
}

/// Clip vertical scrolling while keeping labels beside the native icon column visible.
private struct ConversationRailScrollClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - rect.width * 8, y: rect.minY, width: rect.width * 9, height: rect.height))
    }
}

/// One session row and two independent OR filters; selecting never changes execution or read state.
struct UnifiedConversationSidebar: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var workspaceStore: WorkspaceStore
    let groups: [TaskDirectoryGroup]
    let selectedSessionID: String?
    let selectedConversationID: String?
    let loading: Bool
    let error: String?
    let onOpenSession: (String) -> Void
    let onCreate: (String?) -> Void
    let onReload: () -> Void
    let showsFilters: Bool
    let onMode: (HomeListMode) -> Void
    let onSettings: () -> Void
    let onSwitchServer: () -> Void
    let onSessionDeleted: (String) -> Void
    let onModalVisibilityChanged: (Bool) -> Void
    let onMutationBusyChanged: (Bool) -> Void
    @Environment(\.usesSystemHomeNavigation) private var usesSystemNavigation
    @Environment(\.systemHomeVerticalBarVisible) private var verticalBarVisible
    @Environment(\.systemHomeToolbarInDetail) private var toolbarInDetail
    @Environment(\.systemHomeSidebarToggle) private var sidebarToggle
    @Environment(\.systemHomeSidebarCollapsed) private var sidebarCollapsed
    @State private var query = ""
    @State private var revealedRowID: String?
    @State private var moveSessionTarget: WorkspaceSessionSummary?
    @State private var deleteSessionTarget: WorkspaceSessionSummary?
    @State private var deletionBusy = false
    @State private var deletionError: String?
    @State private var addingWorkspace = false
    @FocusState private var searchFocused: Bool
    private var workspaceOptions: [ConversationWorkspaceOption] {
        var seen = Set<String>()
        return groups.filter { $0.isBindableProject && seen.insert($0.workspaceId).inserted }
            .map { ConversationWorkspaceOption(id: $0.workspaceId, title: $0.workspaceName) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var employeeOptions: [ConversationEmployeeOption] {
        var seen = Set<String>()
        return HomePresentation.conversations(groups, includeArchived: true).compactMap { item -> ConversationEmployeeOption? in
            guard let id = item.session.employeeId, seen.insert(id).inserted else { return nil }
            let name = (item.session.employeeName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversationEmployeeOption(id: id, title: name.isEmpty ? store.employees.first { $0.id == id }?.name ?? "员工" : name)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func currentOutside(entries: [HomeRecentConversation], rows: [HomeRecentConversation], history: [ConversationInstance]) -> Bool {
        if let id = selectedSessionID { return entries.contains { $0.id == id } && !rows.contains { $0.id == id } }
        if let id = selectedConversationID, let item = store.items.first(where: { $0.id == id }) {
            let sessionID = item.communicationSessionId ?? item.sessionId
            return !rows.contains { $0.id == sessionID } && !history.contains { $0.id == id }
        }
        return false
    }
    /// The session behind the current selection; the locate action needs it to widen the archive scope.
    private var locatedSessionID: String? {
        if let selectedSessionID { return selectedSessionID }
        guard let selectedConversationID, let item = store.items.first(where: { $0.id == selectedConversationID }) else { return nil }
        return item.communicationSessionId ?? item.sessionId
    }
    var body: some View {
        // Build one projection per update; search and scroll never repeatedly sort the same sessions.
        let entries = HomePresentation.conversations(groups, includeArchived: true)
        let rows = entries.filter { store.listFilters.matches($0.filterFacts(employees: store.employees), query: query) }
        let attention = rows.filter { [.confirmation, .failed].contains(ConversationRuntime.resolve($0.session)) }
        let other = rows.filter { ![.confirmation, .failed].contains(ConversationRuntime.resolve($0.session)) }
        let history: [ConversationInstance] = []
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                HomeSearchField(placeholder: "搜索会话", text: $query, focused: $searchFocused)
                if !usesSystemNavigation {
                    Button {
                        let selected = store.listFilters.workspaces
                        if selected.count == 1, case .workspace(let id) = selected.first! { onCreate(id) }
                        else { onCreate(nil) }
                    } label: { Image(systemName: "plus").font(.title3) }
                        .buttonStyle(WandQuietButtonStyle())
                        .accessibilityLabel("新建会话")
                        .accessibilityIdentifier("unified-new-session")
                }
                if !usesSystemNavigation {
                    HomeFeatureMenu(onMode: onMode, onSettings: onSettings, onSwitchServer: onSwitchServer)
                }
                // 双栏容器提供收起能力；不要依赖系统工具栏是否启用。
                if let sidebarToggle {
                    Button(action: sidebarToggle) {
                        Image(systemName: "sidebar.left").font(.title3)
                    }
                    .buttonStyle(WandQuietButtonStyle())
                    .accessibilityLabel("收起侧栏")
                    .accessibilityIdentifier("unified-collapse-sidebar")
                }
            }
            if !store.listFilters.isDefault {
                HStack {
                    Text([runtimeSummary, workspaceSummary, employeeSummary, archiveSummary].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("清除") { store.listFilters = ConversationListFilters() }.frame(minWidth: 44, minHeight: 44)
                }
            }
            if currentOutside(entries: entries, rows: rows, history: history) {
                HStack {
                    Text("当前会话不在筛选结果中").font(.caption)
                    Button("定位当前会话") {
                        // An archived row stays out of the default scope, so locating it widens to 全部含已归档.
                        var revealed = ConversationListFilters()
                        if entries.contains(where: { $0.id == locatedSessionID && $0.filterArchived }) { revealed.archive = .all }
                        store.listFilters = revealed
                        query = ""
                    }.frame(minHeight: 44)
                }
            }
            List {
                if (loading || store.loading) && entries.isEmpty && store.items.isEmpty {
                    ProgressView("正在读取会话…")
                }
                if let message = error ?? store.error {
                    Text(message).foregroundStyle(Theme.danger)
                    Button("重新读取", action: onReload)
                }
                if let deletionError {
                    Text("删除会话失败：" + deletionError).font(.caption).foregroundStyle(Theme.danger)
                }
                if !attention.isEmpty { Section("我需要关注") { ForEach(attention) { sessionRow($0) } } }
                Section { ForEach(other) { sessionRow($0) } }
                if rows.isEmpty && history.isEmpty && !loading && !store.loading {
                    // The default projection omits archived rows, so "no sessions yet" would be false here.
                    Text(store.listFilters.isDefault && query.isEmpty
                        ? (entries.isEmpty ? "还没有会话" : "没有未归档的会话")
                        : "没有匹配的会话").foregroundStyle(Theme.textSecondary)
                    if !query.isEmpty || !store.listFilters.isDefault {
                        Button("清除筛选与搜索") { store.listFilters = ConversationListFilters(); query = "" }
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                .homeSwipeDismissal($revealedRowID)
                .onChange(of: query) { _, _ in revealedRowID = nil }
                .onChange(of: store.listFilters) { _, _ in revealedRowID = nil }
                .onChange(of: selectedSessionID) { _, _ in revealedRowID = nil }
                .onChange(of: showsFilters) { _, _ in revealedRowID = nil }
                .overlay(alignment: .top) {
                    if (loading || store.loading) && (!entries.isEmpty || !store.items.isEmpty) {
                        ProgressView().progressViewStyle(.linear).allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("unified-conversation-sidebar")
        }
        .padding(.leading, WandLayout.pageInset)
        .padding(.trailing, verticalBarVisible ? 48 : WandLayout.pageInset)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !usesSystemNavigation && showsFilters && !searchFocused {
                    HStack(spacing: 6) {
                        ConversationFilterCapsule(dimension: .runtime, filters: $store.listFilters,
                            workspaces: workspaceOptions, vertical: false, showsTitle: true)
                        ConversationFilterCapsule(dimension: .workspace, filters: $store.listFilters,
                            workspaces: workspaceOptions, vertical: false, showsTitle: true,
                            onAddWorkspace: { addingWorkspace = true })
                        ConversationFilterCapsule(dimension: .employee, filters: $store.listFilters,
                            workspaces: workspaceOptions, employees: employeeOptions, vertical: false, showsTitle: true)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Theme.workspaceCanvas)
                }
            }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar(usesSystemNavigation ? .visible : .hidden, for: .navigationBar)
            .toolbar(removing: usesSystemNavigation && toolbarInDetail ? .sidebarToggle : nil)
            .sheet(isPresented: $addingWorkspace) {
                WorkspaceAddDialog(api: store.api) { workspace in
                    store.listFilters.workspace = .all
                    store.listFilters.workspaces = [.workspace(workspace.id)]
                    addingWorkspace = false
                }
            }
            .sheet(item: $moveSessionTarget) { session in
                SessionMoveSheet(store: workspaceStore, sessionId: session.id,
                    sessionTitle: session.title ?? "会话")
                    .presentationDetents([.medium, .large])
            }
            .alert("删除会话？", isPresented: Binding(
                get: { deleteSessionTarget != nil },
                set: { if !$0 { deleteSessionTarget = nil } }
            )) {
                Button("取消", role: .cancel) { deleteSessionTarget = nil }
                Button("删除", role: .destructive) {
                    // Capture before the native alert clears its presentation binding.
                    if let session = deleteSessionTarget { deleteSession(session) }
                }.disabled(deletionBusy)
            } message: {
                Text("会话「\(deleteSessionTarget?.title ?? "会话")」会结束并被删除，此操作无法撤销。")
            }
            .onChange(of: addingWorkspace || moveSessionTarget != nil || deleteSessionTarget != nil) { _, visible in
                onModalVisibilityChanged(visible)
            }
            .onDisappear { revealedRowID = nil; onModalVisibilityChanged(false) }
    }

    private func deleteSession(_ session: WorkspaceSessionSummary) {
        guard !deletionBusy else { return }
        deletionBusy = true
        deletionError = nil
        onMutationBusyChanged(true)
        Task {
            defer { deletionBusy = false; onMutationBusyChanged(false) }
            do {
                try await workspaceStore.deleteSessions([session.id])
                onSessionDeleted(session.id)
            } catch { deletionError = error.localizedDescription }
        }
    }

    private func openSession(_ id: String) {
        revealedRowID = nil
        searchFocused = false
        onOpenSession(id)
    }

    private func sessionActions(_ session: WorkspaceSessionSummary) -> [HomeRowAction] {
        [
            HomeRowAction(id: "open", title: "打开", symbol: "bubble.left") { openSession(session.id) },
            HomeRowAction(id: "move", title: "移动", symbol: "folder", tint: Theme.info) {
                searchFocused = false
                moveSessionTarget = session
            },
            HomeRowAction(id: "delete", title: "删除", symbol: "trash", tint: Theme.danger) {
                searchFocused = false
                deleteSessionTarget = session
            }
        ]
    }

    private var runtimeSummary: String {
        let values = ConversationRuntime.options.filter { store.listFilters.runtimes.contains($0) }
        return values.isEmpty ? "全部运行状态" : values.map(\.title).joined(separator: "、")
    }
    private var workspaceSummary: String {
        let values = store.listFilters.workspaces.map(workspaceTitle).sorted()
        return values.isEmpty ? "全部工作区" : values.joined(separator: "、")
    }
    /// Archived rows leave the default projection, so a widened scope has to stay readable here.
    private var archiveSummary: String {
        store.listFilters.archive == .current ? "" : "归档：" + store.listFilters.archive.title
    }
    private var employeeSummary: String {
        let values = store.listFilters.employees.sorted().map { id in id == "none" ? "未分配员工" : employeeOptions.first { $0.id == id }?.title ?? "员工不可用" }
        return values.isEmpty ? "" : "员工：" + values.joined(separator: "、")
    }
    private func workspaceTitle(_ value: ConversationWorkspaceFilter) -> String {
        switch value {
        case .workspace(let id): return workspaceOptions.first { $0.id == id }?.title ?? "工作区不可用"
        case .unassigned: return "未分配工作区"
        case .all: return "全部工作区"
        case .unknown: return "工作区未知"
        }
    }
    private func sessionSubhead(_ item: HomeRecentConversation) -> String {
        var parts: [String] = []
        let provider = item.session.providerLabel
        if !provider.isEmpty { parts.append(provider) }
        if let employee = item.session.employeeName, !employee.isEmpty { parts.append(employee) }
        let workspace = item.filterWorkspaceTitle
        if !workspace.isEmpty { parts.append(workspace) }
        return parts.joined(separator: " · ")
    }

    private func sessionRow(_ item: HomeRecentConversation) -> some View {
        Button {
            openSession(item.id)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.session.title ?? item.task?.name ?? "会话")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        BrandLogo(provider: item.session.provider)
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                        Text(sessionSubhead(item))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SessionStatusGlyph(session: item.session, size: 16)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selectedSessionID == item.id || store.items.contains { $0.id == selectedConversationID && ($0.communicationSessionId ?? $0.sessionId) == item.id } ? .isSelected : [])
            .homeSwipeActions(id: "session-" + item.id, revealedID: $revealedRowID,
                actions: sessionActions(item.session), enabled: !deletionBusy, surface: Theme.workspaceCanvas)
            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("conversation-session-" + item.id)
    }
}

/// A static tool identity is easier to scan than an animated employee avatar in a session directory.
struct SessionToolMark: View {
    let provider: String?
    var body: some View {
        Group {
            if let provider, !provider.isEmpty, !["shell", "terminal"].contains(provider), WandProvider.normalizedID(provider) == nil {
                Image(systemName: "questionmark.square").resizable().scaledToFit().foregroundStyle(Theme.textSecondary)
            } else {
                BrandLogo(provider: provider, color: Theme.textSecondary)
            }
        }
        .frame(width: 24, height: 24)
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}
