import SwiftUI

/// 原生聊天视图：结构化消息渲染 + 原生输入栏 + 权限审批卡片。
/// 输入栏放在 safeAreaInset(edge: .bottom)，键盘升降由系统接管——
/// 这正是 WebView 方案里键盘重叠/状态栏错位问题的根治点。
struct ChatView: View {
    private let sessionId: String
    private let api: WandAPI

    @StateObject private var store: ChatStore
    @State private var draft = ""
    @State private var showQuickCommit = false
    @FocusState private var inputFocused: Bool

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
        _store = StateObject(wrappedValue: ChatStore(sessionId: sessionId, api: api))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if store.loading {
                ProgressView().tint(Theme.brand)
            } else if let error = store.loadError {
                VStack(spacing: 12) {
                    Text("加载失败").font(.headline).foregroundColor(Theme.textPrimary)
                    Text(error).font(.footnote).foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else {
                messageList
            }
        }
        // 点消息区任意空白处收起键盘；输入栏在 safeAreaInset 里不受影响，
        // 点发送 / 权限按钮不会误收。
        .dismissKeyboardOnTap()
        .navigationTitle(store.snapshot?.displayTitle ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button { showQuickCommit = true } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Theme.brand)
                    }
                    statusBadge
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(sessionId: sessionId, api: api)
        }
        .onAppear { store.start() }
        .onDisappear { store.shutdown() }
        .overlay(alignment: .top) { toastView }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(store.messages.enumerated()), id: \.offset) { _, turn in
                        TurnView(turn: turn)
                    }
                    if store.isResponding {
                        respondingIndicator
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .modifier(DismissKeyboardOnDrag())
            .onChange(of: store.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: store.loading) { loading in
                if !loading {
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var respondingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.brand)
            Text(store.currentTaskTitle ?? "正在思考…")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 顶部状态

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var statusColor: Color {
        if !store.connected { return .gray }
        if store.permissionBlocked { return .orange }
        if store.isResponding { return .green }
        if store.sessionEnded { return .gray }
        return Theme.brand
    }

    private var statusText: String {
        if !store.connected { return "重连中" }
        if store.permissionBlocked { return "待授权" }
        if store.isResponding { return "回复中" }
        if store.sessionEnded { return "已结束" }
        return "就绪"
    }

    // MARK: - 底部栏（权限卡 + 队列 + 输入框）

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if store.pendingEscalation != nil || store.legacyPermissionPrompt != nil {
                PermissionCard(
                    escalation: store.pendingEscalation,
                    legacy: store.legacyPermissionPrompt,
                    onResolve: { store.resolvePermission($0) }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !store.queuedMessages.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 11))
                    Text("已排队 \(store.queuedMessages.count) 条消息")
                        .font(.system(size: 12))
                    Spacer()
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
            inputBar
        }
        .background(
            Theme.background
                .opacity(0.97)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.easeInOut(duration: 0.2), value: store.pendingEscalation)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            growingTextField
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )

            if store.isResponding {
                Button(action: { store.stopResponding() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.danger))
                }
            }
            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(canSend ? Theme.brand : Theme.brand.opacity(0.4))
                    )
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// iOS 16+ 用多行自增高输入框；iOS 15 退化为单行。
    @ViewBuilder private var growingTextField: some View {
        if #available(iOS 16.0, *) {
            TextField("发消息…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
        } else {
            TextField("发消息…", text: $draft)
                .font(.system(size: 16))
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.sessionEnded
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        store.send(text: text)
    }

    // MARK: - Toast

    @ViewBuilder private var toastView: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        if store.toast == toast { store.toast = nil }
                    }
                }
        }
    }
}

/// iOS 16+ 才有 scrollDismissesKeyboard；iOS 15 用拖拽手势近似。
private struct DismissKeyboardOnDrag: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content.simultaneousGesture(
                DragGesture().onChanged { value in
                    if value.translation.height > 24 {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                        )
                    }
                }
            )
        }
    }
}

// MARK: - 单条消息

private struct TurnView: View {
    let turn: ConversationTurn

    var body: some View {
        if turn.role == "user" {
            userBubble
        } else {
            assistantBlocks
        }
    }

