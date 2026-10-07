import Foundation
import Combine

@MainActor
private func contactFetch<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}

@MainActor
final class ContactsStore: ObservableObject {
    @Published private(set) var employees: [SiliconEmployee] = []
    @Published private(set) var teams: [ContactTeam] = []
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var defaultCwd: String?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var busyContact: String?
    @Published private(set) var rowErrors: [String: String] = [:]
    @Published private(set) var unconfirmedActions = Set<String>()
    @Published var editorBusy = false
    @Published var editorDirty = false
    private let service: any ContactDirectoryService
    private var active = false
    private var loadGeneration = 0
    private var openGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var creationTask: Task<Void, Never>?

    init(service: any ContactDirectoryService) { self.service = service }
    var busy: Bool { busyContact != nil || editorBusy }
    var binding: ContactConversationBinding? { contactConversationBinding(defaultCwd: defaultCwd, workspaces: workspaces) }
    var teamWorkspace: Workspace? { contactProjectCandidates(workspaces).first }
    func activate() { active = true }
    func close() {
        active = false; loadGeneration += 1; openGeneration += 1
        refreshTask?.cancel(); creationTask?.cancel(); loading = false
        if let busyContact { markUnconfirmed(busyContact) }
        busyContact = nil
    }
    func employees(matching query: String) -> [SiliconEmployee] {
        contactOrderedEmployees(employees.filter { !$0.archived && contactMatches(query, fields: [$0.name, $0.duty] + $0.displayTags) })
    }
    func teams(matching query: String) -> [ContactTeam] {
        contactOrderedTeams(teams.filter { team in
            contactMatches(query, fields: [team.name, team.description] + team.members.map { member in
                employees.first { $0.id == member.employeeId }?.name ?? member.name
            })
        })
    }
    func refreshIfVisible() {
        guard active else { return }
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }
    func refresh() async {
        guard active else { return }
        loadGeneration += 1; let generation = loadGeneration
        loading = true
        async let people = contactFetch { try await service.listContactEmployees() }
        async let groups = contactFetch { try await service.listContactTeams() }
        async let projects = contactFetch { try await service.listWorkspaces() }
        async let directory = contactFetch { try await service.contactDefaultCwd() }
        let (p, g, w, d) = await (people, groups, projects, directory)
        guard active, generation == loadGeneration, !Task.isCancelled else { return }
        var failures: [String] = []
        if case .success(let values) = p { employees = values } else { failures.append("员工") }
        if case .success(let values) = g { teams = values } else { failures.append("团队") }
        if case .success(let values) = w { workspaces = values } else { failures.append("项目") }
        if case .success(let value) = d { defaultCwd = value } else { failures.append("默认目录") }
        error = failures.isEmpty ? nil : failures.joined(separator: "、") + "未能刷新，已有内容已保留。请重试。"
        loading = false
    }
    private func invalidateRefresh() { loadGeneration += 1; refreshTask?.cancel(); loading = false }
    func update(_ employee: SiliconEmployee) {
        invalidateRefresh()
        if let index = employees.firstIndex(where: { $0.id == employee.id }) { employees[index] = employee }
        else { employees.append(employee) }
    }
    func update(_ team: ContactTeam) {
        invalidateRefresh()
        if let index = teams.firstIndex(where: { $0.id == team.id }) { teams[index] = team }
        else { teams.append(team) }
    }
    func removedEmployee(_ id: String) { invalidateRefresh(); employees.removeAll { $0.id == id } }
    func removedTeam(_ id: String) { invalidateRefresh(); teams.removeAll { $0.id == id } }
    func markUnconfirmed(_ key: String) {
        unconfirmedActions.insert(key)
        rowErrors[key] = "结果未确认，请先刷新并核对，勿重复创建。"
    }
    /// An explicit new user intent, never a GET-based inference or automatic retry.
    func acknowledgedUnconfirmed(_ key: String) {
        unconfirmedActions.remove(key); rowErrors[key] = nil
    }
    func openEmployee(_ id: String, onOpen: @escaping (SessionSnapshot) -> Void) {
        let key = "employee:" + id
        guard active, !busy, !unconfirmedActions.contains(key) else { return }
        guard let person = employees.first(where: { $0.id == id && !$0.archived && !$0.agents.isEmpty }),
              let binding else {
            rowErrors[key] = "员工不可用或没有工作目录，请刷新或先创建项目。"; return
        }
        begin(key)
        let generation = openGeneration
        creationTask = Task {
            do {
                let session = try await service.createEmployeeConversation(employeeId: person.id, binding: binding)
                guard !session.id.isEmpty, session.isStructured, session.employeeId == person.id else {
                    throw WandAPI.APIError.network("员工对话回执无效")
                }
                guard active, generation == openGeneration else { return }
                busyContact = nil
                onOpen(session)
            } catch {
                finishCreationFailure(error, key: key, generation: generation)
            }
        }
    }
    func openTeam(_ id: String, onOpen: @escaping (String) -> Void) {
        let key = "team:" + id
        guard active, !busy, !unconfirmedActions.contains(key) else { return }
        guard teams.contains(where: { $0.id == id }), let workspace = teamWorkspace else {
            rowErrors[key] = "团队需要一个已有的非全局项目，请刷新或先创建项目。"; return
        }
        begin(key)
        let generation = openGeneration
        creationTask = Task {
            do {
                let detail = try await service.startContactTeam(teamId: id, workspaceId: workspace.id)
                guard !detail.run.id.isEmpty, detail.run.teamId == id else { throw WandAPI.APIError.network("群聊回执无效") }
                guard active, generation == openGeneration else { return }
                busyContact = nil
                onOpen(detail.run.id)
            } catch {
                finishCreationFailure(error, key: key, generation: generation)
            }
        }
    }
    private func begin(_ key: String) {
        openGeneration += 1; busyContact = key; rowErrors[key] = nil
    }
    private func finishCreationFailure(_ error: Error, key: String, generation: Int) {
        guard active, generation == openGeneration else { return }
        if isDefiniteInputRejection(error) { rowErrors[key] = error.localizedDescription }
        else { markUnconfirmed(key) }
        busyContact = nil
    }
}

