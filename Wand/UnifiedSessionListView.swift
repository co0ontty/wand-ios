import SwiftUI

/// Android 主线同款的统一会话入口：分页混排会话/原生历史，并可切到 cwd 目录树。
struct UnifiedSessionListView: View {
    let api: WandAPI
    let serverID: String

    @Binding var selection: String?
    @Binding var selectedSnapshot: SessionSnapshot?
    @Binding var openingSessionID: String?

    @EnvironmentObject private var serverStore: ServerStore
    @StateObject private var listStore: SessionListStore
    @ObservedObject private var quickActions = QuickActionCoordinator.shared
    @AppStorage(SessionListViewMode.storageKey) private var viewModeRaw = SessionListViewMode.sessions.rawValue

    @State private var showNewSession = false
    @State private var newSessionInitialCwd: String?
    @State private var selectedKeys: Set<String> = []
    @State private var isSelecting = false
    @State private var pendingDelete: DeleteRequest?
    @State private var expandedDirectories: Set<String> = []
    @State private var knownRootDirectories: Set<String> = []
    @State private var renameTarget: SessionDirectoryNode?
    @State private var renameDraft = ""
    @State private var renameError: String?

    init(
        api: WandAPI,
        serverID: String,
        selection: Binding<String?>,
        selectedSnapshot: Binding<SessionSnapshot?>,
        openingSessionID: Binding<String?>
    ) {
        self.api = api
        self.serverID = serverID
        _selection = selection
        _selectedSnapshot = selectedSnapshot
        _openingSessionID = openingSessionID
        _listStore = StateObject(wrappedValue: SessionListStore(api: api, serverID: serverID))
    }

