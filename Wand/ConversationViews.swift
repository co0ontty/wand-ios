import SwiftUI
import UniformTypeIdentifiers

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
        store.items.filter { tier.contains($0) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || $0.preview.localizedCaseInsensitiveContains(query) || $0.tasks.contains { $0.task.title.localizedCaseInsensitiveContains(query) }) }
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
                    Text(error).font(.caption).foregroundStyle(Theme.danger).listRowBackground(Color.clear)
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
                if rows.isEmpty && !store.loading { Text("暂无对话").foregroundStyle(Theme.textSecondary).listRowBackground(Color.clear) }
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
                messageList(detail)
                ConversationComposerView(id: id, store: store, detail: detail, target: store.targets[id], onEmployee: onEmployee)
                    .id(store.draftKey(id, target: store.targets[id]))
            } else {
                Spacer()
                if let error = store.error { Text(error).foregroundStyle(Theme.danger); Button("重试") { Task { await store.load(id) } } }
                else { ProgressView() }
                Spacer()
            }
        }
        .background(Theme.background)
        .navigationTitle(detail?.title ?? "聊天").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let employee = detail?.peerEmployeeId { Button("员工资料") { onEmployee(employee) } }
                    if detail?.kind == "group" {
                        Button(members ? "收起成员" : "成员") { members.toggle(); inviting = false }
                        Button("邀请成员") { inviting.toggle(); members = false }
                        Button(tasks ? "收起任务" : "任务与执行") { tasks.toggle() }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("对话菜单")
            }
        }
        .task(id: id) { store.select(id); await store.load(id) }
        .onDisappear { inviting = false }
        .animation(reduced ? nil : WandMotion.stateSwap, value: members)
        .animation(reduced ? nil : WandMotion.stateSwap, value: tasks)
        .animation(reduced ? nil : WandMotion.stateSwap, value: inviting)
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
            .onScrollPhaseChange { _, phase in userScrolling = phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height || geometry.contentSize.height - geometry.visibleRect.maxY < 40
            } action: { _, atBottom in if userScrolling || atBottom { scrollPinned = atBottom } }
            .onChange(of: messages.map(\.renderRevision)) { _, _ in
                if scrollPinned { proxy.scrollTo("im-tail", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !scrollPinned { Button { scrollPinned = true; proxy.scrollTo("im-tail", anchor: .bottom) } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44).background(Theme.surface, in: Circle()) }.accessibilityLabel("回到最新消息").padding(12) }
            }
        }
    }
    @ViewBuilder private func messageView(_ message: ConversationMessage, detail: ConversationInstance) -> some View {
        if message.notice == true {
            Text(conversationTurnPreview(message.turn)).font(.caption).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
        } else if let link = message.sessionLink {
            ConversationReplyCard(message: message, api: store.api, execution: store.executionStore(link.sessionId)) { onOpenSession(link.sessionId) }
        } else if let link = message.conversationLink {
            VStack(alignment: .leading, spacing: 8) {
                Text(link.title).font(.headline)
                Text(message.taskPreview?.label ?? "准备中").font(.caption).foregroundStyle(Theme.textSecondary)
                ScrollView { Text(message.taskPreview?.text.isEmpty == false ? message.taskPreview!.text : "等待任务输出").font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 152).clipped()
                Button("查看任务") { store.openTask(link, preview: message.taskPreview); onOpenConversation(link.conversationId) }.disabled(message.taskPreview?.status == "unavailable")
            }.padding(12).frame(maxWidth: 420).frame(height: 232).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        } else if let file = message.reportFile {
            ConversationReportCard(file: file, api: store.api)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if detail.kind == "group", message.turn.role != "user", let author = message.author {
                    Button(author.name ?? "成员") {
                        if let employee = detail.team?.members.first(where: { $0.id == author.id })?.employeeId { onEmployee(employee) }
                    }.font(.caption.weight(.semibold)).frame(minHeight: 32)
                }
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
    @State private var pinned = true
    @State private var userScrolling = false
    private var text: String { message.sessionPreview?.text ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message.sessionLink?.title ?? "会话").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(message.sessionPreview?.label ?? "准备中").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(text.isEmpty ? "等待会话输出" : text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        Color.clear.frame(height: 1).id("preview-tail")
                    }
                }
                .onScrollPhaseChange { _, phase in userScrolling = phase == .interacting || phase == .decelerating }
                .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height <= $0.containerSize.height || $0.contentSize.height - $0.visibleRect.maxY < 24 } action: { _, value in if userScrolling || value { pinned = value } }
                .onChange(of: text) { _, _ in if pinned { proxy.scrollTo("preview-tail", anchor: .bottom) } }
            }.frame(maxHeight: .infinity).clipped()
            Button("查看会话", action: onOpen).frame(minHeight: 44).disabled(message.sessionPreview?.status == "unavailable")
        }.padding(12).frame(maxWidth: 420).frame(height: 232).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        SessionProtocolPanel(store: execution)
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
    @State private var focused = false
    @State private var composing = false
    @State private var height: CGFloat = 36
    @State private var workspaceID = ""
    @State private var cwd = ""
    @State private var notice: String?
    @State private var draftConsumer = UUID()
    @State private var visible = false
    @StateObject private var speech = SpeechRecognizerService()
    @StateObject private var keyboard = KeyboardObserver()
    @State private var voiceHolding = false
    @State private var voiceCanceling = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    init(id: String, store: ConversationStore, detail: ConversationInstance, target: ConversationTarget?, onEmployee: @escaping (String) -> Void) {
        self.id = id; self.store = store; self.detail = detail; self.target = target; self.onEmployee = onEmployee
        let draft = store.composer(id, target: target)
        _draft = ObservedObject(wrappedValue: draft); _attachments = ObservedObject(wrappedValue: draft.attachments)
        _action = ObservedObject(wrappedValue: store.operation("action:" + id + ":" + (target?.runId ?? "talk")))
    }
    private var dispatch: Bool { store.dispatchIntent.contains(id) }
    private var run: ContactRunDetail? { detail.runDetails.first { $0.run.id == target?.runId } }
    private var execution: ChatStore? { (run?.run.chatSessionId ?? detail.communicationSessionId).map { store.executionStore($0) } }
    private var running: Bool { target != nil ? ["running", "awaiting_approval", "waiting_user"].contains(run?.run.status ?? "") : execution?.isResponding == true }
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
            if voiceHolding || speech.isRecording || speech.isProcessing {
                Text(voiceCanceling ? "松开取消" : speech.isProcessing ? "服务端识别中…" : speech.transcript.isEmpty ? "正在聆听…松开完成，上滑取消" : speech.transcript)
                    .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !attachments.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack { ForEach(attachments.attachments, id: \.savedPath) { file in Button { attachments.remove(file) } label: { Label(file.originalName, systemImage: "xmark.circle").font(.caption) } } }
                }
            }
            if menu {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("附件") { attachments.showFileImporter = true; menu = false }
                        Button("照片") { attachments.showPhotoPicker = true; menu = false }
                        Button(dispatch ? "取消派发" : "派发任务") { if dispatch { store.dispatchIntent.remove(id); menu = false } else { store.dispatchIntent.insert(id) } }
                    }
                    if detail.kind == "group", let leader = detail.leader { Button("@" + leader.name) { draft.text += "@" + leader.name + " "; menu = false; focused = true } }
                    if dispatch {
                        Picker("项目", selection: $workspaceID) {
                            Text("选择项目").tag("")
                            ForEach(contactProjectCandidates(store.projects)) { Text($0.name).tag($0.id) }
                        }
                    }
                    TextField("工作目录（可选）", text: $cwd).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let employee = detail.peerEmployeeId { Button("员工执行配置") { menu = false; onEmployee(employee) } }
                }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(alignment: .bottom, spacing: 4) {
                ContactMorphButton(expanded: menu, symbol: "plus", label: menu ? "关闭操作" : "更多操作") { menu.toggle() }
                ComposerVoiceControl(draft: draft, speech: speech) { notice = $0 }
                IMEAwareComposerTextView(text: $draft.text, placeholder: composerHoldToTalkEligible(text: draft.text, focused: focused, keyboardVisible: keyboard.isVisible) ? "发消息或按住说话" : dispatch ? "任务说明" : "消息", isFocused: focused,
                    onPasteImages: attachments.handlePastedImageData, onFocusChange: { focused = $0 }, onCompositionChange: { composing = $0 },
                    onSubmit: send, onHeightChange: { height = $0 })
                    .frame(height: min(max(height, 36), ComposerMetrics.expandedInputMaxHeight))
                    .overlay {
                        if composerHoldToTalkEligible(text: draft.text, focused: focused, keyboardVisible: keyboard.isVisible) {
                            ComposerVoiceControl(draft: draft, speech: speech, inputSurface: true, onTap: { focused = true },
                                onPressChanged: { voiceHolding = $0; voiceCanceling = $1 }) { notice = $0 }
                        }
                    }
                NativeComposerActionButton(phase: action.phase == .idle ? draft.sendPhase : action.phase, turnRunning: running,
                    hasDraft: !draft.text.isEmpty || !attachments.attachments.isEmpty,
                    canSubmit: composerDraftIsSendable(draft.text, hasAttachments: !attachments.attachments.isEmpty, isComposing: composing)
                        && !attachments.isUploading && !store.hasUnknown(id, target: target) && detail.dissolvedAt == nil && !detail.deleting,
                    message: action.message ?? draft.sendFeedback, onSend: send, onStop: { if target != nil { perform("stop") } else { execution?.stopResponding() } })
            }
        }.padding(10).background(Theme.elevated)
        .animation(reduced ? nil : WandMotion.stateSwap, value: menu)
        .onAppear { if !visible { draft.acquire(draftConsumer) }; visible = true; attachments.setToastHandler { notice = $0 } }
        .onDisappear { menu = false; speech.stop(cancelled: true); if visible { draft.release(draftConsumer) }; visible = false }
        .fileImporter(isPresented: $attachments.showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: attachments.handleFileSelection)
        .sheet(isPresented: $attachments.showPhotoPicker) { PhotoLibraryPicker { attachments.showPhotoPicker = false; attachments.handlePhotoSelection($0) } }
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
