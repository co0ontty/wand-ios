import SwiftUI

@MainActor
final class ContactTeamProfileStore: ObservableObject {
    @Published var draft = ContactTeamDraft() {
        didSet {
            draftRevision += 1
            if phase != .sending && !creationUnconfirmed { phase = .idle; message = nil }
        }
    }
    private var draftRevision = 0
    private var savedDraft: ContactTeamDraft?
    @Published private(set) var team: ContactTeam?
    @Published private(set) var runs: [ContactTeamRun] = []
    @Published private(set) var ready: Bool
    @Published private(set) var loading = false
    @Published private(set) var catalog: ModelsResponse?
    @Published private(set) var phase = ComposerSendPhase.idle
    @Published private(set) var message: String?
    @Published private(set) var creationUnconfirmed = false
    @Published var note = "" { didSet { noteRevision += 1 } }
    @Published var selectedWorkspaceID = ""
    @Published private(set) var startPhase = ComposerSendPhase.idle
    @Published private(set) var startMessage: String?
    private var noteRevision = 0
    private let id: String?
    private let service: any ContactTeamService
    private var generation = 0
    private var active = true
    init(id: String?, api: WandAPI, service: (any ContactTeamService)? = nil) {
        self.id = id; self.service = service ?? api; ready = id == nil
        if id == nil { savedDraft = ContactTeamDraft() }
    }
    var busy: Bool { phase == .sending || startPhase == .sending }
    var hasUnsavedChanges: Bool { savedDraft.map { draft != $0 } ?? false }
    func close() { active = false; generation += 1; loading = false }
    func load() async {
        guard !busy else { return }
        active = true; generation += 1; let request = generation; let revision = draftRevision
        loading = true
        async let models = try? service.models()
        do {
            if let id = team?.id ?? id {
                let info = try await service.contactTeam(id)
                guard active, request == generation, !Task.isCancelled else { return }
                guard info.team.id == id else { throw WandAPI.APIError.network("团队资料身份不一致") }
                let replaceDraft = !ready || (!hasUnsavedChanges && revision == draftRevision)
                team = info.team; runs = info.runs
                if replaceDraft { draft = ContactTeamDraft(info.team); savedDraft = draft }
                ready = true; message = nil
            }
        } catch { if active, request == generation { message = error.localizedDescription } }
        let modelCatalog = await models
        guard active, request == generation, !Task.isCancelled else { return }
        catalog = modelCatalog; loading = false
    }
    func save(directory: ContactsStore) {
        guard active, ready, !busy, !directory.busy, !creationUnconfirmed else { return }
        if let error = draft.validationError { phase = .failed; message = error; return }
        for member in draft.members {
            if let employeeID = member.employeeId,
               !directory.employees.contains(where: { $0.id == employeeID && !$0.archived && !$0.agents.isEmpty }) {
                phase = .failed; message = "绑定员工已不可用，请刷新通讯录并替换成员。"; return
            }
        }
        let submitted = draft; let revision = draftRevision; let existing = team?.id ?? id
        generation += 1; let request = generation
        phase = .sending; message = nil; directory.editorBusy = true
        Task {
            defer { directory.editorBusy = false }
            do {
                let saved = try await service.saveContactTeam(id: existing, draft: submitted)
                guard !saved.id.isEmpty, existing == nil || existing == saved.id else { throw WandAPI.APIError.network("团队回执身份不一致") }
                guard active, request == generation else { return }
                team = saved; savedDraft = ContactTeamDraft(saved)
                let unchanged = draftRevision == revision
                if unchanged { draft = ContactTeamDraft(saved) }
                phase = .sent; message = unchanged ? "已保存" : "上一版已保存，当前新输入尚未保存。"
                directory.update(saved)
            } catch {
                guard active, request == generation else { return }
                phase = .failed
                if existing == nil && !isDefiniteInputRejection(error) {
                    creationUnconfirmed = true; directory.markUnconfirmed("new:team")
                    message = "创建结果未确认，请刷新列表核对，勿重复新建。"
                } else { message = error.localizedDescription }
            }
        }
    }
    func start(directory: ContactsStore, onOpenRun: @escaping (String) -> Void) {
        guard let team, active, !busy, !directory.busy else { return }
        let key = "team-start:" + team.id
        guard !directory.unconfirmedActions.contains(key) else { return }
        guard !hasUnsavedChanges else { startPhase = .failed; startMessage = "请先保存团队资料。"; return }
        let submitted = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty, submitted.utf16.count <= 4000 else { startPhase = .failed; startMessage = "请填写开工说明，最多4000个字符。"; return }
        let workspaceID = selectedWorkspaceID
        guard contactProjectCandidates(directory.workspaces).contains(where: { $0.id == workspaceID }) else {
            startPhase = .failed; startMessage = "项目已不可用，请重新选择项目。"; return
        }
        generation += 1; let request = generation; let revision = noteRevision
        startPhase = .sending; startMessage = nil; directory.editorBusy = true
        Task {
            defer { directory.editorBusy = false }
            do {
                let detail = try await service.startContactTeam(teamId: team.id, workspaceId: workspaceID, note: submitted)
                guard !detail.run.id.isEmpty, detail.run.teamId == team.id else { throw WandAPI.APIError.network("开工回执身份不一致") }
                guard active, request == generation else { return }
                if revision == noteRevision { note = "" }
                startPhase = .sent; startMessage = "已开工"
                // Clear the navigation lock before opening the accepted run.
                directory.editorBusy = false; onOpenRun(detail.run.id)
            } catch {
                guard active, request == generation else { return }
                startPhase = .failed
                if isDefiniteInputRejection(error) { startMessage = error.localizedDescription }
                else { directory.markUnconfirmed(key); startMessage = "开工结果未确认，请刷新运行记录核对，勿重复派发。" }
            }
        }
    }
    func delete(directory: ContactsStore, onRemoved: @escaping () -> Void) {
        guard let team, active, !busy, !directory.busy else { return }
        generation += 1; let request = generation
        phase = .sending; directory.editorBusy = true
        Task {
            defer { directory.editorBusy = false }
            do {
                try await service.deleteContactTeam(team.id)
                guard active, request == generation else { return }
                directory.removedTeam(team.id); directory.editorBusy = false; onRemoved()
            } catch {
                guard active, request == generation else { return }
                phase = .failed; message = error.localizedDescription
            }
        }
    }
}

