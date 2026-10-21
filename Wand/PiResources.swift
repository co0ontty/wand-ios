import Combine
import Foundation
import SwiftUI

struct PiResourceSelection: Codable, Equatable {
    var skills: [String] = []
    var mcpServers: [String] = []
}
struct PiResourceItem: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
}
struct PiResourcesResponse: Decodable {
    struct Settings: Codable, Equatable {
        var resources: PiResourceSelection?
        var lockedSkills: [String]?
        var autoResources: Bool?
        var codemodeOverride: String?
    }
    struct Catalog: Decodable {
        let supported: Bool
        let reason: String?
        let skills: [PiResourceItem]
        let mcpServers: [PiResourceItem]
    }
    struct Controls: Decodable { let codemodeOverride: Bool?; let codemodeOnly: Bool? }
    var settings: Settings
    let resourceCatalog: Catalog?
    let controls: Controls?
    let engine: String?
    let autoResourcesAvailable: Bool?
    let autoResourcesReason: String?
    let autoCodemodeAvailable: Bool?
    let skillLocksAvailable: Bool?
    var editable: Bool { resourceCatalog?.supported == true }
    var codemodeAvailable: Bool { controls?.codemodeOverride == true }
    var codemodeOnlyAvailable: Bool { controls?.codemodeOnly == true }
}
@MainActor
protocol PiResourcesService {
    func piResources(_ id: String) async throws -> PiResourcesResponse
    func savePiResources(_ id: String, body: [String: Any]) async throws -> PiResourcesResponse.Settings
}
extension WandAPI: PiResourcesService {
    func piResources(_ id: String) async throws -> PiResourcesResponse {
        try await request(PiResourcesResponse.self, method: "GET", path: "/api/sessions/" + percentEncodePathComponent(id) + "/pi-settings")
    }
    func savePiResources(_ id: String, body: [String: Any]) async throws -> PiResourcesResponse.Settings {
        struct Ack: Decodable { let settings: PiResourcesResponse.Settings }
        return try await request(Ack.self, method: "PATCH", path: "/api/sessions/" + percentEncodePathComponent(id) + "/pi-settings", body: body).settings
    }
}

@MainActor
final class PiResourcesStore: ObservableObject {
    let sessionID: String
    private let service: any PiResourcesService
    @Published private(set) var response: PiResourcesResponse?
    @Published var draft = PiResourcesResponse.Settings()
    @Published private(set) var phase = ComposerSendPhase.idle
    @Published private(set) var message: String?
    @Published private(set) var loading = false
    @Published private(set) var uncertain = false
    private var revision = 0
    private var active = true
    init(sessionID: String, service: any PiResourcesService) { self.sessionID = sessionID; self.service = service }
    var dirty: Bool { response.map { draft != $0.settings } ?? false }
    func load() async {
        guard phase != .sending else { return }
        active = true; revision += 1; let request = revision; loading = true
        do {
            let loaded = try await service.piResources(sessionID)
            guard active, request == revision, !Task.isCancelled else { return }
            response = loaded; draft = loaded.settings; message = nil; uncertain = false; phase = .idle
        } catch { if active, request == revision { message = error.localizedDescription } }
        if request == revision { loading = false }
    }
    func skillMode(_ id: String) -> String {
        guard draft.resources?.skills.contains(id) == true else { return "off" }
        return draft.lockedSkills?.contains(id) == true ? "locked" : "on"
    }
    func setSkill(_ id: String, mode: String) {
        var resources = draft.resources ?? PiResourceSelection()
        resources.skills.removeAll { $0 == id }
        if mode != "off" { resources.skills.append(id) }
        draft.resources = resources
        var locks = draft.lockedSkills ?? []; locks.removeAll { $0 == id }
        if mode == "locked" { locks.append(id) }
        draft.lockedSkills = locks
    }
    func setMcp(_ id: String, enabled: Bool) {
        var resources = draft.resources ?? PiResourceSelection()
        resources.mcpServers.removeAll { $0 == id }
        if enabled { resources.mcpServers.append(id) }
        draft.resources = resources
    }
    func save() {
        guard active, dirty, phase != .sending, !uncertain, let response else { return }
        let submitted = draft; let request = revision
        var body: [String: Any] = [:]
        if response.editable, let resources = draft.resources {
            body["resources"] = ["skills": resources.skills, "mcpServers": resources.mcpServers]
            if response.skillLocksAvailable == true { body["lockedSkills"] = draft.lockedSkills ?? [] }
        }
        if response.autoResourcesAvailable == true { body["autoResources"] = draft.autoResources ?? false }
        if response.codemodeAvailable { body["codemodeOverride"] = draft.codemodeOverride ?? NSNull() }
        phase = .sending; message = nil
        Task {
            do {
                let ack = try await service.savePiResources(sessionID, body: body)
                guard active, request == revision else { return }
                if body["resources"] != nil, ack.resources == nil { throw WandAPI.APIError.network("资源选择回执无效") }
                if body["lockedSkills"] != nil, ack.lockedSkills == nil || (ack.lockedSkills?.count ?? 0) > 64
                    || Set(ack.lockedSkills ?? []).count != ack.lockedSkills?.count { throw WandAPI.APIError.network("Skill 锁定回执无效") }
                if body["autoResources"] != nil, ack.autoResources != submitted.autoResources { throw WandAPI.APIError.network("自动配置回执无效") }
                if body["codemodeOverride"] != nil, ack.codemodeOverride != submitted.codemodeOverride { throw WandAPI.APIError.network("CodeMode 回执无效") }
                self.response?.settings = ack
                if draft == submitted { draft = ack }
                phase = .sent; message = "已保存，下轮生效，并成为新建 Pi 会话的默认"
            } catch {
                guard active, request == revision else { return }
                uncertain = !isDefiniteInputRejection(error)
                phase = .failed; message = uncertain ? "保存结果未确认，请重新读取核对，不要重复提交。" : error.localizedDescription
            }
        }
    }
    func close() { active = false; revision += 1 }
}

