import SwiftUI

/// A native document workspace: the directory owns navigation, the editor owns its draft.
struct KnowledgeLibraryView: View {
    @ObservedObject var store: KnowledgeLibraryStore
    var allowsOwnerSelection = true
    @FocusState private var searchFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 720
            HStack(spacing: 0) {
                if columns || !store.documentVisible {
                    directory.frame(width: columns ? 260 : nil)
                }
                if columns { Divider() }
                if columns || store.documentVisible { document(compact: !columns) }
            }
        }
        .background(canvas)
        .buttonStyle(WandQuietButtonStyle())
        .task { await store.loadIfNeeded() }
        .onChange(of: store.showDiscard) { visible in if !visible { store.continueEditing() } }
        .confirmationDialog("放弃未保存的修改？", isPresented: $store.showDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { store.discardAndContinue() }
            Button("继续编辑", role: .cancel) { store.continueEditing() }
        } message: { Text("当前草稿还没有保存到知识库。") }
        .confirmationDialog("删除这篇文档？", isPresented: Binding(get: { store.deleteCandidate != nil }, set: { if !$0 { store.deleteCandidate = nil } }), titleVisibility: .visible, presenting: store.deleteCandidate) { entry in
            Button("删除文档", role: .destructive) { Task { await store.deleteConfirmed(entry) } }
            Button("取消", role: .cancel) { store.deleteCandidate = nil }
        } message: { entry in Text("“\(entry.title)”将从\(store.ownerName)的知识库移除。") }
    }
    private var canvas: Color {
#if os(macOS)
        Theme.workspaceBackground
#else
        Theme.background
#endif
    }
    private var directory: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("知识库").font(.title3.weight(.semibold))
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("刷新知识库").disabled(store.loading || store.busy)
            }
            if allowsOwnerSelection {
            Picker("知识范围", selection: Binding(get: { store.scope }, set: { store.changeScope($0) })) {
                ForEach(KnowledgeScope.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().disabled(store.busy)
            if store.scope == .global {
                Text("所有员工、项目与 CLI").font(.callout).foregroundStyle(.secondary)
            } else {
            Picker(store.scope == .personal ? "员工" : "项目", selection: Binding(get: { store.ownerId }, set: { store.changeOwner($0) })) {
                if store.availableOwners.isEmpty { Text(store.loading ? "正在加载…" : "暂无可选对象").tag("") }
                ForEach(store.availableOwners) { Text($0.name + ($0.isReadOnly ? "（只读）" : "")).tag($0.id) }
            }.disabled(store.busy || store.availableOwners.isEmpty)
            }
            }
            HomeSearchField(placeholder: "搜索文档", text: $store.query, focused: $searchFocused, identifier: "knowledge-search")
            HStack {
                Text("\(store.page?.total ?? 0) 篇文档").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.create() } label: { Label("新建", systemImage: "plus").frame(minHeight: 44) }.disabled(store.ownerId.isEmpty || store.readOnly || store.busy || store.loading)
            }
            if let errors = store.page?.syncErrors, !errors.isEmpty {
                Text("知识已保存，部分 CLI 尚未同步：" + errors.joined(separator: "；")).font(.caption).foregroundStyle(.orange)
            }
            if store.readOnly { Text("项目已移除，仍可阅读与删除保留的文档。").font(.caption).foregroundStyle(.secondary) }
            if store.loading { ProgressView().frame(maxWidth: .infinity) }
            if !store.documentVisible { feedback }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.folders, id: \.self) { folder in
                        Text(folder).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(store.documents.filter { $0.directoryName == folder }) { entry in
                            Button { store.open(entry) } label: {
                                Label(entry.title, systemImage: "doc.text")
                                    .font(.body).lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).padding(.horizontal, 8).frame(minHeight: 44)
                                    .background(store.selectedID == entry.id ? Theme.brand.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(store.busy)
                                .accessibilityAddTraits(store.selectedID == entry.id ? .isSelected : [])
                        }
                    }
                    if !store.loading && store.documents.isEmpty {
                        Text(store.query.isEmpty ? (store.availableOwners.isEmpty ? (store.scope == .global ? "服务器尚不支持全局知识库，请更新服务端。" : store.scope == .project ? "先创建工作区，即可整理项目知识。" : "暂无员工。") : "还没有文档。可以新建，也可以在对话中请员工记住内容。") : "没有找到匹配的文档。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }
            Text(store.scope == .global ? "全局约定自动加载，合计最多 24 KB。默认安装同步各 CLI；现有终端会话可能需要重开。" : store.scope == .personal ? "每位员工保留自己的知识。" : "项目知识由当前项目中的对话使用。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxHeight: .infinity, alignment: .top)
    }
    private func document(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if compact {
                    Button { store.backToDirectory() } label: { Label("目录", systemImage: "chevron.left").frame(minHeight: 44) }
                        .disabled(store.busy)
                }
                Text(store.ownerName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if store.draft != nil {
                    Button("取消") { store.cancelEdit() }.disabled(store.busy)
                    Button("保存") { Task { await store.save() } }.buttonStyle(.borderedProminent)
                        .disabled(store.busy || store.loading || store.conflict).keyboardShortcut("s", modifiers: .command)
                } else if let selected = store.selected {
                    Button("编辑") { store.edit() }.disabled(store.readOnly || store.busy || store.loading)
                    Menu {
                        Button("删除文档", role: .destructive) { store.deleteCandidate = selected }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("文档操作").disabled(store.busy)
                }
            }.padding(.horizontal, compact ? 16 : 28).frame(minHeight: 52)
            Divider()
            feedback.padding(.horizontal, compact ? 16 : 28)
            if store.draft != nil {
                editor.padding(compact ? 16 : 28)
            } else if let selected = store.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(selected.directoryName).font(.caption).foregroundStyle(.secondary)
                        Text(selected.title).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                        MarkdownText(text: selected.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: 760, alignment: .leading).padding(compact ? 20 : 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                }.id(selected.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                    Text("选择一篇文档，开始阅读").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("文档标题", text: draftBinding(\.title)).font(.title2.weight(.semibold)).textFieldStyle(.plain)
                .accessibilityLabel("文档标题")
            HStack {
                Text("目录").foregroundStyle(.secondary)
                TextField("未分类", text: draftBinding(\.folder)).textFieldStyle(.plain).accessibilityLabel("文档目录")
            }.font(.subheadline)
            Divider()
            if store.conflict, let latest = store.selected {
                DisclosureGroup("查看最新版本 · 草稿保留在下方") {
                    ScrollView { MarkdownText(text: latest.content).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                }.font(.callout)
            }
            TextEditor(text: draftBinding(\.content)).font(.body).scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel("文档正文")
            HStack {
                Text("支持 Markdown").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.hasUnsavedChanges ? "未保存" : "编辑中").font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(store.busy)
    }
    @ViewBuilder private var feedback: some View {
        if let error = store.error {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                if store.draft != nil {
                    Button(store.conflict ? "刷新最新版本，保留草稿" : "刷新核对，保留草稿") { store.refreshAfterConflict() }
                        .disabled(store.loading || store.busy)
                } else { Button("重新加载") { store.refresh() }.disabled(store.loading || store.busy) }
            }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        } else if let notice = store.notice {
            Text(notice).font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
        }
    }
    private func draftBinding(_ keyPath: WritableKeyPath<KnowledgeDraft, String>) -> Binding<String> {
        Binding(get: { store.draft?[keyPath: keyPath] ?? "" }, set: { store.draft?[keyPath: keyPath] = $0 })
    }
}