struct ContactTeamProfilePanel: View {
    let id: String?
    let api: WandAPI
    @ObservedObject var directory: ContactsStore
    let onClose: () -> Void
    let onOpenRun: (String) -> Void
    @StateObject private var model: ContactTeamProfileStore
    @State private var confirmDelete = false
    @State private var instructionsExpanded = false
    @State private var inviteOpen = false
    @State private var replacingID: String?
    @State private var inviteQuery = ""
    @Environment(\.accessibilityReduceMotion) private var reduced
    init(id: String?, api: WandAPI, directory: ContactsStore, onClose: @escaping () -> Void, onOpenRun: @escaping (String) -> Void) {
        self.id = id; self.api = api; self.directory = directory; self.onClose = onClose; self.onOpenRun = onOpenRun
        _model = StateObject(wrappedValue: ContactTeamProfileStore(id: id, api: api))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(id == nil ? "新建 AI 团队" : "团队资料").font(.headline)
                Spacer()
                Button { Task { await model.load(); await directory.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.loading || directory.busy).accessibilityLabel("刷新团队资料与运行记录")
                Button("收起", action: onClose).disabled(directory.busy)
            }
            if model.ready {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("团队名字", text: $model.draft.name).accessibilityIdentifier("contact-team-name")
                    TextField("团队说明", text: $model.draft.description, axis: .vertical).lineLimit(2...4)
                    DisclosureGroup("协作指令", isExpanded: $instructionsExpanded) {
                        TextEditor(text: $model.draft.instructions).frame(height: 120)
                    }
                    Toggle("首个计划需批准", isOn: $model.draft.requirePlanApproval)
                    Stepper("步数上限 \(model.draft.maxSteps)", value: $model.draft.maxSteps, in: 5...200)
                    ForEach(model.draft.members.indices, id: \.self) { index in member(index) }
                    if model.draft.members.count < 8 {
                        Button(inviteOpen && replacingID == nil ? "收起邀请" : "从通讯录邀请员工") {
                            replacingID = nil; inviteQuery = ""; inviteOpen.toggle()
                        }
                    }
                    if inviteOpen { invitation }
                }.disabled(model.busy || directory.busy)
                HStack {
                    ContactActionButton(title: "保存", phase: model.phase, disabled: model.creationUnconfirmed || directory.busy) { model.save(directory: directory) }
                    if model.team != nil { Button("删除团队", role: .destructive) { confirmDelete = true }.disabled(model.busy) }
                }
                Text(model.message ?? " ").font(.caption)
                    .foregroundStyle(model.phase == .failed ? Theme.danger : Theme.success).frame(minHeight: 24)
                if model.team != nil { startPanel }
                if !model.runs.isEmpty {
                    Text("运行记录").font(.subheadline.weight(.semibold))
                    ForEach(model.runs) { run in
                        Button { onOpenRun(run.id) } label: {
                            HStack {
                                Text(run.taskTitle?.isEmpty == false ? run.taskTitle! : "任务处理群").lineLimit(1)
                                Spacer(); Text(contactRunStatus(run.status)).font(.caption)
                            }.frame(minHeight: 44)
                        }.disabled(model.busy)
                    }
                }
            } else if let message = model.message {
                Text(message).font(.caption).foregroundStyle(Theme.danger)
                Button("重试加载团队") { Task { await model.load() } }
            } else { ProgressView().frame(height: 44) }
        }
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .animation(reduced ? nil : WandMotion.stateSwap, value: instructionsExpanded)
        .animation(reduced ? nil : WandMotion.stateSwap, value: inviteOpen)
        .task {
            if let project = directory.teamWorkspace { model.selectedWorkspaceID = project.id }
            await model.load(); directory.editorDirty = model.hasUnsavedChanges
        }
        .onChange(of: model.draft) { _, _ in directory.editorDirty = model.hasUnsavedChanges }
        .onDisappear { model.close(); directory.editorDirty = false }
        .confirmationDialog("删除团队定义？运行快照和历史消息保持不变。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除团队", role: .destructive) { model.delete(directory: directory, onRemoved: onClose) }
            Button("取消", role: .cancel) {}
        }
    }
    @ViewBuilder private func member(_ index: Int) -> some View {
        let item = model.draft.members[index]
        let employee = directory.employees.first { $0.id == item.employeeId }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ContactAvatar(id: item.employeeId ?? item.id, avatar: employee?.avatar ?? item.avatar,
                              systemKey: employee?.systemKey, provider: (employee?.agents ?? item.agents).first?.provider, size: 32)
                Text(employee?.name ?? item.name).font(.subheadline.weight(.semibold))
                if item.employeeId != nil { Text("通讯录绑定").font(.caption).foregroundStyle(Theme.brand) }
                Spacer()
                Button("移除") {
                    let wasLeader = model.draft.members[index].isLeader
                    model.draft.members.remove(at: index)
                    if wasLeader, !model.draft.members.isEmpty { model.draft.members[0].isLeader = true }
                }.foregroundStyle(Theme.danger)
            }
            if item.employeeId == nil {
                TextField("成员名字", text: $model.draft.members[index].name)
            }
            TextField("团队分工", text: $model.draft.members[index].duty, axis: .vertical).lineLimit(2...4)
            HStack {
                Button(item.isLeader ? "✓ 负责人" : "设为负责人") {
                    for position in model.draft.members.indices { model.draft.members[position].isLeader = position == index }
                }
                Picker("职责", selection: Binding(
                    get: { model.draft.members[index].role ?? "any" }, set: { model.draft.members[index].role = $0 }
                )) {
                    Text("通用").tag("any"); Text("规划").tag("plan"); Text("工作").tag("work"); Text("验证").tag("verify")
                }
                Button(replacingID == item.id && inviteOpen ? "收起替换" : "替换员工") {
                    inviteQuery = ""; replacingID = item.id; inviteOpen.toggle()
                }
            }
            if item.employeeId != nil {
                Text((employee?.agents ?? item.agents).map { $0.provider + " · " + $0.model }.joined(separator: " → "))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if employee == nil || employee?.archived == true || employee?.agents.isEmpty == true {
                    Text("绑定员工已不可用，请刷新或替换员工。").font(.caption).foregroundStyle(Theme.danger)
                }
                Text("身份与候选由员工维护，团队只维护分工和负责人。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                ContactCandidateEditor(agents: $model.draft.members[index].agents, catalog: model.catalog)
            }
        }.padding(12).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12))
    }
    private var invitation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("搜索员工名字、职责、标签", text: $inviteQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("收起") { inviteOpen = false; replacingID = nil }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(contactOrderedEmployees(directory.employees).filter {
                        contactMatches(inviteQuery, fields: [$0.name, $0.duty] + $0.displayTags)
                    }) { employee in
                        let unavailable = contactEmployeeInviteError(employee, members: model.draft.members, replacingID: replacingID)
                        Button {
                            if let memberID = replacingID, let index = model.draft.members.firstIndex(where: { $0.id == memberID }) {
                                model.draft.members[index].employeeId = employee.id
                                model.draft.members[index].name = employee.name
                                model.draft.members[index].avatar = employee.avatar
                                model.draft.members[index].agents = employee.agents
                            } else if replacingID == nil, model.draft.members.count < 8 {
                                model.draft.members.append(ContactTeamMember(employee: employee, leader: model.draft.members.isEmpty))
                            }
                            inviteOpen = false; replacingID = nil
                        } label: {
                            HStack(spacing: 10) {
                                ContactAvatar(id: employee.id, avatar: employee.avatar, systemKey: employee.systemKey, provider: employee.agents.first?.provider)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(employee.name).foregroundStyle(Theme.textPrimary)
                                    Text(unavailable ?? (employee.duty.isEmpty ? "加入后填写团队分工" : employee.duty))
                                        .font(.caption).foregroundStyle(unavailable == nil ? Theme.textSecondary : Theme.danger)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        }.buttonStyle(.plain).disabled(unavailable != nil)
                    }
                    if directory.employees.isEmpty {
                        Text(directory.loading ? "正在读取通讯录…" : "通讯录为空，请先新建员工。")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if let error = directory.error {
                        Text(error).font(.caption).foregroundStyle(Theme.danger)
                        Button("重试通讯录") { directory.refreshIfVisible() }
                    }
                }
            }.frame(height: 240)
        }.padding(12).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12))
    }
    private var startPanel: some View {
        let candidates = contactProjectCandidates(directory.workspaces)
        let key = "team-start:" + (model.team?.id ?? "")
        let unconfirmed = directory.unconfirmedActions.contains(key)
        return VStack(alignment: .leading, spacing: 10) {
            Text("直接开工").font(.subheadline.weight(.semibold))
            if candidates.isEmpty {
                Text("AI 团队需要先选择一个已有项目。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Picker("工作项目", selection: $model.selectedWorkspaceID) {
                    Text("选择项目").tag("")
                    ForEach(candidates) { Text($0.name.isEmpty ? $0.id : $0.name).tag($0.id) }
                }
                if !model.selectedWorkspaceID.isEmpty && !candidates.contains(where: { $0.id == model.selectedWorkspaceID }) {
                    Text("原项目已不可用，请重新选择项目。").font(.caption).foregroundStyle(Theme.danger)
                }
            }
            TextField("开工说明：要做什么？成员会按职责分工执行", text: $model.note, axis: .vertical)
                .lineLimit(3...8).accessibilityIdentifier("contact-team-start-note")
            Text("\(model.note.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count)/4000字符")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            ContactActionButton(title: "开工", phase: model.startPhase,
                                disabled: model.busy || directory.busy || unconfirmed || model.hasUnsavedChanges ||
                                model.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                !candidates.contains(where: { $0.id == model.selectedWorkspaceID })) {
                model.start(directory: directory, onOpenRun: onOpenRun)
            }
            Text(model.hasUnsavedChanges ? "请先保存团队资料，再开工。" : model.startMessage ?? " ")
                .font(.caption).foregroundStyle(model.startPhase == .failed ? Theme.danger : Theme.textSecondary)
                .frame(minHeight: 24)
            if unconfirmed {
                Text("开工结果未确认，请刷新运行记录核对。").font(.caption).foregroundStyle(Theme.danger)
                Button("我已核对，开始新的开工操作") { directory.acknowledgedUnconfirmed(key) }.font(.caption)
            }
        }.padding(12).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.busy)
    }

}

