import Combine
import Foundation

@MainActor
final class ConversationOperation: ObservableObject {
    @Published private(set) var phase = ComposerSendPhase.idle
    @Published private(set) var message: String?
    @Published private(set) var receipt: ConversationReceipt?
    @Published private(set) var unknownRequest: String?
    private let retainAccepted: Bool
    private var feedbackTask: Task<Void, Never>?
    init(retainAccepted: Bool = true) { self.retainAccepted = retainAccepted }
    var canSubmit: Bool { phase != .sending && unknownRequest == nil && receipt == nil }
    func submit(_ request: @escaping () async throws -> ConversationReceipt, accepted: @escaping (ConversationReceipt) -> Void) {
        guard canSubmit else { return }
        phase = .sending; message = nil
        Task {
            do { settle(try await request(), accepted: accepted) }
            catch {
                unknownRequest = (error as? ConversationUnconfirmed)?.requestId
                phase = .failed; message = error.localizedDescription
            }
        }
    }
    func reconcile(service: any ConversationService, accepted: @escaping (ConversationReceipt) -> Void) {
        guard let id = unknownRequest, phase != .sending else { return }
        phase = .sending
        Task {
            do { settle(try await service.conversationReceipt(id), accepted: accepted) }
            catch { phase = .failed; message = error.localizedDescription }
        }
    }
    private func settle(_ value: ConversationReceipt, accepted: (ConversationReceipt) -> Void) {
        if value.state == "pending" { phase = .failed; message = "仍未确认，请勿重复提交。"; return }
        unknownRequest = nil
        if value.state == "accepted" {
            receipt = retainAccepted ? value : nil; phase = .sent; message = value.error ?? "已接受"; accepted(value)
            if !retainAccepted {
                feedbackTask?.cancel()
                feedbackTask = Task { try? await Task.sleep(nanoseconds: WandMotion.submittedDwell); if !Task.isCancelled { phase = .idle; message = nil } }
            }
        } else { phase = .failed; message = value.error ?? "未接受，可以重试" }
    }
}

/// One endpoint-scoped owner for IM projection and intent. ChatStore still owns actual
/// execution, permissions and queues; ComposerDraftState still owns all draft recovery.
@MainActor
final class ConversationStore: ObservableObject {
    let api: WandAPI
    let service: any ConversationService
    @Published private(set) var items: [ConversationInstance] = []
    @Published private(set) var details: [String: ConversationInstance] = [:]
    @Published private(set) var employees: [SiliconEmployee] = []
    @Published private(set) var presets: [ContactTeam] = []
    @Published private(set) var projects: [Workspace] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var pendingRequests: [String] = []
    @Published private(set) var selectedID: String?
    @Published var targets: [String: ConversationTarget] = [:] { didSet { persist() } }
    @Published var filters: [String: String] = [:] { didSet { persist() } }
    @Published var dispatchIntent: Set<String> = []
    @Published var groupDrafts: [String: ConversationGroupDraft] = [:]
    @Published var creatingPresetID: String?
    @Published private(set) var mutationBusy = false
    private let defaults: UserDefaults
    private let storageKey: String
    private let drafts: SessionDraftStore
    private var generations: [String: Int] = [:]
    private var detailAccessOrder: [String] = []
    private var listRevision = 0
    private var active = false
    private var refreshTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var previewSocket: WandSocket?
    private var operations: [String: ConversationOperation] = [:]
    private var sessionStores: [String: ChatStore] = [:]
    private var sessionAccessOrder: [String] = []
    private var heldSessions: Set<String> = []
    private var ownedDraftKeys: Set<String> = []
    private var unknownRequests: [String: String] = [:]
    private var unknownSubmissions: [String: ComposerDraftSubmission] = [:]

