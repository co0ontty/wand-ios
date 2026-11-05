import SwiftUI

struct SessionDirectory: Decodable {
    let workspaceId: String
    let isGit: Bool
    let root: String
    let branch: String
    let head: String
    let worktrees: [Tree]
    struct Tree: Decodable, Identifiable {
        let path: String
        let name: String
        let branch: String
        let head: String
        var id: String { path }
    }
}
struct DirectoryMergeCheck: Decodable {
    let ok: Bool
    let sourceBranch: String
    let targetBranch: String
    let worktreePath: String
    let sourceHead: String
    let targetHead: String
    let targetCwd: String
    let workspaceId: String
    let reason: String
    let aheadCount: Int
    let agentAllowed: Bool
    let agentPrompt: String
}
struct DirectoryMergeResult: Decodable { let ok: Bool; let cleanupDone: Bool }
struct DirectoryMergeTarget: Identifiable {
    let workspaceId: String
    let path: String
    var id: String { workspaceId + ":" + path }
}
extension WandAPI {
    func sessionDirectory(_ id: String) async throws -> SessionDirectory {
        try await request(SessionDirectory.self, method: "GET", path: "/api/workspaces/\(percentEncodePathComponent(id))/directory")
    }
    func directoryMergeCheck(_ target: DirectoryMergeTarget) async throws -> DirectoryMergeCheck {
        try await request(DirectoryMergeCheck.self, method: "POST", path: "/api/workspaces/\(percentEncodePathComponent(target.workspaceId))/directory/merge-check", body: ["sourcePath": target.path])
    }
    func mergeDirectory(_ check: DirectoryMergeCheck) async throws -> DirectoryMergeResult {
        try await request(DirectoryMergeResult.self, method: "POST", path: "/api/workspaces/\(percentEncodePathComponent(check.workspaceId))/directory/merge", body: ["sourcePath": check.worktreePath, "sourceBranch": check.sourceBranch, "targetBranch": check.targetBranch, "sourceHead": check.sourceHead, "targetHead": check.targetHead])
    }
}