    private var userText: String {
        var pieces: [String] = []
        for block in turn.content {
            if case .text(let text, _) = block { pieces.append(text) }
        }
        return pieces.joined(separator: "\n")
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(userText)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.brand)
                )
                .textSelection(.enabled)
        }
    }

    private var assistantBlocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(turn.content.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 内容块渲染

private struct BlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block {
        case .text(let text, let subagent):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    subagentTag(subagent)
                    MarkdownText(text: text)
                }
            }
        case .thinking(let thinking, _):
            if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CollapsibleSection(
                    icon: "brain",
                    title: "思考过程",
                    tint: Theme.textSecondary
                ) {
                    Text(thinking)
                        .font(.system(size: 13))
                        .italic()
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        case .toolUse(_, let name, let description, let input, let subagent):
            VStack(alignment: .leading, spacing: 4) {
                subagentTag(subagent)
                ToolUseCard(name: name, description: description, input: input)
            }
        case .toolResult(_, let text, let isError, let truncated, _):
            if !text.isEmpty {
                CollapsibleSection(
                    icon: isError ? "xmark.octagon" : "doc.text",
                    title: isError ? "执行出错" : "执行结果",
                    tint: isError ? Theme.danger : Theme.textSecondary
                ) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text.count > 4000 ? String(text.prefix(4000)) + "\n…（已截断）" : text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    if truncated {
                        Text("内容过长，已截断")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder private func subagentTag(_ meta: SubagentMeta?) -> some View {
        if let meta {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(meta.taskDescription ?? meta.agentType ?? "子任务")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.brandStrong)
        }
    }
}

/// 简化 Markdown 渲染：按 ``` 切分代码块，其余段落走 AttributedString 内联样式。
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(segment.content)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                } else {
                    Text(attributed(segment.content))
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct Segment {
        let content: String
        let isCode: Bool
    }

    private var segments: [Segment] {
        let parts = text.components(separatedBy: "```")
        var result: [Segment] = []
        for (index, raw) in parts.enumerated() {
            let isCode = index % 2 == 1
            var content = raw
            if isCode {
                // 去掉语言标记行（``` 后第一行）
                if let newline = content.firstIndex(of: "\n") {
                    let firstLine = content[..<newline]
                    if firstLine.count <= 24, !firstLine.contains(" ") {
                        content = String(content[content.index(after: newline)...])
                    }
                }
            }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                result.append(Segment(content: content, isCode: isCode))
            }
        }
        return result
    }

    private func attributed(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(raw)
    }
}

/// 工具调用卡片：图标 + 工具名 + 参数摘要。
private struct ToolUseCard: View {
    let name: String
    let description: String?
    let input: [String: JSONValue]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.brand)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var iconName: String {
        let lower = name.lowercased()
        if lower.contains("bash") || lower.contains("command") { return "terminal" }
        if lower.contains("edit") || lower.contains("write") { return "pencil" }
        if lower.contains("read") { return "doc.text.magnifyingglass" }
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return "magnifyingglass" }
        if lower.contains("web") || lower.contains("fetch") { return "globe" }
        if lower.contains("task") || lower.contains("agent") { return "person.2" }
        return "wrench.and.screwdriver"
    }

    /// 摘要优先级：description > 常见关键参数 > 第一个参数。
    private var summary: String {
        if let d = description, !d.isEmpty { return d }
        let preferredKeys = ["command", "file_path", "path", "pattern", "query", "prompt", "url", "description"]
        for key in preferredKeys {
            if let value = input[key] {
                let text = value.summaryText
                if !text.isEmpty { return text }
            }
        }
        if let first = input.first {
            return "\(first.key): \(first.value.summaryText)"
        }
        return ""
    }
}

/// 可折叠区块（thinking / tool_result 共用），默认折叠。
private struct CollapsibleSection<Content: View>: View {
    let icon: String
    let title: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12))
                    Text(title).font(.system(size: 12, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(tint)
            }
            .buttonStyle(.plain)
            if expanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - 权限审批卡片

private struct PermissionCard: View {
    let escalation: EscalationRequest?
    let legacy: PermissionRequestInfo?
    let onResolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.orange)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let target, !target.isEmpty {
                Text(target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.background)
                    )
            }
            HStack(spacing: 8) {
                Button { onResolve("approve_once") } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(PermissionButtonStyle(kind: .primary))
                if escalation != nil {
                    Button { onResolve("approve_turn") } label: {
                        Text("本轮均允许").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PermissionButtonStyle(kind: .secondary))
                }
                Button { onResolve("deny") } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(PermissionButtonStyle(kind: .destructive))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1.5)
        )
    }

    private var title: String {
        if let esc = escalation { return esc.scopeTitle }
        return "权限请求"
    }

    private var detail: String {
        if let esc = escalation { return esc.reason }
        return legacy?.prompt ?? ""
    }

    private var target: String? {
        escalation?.target ?? legacy?.target
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(kind == .primary ? .white : (kind == .destructive ? Theme.danger : Theme.textPrimary))
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(kind == .primary ? Theme.brand : Theme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(kind == .primary ? Color.clear : Theme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
