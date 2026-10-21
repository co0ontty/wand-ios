import SwiftUI
import UniformTypeIdentifiers

/// Presentation only: never infer missing data from an empty filtered projection.
enum ConversationListEmptyState: Equatable {
    case empty, search, filtered, historyOnly
    static func resolve(query: String, totalCount: Int, defaultFilter: Bool) -> Self {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .search }
        if !defaultFilter { return .filtered }
        return totalCount > 0 ? .historyOnly : .empty
    }
    var title: String {
        switch self {
        case .empty: return "还没有对话"
        case .search: return "未找到匹配的对话"
        case .filtered: return "此筛选下暂无对话"
        case .historyOnly: return "当前没有活跃对话"
        }
    }
    var explanation: String {
        switch self {
        case .empty: return "从通讯录选择员工开始对话，或用右上角加号新建群聊。"
        case .search: return "没有匹配当前关键词的对话或任务。清空搜索即可恢复当前列表。"
        case .filtered: return "可以切换其他分类，或查看全部对话。"
        case .historyOnly: return "已解散群聊仍保留在历史筛选中。"
        }
    }
    var actionTitle: String {
        switch self {
        case .empty: return "新建群聊"
        case .search: return "清空搜索"
        case .filtered: return "查看全部对话"
        case .historyOnly: return "查看已解散"
        }
    }
    var symbol: String { self == .search ? "magnifyingglass" : self == .historyOnly ? "archivebox" : "bubble.left.and.bubble.right" }
}

struct ConversationListView: View {
    @ObservedObject var store: ConversationStore
    let onSelect: (String) -> Void
    let onEmployee: (String) -> Void
    let onSettings: () -> Void
    let onSwitchServer: () -> Void
    @State private var query = ""
    @State private var creating = false
    @State private var tier = ConversationListTier.all
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var deleteIDs: Set<String> = []
    @State private var batchBusy = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var creationOpen: Bool { creating || store.creatingPresetID != nil }
    private var rows: [ConversationInstance] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.items.filter { tier.contains($0) && (term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)
            || $0.preview.localizedCaseInsensitiveContains(term) || $0.tasks.contains { $0.task.title.localizedCaseInsensitiveContains(term) }) }
    }
    private var emptyState: ConversationListEmptyState {
        .resolve(query: query, totalCount: store.items.count, defaultFilter: tier == .all)
    }
    private func recoverEmptyList() {
        switch emptyState {
        case .empty: creating = true; searchFocused = false
        case .search: query = ""; searchFocused = true
        case .filtered: query = ""; tier = .all; searchFocused = false
        case .historyOnly: tier = .dissolved; searchFocused = false
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
            List(selection: $selected) {
                if store.loading && store.items.isEmpty { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
                if let error = store.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.caption).foregroundStyle(Theme.danger)
                        Button("重试加载对话") { Task { await store.refresh() } }.frame(minHeight: 44)
                    }.listRowBackground(Color.clear)
                }
                if !store.pendingRequests.isEmpty {
                    Section("未确认请求") {
                        ForEach(store.pendingRequests, id: \.self) { request in
                            Button("核对请求 · " + String(request.suffix(6))) { Task { await store.reconcile(request) } }
                        }
                    }
                }
                ForEach(rows) { item in
                    row(item).tag(item.id)
                        .swipeActions(edge: .leading) {
                            Button(item.pinnedAt == nil ? "置顶" : "取消置顶") { Task { await store.update(item.id, patch: ["pinned": item.pinnedAt == nil]) } }.tint(Theme.brand)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { deleteIDs = [item.id] }
                            if item.kind == "group" {
                                Button(item.dissolvedAt == nil ? "解散" : "恢复") { Task { await store.update(item.id, patch: ["dissolved": item.dissolvedAt == nil]) } }.tint(Theme.textSecondary)
                            }
                        }
                        .onLongPressGesture { selecting = true; selected.insert(item.id) }
                }
                if rows.isEmpty && !store.loading && store.error == nil {
                    ContentUnavailableView {
                        Label(emptyState.title, systemImage: emptyState.symbol)
                    } description: {
                        Text(emptyState.explanation)
                    } actions: {
                        Button(emptyState.actionTitle, action: recoverEmptyList).frame(minHeight: 44)
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
            .refreshable { creating = false; await store.refresh() }
            .onChange(of: tier) { _, _ in selected = []; selecting = false; creating = false }
            if selecting {
                HStack {
                    Button("完成") { selected = []; selecting = false }
                    Spacer()
                    Button("置顶") { batchPin(true) }.disabled(selected.isEmpty || batchBusy)
                    Button("取消置顶") { batchPin(false) }.disabled(selected.isEmpty || batchBusy)
                    Button("删除", role: .destructive) { deleteIDs = selected }.disabled(selected.isEmpty || batchBusy)
                }.padding(WandLayout.fieldGap)
            }
            }
            .opacity(creationOpen ? 0 : 1)
            .allowsHitTesting(!creationOpen).accessibilityHidden(creationOpen)
            if creationOpen {
                ConversationGroupPanel(store: store, context: store.creatingPresetID.map { "preset:" + $0 } ?? "create", inviteTo: nil, templateID: store.creatingPresetID,
                    onClose: { creating = false; store.creatingPresetID = nil }, onAccepted: { creating = false; store.creatingPresetID = nil; onSelect($0) })
                    .padding(.horizontal, WandLayout.fieldGap).padding(.bottom, WandLayout.fieldGap)
                    .transition(.opacity.combined(with: reduced ? .identity : .move(edge: .top)))
            }
            }
        }
        .animation(reduced ? nil : WandMotion.expansion, value: creationOpen)
        .onKeyPress(.escape) {
            if creationOpen { creating = false; store.creatingPresetID = nil; return .handled }
            if selecting { selected = []; selecting = false; return .handled }
            if !query.isEmpty || searchFocused { query = ""; searchFocused = false; return .handled }
            return .ignored
        }
        .alert("删除对话？", isPresented: Binding(get: { !deleteIDs.isEmpty }, set: { if !$0 { deleteIDs = [] } })) {
            Button("取消", role: .cancel) { deleteIDs = [] }
            Button("删除", role: .destructive) { batchDelete() }
        } message: { Text("删除其所属执行会话和群任务资源；不会删除其他对话或工作区。") }
    }
    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 88, height: 44).accessibilityHidden(true)
                Text(tier == .all ? "消息" : tier.title).font(.headline)
                    .lineLimit(1).frame(maxWidth: .infinity)
                HStack(spacing: 0) {
                    Menu {
                        ForEach(ConversationListTier.allCases, id: \.self) { option in
                            Button { tier = option } label: {
                                HStack { Text(option == .all ? "全部消息" : option.title); if option == tier { Image(systemName: "checkmark") } }
                            }
                        }
                        Divider()
                        Button("设置", systemImage: "gearshape", action: onSettings)
                        Button("切换服务器", systemImage: "server.rack", action: onSwitchServer)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("消息菜单").disabled(creationOpen)
                    ContactMorphButton(expanded: creationOpen, symbol: "plus", label: creationOpen ? "关闭建群" : "发起群聊") {
                        if creationOpen { creating = false; store.creatingPresetID = nil } else { creating = true }
                        searchFocused = false
                    }
                }.background(Theme.surface, in: Capsule()).overlay(Capsule().stroke(Theme.border.opacity(0.6)))
            }.frame(minHeight: 56)
            if !creationOpen {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("搜索聊天或任务", text: $query).focused($searchFocused)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("清空搜索")
                    }
                }.padding(.horizontal, 12).frame(minHeight: 44).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(.horizontal, WandLayout.pageInset).padding(.vertical, 4)
    }
    private func row(_ item: ConversationInstance) -> some View {
        HStack(spacing: 12) {
            Button {
                if let id = item.peerEmployeeId { onEmployee(id) }
            } label: {
                if let employee = store.employees.first(where: { $0.id == item.peerEmployeeId }) {
                    ContactAvatar(id: employee.id, avatar: employee.avatar, systemKey: employee.systemKey, size: 44)
                } else { Image(systemName: item.kind == "group" ? "person.3.fill" : "person.crop.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.brand).frame(width: 44, height: 44).clipped() }
            }.buttonStyle(.borderless).disabled(item.peerEmployeeId == nil || selecting).accessibilityLabel("查看联系人资料")
            Button {
                if selecting { if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) } }
                else { onSelect(item.id) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.title).font(.headline).lineLimit(2)
                        Spacer()
                        if item.pinnedAt != nil { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                    Text(item.unavailableReason ?? item.preview).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    if item.kind == "group" { Text("\(item.team?.members.count ?? 0) 人 · \(item.tasks.count) 项任务").font(.caption).foregroundStyle(Theme.textSecondary) }
                }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(WandQuietButtonStyle(tint: Theme.textPrimary))
        }.padding(.vertical, 4).listRowBackground(Theme.surface)
    }
    private func batchPin(_ pin: Bool) {
        guard !batchBusy, !selected.isEmpty else { return }
        let ids = selected
        batchBusy = true
        Task {
            var failed = Set<String>()
            for id in ids { if !(await store.update(id, patch: ["pinned": pin])) { failed.insert(id) } }
            selected = failed; selecting = !failed.isEmpty; batchBusy = false
        }
    }
    private func batchDelete() {
        let ids = deleteIDs; deleteIDs = []; batchBusy = true
        Task {
            var failed = Set<String>()
            for id in ids { do { try await store.remove(id) } catch { failed.insert(id); store.reportError(error.localizedDescription) } }
            selected = failed; selecting = !failed.isEmpty; batchBusy = false
        }
    }
}