struct SessionDirectorySections<Row: View>: View {
    let groups: [TaskDirectoryGroup]
    let rows: [HomeRecentConversation]
    let query: String
    let filtered: Bool
    let api: WandAPI
    let serverID: String
    let onCreated: (String) -> Void
    let onReload: () -> Void
    @ViewBuilder let row: (HomeRecentConversation, Int) -> Row
    @State private var directories: [String: SessionDirectory] = [:]
    @State private var errors: [String: String] = [:]
    @State private var collapsed = Set<String>()
    @State private var target: DirectoryMergeTarget?
    @State private var refresh = 0
    private var collapseKey: String { "wand.sessionDirectories.collapsed:" + serverID }
    private var projects: [TaskDirectoryGroup] { groups.filter(\.isBindableProject) }
    private var loadingKey: String { projects.map { $0.workspaceId + $0.workspaceCwd }.joined(separator: "|") + String(refresh) }
    private func inside(_ cwd: String, _ root: String) -> Bool { cwd == root || cwd.hasPrefix(root + "/") }
    private func cwd(_ item: HomeRecentConversation) -> String { item.task?.worktree?.path ?? item.session.cwd ?? item.group.workspaceCwd }
    private func owner(_ item: HomeRecentConversation) -> String? {
        projects.filter { project in
            project.workspaceId == item.group.workspaceId || inside(cwd(item), project.workspaceCwd)
                || directories[project.workspaceId]?.worktrees.contains(where: { inside(cwd(item), $0.path) }) == true
        }.sorted { $0.workspaceCwd.count > $1.workspaceCwd.count }.first?.workspaceId
    }
    private func tree(_ item: HomeRecentConversation, _ directory: SessionDirectory?) -> String? {
        directory?.worktrees.filter { inside(cwd(item), $0.path) }.sorted { $0.path.count > $1.path.count }.first?.path
    }
    private func expanded(_ id: String) -> Bool { !query.isEmpty || !collapsed.contains(id) }
    private func toggle(_ id: String) { if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) } }
    private func heading(_ name: String, detail: String? = nil, id: String, count: String? = nil,
                         branch: Bool = false, gitDetail: Bool = false, sessions: [HomeRecentConversation] = []) -> some View {
        let states = Set(sessions.map { HomePresentation.executionState($0.session) })
        return Button { toggle(id) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: expanded(id) ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                    Image(systemName: branch ? "arrow.triangle.branch" : "folder")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Text(name).font(.headline).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: -4) {
                        ForEach(HomeExecutionState.allCases.filter { states.contains($0) }, id: \.rawValue) { state in
                            Image(systemName: state.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(state.tint)
                                .frame(width: 24, height: 24)
                                .background(Theme.workspaceCanvas, in: Circle())
                                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                        }
                    }
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("目录状态：" + HomeExecutionState.allCases.filter { states.contains($0) }.map(\.label).joined(separator: "、"))
                    .accessibilityIdentifier("directory-status-" + id)
                }
                if let detail {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if gitDetail { Image(systemName: "arrow.triangle.branch").accessibilityHidden(true) }
                        Text(detail).fixedSize(horizontal: false, vertical: true)
                    }.font(.caption).foregroundStyle(Theme.textSecondary).padding(.leading, 28)
                }
                if let count { Text(count).font(.caption2).foregroundStyle(Theme.textSecondary).padding(.leading, 28) }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .textCase(nil)
            .accessibilityValue(expanded(id) ? "已展开" : "已收起")
            .accessibilityIdentifier("session-directory-" + id)
    }
    var body: some View {
        Group {
            ForEach(projects) { project in
                let directory = directories[project.id]
                let matches = rows.filter { owner($0) == project.id }
                let trees = directory?.worktrees ?? []
                if !matches.isEmpty || (!filtered && query.isEmpty) {
                    Section {
                        if expanded(project.id) {
                            if let error = errors[project.id] {
                                Text(error).font(.caption).foregroundStyle(Theme.danger)
                                    .listRowBackground(Color.clear)
                                Button("重新读取目录") { refresh += 1 }
                                    .listRowBackground(Color.clear)
                            }
                            if !trees.isEmpty { heading("主分支", detail: directory?.branch, id: project.id + ":main", count: "\(matches.filter { tree($0, directory) == nil }.count) 个会话", branch: true, sessions: matches.filter { tree($0, directory) == nil }).listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 0)) }
                            if trees.isEmpty || expanded(project.id + ":main") {
                                ForEach(matches.filter { tree($0, directory) == nil }) { row($0, trees.isEmpty ? 1 : 2) }
                            }
                            ForEach(trees) { worktree in
                                let treeRows = matches.filter { tree($0, directory) == worktree.path }
                                let key = project.id + ":" + worktree.path
                                if query.isEmpty || !treeRows.isEmpty || (worktree.name + " " + worktree.branch).localizedCaseInsensitiveContains(query) {
                                    heading(worktree.name, detail: worktree.branch.isEmpty ? "detached HEAD" : worktree.branch, id: key, count: "\(treeRows.count) 个会话", branch: true, sessions: treeRows)
                                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 0))
                                        .contextMenu { Button("合并到项目分支…", systemImage: "arrow.triangle.merge") { target = DirectoryMergeTarget(workspaceId: project.id, path: worktree.path) } }
                                    if expanded(key) {
                                        if treeRows.isEmpty { Text("暂无匹配会话").font(.caption).foregroundStyle(Theme.textSecondary).listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 0)).listRowBackground(Color.clear) }
                                        ForEach(treeRows) { row($0, 2) }
                                    }
                                }
                            }
                        }
                    } header: {
                        heading(project.workspaceName, detail: errors[project.id] != nil ? "分支与 Worktree 暂不可用" : directory.map { $0.isGit ? "\($0.branch.isEmpty ? "detached HEAD" : $0.branch) · \($0.worktrees.count) 个 Worktree" : "非 Git 目录" } ?? "正在读取目录…", id: project.id, gitDetail: directory?.isGit == true, sessions: matches)
                            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
                    }
                }
            }
            let other = rows.filter { owner($0) == nil }
            if !other.isEmpty {
                Section { if expanded("other") { ForEach(other) { row($0, 1) } } } header: { heading("其他会话", id: "other", count: "\(other.count) 个会话", sessions: other) }
            }
        }
        .onAppear { collapsed = Set(UserDefaults.standard.stringArray(forKey: collapseKey) ?? []) }
        .onChange(of: collapsed) { _, value in UserDefaults.standard.set(Array(value), forKey: collapseKey) }
        .task(id: loadingKey) {
            repeat {
                for project in projects {
                    guard !Task.isCancelled else { return }
                    do { let value = try await api.sessionDirectory(project.id); guard !Task.isCancelled else { return }; directories[project.id] = value; errors[project.id] = nil }
                    catch { if !Task.isCancelled { errors[project.id] = error.localizedDescription } }
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .sheet(item: $target) { target in
            SessionDirectoryMergeSheet(target: target, api: api, serverID: serverID, onCreated: onCreated) { refresh += 1; onReload() }
        }
    }
}

struct SessionDirectoryMergeSheet: View {
    let target: DirectoryMergeTarget
    let api: WandAPI
    let serverID: String
    let onCreated: (String) -> Void
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var check: DirectoryMergeCheck?
    @State private var error: String?
    @State private var loading = true
    @State private var busy = false
    @State private var finished = false
    @State private var agent = false
    @State private var draftScope = UUID().uuidString
    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("正在检查来源与目标…") }
                if let check {
                    Section("合并方向") { LabeledContent("来源", value: check.sourceBranch); LabeledContent("目标", value: check.targetBranch); LabeledContent("待合并提交", value: String(check.aheadCount)) }
                    if finished { Text("已合并并清理 Worktree。") }
                    else {
                        Section { Text(check.ok ? "检查通过，确认后合并并清理来源 Worktree 和任务分支，会话历史保留。" : check.reason).foregroundStyle(check.ok ? Theme.textSecondary : Theme.danger) }
                        Button(busy ? "正在合并…" : "确认合并并清理") { Task { await merge(check) } }.disabled(!check.ok || busy)
                        if check.agentAllowed { Button("交给 Agent 合并") { agent = true }.disabled(busy) }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Theme.danger); Button("重新检查") { Task { await load() } }.disabled(busy) } }
            }.navigationTitle("合并 Worktree").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) } }
                .task { await load() }
                .sheet(isPresented: $agent) {
                    if let check { NewConversationView(api: api, serverID: serverID, initialCwd: check.targetCwd, workspaceID: check.workspaceId,
                        initialPrompt: check.agentPrompt, initialDraftScope: "merge:" + draftScope) { session in
                            onCreated(session.id); agent = false; dismiss()
                        } }
                }
        }.interactiveDismissDisabled(busy)
    }
    private func load() async {
        loading = true; error = nil; check = nil
        do { check = try await api.directoryMergeCheck(target) } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func merge(_ check: DirectoryMergeCheck) async {
        guard !busy else { return }; busy = true
        do { _ = try await api.mergeDirectory(check); finished = true; onChanged() }
        catch { self.error = error.localizedDescription; self.check = nil; onChanged() }
        busy = false
    }
}