@MainActor
final class ContactRunStore: ObservableObject {
    @Published private(set) var detail: ContactRunDetail?
    @Published private(set) var liveSteps: [ContactLiveStep] = []
    @Published private(set) var error: String?
    @Published private(set) var loadError: String?
    @Published var text = "" { didSet { textRevision += 1 } }
    @Published private(set) var phase = ComposerSendPhase.idle
    @Published private(set) var unconfirmed = false
    @Published private(set) var currentRunID: String
    private let service: any ContactRunService
    private var active = false
    private var generation = 0
    private var textRevision = 0
    private var feedbackTask: Task<Void, Never>?
    init(runId: String, api: WandAPI, service: (any ContactRunService)? = nil) {
        currentRunID = runId; self.service = service ?? api
    }
    func activate() { active = true }
    func close() {
        active = false; generation += 1; feedbackTask?.cancel()
        if phase == .sending { unconfirmed = true; phase = .failed; error = "操作结果未确认，请先核对群聊。" }
    }
    func acknowledgedUnknown() { unconfirmed = false; phase = .idle; error = nil }
    func refresh() async {
        guard active, phase != .sending else { return }
        generation += 1; let request = generation; let runID = currentRunID
        do {
            var next = try await service.contactRun(runID)
            guard active, request == generation, !Task.isCancelled, next.run.id == runID else { return }
            if ["done", "failed", "stopped"].contains(next.run.status), let chatID = next.run.chatSessionId {
                if let runs = try? await service.contactTaskRuns(next.run.taskId),
                   let latest = runs.filter({ $0.taskId == next.run.taskId && $0.chatSessionId == chatID }).max(by: { $0.updatedAt < $1.updatedAt }),
                   latest.id != runID, latest.updatedAt >= next.run.updatedAt {
                    let followed = try await service.contactRun(latest.id)
                    guard followed.run.id == latest.id, followed.run.taskId == next.run.taskId,
                          followed.run.chatSessionId == chatID else { throw WandAPI.APIError.network("群聊运行归属不一致") }
                    next = followed
                }
            }
            guard active, request == generation, !Task.isCancelled else { return }
            currentRunID = next.run.id
            detail = mergeContactRunDetail(previous: detail, incoming: next, expectedRunID: currentRunID)
            loadError = nil
            if let live = try? await service.contactLive(currentRunID) {
                guard active, request == generation, live.runId == currentRunID else { return }
                let runningStepIDs = Set(detail?.steps.filter { $0.status == "running" }.map(\.id) ?? [])
                liveSteps = live.steps.filter { runningStepIDs.contains($0.stepId) }
            } else if detail?.run.status != "running" { liveSteps = [] }
        } catch { if active, request == generation { loadError = error.localizedDescription } }
    }
    func send() {
        guard let detail, active, phase != .sending, !unconfirmed else { return }
        let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        // Relay input handles running/approval/reply and creates a new run after completion.
        guard let chatID = detail.run.chatSessionId, !chatID.isEmpty else {
            if detail.run.status == "waiting_user" { action("reply", body: ["text": submitted], clearText: true) }
            else { phase = .failed; error = "旧运行没有群聊会话，只能在等待回复时留言。" }
            return
        }
        let revision = textRevision; let runID = currentRunID
        generation += 1; let request = generation
        feedbackTask?.cancel(); phase = .sending; error = nil
        Task {
            do {
                let receipt = try await service.sendStructuredInput(id: chatID, input: submitted)
                guard receipt.id == chatID else { throw WandAPI.APIError.network("群聊发送回执身份不一致") }
                guard active, request == generation, currentRunID == runID else { return }
                if revision == textRevision { text = "" }
                phase = .sent
                resetFeedback(after: WandMotion.submittedDwell)
                // A failed follow-up read does not turn an accepted input into an unknown send.
                await refresh()
            } catch {
                guard active, request == generation else { return }
                phase = .failed; unconfirmed = !isDefiniteInputRejection(error)
                self.error = unconfirmed ? "送达状态未知，请先查看群聊记录，避免重复发送。" : error.localizedDescription
                resetFeedback(after: WandMotion.failedDwell)
            }
        }
    }
    func action(_ action: String, body: [String: Any] = [:], clearText: Bool = false) {
        guard let detail, active, phase != .sending, !unconfirmed else { return }
        let allowed: Bool
        switch action {
        case "approve", "reject": allowed = detail.run.status == "awaiting_approval"
        case "reply": allowed = detail.run.status == "waiting_user"
        case "continue": allowed = detail.run.status == "waiting_user" && detail.run.statusDetail == "已达到步数上限"
        case "stop": allowed = ["running", "awaiting_approval", "waiting_user"].contains(detail.run.status)
        default: allowed = action.hasPrefix("steps/") && detail.steps.contains { "steps/" + $0.id + "/complete" == action && $0.kind == "work" && $0.status == "running" }
        }
        guard allowed else { phase = .failed; error = "运行状态已变化，请刷新后操作。"; return }
        let runID = currentRunID
        generation += 1; let request = generation; let revision = textRevision
        feedbackTask?.cancel(); phase = .sending; error = nil
        Task {
            do {
                let result = try await service.contactRunAction(runID, action: action, body: body)
                guard result.run.id == runID, result.run.taskId == detail.run.taskId,
                      result.run.chatSessionId == detail.run.chatSessionId else { throw WandAPI.APIError.network("运行回执归属不一致") }
                guard active, request == generation else { return }
                self.detail = mergeContactRunDetail(previous: self.detail, incoming: result, expectedRunID: runID)
                phase = .sent
                if clearText, revision == textRevision { text = "" }
                resetFeedback(after: WandMotion.submittedDwell)
            } catch {
                guard active, request == generation else { return }
                phase = .failed; unconfirmed = !isDefiniteInputRejection(error)
                self.error = unconfirmed ? "结果未确认，请刷新核对，勿重复派发或回复。" : error.localizedDescription
                resetFeedback(after: WandMotion.failedDwell)
            }
        }
    }
    private func resetFeedback(after dwell: UInt64) {
        feedbackTask?.cancel()
        let result = phase
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: dwell) } catch { return }
            guard let self, active, phase == result else { return }
            phase = .idle
        }
    }
}