struct ConversationGroupPanel: View {
    @ObservedObject var store: ConversationStore
    let context: String
    let inviteTo: ConversationInstance?
    let templateID: String?
    let onClose: () -> Void
    let onAccepted: (String) -> Void
    @ObservedObject private var operation: ConversationOperation
    @State private var draft: ConversationGroupDraft
    @State private var visible = false
    @State private var memberQuery = ""
    @State private var settingsExpanded = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduced
    init(store: ConversationStore, context: String, inviteTo: ConversationInstance?, templateID: String?, onClose: @escaping () -> Void, onAccepted: @escaping (String) -> Void) {
        self.store = store; self.context = context; self.inviteTo = inviteTo; self.templateID = templateID; self.onClose = onClose; self.onAccepted = onAccepted
        _operation = ObservedObject(wrappedValue: store.operation("group:" + context))
        var draft = store.groupDrafts[context] ?? ConversationGroupDraft()
        if let templateID, draft.templateId.isEmpty { draft.templateId = templateID }
        _draft = State(initialValue: draft)
    }
    private var members: [ContactTeamMember] { draft.members(employees: store.employees, presets: store.presets) }
    private var total: Int { Set(members.map { $0.employeeId ?? $0.id } + (inviteTo?.team?.members.map { $0.employeeId ?? $0.id } ?? [])).count }
    private var invalid: Bool {
        members.contains { member in member.employeeId.map { id in !store.employees.contains { $0.id == id && !$0.archived } } ?? false }
            || draft.duties.values.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).count > 2000 }
    }
    private var matchingEmployees: [SiliconEmployee] {
        let term = memberQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.employees.filter { !$0.archived && (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.duty.localizedCaseInsensitiveContains(term)) }
    }
    private func isSelected(_ id: String) -> Bool { members.contains { $0.employeeId == id || $0.id == id } }
    private func alreadyInGroup(_ id: String) -> Bool { inviteTo?.team?.members.contains { $0.employeeId == id || $0.id == id } == true }
    private var presetPicker: some View {
        Picker("团队预设", selection: $draft.templateId) {
            Text("自选员工").tag("")
            ForEach(store.presets) { Text($0.name).tag($0.id) }
        }.pickerStyle(.menu).frame(minHeight: 44).disabled(!operation.canSubmit)
    }
    private var memberSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(Theme.textSecondary)
            TextField("搜索员工名字或职责", text: $memberQuery).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !memberQuery.isEmpty {
                Button { memberQuery = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .buttonStyle(WandQuietButtonStyle()).accessibilityLabel("清空成员搜索")
            }
        }.padding(.horizontal, 12).frame(minHeight: WandLayout.controlTouch).wandInputSurface(focused: false)
    }
    private var groupNameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("群名（可选）").font(.caption).foregroundStyle(Theme.textSecondary)
            TextField("例如：项目协作", text: $draft.name)
                .padding(.horizontal, 12).frame(minHeight: WandLayout.controlTouch).wandInputSurface(focused: false)
                .accessibilityLabel("群名，可选").disabled(!operation.canSubmit)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WandLayout.fieldGap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(inviteTo == nil ? (typeSize.isAccessibilitySize ? "建群" : "发起群聊") : "邀请成员")
                        .font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(inviteTo == nil ? "已选 \(total)/8" : "已选 \(members.count) 位 · 全群 \(total)/8")
                        .accessibilityLabel("已选 \(members.count) 位，全群 \(total) 位，最多8位成员")
                        .font(.caption).foregroundStyle(total > 8 || invalid ? Theme.danger : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("取消", action: onClose).frame(minWidth: WandLayout.controlTouch, minHeight: WandLayout.controlTouch)
                    .buttonStyle(WandQuietButtonStyle())
            }
            if !typeSize.isAccessibilitySize { presetPicker; memberSearch }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: WandLayout.fieldGap) {
                            presetPicker; memberSearch
                            if inviteTo == nil { groupNameField }
                        }.padding(.bottom, WandLayout.sectionGap)
                    }
                    ForEach(matchingEmployees) { employee in
                        let checked = isSelected(employee.id)
                        Toggle(isOn: Binding(get: { isSelected(employee.id) }, set: { value in
                            draft.selectEmployee(employee.id, selected: value, employees: store.employees, presets: store.presets)
                        })) {
                            HStack(spacing: 12) {
                                ContactAvatar(id: employee.id, avatar: employee.avatar, systemKey: employee.systemKey, size: 40)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(employee.name).font(.headline).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(alreadyInGroup(employee.id) ? "已在群中" : employee.duty).font(.caption).foregroundStyle(Theme.textSecondary)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }.containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                                    max(0, width - 40 - WandLayout.controlTouch - WandLayout.fieldGap * 2)
                                }
                                ZStack {
                                    Image(systemName: "circle").opacity(checked ? 0 : 1)
                                    Image(systemName: "checkmark.circle.fill").opacity(checked ? 1 : 0)
                                }.font(.system(size: 22)).foregroundStyle(checked ? Theme.brandText : Theme.textMuted)
                                    .frame(width: 44, height: 44).accessibilityHidden(true)
                                    .animation(reduced ? nil : WandMotion.stateSwap, value: checked)
                            }.containerRelativeFrame(.horizontal)
                        }.toggleStyle(.button).buttonStyle(WandQuietButtonStyle(tint: Theme.textPrimary))
                            .accessibilityValue(checked ? "已选择" : "未选择")
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 64)
                            .disabled(!operation.canSubmit || alreadyInGroup(employee.id) || (!checked && total >= 8))
                            .padding(.vertical, 4)
                        Divider()
                    }
                    if matchingEmployees.isEmpty {
                        Text(memberQuery.isEmpty ? "还没有可选员工。" : "没有匹配的员工，可换词或清空搜索。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary).padding(.vertical, WandLayout.sectionGap)
                    }
                    DisclosureGroup("群设置与成员职责", isExpanded: $settingsExpanded) {
                        VStack(alignment: .leading, spacing: WandLayout.fieldGap) {
                            if inviteTo == nil {
                                Picker("负责人", selection: $draft.leaderId) {
                                    Text("按预设或名单顺序").tag("")
                                    ForEach(members) { Text($0.name).tag($0.employeeId ?? $0.id) }
                                }
                            }
                            ForEach(members) { member in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(member.name).font(.headline)
                                        Spacer()
                                        Button("移除") { draft.selectEmployee(member.employeeId ?? member.id, selected: false, employees: store.employees, presets: store.presets) }
                                            .frame(minHeight: 44).buttonStyle(WandQuietButtonStyle())
                                    }
                                    Text("本群职责").font(.caption).foregroundStyle(Theme.textSecondary)
                                    TextField("沿用员工职责", text: Binding(get: { draft.duties[member.employeeId ?? member.id] ?? member.duty }, set: { draft.duties[member.employeeId ?? member.id] = $0 }), axis: .vertical)
                                        .lineLimit(1...3).textFieldStyle(.roundedBorder).accessibilityLabel(member.name + "本群职责")
                                }
                            }
                        }.padding(.top, WandLayout.fieldGap)
                    }.padding(.top, WandLayout.sectionGap).disabled(!operation.canSubmit)
                }
            }.frame(maxHeight: .infinity).scrollDismissesKeyboard(.interactively)
            if inviteTo == nil && !typeSize.isAccessibilitySize { groupNameField }
            if invalid { Text("请展开群设置，处理不可用成员或超长职责。").font(.caption).foregroundStyle(Theme.danger) }
            if let message = operation.message { Text(message).font(.caption).foregroundStyle(operation.phase == .failed ? Theme.danger : Theme.textSecondary) }
            if operation.unknownRequest != nil { Button("核对请求") { operation.reconcile(service: store.service, accepted: accept) }.frame(minHeight: 44) }
            if let receipt = operation.receipt { Button("打开已建立的群") { accept(receipt) }.frame(minHeight: 44) }
            Button(action: submit) {
                HStack {
                    Text(operation.phase == .sending ? "处理中" : operation.phase == .sent ? "已完成" : operation.phase == .failed ? "失败" : inviteTo == nil ? "建群" : "邀请")
                    ProgressView().controlSize(.small).opacity(operation.phase == .sending ? 1 : 0)
                        .accessibilityHidden(operation.phase != .sending)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(WandPrimaryButtonStyle()).disabled(!operation.canSubmit || members.isEmpty || total > 8 || invalid)
        }
        .padding(WandLayout.pageInset).frame(maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .animation(reduced ? nil : WandMotion.expansion, value: settingsExpanded)
        .onChange(of: draft) { _, value in store.groupDrafts[context] = value }
        .onChange(of: invalid) { _, value in if value { settingsExpanded = true } }
        .onAppear { visible = true }
        .onDisappear {
            if operation.receipt == nil { store.groupDrafts[context] = draft }
            visible = false
        }
    }
    private func accept(_ receipt: ConversationReceipt) {
        guard visible else { return }
        store.finishGroup(context)
        onAccepted(receipt.conversationId)
    }
    private func submit() {
        var body: [String: Any] = ["group": draft.body]
        if let inviteTo { body["memberVersion"] = inviteTo.memberVersion }
        let path = inviteTo.map { "/api/conversations/" + store.api.percentEncodePathComponent($0.id) + "/invitations" } ?? "/api/conversations"
        operation.submit({ try await store.service.conversationPost(path: path, body: body) }, accepted: { receipt in
            Task { await store.refresh() }; accept(receipt)
        })
    }
}

