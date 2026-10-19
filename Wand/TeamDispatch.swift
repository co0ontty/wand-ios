import Combine
import Foundation
import SwiftUI

struct TeamDispatchMember: Decodable, Identifiable, Equatable {
    let employeeId: String
    let name: String
    let duty: String
    let avatar: String
    let probability: Double
    let isLeader: Bool
    var id: String { employeeId }
    var probabilityLabel: String { probability.isFinite ? "\(Int((min(1, max(0, probability)) * 100).rounded()))%" : "" }
}
struct TeamDispatchPlan: Decodable {
    let members: [TeamDispatchMember]
    let bench: [TeamDispatchMember]
    let considered: Int
    let omitted: Int
    let note: String
    let maxMembers: Int
}
struct TeamDispatchSelection: Equatable {
    var members: [TeamDispatchMember] = []
    var leaderID = ""
    mutating func toggle(_ member: TeamDispatchMember) {
        if members.contains(where: { $0.id == member.id }) { members.removeAll { $0.id == member.id } }
        else if members.count < 8 { members.append(member); members.sort { $0.probability > $1.probability } }
        if !members.contains(where: { $0.id == leaderID }) { leaderID = members.first?.id ?? "" }
    }
    var picks: [[String: Any]] { members.map { ["employeeId": $0.id, "isLeader": $0.id == leaderID] } }
    var valid: Bool { (2...8).contains(members.count) && Set(members.map(\.id)).count == members.count && members.contains { $0.id == leaderID } }
}
@MainActor
protocol TeamDispatchService {
    func planTeamDispatch(note: String, maxMembers: Int) async throws -> TeamDispatchPlan
    func startTeamDispatch(workspaceID: String, note: String, selection: TeamDispatchSelection) async throws -> ContactRunDetail
}
extension WandAPI: TeamDispatchService {
    func planTeamDispatch(note: String, maxMembers: Int) async throws -> TeamDispatchPlan {
        try await request(TeamDispatchPlan.self, method: "POST", path: "/api/team-dispatch/plan", body: ["note": note, "maxMembers": maxMembers], timeout: 180)
    }
    func startTeamDispatch(workspaceID: String, note: String, selection: TeamDispatchSelection) async throws -> ContactRunDetail {
        guard selection.valid else { throw APIError.server(status: 400, message: "团队需有2–8名员工及一名负责人") }
        return try await request(ContactRunDetail.self, method: "POST", path: "/api/team-dispatch/start", body: ["workspaceId": workspaceID, "note": note, "members": selection.picks], timeout: 180)
    }
}

@MainActor
final class TeamDispatchStore: ObservableObject {
    private var service: any TeamDispatchService
    func bind(service: any TeamDispatchService) { self.service = service }
    private let defaults: UserDefaults
    private let key: String
    @Published var note = "" { didSet { if note != oldValue { noteRevision += 1; plan = nil; selection = TeamDispatchSelection() } } }
    @Published var workspaceID = ""
    @Published var maxMembers = 3 { didSet { if maxMembers != oldValue { noteRevision += 1; plan = nil; selection = TeamDispatchSelection() } } }
    @Published var selection = TeamDispatchSelection()
    @Published private(set) var plan: TeamDispatchPlan?
    @Published private(set) var phase = ComposerSendPhase.idle
    @Published private(set) var message: String?
    @Published private(set) var uncertain: Bool
    @Published private(set) var acceptedRunID: String?
    private var noteRevision = 0
    private var visible = false
    private var visibilityRevision = 0
    init(service: any TeamDispatchService, baseURL: URL, defaults: UserDefaults = .standard, scope: String = "contacts") {
        self.service = service; self.defaults = defaults
        key = "wand.teamDispatchPending." + ServerProfiles.stableID(for: baseURL) + (scope == "contacts" ? "" : "." + scope)
        uncertain = defaults.bool(forKey: key)
        acceptedRunID = defaults.string(forKey: key + ".accepted")
    }
    var canPlan: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.count <= 4000 && phase != .sending && !uncertain && acceptedRunID == nil }
    var canStart: Bool { canPlan && plan != nil && !workspaceID.isEmpty && selection.valid }
    func activate() { visible = true; visibilityRevision += 1 }
    func close() { visible = false; visibilityRevision += 1 }
    func suggest() {
        guard canPlan else { return }
        let submitted = note, revision = noteRevision, limit = maxMembers
        phase = .sending; message = nil
        Task {
            do {
                let result = try await service.planTeamDispatch(note: submitted, maxMembers: limit)
                guard revision == noteRevision else { phase = .idle; return }
                plan = result; selection = TeamDispatchSelection(members: result.members,
                    leaderID: result.members.first { $0.isLeader }?.id ?? result.members.first?.id ?? "")
                phase = .idle; message = result.note
            } catch { phase = .failed; message = error.localizedDescription }
        }
    }
    func start(onAccepted: @escaping (String) -> Void) {
        guard canStart else { return }
        let submitted = note, workspace = workspaceID, members = selection
        let viewRevision = visibilityRevision
        phase = .sending; message = nil
        defaults.set(true, forKey: key)
        Task {
            do {
                let result = try await service.startTeamDispatch(workspaceID: workspace, note: submitted, selection: members)
                guard !result.run.id.isEmpty else { throw WandAPI.APIError.network("开工回执无效") }
                acceptedRunID = result.run.id; defaults.set(result.run.id, forKey: key + ".accepted")
                uncertain = false; defaults.removeObject(forKey: key)
                phase = .sent; message = "已开工"
                if visible && visibilityRevision == viewRevision { onAccepted(result.run.id) }
            } catch {
                uncertain = !isDefiniteInputRejection(error)
                if !uncertain { defaults.removeObject(forKey: key) }
                phase = .failed; message = uncertain ? "开工结果未确认，请到任务核对，勿重复开工。" : error.localizedDescription
            }
        }
    }
    /// Only a new explicit user intent after inspecting task history, never automatic retry.
    func newIntent() {
        guard phase != .sending else { return }
        uncertain = false; acceptedRunID = nil; plan = nil; selection = TeamDispatchSelection(); phase = .idle; message = nil
        defaults.removeObject(forKey: key); defaults.removeObject(forKey: key + ".accepted")
    }
}

