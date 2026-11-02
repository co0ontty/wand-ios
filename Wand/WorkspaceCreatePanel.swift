import SwiftUI

struct WorkspaceCreateDraft: Equatable {
    var name = ""
    var cwd = ""
    var provider: WandProvider? = nil
    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedCwd: String { normalizeWorkspaceDirectory(cwd) }
    var validationError: String? {
        if normalizedName.isEmpty { return "请填写工作区名称。" }
        if normalizedCwd.isEmpty { return "请选择工作目录。" }
        if normalizedName.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            return "工作区名称不能包含换行或控制字符。"
        }
        return nil
    }
}

/// 创建直接从小节的加号展开。失败保留输入，待确认的回执先核对服务端事实。
struct WorkspaceCreatePanel: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    let onCreated: (Workspace) -> Void
    let onBusy: (Bool) -> Void
    @State private var draft = WorkspaceCreateDraft()
    @State private var busy = false
    @State private var message: String?
    @State private var unconfirmed = false
    @State private var submittedDraft: WorkspaceCreateDraft?
    @State private var knownWorkspaceIDs = Set<String>()
    @State private var suggestions: [WorkspacePathSuggestion] = []
    @State private var browsing = false
    @FocusState private var directoryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("路径别名", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .disabled(unconfirmed)
                .accessibilityLabel("路径别名")
            TextField("工作目录", text: $draft.cwd)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($directoryFocused)
                .disabled(unconfirmed)
                .accessibilityLabel("工作目录")
            if directoryFocused && !suggestions.isEmpty {
                ForEach(suggestions.prefix(5)) { suggestion in
                    Button {
                        draft.cwd = suggestion.path
                        directoryFocused = false
                    } label: {
                        Label(suggestion.path, systemImage: "folder")
                            .font(.footnote)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
            Button("浏览目录", systemImage: "folder") { browsing = true }.disabled(unconfirmed)
            Picker("默认工具", selection: $draft.provider) {
                Text("跟随默认").tag(nil as WandProvider?)
                ForEach(WandProvider.allCases) { provider in
                    Text(provider.title).tag(Optional(provider))
                }
            }
            .tint(Theme.brand)
            .disabled(unconfirmed)
            if let message {
                Text(message).font(.footnote).foregroundColor(unconfirmed ? Theme.textSecondary : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if unconfirmed {
                    Button("刷新并核对") { Task { await reconcile() } }
                        .buttonStyle(WandSecondaryButtonStyle())
                } else {
                    Button { Task { await create() } } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "正在创建…" : "创建工作区")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WandPrimaryButtonStyle())
                    .disabled(draft.validationError != nil)
                }
            }
        }
        .disabled(busy)
        .sheet(isPresented: $browsing) {
            DirectoryBrowserView(api: api, startPath: draft.cwd.isEmpty ? "~" : draft.cwd) { path in
                draft.cwd = path; browsing = false
            }
        }
        .padding(.vertical, 10)
        .task {
            if draft.cwd.isEmpty, let config = try? await api.serverConfig() {
                guard draft.cwd.isEmpty, !busy, !unconfirmed, !Task.isCancelled else { return }
                draft.cwd = config.defaultCwd ?? ""
            }
        }
        .task(id: "\(directoryFocused)-\(draft.cwd)") {
            guard directoryFocused else { return }
            let query = draft.normalizedCwd
            try? await Task.sleep(nanoseconds: WandMotion.searchDebounce)
            guard !Task.isCancelled else { return }
            let values = (try? await api.workspacePathSuggestions(query: query)) ?? []
            guard !Task.isCancelled, directoryFocused, query == draft.normalizedCwd else { return }
            suggestions = values.filter(\.isDirectory)
        }
    }

    private func create() async {
        guard !busy, !unconfirmed else { return }
        if let error = draft.validationError { message = error; return }
        let submitted = draft
        submittedDraft = submitted
        knownWorkspaceIDs = Set(store.workspaces.map(\.id))
        busy = true; onBusy(true); message = nil
        defer { busy = false; onBusy(unconfirmed) }
        do {
            let created = try await store.createWorkspace(name: submitted.normalizedName,
                cwd: submitted.normalizedCwd, defaultProvider: submitted.provider)
            onCreated(created)
        } catch {
            unconfirmed = !isDefiniteInputRejection(error)
            message = unconfirmed ? "创建结果未确认。请先刷新并核对，避免重复创建。" : error.localizedDescription
        }
    }

    private func reconcile() async {
        guard !busy else { return }
        busy = true; onBusy(true)
        defer { busy = false; onBusy(unconfirmed) }
        await store.loadWorkspaceIndex()
        guard store.indexState == .loaded else {
            message = "暂时无法核对，请恢复连接后重试。"; return
        }
        guard let submittedDraft else { return }
        let matches = store.workspaces.filter {
            $0.name == submittedDraft.normalizedName
                && normalizeWorkspaceDirectory($0.cwd) == submittedDraft.normalizedCwd
        }
        if matches.count == 1, let created = matches.first { unconfirmed = false; onCreated(created) }
        else {
            message = matches.isEmpty ? "尚未找到对应工作区。创建请求可能仍在处理，请稍后继续刷新核对。" : "发现多个同名工作区，无法确认此次结果，请在列表核对。"
        }
    }
}


private struct WorkspaceAPIEnvironmentKey: EnvironmentKey {
    static let defaultValue: WandAPI? = nil
}
extension EnvironmentValues {
    var workspaceAPI: WandAPI? {
        get { self[WorkspaceAPIEnvironmentKey.self] }
        set { self[WorkspaceAPIEnvironmentKey.self] = newValue }
    }
}

struct WorkspaceSelector: View {
    @Binding var selection: String
    let choices: [(id: String, name: String)]
    var emptyLabel = "未归属工作区"
    var onCreated: (Workspace) -> Void = { _ in }
    @Environment(\.workspaceAPI) private var api
    @State private var adding = false
    @State private var added: Workspace?

    var body: some View {
        Menu {
            Button(emptyLabel) { selection = "" }
            ForEach(choices, id: \.id) { choice in
                Button(choice.name) { selection = choice.id }
            }
            if let added, !choices.contains(where: { $0.id == added.id }) {
                Button(added.name) { selection = added.id }
            }
            Divider()
            Button("添加工作区", systemImage: "plus") { adding = true }
        } label: {
            Label(choices.first { $0.id == selection }?.name ?? (added?.id == selection ? added?.name : nil) ?? emptyLabel, systemImage: "folder")
        }
        .accessibilityLabel("选择工作区")
        .sheet(isPresented: $adding) {
            if let api {
                WorkspaceAddDialog(api: api) { workspace in
                    added = workspace; selection = workspace.id; onCreated(workspace); adding = false
                }
            }
        }
    }
}

/// 由页面的稳定容器呈现，不挂在会随键盘/滚动消失的菜单或列表行上。
struct WorkspaceAddDialog: View {
    let api: WandAPI
    let onCreated: (Workspace) -> Void
    @StateObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    init(api: WandAPI, onCreated: @escaping (Workspace) -> Void) {
        self.api = api; self.onCreated = onCreated
        _store = StateObject(wrappedValue: WorkspaceStore(api: api, serverID: api.baseURL.absoluteString))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                WorkspaceCreatePanel(api: api, store: store, onCreated: { workspace in
                    api.taskChanges.send(); onCreated(workspace)
                }, onBusy: { busy = $0 }).padding()
            }.navigationTitle("添加工作区").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
        }.interactiveDismissDisabled(busy)
    }
}
