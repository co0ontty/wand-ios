import SwiftUI
import UIKit

struct ContactMorphButton: View {
    let expanded: Bool
    let symbol: String
    let label: String
    var disabled = false
    var title: String? = nil
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
            ZStack {
                Image(systemName: symbol).opacity(expanded ? 0 : 1).rotationEffect(.degrees(reduced || !expanded ? 0 : -45))
                Image(systemName: "xmark").opacity(expanded ? 1 : 0).rotationEffect(.degrees(reduced || expanded ? 0 : 45))
            }
            .font(.system(size: 17, weight: .semibold))
            .frame(width: title == nil ? 24 : 20, height: 24).contentShape(Rectangle())
            if let title { Text(title).font(.subheadline.weight(.medium)) }
            }.frame(minHeight: 28)
            .animation(reduced ? nil : WandMotion.stateSwap, value: expanded)
        }.buttonStyle(.glass).buttonBorderShape(title == nil ? .circle : .capsule)
            .disabled(disabled).accessibilityLabel(label)
    }
}

/// The complete conversation target excludes only the independent profile avatar.
struct ContactConversationLabel: View {
    let name: String
    let subtitle: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                ProgressView().opacity(busy ? 1 : 0)
                Image(systemName: "chevron.right").font(.caption)
                    .foregroundStyle(Theme.textSecondary).opacity(busy ? 0 : 1)
            }.frame(width: 24, height: 24).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ContactsView: View {
    let api: WandAPI
    @ObservedObject var store: ContactsStore
    let onBack: () -> Void
    let onOpenSession: (SessionSnapshot) -> Void
    let onOpenRun: (String) -> Void
    var onNewConversation: ((String) -> Void)? = nil
    var onOpenConversation: ((String) -> Void)? = nil
    var onTeamConversation: ((String) -> Void)? = nil
    var embedded = false
    var serverDisplayName: String? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onSwitchServer: (() -> Void)? = nil
    @State private var revealedRowID: String?
    @State private var query = ""
    @State private var createChooser = false
    @State private var dispatching = false
    @State private var createKind: String?
    @State private var createTemplate = ContactTeamTemplate.blank
    @State private var expandedID: String?
    @State private var pendingPanelChange: (() -> Void)?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.usesSystemHomeNavigation) private var usesSystemNavigation
    private var creationOpen: Bool { createChooser || createKind != nil }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if dispatching {
                        TeamDispatchPanel(api: api, projects: store.workspaces, onClose: { dispatching = false }, onOpenRun: onOpenRun)
                            .padding(.vertical, 10)
                    }
                    if createChooser {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("创建员工", systemImage: "person.badge.plus") {
                                createChooser = false; createKind = "employee"
                            }.buttonStyle(WandQuietButtonStyle()).accessibilityIdentifier("contact-create-employee")
                            ForEach(ContactTeamTemplate.allCases) { template in
                                Button {
                                    createTemplate = template; createChooser = false; createKind = "team"
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(template.name).font(.subheadline.weight(.semibold))
                                        Text(template.summary).font(.caption).foregroundStyle(Theme.textSecondary)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(WandQuietButtonStyle())
                                    .accessibilityIdentifier("contact-create-team-" + template.id)
                            }
                        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let kind = createKind {
                        let key = "new:" + kind
                        if store.unconfirmedActions.contains(key) {
                            uncertainty(key)
                        } else if kind == "employee" {
                            EmployeeProfilePanel(id: nil, api: api, directory: store) { closePanels() }
                                .id("new-employee")
                        } else {
                            ContactTeamProfilePanel(id: nil, api: api, directory: store, template: createTemplate, onClose: closePanels, onOpenRun: onOpenRun)
                                .id("new-team-" + createTemplate.id)
                        }
                    }
                    if let error = store.error {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(Theme.danger)
                            Spacer(); Button("重试") { store.refreshIfVisible() }
                        }
                    }
                    if store.loading && store.employees.isEmpty && store.teams.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(20)
                    }
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("\(store.teams(matching: query).count + store.employees(matching: query).count)位联系人")
                            .font(.caption).foregroundStyle(Theme.textSecondary).padding(.vertical, 10)
                    }
                    if query.isEmpty || !store.teams(matching: query).isEmpty {
                        Text("AI 团队 · \(store.teams(matching: query).count)").font(.headline).padding(.vertical, 12)
                        ForEach(store.teams(matching: query)) { team in teamRow(team) }
                        if query.isEmpty && store.teams.isEmpty && !store.loading && store.error == nil {
                            Text("还没有团队，点击加号创建。")
                                .font(.caption).foregroundStyle(Theme.textSecondary).padding(.vertical, 12)
                        }
                    }
                    if query.isEmpty || !store.employees(matching: query).isEmpty {
                        Text("硅基员工 · \(store.employees(matching: query).count)").font(.headline).padding(.top, 24).padding(.bottom, 12)
                        ForEach(store.employees(matching: query)) { employee in employeeRow(employee) }
                    }
                    if !store.loading && store.employees(matching: query).isEmpty && store.teams(matching: query).isEmpty {
                        Text(query.isEmpty ? "还没有联系人，点击右上角加号创建。" : "没有匹配的联系人。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary).padding(.vertical, 20)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
                .padding(16)
                .animation(reduced ? nil : WandMotion.stateSwap, value: expandedID)
                .animation(reduced ? nil : WandMotion.stateSwap, value: createKind)
                .animation(reduced ? nil : WandMotion.stateSwap, value: createChooser)
            }
            .homeSwipeDismissal($revealedRowID)
            .onChange(of: query) { _, _ in revealedRowID = nil }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                if !store.busy && !store.editorDirty { clearPanels(); await store.refresh() }
            }
        }
        .background(Theme.background)
        .navigationTitle(usesSystemNavigation ? "通讯录" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(usesSystemNavigation ? .visible : .hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(store.busy || store.editorDirty || (!embedded && !usesSystemNavigation))
        .toolbar {
            if usesSystemNavigation {
                if !embedded && (store.busy || store.editorDirty) {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回", systemImage: "chevron.left") { requestPanelChange(onBack) }
                            .disabled(store.busy)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(creationOpen ? "关闭创建面板" : "创建联系人",
                           systemImage: creationOpen ? "xmark" : "plus", action: toggleCreation)
                        .disabled(store.busy)
                }
                if #available(iOS 27.1, *) {
                    ToolbarOverflowMenu {
                        if let serverDisplayName {
                            Section(serverDisplayName) { headerMenuItems.disabled(store.busy) }
                        } else {
                            headerMenuItems.disabled(store.busy)
                        }
                    }
                }
            }
        }
        .task { store.activate(); await store.refresh() }
        .onDisappear { store.close() }
        .confirmationDialog("放弃未保存的资料修改？", isPresented: Binding(
            get: { pendingPanelChange != nil }, set: { if !$0 { pendingPanelChange = nil } }
        ), titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                let action = pendingPanelChange; pendingPanelChange = nil; store.editorDirty = false; action?()
            }
            Button("继续编辑", role: .cancel) { pendingPanelChange = nil }
        }
        .wandKeyboardShortcuts([
            WandKeyboardShortcutAction(id: "contacts-close", title: "收起通讯录面板", key: .escape,
                                       modifiers: [], isEnabled: !store.busy) {
                if creationOpen || expandedID != nil || dispatching { closePanels() }
                else if !query.isEmpty || searchFocused { closeSearch() }
                else { requestPanelChange(onBack) }
            }
        ])
    }
    private var header: some View {
        VStack(spacing: 4) {
            if !usesSystemNavigation {
                HStack(spacing: 6) {
                    if !embedded {
                        Button { requestPanelChange(onBack) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .disabled(store.busy).accessibilityLabel("返回通讯录上级")
                    }
                    Button {
                        if let onSwitchServer { requestPanelChange(onSwitchServer) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("通讯录").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                            if let serverDisplayName {
                                Text(serverDisplayName).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: WandLayout.controlTouch, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(onSwitchServer == nil || store.busy)
                    .accessibilityLabel(serverDisplayName.map { "切换服务器：" + $0 } ?? "通讯录")
                    ContactMorphButton(expanded: creationOpen, symbol: "plus", label: creationOpen ? "关闭创建面板" : "创建联系人",
                        disabled: store.busy, title: creationOpen ? "收起" : "新建", action: toggleCreation)
                    Menu {
                        headerMenuItems
                    } label: {
                        Text("更多").font(.subheadline.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                    }.disabled(store.busy).accessibilityLabel("更多通讯录功能")
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            HomeSearchField(placeholder: "搜索名字、职责、标签、团队成员", text: $query,
                focused: $searchFocused, identifier: "contact-search-input")
                .disabled(store.busy || store.editorDirty)
        }.padding(.horizontal, WandLayout.pageInset).padding(.vertical, 4)
            .background(Theme.background)
    }
    @ViewBuilder private var headerMenuItems: some View {
        Button(dispatching ? "收起派工" : "派工", systemImage: "paperplane") {
            requestPanelChange { let next = !dispatching; clearPanels(); dispatching = next }
        }
        if let onOpenSettings { Button("设置", systemImage: "gearshape") { requestPanelChange(onOpenSettings) } }
        if let onSwitchServer { Button("切换服务器", systemImage: "server.rack") { requestPanelChange(onSwitchServer) } }
    }
    private func toggleCreation() {
        if creationOpen { closePanels() }
        else { requestPanelChange { clearPanels(); searchFocused = false; createChooser = true } }
    }
    private func closeSearch() { query = ""; searchFocused = false }
    private func requestPanelChange(_ action: @escaping () -> Void) {
        guard !store.busy else { return }
        if store.editorDirty { pendingPanelChange = action } else { action() }
    }
    private func clearPanels() { revealedRowID = nil; createChooser = false; createKind = nil; expandedID = nil; dispatching = false }
    private func closePanels() { requestPanelChange(clearPanels) }
    @ViewBuilder private func uncertainty(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.rowErrors[key] ?? "结果未确认，请先核对列表。")
                .font(.caption).foregroundStyle(Theme.danger)
            Button("我已核对，开始新的创建操作") { store.acknowledgedUnconfirmed(key) }
                .font(.caption).disabled(store.busy)
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func contactActions(key: String, onMessage: @escaping () -> Void) -> [HomeRowAction] {
        [
            HomeRowAction(id: "message", title: "聊天", symbol: "bubble.left", perform: {
                requestPanelChange { clearPanels(); onMessage() }
            }),
            HomeRowAction(id: "profile", title: "资料", symbol: "person.crop.circle", tint: Theme.info) {
                requestPanelChange { clearPanels(); expandedID = key }
            }
        ]
    }

    @ViewBuilder private func employeeRow(_ employee: SiliconEmployee) -> some View {
        let key = "employee:" + employee.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    guard !store.busy else { return }
                    requestPanelChange {
                        createChooser = false; createKind = nil
                        expandedID = expandedID == key ? nil : key
                    }
                } label: { ContactAvatar(id: employee.id, avatar: employee.avatar, systemKey: employee.systemKey, size: 40)
                    .frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("员工资料：\(employee.name)")
                Button {
                    requestPanelChange {
                        clearPanels()
                        if let onOpenConversation { onOpenConversation(ConversationStore.employeeID(employee.id)) }
                        else if let onNewConversation { onNewConversation(employee.id) }
                        else { store.openEmployee(employee.id, onOpen: onOpenSession) }
                    }
                } label: {
                    ContactConversationLabel(name: employee.name,
                        subtitle: employee.displayTags.joined(separator: " · "),
                        busy: store.busyContact == key)
                }.buttonStyle(.plain).disabled(store.busy || store.unconfirmedActions.contains(key))
                    .accessibilityLabel("进入员工对话：\(employee.name)")
            }
            .homeSwipeActions(id: key, revealedID: $revealedRowID, actions: contactActions(key: key, onMessage: {
                if let onOpenConversation { onOpenConversation(ConversationStore.employeeID(employee.id)) }
                else if let onNewConversation { onNewConversation(employee.id) }
                else { store.openEmployee(employee.id, onOpen: onOpenSession) }
            }), enabled: !store.busy && !store.editorDirty)
            if let error = store.rowErrors[key] {
                if store.unconfirmedActions.contains(key) { uncertainty(key) }
                else { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            }
            if expandedID == key {
                EmployeeProfilePanel(id: employee.id, api: api, directory: store, onMessage: {
                    requestPanelChange {
                        clearPanels()
                        if let onOpenConversation { onOpenConversation(ConversationStore.employeeID(employee.id)) }
                        else if let onNewConversation { onNewConversation(employee.id) }
                        else { store.openEmployee(employee.id, onOpen: onOpenSession) }
                    }
                }) { closePanels() }
                    .id(employee.id).transition(.opacity)
            }
            Divider().padding(.leading, 52)
        }.padding(.vertical, 8)
    }
    @ViewBuilder private func teamRow(_ team: ContactTeam) -> some View {
        let key = "team:" + team.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    guard !store.busy else { return }
                    requestPanelChange {
                        createChooser = false; createKind = nil
                        expandedID = expandedID == key ? nil : key
                    }
                } label: { ContactAvatar(id: team.id, avatar: "", team: true, size: 40)
                    .frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("团队资料：\(team.name)")
                Button { requestPanelChange {
                    clearPanels()
                    if let onTeamConversation { onTeamConversation(team.id) }
                    else { store.openTeam(team.id, onOpen: onOpenRun) }
                } } label: {
                    ContactConversationLabel(name: team.name,
                        subtitle: "\(team.members.count) 位成员" + (team.description.isEmpty ? "" : " · " + team.description),
                        busy: store.busyContact == key)
                }.buttonStyle(.plain).disabled(store.busy || store.unconfirmedActions.contains(key))
                    .accessibilityLabel("新建团队群聊：\(team.name)")
            }
            .homeSwipeActions(id: key, revealedID: $revealedRowID, actions: contactActions(key: key, onMessage: {
                if let onTeamConversation { onTeamConversation(team.id) }
                else { store.openTeam(team.id, onOpen: onOpenRun) }
            }), enabled: !store.busy && !store.editorDirty)
            if let error = store.rowErrors[key] {
                if store.unconfirmedActions.contains(key) { uncertainty(key) }
                else { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            }
            if expandedID == key {
                ContactTeamProfilePanel(id: team.id, api: api, directory: store, onClose: closePanels, onOpenRun: onOpenRun)
                    .id(team.id).transition(.opacity)
            }
            Divider().padding(.leading, 52)
        }.padding(.vertical, 8)
    }
}

/// Four persistent root destinations; compact native navigation does not scale like page content.
/// UIKit owns the material, selected indicator, animation, sizing and accessibility.
struct HomeMenuPill: UIViewRepresentable {
    let mode: HomeListMode
    let onMode: (HomeListMode) -> Void
    var canSelect: (HomeListMode) -> Bool = { _ in true }
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    private static let modes = SystemHomeTabController.modes
    private static let symbols = ["bubble.left.and.bubble.right", "folder", "doc.text", "square.grid.2x2"]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        bar.delegate = context.coordinator
        bar.itemPositioning = .fill
        bar.items = Self.modes.enumerated().map { index, mode in
            let item = UITabBarItem(title: mode.label, image: UIImage(systemName: Self.symbols[index]),
                selectedImage: UIImage(systemName: Self.symbols[index] + ".fill"))
            item.tag = index
            item.accessibilityIdentifier = "home-tab-" + mode.label
            return item
        }
        updateUIView(bar, context: context)
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.mode = mode
        context.coordinator.onMode = onMode
        context.coordinator.canSelect = canSelect
        context.coordinator.enabled = enabled
        bar.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        bar.tintColor = UIColor(Theme.brandText)
        bar.items?.forEach { $0.isEnabled = enabled }
        let selectedItem = Self.modes.firstIndex(of: mode).flatMap { bar.items?[$0] }
        if bar.selectedItem !== selectedItem { bar.selectedItem = selectedItem }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITabBar, context: Context) -> CGSize? {
        let width = min(440, proposal.width ?? 440)
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: proposal.height ?? 0))
        return CGSize(width: width, height: fitted.height)
    }

    static func dismantleUIView(_ bar: UITabBar, coordinator: Coordinator) { bar.delegate = nil }

    final class Coordinator: NSObject, UITabBarDelegate {
        var mode = HomeListMode.im
        var onMode: (HomeListMode) -> Void = { _ in }
        var canSelect: (HomeListMode) -> Bool = { _ in true }
        var enabled = true
        func position(for bar: UIBarPositioning) -> UIBarPosition { .bottom }
        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            let modes = HomeMenuPill.modes
            guard modes.indices.contains(item.tag) else { return }
            let requested = modes[item.tag]
            guard enabled && canSelect(requested) else {
                tabBar.selectedItem = modes.firstIndex(of: mode).flatMap { tabBar.items?[$0] }
                return
            }
            onMode(requested)
        }
    }
}