    init(api: WandAPI, service: (any ConversationService)? = nil, drafts: SessionDraftStore? = nil, defaults: UserDefaults = .standard) {
        self.api = api; self.service = service ?? api; self.drafts = drafts ?? .shared; self.defaults = defaults
        storageKey = "wand.conversations." + ServerProfiles.stableID(for: api.baseURL)
        if let data = defaults.data(forKey: storageKey), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            selectedID = saved.selectedID; targets = saved.targets; filters = saved.filters
        }
    }
    private struct Saved: Codable { let selectedID: String?; let targets: [String: ConversationTarget]; let filters: [String: String] }
    private func persist() {
        if let data = try? JSONEncoder().encode(Saved(selectedID: selectedID, targets: targets, filters: filters)) { defaults.set(data, forKey: storageKey) }
    }
    static func employeeID(_ id: String) -> String { "dm_" + id }
    func select(_ id: String?) {
        selectedID = id; persist()
        detailTask?.cancel()
        previewSocket?.close(); previewSocket = nil
        heldSessions.forEach { sessionStores[$0]?.detachView() }; heldSessions.removeAll()
        guard let id, active else { return }
        let socket = WandSocket(baseURL: api.baseURL)
        socket.onConversationPreview = { [weak self] update in
            MainActor.assumeIsolated { self?.applyPreview(update) }
        }
        previewSocket = socket; socket.connect()
        detailTask = Task {
            while !Task.isCancelled, active, selectedID == id {
                await load(id)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    func start() {
        guard !active else { return }
        active = true
        refreshTask = Task {
            while !Task.isCancelled, active {
                await refresh()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
        if let selectedID { select(selectedID) }
    }
    func shutdown() {
        active = false; listRevision += 1
        refreshTask?.cancel(); detailTask?.cancel(); previewSocket?.close(); previewSocket = nil
        heldSessions.forEach { sessionStores[$0]?.detachView() }; heldSessions.removeAll()
        ownedDraftKeys.forEach { drafts.draft(sessionId: $0, api: api).deactivate() }
        persist()
    }
    func refresh() async {
        let revision = listRevision
        loading = true
        defer { loading = false }
        pendingRequests = await service.pendingConversationRequests()
        do {
            let rows = try await service.conversations()
            guard revision == listRevision, !Task.isCancelled else { return }
            items = rows
            employees = try await service.listContactEmployees()
            presets = try await service.listContactTeams()
            projects = try await service.listWorkspaces()
            pendingRequests = await service.pendingConversationRequests()
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func load(_ id: String) async {
        let revision = (generations[id] ?? 0) + 1; generations[id] = revision
        do {
            let detail = try await service.conversation(id)
            guard generations[id] == revision, !Task.isCancelled else { return }
            details[id] = detail; error = nil
            detailAccessOrder.removeAll { $0 == id }; detailAccessOrder.append(id)
            while details.count > 24, let old = detailAccessOrder.first(where: { $0 != selectedID && $0 != id }) {
                details.removeValue(forKey: old); detailAccessOrder.removeAll { $0 == old }
            }
            if selectedID == id { syncExecutionStores(detail) }
        } catch { if generations[id] == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func applyPreview(_ update: ConversationSessionUpdate) {
        guard selectedID == update.conversationId, var detail = details[update.conversationId] else { return }
        detail.messages = detail.messages.map { message in
            var message = message
            if message.sessionLink?.sessionId == update.sessionId { message.sessionPreview = update.preview }
            return message
        }
        details[update.conversationId] = detail
    }
    func executionStore(_ id: String) -> ChatStore {
        sessionAccessOrder.removeAll { $0 == id }; sessionAccessOrder.append(id)
        if let store = sessionStores[id] { return store }
        let store = ChatStore(sessionId: id, api: api); sessionStores[id] = store
        while sessionStores.count > 100, let old = sessionAccessOrder.first(where: { $0 != id && sessionStores[$0]?.canEvict == true }) {
            sessionStores.removeValue(forKey: old)?.shutdown(); sessionAccessOrder.removeAll { $0 == old }
        }
        return store
    }
    private func syncExecutionStores(_ detail: ConversationInstance) {
        var ids = Set(detail.messages.compactMap { $0.sessionPreview?.active == true ? $0.sessionLink?.sessionId : nil })
        if let id = detail.communicationSessionId { ids.insert(id) }
        if let target = targets[detail.id], let run = detail.runDetails.first(where: { $0.run.id == target.runId }), let id = run.run.chatSessionId { ids.insert(id) }
        // Inactive preview cards do not need a socket. Detail polling remains the reconnect repair path.
        for run in detail.runDetails where ["running", "awaiting_approval", "waiting_user"].contains(run.run.status) {
            ids.formUnion(run.steps.filter { ["running", "waiting_user", "waiting-input"].contains($0.status) }.compactMap(\.sessionId).prefix(16))
        }
        for id in heldSessions.subtracting(ids) { sessionStores[id]?.detachView() }
        for id in ids.subtracting(heldSessions) { executionStore(id).attachView() }
        heldSessions = ids
    }
    func reportError(_ message: String) { error = message }
    func operation(_ key: String) -> ConversationOperation {
        if let operation = operations[key] { return operation }
        let operation = ConversationOperation(retainAccepted: key.hasPrefix("group:")); operations[key] = operation; return operation
    }
    func finishGroup(_ context: String) { operations.removeValue(forKey: "group:" + context); groupDrafts.removeValue(forKey: context) }
    func draftKey(_ id: String, target: ConversationTarget?) -> String {
        "conversation:" + id + ":" + (target?.taskId ?? "") + ":" + (target?.runId ?? "talk")
    }
    func composer(_ id: String, target: ConversationTarget?) -> ComposerDraftState {
        let key = draftKey(id, target: target); ownedDraftKeys.insert(key)
        let draft = drafts.draft(sessionId: key, api: api)
        draft.attachments.prepareUpload = { [weak self] in
            guard let self else { throw CancellationError() }
            let receipt = try await service.conversationPost(path: "/api/conversations/" + api.percentEncodePathComponent(id) + "/channel", body: [:])
            guard let sessionID = receipt.sessionId, !sessionID.isEmpty else { throw ConversationUnconfirmed(requestId: receipt.requestId) }
            return sessionID
        }
        return draft
    }
    func hasUnknown(_ id: String, target: ConversationTarget?) -> Bool { unknownRequests[draftKey(id, target: target)] != nil }
    func send(_ id: String, target: ConversationTarget?, dispatch: Bool, workspaceID: String?, cwd: String?, executionPreference: ConversationExecutionPreference? = nil) {
        let draft = composer(id, target: target)
        let key = draftKey(id, target: target)
        let submitted = draft.submission()
        let text = submitted.prompt
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.sendPhase != .sending,
              unknownRequests[key] == nil, !draft.retired, details[id]?.dissolvedAt == nil, details[id]?.deleting != true else { return }
        if dispatch, workspaceID?.isEmpty != false { draft.finishSending(accepted: false, message: "请选择项目再派发任务"); return }
        var body: [String: Any] = dispatch
            ? ["description": text, "workspaceId": workspaceID ?? "", "memberVersion": details[id]?.memberVersion ?? 1]
            : conversationMessageBody(input: text, target: target, cwd: cwd, executionPreference: executionPreference)
        if dispatch, let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if dispatch, let target { body["continueTaskId"] = target.taskId }
        draft.submitted(submitted); draft.beginSending()
        Task {
            do {
                let receipt = try await service.conversationPost(path: "/api/conversations/" + api.percentEncodePathComponent(id) + (dispatch ? "/tasks" : "/messages"), body: body)
                draft.accepted(submitted)
                draft.finishSending(accepted: true, message: receipt.error ?? (dispatch ? "任务已接受" : "已发送"))
                if !draft.retired, dispatch, selectedID == id {
                    dispatchIntent.remove(id)
                    if let taskId = receipt.taskId, let runId = receipt.runId, receipt.conversationId == id {
                        targets[id] = ConversationTarget(taskId: taskId, runId: runId); filters[id] = taskId
                    }
                }
                if !draft.retired { await load(id); await refresh() }
            } catch {
                guard !draft.retired else { return }
                if let unknown = error as? ConversationUnconfirmed {
                    unknownRequests[key] = unknown.requestId; unknownSubmissions[key] = submitted
                    draft.unconfirmedInput = text
                    pendingRequests = await service.pendingConversationRequests()
                } else { draft.rejected(submitted) }
                draft.finishSending(accepted: false, message: error.localizedDescription)
            }
        }
    }
    func reconcile(_ requestID: String) async {
        do {
            let receipt = try await service.conversationReceipt(requestID)
            guard receipt.state != "pending" else { error = "仍未确认，请勿重复提交。"; return }
            for key in unknownRequests.keys.filter({ unknownRequests[$0] == requestID }) {
                let draft = drafts.draft(sessionId: key, api: api)
                if let submission = unknownSubmissions.removeValue(forKey: key) {
                    if receipt.state == "accepted" { draft.accepted(submission) } else { draft.rejected(submission) }
                }
                draft.resolveUnconfirmedInput()
                draft.finishSending(accepted: receipt.state == "accepted", message: receipt.error ?? "已核对请求")
                unknownRequests.removeValue(forKey: key)
            }
            pendingRequests = await service.pendingConversationRequests()
            await refresh()
            if let selectedID { await load(selectedID) }
        } catch { self.error = error.localizedDescription }
    }
    func reconcileComposer(_ id: String, target: ConversationTarget?) {
        guard let request = unknownRequests[draftKey(id, target: target)] else { return }
        Task { await reconcile(request) }
    }
    @discardableResult
    func update(_ id: String, patch: [String: Bool]) async -> Bool {
        guard !mutationBusy else { return false }
        mutationBusy = true; defer { mutationBusy = false }
        do {
            let updated = try await service.updateConversationListState(id, patch: patch)
            listRevision += 1; generations[id] = (generations[id] ?? 0) + 1
            items.removeAll { $0.id == id }; items.append(updated)
            items.sort { ($0.pinnedAt ?? "", $0.messageAt) > ($1.pinnedAt ?? "", $1.messageAt) }
            details.removeValue(forKey: id)
            await load(id)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ id: String) async throws {
        try await service.deleteConversation(id)
        listRevision += 1; generations[id] = (generations[id] ?? 0) + 1
        items.removeAll { $0.id == id }; details.removeValue(forKey: id)
        targets.removeValue(forKey: id); filters.removeValue(forKey: id); dispatchIntent.remove(id)
        for key in ownedDraftKeys.filter({ $0.hasPrefix("conversation:" + id + ":") }) {
            drafts.remove(sessionId: key, api: api); ownedDraftKeys.remove(key)
            unknownRequests.removeValue(forKey: key); unknownSubmissions.removeValue(forKey: key)
        }
        if selectedID == id { select(nil) }
        persist()
    }
    func openTask(_ link: ConversationLink, preview: ConversationPreview?) {
        guard preview?.status != "unavailable" else { return }
        filters[link.conversationId] = link.taskId
        targets[link.conversationId] = preview?.active == true ? preview?.runId.map { ConversationTarget(taskId: link.taskId, runId: $0) } : nil
        select(link.conversationId)
    }
}
