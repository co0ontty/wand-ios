import Foundation
import Combine

enum KnowledgeScope: String, CaseIterable, Codable, Identifiable {
    case project, personal
    var id: String { rawValue }
    var label: String { self == .project ? "项目知识库" : "个人知识库" }
}

struct KnowledgeOwner: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    var readOnly: Bool?
    var isReadOnly: Bool { readOnly == true }
}

struct KnowledgeOwners: Decodable {
    let employees: [KnowledgeOwner]
    let projects: [KnowledgeOwner]
}

struct KnowledgeDocument: Decodable, Identifiable, Equatable {
    let id: String
    let scope: KnowledgeScope
    let ownerId: String
    let title: String
    let content: String
    let folder: String
    let revision: Int
    let createdAt: String
    let updatedAt: String
    var directoryName: String { folder.isEmpty ? "未分类" : folder }
}

struct KnowledgeLibraryPage: Decodable {
    let scope: KnowledgeScope
    let ownerId: String
    let ownerName: String
    let readOnly: Bool
    let entries: [KnowledgeDocument]
    let total: Int
    let limit: Int
}

struct KnowledgeDraft: Equatable {
    let scope: KnowledgeScope
    let ownerId: String
    let original: KnowledgeDocument?
    var title: String
    var content: String
    var folder: String
    var isDirty: Bool {
        title != (original?.title ?? "") || content != (original?.content ?? "") || folder != (original?.folder ?? "")
    }
    var validation: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写文档标题。" }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请写下需要保留的内容。" }
        if title.utf16.count > 100 { return "标题最多 100 字，请精简后保存。" }
        if content.utf16.count > 12_000 { return "正文最多 12000 字，内容已保留，请精简后保存。" }
        if folder.utf16.count > 100 { return "目录名称最多 100 字。" }
        return nil
    }
}

protocol KnowledgeService {
    func knowledgeOwners() async throws -> KnowledgeOwners
    func knowledgeLibrary(scope: KnowledgeScope, ownerId: String) async throws -> KnowledgeLibraryPage
    func saveKnowledge(_ draft: KnowledgeDraft) async throws -> KnowledgeDocument
    func deleteKnowledge(_ document: KnowledgeDocument) async throws
}

extension WandAPI: KnowledgeService {
    func knowledgeOwners() async throws -> KnowledgeOwners {
        try await request(KnowledgeOwners.self, method: "GET", path: "/api/knowledge/owners")
    }
    static func knowledgeLibraryPath(scope: KnowledgeScope, ownerId: String) -> String? {
        var components = URLComponents()
        components.path = "/api/knowledge"
        components.percentEncodedQuery = WandEndpoint.percentEncodedQuery([
            URLQueryItem(name: "scope", value: scope.rawValue), URLQueryItem(name: "ownerId", value: ownerId)
        ])
        return components.string
    }
    func knowledgeLibrary(scope: KnowledgeScope, ownerId: String) async throws -> KnowledgeLibraryPage {
        guard let path = Self.knowledgeLibraryPath(scope: scope, ownerId: ownerId) else { throw APIError.invalidURL }
        let page = try await request(KnowledgeLibraryPage.self, method: "GET", path: path)
        guard page.scope == scope, page.ownerId == ownerId,
              page.entries.allSatisfy({ $0.scope == scope && $0.ownerId == ownerId && $0.revision > 0 }),
              page.total == page.entries.count, page.entries.count <= 200 else {
            throw APIError.network("知识库归属或列表回执不一致，已停止显示。请刷新重试。")
        }
        return page
    }
    func saveKnowledge(_ draft: KnowledgeDraft) async throws -> KnowledgeDocument {
        struct Receipt: Decodable { let entry: KnowledgeDocument }
        var body: [String: Any] = ["scope": draft.scope.rawValue, "ownerId": draft.ownerId,
                                   "title": draft.title, "content": draft.content, "folder": draft.folder]
        if let original = draft.original { body["revision"] = original.revision }
        let suffix = draft.original.map { "/" + percentEncodePathComponent($0.id) } ?? ""
        let receipt = try await request(Receipt.self, method: draft.original == nil ? "POST" : "PATCH",
                                        path: "/api/knowledge" + suffix, body: body).entry
        guard receipt.scope == draft.scope, receipt.ownerId == draft.ownerId, receipt.revision > 0,
              draft.original == nil || receipt.id == draft.original?.id else {
            throw APIError.network("保存回执的归属不一致。草稿已保留，请刷新核对，勿重复保存。")
        }
        return receipt
    }
    func deleteKnowledge(_ document: KnowledgeDocument) async throws {
        struct Receipt: Decodable { let ok: Bool }
        let receipt = try await request(Receipt.self, method: "DELETE", path: "/api/knowledge/" + percentEncodePathComponent(document.id),
                                        body: ["scope": document.scope.rawValue, "ownerId": document.ownerId, "revision": document.revision])
        guard receipt.ok else { throw APIError.network("删除回执未确认，请刷新核对。") }
    }
}