@MainActor
final class TeamDispatchStoreCache {
    static let shared = TeamDispatchStoreCache()
    private var stores: [String: TeamDispatchStore] = [:]
    func store(api: WandAPI, scope: String = "contacts") -> TeamDispatchStore {
        let key = ServerProfiles.stableID(for: api.baseURL) + ":" + scope
        if let store = stores[key] { store.bind(service: api); return store }
        let store = TeamDispatchStore(service: api, baseURL: api.baseURL, scope: scope); stores[key] = store; return store
    }
}

/// Shared selection projection: both entry points use the same owner and actions,
/// with distinct scopes so opening New Task cannot overwrite Contacts' draft/run.
struct TeamDispatchRoster: View {
    @ObservedObject var store: TeamDispatchStore
    var body: some View {
        if let plan = store.plan {
            VStack(alignment: .leading, spacing: 8) {
                Text("评估 \(plan.considered) 人 · 未纳入 \(plan.omitted) 人，概率仅作参考").font(.caption).foregroundStyle(Theme.textSecondary)
                ForEach(plan.members + plan.bench) { member in
                    Toggle(isOn: Binding(get: { store.selection.members.contains { $0.id == member.id } }, set: { _ in store.selection.toggle(member) })) {
                        VStack(alignment: .leading) {
                            Text(member.name + " · " + member.probabilityLabel)
                            Text(member.duty).font(.caption).foregroundStyle(Theme.textSecondary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.toggleStyle(.button).disabled(store.phase == .sending)
                }
                Picker("负责人", selection: $store.selection.leaderID) {
                    ForEach(store.selection.members) { Text($0.name).tag($0.id) }
                }.disabled(store.phase == .sending)
            }
        }
    }
}

struct TeamDispatchPanel: View {
    @ObservedObject private var store: TeamDispatchStore
    let projects: [Workspace]
    let onClose: () -> Void
    let onOpenRun: (String) -> Void
    @State private var confirmNew = false
    init(api: WandAPI, projects: [Workspace], onClose: @escaping () -> Void, onOpenRun: @escaping (String) -> Void) {
        self.projects = projects; self.onClose = onClose; self.onOpenRun = onOpenRun
        _store = ObservedObject(wrappedValue: TeamDispatchStoreCache.shared.store(api: api))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("派工").font(.headline); Spacer(); Button("关闭", action: onClose).disabled(store.phase == .sending) }
            TextField("这次要做什么", text: $store.note, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(store.phase == .sending || store.uncertain)
            Picker("项目", selection: $store.workspaceID) {
                Text("选择项目").tag(""); ForEach(contactProjectCandidates(projects)) { Text($0.name).tag($0.id) }
            }.disabled(store.phase == .sending)
            Stepper("建议最多 \(store.maxMembers) 位员工", value: $store.maxMembers, in: 2...8).disabled(store.phase == .sending)
            TeamDispatchRoster(store: store)
            if let message = store.message { Text(message).font(.caption).foregroundStyle(store.phase == .failed ? Theme.danger : Theme.textSecondary) }
            HStack {
                if store.uncertain { Button("已核对记录，开始新派工") { confirmNew = true } }
                if let runID = store.acceptedRunID { Button("打开已接受的任务") { onOpenRun(runID) }; Button("新派工") { store.newIntent() } }
                else {
                    Button("获取建议") { store.suggest() }.disabled(!store.canPlan)
                    Spacer()
                    Button { store.start(onAccepted: onOpenRun) } label: { Text(store.phase == .sending ? "处理中" : store.phase == .sent ? "已开工" : store.phase == .failed ? "失败" : "确认开工").frame(width: 100, height: 44) }.buttonStyle(.borderedProminent).disabled(!store.canStart)
                }
            }
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { store.activate() }.onDisappear { store.close() }
        .alert("确认已经核对任务记录？", isPresented: $confirmNew) {
            Button("取消", role: .cancel) {}; Button("开始新派工") { store.newIntent() }
        } message: { Text("这不是重试旧请求。未确认的任务可能已经开工，新派工会建立另一项任务。") }
    }
}
