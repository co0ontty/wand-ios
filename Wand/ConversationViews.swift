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
    @State private var searching = false
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
        case .search: query = ""; searchFocused = searching
        case .filtered: query = ""; tier = .all; searchFocused = false
        case .historyOnly: tier = .dissolved; searchFocused = false
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if creationOpen {
                ConversationGroupPanel(store: store, context: store.creatingPresetID.map { "preset:" + $0 } ?? "create", inviteTo: nil, templateID: store.creatingPresetID,
                    onClose: { creating = false; store.creatingPresetID = nil }, onAccepted: { creating = false; store.creatingPresetID = nil; onSelect($0) })
                    .padding(.horizontal, 12)
                    .transition(.opacity.combined(with: reduced ? .identity : .move(edge: .top)))
            }
            Picker("对话筛选", selection: $tier) { ForEach(ConversationListTier.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, 12).padding(.bottom, 8)
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
                        .contextMenu {
                            Button(item.pinnedAt == nil ? "置顶" : "取消置顶") { Task { await store.update(item.id, patch: ["pinned": item.pinnedAt == nil]) } }
                            if item.kind == "group" { Button(item.dissolvedAt == nil ? "解散" : "恢复") { Task { await store.update(item.id, patch: ["dissolved": item.dissolvedAt == nil]) } } }
                            Button("多选") { selecting = true; selected.insert(item.id) }
                            Button("删除", role: .destructive) { deleteIDs = [item.id] }
                        }
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
                }.padding(12)
            }
        }
        .animation(reduced ? nil : WandMotion.stateSwap, value: creating)
        .alert("删除对话？", isPresented: Binding(get: { !deleteIDs.isEmpty }, set: { if !$0 { deleteIDs = [] } })) {
            Button("取消", role: .cancel) { deleteIDs = [] }
            Button("删除", role: .destructive) { batchDelete() }
        } message: { Text("删除其所属执行会话和群任务资源；不会删除其他对话或工作区。") }
    }
    private var header: some View {
        HStack(spacing: 4) {
            Button(action: onSwitchServer) { WandBrandMark(size: 26).frame(width: 44, height: 44) }.accessibilityLabel("切换服务器")
            if searching {
                TextField("搜索对话与任务", text: $query).focused($searchFocused).textInputAutocapitalization(.never)
                    .transition(.opacity)
            } else { Text("聊天").font(.headline).frame(maxWidth: .infinity, alignment: .leading) }
            ContactMorphButton(expanded: searching, symbol: "magnifyingglass", label: searching ? "关闭搜索" : "搜索") {
                searching.toggle(); searchFocused = searching
                if !searching { query = "" }
            }
            ContactMorphButton(expanded: creationOpen, symbol: "plus", label: creationOpen ? "关闭建群" : "建群") { if creationOpen { creating = false; store.creatingPresetID = nil } else { creating = true }; searchFocused = false }
            Menu {
                Button("多选") { selecting = true }
                Button("刷新") { Task { await store.refresh() } }
                Button("设置", action: onSettings)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("聊天菜单")
        }.padding(.horizontal, 8).frame(minHeight: 52)
            .animation(reduced ? nil : WandMotion.stateSwap, value: searching)
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
                        Text(item.title).font(.body.weight(.semibold)).lineLimit(1)
                        Spacer()
                        if item.pinnedAt != nil { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                    Text(item.unavailableReason ?? item.preview).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    if item.kind == "group" { Text("\(item.team?.members.count ?? 0) 人 · \(item.tasks.count) 项任务").font(.caption).foregroundStyle(Theme.textSecondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.vertical, 4).listRowBackground(Theme.surface)
    }
    private func batchPin(_ pin: Bool) {
        batchBusy = true
        Task { for id in selected { await store.update(id, patch: ["pinned": pin]) }; batchBusy = false }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(inviteTo == nil ? "建群" : "邀请成员").font(.headline); Spacer(); Button("取消", action: onClose) }
                Picker("团队预设", selection: $draft.templateId) {
                    Text("从通讯录选择").tag("")
                    ForEach(store.presets) { Text($0.name).tag($0.id) }
                }
                ForEach(store.employees.filter { !$0.archived }) { employee in
                    Toggle(employee.name, isOn: Binding(get: { draft.employeeIds.contains(employee.id) }, set: { value in
                        if value { draft.employeeIds.insert(employee.id) } else { draft.employeeIds.remove(employee.id) }
                    }))
                }
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(member.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("移除") { draft.employeeIds.remove(member.employeeId ?? member.id); draft.excludedMemberIds.insert(member.id) }
                        }
                        TextField("本群职责", text: Binding(get: { draft.duties[member.employeeId ?? member.id] ?? member.duty }, set: { draft.duties[member.employeeId ?? member.id] = $0 }), axis: .vertical)
                            .lineLimit(1...3).textFieldStyle(.roundedBorder)
                    }
                }
                if inviteTo == nil {
                    Picker("负责人", selection: $draft.leaderId) {
                        Text("按预设").tag("")
                        ForEach(members) { Text($0.name).tag($0.employeeId ?? $0.id) }
                    }
                    TextField("群名（可选）", text: $draft.name).textFieldStyle(.roundedBorder)
                }
                Text("\(total)/8 位成员").font(.caption).foregroundStyle(total > 8 || invalid ? Theme.danger : Theme.textSecondary)
                if invalid { Text("请处理不可用成员或超长职责。").font(.caption).foregroundStyle(Theme.danger) }
                if let message = operation.message { Text(message).font(.caption).foregroundStyle(operation.phase == .failed ? Theme.danger : Theme.textSecondary) }
                HStack {
                    if operation.unknownRequest != nil { Button("核对请求") { operation.reconcile(service: store.service, accepted: accept) } }
                    if let receipt = operation.receipt { Button("打开已建立的群") { accept(receipt) } }
                    Spacer()
                    Button(action: submit) {
                        HStack {
                            Text(operation.phase == .sending ? "处理中" : operation.phase == .sent ? "已完成" : operation.phase == .failed ? "失败" : inviteTo == nil ? "建群" : "邀请")
                            if operation.phase == .sending { ProgressView().controlSize(.small) }
                        }.frame(width: 96, height: 44)
                    }.buttonStyle(.borderedProminent).disabled(!operation.canSubmit || members.isEmpty || total > 8 || invalid)
                }
            }.padding(12)
        }.frame(maxHeight: 340).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .onChange(of: draft) { _, value in store.groupDrafts[context] = value }
            .onAppear { visible = true }.onDisappear { visible = false }
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
    @StateObject private var voice = DraftVoiceController()
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
    @Environment(\.accessibilityReduceMotion) private var reduced
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
                messageList(detail).clipped()
                    .overlay {
                        if messages.isEmpty {
                            ContentUnavailableView(
                                (store.filters[id] ?? "").isEmpty ? "还没有消息" : "此任务暂无消息",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text(detail.dissolvedAt == nil ? "消息会显示在这里，你也可以直接开始沟通。" : "群聊已解散，恢复后可继续沟通。"))
                        }
                    }
                    .onTapGesture { composerFocus.collapse() }
                ConversationComposerView(id: id, store: store, detail: detail, target: store.targets[id], focus: composerFocus, voice: voice, onEmployee: onEmployee)
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
        .padding(.top, ChatTopLayout.clearance(compact: verticalSizeClass == .compact))
        .background(Theme.background)
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
        .onDisappear { inviting = false; voice.finish(cancelled: true); composerFocus.collapse(); messageLinks.cancel() }
        .animation(reduced ? nil : WandMotion.stateSwap, value: members)
        .animation(reduced ? nil : WandMotion.stateSwap, value: tasks)
        .animation(reduced ? nil : WandMotion.stateSwap, value: inviting)
    }
    private var navigation: some View {
        ZStack(alignment: .top) {
            TopChatCompanion(side: CatComposerSide(rawValue: sideRaw) ?? .left, dragOffset: dragOffset) { size in
                if let detail {
                    let employee = store.employees.first { $0.id == detail.peerEmployeeId }
                    let session = detail.messages.last(where: { $0.sessionPreview?.active == true })?.sessionLink?.sessionId ?? detail.communicationSessionId
                    ConversationCompanionFace(employee: employee, detail: detail, execution: session.map { store.executionStore($0) }, size: size)
                        .overlay { Color.clear.modifier(voice.gesture(draft: store.composer(id, target: store.targets[id]), focus: composerFocus,
                            onDrag: { dragOffset = $0 }, onDrop: { offset in
                                sideRaw = (CatComposerSide(rawValue: sideRaw) ?? .left).dropped(translation: offset).rawValue; dragOffset = 0
                            })) }
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
                    Menu("猫头位置") {
                        Button("控件间居中") { sideRaw = CatComposerSide.left.rawValue }
                        Button("向右微移") { sideRaw = CatComposerSide.right.rawValue }
                    }
                } label: { FloatingChatIcon(symbol: "ellipsis") }.accessibilityLabel("对话菜单")
            }.padding(.top, verticalSizeClass == .compact ? 0 : 18)
        }
    }
    private func messageList(_ detail: ConversationInstance) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { _, message in
                        messageView(message, detail: detail).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("im-tail")
                }.padding(12).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
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
                if old != new, scrollPinned, !userScrolling {
                    proxy.scrollTo("im-tail", anchor: .bottom)
                }
            }
            .onChange(of: messages.map(\.renderRevision)) { _, _ in
                if scrollPinned { proxy.scrollTo("im-tail", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !scrollPinned { Button { scrollPinned = true; proxy.scrollTo("im-tail", anchor: .bottom) } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44).background(Theme.surface, in: Circle()) }.accessibilityLabel("回到最新消息").padding(12) }
            }
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
    @State private var menu = false
    @ObservedObject var focus: ComposerFocusController
    @ObservedObject var voice: DraftVoiceController
    @StateObject private var links = ServerFileLinkController()
    @State private var settingsInfo = false
    @State private var pendingAttachment: String?
    @State private var pendingStop = false
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
    init(id: String, store: ConversationStore, detail: ConversationInstance, target: ConversationTarget?, focus: ComposerFocusController, voice: DraftVoiceController, onEmployee: @escaping (String) -> Void) {
        self.id = id; self.store = store; self.detail = detail; self.target = target; self.focus = focus; self.voice = voice; self.onEmployee = onEmployee
        let draft = store.composer(id, target: target)
        _draft = ObservedObject(wrappedValue: draft); _attachments = ObservedObject(wrappedValue: draft.attachments)
        _action = ObservedObject(wrappedValue: store.operation("action:" + id + ":" + (target?.runId ?? "talk")))
    }
    private var dispatch: Bool { store.dispatchIntent.contains(id) }
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
                    Spacer(); Button("取消") { store.dispatchIntent.remove(id); store.targets[id] = nil; menu = false }
                }
            }
            if run?.run.status == "awaiting_approval" {
                ConversationRunActionButton(operation: action, title: "同意计划并开工") { perform("approve") }
            }
            if store.hasUnknown(id, target: target) { Button("核对送达状态") { store.reconcileComposer(id, target: target) } }
            if action.unknownRequest != nil { Button("核对运行操作") { action.reconcile(service: store.service, accepted: { _ in Task { await store.load(id) } }) } }
            if let notice { Text(notice).font(.caption).foregroundStyle(Theme.textSecondary) }
            if voice.holding || voice.speech.isProcessing || voice.notice != nil {
                Text(voice.cancelling ? "松开取消" : voice.speech.isProcessing ? "转写中…" : voice.notice ?? "正在听 · 上滑取消").font(.caption)
            }
            FocusComposerSurface(expanded: expanded, hasDraft: !draft.text.isEmpty || !attachments.attachments.isEmpty,
                onFocus: { focus.focus() }, editor: {
                    VStack(spacing: 4) {
                        PendingAttachmentsPreview(baseURL: store.api.baseURL, attachments: attachments.attachments, onRemove: attachments.remove,
                            onPreview: { file in focus.borrow("preview", open: true); links.open(serverPath: file.savedPath, api: store.api) })
                        if draft.submissionFailed, let feedback = draft.sendFeedback { Text(feedback).font(.caption).foregroundStyle(Theme.danger) }
                        IMEAwareComposerTextView(text: $draft.text, placeholder: dispatch ? "任务说明" : "输入消息，回车换行", isFocused: focus.focused,
                            maximumHeight: maximumHeight, submitOnReturn: false, onPasteImages: attachments.handlePastedImageData,
                            onFocusChange: { focus.focused = $0 }, onCompositionChange: { composing = $0 }, onSubmit: send, onHeightChange: { height = $0 })
                            .frame(height: min(maximumHeight, max(34, height)))
                    }
                }, add: {
                    Button { focus.borrow("menu", open: true); menu = true } label: { Image(systemName: "plus").frame(width: 48, height: 48) }.accessibilityLabel("添加附件与对话操作")
                }, voice: {
                    Image(systemName: voice.holding ? "waveform" : "mic").frame(width: 48, height: 48)
                        .modifier(voice.gesture(draft: draft, focus: focus)).accessibilityLabel("语音输入")
                }, send: {
                        NativeComposerActions(phase: composerPhase,
                            turnRunning: running && !dispatch, hasDraft: hasComposerDraft,
                            canSubmit: !voice.holding && !voice.speech.isProcessing && composerDraftIsSendable(draft.text, hasAttachments: !attachments.attachments.isEmpty, isComposing: composing)
                                && !attachments.isUploading && !store.hasUnknown(id, target: target) && action.canSubmit && detail.dissolvedAt == nil && !detail.deleting,
                            canStop: action.canSubmit,
                            message: action.message ?? draft.sendFeedback, sendLabel: dispatch ? "确认派发任务" : running ? "继续发送" : "发送消息",
                            onSend: send, onStop: { if action.canSubmit { stopConfirm = true } })
                }, settings: {
                    if let execution, !dispatch, target != nil || detail.kind == "group" { SessionComposerSettings(store: execution, focus: focus) }
                    else {
                        Button { focus.borrow("settings", open: true); settingsInfo = true } label: {
                            ComposerSettingLabel(title: store.employees.first(where: { $0.id == (detail.peerEmployeeId ?? detail.leader?.employeeId) })?.agents.first.map {
                                $0.model == "default" ? "默认模型" : $0.model
                            } ?? "员工配置")
                        }.buttonStyle(.plain).accessibilityHint("查看真实配置与生效范围")
                    }
                }, actionCount: ComposerActionPresentation(phase: composerPhase,
                    turnRunning: running && !dispatch, hasDraft: hasComposerDraft).slotCount)
        }
        .onAppear { if !visible { draft.acquire(draftConsumer) }; visible = true; attachments.setToastHandler { notice = $0 } }
        .onDisappear { menu = false; voice.finish(cancelled: true); if visible { draft.release(draftConsumer) }; visible = false }
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
        .sheet(isPresented: $menu, onDismiss: {
            focus.resume("menu")
            if pendingStop { pendingStop = false; stopConfirm = true }
            if let pendingAttachment {
                self.pendingAttachment = nil
                if pendingAttachment == "file" { attachments.showFileImporter = true }
                else { attachments.showPhotoPicker = true }
            }
        }) { menuSheet }
        .sheet(isPresented: $settingsInfo, onDismiss: { focus.resume("settings") }) {
            NavigationStack {
                List {
                    Text("这里展示员工默认配置，影响后续新工作。私聊每条消息按员工候选新建会话，尚不支持只覆盖本条消息的模型、权限或思考深度；不会修改历史会话。")
                    if let employee = store.employees.first(where: { $0.id == (detail.peerEmployeeId ?? detail.leader?.employeeId) }) {
                        ForEach(Array(employee.agents.enumerated()), id: \.offset) { index, candidate in
                            VStack(alignment: .leading) {
                                Text("候选 \(index + 1) · \(candidate.provider) · \(candidate.model)")
                                Text("权限：\(composerModeName(candidate.mode)) · 思考：\(composerThinkingName(candidate.thinkingEffort))").font(.caption)
                            }
                        }
                        Button("查看员工执行配置（影响后续消息）") { settingsInfo = false; focus.collapse(); onEmployee(employee.id) }
                    }
                }.navigationTitle("当前输入的执行设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settingsInfo = false } } }
            }
        }
        .confirmationDialog("停止当前任务？", isPresented: $stopConfirm, titleVisibility: .visible) {
            Button("停止", role: .destructive) { if target != nil { perform("stop") } else { execution?.stopResponding() } }
        }
    }
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    private var maximumHeight: CGFloat { max(typeSize.isAccessibilitySize ? 80 : 0, composerMaximumInputHeight(compact: verticalSizeClass == .compact, keyboardVisible: keyboard.isVisible)) }
    private var expanded: Bool { focus.editing || focus.focused || draft.submissionFailed || store.hasUnknown(id, target: target) }
    private var menuSheet: some View {
        NavigationStack {
                VStack(alignment: .leading, spacing: 8) {
                    if running {
                        Button("停止当前任务", role: .destructive) { pendingStop = true; menu = false }
                            .disabled(!action.canSubmit || draft.sendPhase == .sending)
                    }
                    HStack {
                        Button("附件") { focus.borrow("attachment", open: true); pendingAttachment = "file"; menu = false }
                        Button("照片") { focus.borrow("attachment", open: true); pendingAttachment = "photo"; menu = false }
                        Button(dispatch ? "取消派发" : "派发任务") { if dispatch { store.dispatchIntent.remove(id); menu = false } else { store.dispatchIntent.insert(id) } }
                    }
                    if detail.kind == "group", let leader = detail.leader { Button("@" + leader.name) { draft.text += "@" + leader.name + " "; menu = false; focus.focus() } }
                    if dispatch {
                        Picker("项目", selection: $workspaceID) {
                            Text("选择项目").tag("")
                            ForEach(contactProjectCandidates(store.projects)) { Text($0.name).tag($0.id) }
                        }
                    }
                    TextField("工作目录（可选）", text: $cwd).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let employee = detail.peerEmployeeId { Button("员工执行配置") { menu = false; onEmployee(employee) } }
                }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .navigationTitle("附件与对话操作")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { menu = false } } }
        }.presentationDetents([.medium, .large])
    }
    private func send() {
        guard !composing else { return }
        store.send(id, target: target, dispatch: dispatch, workspaceID: workspaceID, cwd: cwd)
        menu = false
    }
    private func perform(_ name: String) {
        guard let target else { return }
        action.submit({ try await store.service.conversationPost(path: "/api/conversations/" + store.api.percentEncodePathComponent(id) + "/actions", body: ["target": target.body, "action": name]) }, accepted: { _ in Task { await store.load(id) } })
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