    private var viewMode: SessionListViewMode {
        SessionListViewMode(rawValue: viewModeRaw) ?? .sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isSelecting {
                viewModePicker
            }
            content
        }
        .background(WandAmbientBackground())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView(
                api: api,
                hostServerID: serverID,
                initialCwd: newSessionInitialCwd
            ) { snapshot, targetServerID in
                showNewSession = false
                newSessionInitialCwd = nil
                if targetServerID == serverID {
                    Task {
                        await listStore.addCreated(snapshot)
                        SessionPresenceController.shared.sync(snapshot: snapshot, serverID: serverID)
                        selectSession(snapshot)
                    }
                } else {
                    _ = serverStore.activateProfile(id: targetServerID)
                    QuickActionCoordinator.shared.enqueue(
                        .openSession(id: snapshot.id, serverID: targetServerID)
                    )
                }
            }
            .environmentObject(serverStore)
        }
        .confirmationDialog(
            pendingDelete?.title ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { performPendingDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("此操作无法撤销。托管会话和 Provider 原生历史会从对应服务器删除。")
        }
        .alert("重命名工作区", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil; renameError = nil } }
        )) {
            TextField("工作区名称（留空恢复目录名）", text: $renameDraft)
            Button("保存") { saveDirectoryName() }
                .disabled(listStore.directoryRenamePath != nil)
            Button("取消", role: .cancel) {
                renameTarget = nil
                renameError = nil
            }
        } message: {
            Text(renameError ?? renameTarget?.path ?? "")
        }
        .task {
            listStore.startSync()
            if viewMode == .directories {
                _ = await listStore.loadDirectories()
            }
        }
        .onDisappear { listStore.stopSync() }
        .onChange(of: viewModeRaw) { _, raw in
            endSelection()
            if raw == SessionListViewMode.directories.rawValue {
                Task { _ = await listStore.loadDirectories() }
            }
        }
        .onChange(of: listStore.directoryTree?.treeRevision) { _, _ in
            expandInitialAndSelectedPaths()
        }
        .onChange(of: selection) { _, _ in expandInitialAndSelectedPaths() }
        .onChange(of: listStore.entries.map(\.key)) { _, keys in
            selectedKeys.formIntersection(keys)
        }
        .onReceive(quickActions.$pending) { _ in handleQuickAction() }
        .onReceive(NotificationCenter.default.publisher(for: .wandBeginSessionSelection)) { _ in
            guard viewMode == .sessions else { return }
            isSelecting = true
        }
        .wandKeyboardShortcuts(keyboardShortcuts)
    }

    private var viewModePicker: some View {
        Picker("列表视图", selection: $viewModeRaw) {
            Label("会话", systemImage: "bubble.left.and.bubble.right")
                .tag(SessionListViewMode.sessions.rawValue)
            Label("目录", systemImage: "folder")
                .tag(SessionListViewMode.directories.rawValue)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .accessibilityLabel("会话列表视图")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(isSelecting ? "已选择 \(selectedKeys.count) 项" : viewMode == .sessions ? "会话" : "目录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                if isSelecting { endSelection() }
                else { presentNewSession(cwd: nil) }
            } label: {
                Image(systemName: isSelecting ? "xmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.brand)
            }
            .accessibilityLabel(isSelecting ? "退出选择" : "新建会话")
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewMode == .directories {
            directoryContent
        } else {
            sessionContent
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        if listStore.loading && listStore.entries.isEmpty {
            loadingState("正在加载会话…")
        } else if let error = listStore.loadError, listStore.entries.isEmpty {
            errorState(error) { Task { _ = await listStore.load() } }
        } else if listStore.entries.isEmpty {
            emptyState(
                icon: "wand.and.stars",
                title: "还没有会话",
                subtitle: "新建一个会话，开始与 AI 协作"
            ) { presentNewSession(cwd: nil) }
        } else {
            List {
                if let error = listStore.loadError {
                    inlineError(error)
                }
                ForEach(listStore.entries) { entry in
                    entryRow(entry, inDirectory: false)
                        .onAppear { loadMoreIfNeeded(after: entry) }
                }
                if listStore.loadingMore {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载更多会话…")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { _ = await listStore.load(silent: true) }
        }
    }

    @ViewBuilder
    private var directoryContent: some View {
        if listStore.directoryLoading && listStore.directoryTree == nil {
            loadingState("正在整理目录…")
        } else if let error = listStore.directoryError, listStore.directoryTree == nil {
            errorState(error) { Task { _ = await listStore.loadDirectories() } }
        } else if let tree = listStore.directoryTree, !tree.roots.isEmpty {
            List {
                if let error = listStore.directoryError {
                    inlineError(error)
                }
                ForEach(flattenedDirectoryRows(tree.roots)) { row in
                    switch row {
                    case .folder(let node, let depth):
                        directoryFolderRow(node, depth: depth)
                    case .entry(let entry, let depth):
                        entryRow(entry, inDirectory: true)
                            .padding(.leading, CGFloat(min(depth, 6)) * 12)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { _ = await listStore.loadDirectories(silent: true) }
        } else {
            emptyState(
                icon: "folder",
                title: "还没有会话目录",
                subtitle: "创建会话后会按工作目录显示在这里"
            ) { presentNewSession(cwd: nil) }
        }
    }

    private func entryRow(_ entry: SessionListEntry, inDirectory: Bool) -> some View {
        Group {
            switch entry {
            case .managed(_, _, let session):
                SessionRow(
                    session: session,
                    selecting: isSelecting && !inDirectory,
                    selected: selectedKeys.contains(entry.key)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelecting && !inDirectory { toggleSelection(entry.key) }
                    else { selectSession(session) }
                }
            case .recoverable(_, _, let history):
                HStack(spacing: 10) {
                    if isSelecting && !inDirectory {
                        Image(systemName: selectedKeys.contains(entry.key) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedKeys.contains(entry.key) ? Theme.brand : Theme.textSecondary)
                    }
                    HistorySessionRow(
                        history: history,
                        loading: listStore.isRestoring(history)
                    )
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelecting && !inDirectory { toggleSelection(entry.key) }
                    else { restore(history) }
                }
            }
        }
        .disabled(listStore.isRestoringHistory && entry.history != nil)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = DeleteRequest(entries: [entry])
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            if !inDirectory {
                Button {
                    isSelecting = true
                    selectedKeys.insert(entry.key)
                } label: {
                    Label("多选会话", systemImage: "checkmark.circle")
                }
            }
            Button(role: .destructive) {
                pendingDelete = DeleteRequest(entries: [entry])
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }

    private func directoryFolderRow(_ node: SessionDirectoryNode, depth: Int) -> some View {
        let expanded = expandedDirectories.contains(node.id)
        return HStack(spacing: 9) {
            Button {
                if expanded { expandedDirectories.remove(node.id) }
                else { expandedDirectories.insert(node.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 20, height: 32)
            }
            .buttonStyle(.plain)
            Image(systemName: expanded ? "folder.fill" : "folder")
                .foregroundColor(node.containsSession(selection) ? Theme.brand : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(node.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text("\(node.totalCount)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            if !node.synthetic && !node.path.isEmpty {
                Menu {
                    Button { presentNewSession(cwd: node.path) } label: {
                        Label("在此目录新建会话", systemImage: "plus")
                    }
                    Button { beginRename(node) } label: {
                        Label("重命名工作区", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 30, height: 32)
                }
            }
        }
        .padding(.leading, CGFloat(min(depth, 6)) * 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded { expandedDirectories.remove(node.id) }
            else { expandedDirectories.insert(node.id) }
        }
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("工作区 \(node.displayName)，\(node.totalCount) 个会话")
    }

    private var selectionBar: some View {
        HStack {
            Button(selectedKeys.count == listStore.entries.count ? "取消全选" : "全选") {
                if selectedKeys.count == listStore.entries.count { selectedKeys.removeAll() }
                else { selectedKeys = Set(listStore.entries.map(\.key)) }
            }
            Spacer()
            Button(role: .destructive) {
                let targets = listStore.entries.filter { selectedKeys.contains($0.key) }
                guard !targets.isEmpty else { return }
                pendingDelete = DeleteRequest(entries: targets)
            } label: {
                Label("删除 \(selectedKeys.count)", systemImage: "trash")
            }
            .disabled(selectedKeys.isEmpty)
            Spacer()
            Button("完成") { endSelection() }
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(Theme.border) }
    }

    private var keyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "refresh-sessions",
                title: viewMode == .sessions ? "刷新会话" : "刷新目录",
                key: "r",
                modifiers: .command,
                isEnabled: !listStore.loading && !listStore.directoryLoading
            ) {
                Task {
                    if viewMode == .sessions { _ = await listStore.load(silent: true) }
                    else { _ = await listStore.loadDirectories(silent: true) }
                }
            },
            WandKeyboardShortcutAction(
                id: "end-selection",
                title: "退出选择",
                key: .escape,
                modifiers: [],
                isEnabled: isSelecting
            ) { endSelection() },
        ]
    }

    private func selectSession(_ snapshot: SessionSnapshot) {
        guard shouldBeginSessionOpen(
            requestedID: snapshot.id,
            currentSelection: selection,
            openingSessionID: openingSessionID
        ) else { return }
        openingSessionID = snapshot.id
        selection = snapshot.id
        selectedSnapshot = snapshot
    }

    private func clearSelection() {
        openingSessionID = nil
        selection = nil
        selectedSnapshot = nil
    }

    private func restore(_ history: HistorySession) {
        guard !listStore.isRestoringHistory else { return }
        Task {
            guard let snapshot = await listStore.restore(history) else { return }
            SessionPresenceController.shared.sync(snapshot: snapshot, serverID: serverID)
            selectSession(snapshot)
        }
    }

    private func handleQuickAction() {
        guard let action = quickActions.consume(where: { action in
            guard action.belongs(to: serverID) else { return false }
            switch action {
            case .newSession, .openSession, .showSessions: return true
            case .openWeb: return false
            }
        }) else { return }

        switch action {
        case .newSession:
            clearSelection()
            presentNewSession(cwd: nil)
        case .openSession(let id, _):
            showNewSession = false
            if let snapshot = listStore.managedSessions.first(where: { $0.id == id }) {
                selectSession(snapshot)
            } else {
                guard shouldBeginSessionOpen(
                    requestedID: id,
                    currentSelection: selection,
                    openingSessionID: openingSessionID
                ) else { return }
                openingSessionID = id
                selection = id
                selectedSnapshot = nil
                Task {
                    let snapshot = try? await api.getSession(id: id)
                    if let snapshot {
                        SessionPresenceController.shared.sync(snapshot: snapshot, serverID: serverID)
                    }
                    if selection == id { selectedSnapshot = snapshot }
                }
            }
        case .showSessions:
            showNewSession = false
            clearSelection()
        case .openWeb:
            break
        }
    }

    private func loadMoreIfNeeded(after entry: SessionListEntry) {
        guard listStore.canLoadMore,
              listStore.entries.suffix(4).contains(where: { $0.key == entry.key }) else { return }
        Task { _ = await listStore.loadMore() }
    }

    private func presentNewSession(cwd: String?) {
        newSessionInitialCwd = cwd
        showNewSession = true
    }

    private func toggleSelection(_ key: String) {
        if selectedKeys.contains(key) { selectedKeys.remove(key) }
        else { selectedKeys.insert(key) }
    }

    private func endSelection() {
        isSelecting = false
        selectedKeys.removeAll()
    }

    private func performPendingDelete() {
        guard let request = pendingDelete else { return }
        pendingDelete = nil
        if request.entries.contains(where: { $0.session?.id == selection }) {
            clearSelection()
        }
        endSelection()
        Task { _ = await listStore.delete(request.entries) }
    }

    private func beginRename(_ node: SessionDirectoryNode) {
        renameTarget = node
        renameDraft = node.customName ?? ""
        renameError = nil
    }

    private func saveDirectoryName() {
        guard let target = renameTarget else { return }
        do {
            _ = try SessionDirectoryNameValidation.normalized(renameDraft)
        } catch {
            renameError = error.localizedDescription
            return
        }
        Task {
            if await listStore.renameDirectory(path: target.path, name: renameDraft) {
                renameTarget = nil
                renameError = nil
            } else {
                renameError = listStore.directoryError ?? "无法保存工作区名称"
            }
        }
    }

    private func expandInitialAndSelectedPaths() {
        guard let tree = listStore.directoryTree else { return }
        for root in tree.roots {
            // A newly discovered root starts expanded once. Polling must preserve an
            // explicit user collapse instead of treating each tree revision as first load.
            if knownRootDirectories.insert(root.id).inserted {
                expandedDirectories.insert(root.id)
            }
            expandSelectedPath(in: root)
        }
    }

    private func expandSelectedPath(in node: SessionDirectoryNode) {
        guard node.containsSession(selection) else { return }
        expandedDirectories.insert(node.id)
        for child in node.children { expandSelectedPath(in: child) }
    }

    private func flattenedDirectoryRows(_ roots: [SessionDirectoryNode]) -> [DirectoryRow] {
        var rows: [DirectoryRow] = []
        func append(_ node: SessionDirectoryNode, depth: Int) {
            rows.append(.folder(node, depth: depth))
            guard expandedDirectories.contains(node.id) else { return }
            rows += node.entries.map { .entry($0, depth: depth + 1) }
            for child in node.children { append(child, depth: depth + 1) }
        }
        for root in roots { append(root, depth: 0) }
        return rows
    }

    private func loadingState(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.brand)
            Text(text).font(.footnote).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(Theme.textSecondary)
            Text(message)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry).buttonStyle(WandSecondaryButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(Theme.brand)
            Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(Theme.textPrimary)
            Text(subtitle).font(.footnote).foregroundColor(Theme.textSecondary)
            Button("新建会话", action: action).buttonStyle(WandPrimaryButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundColor(Theme.danger)
            .listRowBackground(Theme.danger.opacity(0.08))
            .onTapGesture { listStore.clearLoadError(message); listStore.clearDirectoryError(message) }
    }
}

private struct DeleteRequest: Identifiable {
    let entries: [SessionListEntry]
    var id: String { entries.map(\.key).sorted().joined(separator: "|") }
    var title: String { entries.count == 1 ? "删除会话" : "删除 \(entries.count) 个会话" }
}

private enum DirectoryRow: Identifiable {
    case folder(SessionDirectoryNode, depth: Int)
    case entry(SessionListEntry, depth: Int)

    var id: String {
        switch self {
        case .folder(let node, _): return "folder:\(node.id)"
        case .entry(let entry, _): return "entry:\(entry.key)"
        }
    }
}
