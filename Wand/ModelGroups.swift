import Combine
import Foundation
import SwiftUI

struct ModelGroup: Codable, Equatable, Identifiable {
    var id: String
    var provider: String
    var name: String
    var models: [String]
    var builtIn: Bool { id == "openrouter-free" && provider == "pi" }
    var selector: String { builtIn ? "wand-openrouter-free/auto" : "wand-model-group/" + provider + "/" + id }
    var body: [String: Any] { ["id": id, "provider": provider, "name": name.trimmingCharacters(in: .whitespacesAndNewlines), "models": models] }
}

func modelGroupValidation(_ groups: [ModelGroup]) -> String? {
    var identities = Set<String>(), names = Set<String>()
    for group in groups {
        guard group.id.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
              WandProvider.normalizedID(group.provider) == group.provider else { return "分组标识或工具无效" }
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "分组名称需为1–40个字符" }
        guard identities.insert(group.provider + "/" + group.id).inserted, names.insert(group.provider + "/" + name).inserted else { return "同一工具的分组标识或名称不能重复" }
        if group.id == "openrouter-free", !group.builtIn || name != "免费分组" { return "免费分组的工具与名称不可修改" }
        if !group.builtIn, group.provider == "pi", name == "免费分组" { return "请直接调整内置免费分组" }
        guard (group.builtIn || !group.models.isEmpty), group.models.count <= (group.builtIn ? 128 : 32), Set(group.models).count == group.models.count else { return "组内需有1–32个不重复的模型" }
        for model in group.models {
            guard !model.isEmpty, model.count <= 256, !model.hasPrefix("-"),
                  !model.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
                  model != "default", model != "wand-openrouter-free/auto", !model.hasPrefix("wand-model-group/"), model != "wand-auto-assign/auto" else { return "组内只能使用具体模型 ID，不能嵌套分组" }
            if model.hasPrefix("wand-openrouter-free/"), group.provider != "pi" { return "免费模型只属于 Pi" }
            if group.builtIn, !model.hasPrefix("wand-openrouter-free/") { return "免费分组只能包含免费池模型" }
        }
    }
    for provider in WandProvider.allCases where groups.filter({ !$0.builtIn && $0.provider == provider.rawValue }).count > 32 { return "每个工具最多32个分组" }
    return nil
}
func modelGroupsDraft(_ saved: [ModelGroup], catalog: ModelsResponse) -> [ModelGroup] {
    let free = saved.first { $0.builtIn }
    let ids = catalog.freeModels.map(\.id)
    var seen = Set<String>()
    let ordered = ((free?.models.filter { ids.contains($0) } ?? []) + ids).filter { seen.insert($0).inserted }
    return saved.filter { !$0.builtIn } + (catalog.modelGroupsSupported ? [ModelGroup(id: "openrouter-free", provider: "pi", name: "免费分组", models: ordered)] : [])
}

@MainActor
protocol ModelGroupsService {
    func modelGroupSettings() async throws -> [ModelGroup]
    func saveModelGroups(_ groups: [ModelGroup], expected: [ModelGroup]) async throws -> [ModelGroup]
}
extension WandAPI: ModelGroupsService {
    func modelGroupSettings() async throws -> [ModelGroup] {
        struct Config: Decodable { let modelGroups: [ModelGroup]? }
        struct Page: Decodable { let config: Config }
        return try await request(Page.self, method: "GET", path: "/api/settings").config.modelGroups ?? []
    }
    func saveModelGroups(_ groups: [ModelGroup], expected: [ModelGroup]) async throws -> [ModelGroup] {
        if let error = modelGroupValidation(groups) { throw APIError.server(status: 400, message: error) }
        struct Config: Decodable { let modelGroups: [ModelGroup] }
        struct Ack: Decodable { let config: Config }
        return try await request(Ack.self, method: "POST", path: "/api/settings/config", body: ["modelGroups": groups.map(\.body), "expectedModelGroups": expected.map(\.body)]).config.modelGroups
    }
}

@MainActor
final class ModelGroupsStore: ObservableObject {
    private let service: any ModelGroupsService
    @Published private(set) var saved: [ModelGroup] = []
    @Published var draft: [ModelGroup] = []
    @Published private(set) var phase = ComposerSendPhase.idle
    @Published private(set) var message: String?
    @Published private(set) var ready = false
    @Published private(set) var uncertain = false
    private var revision = 0
    private var active = true
    init(service: any ModelGroupsService) { self.service = service }
    var dirty: Bool { saved != draft }
    func load(catalog: ModelsResponse) async {
        guard phase != .sending else { return }
        active = true; revision += 1; let request = revision
        do {
            let rows = try await service.modelGroupSettings()
            guard active, request == revision else { return }
            saved = rows; draft = modelGroupsDraft(rows, catalog: catalog); ready = true; uncertain = false; phase = .idle; message = nil
        } catch { message = error.localizedDescription }
    }
    func save() {
        guard ready, dirty, active, !uncertain, phase != .sending else { return }
        if let error = modelGroupValidation(draft) { phase = .failed; message = error; return }
        let submitted = draft, expected = saved, request = revision
        phase = .sending; message = nil
        Task {
            do {
                let ack = try await service.saveModelGroups(submitted, expected: expected)
                guard active, request == revision else { return }
                saved = ack; if draft == submitted { draft = ack }
                phase = .sent; message = "已保存"
            } catch {
                guard active, request == revision else { return }
                phase = .failed
                if case WandAPI.APIError.server(409, _) = error { message = "分组已被其他客户端修改，当前草稿保留。请核对后重新读取。"; uncertain = true }
                else { uncertain = !isDefiniteInputRejection(error); message = uncertain ? "保存结果未确认，草稿保留。请重新读取核对。" : error.localizedDescription }
            }
        }
    }
    func close() { active = false; revision += 1 }
}