struct ConversationDetailView: View {
    let id: String
    @ObservedObject var store: ConversationStore
    let onOpenSession: (String) -> Void
    let onOpenConversation: (String) -> Void
    let onEmployee: (String) -> Void
    @StateObject private var composerFocus = ComposerFocusController()
    @StateObject private var keyboard = KeyboardObserver()
    @AppStorage(CatComposerSide.preferenceKey) private var sideRaw = CatComposerSide.left.rawValue
    @State private var dragOffset: CGFloat = 0
    @State private var files = false
    @StateObject private var messageLinks = ServerFileLinkController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var members = false
    @State private var tasks = false
    @State private var inviting = false
    @State private var scrollPinned = true
    @State private var userScrolling = false
    @StateObject private var scrollScheduler = ChatScrollScheduler()
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var identityMetrics = ChatIdentityLayoutMetrics()
    private var detail: ConversationInstance? { store.details[id] }
    private var messages: [ConversationMessage] {
        let filter = store.filters[id] ?? ""
        return detail?.messages.filter { filter.isEmpty || $0.taskId == filter } ?? []
    }
    var body: some View {
        VStack(spacing: 0) {
            if let detail {
                if let reason = detail.unavailableReason { Text(reason).font(.caption).foregroundStyle(Theme.danger).padding(8) }
                if members { memberPanel(detail) }
                if inviting {
                    ConversationGroupPanel(store: store, context: "invite:" + id, inviteTo: detail, templateID: nil,
                        onClose: { inviting = false }, onAccepted: { _ in inviting = false; Task { await store.load(id) } }).padding(8)
                }
                if tasks { taskPanel(detail) }
                if let filter = store.filters[id], !filter.isEmpty {
                    HStack {
                        Text(detail.tasks.first { $0.id == filter }?.task.title ?? "任务消息").font(.caption)
                        Spacer(); Button("查看全部") { store.filters[id] = nil }
                    }.padding(10).background(Theme.surface)
                }
                GeometryReader { viewport in
                    messageList(detail).environment(\.chatViewportHeight, viewport.size.height)
                }.clipped()
                    .overlay {
                        if messages.isEmpty {
                            ContentUnavailableView(
                                (store.filters[id] ?? "").isEmpty ? "还没有消息" : "此任务暂无消息",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text(detail.dissolvedAt == nil ? "消息会显示在这里，你也可以直接开始沟通。" : "群聊已解散，恢复后可继续沟通。"))
                        }
                    }
                    .onTapGesture { composerFocus.collapse() }
                ConversationComposerView(id: id, store: store, detail: detail, target: store.targets[id], focus: composerFocus, onEmployee: onEmployee)
                    .id(store.draftKey(id, target: store.targets[id]))
                    .padding(.bottom, keyboard.lift)
            } else {
                Spacer()
                if let error = store.error { Text(error).foregroundStyle(Theme.danger); Button("重试") { Task { await store.load(id) } } }
                else { ProgressView("正在加载对话…") }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, identityMetrics.clearance)
        .background(Theme.background)
        .background { SessionBackSwipeEnabler().allowsHitTesting(false) }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .top) { navigation }
        .environment(\.chatAPI, store.api)
        .environment(\.serverFileLinkController, messageLinks)
        .sheet(item: $messageLinks.previewItem, onDismiss: { messageLinks.dismissPreview(); composerFocus.resume("message-file") }) {
            ServerFilePreviewView(item: $0)
        }
        .alert(item: $messageLinks.failure) { failure in
            Alert(title: Text("文件下载失败"), message: Text(failure.message), dismissButton: .default(Text("好")))
        }
        .onChange(of: messageLinks.isDownloading) { _, downloading in
            if downloading { composerFocus.borrow("message-file") }
            else if messageLinks.previewItem == nil { composerFocus.resume("message-file") }
        }
        .sheet(isPresented: $files, onDismiss: { composerFocus.resume("files") }) {
            NavigationStack {
                List {
                    ForEach(detail?.messages.compactMap(\.reportFile) ?? [], id: \.path) { file in
                        ConversationReportCard(file: file, api: store.api)
                    }
                    if detail?.messages.compactMap(\.reportFile).isEmpty != false {
                        Text("暂无已交付文件；执行会话中的文件可从回复详情打开。")
                    }
                }.navigationTitle("对话文件").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { files = false } } }
            }
        }
        .task(id: id) { store.select(id); await store.load(id) }
        .onDisappear {
            inviting = false; composerFocus.collapse(); messageLinks.cancel(); scrollScheduler.cancel()
            store.clearExecutionPreference(for: id)
        }
        .animation(reduced ? nil : WandMotion.stateSwap, value: members)
        .animation(reduced ? nil : WandMotion.stateSwap, value: tasks)
        .animation(reduced ? nil : WandMotion.stateSwap, value: inviting)
    }
    private var navigation: some View {
        ZStack(alignment: .top) {
            TopChatCompanion(side: CatComposerSide(rawValue: sideRaw) ?? .left, dragOffset: dragOffset,
                title: detail?.title ?? "对话", status: detail?.identityStatus ?? "正在加载对话") { size in
                if let detail {
                    let employee = store.employees.first { $0.id == detail.peerEmployeeId }
                    let session = detail.messages.last(where: { $0.sessionPreview?.active == true })?.sessionLink?.sessionId ?? detail.communicationSessionId
                    ConversationCompanionFace(employee: employee, detail: detail, execution: session.map { store.executionStore($0) }, size: size)
                        .overlay { Color.clear.modifier(CatInputGesture(onTap: { composerFocus.focus() }, onDrag: { dragOffset = $0 }, onDrop: { offset in
                                sideRaw = (CatComposerSide(rawValue: sideRaw) ?? .left).dropped(translation: offset).rawValue; dragOffset = 0
                            }, identityName: detail.title)) }
                        .accessibilityAction(named: "切换角色位置") { sideRaw = sideRaw == "left" ? "right" : "left" }
                }
            }
            FloatingChatControls(onBack: { dismiss() }) {
                Button { composerFocus.borrow("files"); files = true } label: { FloatingChatIcon(symbol: "folder") }.accessibilityLabel("对话文件")
                Menu {
                    Text(detail?.title ?? "聊天")
                    if let employee = detail?.peerEmployeeId { Button("员工资料与执行配置") { onEmployee(employee) } }
                    if detail?.kind == "group" {
                        Button(members ? "收起成员" : "成员") { composerFocus.collapse(); members.toggle(); inviting = false }
                        Button("邀请成员") { composerFocus.collapse(); inviting.toggle(); members = false }
                        Button(tasks ? "收起任务" : "任务与执行") { composerFocus.collapse(); tasks.toggle() }
                    }
                } label: { FloatingChatIcon(symbol: "ellipsis") }.accessibilityLabel("对话菜单")
            }
        }
    }
    private func messageList(_ detail: ConversationInstance) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if detail.history?.hasEarlier == true {
                        Button(store.historyLoading.contains(id) ? "加载中…" : "加载更早消息") {
                            scrollPinned = false
                            let anchor = messages.first?.id
                            Task {
                                await store.load(id, older: true)
                                if let anchor { scrollScheduler.request { proxy.scrollTo(anchor, anchor: .top) } }
                            }
                        }.buttonStyle(WandSecondaryButtonStyle()).disabled(store.historyLoading.contains(id))
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { _, message in
                        messageView(message, detail: detail).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("im-tail")
                }.padding(12).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .environment(\.wandImageGallery, { wandConversationImagePages(messages.map(\.turn)) })
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(scrollPinned ? .bottom : nil, for: .sizeChanges)
            .onScrollPhaseChange { _, phase in userScrolling = phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height || geometry.contentSize.height - geometry.visibleRect.maxY < 40
            } action: { _, atBottom in if userScrolling { scrollPinned = atBottom } }
            // A keyboard/composer resize does not change the message revision. Re-anchor
            // after the new viewport is laid out, but never while reading older messages.
            .onScrollGeometryChange(for: CGSize.self) { geometry in
                CGSize(width: geometry.containerSize.width, height: geometry.containerSize.height)
            } action: { old, new in
                if old != new { scrollToTail(proxy) }
            }
            .onChange(of: messages.map(\.renderRevision)) { _, _ in
                scrollToTail(proxy)
            }
            // Expanding or collapsing an activity window changes the content height without
            // changing the message revision, so pinned follow must not depend on new messages.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                if old != new { scrollToTail(proxy) }
            }
            .onChange(of: scrollPinned) { _, pinned in if !pinned { scrollScheduler.cancel() } }
            .onChange(of: userScrolling) { _, scrolling in if scrolling { scrollScheduler.cancel() } }
            .overlay(alignment: .bottomTrailing) {
                if !scrollPinned { Button { userScrolling = false; scrollPinned = true; scrollToTail(proxy) } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44).background(Theme.surface, in: Circle()) }.accessibilityLabel("回到最新消息").padding(12) }
            }
        }
    }
    private func scrollToTail(_ proxy: ScrollViewProxy) {
        guard scrollPinned, !userScrolling else { scrollScheduler.cancel(); return }
        scrollScheduler.request {
            guard scrollPinned, !userScrolling else { return }
            proxy.scrollTo("im-tail", anchor: .bottom)
        }
    }
    private func messageView(_ message: ConversationMessage, detail: ConversationInstance) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if detail.kind == "group", message.turn.role != "user", let author = message.author {
                Button(author.name ?? "成员") {
                    if let employee = detail.team?.members.first(where: { $0.id == author.id })?.employeeId { onEmployee(employee) }
                }.font(.caption.weight(.semibold)).frame(minHeight: 32)
            }
            messageContent(message, detail: detail)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func messageContent(_ message: ConversationMessage, detail: ConversationInstance) -> some View {
        if message.notice == true {
            Text(conversationTurnPreview(message.turn)).font(.caption).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
        } else if let link = message.sessionLink {
            ConversationReplyCard(message: message, api: store.api, execution: store.executionStore(link.sessionId)) { onOpenSession(link.sessionId) }
        } else if let link = message.conversationLink {
            VStack(alignment: .leading, spacing: 8) {
                Text(link.title).font(.headline)
                Text(message.taskPreview?.label ?? "准备中").font(.caption).foregroundStyle(Theme.textSecondary)
                ScrollView {
                    MarkdownText(text: message.taskPreview?.text.isEmpty == false ? message.taskPreview!.text : "等待任务输出")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 152).clipped()
                Button("查看任务") { store.openTask(link, preview: message.taskPreview); onOpenConversation(link.conversationId) }.disabled(message.taskPreview?.status == "unavailable")
            }.padding(12).frame(maxWidth: 420).frame(height: 232).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        } else if let file = message.reportFile {
            ConversationReportCard(file: file, api: store.api)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                SessionMessageBody(turn: message.turn, api: store.api, sessionID: message.author?.sessionId ?? detail.communicationSessionId ?? detail.sessionId ?? "", store: message.author?.sessionId.map { store.executionStore($0) })
            }
        }
    }
    private func memberPanel(_ detail: ConversationInstance) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(detail.team?.members ?? []) { member in
                    Button { if let employee = member.employeeId { onEmployee(employee) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.name + (member.isLeader ? " · 负责人" : "")).font(.subheadline.weight(.semibold))
                            Text(detail.memberUnavailableReasons[member.id] ?? member.duty).font(.caption).foregroundStyle(Theme.textSecondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                    }.buttonStyle(.plain).disabled(member.employeeId == nil)
                }
            }.padding(12)
        }.frame(maxHeight: 220).background(Theme.surface)
    }
    private func taskPanel(_ detail: ConversationInstance) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(detail.tasks) { task in
                    DisclosureGroup(task.task.title) {
                        ForEach(detail.runDetails.filter { $0.run.taskId == task.id }, id: \.run.id) { run in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("第 \(run.run.roundNumber ?? 1) 轮 · " + contactActivityLabel(run.run.status)).font(.caption)
                                ForEach(run.steps) { step in Button(step.title) { if let session = step.sessionId { onOpenSession(session) } }.disabled(step.sessionId == nil) }
                                Button("回复本轮") { store.targets[id] = ConversationTarget(taskId: task.id, runId: run.run.id); store.filters[id] = task.id; tasks = false }
                            }
                        }
                        Button("查看消息") { store.filters[id] = task.id; tasks = false }
                    }
                }
            }.padding(12)
        }.frame(maxHeight: 280).background(Theme.surface)
    }
}

