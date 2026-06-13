import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
    @StateObject private var speech = SpeechRecognizerService()
    @State private var draft = ""
    @State private var showQuickCommit = false
    @State private var followsLatest = true
    @State private var voicePressed = false
    @State private var voiceCanceling = false
    /// 语音输入模式：轻点话筒进入，整个输入框变成「按住说话」面板。
    @State private var voiceMode = false
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var uploadingAttachments = false
    @State private var gitStatus: GitStatusResult?
    /// 轻点 vs 按住的计时器：按满阈值才开始录音，阈值内松手按轻点处理。
    @State private var voiceHoldWork: DispatchWorkItem?
    /// 停止任务二次确认弹窗开关：点停止按钮先弹确认，避免误触中断正在跑的任务。
    @State private var showStopConfirm = false
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
            } else if store.isStructured && store.messages.isEmpty && !store.isResponding {
                sessionLaunchPanel
            } else {
                messageList
            }
        }
        // 点消息区任意空白处收起键盘；输入栏在 safeAreaInset 里不受影响，
        // 点发送 / 权限按钮不会误收。
        .dismissKeyboardOnTap()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
#if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarLeading) {
                    providerBadge
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarItem(placement: .principal) {
                    navigationStatus
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigationBarLeading) {
                    providerBadge
                }
                ToolbarItem(placement: .principal) {
                    navigationStatus
                }
            }
#else
            ToolbarItem(placement: .navigationBarLeading) {
                providerBadge
            }
            ToolbarItem(placement: .principal) {
                navigationStatus
            }