struct PiResourcesView: View {
    @StateObject private var store: PiResourcesStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReload = false
    @State private var confirmClose = false
    init(sessionID: String, api: WandAPI) { _store = StateObject(wrappedValue: PiResourcesStore(sessionID: sessionID, service: api)) }
    var body: some View {
        NavigationStack {
            Form {
                if store.loading { ProgressView() }
                if let message = store.message { Text(message).font(.caption).foregroundStyle(store.phase == .failed ? Theme.danger : Theme.textSecondary) }
                if let response = store.response {
                    if let reason = response.resourceCatalog?.reason, !reason.isEmpty { Text(reason).font(.caption) }
                    Section("Skills") {
                        ForEach(response.resourceCatalog?.skills ?? []) { skill in
                            VStack(alignment: .leading) {
                                Picker(skill.name, selection: Binding(get: { store.skillMode(skill.id) }, set: { store.setSkill(skill.id, mode: $0) })) {
                                    Text("关闭").tag("off"); Text("启用").tag("on")
                                    if response.skillLocksAvailable == true { Text("锁定").tag("locked") }
                                }
                                if let description = skill.description { Text(description).font(.caption).foregroundStyle(Theme.textSecondary) }
                            }
                        }
                    }.disabled(!response.editable || store.phase == .sending)
                    Section("MCP") {
                        ForEach(response.resourceCatalog?.mcpServers ?? []) { item in
                            Toggle(item.name, isOn: Binding(get: { store.draft.resources?.mcpServers.contains(item.id) == true }, set: { store.setMcp(item.id, enabled: $0) }))
                        }
                    }.disabled(!response.editable || store.phase == .sending)
                    Section("自动配置") {
                        Toggle("按本轮提示词选择资源", isOn: Binding(get: { store.draft.autoResources == true }, set: { store.draft.autoResources = $0 }))
                            .disabled(response.autoResourcesAvailable != true || store.phase == .sending)
                        if let reason = response.autoResourcesReason, !reason.isEmpty { Text(reason).font(.caption) }
                    }
                    Section("CodeMode") {
                        Picker("本会话", selection: Binding(get: { store.draft.codemodeOverride ?? "follow" }, set: { store.draft.codemodeOverride = $0 == "follow" ? nil : $0 })) {
                            Text(response.autoCodemodeAvailable == true ? "跟随自动选择" : "跟随全局").tag("follow")
                            Text("关闭").tag("off"); Text("启用").tag("on")
                            if response.codemodeOnlyAvailable { Text("仅 CodeMode").tag("only") }
                        }.disabled(!response.codemodeAvailable || store.phase == .sending)
                    }
                }
                Button("重新读取") { if store.dirty { confirmReload = true } else { Task { await store.load() } } }.disabled(store.phase == .sending)
            }
            .navigationTitle("工具与资源").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { if store.dirty { confirmClose = true } else { dismiss() } }.disabled(store.phase == .sending) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.save() } label: { Text(store.phase == .sending ? "保存中" : store.phase == .sent ? "已保存" : store.phase == .failed ? "失败" : "保存").frame(width: 64, height: 44) }
                        .disabled(!store.dirty || store.phase == .sending || store.uncertain)
                }
            }
        }.task { await store.load() }.onDisappear { store.close() }
        .interactiveDismissDisabled(store.dirty || store.phase == .sending)
        .alert("放弃未保存的资源选择？", isPresented: $confirmClose) {
            Button("继续编辑", role: .cancel) {}; Button("放弃选择", role: .destructive) { dismiss() }
        }
        .alert("重新读取会放弃尚未保存的选择", isPresented: $confirmReload) {
            Button("取消", role: .cancel) {}
            Button("重新读取") { Task { await store.load() } }
        }
    }
}
