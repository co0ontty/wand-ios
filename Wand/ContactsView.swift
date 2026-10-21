import SwiftUI

struct ContactMorphButton: View {
    let expanded: Bool
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: symbol).opacity(expanded ? 0 : 1).rotationEffect(.degrees(reduced || !expanded ? 0 : -45))
                Image(systemName: "xmark").opacity(expanded ? 1 : 0).rotationEffect(.degrees(reduced || expanded ? 0 : 45))
            }
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .animation(reduced ? nil : WandMotion.stateSwap, value: expanded)
        }.buttonStyle(WandQuietButtonStyle()).disabled(disabled).accessibilityLabel(label)
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
    @State private var query = ""
    @State private var createChooser = false
    @State private var dispatching = false
    @State private var createKind: String?
    @State private var createTemplate = ContactTeamTemplate.blank
    @State private var expandedID: String?
    @State private var pendingPanelChange: (() -> Void)?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
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
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                if !store.busy && !store.editorDirty { clearPanels(); await store.refresh() }
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(store.busy)
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
            HStack(spacing: 6) {
                if !embedded {
                    Button { requestPanelChange(onBack) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(store.busy).accessibilityLabel("返回通讯录上级")
                }
                Button {
                    if let onSwitchServer { requestPanelChange(onSwitchServer) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("通讯录").font(.headline).foregroundStyle(Theme.textPrimary)
                        if let serverDisplayName {
                            Text(serverDisplayName).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: WandLayout.controlTouch, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(onSwitchServer == nil || store.busy)
                .accessibilityLabel(serverDisplayName.map { "切换服务器：" + $0 } ?? "通讯录")
                ContactMorphButton(expanded: dispatching, symbol: "paperplane", label: dispatching ? "关闭派工" : "派工", disabled: store.busy) {
                    requestPanelChange { let next = !dispatching; clearPanels(); dispatching = next }
                }
                ContactMorphButton(expanded: creationOpen, symbol: "plus", label: creationOpen ? "关闭创建面板" : "创建联系人", disabled: store.busy) {
                    if creationOpen { closePanels() }
                    else { requestPanelChange { clearPanels(); searchFocused = false; createChooser = true } }
                }
                if let onOpenSettings {
                    Menu {
                        Button("设置", systemImage: "gearshape") { requestPanelChange(onOpenSettings) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: WandLayout.controlTouch, height: WandLayout.controlTouch)
                    }
                    .disabled(store.busy).accessibilityLabel("更多通讯录功能")
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("搜索名字、职责、标签、团队成员", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($searchFocused).disabled(store.busy || store.editorDirty)
                    .accessibilityIdentifier("contact-search-input")
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 36, height: 36)
                }.buttonStyle(.plain).disabled(store.busy || query.isEmpty)
                    .opacity(query.isEmpty ? 0 : 1).accessibilityHidden(query.isEmpty)
                    .accessibilityLabel("清空搜索")
            }.padding(.horizontal, 12).frame(minHeight: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12).padding(.bottom, 10)
        }.background(Theme.elevated)
    }
    private func closeSearch() { query = ""; searchFocused = false }
    private func requestPanelChange(_ action: @escaping () -> Void) {
        guard !store.busy else { return }
        if store.editorDirty { pendingPanelChange = action } else { action() }
    }
    private func clearPanels() { createChooser = false; createKind = nil; expandedID = nil; dispatching = false }
    private func closePanels() { requestPanelChange(clearPanels) }
    @ViewBuilder private func uncertainty(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.rowErrors[key] ?? "结果未确认，请先核对列表。")
                .font(.caption).foregroundStyle(Theme.danger)
            Button("我已核对，开始新的创建操作") { store.acknowledgedUnconfirmed(key) }
                .font(.caption).disabled(store.busy)
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
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

/// Only the two home views are selected tabs; Contacts is a navigation action.
struct HomeMenuPill: View {
    let mode: HomeListMode
    let onMode: (HomeListMode) -> Void
    let onContacts: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var leadingIndex = 0
    @State private var trailingIndex = 0
    @ScaledMetric(relativeTo: .caption) private var itemHeight: CGFloat = 56
    private var modeIndex: Int {
        switch mode { case .im: return 0; case .contacts: return 1; case .sessions: return 2; case .board: return 3 }
    }
    var body: some View {
        HStack(spacing: 0) {
            item("聊天", symbol: "bubble.left.and.bubble.right", active: mode == .im) { onMode(.im) }
            item("通讯录", symbol: "person.crop.rectangle", active: mode == .contacts, action: onContacts)
            item("工作区", symbol: "folder", active: mode == .sessions) { onMode(.sessions) }
            item("任务", symbol: "square.grid.2x2", active: mode == .board) { onMode(.board) }
        }
        .background(alignment: .bottomLeading) {
            GeometryReader { proxy in
                let cell = proxy.size.width / 4
                Capsule().fill(Theme.brand)
                    .frame(width: CGFloat(abs(leadingIndex - trailingIndex) + 1) * cell - 28, height: 3)
                    .offset(x: CGFloat(min(leadingIndex, trailingIndex)) * cell + 14, y: proxy.size.height - 5)
            }.allowsHitTesting(false)
        }
        .background(Theme.elevated, in: Capsule()).overlay(Capsule().stroke(Theme.border.opacity(0.6)))
        .frame(maxWidth: 440).frame(minHeight: itemHeight).padding(.bottom, 8)
        .onAppear {
            let index = modeIndex
            leadingIndex = index; trailingIndex = index
        }
        .onChange(of: mode) { _, _ in
            let target = modeIndex
            if reduced { leadingIndex = target; trailingIndex = target }
            else {
                // The front edge starts first, the rear edge follows using the shared token.
                withAnimation(WandMotion.tabFront) { leadingIndex = target }
                withAnimation(WandMotion.tabRear) { trailingIndex = target }
            }
        }
    }
    private func item(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.caption.weight(.semibold))
            }.foregroundStyle(active ? Theme.brand : Theme.textSecondary).frame(maxWidth: .infinity).frame(minHeight: itemHeight)
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(active ? .isSelected : [])
    }
}
