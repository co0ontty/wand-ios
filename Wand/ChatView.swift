import Combine
import SwiftUI

/// 原生聊天视图：结构化消息渲染 + 原生输入栏 + 权限审批卡片。
/// 输入栏放在 safeAreaInset(edge: .bottom)；键盘避让不走系统自动机制
/// （NavigationView push 页面 + 多行 TextField 组合下系统避让会漏抬、键盘盖住输入栏），
/// 而是 .ignoresSafeArea(.keyboard) 关掉系统行为，由 KeyboardObserver
/// 监听键盘 frame 手动抬升，行为确定。
struct ChatView: View {
    private let sessionId: String
    private let api: WandAPI

    @StateObject private var store: ChatStore
    @StateObject private var keyboard = KeyboardObserver()
    @State private var draft = ""
    @State private var showQuickCommit = false
    @State private var followsLatest = true
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
        // 关掉系统键盘避让，统一交给 KeyboardObserver 手动抬升（见 bottomBar），
        // 避免「系统抬一次 + 手动抬一次」叠加或两边都不抬的不确定行为。
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
                    ForEach(Array(store.messages.enumerated()), id: \.offset) { index, turn in
                        TurnView(
                            turn: turn,
                            isLastTurn: index == store.messages.count - 1,
                            isResponding: store.isResponding,
                            askSelections: store.askUserSelections,
                            onAskToggle: { toolUseId, qIdx, optIdx, multi in
                                store.toggleAskOption(
                                    toolUseId: toolUseId, questionIndex: qIdx,
                                    optionIndex: optIdx, multiSelect: multi
                                )
                            },
                            onAskSubmit: { toolUseId, answerText in
                                store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                            }
                        )
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
            // 用户一开始拖动就暂停跟随，避免高频流式更新在手势完成前
            // 把列表抢回底部。恢复跟随只通过右下角按钮。
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in followsLatest = false }
            )
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    jumpToLatestButton(proxy)
                }
            }
            .onAppear { pinToBottom(proxy) }
            // 流式回复会原地替换最后一条消息，messages.count 不变；
            // 直接订阅数组发布事件，跟随状态下每次内容更新都定位到底部。
            .onReceive(store.$messages.dropFirst()) { _ in
                scrollToLatestIfFollowing(proxy)
            }
            .onChange(of: store.isResponding) { _ in
                scrollToLatestIfFollowing(proxy)
            }
            .onChange(of: store.loading) { loading in
                if !loading { pinToBottom(proxy) }
            }
            // 键盘弹出 → 输入栏抬升、可视区变矮，把列表重新钉到底部；
            // 用户正在看历史消息时不改变当前位置。
            .onChange(of: keyboard.lift) { lift in
                if lift > 0 && followsLatest { pinToBottom(proxy) }
            }
        }
    }

    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            followsLatest = true
            pinToBottom(proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.brand))
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
        }
        .accessibilityLabel("回到最新消息并继续跟随")
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func scrollToLatestIfFollowing(_ proxy: ScrollViewProxy) {
        guard followsLatest else { return }
        DispatchQueue.main.async {
            guard followsLatest else { return }
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
    }

    /// 打开会话时把列表钉到底部。LazyVStack 首帧尚未完成布局，单次 scrollTo
    /// 常停在半中间——立即滚一次，再按递增延迟补几次，直到布局稳定。
    private func pinToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
        for delay in [0.05, 0.15, 0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard followsLatest else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
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

    /// 输入栏上方悬浮的待办进度条数据：当前 turn 的 todos，全部完成后隐藏（对齐 Web）。
    private var visibleTodos: [TodoItem] {
        let todos = TodoItem.currentTodos(in: store.messages)
        guard !todos.isEmpty else { return [] }
        let completed = todos.filter { $0.status == "completed" }.count
        return completed == todos.count ? [] : todos
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if !visibleTodos.isEmpty {
                TodoProgressBar(todos: visibleTodos)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
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
        // 手动键盘避让：使用键盘与窗口的完整重叠高度。safeAreaInset 已经处理
        // 底部安全区，观察器不能再次扣除，否则输入栏会少抬一截。
        .padding(.bottom, keyboard.lift)
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
/// 用 .immediately 而非 .interactively：手动键盘避让（KeyboardObserver）依赖
/// 键盘 frame 通知，而交互式拖拽过程中 UIKit 不发通知，输入栏会悬空脱节；
/// 立即收起则输入栏随 willHide 同步落下。
private struct DismissKeyboardOnDrag: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.immediately)
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

/// 工具调用与结果在渲染层配成一张卡片（对齐 Web 端 buildToolResultMap / Android pairToolBlocks）。
private enum DisplayItem {
    case plain(ContentBlock)
    case tool(
        id: String, name: String, description: String?,
        input: [String: JSONValue], subagent: SubagentMeta?,
        result: ToolResultInfo?
    )
}

/// 配对后挂在工具卡上的结果。
struct ToolResultInfo {
    let text: String
    let isError: Bool
    let truncated: Bool
}

/// 优先按 tool_use_id 精确配对（并行工具调用时顺序会交错）；
/// id 缺失时退回「紧随其后的第一个结果」邻接兜底；没配上的 ToolResult 原样透传。
private func pairToolBlocks(_ content: [ContentBlock]) -> [DisplayItem] {
    var items: [DisplayItem] = []
    var consumed = Set<Int>()
    for (i, block) in content.enumerated() {
        if consumed.contains(i) { continue }
        guard case .toolUse(let id, let name, let description, let input, let subagent) = block else {
            items.append(.plain(block))
            continue
        }
        var resultIndex = -1
        if !id.isEmpty {
            // 1) 全局按 tool_use_id 精确配对
            for j in (i + 1)..<content.count where !consumed.contains(j) {
                if case .toolResult(let rid, _, _, _, _) = content[j], rid == id {
                    resultIndex = j
                    break
                }
            }
        }
        if resultIndex < 0 {
            // 2) 邻接兜底：中间隔着下一个 ToolUse 视为无结果；id 双方都有但不匹配时不抢配。
            for j in (i + 1)..<content.count where !consumed.contains(j) {
                if case .toolUse = content[j] { break }
                if case .toolResult(let rid, _, _, _, _) = content[j] {
                    if rid.isEmpty || id.isEmpty { resultIndex = j }
                    break
                }
            }
        }
        var result: ToolResultInfo?
        if resultIndex >= 0, case .toolResult(_, let text, let isError, let truncated, _) = content[resultIndex] {
            consumed.insert(resultIndex)
            result = ToolResultInfo(text: text, isError: isError, truncated: truncated)
        }
        items.append(.tool(
            id: id, name: name, description: description,
            input: input, subagent: subagent, result: result
        ))
    }
    return items
}

private struct TurnView: View {
    let turn: ConversationTurn
    var isLastTurn = false
    var isResponding = false
    var askSelections: [String: AskUserSelectionState] = [:]
    var onAskToggle: (String, Int, Int, Bool) -> Void = { _, _, _, _ in }
    var onAskSubmit: (String, String) -> Void = { _, _ in }

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
            ForEach(Array(pairToolBlocks(turn.content).enumerated()), id: \.offset) { _, item in
                itemView(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func itemView(_ item: DisplayItem) -> some View {
        switch item {
        case .plain(let block):
            BlockView(block: block)
        case .tool(let id, let name, let description, let input, let subagent, let result):
            VStack(alignment: .leading, spacing: 4) {
                subagentTag(subagent)
                toolView(
                    id: id, name: name, description: description,
                    input: input, result: result
                )
            }
        }
    }

    /// 工具卡分流（对齐 Web 端 renderToolUseCard）：
    /// AskUserQuestion → 交互卡；Edit/Write/MultiEdit → diff 卡；Bash → 终端卡；其余 → 通用卡。
    @ViewBuilder private func toolView(
        id: String, name: String, description: String?,
        input: [String: JSONValue], result: ToolResultInfo?
    ) -> some View {
        let questions = name == "AskUserQuestion" ? AskUserQuestion.parse(input: input) : []
        if !questions.isEmpty {
            AskUserQuestionCard(
                toolUseId: id,
                questions: questions,
                result: result,
                selection: askSelections[id] ?? AskUserSelectionState(),
                onToggle: { qIdx, optIdx, multi in onAskToggle(id, qIdx, optIdx, multi) },
                onSubmit: { answerText in onAskSubmit(id, answerText) }
            )
        } else if name == "Edit" || name == "Write" || name == "MultiEdit" {
            DiffCard(toolName: name, input: input, result: result)
        } else if name == "Bash" {
            TerminalCard(input: input, result: result, running: result == nil && isLastTurn && isResponding)
        } else {
            ToolUseCard(
                name: name, description: description, input: input,
                result: result, running: result == nil && isLastTurn && isResponding
            )
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
            // 兜底：正常路径已在 TurnView 配对分流，这里处理极端的落单 ToolUse。
            VStack(alignment: .leading, spacing: 4) {
                subagentTag(subagent)
                ToolUseCard(name: name, description: description, input: input, result: nil, running: false)
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

/// 原生 Markdown 渲染：块级结构独立布局，内联标记交给 AttributedString。
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    private enum Block {
        case paragraph(String)
        case heading(Int, String)
        case listItem(marker: String, text: String, indent: Int, checked: Bool?)
        case quote(String)
        case code(String, String?)
        case divider
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            inlineText(content, size: 16)
        case .heading(let level, let content):
            inlineText(content, size: headingSize(level), weight: .semibold)
                .padding(.top, level <= 2 ? 3 : 1)
        case .listItem(let marker, let content, let indent, let checked):
            HStack(alignment: .top, spacing: 7) {
                Text(checked.map { $0 ? "☑" : "☐" } ?? marker)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(checked == true ? .green : Theme.brand)
                    .padding(.top, 2)
                inlineText(content, size: 16)
            }
            .padding(.leading, CGFloat(indent * 14))
        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.brand)
                    .frame(width: 3)
                inlineText(content, size: 15, color: Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
        case .code(let content, let language):
            VStack(alignment: .leading, spacing: 2) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        case .divider:
            Divider().overlay(Theme.border).padding(.vertical, 3)
        }
    }

    private func inlineText(
        _ content: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        color: Color = Theme.textPrimary
    ) -> some View {
        Text(attributed(content))
            .font(.system(size: size, weight: weight))
            .foregroundColor(color)
            .tint(Theme.brand)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 19
        case 3: return 17
        default: return 16
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?
        var language: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            paragraph.removeAll()
        }
        func flushCode() {
            result.append(.code(code.joined(separator: "\n").trimmingCharacters(in: .newlines), language))
            code.removeAll()
            fence = nil
            language = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let fence {
                if trimmed.hasPrefix(fence) { flushCode() } else { code.append(rawLine) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                fence = String(trimmed.prefix(3))
                let suffix = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                language = suffix.isEmpty ? nil : suffix
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            let level = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
                flushParagraph()
                result.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                continue
            }
            let rule = trimmed.replacingOccurrences(of: " ", with: "")
            if ["---", "***", "___"].contains(rule) {
                flushParagraph()
                result.append(.divider)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let item = listItem(rawLine) {
                flushParagraph()
                result.append(item)
                continue
            }
            paragraph.append(rawLine)
        }
        if fence != nil { flushCode() } else { flushParagraph() }
        return result
    }

    private func listItem(_ rawLine: String) -> Block? {
        let leading = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let indent = leading / 2
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        var marker: String?
        var content: String?
        for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
            marker = "•"
            content = String(trimmed.dropFirst(2))
        }
        if marker == nil, let end = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) {
            let digits = trimmed[..<end]
            let after = trimmed.index(after: end)
            if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), after < trimmed.endIndex, trimmed[after] == " " {
                marker = String(trimmed[...end])
                content = String(trimmed[trimmed.index(after: after)...])
            }
        }
        guard let marker, var content else { return nil }
        var checked: Bool?
        if content.lowercased().hasPrefix("[x] ") {
            checked = true
            content = String(content.dropFirst(4))
        } else if content.hasPrefix("[ ] ") {
            checked = false
            content = String(content.dropFirst(4))
        }
        return .listItem(marker: marker, text: content, indent: indent, checked: checked)
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

/// 工具名 → 中文标签；未识别的工具显示原名（对齐 Web 端 toolDisplayName）。
private func toolLabel(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("todo") { return "更新待办" }
    if lower.contains("websearch") { return "网页搜索" }
    if lower.contains("webfetch") || lower.contains("fetch") { return "网页获取" }
    if lower.contains("notebook") { return "编辑笔记本" }
    if lower.hasPrefix("multiedit") || lower.hasPrefix("edit") { return "编辑文件" }
    if lower.hasPrefix("write") { return "写入文件" }
    if lower.hasPrefix("read") { return "读取文件" }
    if lower.hasPrefix("grep") { return "搜索内容" }
    if lower.hasPrefix("glob") { return "查找文件" }
    if lower == "bash" || lower.contains("command") || lower.contains("shell") { return "执行命令" }
    if lower.hasPrefix("task") || lower.contains("agent") { return "子任务" }
    return name
}

/// 工具调用卡片：图标 + 中文工具名 + 参数摘要 + 可折叠结果区。
/// 三态对齐 Web：运行中（转圈）/ 成功（左侧绿竖线）/ 失败（红弱底 + 红边框）。
private struct ToolUseCard: View {
    let name: String
    let description: String?
    let input: [String: JSONValue]
    var result: ToolResultInfo?
    var running = false

    @State private var expanded = false

    private var isError: Bool { result?.isError == true }
    private var isSuccess: Bool { result != nil && !isError }
    private var hasBody: Bool { !(result?.text.isEmpty ?? true) }

    var body: some View {
        HStack(spacing: 0) {
            if isSuccess {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.green.opacity(0.75))
                    .frame(width: 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded, let result, hasBody {
                    ToolResultBody(result: result)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isError ? Theme.danger.opacity(0.08) : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isError ? Theme.danger.opacity(0.45) : Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        Button {
            guard hasBody else { return }
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small).tint(Theme.brand).frame(width: 22)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isError ? Theme.danger : Theme.brand)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(toolLabel(name))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                        if isError {
                            Text("出错")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.danger)
                        }
                    }
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if hasBody {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// 工具结果正文：次级底色代码框 + 4000 字截断。
private struct ToolResultBody: View {
    let result: ToolResultInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(result.text.count > 4000 ? String(result.text.prefix(4000)) + "\n…（已截断）" : result.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(result.isError ? Theme.danger : Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.background.opacity(0.6))
            )
            if result.truncated {
                Text("内容过长，已截断")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
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

// MARK: - 共享语义色（Web 端 --success 同款 #4F7A58）

private let chatSuccess = Color(red: 0.310, green: 0.478, blue: 0.345)

// MARK: - AskUserQuestion 交互卡片（对齐 Web 端 ask-user 卡）

/// 提问卡：头部「? 提问 · header」，body 是题目 + 选项列表 + 确认提交。
/// 未答可交互（单选/多选），已答（配对到 tool_result）转只读并高亮用户选过的项。
private struct AskUserQuestionCard: View {
    let toolUseId: String
    let questions: [AskUserQuestion]
    let result: ToolResultInfo?
    let selection: AskUserSelectionState
    let onToggle: (Int, Int, Bool) -> Void
    let onSubmit: (String) -> Void

    @State private var expanded = true

    private var isAnswered: Bool { result != nil }
    /// 已答时按行拆答案：每道题一行，行内 ", " 分隔多选 label（对齐 Web 的解析）。
    private var answerLines: [String] {
        guard let text = result?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }
    private var headerLabel: String? {
        questions.first(where: { !($0.header ?? "").isEmpty })?.header
    }
    private var allAnswered: Bool {
        (0..<questions.count).allSatisfy { !(selection.selected[$0] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { qIdx, question in
                        questionGroup(qIdx: qIdx, question: question)
                    }
                    if !isAnswered {
                        submitRow
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.brand.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isAnswered ? chatSuccess.opacity(0.55) : Theme.brand.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { expanded = !isAnswered }
        .onChange(of: isAnswered) { answered in
            // 回答送达后自动折叠（对齐 Web 已答默认折叠）。
            if answered { withAnimation(.easeInOut(duration: 0.15)) { expanded = false } }
        }
    }

    private var headerView: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isAnswered ? "checkmark.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isAnswered ? chatSuccess : Theme.brand)
                    .frame(width: 22)
                Text("提问")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let headerLabel {
                    Text(headerLabel)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                if isAnswered {
                    Text(answerLines.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundColor(chatSuccess)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func questionGroup(qIdx: Int, question: AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.question.isEmpty {
                Text(question.question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { optIdx, option in
                    optionRow(qIdx: qIdx, optIdx: optIdx, option: option, multiSelect: question.multiSelect)
                }
            }
        }
    }

    @ViewBuilder private func optionRow(
        qIdx: Int, optIdx: Int, option: AskUserQuestion.Option, multiSelect: Bool
    ) -> some View {
        let chosen: Bool = {
            if isAnswered {
                // 只读态：答案第 qIdx 行（缺行回落第一行），按 "," 拆出已选 label。
                let line = qIdx < answerLines.count ? answerLines[qIdx] : (answerLines.first ?? "")
                return line.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .contains(option.label)
            }
            return (selection.selected[qIdx] ?? []).contains(optIdx)
        }()

        Button {
            guard !isAnswered, !selection.submitted else { return }
            onToggle(qIdx, optIdx, multiSelect)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                indicator(chosen: chosen, multiSelect: multiSelect)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(optionFill(chosen: chosen))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(optionBorder(chosen: chosen), lineWidth: chosen ? 1.5 : 1)
            )
            .opacity(isAnswered && !chosen ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAnswered || selection.submitted)
    }

    private func optionFill(chosen: Bool) -> Color {
        if isAnswered {
            return chosen ? chatSuccess.opacity(0.08) : Theme.surface
        }
        return chosen ? Theme.brand.opacity(0.16) : Theme.surface
    }

    private func optionBorder(chosen: Bool) -> Color {
        if isAnswered {
            return chosen ? chatSuccess : Theme.border
        }
        return chosen ? Theme.brand : Theme.border
    }

    /// 单选圆形 / 多选圆角方形 indicator，选中实底白点/白勾（对齐 Web）。
    @ViewBuilder private func indicator(chosen: Bool, multiSelect: Bool) -> some View {
        let tint = isAnswered ? chatSuccess : Theme.brand
        ZStack {
            if multiSelect {
                RoundedRectangle(cornerRadius: 3)
                    .fill(chosen ? tint : Color.clear)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(chosen ? tint : Theme.border, lineWidth: 2)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
            } else {
                Circle().fill(chosen ? tint : Color.clear)
                Circle().stroke(chosen ? tint : Theme.border, lineWidth: 2)
                if chosen {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: 16, height: 16)
        .padding(.top, 1)
    }

    private var submitRow: some View {
        HStack {
            Spacer()
            Button {
                guard allAnswered, !selection.submitted else { return }
                var lines: [String] = []
                for (qIdx, question) in questions.enumerated() {
                    let chosen = (selection.selected[qIdx] ?? []).sorted()
                    lines.append(chosen.map { question.options[$0].label }.joined(separator: ", "))
                }
                onSubmit(lines.joined(separator: "\n"))
            } label: {
                Text(selection.submitted ? "已提交…" : "确认提交")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((allAnswered && !selection.submitted) ? Theme.brand : Theme.brand.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!allAnswered || selection.submitted)
        }
    }
}

// MARK: - Diff 卡片（Edit / Write / MultiEdit，对齐 Web 端 inline-diff）

private struct DiffCard: View {
    let toolName: String
    let input: [String: JSONValue]
    let result: ToolResultInfo?

    @State private var expanded = false
    @State private var initialized = false

    private var path: String {
        input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? ""
    }
    private var fileName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
    private var isWrite: Bool { toolName == "Write" || toolName == "MultiEdit" }
    private var oldText: String { input["old_string"]?.stringValue ?? "" }
    private var newText: String {
        input["new_string"]?.stringValue ?? input["content"]?.stringValue ?? ""
    }

    private var statusText: String {
        guard let result else { return "执行中" }
        if result.isError {
            let text = result.text
            return (text.contains("haven't granted") || text.contains("permission")) ? "等待授权" : "失败"
        }
        return "已修改"
    }
    private var statusColor: Color {
        guard let result else { return Theme.brand }
        return result.isError ? Theme.danger : chatSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !isWrite && !oldText.isEmpty {
                        diffColumn(label: "旧", text: oldText, prefix: "- ", tint: Theme.danger)
                    }
                    if !newText.isEmpty {
                        diffColumn(label: isWrite ? "" : "新", text: newText, prefix: "+ ", tint: chatSuccess)
                    }
                    if let result, result.isError, !result.text.isEmpty {
                        Text(result.text.count > 600 ? String(result.text.prefix(600)) + "…" : result.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.danger)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            // 默认展开态对齐 Web：执行中展开，已完成折叠。只在首次出现时定初值。
            if !initialized {
                expanded = result == nil
                initialized = true
            }
        }
        .onChange(of: result != nil) { hasResult in
            // 结果到达后自动收起（对齐 Android / Web 行为；手动点开不受影响）。
            if hasResult { withAnimation(.easeInOut(duration: 0.15)) { expanded = false } }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .frame(width: 22)
                Text(fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.12)))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func diffColumn(label: String, text: String, prefix: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(prefix + (text.count > 2000 ? String(text.prefix(2000)) + "\n…（已截断）" : text))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(tint)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.08))
            )
        }
    }
}

// MARK: - 终端卡片（Bash，对齐 Web 端 inline-terminal）

private struct TerminalCard: View {
    let input: [String: JSONValue]
    let result: ToolResultInfo?
    var running = false

    @State private var expanded = false

    private var command: String {
        input["command"]?.stringValue ?? input["cmd"]?.stringValue ?? ""
    }
    private var statusColor: Color {
        guard let result else { return Theme.brand }
        return result.isError ? Theme.danger : chatSuccess
    }
    // 终端卡固定深色，亮暗主题一致（对齐 Web）。
    private let termBg = Color(red: 0.118, green: 0.118, blue: 0.118)
    private let termText = Color(red: 0.85, green: 0.85, blue: 0.83)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text("$ " + command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(termText)
                            .textSelection(.enabled)
                    }
                    if let result, !result.text.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(result.text.count > 4000 ? String(result.text.prefix(4000)) + "\n…（已截断）" : result.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(result.isError ? Color(red: 0.95, green: 0.55, blue: 0.5) : termText.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(termBg))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small).tint(termText)
                } else {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                }
                Text("$ " + (command.count > 80 ? String(command.prefix(77)) + "…" : command))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(termText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(termText.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 待办进度条（TodoWrite，对齐 Web 端 todo-progress）

/// 输入栏上方的悬浮进度条：环形进度 + N/M + 当前任务，点击展开任务列表。
struct TodoProgressBar: View {
    let todos: [TodoItem]

    @State private var expanded = false

    private var completed: Int { todos.filter { $0.status == "completed" }.count }
    /// 1-indexed「正在干第 N 个」：completed+1 封顶（对齐 Web currentStep）。
    private var currentStep: Int { min(completed + 1, todos.count) }
    private var activeTask: String {
        if let active = todos.first(where: { $0.status == "in_progress" }) {
            let label = active.activeForm ?? active.content
            if !label.isEmpty { return label }
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    progressRing
                    Text("\(currentStep)/\(todos.count)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.brand)
                    if !activeTask.isEmpty {
                        Text(activeTask)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                        todoRow(todo)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Theme.border, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(currentStep) / CGFloat(max(todos.count, 1)))
                .stroke(Theme.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }

    @ViewBuilder private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch todo.status {
                case "completed":
                    Text("✓").foregroundColor(chatSuccess)
                case "in_progress":
                    Text("›").foregroundColor(Theme.brand)
                default:
                    Text("○").foregroundColor(Theme.textSecondary)
                }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .frame(width: 14)
            Text(todo.content)
                .font(.system(size: 12))
                .foregroundColor(todo.status == "in_progress" ? Theme.textPrimary : Theme.textSecondary)
                .strikethrough(todo.status == "completed", color: Theme.textSecondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
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