struct ContactRunView: View {
    let runId: String
    let api: WandAPI
    let onOpenSession: (String) -> Void
    let onCompletionVisible: ((SessionSnapshot) -> Void)?
    @StateObject private var model: ContactRunStore
    @StateObject private var files = ServerFileLinkController()
    @State private var composing = false
    @State private var focused = false
    @State private var height: CGFloat = 34
    @State private var confirmStop = false
    @State private var completingStep: ContactTeamStep?
    @State private var completionReport = ""
    @State private var deliveryExpanded: [String: Bool] = [:]
    @Environment(\.scenePhase) private var scenePhase
    init(runId: String, api: WandAPI, onOpenSession: @escaping (String) -> Void,
         onCompletionVisible: ((SessionSnapshot) -> Void)? = nil) {
        self.runId = runId; self.api = api; self.onOpenSession = onOpenSession
        self.onCompletionVisible = onCompletionVisible
        _model = StateObject(wrappedValue: ContactRunStore(runId: runId, api: api))
    }
    var body: some View {
        VStack(spacing: 0) {
            if let detail = model.detail {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text(contactRunStatus(detail.run.status)).font(.headline).foregroundStyle(Theme.brand)
                        if let status = detail.run.statusDetail, !status.isEmpty { Text(status).font(.subheadline) }
                        if let objective = detail.run.objective, !objective.isEmpty {
                            DisclosureGroup("任务说明") { Text(objective).font(.caption).textSelection(.enabled) }
                        }
                        if let delivery = detail.delivery { deliveryPanel(delivery, detail: detail) }
                        if !model.liveSteps.isEmpty { livePanel(detail) }
                        ForEach(Array((detail.chatTurns ?? []).enumerated()), id: \.offset) { _, turn in
                            if turn.notice == true { Text(turn.text).font(.caption).foregroundStyle(Theme.textSecondary) }
                            else {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        if turn.role != "user", let author = turn.author {
                                            let member = detail.presentationTeam?.members.first { $0.id == author.id }
                                            ContactAvatar(id: author.id, avatar: member?.avatar ?? author.avatar ?? "", provider: author.provider, size: 28)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(author(turn, detail: detail)).font(.caption.weight(.semibold)).foregroundStyle(Theme.brand)
                                            if let provider = turn.author?.provider {
                                                Text([WandProvider(rawValue: provider)?.title ?? provider,
                                                      turn.author?.model == "default" ? nil : turn.author?.model,
                                                      turn.author?.thinkingEffort == "off" ? nil : turn.author?.thinkingEffort]
                                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                                            }
                                        }
                                    }
                                    if let file = turn.reportFile {
                                        Button {
                                            if let path = contactReportPath(file, cwd: detail.run.cwd) { files.open(serverPath: path, api: api) }
                                        } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Label(file.preview?.title.isEmpty == false ? file.preview!.title : file.name, systemImage: "doc.text")
                                                if let preview = file.preview, !preview.excerpt.isEmpty { Text(preview.excerpt).font(.caption).lineLimit(3) }
                                                Text("\(file.size)字节 · 点击预览/下载").font(.caption).foregroundStyle(Theme.textSecondary)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                        }.disabled(files.isDownloading || contactReportPath(file, cwd: detail.run.cwd) == nil)
                                    } else { Text(turn.text).textSelection(.enabled) }
                                    if let sessionId = turn.author?.sessionId { Button("查看成员完整会话") { onOpenSession(sessionId) } }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(turn.role == "user" ? Theme.brandSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        DisclosureGroup("步骤与接力") {
                            ForEach(detail.steps) { step in
                                VStack(alignment: .leading) {
                                    Text("\(step.seq). \(step.title) · \(contactRunStatus(step.status))").font(.caption)
                                    if let sessionId = step.sessionId {
                                        let state = detail.memberStates[sessionId]
                                        if let state { Text(contactActivityLabel(state)).font(.caption).foregroundStyle(state == "needs_permission" ? Theme.danger : Theme.textSecondary) }
                                        Button("打开执行会话") { onOpenSession(sessionId) }.disabled(model.phase == .sending)
                                    }
                                    if step.kind == "work" && step.status == "running" {
                                        Button("手动标记完成") { completionReport = ""; completingStep = step }
                                            .disabled(model.phase == .sending || model.unconfirmed)
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                        if detail.run.status == "awaiting_approval" {
                            HStack {
                                ContactActionButton(title: "批准计划", phase: model.phase, disabled: model.unconfirmed) { model.action("approve") }
                                Button("退回修改") { model.action("reject", body: ["feedback": model.text], clearText: true) }
                                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.phase == .sending || model.unconfirmed)
                            }
                        }
                        if detail.run.status == "waiting_user" && detail.run.statusDetail == "已达到步数上限" {
                            ContactActionButton(title: "继续10步", phase: model.phase, disabled: model.unconfirmed) { model.action("continue", body: ["extraSteps": 10]) }
                        }
                        if ["running", "awaiting_approval", "waiting_user"].contains(detail.run.status) {
                            Button("停止团队", role: .destructive) { confirmStop = true }.disabled(model.phase == .sending || model.unconfirmed)
                        }
                    }.padding(16).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
                }
                .refreshable { await model.refresh() }
            } else if let error = model.loadError { Text(error).foregroundStyle(Theme.danger); Button("重试") { Task { await model.refresh() } } }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if model.unconfirmed {
                VStack(spacing: 6) {
                    Text("操作结果未确认，请先核对群聊和运行状态。").font(.caption).foregroundStyle(Theme.danger)
                    Button("我已核对，开始新的操作") { model.acknowledgedUnknown() }.font(.caption)
                }.padding(8)
            } else if let error = model.error ?? model.loadError { Text(error).font(.caption).foregroundStyle(Theme.danger).padding(8) }
            HStack(alignment: .bottom) {
                IMEAwareComposerTextView(text: $model.text, placeholder: "给团队留言", isFocused: focused,
                                         maximumHeight: 120, submitOnReturn: false, onFocusChange: { focused = $0 },
                                         onCompositionChange: { composing = $0 }, onSubmit: reply,
                                         onHeightChange: { height = $0 })
                    .frame(height: max(34, height))
                NativeComposerActionButton(phase: model.phase, turnRunning: false,
                                           hasDraft: !model.text.isEmpty,
                                           canSubmit: model.detail != nil && !composing && !model.unconfirmed && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                           message: model.error, onSend: reply, onStop: {})
            }.padding(12).background(Theme.surface)
                .disabled(model.phase == .sending)
        }
        .background(Theme.background)
        .navigationTitle(model.detail?.title ?? "任务处理群").navigationBarTitleDisplayMode(.inline)
        .wandToolbarSurface()
        .task {
            model.activate()
            while !Task.isCancelled {
                if scenePhase == .active { await model.refresh() }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .task(id: completionScope) {
            guard scenePhase == .active, let detail = model.detail,
                  let sessionID = detail.run.chatSessionId, onCompletionVisible != nil else { return }
            let expectedRun = detail.run.id
            if let snapshot = try? await api.getSession(id: sessionID, blockBudget: 1),
               !Task.isCancelled, scenePhase == .active, snapshot.id == sessionID,
               model.detail?.run.id == expectedRun, model.detail?.run.chatSessionId == sessionID {
                onCompletionVisible?(snapshot)
            }
        }
        .onDisappear { model.close(); files.cancel() }
        .sheet(item: $files.previewItem, onDismiss: files.dismissPreview) { ServerFilePreviewView(item: $0) }
        .alert(item: $files.failure) { Alert(title: Text("文件预览失败"), message: Text($0.message), dismissButton: .default(Text("好"))) }
        .alert("手动完成成员步骤", isPresented: Binding(
            get: { completingStep != nil }, set: { if !$0 { completingStep = nil } }
        )) {
            TextField("完成说明（可选）", text: $completionReport)
            Button("标记完成") {
                if let step = completingStep { model.action("steps/" + step.id + "/complete", body: ["report": completionReport]) }
                completingStep = nil
            }
            Button("取消", role: .cancel) { completingStep = nil }
        } message: { Text("这会结束所选成员步骤；请确认交付已完成。") }
        .confirmationDialog("停止本次团队运行？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止", role: .destructive) { model.action("stop") }; Button("取消", role: .cancel) {}
        }
    }
    private var completionScope: String {
        [model.detail?.run.id ?? "", model.detail?.run.chatSessionId ?? "",
         model.detail?.run.updatedAt ?? "", scenePhase == .active ? "visible" : "hidden"].joined(separator: "\u{0}")
    }
    private func reply() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !composing else { return }
        model.send()
    }
    private func deliveryPanel(_ delivery: ContactDeliverySummary, detail: ContactRunDetail) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { deliveryExpanded[detail.run.id] ?? false }, set: { deliveryExpanded[detail.run.id] = $0 }
        )) {
            VStack(alignment: .leading, spacing: 10) {
                if let conclusion = delivery.conclusion, !conclusion.isEmpty {
                    Text("负责人交付说明").font(.caption.weight(.semibold))
                    Text(conclusion).font(.subheadline).textSelection(.enabled)
                }
                if let attention = delivery.attention, !attention.message.isEmpty {
                    Text(attention.message).font(.caption).foregroundStyle(Theme.danger)
                }
                if delivery.totalFiles > 0 {
                    Text("交付文件 · \(delivery.totalFiles)").font(.caption.weight(.semibold))
                    ForEach(Array(delivery.files.prefix(20))) { item in
                        Button {
                            if let path = contactReportPath(item.file, cwd: detail.run.cwd) { files.open(serverPath: path, api: api) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(item.file.preview?.title.isEmpty == false ? item.file.preview!.title : item.file.name, systemImage: "doc.text")
                                Text(contactMemberName(detail, id: item.memberId, recorded: item.memberName) + " · " + item.title)
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                                if let excerpt = item.file.preview?.excerpt, !excerpt.isEmpty { Text(excerpt).font(.caption).lineLimit(3) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.disabled(files.isDownloading || contactReportPath(item.file, cwd: detail.run.cwd) == nil)
                    }
                    if delivery.totalFiles > delivery.files.count {
                        Text("这里只显示最近\(delivery.files.count)份，更多文件可在成员会话中查看。")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if delivery.totalHandoffs > 0 {
                    Text("当前接力 · \(delivery.totalHandoffs)").font(.caption.weight(.semibold))
                    ForEach(Array(delivery.handoffs.prefix(6))) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contactMemberName(detail, id: item.memberId, recorded: item.memberName) + " · " + item.title)
                            Text(contactActivityLabel(item.state ?? item.status)).font(.caption).foregroundStyle(Theme.textSecondary)
                            if !item.waitingFor.isEmpty { Text("等待：" + item.waitingFor.joined(separator: "、")).font(.caption) }
                            if let sessionID = item.sessionId { Button("打开执行会话") { onOpenSession(sessionID) }.font(.caption) }
                        }
                    }
                }
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(delivery.headline.isEmpty ? "团队交付概览" : delivery.headline).font(.subheadline.weight(.semibold))
                Text("\(delivery.totalFiles)份文件 · \(delivery.totalHandoffs)项接力").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
    private func livePanel(_ detail: ContactRunDetail) -> some View {
        DisclosureGroup("成员正在处理 · \(model.liveSteps.count)") {
            ForEach(model.liveSteps) { step in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(contactMemberName(detail, id: step.memberId, recorded: step.memberName)).font(.caption.weight(.semibold))
                        Spacer(); Text(contactActivityLabel(step.state)).font(.caption).foregroundStyle(Theme.brand)
                    }
                    if step.omittedChars > 0 { Text("已省略前面\(step.omittedChars)字").font(.caption2).foregroundStyle(Theme.textSecondary) }
                    Text(step.text).font(.caption.monospaced()).lineLimit(12).textSelection(.enabled)
                    Button("打开成员会话") { onOpenSession(step.sessionId) }.font(.caption)
                }.padding(.vertical, 8)
            }
        }
    }
    private func author(_ turn: ContactChatTurn, detail: ContactRunDetail) -> String {
        if let id = turn.author?.id, let member = detail.presentationTeam?.members.first(where: { $0.id == id }) { return member.name }
        return turn.author?.name ?? (turn.role == "user" ? "你" : "团队")
    }
}
