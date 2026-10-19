import Combine
import Foundation
import SwiftUI

struct SessionFilePreview: Decodable, Equatable {
    let path: String
    let name: String
    let kind: String
    let size: Int?
    let mtime: String?
    var content: String?
    var canEdit: Bool { kind == "text" && content != nil && size != nil && mtime?.isEmpty == false }
}
struct SessionFileWriteResult: Decodable {
    let ok: Bool
    let size: Int
    let mtime: String
}
@MainActor
protocol SessionFilesService {
    func listDirectory(_ query: String) async throws -> DirectoryListing
    func previewFile(_ path: String) async throws -> SessionFilePreview
    func writeFile(_ file: SessionFilePreview, content: String) async throws -> SessionFileWriteResult
}
extension WandAPI: SessionFilesService {
    func previewFile(_ path: String) async throws -> SessionFilePreview {
        let result = try await request(SessionFilePreview.self, method: "GET", path: "/api/file-preview", queryItems: [URLQueryItem(name: "path", value: path)])
        guard result.path == path else { throw APIError.network("文件回执身份不一致") }
        return result
    }
    func writeFile(_ file: SessionFilePreview, content: String) async throws -> SessionFileWriteResult {
        guard file.canEdit else { throw APIError.server(status: 400, message: "此文件无法安全编辑，请重新读取") }
        let result = try await request(SessionFileWriteResult.self, method: "POST", path: "/api/file-write", body: ["path": file.path, "content": content, "expectedMtime": file.mtime!, "expectedSize": file.size!])
        guard result.ok, !result.mtime.isEmpty, result.size >= 0 else { throw APIError.network("服务端未确认保存，请重新读取核对") }
        return result
    }
}

enum FileActionPhase: Equatable { case idle, running, done, failed, uncertain }