@MainActor
final class EmployeeProfileStore: ObservableObject {
    @Published var draft = EmployeeDraft() {
        didSet {
            draftRevision += 1
            if phase != .sending && !creationUnconfirmed { phase = .idle; message = nil }
        }
    }
    private var draftRevision = 0
    private var savedDraft = EmployeeDraft()
    @Published private(set) var employee: SiliconEmployee?
    @Published private(set) var ready: Bool
    @Published private(set) var loading = false
    @Published private(set) var phase = ComposerSendPhase.idle
    @Published private(set) var message: String?
    @Published private(set) var creationUnconfirmed = false
    @Published private(set) var catalog: ModelsResponse?
    private let id: String?
    private let service: any EmployeeEditingService
    private var generation = 0
    private var active = true
    init(id: String?, api: WandAPI, service: (any EmployeeEditingService)? = nil) {
        self.id = id; self.service = service ?? api; ready = id == nil
    }
    var busy: Bool { phase == .sending }
    var builtin: Bool { employee?.builtin == true }
    var hasUnsavedChanges: Bool { ready && draft != savedDraft }
    func close() { active = false; generation += 1 }
    func load() async {
        guard !busy else { return }
        active = true; generation += 1; let request = generation; let revision = draftRevision; loading = true
        async let models = try? service.models()
        let initialAgents = draft.agents
        do {
            if let id {
                let employee = try await service.contactEmployee(id)
                guard active, request == generation, !Task.isCancelled else { return }
                guard employee.id == id else { throw WandAPI.APIError.network("员工资料身份不一致") }
                self.employee = employee
                if !ready || revision == draftRevision { draft = EmployeeDraft(employee); savedDraft = draft }
                ready = true
            } else if let candidate = try? await service.contactDefaultCandidate(), active,
                      request == generation, draft.agents == initialAgents {
                draft.agents = [candidate]
                var initial = EmployeeDraft(); initial.agents = [candidate]; savedDraft = initial
            }
        } catch { if active, request == generation { message = error.localizedDescription } }
        let modelCatalog = await models
        guard active, request == generation, !Task.isCancelled else { return }
        catalog = modelCatalog; loading = false
    }
    func save(onBusy: @escaping (Bool) -> Void, onSaved: @escaping (SiliconEmployee) -> Void,
              onUnconfirmed: @escaping () -> Void) {
        guard active, ready, !busy, !creationUnconfirmed else { return }
        if let error = draft.validationError(builtin: builtin) { phase = .failed; message = error; return }
        generation += 1; let request = generation
        let submitted = draft; let revision = draftRevision
        let existingID = employee?.id ?? id; let locked = builtin
        phase = .sending; message = nil; onBusy(true)
        Task {
            defer { onBusy(false) }
            do {
                let saved = try await service.saveContactEmployee(id: existingID, draft: submitted, builtin: locked)
                guard existingID == nil || saved.id == existingID else { throw WandAPI.APIError.network("资料回执身份不一致") }
                guard active, request == generation else { return }
                employee = saved; savedDraft = EmployeeDraft(saved)
                let unchanged = draftRevision == revision
                if unchanged { draft = EmployeeDraft(saved) }
                phase = .sent
                message = unchanged ? "已保存" : "上一版已保存，当前新输入尚未保存。"
                onSaved(saved)
            } catch {
                guard active, request == generation else { return }
                phase = .failed
                if existingID == nil && !isDefiniteInputRejection(error) {
                    creationUnconfirmed = true; onUnconfirmed()
                    message = "创建结果未确认，请刷新通讯录核对，勿重复新建。"
                } else { message = error.localizedDescription }
            }
        }
    }
    func manage(_ action: String, onBusy: @escaping (Bool) -> Void, onRemoved: @escaping () -> Void) {
        guard let employee, !employee.builtin, active, !busy else { return }
        generation += 1; let request = generation
        phase = .sending; message = nil; onBusy(true)
        Task {
            defer { onBusy(false) }
            do {
                try await service.manageContactEmployee(id: employee.id, action: action)
                guard active, request == generation else { return }
                phase = .sent; onRemoved()
            } catch {
                guard active, request == generation else { return }
                phase = .failed; message = error.localizedDescription
            }
        }
    }
}