private struct ConversationReplyCard: View {
    let message: ConversationMessage
    let api: WandAPI
    @ObservedObject var execution: ChatStore
    let onOpen: () -> Void
    private var text: String { message.sessionPreview?.text ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText(text: text.isEmpty ? "等待会话输出" : text)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(message.sessionPreview?.label ?? "准备中").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button("继续此工作", action: onOpen).font(.caption).frame(minHeight: 44)
                    .disabled(message.sessionPreview?.status == "unavailable")
            }
            SessionProtocolPanel(store: execution)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConversationReportCard: View {
    let file: ContactReportFile
    let api: WandAPI
    @StateObject private var links = ServerFileLinkController()
    var body: some View {
        Button { links.open(serverPath: file.path, api: api) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(file.preview?.title.isEmpty == false ? file.preview!.title : file.name, systemImage: "doc.text")
                if let excerpt = file.preview?.excerpt { Text(excerpt).font(.caption).lineLimit(3) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.buttonStyle(.bordered).disabled(links.isDownloading)
            .sheet(item: $links.previewItem, onDismiss: links.dismissPreview) { ServerFilePreviewView(item: $0) }
            .onDisappear { links.cancel() }
    }
}

private struct ConversationCompanionFace: View {
    let employee: SiliconEmployee?
    let detail: ConversationInstance
    let execution: ChatStore?
    let size: CGFloat
    var body: some View {
        if let execution { ConversationExecutingCompanion(employee: employee, execution: execution, size: size) }
        else if let employee { WorkingAvatar(id: employee.id, name: employee.name, avatar: employee.avatar, size: size) }
        else { ContactAvatar(id: detail.id, avatar: "", size: size, name: detail.title) }
    }
}
private struct ConversationExecutingCompanion: View {
    let employee: SiliconEmployee?
    @ObservedObject var execution: ChatStore
    let size: CGFloat
    private var executing: Bool { execution.isResponding && execution.status == "running" && !execution.permissionBlocked }
    var body: some View {
        WorkingAvatar(id: employee?.id ?? execution.snapshot?.employeeId ?? "", name: employee?.name ?? execution.displayEmployeeName ?? "",
            avatar: employee?.avatar ?? execution.displayEmployeeAvatar ?? "",
            activity: avatarFileActivity(messages: execution.messages, executing: executing),
            thinking: avatarIsThinking(messages: execution.messages, executing: executing), size: size)
    }
}

private struct ConversationComposerView: View {
    let id: String
    @ObservedObject var store: ConversationStore
    let detail: ConversationInstance
    let target: ConversationTarget?
    let onEmployee: (String) -> Void
    @ObservedObject private var draft: ComposerDraftState
    @ObservedObject private var attachments: ComposerAttachmentController
    @ObservedObject private var action: ConversationOperation
    @State private var contextExpanded = false
    @State private var composerActionsOpen = false
    @ObservedObject var focus: ComposerFocusController
    @StateObject private var links = ServerFileLinkController()
    @State private var settingsInfo = false
    @State private var settingsEmployeeID: String?
    @State private var stopConfirm = false
    @State private var composing = false
    @State private var height: CGFloat = 36
    @State private var workspaceID = ""
    @State private var cwd = ""
    @State private var notice: String?
    @State private var draftConsumer = UUID()
    @State private var visible = false
    @StateObject private var keyboard = KeyboardObserver()
    @Environment(\.accessibilityReduceMotion) private var reduced
    init(id: String, store: ConversationStore, detail: ConversationInstance, target: ConversationTarget?, focus: ComposerFocusController, onEmployee: @escaping (String) -> Void) {
        self.id = id; self.store = store; self.detail = detail; self.target = target; self.focus = focus; self.onEmployee = onEmployee
        let draft = store.composer(id, target: target)
        _draft = ObservedObject(wrappedValue: draft); _attachments = ObservedObject(wrappedValue: draft.attachments)
        _action = ObservedObject(wrappedValue: store.operation("action:" + id + ":" + (target?.runId ?? "talk")))
    }
    private var dispatch: Bool { store.dispatchIntent.contains(id) }
    private var editorText: Binding<String> {
        let revision = draft.discardRevision
        return Binding(get: { draft.text }, set: { draft.setText($0, ifDiscardRevision: revision) })
    }
    private var employee: SiliconEmployee? { store.employees.first { $0.id == detail.peerEmployeeId } }
    private var preferenceEligible: Bool { detail.kind == "dm" && target == nil && !dispatch }
    private var run: ContactRunDetail? { detail.runDetails.first { $0.run.id == target?.runId } }
    private var execution: ChatStore? { (run?.run.chatSessionId ?? detail.communicationSessionId).map { store.executionStore($0) } }
    private var running: Bool { target != nil ? ["running", "awaiting_approval", "waiting_user"].contains(run?.run.status ?? "") : execution?.isResponding == true }
    private var hasComposerDraft: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.attachments.isEmpty }
    private var composerPhase: ComposerSendPhase { action.phase == .idle ? draft.sendPhase : action.phase }
    var body: some View {
        VStack(spacing: 6) {
            if target != nil || dispatch {
                HStack {
                    Text(dispatch ? "派发任务" : "回复本轮 · " + (detail.tasks.first { $0.id == target?.taskId }?.task.title ?? "任务")).font(.caption)
                    Spacer(); Button {
                        if dispatch { cancelDispatch() }
                        else { store.targets[id] = nil; contextExpanded = false }
                    } label: {
                        Text("取消").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.sendPhase == .sending || store.hasUnknown(id, target: target))
                    .accessibilityIdentifier("conversation-cancel-dispatch")
                }
            }
            if run?.run.status == "awaiting_approval" {
                ConversationRunActionButton(operation: action, title: "同意计划并开工") { perform("approve") }
            }
            if store.hasUnknown(id, target: target) { Button("核对送达状态") { store.reconcileComposer(id, target: target) } }
            if action.unknownRequest != nil { Button("核对运行操作") { action.reconcile(service: store.service, accepted: { _ in Task { await store.load(id) } }) } }
            if let notice { Text(notice).font(.caption).foregroundStyle(Theme.textSecondary) }
            if composerActionsOpen { composerActionsPanel.transition(.opacity.combined(with: reduced ? .identity : .move(edge: .bottom))) }
            if contextExpanded { contextPanel.transition(.opacity.combined(with: reduced ? .identity : .move(edge: .bottom))) }
            FocusComposerSurface(expanded: expanded, hasDraft: !draft.text.isEmpty || !attachments.attachments.isEmpty,
                onFocus: { focus.focus() }, editor: {
                    VStack(spacing: 4) {
                        PendingAttachmentsPreview(baseURL: store.api.baseURL, attachments: attachments.attachments, onRemove: attachments.remove,
                            onPreview: { file in focus.borrow("preview", open: true); links.open(serverPath: file.savedPath, api: store.api) })
                        if draft.submissionFailed, let feedback = draft.sendFeedback { Text(feedback).font(.caption).foregroundStyle(Theme.danger) }
                        IMEAwareComposerTextView(text: editorText, placeholder: dispatch ? "任务说明" : "输入消息，回车换行", isFocused: focus.focused,
                            maximumHeight: maximumHeight, submitOnReturn: false, onPasteImages: attachments.handlePastedImageData,
                            onFocusChange: { focus.focused = $0 }, onCompositionChange: { composing = $0 }, onSubmit: send, onHeightChange: { height = $0 })
                            // Discard also retires UIKit marked text; it must not commit back on blur.
                            .id(draft.discardRevision)
                            .frame(height: min(maximumHeight, max(34, height)))
                    }
                }, add: {
                    ComposerAddButton(expanded: composerActionsOpen, uploading: attachments.isUploading) {
                        if composerActionsOpen { closeComposerActions() }
                        else { contextExpanded = false; focus.borrow("actions", open: true); composerActionsOpen = true }
                    }
                }, send: {
                        NativeComposerActions(phase: composerPhase,
                            turnRunning: running && !dispatch, hasDraft: hasComposerDraft,
                            canSubmit: composerDraftIsSendable(draft.text, hasAttachments: !attachments.attachments.isEmpty, isComposing: composing)
                                && !attachments.isUploading && !store.hasUnknown(id, target: target) && action.canSubmit && detail.dissolvedAt == nil && !detail.deleting,
                            canStop: action.canSubmit,
                            message: action.message ?? draft.sendFeedback, sendLabel: dispatch ? "确认派发任务" : running ? "继续发送" : "发送消息",
                            onSend: send, onStop: { if action.canSubmit { stopConfirm = true } })
                }, settings: {
                    if preferenceEligible, let employee, !employee.agents.isEmpty {
                        ConversationExecutionSettings(store: store, conversationID: id, employee: employee, focus: focus,
                            disabled: composerPhase == .sending || attachments.isUploading || store.hasUnknown(id, target: target))
                    } else if let execution, !dispatch, target != nil || detail.kind == "group" {
                        SessionComposerSettings(store: execution, focus: focus)
                    } else {
                        Button { focus.borrow("settings", open: true); settingsInfo = true } label: {
                            Label("员工默认 · " + (store.employees.first(where: { $0.id == (detail.peerEmployeeId ?? detail.leader?.employeeId) })?.agents.first.map {
                                $0.model == "default" ? "默认模型" : $0.model
                            } ?? "配置不可用"), systemImage: "info.circle")
                                .font(.caption).lineLimit(1).truncationMode(.tail)
                                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("查看员工默认配置，只读")
                            .accessibilityHint("此处不能选择模型，可前往员工执行配置修改")
                            .accessibilityIdentifier("conversation-execution-defaults")
                    }
                }, actionCount: ComposerActionPresentation(phase: composerPhase,
                    turnRunning: running && !dispatch, hasDraft: hasComposerDraft).slotCount)
        }
        .onAppear { if !visible { draft.acquire(draftConsumer) }; visible = true; attachments.setToastHandler { notice = $0 } }
        .onDisappear { closeComposerActions(); contextExpanded = false; if visible { draft.release(draftConsumer) }; visible = false }
        .animation(reduced ? nil : WandMotion.expansion, value: contextExpanded)
        .animation(reduced ? nil : WandMotion.expansion, value: composerActionsOpen)
        .onChange(of: target?.runId) { _, _ in closeComposerActions(); contextExpanded = false }
        .onChange(of: focus.editing) { _, editing in if !editing { closeComposerActions() } }
        .onChange(of: store.filters[id]) { _, _ in closeComposerActions(); contextExpanded = false }
        .onKeyPress(.escape) { if composerActionsOpen { closeComposerActions(); return .handled }; if contextExpanded { contextExpanded = false; return .handled }; return .ignored }
        .onChange(of: keyboard.isVisible) { old, value in if old && !value { focus.keyboardHidden() } }
        .onChange(of: draft.sendPhase) { _, phase in
            if phase == .sent && draft.text.isEmpty && attachments.attachments.isEmpty && !composing { focus.collapse() }
        }
        .fileImporter(isPresented: $attachments.showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            attachments.handleFileSelection(result); focus.resume("attachment")
        }
        .sheet(isPresented: $attachments.showPhotoPicker, onDismiss: { focus.resume("attachment") }) { PhotoLibraryPicker { attachments.showPhotoPicker = false; attachments.handlePhotoSelection($0) } }
        .sheet(item: $links.previewItem, onDismiss: { links.dismissPreview(); focus.resume("preview") }) { ServerFilePreviewView(item: $0) }
        .alert("附件预览失败", isPresented: Binding(get: { links.failure != nil }, set: { if !$0 { links.failure = nil; focus.resume("preview") } })) {
            Button("完成") { links.failure = nil; focus.resume("preview") }
        } message: { Text(links.failure?.message ?? "") }
        .sheet(isPresented: $settingsInfo, onDismiss: {
            if let employeeID = settingsEmployeeID {
                settingsEmployeeID = nil; focus.collapse(); onEmployee(employeeID)
            } else { focus.resume("settings") }
        }) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: WandLayout.sectionGap) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("只读说明", systemImage: "info.circle").font(.headline)
                            Text("这里不能选择或切换模型。派发的新工作使用员工默认配置；候选按顺序尝试，不是可选项。")
                            Text("修改请前往员工执行配置，保存后影响此员工后续新工作，不改变历史会话或正在运行的任务。私聊输入栏的临时选择不用于派发任务。")
                                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                        if let employee = store.employees.first(where: { $0.id == (detail.peerEmployeeId ?? detail.leader?.employeeId) }) {
                            VStack(alignment: .leading, spacing: WandLayout.fieldGap) {
                                Text(employee.name + " · 默认执行顺序").font(.headline)
                                if employee.agents.isEmpty {
                                    Text("尚未配置执行候选，请前往员工执行配置添加。")
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                ForEach(Array(employee.agents.enumerated()), id: \.offset) { index, candidate in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(index == 0 ? "首选" : "降级候选 \(index + 1)").font(.subheadline.weight(.semibold))
                                        Text(WandAgentTool(provider: candidate.provider, engine: candidate.engine).title + " · " + (candidate.model == "default" ? "默认模型" : candidate.model))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("权限：\(composerModeName(candidate.mode)) · 思考：\(composerThinkingName(candidate.thinkingEffort))")
                                            .font(.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("conversation-default-candidate-\(index)")
                                }
                            }
                            Button("前往员工执行配置", systemImage: "person.crop.circle") {
                                settingsEmployeeID = employee.id; settingsInfo = false
                            }.frame(minHeight: 44)
                                .accessibilityIdentifier("conversation-edit-execution-defaults")
                        } else {
                            Text("员工默认配置暂不可用，请关闭后刷新对话重试。")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(WandLayout.pageInset)
                }
                .navigationTitle("员工默认配置（只读）").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { settingsInfo = false }
                        .accessibilityIdentifier("conversation-close-execution-defaults")
                } }
            }
        }
        .confirmationDialog("停止当前任务？", isPresented: $stopConfirm, titleVisibility: .visible) {
            Button("停止", role: .destructive) { if target != nil { perform("stop") } else { execution?.stopResponding() } }
        }
    }
    private func closeComposerActions() {
        composerActionsOpen = false; focus.resume("actions")
    }
    private func cancelDispatch() {
        guard store.cancelDispatch(id, target: target) else { return }
        store.targets[id] = nil
        contextExpanded = false
        closeComposerActions()
        focus.collapse()
    }
    private var composerActionsPanel: some View {
        ComposerAttachmentPanel(onPhoto: {
            focus.borrow("attachment", open: true); closeComposerActions(); attachments.showPhotoPicker = true
        }, onFile: {
            focus.borrow("attachment", open: true); closeComposerActions(); attachments.showFileImporter = true
        }) {
            HStack {
                Button(dispatch ? "取消派发" : "派发任务", systemImage: "checklist") {
                    closeComposerActions()
                    if dispatch { cancelDispatch() } else { store.dispatchIntent.insert(id) }
                }.frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(draft.sendPhase == .sending || store.hasUnknown(id, target: target))
                Button("派发与目录设置", systemImage: "slider.horizontal.3") {
                    closeComposerActions(); contextExpanded = true
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            HStack {
                if detail.kind == "group", let leader = detail.leader {
                    Button("@" + leader.name, systemImage: "at") {
                        closeComposerActions(); draft.text += "@" + leader.name + " "; focus.focus()
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }
                if let employee = detail.peerEmployeeId {
                    Button("员工执行配置", systemImage: "person.crop.circle") {
                        closeComposerActions(); onEmployee(employee)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }
                if running {
                    Button("停止当前任务", systemImage: "stop", role: .destructive) {
                        closeComposerActions(); stopConfirm = true
                    }.frame(maxWidth: .infinity, minHeight: 44).disabled(!action.canSubmit || draft.sendPhase == .sending)
                }
            }
        }
    }
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    private var maximumHeight: CGFloat { max(typeSize.isAccessibilitySize ? 80 : 0, composerMaximumInputHeight(compact: verticalSizeClass == .compact, keyboardVisible: keyboard.isVisible)) }
    private var expanded: Bool { focus.editing || focus.focused || draft.submissionFailed || store.hasUnknown(id, target: target) }
    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("派发与目录设置").font(.headline)
                Spacer()
                Button { contextExpanded = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(WandQuietButtonStyle()).accessibilityLabel("关闭派发设置")
            }
            if dispatch {
                Picker("项目", selection: $workspaceID) {
                    Text("选择项目").tag("")
                    ForEach(contactProjectCandidates(store.projects)) { Text($0.name).tag($0.id) }
                }.frame(minHeight: 44)
            }
            Text("工作目录（可选）").font(.caption).foregroundStyle(Theme.textSecondary)
            TextField("沿用当前目录", text: $cwd).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 12).frame(minHeight: 44).wandInputSurface(focused: false).accessibilityLabel("工作目录，可选")
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private func send() {
        closeComposerActions()
        guard !composing else { return }
        store.send(id, target: target, dispatch: dispatch, workspaceID: workspaceID, cwd: cwd,
                   executionPreference: preferenceEligible ? store.executionPreference(for: id, employeeID: detail.peerEmployeeId) : nil)
        contextExpanded = false
    }
    private func perform(_ name: String) {
        guard let target else { return }
        action.submit({ try await store.service.conversationPost(path: "/api/conversations/" + store.api.percentEncodePathComponent(id) + "/actions", body: ["target": target.body, "action": name]) }, accepted: { _ in Task { await store.load(id) } })
    }
}

/// DM-only, page-scoped override of the employee's first candidate. Mirrors Android's
/// three separate pickers; the selection lives in ConversationStore so composer rebuilds,
/// focus changes and polling cannot silently reset it.
private struct ConversationExecutionSettings: View {
    @ObservedObject var store: ConversationStore
    let conversationID: String
    let employee: SiliconEmployee
    @ObservedObject var focus: ComposerFocusController
    var disabled = false
    @State private var picker: Picker?
    @State private var catalog: ModelsResponse?
    @State private var loading = false
    @State private var loadError: String?
    @State private var requestedCatalog = false

    private enum Picker: String, Identifiable {
        case tool, model, thinking
        var id: String { rawValue }
    }
    private var preference: ConversationExecutionPreference? {
        store.executionPreference(for: conversationID, employeeID: employee.id)
    }
    private var defaultPreference: ConversationExecutionPreference? {
        guard let candidate = employee.agents.first else { return nil }
        return ConversationExecutionPreference(
            provider: candidate.provider,
            engine: candidate.engine,
            model: candidate.model,
            thinkingEffort: candidate.thinkingEffort
        )
    }
    private var effective: ConversationExecutionPreference? { preference ?? defaultPreference }
    private var tool: WandAgentTool? {
        effective.map { WandAgentTool(provider: $0.provider, engine: $0.engine) }
    }
    private var provider: WandProvider { tool?.provider ?? .claude }
    private var models: [ModelInfo] { catalog?.models(for: provider) ?? [] }
    private var defaultModelID: String { catalog?.defaultModelId(for: provider.rawValue) ?? "" }
    private var thinkingOptions: [ThinkingEffortOption] {
        thinkingEffortOptions(provider: provider.rawValue, selectedModel: effective?.model,
            defaultModel: defaultModelID, models: models,
            providerEfforts: catalog?.thinkingEfforts(for: provider.rawValue) ?? [])
    }
    private var toolLabel: String { tool.map(toolTitle) ?? "员工默认" }
    private var selectedModelID: String {
        let model = effective?.model ?? ""
        return model.isEmpty ? "default" : model
    }
    private var modelLabel: String {
        guard selectedModelID != "default" else { return "默认模型" }
        return models.first { $0.id == selectedModelID }?.label ?? selectedModelID
    }
    private var thinkingLabel: String {
        thinkingOptions.first { $0.id == effective?.thinkingEffort }?.label ?? "自动"
    }
    private func toolTitle(_ tool: WandAgentTool) -> String { tool == .pi ? "Pi CLI" : tool.title }
    var body: some View {
        HStack(spacing: 4) {
            ComposerSettingsStrip(model: modelLabel, mode: toolLabel, thinking: thinkingLabel,
                onModel: { open(.model) }, onMode: { open(.tool) }, onThinking: { open(.thinking) },
                modeName: "执行工具", modeSymbol: "wrench.and.screwdriver")
            if preference != nil {
                Button {
                    store.setExecutionPreference(nil, for: conversationID, employeeID: employee.id)
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 15))
                        .frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("恢复员工默认")
                .accessibilityHint("清除本页对执行工具、模型和思考深度的临时覆盖")
                .accessibilityIdentifier("dm-execution-reset")
            }
        }
        .disabled(disabled)
        .sheet(item: $picker, onDismiss: { focus.resume("settings") }) { selection in
            sheet(selection)
        }
        .onAppear { loadModels() }
    }
    private func open(_ selection: Picker) {
        focus.borrow("settings", open: true); picker = selection
    }
    @ViewBuilder private func sheet(_ selection: Picker) -> some View {
        switch selection {
        case .tool:
            SearchableChoiceSheet(title: "本页执行工具", sections: [
                SearchableChoiceSection(id: "tool",
                    items: WandAgentTool.allCases.map { SearchableChoiceItem(id: $0.rawValue, label: toolTitle($0)) },
                    selectedId: tool?.rawValue ?? ""),
            ]) { _, value in
                guard let tool = WandAgentTool(rawValue: value) else { return }
                update(provider: tool.provider.rawValue, engine: tool.engine, model: "default", thinking: "off")
            }
        case .model:
            SearchableChoiceSheet(title: "本页模型", sections: [
                SearchableChoiceSection(id: "model", items: modelItems, selectedId: selectedModelID, searchable: true),
            ], notice: loading ? "正在加载模型目录…" : loadError,
               onRetry: loadError == nil ? nil : { reloadModels() }) { _, value in
                update(model: value)
            }
        case .thinking:
            SearchableChoiceSheet(title: "本页思考深度", sections: [
                SearchableChoiceSection(id: "thinking",
                    items: thinkingOptions.map { SearchableChoiceItem(id: $0.id, label: $0.menuLabel) },
                    selectedId: effective?.thinkingEffort ?? "off"),
            ]) { _, value in
                update(thinking: value)
            }
        }
    }
    private var modelItems: [SearchableChoiceItem] {
        var items = [SearchableChoiceItem(id: "default", label: "默认模型")]
        items += models.filter { $0.id != "default" }.map { SearchableChoiceItem(id: $0.id, label: $0.label) }
        if selectedModelID != "default", !items.contains(where: { $0.id == selectedModelID }) {
            items.append(SearchableChoiceItem(id: selectedModelID, label: selectedModelID))
        }
        return items
    }
    private func update(provider nextProvider: String? = nil, engine nextEngine: String? = nil,
                        model nextModel: String? = nil, thinking nextThinking: String? = nil) {
        guard let current = effective else { return }
        let provider = nextProvider ?? current.provider
        let engine = nextProvider == nil ? current.engine : nextEngine
        let model = nextModel ?? current.model
        var thinking = nextThinking ?? current.thinkingEffort
        if nextModel != nil, nextProvider == nil, thinking != "off",
           let options = dynamicThinkingEffortOptions(provider: provider, selectedModel: model,
                defaultModel: defaultModelID, models: models,
                providerEfforts: catalog?.thinkingEfforts(for: provider) ?? []),
           !options.contains(where: { $0.id == thinking }) {
            thinking = "off"
        }
        store.setExecutionPreference(ConversationExecutionPreference(
            provider: provider, engine: engine, model: model, thinkingEffort: thinking
        ), for: conversationID, employeeID: employee.id)
    }
    private func loadModels(force: Bool = false) {
        guard (force || !requestedCatalog), !loading else { return }
        requestedCatalog = true
        loading = true
        loadError = nil
        Task {
            do {
                let value = try await store.api.models()
                guard !Task.isCancelled else { return }
                catalog = value
            } catch {
                if !Task.isCancelled { loadError = "模型目录加载失败：\(error.localizedDescription)" }
            }
            loading = false
        }
    }
    private func reloadModels() {
        guard !loading else { return }
        loadModels(force: true)
    }
}

private struct ConversationRunActionButton: View {
    @ObservedObject var operation: ConversationOperation
    let title: String
    let action: () -> Void
    var body: some View {
        VStack {
            Button(action: action) {
                Text(operation.phase == .sending ? "处理中" : operation.phase == .sent ? "已接受" : operation.phase == .failed ? "失败" : title)
                    .frame(maxWidth: .infinity).frame(height: 44)
            }.buttonStyle(.borderedProminent).disabled(!operation.canSubmit)
            if let message = operation.message { Text(message).font(.caption) }
        }
    }
}