/// Each server owns one store. Administrative selection never changes a running employee.
@MainActor final class KnowledgeLibraryStore: ObservableObject {
    @Published private(set) var owners: KnowledgeOwners?
    @Published private(set) var scope: KnowledgeScope = .project
    @Published private(set) var ownerId = ""
    @Published private(set) var page: KnowledgeLibraryPage?
    @Published private(set) var selectedID: String?
    @Published var query = ""
    @Published var draft: KnowledgeDraft?
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var conflict = false
    @Published var documentVisible = false
    @Published var showDiscard = false
    @Published var deleteCandidate: KnowledgeDocument?
    private var pendingNavigation: (() -> Void)?
    private var generation = 0
    private var ownerSelections: [KnowledgeScope: String] = [:]
    private let service: KnowledgeService
    init(service: KnowledgeService, scope: KnowledgeScope = .project, ownerId: String = "") {
        self.service = service; self.scope = scope; self.ownerId = ownerId
    }
    var hasUnsavedChanges: Bool { draft?.isDirty == true }
    var availableOwners: [KnowledgeOwner] { scope == .project ? owners?.projects ?? [] : owners?.employees ?? [] }
    var ownerName: String { page?.ownerName ?? availableOwners.first(where: { $0.id == ownerId })?.name ?? "" }
    var readOnly: Bool { page?.readOnly == true || availableOwners.first(where: { $0.id == ownerId })?.isReadOnly == true }
    var selected: KnowledgeDocument? { page?.entries.first { $0.id == selectedID } }
    var documents: [KnowledgeDocument] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (page?.entries ?? []).filter { value.isEmpty || ($0.title + "\n" + $0.content).localizedCaseInsensitiveContains(value) }
    }
    var folders: [String] { Array(Set(documents.map(\.directoryName))).sorted() }
    func loadIfNeeded() async { if owners == nil && !loading { await loadOwners() } }
    func loadOwners() async {
        guard !busy else { return }
        generation += 1; let request = generation
        loading = true; error = nil
        do {
            let result = try await service.knowledgeOwners()
            guard request == generation else { return }
            owners = result
            if ownerId.isEmpty { ownerId = availableOwners.first?.id ?? "" }
            else if !availableOwners.contains(where: { $0.id == ownerId }) {
                page = nil; selectedID = nil; loading = false
                error = "此知识库已不可用，请选择其他员工或项目。"; return
            }
            loading = false
            await loadLibrary()
        } catch {
            guard request == generation else { return }
            loading = false; self.error = error.localizedDescription
        }
    }
    func loadLibrary(preserveDraft: Bool = false) async {
        guard !busy else { return }
        generation += 1; let request = generation, capturedScope = scope, capturedOwner = ownerId
        guard !capturedOwner.isEmpty else { page = nil; selectedID = nil; loading = false; return }
        loading = true; error = nil
        do {
            let result = try await service.knowledgeLibrary(scope: capturedScope, ownerId: capturedOwner)
            guard request == generation, scope == capturedScope, ownerId == capturedOwner else { return }
            page = result; loading = false
            if !result.entries.contains(where: { $0.id == selectedID }) { selectedID = result.entries.first?.id }
            if !preserveDraft { conflict = false }
        } catch {
            guard request == generation else { return }
            loading = false; self.error = error.localizedDescription
        }
    }
    func guarded(_ action: @escaping () -> Void) {
        guard !busy else { return }
        if hasUnsavedChanges { pendingNavigation = action; showDiscard = true }
        else { action() }
    }
    func discardAndContinue() {
        guard !busy else { return }
        let action = pendingNavigation; pendingNavigation = nil; showDiscard = false; draft = nil; conflict = false
        action?()
    }
    func continueEditing() { pendingNavigation = nil; showDiscard = false }
    func changeScope(_ value: KnowledgeScope) {
        guard value != scope else { return }
        guarded { [weak self] in
            guard let self else { return }
            self.ownerSelections[self.scope] = self.ownerId
            self.scope = value
            self.switchOwner(self.ownerSelections[value].flatMap { id in self.availableOwners.contains { $0.id == id } ? id : nil } ?? self.availableOwners.first?.id ?? "")
        }
    }
    func changeOwner(_ id: String) {
        guard id != ownerId, availableOwners.contains(where: { $0.id == id }) else { return }
        guarded { [weak self] in self?.switchOwner(id) }
    }
    private func switchOwner(_ id: String) {
        generation += 1; ownerId = id; ownerSelections[scope] = id
        page = nil; selectedID = nil; query = ""; draft = nil; error = nil; notice = nil; conflict = false; documentVisible = false
        Task { await loadLibrary() }
    }
    func open(_ document: KnowledgeDocument) {
        guard document.scope == scope, document.ownerId == ownerId else { return }
        guarded { [weak self] in
            self?.draft = nil; self?.selectedID = document.id; self?.documentVisible = true; self?.error = nil; self?.notice = nil; self?.conflict = false
        }
    }
    func create() {
        guard page != nil, !ownerId.isEmpty, !readOnly else { return }
        guarded { [weak self] in
            guard let self else { return }
            self.draft = KnowledgeDraft(scope: self.scope, ownerId: self.ownerId, original: nil, title: "", content: "", folder: "")
            self.documentVisible = true; self.error = nil; self.notice = nil; self.conflict = false
        }
    }
    func edit() {
        guard let selected, !readOnly, !busy else { return }
        draft = KnowledgeDraft(scope: scope, ownerId: ownerId, original: selected, title: selected.title, content: selected.content, folder: selected.folder)
        error = nil; notice = nil; conflict = false
    }
    func cancelEdit() { guarded { [weak self] in self?.draft = nil; self?.error = nil; self?.conflict = false } }
    func backToDirectory() { guarded { [weak self] in self?.draft = nil; self?.documentVisible = false; self?.error = nil; self?.conflict = false } }
    func refresh() { guarded { [weak self] in self?.draft = nil; Task { await self?.loadOwners() } } }
    func refreshAfterConflict() { Task { await loadLibrary(preserveDraft: true) } }
    func save() async {
        guard !busy, let captured = draft, captured.scope == scope, captured.ownerId == ownerId, !readOnly else { return }
        if let validation = captured.validation { error = validation; return }
        busy = true; error = nil; notice = nil; let request = generation
        do {
            let saved = try await service.saveKnowledge(captured)
            guard request == generation, captured.scope == scope, captured.ownerId == ownerId else { busy = false; return }
            let retained = (page?.entries ?? []).filter { $0.id != saved.id } + [saved]
            page = KnowledgeLibraryPage(scope: scope, ownerId: ownerId, ownerName: ownerName, readOnly: readOnly,
                                        entries: retained, total: retained.count, limit: 200)
            if let current = draft, current != captured {
                draft = KnowledgeDraft(scope: scope, ownerId: ownerId, original: saved,
                                       title: current.title, content: current.content, folder: current.folder)
            } else { draft = nil }
            selectedID = saved.id; conflict = false; busy = false
            await loadLibrary()
            if request + 1 == generation { notice = "已保存" }
        } catch {
            guard request == generation else { busy = false; return }
            busy = false; conflict = Self.isConflict(error)
            self.error = conflict ? "文档已被更新或删除。草稿已保留；可刷新查看最新版本，再决定如何处理。" : error.localizedDescription + " 草稿已保留，请先刷新核对保存结果。"
        }
    }
    func deleteConfirmed(_ captured: KnowledgeDocument) async {
        guard !busy, captured.scope == scope, captured.ownerId == ownerId else { return }
        deleteCandidate = nil; busy = true; error = nil; notice = nil; let request = generation
        do {
            try await service.deleteKnowledge(captured)
            guard request == generation else { busy = false; return }
            if let current = page {
                let retained = current.entries.filter { $0.id != captured.id }
                page = KnowledgeLibraryPage(scope: current.scope, ownerId: current.ownerId,
                                            ownerName: current.ownerName, readOnly: current.readOnly,
                                            entries: retained, total: retained.count, limit: current.limit)
            }
            busy = false; if selectedID == captured.id { selectedID = nil }; draft = nil
            await loadLibrary(); notice = "已删除"
        } catch {
            guard request == generation else { busy = false; return }
            busy = false; self.error = error.localizedDescription + " 文档仍保留在当前页面，请刷新核对。"
        }
    }
    private static func isConflict(_ error: Error) -> Bool {
        if let error = error as? WandAPI.APIError, case .server(let status, _) = error { return status == 409 }
        return false
    }
}
