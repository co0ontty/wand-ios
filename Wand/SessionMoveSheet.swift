import SwiftUI

/// 会话归属移动：触摸/键盘端的等价实现，替代桌面端拖拽，并给出明确的目的地确认。
/// 只改任务归属——运行目录、历史、正在执行的 CLI 都不动。
struct SessionMoveSheet: View {
    @ObservedObject var store: WorkspaceStore
    let sessionId: String
    let sessionTitle: String
    var onMoved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var groups: [TaskDirectoryGroup] = []
    @State private var query = ""
    @State private var selectedId: String?
    @State private var loading = true
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var reloadNonce = 0

    private var allTargets: [SessionMoveTarget] {
        SessionMovePresentation.targets(groups: groups, sessionId: sessionId)
    }

    private var ambiguousKeys: Set<String> {
        SessionMovePresentation.ambiguousKeys(allTargets)
    }

    private var targets: [SessionMoveTarget] {
        SessionMovePresentation.ordered(
            SessionMovePresentation.targets(groups: groups, sessionId: sessionId, query: query)
        )
    }

    private var selectedTarget: SessionMoveTarget? {
        allTargets.first { $0.id == selectedId && !$0.current }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WandAmbientBackground()
                content
            }
            .navigationTitle("移动会话到任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(busy ? "移动中…" : "移动") {
                        Task { await submit() }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .disabled(selectedTarget == nil || busy || loading)
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .task(id: reloadNonce) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(sessionTitle.isEmpty ? "CLI 会话" : sessionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Text("只改变任务归属，保留运行目录、历史和正在执行的 CLI。")
                    .font(.footnote)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            searchField

            if loading {
                ProgressView().tint(Theme.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(Theme.danger)
                    Button("重新加载任务") { reloadNonce += 1 }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.brand)
                        .disabled(busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            List {
                if !loading, errorMessage == nil, !targets.contains(where: { !$0.current }) {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "还没有其他任务，请先创建一个任务分组。"
                        : "没有匹配的目标任务。")
                        .font(.footnote)
                        .foregroundColor(Theme.textMuted)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(targets) { target in
                    targetRow(target)
                        .listRowBackground(Theme.background)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textMuted)
            TextField("搜索任务或工作区", text: $query)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(busy)
                .onChange(of: query) { _, _ in selectedId = nil }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface.opacity(0.9))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func targetRow(_ target: SessionMoveTarget) -> some View {
        let selected = selectedId == target.id
        return Button {
            guard !busy, !target.current else { return }
            selectedId = target.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(target.current
                        ? Theme.textMuted.opacity(0.5)
                        : (selected ? Theme.brand : Theme.textMuted))
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name.isEmpty ? "未命名任务" : target.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(target.current ? Theme.textMuted : Theme.textPrimary)
                        .lineLimit(2)
                    Text(target.subtitle(ambiguous: ambiguousKeys.contains(target.key)))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if target.current {
                    Text("当前任务")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || target.current)
        .accessibilityLabel("移动到 \(target.name)，\(target.subtitle(ambiguous: ambiguousKeys.contains(target.key)))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            groups = try await store.freshTaskGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func submit() async {
        guard let destination = selectedTarget, !busy else { return }
        busy = true
        errorMessage = nil
        do {
            try await store.moveSession(sessionId: sessionId, toTaskId: destination.id)
            onMoved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }
}