struct ModelGroupsView: View {
    let api: WandAPI
    @StateObject private var store: ModelGroupsStore
    @State private var catalog: ModelsResponse?
    @State private var provider = "claude"
    @State private var expandedID: String?
    @State private var password = ""
    @State private var loginMessage: String?
    @State private var loginBusy = false
    @State private var confirmReload = false
    @State private var confirmClose = false
    @Environment(\.dismiss) private var dismiss
    init(api: WandAPI) { self.api = api; _store = StateObject(wrappedValue: ModelGroupsStore(service: api)) }
    var body: some View {
        NavigationStack {
            Form {
                if !store.ready {
                    Section("管理认证") {
                        SecureField("管理密码", text: $password)
                        Button(loginBusy ? "认证中" : "登录并读取") { login() }.disabled(loginBusy || password.isEmpty)
                        if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(Theme.danger) }
                    }
                }
                Picker("执行工具", selection: $provider) { ForEach(WandProvider.allCases) { Text($0.title).tag($0.rawValue) } }
                if let message = store.message { Text(message).font(.caption).foregroundStyle(store.phase == .failed ? Theme.danger : Theme.textSecondary) }
                ForEach(store.draft.indices.filter { store.draft[$0].provider == provider }, id: \.self) { index in
                    DisclosureGroup(isExpanded: Binding(get: { expandedID == store.draft[index].id }, set: { expandedID = $0 ? store.draft[index].id : nil })) {
                        groupEditor(index)
                    } label: { Text(store.draft[index].name).font(.body.weight(.semibold)) }
                }
                if store.ready {
                    Button("添加分组") {
                        let group = ModelGroup(id: "g_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), provider: provider, name: "新分组", models: [])
                        store.draft.append(group); expandedID = group.id
                    }.disabled(store.phase == .sending)
                    Button("重新读取") { if store.dirty { confirmReload = true } else { Task { await load() } } }.disabled(store.phase == .sending)
                }
            }
            .navigationTitle("模型分组").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { if store.dirty { confirmClose = true } else { dismiss() } }.disabled(store.phase == .sending) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.save() } label: { Text(store.phase == .sending ? "保存中" : store.phase == .sent ? "已保存" : store.phase == .failed ? "失败" : "保存").frame(width: 64, height: 44) }
                        .disabled(!store.ready || !store.dirty || store.uncertain || store.phase == .sending || catalog?.modelGroupsSupported != true)
                }
            }
        }.task { await load() }.onDisappear { store.close(); password = "" }
        .interactiveDismissDisabled(store.dirty || store.phase == .sending)
        .alert("放弃未保存的分组修改？", isPresented: $confirmClose) {
            Button("继续编辑", role: .cancel) {}; Button("放弃修改", role: .destructive) { dismiss() }
        }
        .alert("重新读取会丢弃当前分组草稿", isPresented: $confirmReload) {
            Button("取消", role: .cancel) {}; Button("重新读取") { Task { await load() } }
        }
    }
    private func groupEditor(_ index: Int) -> some View {
        let group = store.draft[index]
        return VStack(alignment: .leading, spacing: 8) {
            TextField("分组名称", text: $store.draft[index].name).disabled(group.builtIn || store.phase == .sending)
            ForEach(Array(group.models.enumerated()), id: \.element) { row, model in
                HStack {
                    Text(model).font(.caption.monospaced()).lineLimit(2)
                    Spacer()
                    Button { if row > 0 { store.draft[index].models.swapAt(row, row - 1) } } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44) }.disabled(row == 0).accessibilityLabel("模型上移")
                    Button { if row + 1 < group.models.count { store.draft[index].models.swapAt(row, row + 1) } } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44) }.disabled(row + 1 == group.models.count).accessibilityLabel("模型下移")
                    if !group.builtIn { Button("移除") { store.draft[index].models.removeAll { $0 == model } } }
                }
            }
            if !group.builtIn {
                Menu("添加具体模型") {
                    ForEach((catalog?.models(for: provider) ?? []) + (provider == "pi" ? catalog?.freeModels ?? [] : [])) { model in
                        if model.id != "default", model.id != "wand-openrouter-free/auto", model.id != "wand-auto-assign/auto", !model.id.hasPrefix("wand-model-group/"), !group.models.contains(model.id) {
                            Button(model.label) { store.draft[index].models.append(model.id) }
                        }
                    }
                }
                Button("删除分组", role: .destructive) { store.draft.remove(at: index); expandedID = nil }
            } else { Text("免费池成员由服务端维护；这里只调整优先顺序。").font(.caption).foregroundStyle(Theme.textSecondary) }
        }.disabled(store.phase == .sending)
    }
    private func load() async {
        do { let catalog = try await api.models(); self.catalog = catalog; await store.load(catalog: catalog) }
        catch { loginMessage = error.localizedDescription }
    }
    private func login() {
        guard !loginBusy else { return }
        let submitted = password; password = ""; loginBusy = true
        Task {
            defer { loginBusy = false }
            do { _ = try await api.requestData(method: "POST", path: "/api/login", body: ["password": submitted]); await load() }
            catch { loginMessage = error.localizedDescription }
        }
    }
}
