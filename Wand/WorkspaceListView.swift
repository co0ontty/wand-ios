import SwiftUI

struct WorkspaceTaskSelection: Equatable {
    let workspace: Workspace
    let task: WorkspaceTask
}

struct WorkspaceListView: View {
    @ObservedObject var store: WorkspaceStore
    let selectedTaskId: String?
    let onOpenTask: (Workspace, WorkspaceTask) -> Void

    @State private var expandedWorkspaceIds = Set<String>()

    var body: some View {
        Group {
            switch store.indexState {
            case .idle:
                loadingState
            case .loading:
                if store.workspaces.isEmpty { loadingState }
                else { workspaceContent }
            case .failed(let message):
                if store.workspaces.isEmpty { errorState(message) }
                else { workspaceContent }
            case .loaded:
                workspaceContent
            }
        }
        .background(WandAmbientBackground())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if case .idle = store.indexState {
                await store.loadWorkspaceIndex()
            }
        }
        .onChange(of: store.workspaces.map(\.id)) { _, ids in
            if expandedWorkspaceIds.isEmpty {
                expandedWorkspaceIds = Set(ids)
            }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if store.workspaces.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 34))
                    .foregroundColor(Theme.brand)
                Text("还没有项目")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("可在网页版中创建 Workspace 项目和任务")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        } else {
            List {
                if case .failed(let message) = store.indexState {
                    inlineError(message)
                }
                ForEach(store.workspaces) { workspace in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedWorkspaceIds.contains(workspace.id) },
                            set: { expanded in
                                if expanded { expandedWorkspaceIds.insert(workspace.id) }
                                else { expandedWorkspaceIds.remove(workspace.id) }
                            }
                        )
                    ) {
                        if let error = store.taskErrors[workspace.id] {
                            inlineError(error)
                        }
                        let tasks = store.tasks(for: workspace.id)
                        if tasks.isEmpty && store.taskErrors[workspace.id] == nil {
                            Text("还没有任务")
                                .font(.footnote)
                                .foregroundColor(Theme.textMuted)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(tasks) { task in
                                taskRow(task, workspace: workspace)
                            }
                        }
                    } label: {
                        workspaceHeader(workspace)
                    }
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await store.loadWorkspaceIndex() }
        }
    }

    private func workspaceHeader(_ workspace: Workspace) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "folder.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.brand)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brand.opacity(0.10))
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if let provider = workspace.defaultProvider {
                        Text(provider.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                Text(workspace.cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("项目 \(workspace.name)，目录 \(workspace.cwd)")
    }

    private func taskRow(_ task: WorkspaceTask, workspace: Workspace) -> some View {
        Button {
            onOpenTask(workspace, task)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: task.status == "done" ? "checkmark.circle.fill" : "terminal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(task.status == "done" ? Theme.success : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.surface)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    Text(task.worktree == nil ? "共享项目目录" : task.worktree?.branch ?? "独立 worktree")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if selectedTaskId == task.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.brand)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.leading, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("任务 \(task.name)")
        .accessibilityValue(task.status == "done" ? "已完成" : "进行中")
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.brand)
            Text("正在加载项目…")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(Theme.textSecondary)
            Text(message)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await store.loadWorkspaceIndex() } }
                .buttonStyle(WandSecondaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundColor(Theme.danger)
            .padding(.vertical, 6)
    }
}