/// Endpoint/session owned. An old read/write cannot replace a new file or unsaved edit.
@MainActor
final class SessionFilesStore: ObservableObject {
    private let service: any SessionFilesService
    @Published private(set) var open = false
    @Published private(set) var root = ""
    @Published private(set) var directory = ""
    @Published private(set) var listing: DirectoryListing?
    @Published private(set) var filePath: String?
    @Published private(set) var file: SessionFilePreview?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var editing = false
    @Published private(set) var draft = ""
    @Published private(set) var savePhase = FileActionPhase.idle
    @Published private(set) var saveConflict = false
    @Published private(set) var saveMessage: String?
    @Published private(set) var pendingDiscard: (() -> Void)?
    private var revision = 0
    private var loadTask: Task<Void, Never>?
    init(service: any SessionFilesService) { self.service = service }
    var dirty: Bool { editing && file != nil && draft != file?.content }
    var canSave: Bool { dirty && file?.canEdit == true && savePhase != .running && savePhase != .uncertain && !saveConflict }
    func show(cwd: String) {
        guard !cwd.isEmpty, !open else { return }
        root = cwd; open = true; loadDirectory(cwd)
    }
    private func navigate(_ action: @escaping () -> Void) {
        guard savePhase != .running else { return }
        if dirty { pendingDiscard = action } else { action() }
    }
    func requestClose() { navigate { [weak self] in self?.shutdown() } }
    func requestDirectory(_ path: String) { navigate { [weak self] in self?.loadDirectory(path) } }
    func requestFile(_ path: String) { navigate { [weak self] in self?.loadFile(path) } }
    func requestReload() { navigate { [weak self] in guard let self else { return }; if let filePath { loadFile(filePath) } else { loadDirectory(directory) } } }
    func cancelDiscard() { pendingDiscard = nil }
    func confirmDiscard() { let action = pendingDiscard; pendingDiscard = nil; action?() }
    func requestBack() {
        if filePath != nil { requestDirectory(directory) }
        else if directory != root && directory != "/" { requestDirectory((directory as NSString).deletingLastPathComponent) }
        else { requestClose() }
    }
    private func resetFile() {
        file = nil; editing = false; draft = ""; savePhase = .idle; saveMessage = nil; saveConflict = false; error = nil
    }
    private func loadDirectory(_ path: String) {
        revision += 1; let request = revision; loadTask?.cancel()
        directory = path; filePath = nil; listing = nil; resetFile(); loading = true
        loadTask = Task {
            defer { if request == revision { loading = false } }
            do {
                let value = try await service.listDirectory(path)
                guard open, request == revision, !Task.isCancelled else { return }
                listing = value
            } catch { if open, request == revision, !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func loadFile(_ path: String) {
        revision += 1; let request = revision; loadTask?.cancel()
        resetFile(); filePath = path; loading = true
        loadTask = Task {
            defer { if request == revision { loading = false } }
            do {
                let value = try await service.previewFile(path)
                guard open, request == revision, !Task.isCancelled else { return }
                file = value; draft = value.content ?? ""
            } catch { if open, request == revision, !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func toggleEditing() {
        guard savePhase != .running, file?.canEdit == true else { return }
        if editing { navigate { [weak self] in self?.editing = false; self?.draft = self?.file?.content ?? "" } }
        else { editing = true }
    }
    func edit(_ value: String) {
        guard editing, savePhase != .running else { return }
        draft = value
        if savePhase != .uncertain && !saveConflict { savePhase = .idle; saveMessage = nil }
    }
    func save() {
        guard canSave, let original = file else { return }
        let submitted = draft; let request = revision
        savePhase = .running; saveMessage = nil
        Task {
            do {
                let result = try await service.writeFile(original, content: submitted)
                guard open, request == revision else { return }
                guard result.ok else { throw WandAPI.APIError.network("服务端未确认保存") }
                file = SessionFilePreview(path: original.path, name: original.name, kind: original.kind,
                    size: result.size, mtime: result.mtime, content: submitted)
                savePhase = .done; saveMessage = "已保存到服务器"
            } catch {
                guard open, request == revision else { return }
                let status: Int?
                if case WandAPI.APIError.server(let code, _) = error { status = code } else { status = nil }
                saveConflict = status == 409
                savePhase = status == nil || status == 408 || (status ?? 0) >= 500 ? .uncertain : .failed
                saveMessage = saveConflict ? "文件已被外部修改，草稿保留。请复制草稿后重新读取。"
                    : savePhase == .uncertain ? "保存结果未确认，草稿保留。请复制并重新读取核对，不要重复保存。"
                    : error.localizedDescription
            }
        }
    }
    func shutdown() { open = false; revision += 1; loadTask?.cancel(); pendingDiscard = nil }
}

struct SessionFilesView: View {
    @ObservedObject var store: SessionFilesStore
    let api: WandAPI
    @StateObject private var links = ServerFileLinkController()
    @State private var downloadPhase = FileActionPhase.idle
    @State private var downloadMessage: String?
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if store.filePath != nil { fileContent }
                else { directoryContent }
            }
            .background(Theme.background)
            .navigationTitle(store.file?.name ?? "文件").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("返回") { store.requestBack() }.disabled(store.savePhase == .running) }
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { store.requestClose() }.disabled(store.savePhase == .running) }
            }
            .safeAreaInset(edge: .bottom) {
                if let file = store.file {
                    HStack {
                        if file.canEdit { Button(store.editing ? "预览" : "编辑") { store.toggleEditing() }.disabled(store.savePhase == .running) }
                        if store.editing {
                            Button { store.save() } label: { Text(saveLabel).frame(width: 100, height: 44) }
                                .buttonStyle(.borderedProminent).disabled(!store.canSave)
                            Button("复制草稿") { UIPasteboard.general.string = store.draft }
                        }
                        Spacer()
                        Button(action: download) { Text(downloadLabel).frame(minWidth: 64, minHeight: 44) }.disabled(links.isDownloading || store.savePhase == .running)
                    }.padding(12).background(Theme.elevated)
                }
            }
        }
        .interactiveDismissDisabled(store.dirty || store.savePhase == .running)
        .confirmationDialog("尚有未保存修改", isPresented: Binding(get: { store.pendingDiscard != nil }, set: { if !$0 { store.cancelDiscard() } }), titleVisibility: .visible) {
            Button("继续编辑", role: .cancel) { store.cancelDiscard() }
            Button("丢弃修改", role: .destructive) { store.confirmDiscard() }
        }
        .sheet(item: $links.previewItem, onDismiss: links.dismissPreview) { ServerFilePreviewView(item: $0) }
        .onChange(of: links.previewItem?.id) { _, value in if value != nil { downloadPhase = .done; downloadMessage = "已下载，可预览或分享" } }
        .onChange(of: links.failure?.id) { _, _ in if let failure = links.failure { downloadPhase = .failed; downloadMessage = failure.message } }
        .onChange(of: store.filePath) { _, _ in links.cancel(); downloadPhase = .idle; downloadMessage = nil }
        .onChange(of: store.directory) { _, _ in filter = "" }
        .onChange(of: store.open) { _, open in if !open { dismiss() } }
        .onDisappear { links.cancel() }
    }
    private var saveLabel: String {
        switch store.savePhase { case .idle: return "保存"; case .running: return "保存中"; case .done: return "已保存"; case .failed: return "保存失败"; case .uncertain: return "未确认" }
    }
    private var downloadLabel: String {
        switch downloadPhase { case .running: return "下载中"; case .done: return "已下载"; case .failed: return "下载失败"; default: return "下载" }
    }
    private var directoryContent: some View {
        List {
            Text(store.directory).font(.caption.monospaced()).textSelection(.enabled)
            if store.directory != store.root {
                Button("返回会话目录", systemImage: "folder") { store.requestDirectory(store.root) }
            }
            TextField("筛选文件", text: $filter)
            if store.loading { ProgressView() }
            if let error = store.error { Text(error).foregroundStyle(Theme.danger); Button("重试") { store.requestReload() } }
            if store.directory != "/" { Button("上一级") { store.requestDirectory((store.directory as NSString).deletingLastPathComponent) } }
            ForEach(store.listing?.items.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) } ?? []) { item in
                Button { if item.isDirectory { store.requestDirectory(item.path) } else { store.requestFile(item.path) } } label: {
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "doc").frame(minHeight: 32)
                }
            }
            if store.listing?.truncated == true { Text("目录条目已截断，可缩小筛选或打开子目录。").font(.caption) }
        }.listStyle(.plain).refreshable { store.requestReload() }
    }
    private var fileContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.filePath ?? "").font(.caption.monospaced()).textSelection(.enabled)
            if let error = store.error { Text(error).foregroundStyle(Theme.danger); Button("重新读取") { store.requestReload() } }
            if let message = store.saveMessage { Text(message).font(.caption).foregroundStyle(store.savePhase == .done ? Theme.success : Theme.danger) }
            if let message = downloadMessage { Text(message).font(.caption).foregroundStyle(Theme.textSecondary) }
            if store.loading { ProgressView() }
            if store.editing {
                TextEditor(text: Binding(get: { store.draft }, set: store.edit)).font(.body.monospaced()).disabled(store.savePhase == .running)
            } else if let file = store.file, file.kind == "image" {
                WandRemoteImage(baseURL: api.baseURL, path: file.path) {
                    Label("图片暂不可用，可重试或下载", systemImage: "photo")
                }.frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                    .accessibilityLabel(file.name).id(file.path)
            } else if let content = store.file?.content {
                ScrollView([.horizontal, .vertical]) { Text(content).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Text("此文件可通过下载进行系统预览或分享。").foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func download() {
        guard let path = store.filePath else { return }
        downloadPhase = .running; downloadMessage = nil
        links.open(serverPath: path, api: api)
    }
}