#endif
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    gitChangesButton
                    if store.isStructured {
                        sessionSettingsMenu
                    }
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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handlePickedAttachments
        )
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { result in
                showPhotoPicker = false
                handlePickedPhotos(result)
            }
        }
        .onAppear {
            store.start()
            refreshGitStatus()
        }
        .onChange(of: showQuickCommit) { showing in
            if !showing { refreshGitStatus() }
        }
        .onDisappear { store.shutdown() }
        .overlay(alignment: .top) { connectionBanner }
        .animation(.easeInOut(duration: 0.2), value: store.connected)
        .overlay(alignment: .top) { toastView }
    }

    // MARK: - 断线提示条

    @ViewBuilder private var connectionBanner: some View {
        if !store.connected {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                Text("连接已断开，正在重连…")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Theme.danger)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(groupedMessageItems.enumerated()), id: \.offset) { _, item in
                            messageItemView(item)
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
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            // 仅用户明确向下拖动、准备查看更早消息时暂停跟随。
                            // 旧逻辑任何轻微拖动都会永久关掉跟随，收键盘或触摸
                            // 列表后，新回复就只能靠右下角按钮才能看到。
                            if value.translation.height > 18 {
                                followsLatest = false
                            }
                        }
                )
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        jumpToLatestButton(proxy)
                    }
                }
                .onAppear { pinToBottom(proxy) }
                .onReceive(store.$messages.dropFirst()) { _ in
                    scrollToLatestIfFollowing(proxy)
                }
                .onChange(of: store.isResponding) { _ in
                    scrollToLatestIfFollowing(proxy)
                }
                .onChange(of: store.loading) { loading in
                    if !loading { pinToBottom(proxy) }
                }
                .onChange(of: keyboard.lift) { lift in
                    if lift > 0 && followsLatest { pinToBottom(proxy) }
            }
        }
    }

    @ViewBuilder private func messageItemView(_ item: MessageDisplayItem) -> some View {
        switch item {
        case .turn(let index, let turn):
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
                    followsLatest = true
                    store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                }
            )
        case .explorationGroup(let tools, let lastTurnIndex):
            ExplorationGroupCard(
                tools: tools,
                running: store.isResponding
                    && lastTurnIndex == store.messages.count - 1
                    && tools.contains { $0.result == nil }
            )
        }
    }

    private var groupedMessageItems: [MessageDisplayItem] {
        groupExplorationTurns(store.messages)
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
        // 流式更新会原地增高最后一条消息，首个 scrollTo 可能早于
        // LazyVStack 完成新高度布局；补一次短延迟即可稳定贴住底部。
        for delay in [0.0, 0.08] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard followsLatest else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
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

    private var sessionLaunchPanel: some View {
        VStack(spacing: 18) {
            WandBrandMark(size: 52)
            Text(store.snapshot?.providerLabel ?? "结构化会话")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: 340)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Color.black.opacity(0.07), radius: 18, y: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    private func modelButton(id: String?, label: String) -> some View {
        Button {
            store.setModel(id)
        } label: {
            if store.selectedModel == id {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private static let thinkingLevels = [
        (id: "off", label: "off"),
        (id: "standard", label: "think"),
        (id: "deep", label: "think hard"),
        (id: "max", label: "ultrathink"),
    ]

    private static func thinkingLabel(_ id: String) -> String {
        thinkingLevels.first { $0.id == id }?.label ?? "off"
    }

    /// 顶栏左侧 provider 小徽标：品牌色弱底圆角方块 + 品牌 logo，标明当前 Claude / Codex。
    private var providerBadge: some View {
        let isCodex = store.snapshot?.provider == "codex"
        let tint: Color = isCodex ? Theme.codex : Theme.brand
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.13))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1)
            BrandLogoShape(provider: store.snapshot?.provider)
                .fill(tint)
                .frame(width: 15, height: 15)
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel(isCodex ? "Codex" : "Claude")
    }

    private var navigationStatus: some View {
        VStack(spacing: 0) {
            Text(latestUserMessage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190)
            Text(store.snapshot?.cwd ?? "未设置工作目录")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190)
        }
        .accessibilityElement(children: .combine)
    }

    private var latestUserMessage: String {
        for turn in store.messages.reversed() where turn.role == "user" {
            let text = turn.content.compactMap { block -> String? in
                guard case .text(let value, _) = block else { return nil }
                return value
            }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            if !text.isEmpty { return text }
        }
        return store.snapshot?.displayTitle ?? "对话详情"
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
            if voicePressed || speech.isRecording {
                voiceBubble
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
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
        // 手动键盘避让：观察器只返回键盘在底部安全区上方的高度。
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
            composerActionsMenu
            composerField

            if store.isResponding {
                Button(action: { showStopConfirm = true }) {
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
        .confirmationDialog(
            "确定要停止当前正在运行的任务吗？",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("停止", role: .destructive) { store.stopResponding() }
            Button("取消", role: .cancel) {}
        }
    }

    private var composerField: some View {
        ZStack(alignment: .bottomTrailing) {
            if voiceMode {
                voiceHoldField
            } else {
                growingTextField
                    .focused($inputFocused)
                    .padding(.leading, 14)
                    .padding(.trailing, 48)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
            micButton
                .padding(.trailing, 4)
                .padding(.bottom, 3)
        }
    }

    private var sessionSettingsMenu: some View {
        Menu {
            Menu {
                modelButton(id: nil, label: "默认")
                ForEach(store.availableModels.filter { $0.id != "default" }) { model in
                    modelButton(id: model.id, label: model.label)
                }
            } label: {
                Label("模型 · \(store.selectedModel ?? "默认")", systemImage: "cpu")
            }

            Menu {
                ForEach(Self.thinkingLevels, id: \.id) { level in
                    Button {
                        store.setThinkingEffort(level.id)
                    } label: {
                        if store.thinkingEffort == level.id {
                            Label(level.label, systemImage: "checkmark")
                        } else {
                            Text(level.label)
                        }
                    }
                }
            } label: {
                Label("思考深度 · \(Self.thinkingLabel(store.thinkingEffort))", systemImage: "brain")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.brand)
        }
        .accessibilityLabel("会话设置")
    }

    private var gitChangesButton: some View {
        Button {
            showQuickCommit = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text("~\(gitChangeCounts.modified)")
                Text("-\(gitChangeCounts.deleted)")
                    .foregroundColor(Theme.danger)
                Text("+\(gitChangeCounts.added)")
                    .foregroundColor(.green)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.textSecondary)
        }
        .accessibilityLabel(
            "Git 修改 \(gitChangeCounts.modified)，删除 \(gitChangeCounts.deleted)，新增 \(gitChangeCounts.added)"
        )
    }

    private var gitChangeCounts: (modified: Int, deleted: Int, added: Int) {
        var counts = (modified: 0, deleted: 0, added: 0)
        for file in gitStatus?.files ?? [] {
            let status = file.status.uppercased()
            if status.contains("?") || status.contains("A") {
                counts.added += 1
            } else if status.contains("D") {
                counts.deleted += 1
            } else {
                counts.modified += 1
            }
        }
        return counts
    }

    private func refreshGitStatus() {
        Task {
            gitStatus = try? await api.gitStatus(sessionId: sessionId)
        }
    }

    private var composerActionsMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("从相册选择", systemImage: "photo.on.rectangle")
            }
            .disabled(uploadingAttachments)

            Button {
                showFileImporter = true
            } label: {
                Label("从文件选择", systemImage: "paperclip")
            }
            .disabled(uploadingAttachments)
        } label: {
            if uploadingAttachments {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                    .frame(width: 38, height: 38)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            }
        }
        .accessibilityLabel("更多操作")
    }

    private func handlePickedAttachments(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { store.toast = error.localizedDescription }
            return
        }
        uploadAttachments(urls)
    }

    private func handlePickedPhotos(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { store.toast = error.localizedDescription }
            return
        }
        uploadAttachments(urls, cleanupAfterUpload: true)
    }

    private func uploadAttachments(_ urls: [URL], cleanupAfterUpload: Bool = false) {
        uploadingAttachments = true
        Task {
            defer {
                uploadingAttachments = false
                if cleanupAfterUpload {
                    for url in urls {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            do {
                let files = try await api.uploadAttachments(id: sessionId, urls: urls)
                let paths = files.map(\.savedPath).joined(separator: "\n")
                let prefix = "[附件已上传，请查看以下文件:\n\(paths)\n]\n\n"
                draft = prefix + draft
                store.toast = "已上传 \(files.count) 个附件"
            } catch {
                store.toast = error.localizedDescription
            }
        }
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
        followsLatest = true
        store.send(text: text)
        // 清空 draft 后，权限卡/todo bar 的插入移除可能让 @FocusState 丢焦点、键盘收起，
        // 用户得再点一次输入框才能继续。非语音模式且会话未结束时主动保持焦点，连续对话不断。
        if !voiceMode && !store.sessionEnded {
            inputFocused = true
        }
    }

    // MARK: - 按住说话（端侧语音识别）

    /// 麦克风按钮：
    /// - 轻点 → 切换语音输入模式（整个输入框变成「按住说话」面板，图标变键盘）；
    /// - 长按 → 立即按住说话（原交互）：按住录音、上滑取消、松手把识别文本追加进输入框。
    private var micButton: some View {
        Image(systemName: micButtonSymbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(voicePressed ? .white : Theme.brand)
            .frame(width: 32, height: 32)
            .background(
                Circle().fill(
                    voicePressed
                        ? (voiceCanceling ? Theme.danger : Theme.brand)
                        : Theme.brand.opacity(0.12)
                )
            )
            .scaleEffect(voicePressed ? 1.1 : 1)
            .animation(.easeInOut(duration: 0.15), value: voicePressed)
            .animation(.easeInOut(duration: 0.15), value: voiceCanceling)
            .gesture(voiceTapOrHoldGesture(onTap: {
                voiceMode.toggle()
                if voiceMode {
                    inputFocused = false
                    // 进入语音模式即预热：把首次冷启成本（recognizer/授权/setCategory）
                    // 前移到用户还没按下时，避免「按下去很久识别框才出现」。
                    speech.prewarm()
                }
            }))
            .accessibilityLabel(voiceMode ? "切回键盘输入" : "轻点切语音模式，长按说话")
    }

    private var micButtonSymbol: String {
        if speech.isRecording { return "waveform" }
        return voiceMode && !voicePressed ? "keyboard" : "mic"
    }

    /// 语音模式下替换文本框的「按住说话」面板：
    /// 按住录音（同话筒长按），轻点切回键盘输入；非录音时显示当前草稿，所见即所得。
    private var voiceHoldField: some View {
        HStack {
            if voicePressed || draft.isEmpty {
                Spacer(minLength: 0)
            }
            Group {
                if voicePressed {
                    Text(voiceCanceling ? "松开手指，取消输入" : "松开结束 · 上滑取消")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(voiceCanceling ? Theme.danger : Theme.brand)
                } else if draft.isEmpty {
                    Text("按住说话")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Text(draft)
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 48)
        .padding(.vertical, 9)
        .frame(minHeight: 38)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    voicePressed
                        ? (voiceCanceling ? Theme.danger.opacity(0.16) : Theme.brand.opacity(0.14))
                        : Theme.surface
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: voicePressed)
        .animation(.easeInOut(duration: 0.15), value: voiceCanceling)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .gesture(voiceTapOrHoldGesture(onTap: {
            // 轻点面板：切回键盘并自动聚焦，直接接着打字。
            voiceMode = false
            DispatchQueue.main.async { inputFocused = true }
        }))
        .accessibilityLabel("按住说话，轻点切回键盘输入")
    }

    /// 上滑超过该距离进入「松开取消」态（对齐 Web 端 VOICE_CANCEL_THRESHOLD）。
    private static let voiceCancelThreshold: CGFloat = 60

    /// 轻点 vs 按住的分界：按住超过该时长进入录音，否则按轻点处理。
    /// 0.18s 仍足以区分轻点/长按，但比 0.3s 让识别框出现快 ~40%，减少「按下去没反应」的感知延迟。
    private static let voiceHoldThreshold: TimeInterval = 0.18

    /// 轻点 / 按住二分手势：按满阈值 → 开始录音（移动驱动上滑取消、松手提交）；
    /// 阈值内松手 → onTap()。
    private func voiceTapOrHoldGesture(onTap: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if voiceHoldWork == nil && !voicePressed {
                    // 手指刚按下：起计时，按满阈值才真正开始录音。
                    let work = DispatchWorkItem {
                        voiceHoldWork = nil
                        startVoiceRecording()
                    }
                    voiceHoldWork = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Self.voiceHoldThreshold, execute: work
                    )
                }
                if voicePressed {
                    voiceCanceling = value.translation.height < -Self.voiceCancelThreshold
                }
            }
            .onEnded { _ in
                if let work = voiceHoldWork {
                    // 阈值内松手 → 轻点。
                    work.cancel()
                    voiceHoldWork = nil
                    onTap()
                    return
                }
                let cancelled = voiceCanceling
                voicePressed = false
                voiceCanceling = false
                speech.stop(cancelled: cancelled) { text in
                    appendTranscriptToDraft(text)
                }
            }
    }

    /// 按满阈值进入录音态（原「按下立即录音」交互的主体）。
    private func startVoiceRecording() {
        guard !voicePressed else { return }
        voicePressed = true
        voiceCanceling = false
        speech.start { message in
            store.toast = message
            voicePressed = false
            voiceCanceling = false
        }
    }

    /// 识别文本追加进草稿（不覆盖已有内容，对齐 Web 端 commitVoiceTranscript）。
    private func appendTranscriptToDraft(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var existing = draft
        while let last = existing.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            existing.unicodeScalars.removeLast()
        }
        draft = existing.isEmpty ? clean : existing + " " + clean
    }

    /// 输入栏上方的实时转写气泡。
    private var voiceBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: voiceCanceling ? "xmark.circle.fill" : "waveform.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(voiceCanceling ? Theme.danger : Theme.brand)
                Text(voiceCanceling
                     ? "松开手指，取消输入"
                     : (speech.transcript.isEmpty ? "正在聆听…" : speech.transcript))
                    .font(.system(size: 14))
                    .foregroundColor(
                        voiceCanceling
                            ? Theme.danger
                            : (speech.transcript.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !voiceCanceling {
                HStack(spacing: 6) {
                    Text(speech.usingOnDevice ? "端侧识别" : "在线识别")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.brand.opacity(0.12)))
                        .foregroundColor(Theme.brand)
                    Text("松开填入输入框 · 上滑取消")
                        .foregroundColor(Theme.textSecondary)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Color.black.opacity(0.1), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(voiceCanceling ? Theme.danger.opacity(0.55) : Theme.border, lineWidth: 1)
        )
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
    case explorationGroup([ExplorationToolItem])
}

private enum MessageDisplayItem {
    case turn(index: Int, ConversationTurn)
    case explorationGroup(tools: [ExplorationToolItem], lastTurnIndex: Int)
}

private struct ExplorationToolItem {
    let id: String
    let name: String
    let description: String?
    let input: [String: JSONValue]
    let subagent: SubagentMeta?
    let result: ToolResultInfo?
}

/// 将相邻、且内容完全由只读探索工具组成的 assistant turn 跨消息合并。
/// 用户消息、正式文本、编辑/命令等操作都会立即终止分组。
private func groupExplorationTurns(_ turns: [ConversationTurn]) -> [MessageDisplayItem] {
    var items: [MessageDisplayItem] = []
    var pendingTools: [ExplorationToolItem] = []
    var pendingLastIndex = -1

    func flushPending() {
        guard !pendingTools.isEmpty else { return }
        items.append(.explorationGroup(tools: pendingTools, lastTurnIndex: pendingLastIndex))
        pendingTools.removeAll(keepingCapacity: true)
        pendingLastIndex = -1
    }

    for (index, turn) in turns.enumerated() {
        if let tools = explorationToolsOnly(in: turn) {
            pendingTools.append(contentsOf: tools)
            pendingLastIndex = index
        } else {
            flushPending()
            items.append(.turn(index: index, turn))
        }
    }
    flushPending()
    return items
}

private func explorationToolsOnly(in turn: ConversationTurn) -> [ExplorationToolItem]? {
    guard turn.role == "assistant" else { return nil }
    var tools: [ExplorationToolItem] = []
    for item in pairToolBlocks(turn.content) {
        switch item {
        case .explorationGroup(let group):
            tools.append(contentsOf: group)
        case .tool(let id, let name, let description, let input, let subagent, let result)
            where isExplorationTool(name):
            tools.append(ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            ))
        default:
            return nil
        }
    }
    return tools.isEmpty ? nil : tools
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
    var paired: [DisplayItem] = []
    var consumed = Set<Int>()
    for (i, block) in content.enumerated() {
        if consumed.contains(i) { continue }
        guard case .toolUse(let id, let name, let description, let input, let subagent) = block else {
            paired.append(.plain(block))
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
        paired.append(.tool(
            id: id, name: name, description: description,
            input: input, subagent: subagent, result: result
        ))
    }
    return collapseConsecutiveExplorationTools(paired)
}

/// 连续读取、搜索、网页获取通常只是模型探索上下文，不需要逐张占满对话流。
/// 至少连续两次才合并，单次操作仍保留完整工具卡。
private func collapseConsecutiveExplorationTools(_ paired: [DisplayItem]) -> [DisplayItem] {
    var items: [DisplayItem] = []
    var exploration: [ExplorationToolItem] = []

    func flushExploration() {
        if exploration.count >= 2 {
            items.append(.explorationGroup(exploration))
        } else if let tool = exploration.first {
            items.append(.tool(
                id: tool.id, name: tool.name, description: tool.description,
                input: tool.input, subagent: tool.subagent, result: tool.result
            ))
        }
        exploration.removeAll(keepingCapacity: true)
    }

    for item in paired {
        if case .tool(let id, let name, let description, let input, let subagent, let result) = item,
           isExplorationTool(name) {
            exploration.append(ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            ))
        } else {
            flushExploration()
            items.append(item)
        }
    }
    flushExploration()
    return items
}

private func isExplorationTool(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.hasPrefix("read")
        || lower.hasPrefix("grep")
        || lower.hasPrefix("glob")
        || lower.hasPrefix("search")
        || lower.hasPrefix("find")
        || lower.contains("websearch")
        || lower.contains("webfetch")
        || lower == "todoread"
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
        case .explorationGroup(let tools):
            ExplorationGroupCard(
                tools: tools,
                running: isLastTurn && isResponding && tools.contains { $0.result == nil }
            )
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
        case table(headers: [String], rows: [[String]])
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
        case .table(let headers, let rows):
            markdownTable(headers: headers, rows: rows)
        case .divider:
            Divider().overlay(Theme.border).padding(.vertical, 3)
        }
    }

    private func markdownTable(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(normalizedRow(row, count: headers.count), header: false)
                        .background(index.isMultiple(of: 2) ? Theme.surface : Theme.background.opacity(0.45))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(attributed(cell))
                    .font(.system(size: header ? 13 : 12, weight: header ? .semibold : .regular))
                    .foregroundColor(header ? Theme.textPrimary : Theme.textSecondary)
                    .tint(Theme.brand)
                    .textSelection(.enabled)
                    .frame(minWidth: 110, maxWidth: 190, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(header ? Theme.brand.opacity(0.09) : Color.clear)
                    .overlay(alignment: .trailing) {
                        if index < cells.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
    }

    private func normalizedRow(_ row: [String], count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
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

        let lines = text.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let fence {
                if trimmed.hasPrefix(fence) { flushCode() } else { code.append(rawLine) }
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                fence = String(trimmed.prefix(3))
                let suffix = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                language = suffix.isEmpty ? nil : suffix
                lineIndex += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                lineIndex += 1
                continue
            }
            if lineIndex + 1 < lines.count,
               let headers = tableCells(rawLine),
               isTableSeparator(lines[lineIndex + 1], columnCount: headers.count) {
                flushParagraph()
                var rows: [[String]] = []
                lineIndex += 2
                while lineIndex < lines.count, let row = tableCells(lines[lineIndex]), !row.isEmpty {
                    rows.append(row)
                    lineIndex += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }
            let level = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
                flushParagraph()
                result.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                lineIndex += 1
                continue
            }
            let rule = trimmed.replacingOccurrences(of: " ", with: "")
            if ["---", "***", "___"].contains(rule) {
                flushParagraph()
                result.append(.divider)
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                lineIndex += 1
                continue
            }
            if let item = listItem(rawLine) {
                flushParagraph()
                result.append(item)
                lineIndex += 1
                continue
            }
            paragraph.append(rawLine)
            lineIndex += 1
        }
        if fence != nil { flushCode() } else { flushParagraph() }
        return result
    }

    private func tableCells(_ line: String) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    private func isTableSeparator(_ line: String, columnCount: Int) -> Bool {
        guard let cells = tableCells(line), cells.count == columnCount else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.replacingOccurrences(of: ":", with: "")
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
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

/// 连续只读探索操作的紧凑进度卡。默认折叠，避免探索阶段淹没对话。
private struct ExplorationGroupCard: View {
    let tools: [ExplorationToolItem]
    let running: Bool

    @State private var expanded = false

    private var completedCount: Int { tools.filter { $0.result != nil }.count }
    private var failedCount: Int { tools.filter { $0.result?.isError == true }.count }
    private var progress: Double {
        guard !tools.isEmpty else { return 0 }
        return Double(completedCount) / Double(tools.count)
    }
    private var tint: Color {
        if failedCount > 0 { return Theme.danger }
        if running { return Theme.brand }
        return chatSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint.opacity(0.11))
                        if running {
                            ProgressView()
                                .controlSize(.small)
                                .tint(tint)
                        } else {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(tint)
                        }
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("探索上下文")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            Spacer(minLength: 8)
                            Text("\(completedCount)/\(tools.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(tint)
                        }
                        Text(activitySummary)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        ProgressView(value: progress)
                            .tint(tint)
                    }

                    if failedCount > 0 {
                        Text("失败 \(failedCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.danger.opacity(0.10)))
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                    .overlay(Theme.border.opacity(0.7))
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                        HStack(spacing: 8) {
                            Image(systemName: toolStatusIcon(tool))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(toolStatusColor(tool))
                                .frame(width: 14)
                            Text(toolLabel(tool.name))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                                .frame(width: 54, alignment: .leading)
                            Text(toolSummary(tool))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(failedCount > 0 ? 0.42 : 0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 7, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var activitySummary: String {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[activityLabel(tool.name), default: 0] += 1
        }
        return ["读取", "搜索", "网页", "待办"]
            .compactMap { label in counts[label].map { "\(label) \($0)" } }
            .joined(separator: " · ")
    }

    private func activityLabel(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("web") { return "网页" }
        if lower == "todoread" { return "待办" }
        if lower.hasPrefix("read") { return "读取" }
        return "搜索"
    }

    private func toolSummary(_ tool: ExplorationToolItem) -> String {
        for key in ["file_path", "path", "pattern", "query", "url", "file", "filename"] {
            if let value = tool.input[key] {
                let text = value.summaryText
                if !text.isEmpty { return text }
            }
        }
        return tool.description
            ?? tool.input.first.map { "\($0.key): \($0.value.summaryText)" }
            ?? "无参数"
    }

    private func toolStatusIcon(_ tool: ExplorationToolItem) -> String {
        if tool.result?.isError == true { return "xmark.circle.fill" }
        if tool.result != nil { return "checkmark.circle.fill" }
        return "circle.dotted"
    }

    private func toolStatusColor(_ tool: ExplorationToolItem) -> Color {
        if tool.result?.isError == true { return Theme.danger }
        if tool.result != nil { return chatSuccess }
        return Theme.brand
    }
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
    private var statusColor: Color {
        if isError { return Theme.danger }
        if running { return Theme.brand }
        if isSuccess { return chatSuccess }
        return Theme.textSecondary
    }
    private var statusText: String {
        if isError { return "失败" }
        if running { return "处理中" }
        if isSuccess { return "完成" }
        return "待执行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, let result, hasBody {
                Divider()
                    .overlay(Theme.border.opacity(0.7))
                    .padding(.horizontal, 12)
                ToolResultBody(result: result)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusColor.opacity(isError ? 0.42 : 0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 7, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        Button {
            guard hasBody else { return }
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 11) {
                if running {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(statusColor.opacity(0.12))
                        ProgressView()
                            .controlSize(.small)
                            .tint(statusColor)
                    }
                    .frame(width: 34, height: 34)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(statusColor.opacity(isSuccess ? 0.10 : 0.12))
                        Image(systemName: iconName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(statusColor)
                    }
                    .frame(width: 34, height: 34)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(toolLabel(name))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.10)))
                if hasBody {
                    ZStack {
                        Circle().fill(Theme.background)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
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

/// 系统相册选择器。PHPicker 只把用户明确选择的图片交给应用，无需申请整库访问权限。
private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onComplete: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 5
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: (Result<[URL], Error>) -> Void

        init(onComplete: @escaping (Result<[URL], Error>) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else {
                onComplete(.success([]))
                return
            }

            let group = DispatchGroup()
            let lock = NSLock()
            var copiedURLs: [URL] = []
            var firstError: Error?

            for result in results {
                let provider = result.itemProvider
                guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
                    UTType($0)?.conforms(to: .image) == true
                }) else {
                    lock.lock()
                    firstError = PhotoLibraryPickerError.unsupportedImage
                    lock.unlock()
                    continue
                }

                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    defer { group.leave() }
                    do {
                        if let error { throw error }
                        guard let url else { throw PhotoLibraryPickerError.missingFile }
                        let copiedURL = try Self.copyToTemporaryDirectory(
                            source: url,
                            suggestedName: provider.suggestedName,
                            typeIdentifier: typeIdentifier
                        )
                        lock.lock()
                        copiedURLs.append(copiedURL)
                        lock.unlock()
                    } catch {
                        lock.lock()
                        if firstError == nil { firstError = error }
                        lock.unlock()
                    }
                }
            }

            group.notify(queue: .main) {
                if let firstError {
                    for url in copiedURLs {
                        try? FileManager.default.removeItem(at: url)
                    }
                    self.onComplete(.failure(firstError))
                } else {
                    self.onComplete(.success(copiedURLs))
                }
            }
        }

        private static func copyToTemporaryDirectory(
            source: URL,
            suggestedName: String?,
            typeIdentifier: String
        ) throws -> URL {
            let suggested = suggestedName.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            }
            let baseName = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? "photo"
            let fileExtension = source.pathExtension.isEmpty
                ? (UTType(typeIdentifier)?.preferredFilenameExtension ?? "jpg")
                : source.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
    }
}

private enum PhotoLibraryPickerError: LocalizedError {
    case unsupportedImage
    case missingFile

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: return "无法读取所选图片格式"
        case .missingFile: return "无法读取所选图片"
        }
    }
}
