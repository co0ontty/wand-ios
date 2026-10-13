import Combine
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 原生聊天视图：结构化消息渲染 + 原生输入栏 + 权限审批卡片。
/// 输入栏放在内容区下方的 VStack 里（不要用 overlay + PreferenceKey 量高：嵌在任务窗口里
/// 量到的高度会把对话区挤成 0）。键盘避让不走系统自动机制
/// （NavigationView push 页面 + 多行 TextField 组合下系统避让会漏抬、键盘盖住输入栏），
/// 而是 .ignoresSafeArea(.keyboard) 关掉系统行为，由 KeyboardObserver
/// 监听键盘 frame 手动抬升，行为确定。
private enum ChatScrollMode {
    case stickToBottom
    case manual
}

private enum ModelPickerPresentation: String, Identifiable {
    case launch
    case session
    var id: String { rawValue }
}

private enum ComposerChoicePresentation: String, Identifiable {
    case mode
    case attachments
    case context
    var id: String { rawValue }
}

private struct CardExpandDefaultsEnvironmentKey: EnvironmentKey {
    static let defaultValue = CardExpandDefaults()
}

private extension EnvironmentValues {
    var cardExpandDefaults: CardExpandDefaults {
        get { self[CardExpandDefaultsEnvironmentKey.self] }
        set { self[CardExpandDefaultsEnvironmentKey.self] = newValue }
    }
}

private struct ChatAPIEnvironmentKey: EnvironmentKey {
    static let defaultValue: WandAPI? = nil
}

private struct ChatToolContentDidLoadKey: EnvironmentKey {
    static let defaultValue: ((ToolContentResponse) -> Void)? = nil
}

private struct ChatSessionIDEnvironmentKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var chatAPI: WandAPI? {
        get { self[ChatAPIEnvironmentKey.self] }
        set { self[ChatAPIEnvironmentKey.self] = newValue }
    }

    var chatToolContentDidLoad: ((ToolContentResponse) -> Void)? {
        get { self[ChatToolContentDidLoadKey.self] }
        set { self[ChatToolContentDidLoadKey.self] = newValue }
    }

    var chatSessionID: String {
        get { self[ChatSessionIDEnvironmentKey.self] }
        set { self[ChatSessionIDEnvironmentKey.self] = newValue }
    }
}

struct ChatView: View {
    private let sessionId: String
    private let api: WandAPI
    /// 工作区任务页已经有系统返回键和任务标题。嵌套时再往导航栏塞 badge / 路径，
    /// 会和 iOS 26 圆形返回键叠在一起，浅色背景下看起来像残影。
    private let showsNavigationChrome: Bool
    private let offersInitialCall: Bool
    private let onCompletionVisible: ((SessionSnapshot) -> Void)?
    @State private var viewVisible = false
    @State private var showProviderPicker = false

    @StateObject private var store: ChatStore
    @StateObject private var keyboard = KeyboardObserver()
    @StateObject private var speech = SpeechRecognizerService()
    @StateObject private var call = VoiceCallController()
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var showCallTarget = false
    @State private var showDraftEditor = false
    @State private var offeredInitialCall = false
    @StateObject private var composerDraft: ComposerDraftState
    @State private var voiceDraftRevision = 0
    @State private var voiceDraftLifecycle = 0
    private var draft: String { composerDraft.text }
    @State private var showQuickCommit = false
    @State private var showDirectoryPicker = false
    @State private var showPiResources = false
    @StateObject private var sessionFiles: SessionFilesStore
    @State private var scrollMode: ChatScrollMode = .stickToBottom
    @State private var voicePressed = false
    @State private var voiceCanceling = false
    @State private var draftNeedsExpanded = false
    @State private var composerInputHeight: CGFloat = 34
    @State private var composerIsComposing = false
    @StateObject private var attachments: ComposerAttachmentController
    @StateObject private var serverFileLinks = ServerFileLinkController()
    @State private var gitStatus: GitStatusResult?
    @StateObject private var quickCommitFeedback = QuickCommitFeedbackController()
    /// 轻点 vs 按住的计时器：按满阈值才开始录音，阈值内松手按轻点处理。
    /// 停止任务二次确认弹窗开关：点停止按钮先弹确认，避免误触中断正在跑的任务。
    @State private var showStopConfirm = false
    @State private var showActivityPanel = false
    /// 排队消息气泡条是否展开成列表（默认折叠成「已排队 N 条」徽章）。
    @State private var queueBarExpanded = false
    /// 历史折叠记录绝对 turn 下标。prepend 更早页会同时改变 loadedOffset 和局部下标，
    /// 但两者之和不变，因此分页不会把用户刚展开的历史重新收起。
    @State private var expandedHistoryBoundaryAbsolute: Int?
    /// 用户手动收起的助手回复，使用绝对 turn 下标避免历史 prepend 后串状态。
    @State private var collapsedAssistantTurns: Set<Int> = []
    /// 每次贴底请求递增；较旧的下一帧任务看到代次变化后自行退出，避免连续事件抢滚动。
    @State private var scrollRequestGeneration = 0
    /// 顶部分页哨兵是否在视口内。只有用户主动向历史方向拖动后才允许触发，避免页面
    /// 初次布局从顶部跳到底部的瞬间误加载。
    @State private var earlierSentinelVisible = false
    /// prepend 前最早一条现有消息的稳定身份；加载完成后滚回它，避免内容插入导致阅读位置跳动。
    @State private var earlierLoadAnchorID: String?
    /// 应用前后台感知：回前台做连接健康检查 + 拉最新快照，避免半死连接苦等 40s 看门狗。
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 不用 @FocusState：输入框是 UIKit UITextView，没有挂 .focused()。
    /// FocusState 在没有绑定视图时会把 true 立刻打回 false，updateUIView 再 resign，键盘就弹不出来。
    @StateObject private var composerFocus = ComposerFocusController()
    private var inputFocused: Bool { get { composerFocus.focused } nonmutating set { composerFocus.focused = newValue } }
    @State private var composerAcknowledged = false
    private var composerEditing: Bool { get { composerFocus.editing } nonmutating set { composerFocus.editing = newValue } }
    @State private var voiceNotice = ""
    @AppStorage(CatComposerSide.preferenceKey) private var catSideRaw = CatComposerSide.left.rawValue
    @State private var catDragOffset: CGFloat = 0
    @State private var modelPicker: ModelPickerPresentation?
    @State private var composerChoice: ComposerChoicePresentation?
    @State private var visibleTurnIndex = 0
    @State private var holdCompletedClock = ""
    @State private var sawResponding = false

    init(sessionId: String, api: WandAPI, showsNavigationChrome: Bool = true,
         onCompletionVisible: ((SessionSnapshot) -> Void)? = nil, sharedStore: ChatStore? = nil, offersInitialCall: Bool = false) {
        self.sessionId = sessionId
        self.api = api
        self.showsNavigationChrome = showsNavigationChrome
        self.offersInitialCall = offersInitialCall
        self.onCompletionVisible = onCompletionVisible
        let chatStore = sharedStore ?? ChatStore(sessionId: sessionId, api: api)
        _store = StateObject(wrappedValue: chatStore)
        _sessionFiles = StateObject(wrappedValue: SessionFilesStore(service: api))
        _composerDraft = StateObject(wrappedValue: chatStore.composerDraft)
        _attachments = StateObject(wrappedValue: chatStore.composerDraft.attachments)
    }

    private var chatLayout: some View {
        GeometryReader { root in
            ZStack(alignment: .bottom) {
                if showsNavigationChrome {
                    WandAmbientBackground()
                }
                VStack(spacing: 0) {
                    mainContent
                        .clipped() // Clip the viewport, not just the first message's padding.
                        .padding(.top, showsNavigationChrome ? ChatTopLayout.clearance(compact: verticalSizeClass == .compact) : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture { composerFocus.collapse() }
                        .overlay(alignment: .bottom) { toastView }

                    bottomBar
                        .padding(.bottom, root.safeAreaInsets.bottom)
                        .animation(WandMotion.scroll, value: keyboard.lift)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(showsNavigationChrome ? Theme.background : Color.clear)
        .onChange(of: sessionFiles.open) { _, open in if !open { composerFocus.resume("files") } }
        .onChange(of: serverFileLinks.failure?.id) { _, failure in if failure != nil { composerFocus.resume("preview") } }
        .onChange(of: speech.isProcessing) { _, processing in
            if !processing && !voicePressed { composerFocus.resume("voice") }
        }
        .onChange(of: composerDraft.text) { _, value in
            if !value.isEmpty { composerAcknowledged = false }
            if value.isEmpty { draftNeedsExpanded = false; composerInputHeight = 34 }
            if call.ownsInput { call.pause("已切换到文字输入，点继续恢复通话") }
        }
        // 点消息区任意空白处收起键盘；输入栏在 VStack 底部，不受 dismiss 手势误伤。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsNavigationChrome ? .hidden : .automatic, for: .navigationBar)
        .overlay(alignment: .top) {
            if showsNavigationChrome {
                ZStack(alignment: .top) {
                    TopChatCompanion(side: catSide, dragOffset: catDragOffset) { size in companionFace(size: size) }
                    floatingChatControls.padding(.top, verticalSizeClass == .compact ? 0 : 18)
                }
            }
        }
        // 关掉系统键盘避让，统一交给 KeyboardObserver 手动抬升（见 bottomBar），
        // 避免「系统抬一次 + 手动抬一次」叠加或两边都不抬的不确定行为。
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var floatingChatControls: some View {
        FloatingChatControls(onBack: { dismiss() }) {
            Button { composerFocus.borrow("files"); sessionFiles.show(cwd: store.snapshot?.cwd ?? "") } label: { FloatingChatIcon(symbol: "folder") }
                .buttonStyle(.plain).disabled(store.snapshot?.cwd?.isEmpty != false).accessibilityLabel("会话文件")
            Menu {
                Section("当前会话") {
                    Text(store.displayEmployeeName ?? store.snapshot?.providerLabel ?? "当前会话")
                    Text(store.snapshot?.cwd ?? "未选择目录")
                    Button("模型、目录与执行设置") { composerChoice = .context }
                    Button("返回选择其他员工或会话") { dismiss() }
                }
                if store.snapshot?.provider == "pi", store.isStructured {
                    Button("工具与资源") { showPiResources = true }
                }
                if store.isStructured {
                    Button("持续语音通话") { showCallTarget = true }
                        .disabled(store.snapshot?.employeeId == nil || store.snapshot?.cwd?.isEmpty != false)
                }
                Menu("猫头位置") {
                    Button("控件间居中") { catSideRaw = CatComposerSide.left.rawValue }
                    Button("向右微移") { catSideRaw = CatComposerSide.right.rawValue }
                }
                if store.isResponding { Button("停止当前任务", role: .destructive) { showStopConfirm = true } }
                if call.phase == .speaking { Button("暂停朗读声音") { call.pause("朗读已暂停，点继续恢复") } }
                Button("Git 变更与提交") { showQuickCommit = true }
            } label: { FloatingChatIcon(symbol: "ellipsis") }
                .accessibilityLabel("更多会话功能")
                .accessibilityValue("\(store.displayEmployeeName ?? "当前会话")，\(store.snapshot?.cwd ?? "未选择目录")")
        }
    }

    private var callContent: some View {
        chatLayout
        .confirmationDialog("开始语音通话", isPresented: $showCallTarget, titleVisibility: .visible) {
            Button("开始通话") {
                speech.stop(cancelled: true)
                inputFocused = false
                call.start(store: store)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(store.displayEmployeeName ?? "员工")\n\(store.snapshot?.cwd ?? "")\n说完后发送给当前会话；回复由系统语音播报。")
        }
        .onChange(of: store.isResponding) { _, _ in call.update() }
        .onChange(of: store.inputFeedback) { _, value in
            if value == .failed { composerAcknowledged = false }
            call.update()
        }
        .onChange(of: store.unconfirmedInput) { _, value in
            if value != nil { composerAcknowledged = false }
        }
        .onChange(of: store.pendingEscalation?.requestId) { _, _ in call.update() }
        .onChange(of: store.permissionBlocked) { _, _ in call.update() }
        .onChange(of: store.connected) { _, _ in call.update() }
        .onChange(of: store.messages.count) { _, _ in call.update() }
        .onChange(of: store.messages.last?.completedAt) { _, _ in call.update() }
        .onChange(of: store.snapshot?.cwd) { _, _ in call.pause("工作目录已变化，请核对目标后继续") }
        .onChange(of: store.snapshot?.employeeId) { _, _ in call.pause("员工已变化，请核对目标后继续") }
        .onChange(of: store.providerSwitching) { _, switching in if switching { call.pause("执行工具正在切换，请核对目标后继续") } }
        .onChange(of: store.loading) { _, loading in
            if !loading, offersInitialCall, !offeredInitialCall, store.loadError == nil {
                offeredInitialCall = true; showCallTarget = true
            }
        }
        .onChange(of: scenePhase) { _, value in
            if value != .active { call.pause("应用已离开前台，点继续恢复通话") }
        }
        .onDisappear { call.end() }
    }

    private var modalContent: some View {
        callContent
        .sheet(isPresented: $showActivityPanel, onDismiss: { composerFocus.resume("activity") }) { activityPanel }
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(
                sessionId: sessionId,
                api: api,
                onRunning: beginQuickCommitFeedback,
                onCompleted: completeQuickCommitFeedback,
                onFailed: failQuickCommitFeedback
            )
                .presentationDetents([.height(620), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(get: { sessionFiles.open }, set: { if !$0 { sessionFiles.requestClose() } })) {
            SessionFilesView(store: sessionFiles, api: api)
        }
        .sheet(isPresented: $showDirectoryPicker) {
            BlankSessionDirectoryPicker(store: store) { showDirectoryPicker = false }
        }
        .sheet(isPresented: $showDraftEditor, onDismiss: { composerIsComposing = false; focusComposer() }) {
            ComposerDraftEditor(text: $composerDraft.text, onCompositionChange: { composerIsComposing = $0 },
                onPasteImages: { attachments.handlePastedImageData($0) })
        }
        .sheet(isPresented: $showPiResources) { PiResourcesView(sessionID: sessionId, api: api) }
        .fileImporter(
            isPresented: $attachments.showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: attachments.handleFileSelection
        )
        .sheet(isPresented: $attachments.showPhotoPicker) {
            PhotoLibraryPicker { result in
                attachments.showPhotoPicker = false
                attachments.handlePhotoSelection(result)
            }
        }
        .sheet(item: $serverFileLinks.previewItem, onDismiss: {
            serverFileLinks.dismissPreview()
            composerFocus.resume("preview")
        }) { item in
            ServerFilePreviewView(item: item)
        }
        .sheet(isPresented: $showProviderPicker) {
            SearchableChoiceSheet(title: "切换执行工具", sections: [
                SearchableChoiceSection(id: "provider", items: WandAgentTool.allCases.map {
                    SearchableChoiceItem(id: $0.rawValue, label: $0.title)
                }, selectedId: store.snapshot?.agentTool.rawValue ?? "")
            ]) { _, id in
                if let tool = WandAgentTool(rawValue: id) { store.switchProvider(tool.provider.rawValue, engine: tool.engine) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $modelPicker) { picker in
            SearchableChoiceSheet(
                title: picker == .session ? "模型与思考" : "选择模型",
                searchPrompt: "搜索模型",
                sections: modelPickerSections(for: picker)
            ) { sectionId, itemId in
                if sectionId == "thinking" {
                    store.setThinkingEffort(itemId)
                } else {
                    store.setModel(itemId.isEmpty ? nil : itemId)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $composerChoice) { choice in
            composerChoiceSheet(choice)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(item: $serverFileLinks.failure) { failure in
            Alert(
                title: Text("文件下载失败"),
                message: Text(failure.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    var body: some View {
        modalContent
        .onChange(of: completionVisibilityToken) { _, _ in publishCompletionVisibility() }
        .onAppear {
            if !viewVisible { store.attachView() }
            viewVisible = true
            let activeStore = store
            attachments.setToastHandler { [weak activeStore] in activeStore?.toast = $0 }
            refreshGitStatus()
        }
        .onChange(of: showQuickCommit) { _, showing in
            if !showing { refreshGitStatus() }
        }
        .onDisappear {
            if viewVisible { store.detachView() }
            viewVisible = false
            speech.stop(cancelled: true)
            voicePressed = false
            voiceCanceling = false
            serverFileLinks.cancel()
        }
        .onChange(of: scenePhase) { _, newPhase in
            wlog("session", "scenePhase=\(newPhase) session=\(sessionId)")
            if newPhase == .active { store.handleEnterForeground() }
            else if newPhase == .background { store.handleEnterBackground() }
        }
        .overlay(alignment: .top) { connectionBanner }
        .animation(WandMotion.disclosure, value: store.connected)
        .overlay {
            if serverFileLinks.isDownloading {
                HStack(spacing: 10) {
                    Label("正在从服务器下载…", systemImage: "arrow.down.circle")
                        .font(.wand(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Button {
                        serverFileLinks.cancel()
                        composerFocus.resume("preview")
                    } label: {
                        Text("取消")
                            .font(.wand(size: 13, weight: .semibold))
                            .foregroundColor(Theme.brand)
                    }
                    .accessibilityLabel("取消下载")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            }
        }
        .environment(\.cardExpandDefaults, store.cardDefaults)
        .environment(\.chatAPI, api)
        .environment(\.chatSessionID, sessionId)
        .environment(\.chatDecisionCards, store.decisionCards)
        .environment(\.chatToolContentDidLoad, { [weak store] loaded in store?.applyLoadedToolContent(loaded) })
        .environment(\.serverFileLinkController, serverFileLinks)
        .wandKeyboardShortcuts(chatKeyboardShortcuts)
    }

    private var chatKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "focus-input",
                title: "聚焦输入",
                key: "l",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && !inputFocused
            ) {
                inputFocused = true
            },
            WandKeyboardShortcutAction(
                id: "send",
                title: "发送",
                key: .return,
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && canSend
            ) {
                sendDraft()
            },
            WandKeyboardShortcutAction(
                id: "stop",
                title: "停止任务",
                key: ".",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && store.isResponding
            ) {
                showStopConfirm = true
            },
            WandKeyboardShortcutAction(
                id: "attach-file",
                title: "选择文件",
                key: "o",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && !attachments.isUploading
            ) {
                inputFocused = false
                attachments.showFileImporter = true
            },
            WandKeyboardShortcutAction(
                id: "quick-commit",
                title: "快速提交",
                key: "c",
                modifiers: [.command, .shift],
                isEnabled: keyboardShortcutsActive && quickCommitFeedback.phase == .idle
            ) {
                showQuickCommit = true
            },
            WandKeyboardShortcutAction(
                id: "dismiss-input",
                title: "收起输入",
                key: .escape,
                modifiers: [],
                isEnabled: keyboardShortcutsActive && inputFocused
            ) {
                inputFocused = false
            },
        ]
    }

    private var keyboardShortcutsActive: Bool {
        if call.active { return false }
        return !showQuickCommit
            && !showDraftEditor
            && !attachments.showFileImporter
            && !attachments.showPhotoPicker
            && !showStopConfirm
            && modelPicker == nil
            && composerChoice == nil
            && !showProviderPicker
            && serverFileLinks.previewItem == nil
            && serverFileLinks.failure == nil
    }

    private var completionVisibilityToken: String {
        "\(viewVisible):\(scenePhase):\(keyboardShortcutsActive):\(store.loading):\(store.loadError == nil):\(store.snapshot?.completionRevision ?? 0):\(store.isResponding):\(store.permissionBlocked):\(store.pendingEscalation != nil):\(store.snapshot?.archived == true)"
    }

    private func publishCompletionVisibility() {
        guard viewVisible, scenePhase == .active, keyboardShortcutsActive,
              !store.loading, store.loadError == nil, let snapshot = store.snapshot else { return }
        onCompletionVisible?(snapshot)
    }

    @ViewBuilder private var mainContent: some View {
        if store.loading {
            ProgressView().tint(Theme.brand)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.loadError {
            VStack(spacing: 14) {
                Text("加载失败").font(.headline).foregroundColor(Theme.textPrimary)
                Text(error).font(.footnote).foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("重试") { store.retryInitialLoad() }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .accessibilityLabel("重新加载会话")
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isStructured && store.messages.isEmpty && !store.isResponding {
            sessionLaunchPanel
        } else {
            messageList
        }
    }

    // MARK: - 断线提示条

    @ViewBuilder private var connectionBanner: some View {
        if !store.connected {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                Text("连接已断开，正在重连…")
                    .font(.wand(size: 13, weight: .medium))
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
                        // 用户浏览到顶部时自动加载更早消息。哨兵不再要求点击；每次 prepend 后
                        // 会恢复原阅读锚点，使哨兵退出视口，避免一次到顶连续翻完全部历史。
                        if store.canLoadEarlier {
                            HStack(spacing: 8) {
                                Spacer()
                                if store.loadingEarlier {
                                    ProgressView().controlSize(.small).tint(Theme.brand)
                                    Text("正在加载更早消息…")
                                        .font(.wand(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .frame(minHeight: 24)
                            .accessibilityLabel(store.loadingEarlier ? "正在加载更早消息" : "继续向上滚动加载更早消息")
                            .id("chat-top")
                            .onAppear {
                                earlierSentinelVisible = true
                                requestEarlierMessagesIfNeeded()
                            }
                            .onDisappear { earlierSentinelVisible = false }
                        }
                        // 把每个 assistant turn 摊平成独立的 LazyVStack 行（而非整条 turn 一个
                        // 急加载 VStack）：一条 assistant 消息可能携带上百个 text/工具/diff 块，
                        // 整条一次性构建会在主线程同步堆出数百个嵌套视图，打开会话时直接卡死、
                        // 什么都渲染不出来。摊平后 LazyVStack 只实例化进入视口的行。
                        ForEach(identifiedMessageItems(presentedMessageItems, turnOffset: store.loadedOffset)) { row in
                            messageItemView(row.item, proxy: proxy)
                                .onAppear {
                                    let index = itemTurnIndex(row.item)
                                    if store.messages.indices.contains(index) {
                                        visibleTurnIndex = index
                                    }
                                }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                }
                .scrollContentBackground(.hidden)
                .modifier(DismissKeyboardOnDrag())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            // 仅用户明确向下拖动、准备查看更早消息时暂停跟随。
                            // 旧逻辑任何轻微拖动都会永久关掉跟随，收键盘或触摸
                            // 列表后，新回复就只能靠右下角按钮才能看到。
                            if value.translation.height > 18 {
                                scrollMode = .manual
                                requestEarlierMessagesIfNeeded()
                            }
                        }
                )
                .overlay(alignment: .trailing) {
                    if store.messages.count >= 2 {
                        ConversationTurnScrubber(
                            itemCount: store.messages.count,
                            currentItem: visibleTurnIndex,
                            currentPreview: scrubberUserPreview(turns: store.messages, index: visibleTurnIndex)
                        ) { index, animate in
                            guard store.messages.indices.contains(index) else { return }
                            visibleTurnIndex = index
                            scrollMode = .manual
                            let targetID = scrubberScrollID(for: index)
                            if animate {
                                withAnimation(WandMotion.scroll) {
                                    proxy.scrollTo(targetID, anchor: .top)
                                }
                            } else {
                                proxy.scrollTo(targetID, anchor: .top)
                            }
                        }
                        .padding(.trailing, 3)
                        .padding(.vertical, 12)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if scrollMode == .manual {
                        jumpToLatestButton(proxy)
                    }
                }
                .onAppear { scrollToActiveTarget(proxy) }
                .onReceive(store.$messages.dropFirst()) { _ in
                    scrollToActiveTarget(proxy)
                }
                .onChange(of: store.loadedOffset) {
                    restoreEarlierLoadAnchor(proxy)
                }
                .onChange(of: store.leadingBlockOffset) {
                    restoreEarlierLoadAnchor(proxy)
                }
                .onChange(of: store.loadingEarlier) { _, loadingEarlier in
                    // 空页或请求失败不会改变 offset，不能让过期锚点误作用于之后的推送。
                    if !loadingEarlier, earlierLoadAnchorID != nil {
                        Task { @MainActor in
                            await Task.yield()
                            earlierLoadAnchorID = nil
                        }
                    }
                }
                .onChange(of: store.isResponding) {
                    if store.isResponding {
                        sawResponding = true
                    } else if sawResponding {
                        let fromTurn = store.messages.last(where: { $0.role == "assistant" })
                            .map { SessionTimeFormatting.conversationTurnClock($0) } ?? ""
                        holdCompletedClock = fromTurn.isEmpty
                            ? SessionTimeFormatting.chatClock(iso: SessionTimeFormatting.nowISO())
                            : fromTurn
                    }
                    scrollToActiveTarget(proxy)
                }
                .onChange(of: store.loading) { _, loading in
                    if !loading { scrollToActiveTarget(proxy) }
                }
                .onChange(of: keyboard.lift) {
                    scrollToActiveTarget(proxy)
                }
                .onChange(of: inputExpanded) {
                    scrollToActiveTarget(proxy)
                }
                .onChange(of: store.queuedMessages.count) {
                    scrollToActiveTarget(proxy)
                }
                .onChange(of: store.pendingEscalation != nil) {
                    scrollToActiveTarget(proxy)
                }
        }
    }

    private func requestEarlierMessagesIfNeeded() {
        guard shouldAutoLoadEarlierMessages(
            isTopSentinelVisible: earlierSentinelVisible,
            isBrowsingHistory: scrollMode == .manual,
            canLoadEarlier: store.canLoadEarlier,
            loadingEarlier: store.loadingEarlier
        ) else { return }

        earlierLoadAnchorID = identifiedMessageItems(
            presentedMessageItems,
            turnOffset: store.loadedOffset
        ).first?.id
        store.loadEarlier()
    }

    private func restoreEarlierLoadAnchor(_ proxy: ScrollViewProxy) {
        guard let anchorID = earlierLoadAnchorID else { return }
        earlierLoadAnchorID = nil
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    @ViewBuilder private func messageItemView(_ item: MessageDisplayItem, proxy: ScrollViewProxy) -> some View {
        switch item {
        case .assistantHeader(let turnIndex, let preview):
            let absoluteTurn = absoluteTurnIndex(
                localIndex: turnIndex,
                loadedOffset: store.loadedOffset
            )
            let collapsed = collapsedAssistantTurns.contains(absoluteTurn)
            HStack(spacing: 6) {
                if store.messages.indices.contains(turnIndex) {
                    ChatMessageTime(clock: SessionTimeFormatting.conversationTurnClock(store.messages[turnIndex]), alignEnd: false)
                }
                AssistantReplyDisclosure(
                    preview: preview,
                    collapsed: collapsed,
                    onToggle: {
                        if collapsed {
                            collapsedAssistantTurns.remove(absoluteTurn)
                        } else {
                            collapsedAssistantTurns.insert(absoluteTurn)
                        }
                    }
                )
            }
        case .turn(let index, let turn):
            let turnView = TurnView(
                turn: turn,
                baseURL: store.api.baseURL,
                isLastTurn: index == store.messages.count - 1,
                isResponding: store.isResponding,
                compactUser: false,
                askSelections: store.displayedAskSelections,
                onAskToggle: { toolUseId, qIdx, optIdx, multi in
                    store.toggleAskOption(
                        toolUseId: toolUseId, questionIndex: qIdx,
                        optionIndex: optIdx, multiSelect: multi
                    )
                },
                onAskSubmit: { toolUseId, answerText in
                    expandedHistoryBoundaryAbsolute = nil
                    scrollMode = .stickToBottom
                    store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                }
            )
            turnView
        case .assistantItem(let turnIndex, let displayItem):
            AssistantItemView(
                item: displayItem,
                baseURL: store.api.baseURL,
                isLastTurn: turnIndex == store.messages.count - 1,
                isResponding: store.isResponding,
                askSelections: store.displayedAskSelections,
                onAskToggle: { toolUseId, qIdx, optIdx, multi in
                    store.toggleAskOption(
                        toolUseId: toolUseId, questionIndex: qIdx,
                        optionIndex: optIdx, multiSelect: multi
                    )
                },
                onAskSubmit: { toolUseId, answerText in
                    expandedHistoryBoundaryAbsolute = nil
                    scrollMode = .stickToBottom
                    store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                }
            )
        case .explorationGroup(let tools, let lastTurnIndex):
            ExplorationGroupCard(
                tools: tools,
                baseURL: store.api.baseURL,
                running: store.isResponding
                    && lastTurnIndex == store.messages.count - 1
                    && tools.contains { $0.result == nil },
                expandAll: lastTurnIndex == store.messages.count - 1
            )
        case .activityGroup(let turnIndex, let group, _):
            ActivityFoldCard(
                group: group,
                baseURL: store.api.baseURL,
                isLastTurn: turnIndex == store.messages.count - 1,
                isResponding: store.isResponding,
                askSelections: store.displayedAskSelections,
                onAskToggle: { toolUseId, qIdx, optIdx, multi in
                    store.toggleAskOption(
                        toolUseId: toolUseId, questionIndex: qIdx,
                        optionIndex: optIdx, multiSelect: multi
                    )
                },
                onAskSubmit: { toolUseId, answerText in
                    expandedHistoryBoundaryAbsolute = nil
                    scrollMode = .stickToBottom
                    store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                }
            )
        case .resourceSelection(_, let notice):
            ResourceSelectionNoticeView(notice: notice)
        case .usageSummary:
            EmptyView()
        case .historySummary(let stats, let boundary):
            HistorySummaryCard(
                stats: stats,
                expanded: expandedHistoryBoundaryAbsolute == absoluteTurnIndex(
                    localIndex: boundary,
                    loadedOffset: store.loadedOffset
                ),
                onToggle: { toggleHistory(proxy) }
            )
            .id(historySummaryAnchorID(
                localBoundary: boundary,
                loadedOffset: store.loadedOffset
            ))
        }
    }

    /// 最后一条用户消息的下标；没有则 -1。
    private var lastUserTurnIndex: Int {
        for i in stride(from: store.messages.count - 1, through: 0, by: -1) where store.messages[i].role == "user" {
            return i
        }
        return -1
    }

    private var historyBoundary: Int {
        lastUserTurnIndex
    }

    private var absoluteHistoryBoundary: Int? {
        guard historyBoundary >= 0 else { return nil }
        return absoluteTurnIndex(localIndex: historyBoundary, loadedOffset: store.loadedOffset)
    }

    private var hasCollapsedHistory: Bool {
        historyBoundary >= 2
    }

    private var isHistoryExpanded: Bool {
        expandedHistoryBoundaryAbsolute == absoluteHistoryBoundary
    }

    private var currentHistoryStats: HistoryStats {
        computeHistoryStats(turns: store.messages, boundary: historyBoundary)
    }

    private var latestUserTurn: ConversationTurn? {
        guard lastUserTurnIndex >= 0, store.messages.indices.contains(lastUserTurnIndex) else { return nil }
        return store.messages[lastUserTurnIndex]
    }

    private var subagentActivities: [SubagentActivity] {
        collectSubagentActivities(messages: store.messages, isResponding: store.isResponding)
    }

    private var completedClock: String {
        if store.isResponding { return "" }
        if !holdCompletedClock.isEmpty { return holdCompletedClock }
        return store.messages.last(where: { $0.role == "assistant" })
            .map { SessionTimeFormatting.conversationTurnClock($0) } ?? ""
    }

    private var shouldShowSubagentShelf: Bool {
        // 没有子任务时不摆一条点不开的「子 Agent」栏：运行态提示交给输入栏，这里只承接真实子任务。
        store.isStructured && !subagentActivities.isEmpty
    }

    private var groupedMessageItems: [MessageDisplayItem] {
        let base = collapseActivityItems(
            flattenAssistantTurns(
                groupExplorationTurns(toolPairedDisplayTurns(store.messages)),
                liveTurnIndex: store.isResponding ? latestAssistantTurnIndex : nil
            ),
            latestTurnIndex: latestAssistantTurnIndex ?? -1,
            running: store.isResponding
        )
        return base
    }

    private var presentedMessageItems: [MessageDisplayItem] {
        groupedMessageItems.filter { item in
            if case .assistantHeader = item { return true }
            let turnIndex = itemTurnIndex(item)
            guard store.messages.indices.contains(turnIndex), store.messages[turnIndex].role == "assistant" else {
                return true
            }
            let absoluteTurn = absoluteTurnIndex(localIndex: turnIndex, loadedOffset: store.loadedOffset)
            return !collapsedAssistantTurns.contains(absoluteTurn)
        }
    }

    /// 当前轮 assistant 回复的下标；用于流式状态和活动分组判断。
    private var latestAssistantTurnIndex: Int? {
        guard let last = store.messages.indices.last,
              store.messages[last].role == "assistant",
              last > lastUserTurnIndex else { return nil }
        return last
    }

    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            expandedHistoryBoundaryAbsolute = nil
            scrollMode = .stickToBottom
            scrollToActiveTarget(proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.brand))
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.10), radius: 6, y: 2)
        }
        .accessibilityLabel("回到列表底部")
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func toggleHistory(_ proxy: ScrollViewProxy) {
        guard hasCollapsedHistory else { return }
        let boundary = historyBoundary
        let absoluteBoundary = absoluteTurnIndex(
            localIndex: boundary,
            loadedOffset: store.loadedOffset
        )
        let anchorID = "history-summary-\(absoluteBoundary)"
        let next = !isHistoryExpanded
        expandedHistoryBoundaryAbsolute = next ? absoluteBoundary : nil
        scrollMode = next ? .manual : .stickToBottom
        if next {
            Task { @MainActor in
                // 等新一轮 LazyVStack 布局提交，不用固定延时和慢设备/分页竞争。
                await Task.yield()
                guard expandedHistoryBoundaryAbsolute == absoluteBoundary else { return }
                withAnimation(WandMotion.scroll) {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        } else {
            scrollToActiveTarget(proxy, animated: true)
        }
    }

    /// 根据当前模式同步滚动：贴底跟随，或尊重用户手动浏览。
    private func scrollToActiveTarget(_ proxy: ScrollViewProxy, animated: Bool = false) {
        guard scrollMode != .manual else { return }
        let mode = scrollMode
        scrollRequestGeneration &+= 1
        let generation = scrollRequestGeneration
        let scroll = {
            switch mode {
            case .stickToBottom:
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            case .manual:
                break
            }
        }
        let performScroll = {
            if animated && !reduceMotion {
                withAnimation(WandMotion.scroll) { scroll() }
            } else {
                scroll()
            }
        }
        performScroll()
        Task { @MainActor in
            // 等消息、键盘或输入栏的新布局提交，再校正一次；新请求或用户手势会取消旧请求。
            await Task.yield()
            guard scrollRequestGeneration == generation, scrollMode == mode else { return }
            performScroll()
        }
    }

    // MARK: - 顶部状态

    private var currentProvider: WandProvider {
        WandProvider(normalizing: store.snapshot?.provider)
    }

    private var providerTint: Color { Theme.providerColor(store.snapshot?.provider) }

    private var sessionLaunchPanel: some View {
        let provider = currentProvider
        let tint = providerTint
        return VStack(spacing: 14) {
            Spacer(minLength: 12)
            Button { showProviderPicker = true } label: {
                ZStack {
                    BrandLogo(provider: store.snapshot?.provider, color: tint.opacity(0.94))
                        .opacity(store.providerSwitching ? 0 : 1)
                    ProgressView().tint(tint).opacity(store.providerSwitching ? 1 : 0)
                }.frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!store.canSwitchProvider)
            .accessibilityLabel("切换 CLI 工具")
            Text("开始与 \(store.snapshot?.providerLabel ?? provider.title) 的对话")
                .font(.wand(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("输入消息，让它帮你完成任务")
                .font(.wand(size: 13))
                .foregroundColor(Theme.textSecondary)
            launchContextControls
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var launchContextControls: some View {
        if store.isStructured && !inputExpanded {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    launchModelMenu
                    launchThinkingMenu
                }
                VStack(spacing: 8) {
                    launchModelMenu
                    launchThinkingMenu
                }
            }
            .frame(maxWidth: 340)
            if store.canChangeDirectory {
                Button { showDirectoryPicker = true } label: {
                    Label(store.snapshot?.cwd ?? "选择运行目录", systemImage: "folder")
                        .font(.subheadline).lineLimit(1).truncationMode(.middle).frame(minHeight: 44)
                }.accessibilityLabel("切换运行目录")
            }
        }
    }

    private var launchModelMenu: some View {
        Button {
            modelPicker = .launch
        } label: {
            launchOptionChrome(title: "模型", value: launchModelLabel, icon: "cpu")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("模型")
        .accessibilityValue(launchModelLabel)
        .accessibilityHint("轻点选择模型")
    }

    private var launchThinkingMenu: some View {
        launchOptionMenu(
            title: "思考深度",
            value: thinkingLabel(store.thinkingEffort),
            icon: "brain"
        ) {
            ForEach(thinkingLevels) { level in
                Button {
                    store.setThinkingEffort(level.id)
                } label: {
                    if effectiveThinkingOption?.id == level.id {
                        Label(level.menuLabel, systemImage: "checkmark")
                    } else {
                        Text(level.menuLabel)
                    }
                }
            }
        }
    }

    private var launchModelLabel: String {
        guard let selected = store.selectedModel, !selected.isEmpty, selected != "default" else {
            return defaultModelLabel
        }
        return store.availableModels.first(where: { $0.id == selected })?.label ?? selected
    }

    private var defaultModelLabel: String {
        if let id = store.defaultModel, !id.isEmpty {
            return store.availableModels.first(where: { $0.id == id })?.label ?? id
        }
        return store.availableModels.first(where: { $0.id == "default" })?.label ?? "默认"
    }

    private func launchOptionChrome(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.wand(size: 9, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text(value)
                    .font(.wand(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func launchOptionMenu<Content: View>(
        title: String,
        value: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            launchOptionChrome(title: title, value: value, icon: icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("轻点选择\(title)")
    }

    private var modelChoiceItems: [SearchableChoiceItem] {
        var items = [SearchableChoiceItem(id: "", label: "默认 · \(defaultModelLabel)")]
        items.append(contentsOf: store.availableModels.filter { $0.id != "default" }.map {
            SearchableChoiceItem(id: $0.id, label: $0.label)
        })
        return items
    }

    private var selectedModelChoiceId: String {
        guard let selected = store.selectedModel, !selected.isEmpty, selected != "default" else { return "" }
        return selected
    }

    private func modelPickerSections(for picker: ModelPickerPresentation) -> [SearchableChoiceSection] {
        var sections = [
            SearchableChoiceSection(
                id: "model",
                title: picker == .session ? "模型" : nil,
                items: modelChoiceItems,
                selectedId: selectedModelChoiceId,
                searchable: true
            )
        ]
        if picker == .session {
            sections.append(
                SearchableChoiceSection(
                    id: "thinking",
                    title: "思考深度",
                    items: thinkingLevels.map { SearchableChoiceItem(id: $0.id, label: $0.menuLabel) },
                    selectedId: store.thinkingEffort,
                    searchable: false
                )
            )
        }
        return sections
    }

    private var thinkingLevels: [ThinkingEffortOption] {
        thinkingEffortOptions(
            provider: store.snapshot?.provider ?? "claude",
            selectedModel: store.selectedModel,
            defaultModel: store.defaultModel,
            models: store.availableModels,
            providerEfforts: store.availableThinkingEfforts
        )
    }

    private var effectiveThinkingOption: ThinkingEffortOption? {
        thinkingLevels.first { $0.id == store.thinkingEffort } ?? thinkingLevels.first
    }

    private func thinkingLabel(_ id: String) -> String {
        (thinkingLevels.first { $0.id == id } ?? thinkingLevels.first)?.label ?? "自动"
    }

    private func thinkingShortLabel(_ id: String) -> String {
        (thinkingLevels.first { $0.id == id } ?? thinkingLevels.first)?.shortLabel ?? "自"
    }

    /// 顶栏身份：logo 放在标题左侧，不要再塞进 navigationBarLeading。
    /// iOS 26 圆形返回键会占掉 leading 区域，badge / 路径叠在返回键下面会变成浅色残影。
    @ViewBuilder private var providerBadge: some View {
            BrandLogo(provider: store.snapshot?.provider, color: providerTint.opacity(0.94))
                .frame(width: 18, height: 18).frame(width: 26, height: 26)
                .accessibilityLabel(store.snapshot?.providerLabel ?? "执行工具")
    }

    private var navigationStatus: some View {
        HStack(spacing: 8) {
            providerBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(navigationStatusTitle)
                    .font(.wand(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .topicTitleRhythm(store.titleGenerating)
                if let cwd = store.snapshot?.cwd, !cwd.isEmpty {
                    WandPathRevealText(path: cwd, fontSize: 10, color: Theme.textSecondary)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var navigationStatusTitle: String {
        // 会话标题由服务端统一解析并通过 title 下发。currentTaskTitle 只描述当前
        // 执行进度，不能在响应期间替换标题，否则 iOS 会和 Android 显示不同内容。
        if store.snapshot?.title?.isEmpty == false {
            return store.displayTitle
        }
        return latestUserMessage
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
    /// 会话不再 running（turn 已结束、idle/exited/archived）时也直接收起：模型经常
    /// 漏发最后一条全 completed 的 TodoWrite，否则进度条会卡在最后一项 in_progress
    /// 直到下一次发消息才被刷新，看着像「永远执行中」（对齐 Web updateTodoProgress
    /// 用 session.status 而不是 inFlight 判定，避免流式间隙闪烁）。
    private var visibleTodos: [TodoItem] {
        guard store.status == "running" else { return [] }
        let todos = TodoItem.currentTodos(in: store.messages)
        guard !todos.isEmpty else { return [] }
        let completed = todos.filter { $0.status == "completed" }.count
        return completed == todos.count ? [] : todos
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if call.active {
                VoiceCallPanel(call: call, onStopTask: {
                    call.pause("请确认是否停止当前任务")
                    showStopConfirm = true
                }).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if hasActivityPanel {
                Button {
                    composerFocus.borrow("activity", open: composerEditing)
                    showActivityPanel = true
                } label: {
                    HStack {
                        Label(store.pendingEscalation != nil || store.legacyPermissionPrompt != nil ? "等待权限确认" : "查看执行进度", systemImage: "list.bullet.rectangle")
                        Spacer()
                        if !store.queuedMessages.isEmpty { Text("待发 \(store.queuedMessages.count)") }
                        Image(systemName: "chevron.up")
                    }.font(.caption).frame(minHeight: 44).padding(.horizontal, 16)
                }.buttonStyle(.plain)
            }
            inputBar
        }
        // 手动键盘避让：观察器只返回键盘在底部安全区上方的高度。
        .padding(.bottom, keyboard.lift)
        .animation(WandMotion.disclosure, value: store.pendingEscalation)
    }

    private var hasActivityPanel: Bool {
        !visibleTodos.isEmpty || store.pendingEscalation != nil || store.legacyPermissionPrompt != nil ||
            !store.queuedMessages.isEmpty || shouldShowSubagentShelf
    }
    private var activityPanel: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
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
                        QueueBar(
                            items: store.queuedMessages,
                            expanded: $queueBarExpanded,
                            inFlight: store.queueInFlight,
                            onPromote: { store.promoteQueued(index: $0) },
                            onDelete: { store.deleteQueued(index: $0) },
                            onEdit: { store.editQueued(index: $0, text: $1) },
                            onClearAll: { store.clearQueued() }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                    if shouldShowSubagentShelf {
                        SubagentActivityShelf(
                            activities: subagentActivities,
                            isResponding: store.isResponding,
                            completedClock: completedClock,
                            baseURL: store.api.baseURL,
                            askSelections: store.displayedAskSelections,
                            onAskToggle: { toolUseId, qIdx, optIdx, multi in
                                store.toggleAskOption(
                                    toolUseId: toolUseId, questionIndex: qIdx,
                                    optionIndex: optIdx, multiSelect: multi
                                )
                            },
                            onAskSubmit: { toolUseId, answerText in
                                scrollMode = .stickToBottom
                                store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                }.padding(.vertical, 12)
            }.background(Theme.background).navigationTitle("执行进度与待办")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showActivityPanel = false } } }
        }.presentationDetents([.medium, .large])
    }

    private var composerStatus: some View {
        Text(voiceCanceling ? "松开取消" : speech.isProcessing ? "转写中…" : voicePressed && !speech.isRecording ? "等待麦克风授权…" : speech.isRecording ? "正在听 · 上滑取消" : !voiceNotice.isEmpty ? voiceNotice : store.permissionBlocked ? "等待确认" : call.phase == .speaking ? "正在朗读" : store.inputSending ? "发送中…" : store.isResponding ? "处理中" : "正在输入")
            .font(.caption).foregroundStyle(voiceCanceling ? Theme.danger : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(store.displayEmployeeName ?? "员工")的会话状态")
    }

    private var catInputExpanded: Bool {
        catComposerExpanded(editing: composerEditing, focused: inputFocused, keyboard: keyboard.isVisible,
            failed: composerDraft.submissionFailed, unconfirmed: store.unconfirmedInput != nil)
    }
    @Environment(\.dynamicTypeSize) private var composerTypeSize
    private var composerMaximumHeight: CGFloat {
        max(composerTypeSize.isAccessibilitySize ? 80 : 0, composerMaximumInputHeight(compact: verticalSizeClass == .compact, keyboardVisible: keyboard.isVisible))
    }
    private var catStatusVisible: Bool {
        store.isResponding || store.inputSending || store.permissionBlocked || call.phase == .speaking ||
            voicePressed || speech.isRecording || speech.isProcessing || !voiceNotice.isEmpty
    }
    private var inputBar: some View {
        VStack(spacing: 4) {
            if catStatusVisible { composerStatus.padding(.horizontal, 16) }
            FocusComposerSurface(expanded: catInputExpanded, hasDraft: !draft.isEmpty || !attachments.attachments.isEmpty,
                onFocus: focusComposer, editor: { composerInputContent }, add: { composerActionsMenu },
                voice: { composerVoiceButton }, send: { sendButton },
                settings: { SessionComposerSettings(store: store, focus: composerFocus) },
                primaryVisible: store.isResponding || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !attachments.attachments.isEmpty || store.inputSending)
        }
        .onChange(of: keyboard.isVisible) { old, visible in
            if old && !visible { composerFocus.keyboardHidden() }
        }
        .onChange(of: composerModalActive) { _, active in
            if active { composerFocus.borrow("modal", open: composerEditing) }
            else { composerFocus.resume("modal") }
        }
        .confirmationDialog("确定要停止当前正在运行的任务吗？", isPresented: $showStopConfirm, titleVisibility: .visible) {
            Button("停止", role: .destructive) { call.pause("任务已停止，点继续恢复通话"); store.stopResponding() }
            Button("取消", role: .cancel) {}
        }
    }
    private var composerModalActive: Bool {
        composerChoice != nil || modelPicker != nil || showDraftEditor || showDirectoryPicker ||
            attachments.showFileImporter || attachments.showPhotoPicker || serverFileLinks.previewItem != nil
    }
    private func companionFace(size: CGFloat) -> some View {
        WorkingAvatar(id: store.snapshot?.employeeId ?? sessionId, name: store.displayEmployeeName ?? "员工",
            avatar: store.displayEmployeeAvatar ?? "", activity: avatarFileActivity(messages: store.messages,
                executing: store.isResponding && store.status == "running" && !store.permissionBlocked && store.pendingEscalation == nil),
            thinking: avatarThinking, speaking: call.isSpeaking, size: size)
            .overlay { Color.clear.modifier(catVoiceGesture) }
    }
    private var catSide: CatComposerSide { CatComposerSide(rawValue: catSideRaw) ?? .left }
    private var avatarThinking: Bool {
        !store.permissionBlocked && store.pendingEscalation == nil &&
            avatarIsThinking(messages: store.messages, executing: store.isResponding && store.status == "running")
    }
    private var catVoiceGesture: CatInputGesture {
        CatInputGesture(onTap: focusComposer, onHold: startVoiceRecording,
            onMove: { voiceCanceling = $0 }, onRelease: finishVoiceRecording,
            onDrag: { catDragOffset = $0 }, onDrop: { x in
                catSideRaw = catSide.dropped(translation: x).rawValue
                catDragOffset = 0
            })
    }

    private var inputExpanded: Bool { catInputExpanded }

    private func focusComposer() {
        if call.ownsInput { call.pause("已切换到文字输入，点继续恢复通话") }
        composerAcknowledged = false
        voiceNotice = ""
        composerFocus.focus()
    }

    /// 文本框只处理系统文本编辑；语音手势由外侧独立按钮承载。
    @ViewBuilder private var composerInputContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.attachments.isEmpty {
                PendingAttachmentsPreview(
                    baseURL: api.baseURL,
                    attachments: attachments.attachments,
                    onRemove: attachments.remove,
                    onPreview: { file in composerFocus.borrow("preview", open: true); serverFileLinks.open(serverPath: file.savedPath, api: api) }
                )
            }
            if let message = composerDraft.optimizationMessage {
                Text(message).font(.caption).foregroundStyle(Theme.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if composerDraft.submissionFailed || store.unconfirmedInput != nil {
                Label(store.unconfirmedInput != nil ? "送达状态未确认，请核对会话后再发送。草稿已保留。" : (store.inputFeedbackMessage ?? "发送失败，草稿已保留。"), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            growingTextField
                .frame(height: min(composerMaximumHeight, max(inputExpanded ? 32 : 34, composerInputHeight)))
                .padding(.leading, inputExpanded ? 6 : 2)
                .padding(.trailing, inputExpanded ? 4 : 0)
                .padding(.vertical, inputExpanded ? 4 : 2)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerVoiceButton: some View {
        Image(systemName: voicePressed ? "waveform" : "mic")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(voiceCanceling ? Theme.danger : (voicePressed ? Theme.brand : Theme.textSecondary))
            .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
            .background(Circle().fill(Theme.surface.opacity(0.92)))
            .overlay(Circle().stroke(Theme.border.opacity(0.5), lineWidth: 0.8))
            .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
            .contentShape(Circle())
            .modifier(CatInputGesture(onTap: focusComposer, onHold: startVoiceRecording,
                onMove: { voiceCanceling = $0 }, onRelease: finishVoiceRecording))
            .accessibilityLabel("语音输入")
            .accessibilityValue(voicePressed ? "正在录音" : "长按录音")
    }

    private var sendButton: some View {
        NativeComposerActionButton(
            phase: store.isResponding ? .idle : store.inputSending ? .sending : .idle,
            turnRunning: store.isResponding,
            hasDraft: !store.isResponding,
            canSubmit: canSend,
            // The expanded editor owns the full failure message; keep the capsule icon-only.
            message: nil,
            onSend: sendDraft,
            onStop: { showStopConfirm = true }
        )
    }

    // MARK: - 控制行徽标（模式 / 模型·思考）

    /// 执行模式选项（与 NewSessionView.sessionModes 一致）。Codex 锁 full-access；
    /// OpenCode 仅支持 default / full-access / managed。
    private static let sessionModes = [
        (id: "managed", label: "托管"),
        (id: "full-access", label: "全权限"),
        (id: "auto-edit", label: "自动编辑"),
        (id: "default", label: "标准"),
        (id: "native", label: "原生"),
    ]

    private static func modeLabel(_ id: String) -> String {
        sessionModes.first { $0.id == id }?.label ?? "标准"
    }

    private var modelThinkingText: String {
        let model = shortModelLabel
        return "\(model) · \(thinkingShortLabel(store.thinkingEffort))"
    }

    /// 控制行徽标用的精简模型名：去掉「opus（最新 Opus）」这类括号补充（全角/半角都吃），只留主名。
    private var shortModelLabel: String {
        let full = launchModelLabel
        if full == "跟随服务端默认" || full == "默认" { return "默认" }
        if let idx = full.firstIndex(where: { $0 == "（" || $0 == "(" }) {
            return abbreviatedModelLabel(String(full[..<idx]).trimmingCharacters(in: .whitespaces))
        }
        return abbreviatedModelLabel(full)
    }

    private func abbreviatedModelLabel(_ value: String) -> String {
        let clean = value.split(separator: "/").last.map(String.init) ?? value
        let lower = clean.lowercased()
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        if lower.contains("gpt-5.5") { return "GPT-5.5" }
        if lower.contains("gpt-5") { return "GPT-5" }
        if lower.contains("gpt-4") { return "GPT-4" }
        return clean.count > 12 ? String(clean.prefix(10)) + "…" : clean
    }

    private func refreshGitStatus() {
        Task {
            gitStatus = try? await api.gitStatus(sessionId: sessionId)
        }
    }

    private func beginQuickCommitFeedback() {
        quickCommitFeedback.begin()
    }

    private func completeQuickCommitFeedback(_ message: String) {
        store.toast = message
        quickCommitFeedback.complete(onReset: refreshGitStatus)
    }

    private func failQuickCommitFeedback(_ message: String) {
        quickCommitFeedback.fail()
        store.toast = message
        refreshGitStatus()
    }

    private var composerActionsMenu: some View {
        Button {
            composerChoice = .attachments
        } label: {
            if attachments.isUploading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                    .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
            } else {
                // 卡片内的「+」走极简：无圆底描边，仅图标（对齐 Codex）。
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
                    .contentShape(Rectangle())
            }
        }
        .disabled(attachments.isUploading)
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .accessibilityLabel("添加附件")
        .accessibilityHint("轻点从相册或文件选择")
    }

    /// 多行自增高输入框。走 UIKit marked-text，避免中文输入法组字被 SwiftUI Binding 打断。
    private var growingTextField: some View {
        IMEAwareComposerTextView(
            text: $composerDraft.text,
            placeholder: composerPlaceholder,
            isFocused: inputFocused,
            maximumHeight: composerMaximumHeight,
            submitOnReturn: false,
            onPasteImages: { items in
                attachments.handlePastedImageData(items)
            },
            onFocusChange: {
                inputFocused = $0
                if $0 && call.ownsInput { call.pause("已切换到文字输入，点继续恢复通话") }
            },
            onCompositionChange: { composerIsComposing = $0 },
            onSubmit: sendDraft,
            onHeightChange: { height in
                composerInputHeight = height
                draftNeedsExpanded = !draft.isEmpty && height > 36
            }
        )
        .wandSubmitOnHardwareReturn(isEnabled: { keyboardShortcutsActive && canSend }, perform: sendDraft)
    }

    private var composerPlaceholder: String {
        if voicePressed {
            return voiceCanceling ? "松开手指，取消输入" : "松开结束 · 上滑取消"
        }
        return "输入消息，回车换行"
    }

    private var canSend: Bool {
        // 结构化会话不存在「已结束」终止态：停止只回到 idle，真失败也能再发消息触发
        // 服务端 --resume 续接。所以发送只看草稿是否非空，不再被 sessionEnded 卡死。
        // 组字未确认时不能发，否则会把拼音半成品送出去，或把候选确认键当成发送。
        !voicePressed && !speech.isRecording && !speech.isProcessing && !store.inputSending && !store.providerSwitching && !composerDraft.isOptimizing && !attachments.isUploading && composerDraftIsSendable(
            draft,
            hasAttachments: !attachments.attachments.isEmpty,
            isComposing: composerIsComposing
        )
    }

    private func sendDraft() {
        guard canSend else { return }
        let submission = composerDraft.submission()
        let started = store.send(text: submission.prompt, onAccepted: {
            composerDraft.accepted(submission)
            if draft.isEmpty && attachments.attachments.isEmpty && !composerIsComposing {
                composerAcknowledged = true
                composerEditing = false
                inputFocused = false
            }
        }, onFailure: {
            composerDraft.rejected(submission)
            composerAcknowledged = false
            composerEditing = true
        })
        guard started else { return }
        composerDraft.submitted(submission)
        scrollMode = .stickToBottom
        // 清空 draft 后，权限卡/todo bar 的插入移除可能让输入框丢焦点。
        // 发送后主动保持焦点，方便连续输入。
        inputFocused = true
    }

    // MARK: - 按住说话（端侧语音识别）

    private func finishVoiceRecording(cancelled: Bool) {
        let revision = voiceDraftRevision, lifecycle = voiceDraftLifecycle
        voicePressed = false; voiceCanceling = false
        speech.stop(cancelled: cancelled) { text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if composerDraft.textRevision == revision && composerDraft.lifecycleRevision == lifecycle { voiceNotice = "没有听到声音，请再试一次" }
                return
            }
            let before = composerDraft.textRevision
            composerDraft.appendVoice(text, ifUnchangedSince: revision, lifecycle: lifecycle)
            if composerDraft.textRevision != before { focusComposer() }
        }
        if cancelled { voiceNotice = "已取消，草稿保留" }
        if !speech.isProcessing { composerFocus.resume("voice") }
    }

    /// 按满阈值进入录音态（原「按下立即录音」交互的主体）。
    private func startVoiceRecording() {
        guard !voicePressed, !speech.isProcessing, !store.inputSending, !store.providerSwitching, !composerDraft.isOptimizing, !attachments.isUploading else { return }
        if call.ownsInput { call.pause("已切换到按住说话，点继续恢复通话") }
        composerFocus.borrow("voice", open: composerEditing)
        voiceDraftRevision = composerDraft.textRevision
        voiceDraftLifecycle = composerDraft.lifecycleRevision
        voicePressed = true
        voiceCanceling = false
        voiceNotice = ""
        inputFocused = false
        speech.start(api: api) { message in
            voiceNotice = message
            store.toast = message
            voicePressed = false
            voiceCanceling = false
            composerFocus.resume("voice")
        }
    }

    // MARK: - Toast

    @ViewBuilder private var toastView: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.wand(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.82)))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + wandNoticeDuration(toast)) {
                        if store.toast == toast { store.toast = nil }
                    }
                }
        }
    }

    private func composerChoiceSheet(_ choice: ComposerChoicePresentation) -> some View {
        switch choice {
        case .mode:
            SearchableChoiceSheet(
                title: "执行模式",
                sections: [
                    SearchableChoiceSection(
                        id: "mode",
                        items: Self.sessionModes
                            .filter { currentProvider.supportedModeIDs.contains($0.id) }
                            .map { SearchableChoiceItem(id: $0.id, label: $0.label) },
                        selectedId: store.mode
                    )
                ]
            ) { _, itemId in
                store.setMode(itemId)
            }
        case .context:
            SearchableChoiceSheet(title: "会话上下文", sections: [
                SearchableChoiceSection(id: "context", items: [
                    SearchableChoiceItem(id: "model", label: "模型与思考 · \(modelThinkingText)"),
                    SearchableChoiceItem(id: "mode", label: "执行模式 · \(Self.modeLabel(store.mode))"),
                    SearchableChoiceItem(id: "directory", label: "目录 · \(store.snapshot?.cwd ?? "未选择")"),
                    SearchableChoiceItem(id: "optimize", label: "优化提示词"),
                    SearchableChoiceItem(id: "editor", label: "展开编辑长消息"),
                    SearchableChoiceItem(id: "call", label: "持续语音通话（自动发送与播报）")
                ], selectedId: "")
            ]) { _, itemId in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    switch itemId {
                    case "model": modelPicker = .session
                    case "mode":
                        if currentProvider == .codex { store.toast = "Codex 会话的执行模式固定" }
                        else { composerChoice = .mode }
                    case "directory":
                        if store.canChangeDirectory { showDirectoryPicker = true }
                        else { store.toast = "当前会话目录固定；更换目录请创建新会话" }
                    case "editor": showDraftEditor = true
                    case "optimize":
                        guard !composerDraft.isOptimizing, !store.inputSending, !attachments.isUploading,
                              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            store.toast = "请输入提示词，等待当前上传或发送完成后再优化"; return
                        }
                        composerDraft.optimize { text in try await api.optimizePrompt(id: sessionId, prompt: text) }
                    case "call": showCallTarget = true
                    default: break
                    }
                }
            }
        case .attachments:
            SearchableChoiceSheet(
                title: "添加附件",
                sections: [
                    SearchableChoiceSection(
                        id: "attach",
                        items: [
                            SearchableChoiceItem(id: "photo", label: "从相册选择"),
                            SearchableChoiceItem(id: "file", label: "从文件选择"),
                        ],
                        selectedId: ""
                    )
                ]
            ) { _, itemId in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if itemId == "photo" {
                        attachments.showPhotoPicker = true
                    } else {
                        attachments.showFileImporter = true
                    }
                }
            }
        }
    }

    private func scrubberScrollID(for localIndex: Int) -> String {
        let absolute = absoluteTurnIndex(localIndex: localIndex, loadedOffset: store.loadedOffset)
        guard store.messages.indices.contains(localIndex), store.messages[localIndex].role != "user" else {
            return "turn:\(absolute)"
        }
        return "assistant-header:\(absolute)"
    }
}

/// scrollDismissesKeyboard 在消息列表拖动时立即收起键盘。
/// 用 .immediately 而非 .interactively：手动键盘避让（KeyboardObserver）依赖
/// 键盘 frame 通知，而交互式拖拽过程中 UIKit 不发通知，输入栏会悬空脱节；
/// 立即收起则输入栏随 willHide 同步落下。
private struct DismissKeyboardOnDrag: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.scrollDismissesKeyboard(.immediately)
    }
}

// MARK: - 单条消息

/// 工具调用与结果在渲染层配成一张卡片（对齐 Web 端 buildToolResultMap / Android pairToolBlocks）。
enum DisplayItem {
    case plain(ContentBlock)
    case tool(
        id: String, name: String, description: String?,
        input: [String: JSONValue], subagent: SubagentMeta?,
        result: ToolResultInfo?
    )
}

private enum MessageDisplayItem {
    case turn(index: Int, ConversationTurn)
    /// assistant turn 的统一展开/收起入口；正文仍保持块级懒加载。
    case assistantHeader(turnIndex: Int, preview: String)
    /// 摊平后的单个 assistant 内容块（见 flattenAssistantTurns / AssistantItemView）。
    case assistantItem(turnIndex: Int, item: DisplayItem)
    case explorationGroup(tools: [ExplorationToolItem], lastTurnIndex: Int)
    case activityGroup(turnIndex: Int, group: ActivityGroup, id: String)
    /// 当前 assistant turn 的 token / cost 摘要。
    case usageSummary(turnIndex: Int, usage: TurnUsage?, isLive: Bool)
    case resourceSelection(turnIndex: Int, notice: ResourceSelectionNotice)
    /// 历史折叠摘要卡：折叠"最后一条用户消息"之前的全部历史，boundary = 该用户消息下标。
    case historySummary(stats: HistoryStats, boundary: Int)
}

/// LazyVStack/ForEach 不能用当前数组 offset 当身份：历史 prepend 会让所有
/// offset 平移，流式重分组也会改变位置，从而把上一张工具卡的 @State
/// 复用给下一张。这里用绝对 turn 位置 + toolUseId/语义 key 生成稳定身份。
private struct IdentifiedMessageDisplayItem: Identifiable {
    let id: String
    let item: MessageDisplayItem
}

private struct IdentifiedDisplayItem: Identifiable {
    let id: String
    let item: DisplayItem
}

private struct IdentifiedExplorationTool: Identifiable {
    let id: String
    let item: ExplorationToolItem
}

private func identifiedMessageItems(
    _ items: [MessageDisplayItem],
    turnOffset: Int
) -> [IdentifiedMessageDisplayItem] {
    identified(items, baseID: { messageDisplayIdentity($0, turnOffset: turnOffset) })
        .map { IdentifiedMessageDisplayItem(id: $0.id, item: $0.value) }
}

private func identifiedDisplayItems(_ items: [DisplayItem]) -> [IdentifiedDisplayItem] {
    identified(items, baseID: displayItemIdentity)
        .map { IdentifiedDisplayItem(id: $0.id, item: $0.value) }
}

private func identifiedExplorationTools(_ items: [ExplorationToolItem]) -> [IdentifiedExplorationTool] {
    identified(items) { tool in
        let key = !tool.id.isEmpty ? tool.id : (tool.result?.toolUseId ?? "")
        return key.isEmpty ? "tool:\(tool.name)" : "tool:\(key)"
    }
    .map { IdentifiedExplorationTool(id: $0.id, item: $0.value) }
}

private func identified<Value>(
    _ values: [Value],
    baseID: (Value) -> String
) -> [(id: String, value: Value)] {
    var occurrences: [String: Int] = [:]
    return values.map { value in
        let base = baseID(value)
        let occurrence = occurrences[base, default: 0]
        occurrences[base] = occurrence + 1
        return (occurrence == 0 ? base : "\(base)#\(occurrence)", value)
    }
}

private func messageDisplayIdentity(_ item: MessageDisplayItem, turnOffset: Int) -> String {
    let absoluteTurn = absoluteTurnIndex(localIndex: itemTurnIndex(item), loadedOffset: turnOffset)
    switch item {
    case .turn:
        return "turn:\(absoluteTurn)"
    case .assistantHeader:
        return "assistant-header:\(absoluteTurn)"
    case .assistantItem(_, let displayItem):
        return "assistant:\(absoluteTurn):\(displayItemIdentity(displayItem))"
    case .explorationGroup(let tools, _):
        let first = tools.first.map { !$0.id.isEmpty ? $0.id : ($0.result?.toolUseId ?? $0.name) } ?? "empty"
        return "exploration:\(first)"
    case .activityGroup(_, let group, _):
        return "activity:\(absoluteTurn):\(group.items.first.map(displayItemIdentity) ?? "empty")"
    case .resourceSelection:
        return "resources:\(absoluteTurn)"
    case .usageSummary:
        return "usage:\(absoluteTurn)"
    case .historySummary:
        return "history-summary:\(absoluteTurn)"
    }
}

func absoluteTurnIndex(localIndex: Int, loadedOffset: Int) -> Int {
    loadedOffset + localIndex
}

func historySummaryAnchorID(localBoundary: Int, loadedOffset: Int) -> String {
    "history-summary-\(absoluteTurnIndex(localIndex: localBoundary, loadedOffset: loadedOffset))"
}

func displayItemIdentity(_ item: DisplayItem) -> String {
    switch item {
    case .tool(let id, let name, _, _, _, let result):
        let key = !id.isEmpty ? id : (result?.toolUseId ?? "")
        return key.isEmpty ? "tool:\(name)" : "tool:\(key)"
    case .plain(let block):
        switch block {
        case .toolUse(let id, let name, _, _, _):
            return id.isEmpty ? "tool-use:\(name)" : "tool-use:\(id)"
        case .toolResult(let id, _, _, _, _, _, _):
            return id.isEmpty ? "tool-result" : "tool-result:\(id)"
        case .text:
            return "text"
        case .thinking:
            return "thinking"
        case .unknown(let type, _):
            return "unknown:\(type)"
        }
    }
}

struct ActivityGroup {
    let latest: String
    let meta: String
    let count: Int
    let items: [DisplayItem]
    /// 这条回复里最新的一段活动：默认展开，更早的段默认收起成状态条。
    var newest = false
}

/// 被折叠历史区间的统计：轮次 / 工具调用 / 子代理 / 失败。
struct HistoryStats {
    let rounds: Int
    let tools: Int
    let agents: Int
    let errors: Int
}

/// 自动历史分页只在顶部哨兵可见、用户正在手动浏览且当前没有请求时触发。
/// 这样初次进入页面的贴底布局不会误加载，也不会在一次到顶后并发翻多页。
func shouldAutoLoadEarlierMessages(
    isTopSentinelVisible: Bool,
    isBrowsingHistory: Bool,
    canLoadEarlier: Bool,
    loadingEarlier: Bool
) -> Bool {
    isTopSentinelVisible && isBrowsingHistory && canLoadEarlier && !loadingEarlier
}

/// 取出一个 MessageDisplayItem 归属的 turn 下标，用于按历史边界分区。
private func itemTurnIndex(_ item: MessageDisplayItem) -> Int {
    switch item {
    case .turn(let i, _): return i
    case .assistantHeader(let i, _): return i
    case .assistantItem(let i, _): return i
    case .explorationGroup(_, let i): return i
    case .activityGroup(let i, _, _): return i
    case .resourceSelection(let i, _): return i
    case .usageSummary(let i, _, _): return i
    case .historySummary(_, let b): return b
    }
}

/// 统计被折叠历史区间（turns[0..<boundary]）里的轮次 / 工具 / 子代理 / 失败数量。
func computeHistoryStats(turns: [ConversationTurn], boundary: Int) -> HistoryStats {
    var rounds = 0, tools = 0, errors = 0
    var agentIds = Set<String>()
    let upper = min(boundary, turns.count)
    guard upper > 0 else { return HistoryStats(rounds: 0, tools: 0, agents: 0, errors: 0) }
    for idx in 0..<upper {
        let turn = turns[idx]
        if turn.role == "user" { rounds += 1 }
        for block in turn.content {
            switch block {
            case .toolUse(let id, let name, _, let input, let subagent):
                tools += 1
                if let tid = subagent?.taskId, !tid.isEmpty {
                    agentIds.insert(tid)
                } else if name == "Task" || name == "Agent"
                    || (input["subagent_type"]?.stringValue?.isEmpty == false) {
                    if !id.isEmpty { agentIds.insert(id) }
                }
            case .toolResult(_, _, let isError, _, _, let subagent, _):
                if isError { errors += 1 }
                if let tid = subagent?.taskId, !tid.isEmpty { agentIds.insert(tid) }
            case .text(_, let subagent), .thinking(_, let subagent, _, _):
                if let tid = subagent?.taskId, !tid.isEmpty { agentIds.insert(tid) }
            case .unknown:
                break
            }
        }
    }
    return HistoryStats(rounds: rounds, tools: tools, agents: agentIds.count, errors: errors)
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
        if turn.resourceSelection == nil, let tools = explorationToolsOnly(in: turn) {
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

/// 把 assistant turn 摊平成「每个内容块一行」，使顶层 LazyVStack 能按需实例化。
/// user turn 保持整条一行（一个气泡，无性能问题）；探索分组本就是单行卡片。
/// 历史问题：一条 assistant turn 可携带上百个 text/工具/diff 块，整条作为单行
/// 由 LazyVStack 渲染时单行高度过大，滚到底部后视口落在空白区、该懒加载行迟迟不绘制
/// （表现为打开会话白屏，主线程并不忙、CPU 为 0）；摊平成多行后按行懒加载即可。
private func flattenAssistantTurns(
    _ items: [MessageDisplayItem],
    liveTurnIndex: Int? = nil
) -> [MessageDisplayItem] {
    var out: [MessageDisplayItem] = []
    for item in items {
        if case .turn(let index, let turn) = item, turn.role == "assistant" {
            if let notice = turn.resourceSelection { out.append(.resourceSelection(turnIndex: index, notice: notice)) }
            let parentBlocks = parentTranscriptBlocks(turn.content)
            if !parentBlocks.isEmpty {
                out.append(.assistantHeader(
                    turnIndex: index,
                    preview: assistantReplyPreview(parentBlocks)
                ))
                for displayItem in pairToolBlocks(parentBlocks) {
                    out.append(.assistantItem(turnIndex: index, item: displayItem))
                }
            }
            let usageIsLive = index == liveTurnIndex
            // 流式用量与「正在思考」合并到底部 LiveTurnStatusRow；结束后再把
            // 完整用量作为回复尾部的一行保留下来。
            if !usageIsLive, turn.usage?.hasVisibleValue == true {
                out.append(.usageSummary(turnIndex: index, usage: turn.usage, isLive: false))
            }
        } else {
            out.append(item)
        }
    }
    return out
}

private func collapseActivityItems(
    _ items: [MessageDisplayItem],
    latestTurnIndex: Int,
    running: Bool = false
) -> [MessageDisplayItem] {
    var out: [MessageDisplayItem] = []
    var pending: [(turnIndex: Int, item: DisplayItem)] = []
    var groupOrdinal = 0

    func flushPending() {
        guard !pending.isEmpty else { return }
        let turnIndex = pending.last?.turnIndex ?? -1
        let displayItems = pending.map(\.item)
        let summary = summarizeActivityItems(displayItems)
        if summary.count > 0 || (running && turnIndex == latestTurnIndex) {
            out.append(.activityGroup(
                turnIndex: turnIndex,
                group: ActivityGroup(
                    latest: summary.latest,
                    meta: summary.meta,
                    count: summary.count,
                    items: displayItems
                ),
                id: "activity-\(turnIndex)-\(groupOrdinal)"
            ))
            groupOrdinal += 1
        }
        pending.removeAll(keepingCapacity: true)
    }

    for (position, item) in items.enumerated() {
        if case .assistantItem(let turnIndex, let displayItem) = item {
            let keepLiveThinking = running && turnIndex == latestTurnIndex && position == items.count - 1 && {
                if case .plain(.thinking) = displayItem { return true }; return false
            }()
            if shouldSkipActivityItem(displayItem) && !keepLiveThinking {
                continue
            }
            if isCollapsibleActivityItem(displayItem) {
                if let previousTurn = pending.last?.turnIndex, previousTurn != turnIndex {
                    flushPending()
                }
                pending.append((turnIndex, displayItem))
            } else {
                flushPending()
                out.append(item)
            }
        } else {
            flushPending()
            out.append(item)
        }
    }
    flushPending()
    // 本轮最后一段活动标记成「最新」：默认展开；末尾还在跑时同时标记运行态。
    if case .activityGroup(let turnIndex, let group, let id) = out.last,
       turnIndex == latestTurnIndex {
        out[out.count - 1] = .activityGroup(
            turnIndex: turnIndex,
            group: ActivityGroup(
                latest: group.latest,
                meta: group.meta,
                count: group.count,
                items: group.items,
                newest: true
            ),
            id: id
        )
    }
    return out
}

private func shouldSkipActivityItem(_ item: DisplayItem) -> Bool {
    if case .plain(.thinking(let text, _, _, _)) = item {
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard case .tool(let id, _, _, _, let subagent, _) = item else { return false }
    return isSubagentDispatchBlock(id: id, subagent: subagent)
}

/// 派发块判据：服务端 `__subagent` 盖章是唯一来源——Claude 的 Task/Agent 与 pi 的
/// `subagent`（agent+task / tasks / chain / workflow 脚本 / resume / mission 各形态）
/// 都会盖章。旧代码另外按工具名和 `subagent_type` 判，pi 的 workflow 派发名字是
/// `Pi/subagent`、又没有 `subagent_type`，于是被漏掉：同一块既进正文活动轨迹又进
/// 子 Agent 状态坞，重复显示。
///
/// 块 id 与 taskId 相同 = 派发调用本身；子 Agent 内部的普通调用（Read/Bash…）共享
/// 同一份 meta 但 id 不同，仍按普通活动轨迹处理。
func isSubagentDispatchBlock(id: String, subagent: SubagentMeta?) -> Bool {
    guard let taskId = subagent?.taskId, !taskId.isEmpty else { return false }
    return !id.isEmpty && taskId == id
}

private func isCollapsibleActivityItem(_ item: DisplayItem) -> Bool {
    switch item {
    case .plain(let block):
        switch block {
        case .text, .unknown, .toolUse: return false
        case .thinking: return true
        case .toolResult(_, _, _, _, let images, _, let projection):
            return images.isEmpty && projection?.isDecision != true
        }
    case .tool(_, let name, _, let input, _, let result):
        return isCollapsibleActivityTool(name: name, input: input,
                                         resultImages: result?.images ?? [], projection: result?.projection)
    }
}

func isCollapsibleActivityTool(name: String, input: [String: JSONValue],
                               resultImages: [String] = [], projection: ToolProjection? = nil) -> Bool {
    if isDecisionTool(input: input) || projection?.isDecision == true { return false }
    if !AskUserQuestion.parse(input: input).isEmpty || name == "AskUserQuestion" { return false }
    if name == "Task" || name == "Agent" || input["subagent_type"]?.stringValue?.isEmpty == false { return false }
    if !resultImages.isEmpty || isReadImageTool(name: name, input: input) { return false }
    let lower = name.lowercased()
    if lower.contains("imagegen") || lower.contains("view_image") { return false }
    if ["spawn_agent", "send_message", "wait_agent", "resume_agent", "close_agent"].contains(where: { lower.hasSuffix($0) }) { return false }
    return true
}

private struct ActivityRunSummary {
    let latest: String
    let meta: String
    let count: Int
}

private let activityKindMeta: [(String, String)] = [
    ("read", "浏览"),
    ("command", "命令"),
    ("search", "搜索"),
    ("edit", "编辑"),
    ("web", "网页"),
    ("other", "调用"),
    ("thinking", "思考"),
]

private func summarizeActivityItems(_ items: [DisplayItem]) -> ActivityRunSummary {
    var counts: [String: Int] = [:]
    var latest = ""
    var count = 0

    func addTool(name: String, input: [String: JSONValue]) {
        let kind = activityKindOf(name)
        counts[kind, default: 0] += 1
        let label = activityToolLabel(name: name, input: input)
        if !label.isEmpty { latest = label }
        count += 1
    }

    for item in items {
        switch item {
        case .plain(.thinking(let thinking, _, _, _)):
            let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            counts["thinking", default: 0] += 1
            latest = activityThinkingLabel(thinking)
            count += 1
        case .tool(_, let name, _, let input, _, _):
            addTool(name: name, input: input)
        default:
            break
        }
    }
    let meta = activityKindMeta.compactMap { kind, label in
        guard let value = counts[kind], value > 0 else { return nil }
        return "\(label) \(value)"
    }.joined(separator: " · ")
    return ActivityRunSummary(
        latest: latest.isEmpty ? "处理中" : latest,
        meta: meta,
        count: count
    )
}

private func compactInline(_ value: String) -> String {
    value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func truncateInline(_ value: String, max: Int) -> String {
    let text = compactInline(value)
    if text.isEmpty { return "" }
    return text.count > max ? String(text.prefix(max - 1)) + "…" : text
}

private func tailInline(_ value: String, max: Int) -> String {
    let text = compactInline(value)
    if text.isEmpty { return "" }
    return text.count > max ? "…" + String(text.suffix(max - 1)) : text
}

private func fileNameOf(_ path: String) -> String {
    if let idx = path.lastIndex(of: "/") {
        return String(path[path.index(after: idx)...])
    }
    return path
}

private func activityThinkingLabel(_ thinking: String) -> String {
    let text = tailInline(thinking, max: 240)
    return text.isEmpty ? "深度思考" : text
}

func activityToolLabel(name: String, input: [String: JSONValue]) -> String {
    let command = input["command"]?.stringValue ?? input["cmd"]?.stringValue ?? ""
    let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? ""
    let query = input["pattern"]?.stringValue ?? input["query"]?.stringValue ?? ""
    let url = input["url"]?.stringValue ?? ""
    switch name {
    case "Bash":
        return command.isEmpty ? "运行命令" : "运行 \(truncateInline(command, max: 240))"
    case "Read":
        return path.isEmpty ? "读取文件" : "读取 \(truncateInline(path, max: 240))"
    case "Grep", "Glob", "WebSearch":
        return query.isEmpty ? "搜索" : "搜索 \(truncateInline(query, max: 240))"
    case "WebFetch":
        return url.isEmpty ? "抓取网页" : "抓取 \(truncateInline(url, max: 240))"
    case "Edit", "MultiEdit":
        return "修改 \(path.isEmpty ? "文件" : truncateInline(path, max: 240))"
    case "Write":
        return "写入 \(path.isEmpty ? "文件" : truncateInline(path, max: 240))"
    default:
        return toolLabel(name)
    }
}

private func activityKindOf(_ name: String) -> String {
    let lower = name.lowercased()
    if ["read", "inspect", "view", "open", "list", "load"].contains(where: { lower.contains($0) }) { return "read" }
    if ["bash", "exec", "command", "shell", "stdin", "terminal"].contains(where: { lower.contains($0) }) { return "command" }
    if ["grep", "glob", "search", "find", "query", "lookup"].contains(where: { lower.contains($0) }) { return "search" }
    if ["edit", "write", "patch", "replace", "notebook"].contains(where: { lower.contains($0) }) { return "edit" }
    if ["web", "fetch", "http", "url", "browser"].contains(where: { lower.contains($0) }) { return "web" }
    return "other"
}

private func activityTools(_ items: [DisplayItem]) -> [ExplorationToolItem] {
    items.flatMap { item -> [ExplorationToolItem] in
        switch item {
        case .tool(let id, let name, let description, let input, let subagent, let result):
            return [ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            )]
        case .plain:
            return []
        }
    }
}

private func activitySummary(_ items: [DisplayItem], running: Bool) -> String {
    let tools = activityTools(items)
    if items.count == 1, let tool = tools.first, tools.count == 1 {
        let prefix = running && tool.result == nil ? "正在" : "已"
        let label = activityVerb(tool.name)
        let detail = activityToolSummary(description: tool.description, input: tool.input)
        return detail.isEmpty ? "\(prefix)\(label)" : "\(prefix)\(label) \(detail)"
    }
    if items.count == 1, case .plain(let block) = items[0] {
        switch block {
        case .thinking:
            return running ? "正在思考" : "已思考"
        case .toolResult(_, _, let isError, _, _, _, _):
            return isError ? "有 1 条执行错误" : "已生成 1 条执行结果"
        default:
            return "已完成 1 项活动"
        }
    }

    var read = 0, command = 0, search = 0, edit = 0, web = 0, todo = 0, other = 0
    for tool in tools {
        switch activityKind(tool.name) {
        case "read": read += 1
        case "command": command += 1
        case "search": search += 1
        case "edit": edit += 1
        case "web": web += 1
        case "todo": todo += 1
        default: other += 1
        }
    }
    let thinking = items.filter {
        if case .plain(.thinking) = $0 { return true }
        return false
    }.count
    let result = items.filter {
        if case .plain(.toolResult) = $0 { return true }
        return false
    }.count

    var parts: [String] = []
    if read > 0 { parts.append("浏览 \(read) 个文件") }
    if command > 0 { parts.append("运行 \(command) 条命令") }
    if search > 0 { parts.append("搜索 \(search) 次") }
    if edit > 0 { parts.append("修改 \(edit) 个文件") }
    if web > 0 { parts.append("访问 \(web) 个网页") }
    if todo > 0 { parts.append("更新 \(todo) 次待办") }
    if thinking > 0 { parts.append("思考 \(thinking) 段") }
    if result > 0 { parts.append("生成 \(result) 条结果") }
    if other > 0 { parts.append("调用 \(other) 个工具") }

    let prefix = running ? "正在" : "已"
    return parts.isEmpty ? "\(prefix)完成 \(items.count) 项活动" : prefix + parts.joined(separator: "，")
}

private func activityVerb(_ name: String) -> String {
    switch activityKind(name) {
    case "read": return "浏览"
    case "command": return "运行"
    case "search": return "搜索代码"
    case "edit": return "修改"
    case "web": return "访问网页"
    case "todo": return "更新待办"
    default: return toolLabel(name)
    }
}

private func activityKind(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.hasPrefix("read") || lower.contains("notebook") { return "read" }
    if lower == "bash" || lower.contains("command") || lower.contains("shell") { return "command" }
    if lower.contains("grep") || lower.contains("glob") || lower.contains("search") || lower.contains("find") {
        return "search"
    }
    if lower.contains("edit") || lower.contains("write") { return "edit" }
    if lower.contains("web") || lower.contains("fetch") || lower.contains("http") { return "web" }
    if lower.contains("todo") { return "todo" }
    return "other"
}

func activityToolSummary(description: String?, input: [String: JSONValue]) -> String {
    if let description, !description.isEmpty { return description }
    for key in ["command", "file_path", "path", "pattern", "query", "url", "prompt", "description"] {
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

private func explorationToolsOnly(in turn: ConversationTurn) -> [ExplorationToolItem]? {
    guard turn.role == "assistant" else { return nil }
    var tools: [ExplorationToolItem] = []
    for item in pairToolBlocks(parentTranscriptBlocks(turn.content)) {
        switch item {
        case .tool(let id, let name, let description, let input, let subagent, let result)
            where isGroupableExplorationTool(name: name, input: input)
                && isCollapsibleActivityTool(name: name, input: input,
                    resultImages: result?.images ?? [], projection: result?.projection):
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
    let toolUseId: String
    let text: String
    let isError: Bool
    let truncated: Bool
    /// 结果内联图片（站内取图 URL 或 data URI）；服务端已归一化。
    var images: [String] = []
    var projection: ToolProjection? = nil
}

private func toolResultMetadataToken(_ result: ToolResultInfo?) -> Int {
    guard let result else { return 0 }
    var token = Hasher()
    token.combine(result.toolUseId)
    token.combine(result.text)
    token.combine(result.truncated)
    token.combine(result.isError)
    token.combine(result.images)
    token.combine(result.projection?.preview)
    token.combine(result.projection?.semantic?.kind)
    token.combine(result.projection?.decisionLabel)
    token.combine(result.projection?.semantic?.summary?.outcome)
    return token.finalize()
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
                if case .toolResult(let rid, _, _, _, _, _, _) = content[j], rid == id {
                    resultIndex = j
                    break
                }
            }
        }
        if resultIndex < 0 {
            // 2) 邻接兜底：中间隔着下一个 ToolUse 视为无结果；id 双方都有但不匹配时不抢配。
            for j in (i + 1)..<content.count where !consumed.contains(j) {
                if case .toolUse = content[j] { break }
                if case .toolResult(let rid, _, _, _, _, _, _) = content[j] {
                    if rid.isEmpty || id.isEmpty { resultIndex = j }
                    break
                }
            }
        }
        var result: ToolResultInfo?
        if resultIndex >= 0, case .toolResult(let resultID, let text, let isError, let truncated, let images, _, let projection) = content[resultIndex] {
            consumed.insert(resultIndex)
            result = ToolResultInfo(
                toolUseId: resultID.isEmpty ? id : resultID,
                text: text,
                isError: isError,
                truncated: truncated,
                images: images,
                projection: projection
            )
        }
        paired.append(.tool(
            id: id, name: name, description: description,
            input: input, subagent: subagent, result: result
        ))
    }
    return paired
}

private func isExplorationTool(_ name: String) -> Bool {
    let lower = name.lowercased()
    let operation = lower.components(separatedBy: "__").last ?? lower
    return operation.hasPrefix("read")
        || operation.hasPrefix("grep")
        || operation.hasPrefix("glob")
        || operation.hasPrefix("search")
        || operation.hasPrefix("find")
        || lower == "tool_search"
        || lower.contains("websearch")
        || lower.contains("webfetch")
        || lower == "todoread"
}

/// Read 工具读到的是图片：这种工具卡要单独显示（内联缩略图常驻），
/// 不并进探索分组（对齐 Web chat-render.ts 把 Read 读图从分组里排除）。
private func isReadImageTool(name: String, input: [String: JSONValue]) -> Bool {
    guard name == "Read" else { return false }
    let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue
    return isImagePath(path)
}

/// 探索判定：是探索工具，且不是 Read 读图（后者要单独显示缩略图）。
private func isGroupableExplorationTool(name: String, input: [String: JSONValue]) -> Bool {
    isExplorationTool(name) && !isReadImageTool(name: name, input: input)
}

private let compactUserMinChars = 72

func shouldCompactUserBody(_ text: String) -> Bool {
    text.count > compactUserMinChars
        || text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
            .count > 2
}

func conversationTurnPreview(_ turn: ConversationTurn) -> String {
    let rawText = turn.content.compactMap { block -> String? in
        if case .text(let text, _) = block { return text }
        return nil
    }.joined(separator: " ")
    if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if turn.role == "user" {
            let parsed = parseUserAttachmentMessage(rawText)
            let body = compactReplyPreviewText(parsed.body)
            if !body.isEmpty { return body }
            if !parsed.attachmentPaths.isEmpty { return "\(parsed.attachmentPaths.count) 个附件" }
        } else {
            let body = compactReplyPreviewText(rawText)
            if !body.isEmpty { return body }
        }
    }
    let toolCount = turn.content.reduce(into: 0) { count, block in
        if case .toolUse = block { count += 1 }
    }
    return toolCount > 0 ? "\(toolCount) 个工具调用" : ""
}

func scrubberUserPreview(turns: [ConversationTurn], index: Int) -> String {
    for position in stride(from: min(index, turns.count - 1), through: 0, by: -1) {
        guard turns.indices.contains(position) else { continue }
        let turn = turns[position]
        guard turn.role == "user" else { continue }
        let preview = conversationTurnPreview(turn)
        return preview.isEmpty ? "用户消息" : preview
    }
    return ""
}

func compactReplyPreviewText(_ source: String) -> String {
    let lines = source.components(separatedBy: .newlines).map { line -> String in
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["### ", "## ", "# ", "- ", "> "] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        return value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }
    let compact = lines.joined(separator: " ")
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
    return String(compact.prefix(160))
}

private func assistantReplyPreview(_ blocks: [ContentBlock]) -> String {
    let texts = blocks.compactMap { block -> String? in
        if case .text(let text, _) = block { return text }
        return nil
    }
    let preview = compactReplyPreviewText(texts.joined(separator: " "))
    if !preview.isEmpty { return preview }
    let toolCount = blocks.reduce(into: 0) { count, block in
        if case .toolUse = block { count += 1 }
    }
    return toolCount > 0 ? "\(toolCount) 个工具调用" : "助手回复"
}

/// Shared renderer for IM and execution pages. Execution protocol and permission state remain in ChatStore.
struct ResourceSelectionNoticeView: View {
    let notice: ResourceSelectionNotice
    var body: some View {
        Text(notice.label).font(.footnote).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("chat.resource-selection-notice")
            .accessibilityValue(notice.status ?? "")
    }
}

struct SessionMessageBody: View {
    let turn: ConversationTurn
    let api: WandAPI
    let sessionID: String
    var store: ChatStore? = nil
    var body: some View {
        TurnView(turn: turn, baseURL: api.baseURL,
            askSelections: store?.displayedAskSelections ?? [:],
            onAskToggle: { store?.toggleAskOption(toolUseId: $0, questionIndex: $1, optionIndex: $2, multiSelect: $3) },
            onAskSubmit: { store?.submitAskUser(toolUseId: $0, answerText: $1) })
            .environment(\.chatAPI, api)
            .environment(\.chatSessionID, sessionID)
            .environment(\.chatToolContentDidLoad, { store?.applyLoadedToolContent($0) })
    }
}

struct SessionProtocolPanel: View {
    @ObservedObject var store: ChatStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.pendingEscalation != nil || store.legacyPermissionPrompt != nil {
                PermissionCard(escalation: store.pendingEscalation, legacy: store.legacyPermissionPrompt,
                    onResolve: store.resolvePermission)
            }
            ForEach(identifiedDisplayItems(pairToolBlocks(store.messages.flatMap(\.content)))) { row in
                if case .tool(let id, _, _, let input, _, let result) = row.item {
                    let questions = AskUserQuestion.parse(input: input)
                    if !questions.isEmpty && result == nil {
                        AskUserQuestionCard(toolUseId: id, questions: questions, result: nil,
                            selection: store.displayedAskSelections[id] ?? AskUserSelectionState(),
                            onToggle: { store.toggleAskOption(toolUseId: id, questionIndex: $0, optionIndex: $1, multiSelect: $2) },
                            onSubmit: { store.submitAskUser(toolUseId: id, answerText: $0) })
                    }
                }
            }
        }
    }
}

private struct TurnView: View {
    let turn: ConversationTurn
    var baseURL: URL? = nil
    var isLastTurn = false
    var isResponding = false
    var compactUser = false
    var askSelections: [String: AskUserSelectionState] = [:]
    var onAskToggle: (String, Int, Int, Bool) -> Void = { _, _, _, _ in }
    var onAskSubmit: (String, String) -> Void = { _, _ in }

    @State private var userExpanded = false

    var body: some View {
        if turn.role == "user" {
            userBubble
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let notice = turn.resourceSelection { ResourceSelectionNoticeView(notice: notice) }
                assistantBlocks
            }
        }
    }

    private var userText: String {
        var pieces: [String] = []
        for block in turn.content {
            if case .text(let text, _) = block { pieces.append(text) }
        }
        return pieces.joined(separator: "\n")
    }

    /// 解析上传附件前缀：图片渲染缩略图、其余渲染文件块，正文保持在下方气泡。
    private var parsedUser: ParsedUserMessage {
        parseUserAttachmentMessage(userText)
    }

    private var userBubble: some View {
        let parsed = parsedUser
        let canCompact = compactUser && shouldCompactUserBody(parsed.body)
        let collapsed = canCompact && !userExpanded
        return VStack(alignment: .trailing, spacing: 6) {
            ChatMessageTime(
                clock: SessionTimeFormatting.conversationTurnClock(turn),
                alignEnd: true
            )
            if !parsed.attachmentPaths.isEmpty {
                attachmentsView(parsed.attachmentPaths)
            }
            if !parsed.body.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(parsed.body)
                            .font(.body)
                            .foregroundColor(Theme.onBrand)
                            .lineLimit(collapsed ? 2 : nil)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                        if canCompact {
                            Button {
                                withAnimation(WandMotion.disclosure) {
                                    userExpanded.toggle()
                                }
                            } label: {
                                Text(collapsed ? "展开" : "收起")
                                    .font(.wand(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.onBrand.opacity(0.86))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(collapsed ? "展开用户消息" : "收起用户消息")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.brand)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 上传附件：图片走缩略图、非图片走文件块，整体靠右对齐用户侧。
    @ViewBuilder private func attachmentsView(_ paths: [String]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                if let baseURL, isImagePath(path) {
                    WandImageThumbnail(baseURL: baseURL, path: path)
                } else {
                    WandFileChip(path: path)
                }
            }
        }
    }

    /// 兜底路径（非摊平场景，例如未来复用 TurnView 渲染整条 assistant turn）。
    /// 主列表已改为 flattenAssistantTurns + AssistantItemView 逐块摊平到顶层
    /// LazyVStack，避免单条 turn 携带上百块时一次性构建数百视图。
    private var assistantBlocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(identifiedDisplayItems(pairToolBlocks(turn.content))) { identified in
                AssistantItemView(
                    item: identified.item, baseURL: baseURL,
                    isLastTurn: isLastTurn, isResponding: isResponding,
                    askSelections: askSelections,
                    onAskToggle: onAskToggle, onAskSubmit: onAskSubmit
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageSummaryRow: View {
    let usage: TurnUsage?
    let isLive: Bool

    private var chips: [(String, String)] {
        var result: [(String, String)] = []
        guard let usage else { return result }
        if let input = usage.inputTokens, input > 0 {
            result.append(("输入", compactTokenCount(input)))
        }
        if let cache = usage.cacheReadInputTokens, cache > 0 {
            result.append(("缓存命中", compactTokenCount(cache)))
        }
        if let cacheWrite = usage.cacheCreationInputTokens, cacheWrite > 0 {
            result.append(("缓存写入", compactTokenCount(cacheWrite)))
        }
        if let output = usage.outputTokens, output > 0 {
            result.append(("输出", "\(usage.estimated == true ? "≈" : "")\(compactTokenCount(output))"))
        }
        if let reasoning = usage.reasoningOutputTokens, reasoning > 0 {
            result.append(("推理", "\(usage.estimated == true ? "≈" : "")\(compactTokenCount(reasoning))"))
        }
        if let cost = usage.totalCostUsd, cost > 0 {
            result.append(("费用", formatUsd(cost)))
        }
        return result
    }

    var body: some View {
        if !chips.isEmpty || isLive || usage?.estimated == true {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                if chips.isEmpty {
                    Text("正在统计用量…")
                        .font(.wand(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        HStack(spacing: 3) {
                            Text(chip.0)
                            Text(chip.1)
                                .fontWeight(.semibold)
                        }
                        .font(.wand(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.surface.opacity(0.75)))
                        .overlay(Capsule().stroke(Theme.border.opacity(0.75), lineWidth: 1))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
            .padding(.top, -4)
            .accessibilityLabel(chips.isEmpty
                ? "正在统计本轮用量"
                : "本轮用量 \(chips.map { "\($0.0) \($0.1)" }.joined(separator: "，"))")
        }
    }
}

/// 运行中的稳定单行状态：用量在左，当前思考/任务在右；两侧独立截断以适配窄屏。
private struct LiveTurnStatusRow: View {
    let usage: TurnUsage?
    let taskTitle: String?

    private var usageText: String {
        var parts: [String] = []
        if let input = usage?.inputTokens, input > 0 {
            parts.append("输入 \(compactTokenCount(input))")
        }
        if let cache = usage?.cacheReadInputTokens, cache > 0 {
            parts.append("缓存命中 \(compactTokenCount(cache))")
        }
        if let cacheWrite = usage?.cacheCreationInputTokens, cacheWrite > 0 {
            parts.append("缓存写入 \(compactTokenCount(cacheWrite))")
        }
        if let output = usage?.outputTokens, output > 0 {
            parts.append("输出 \(usage?.estimated == true ? "≈" : "")\(compactTokenCount(output))")
        }
        if let reasoning = usage?.reasoningOutputTokens, reasoning > 0 {
            parts.append("推理 \(usage?.estimated == true ? "≈" : "")\(compactTokenCount(reasoning))")
        }
        if let cost = usage?.totalCostUsd, cost > 0 {
            parts.append("费用 \(formatUsd(cost))")
        }
        return parts.isEmpty ? "正在统计用量…" : parts.joined(separator: " · ")
    }

    private var activityText: String {
        let trimmed = taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "正在思考…" : trimmed
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .semibold))
                Text(usageText)
                    .font(.wand(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.brand)
                Text(activityText)
                    .font(.wand(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 2)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("本轮用量 \(usageText)，\(activityText)")
    }
}

private func compactTokenCount(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 10_000 {
        return "\(value / 1_000)K"
    }
    if value >= 1_000 {
        let rounded = Double(value) / 1_000
        return rounded >= 10 ? "\(Int(rounded.rounded()))K" : String(format: "%.1fK", rounded)
    }
    return "\(value)"
}

private func formatUsd(_ value: Double) -> String {
    if value >= 0.01 {
        return String(format: "$%.2f", value)
    }
    return String(format: "$%.4f", value)
}

private struct ActivityFoldCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var activityFoldCompact: Bool {
        get { self[ActivityFoldCompactKey.self] }
        set { self[ActivityFoldCompactKey.self] = newValue }
    }
}

/// 活动滚动窗口的固定高度：活动再多也不撑爆对话流，内部自己滚。
let activityWindowHeight: CGFloat = 240

/// 离底超过这个距离就算「在读历史」：新的活动不再把用户拽回尾部。
let activityTailPin: CGFloat = 24

/// 活动窗口展开 / 收起：240ms 强调曲线（对齐 WandMotion.tweenNormal / Web 端）；
/// 减弱动效时瞬切。
func activityWindowAnimation(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : WandMotion.stateSwap
}

private struct ChatMessageTime: View {
    let clock: String
    var alignEnd = false

    var body: some View {
        if !clock.isEmpty {
            Text(clock)
                .font(.wand(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: alignEnd ? .trailing : .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
    }
}

private struct SubagentActivityShelf: View {
    let activities: [SubagentActivity]
    let isResponding: Bool
    var completedClock: String = ""
    var baseURL: URL? = nil
    var askSelections: [String: AskUserSelectionState] = [:]
    var onAskToggle: (String, Int, Int, Bool) -> Void = { _, _, _, _ in }
    var onAskSubmit: (String, String) -> Void = { _, _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedActivityID: String?
    @State private var isExpanded = false

    private var selectedActivity: SubagentActivity? {
        guard let selectedActivityID else { return nil }
        return activities.first { $0.id == selectedActivityID }
    }

    private var runningCount: Int {
        activities.filter { $0.state == .running }.count
    }

    private var summary: String {
        if isResponding {
            return runningCount > 0 ? "\(runningCount) 个正在运行" : "\(activities.count) 个子任务已完成"
        }
        if !completedClock.isEmpty { return "完成 \(completedClock)" }
        return "\(activities.count) 个子任务已完成"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.brand.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("子 Agent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                // 头部整行都能开合子任务详情：只让 chip 可点是「点不开」的来源。
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 32, height: 32, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleDetail() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("子 Agent")
            .accessibilityValue(summary)
            .accessibilityHint(isExpanded ? "收起子任务详情" : "展开子任务详情")
            .accessibilityAddTraits(.isButton)

            // 栏只在有真实子任务时出现（见 shouldShowSubagentShelf），这里不再兜空列表。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(activities, id: \.id) { activity in
                        activityChip(activity)
                    }
                }
            }

            if isExpanded, let selectedActivity {
                SubagentActivityDetail(
                    activity: selectedActivity,
                    baseURL: baseURL,
                    askSelections: askSelections,
                    onAskToggle: onAskToggle,
                    onAskSubmit: onAskSubmit,
                    onClose: { setExpanded(false) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.border.opacity(0.85), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.045), radius: 8, y: 2)
        .animation(reduceMotion ? nil : WandMotion.disclosure, value: isExpanded)
        .onAppear { reconcileSelection() }
        .onChange(of: activities.map(\.id)) { _, _ in reconcileSelection() }
        .accessibilityElement(children: .contain)
    }

    private func activityChip(_ activity: SubagentActivity) -> some View {
        let selected = isExpanded && selectedActivityID == activity.id
        return Button {
            selectedActivityID = activity.id
            setExpanded(!selected)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: subagentSymbol(for: activity.meta.agentType))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundColor(subagentTint(activity.state))
                    .background(Circle().fill(subagentTint(activity.state).opacity(0.12)))
                Text(subagentRoleName(activity.meta.agentType))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                subagentStateIndicator(activity.state)
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 9)
            .frame(minHeight: 44)
            .background(Capsule().fill(selected ? Theme.brand.opacity(0.12) : Theme.background.opacity(0.72)))
            .overlay(Capsule().stroke(selected ? Theme.brand.opacity(0.55) : Theme.border.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(subagentRoleName(activity.meta.agentType))，\(subagentStateText(activity.state))")
        .accessibilityValue(selected ? "详情已展开" : "详情已收起")
        .accessibilityHint("轻点查看子任务输出")
    }

    @ViewBuilder private func subagentStateIndicator(_ state: SubagentActivity.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini).tint(Theme.brand)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.textMuted)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.danger)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        if reduceMotion {
            isExpanded = expanded
        } else {
            withAnimation(WandMotion.disclosure) { isExpanded = expanded }
        }
    }

    /// 头部整行开合详情：展开时选中正在运行的（没有就用第一个），和 chip 的选中规则一致。
    private func toggleDetail() {
        guard !activities.isEmpty else { return }
        if isExpanded {
            setExpanded(false)
            return
        }
        if selectedActivity == nil {
            selectedActivityID = activities.first(where: { $0.state == .running })?.id ?? activities.first?.id
        }
        setExpanded(true)
    }

    private func reconcileSelection() {
        guard selectedActivity == nil else { return }
        selectedActivityID = activities.first(where: { $0.state == .running })?.id ?? activities.first?.id
    }
}

private struct SubagentActivityDetail: View {
    let activity: SubagentActivity
    var baseURL: URL? = nil
    var askSelections: [String: AskUserSelectionState] = [:]
    var onAskToggle: (String, Int, Int, Bool) -> Void = { _, _, _, _ in }
    var onAskSubmit: (String, String) -> Void = { _, _ in }
    let onClose: () -> Void
    private let subagentWindowContentHeight: CGFloat = 280

    private var items: [DisplayItem] { pairToolBlocks(activity.blocks) }
    private var tailAnchorID: String { "subagent-shelf-tail:\(activity.id)" }
    private var title: String { subagentRoleName(activity.meta.agentType) }
    private var description: String {
        let value = activity.meta.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "子任务输出" : value
    }

    var body: some View {
        let refreshToken = subagentTailRefreshToken(items)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: subagentSymbol(for: activity.meta.agentType))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(subagentTint(activity.state))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(subagentTint(activity.state).opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起子任务详情")
            }

            HStack(spacing: 5) {
                subagentStateIndicator(activity.state)
                Text(subagentStateText(activity.state))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(subagentTint(activity.state))
                Text("· \(items.count) 条内容")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }

            Divider().overlay(Theme.border.opacity(0.7))

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        if items.isEmpty {
                            Text(activity.state == .running ? "等待子 Agent 输出…" : "没有可显示的子任务输出")
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(identifiedDisplayItems(items)) { identified in
                                AssistantItemView(
                                    item: identified.item,
                                    baseURL: baseURL,
                                    isLastTurn: activity.state == .running,
                                    isResponding: activity.state == .running,
                                    askSelections: askSelections,
                                    onAskToggle: onAskToggle,
                                    onAskSubmit: onAskSubmit,
                                    showSubagentTags: false
                                )
                            }
                        }
                        Color.clear.frame(height: 1).id(tailAnchorID)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 1)
                }
                .frame(height: subagentWindowContentHeight)
                .onAppear { scrollToTail(proxy) }
                .onChange(of: refreshToken) { _, _ in
                    guard activity.state == .running else { return }
                    scrollToTail(proxy)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.background.opacity(0.62)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(description)，\(subagentStateText(activity.state))")
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(tailAnchorID, anchor: .bottom)
        }
    }

    @ViewBuilder private func subagentStateIndicator(_ state: SubagentActivity.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini).tint(Theme.brand)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.textMuted)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.danger)
        }
    }
}

private func subagentTailRefreshToken(_ items: [DisplayItem]) -> Int {
    var hasher = Hasher()
    hasher.combine(items.count)
    for item in items {
        hasher.combine(displayItemIdentity(item))
        switch item {
        case .tool(_, _, _, _, _, let result):
            hasher.combine(result?.text)
            hasher.combine(result?.isError)
            hasher.combine(result?.truncated)
        case .plain:
            break
        }
    }
    return hasher.finalize()
}

private func subagentRoleName(_ raw: String?) -> String {
    let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? "子 Agent" : name
}

private func subagentSymbol(for role: String?) -> String {
    let normalized = role?.lowercased() ?? ""
    if normalized.contains("explore") || normalized.contains("search") { return "magnifyingglass" }
    if normalized.contains("code") || normalized.contains("dev") { return "chevron.left.forwardslash.chevron.right" }
    if normalized.contains("review") { return "checklist" }
    return "sparkles"
}

private func subagentTint(_ state: SubagentActivity.State) -> Color {
    switch state {
    case .running: return Theme.brand
    case .completed: return Theme.textMuted
    case .failed: return Theme.danger
    }
}

private func subagentStateText(_ state: SubagentActivity.State) -> String {
    switch state {
    case .running: return "正在运行"
    case .completed: return "已完成"
    case .failed: return "执行失败"
    }
}

/// 单个 assistant 内容块（plain / 工具卡 / 探索分组）的渲染。
/// 抽成独立视图，让主列表能把一条 assistant turn 的每个块摊平成顶层 LazyVStack
/// 的独立行——单条 turn 携带上百个块时，避免整条 turn 一次性构建数百个嵌套视图
/// （会卡死/白屏），改由 LazyVStack 仅实例化进入视口的块。
struct AssistantItemView: View {
    @Environment(\.cardExpandDefaults) private var cardDefaults

    let item: DisplayItem
    var baseURL: URL? = nil
    var isLastTurn = false
    var isResponding = false
    var askSelections: [String: AskUserSelectionState] = [:]
    var onAskToggle: (String, Int, Int, Bool) -> Void = { _, _, _, _ in }
    var onAskSubmit: (String, String) -> Void = { _, _ in }
    var showSubagentTags = true
    var forceExpanded = false
    private func expandDefault(_ configured: Bool) -> Bool { forceExpanded || configured }

    var body: some View {
        switch item {
        case .plain(let block):
            BlockView(block: block, showSubagentTags: showSubagentTags)
        case .tool(let id, let name, let description, let input, let subagent, let result):
            VStack(alignment: .leading, spacing: 4) {
                if showSubagentTags { subagentTag(subagent) }
                toolView(id: id, name: name, description: description, input: input, result: result, openedFromActivity: forceExpanded)
            }
        }
    }

    /// 工具卡分流（对齐 Web 端 renderToolUseCard）：
    /// AskUserQuestion → 交互卡；Edit/Write/MultiEdit → diff 卡；Bash → 终端卡；其余 → 通用卡。
    @ViewBuilder private func toolView(
        id: String, name: String, description: String?,
        input: [String: JSONValue], result: ToolResultInfo?, openedFromActivity: Bool = false
    ) -> some View {
        let questions = AskUserQuestion.parse(input: input)
        if isDecisionTool(input: input) || result?.projection?.isDecision == true {
            DecisionToolCard(id: id, label: result?.projection?.decisionLabel ?? input["__wandDecisionLabel"]?.stringValue,
                             input: input, result: result, running: result == nil && isLastTurn && isResponding)
        } else if !questions.isEmpty {
            AskUserQuestionCard(
                toolUseId: id,
                questions: questions,
                result: result,
                selection: askSelections[id] ?? AskUserSelectionState(),
                expandAll: isLastTurn,
                onToggle: { qIdx, optIdx, multi in onAskToggle(id, qIdx, optIdx, multi) },
                onSubmit: { answerText in onAskSubmit(id, answerText) }
            )
        } else if let result, !result.images.isEmpty {
            ToolUseCard(name: name, description: description, input: input, result: result,
                        baseURL: baseURL, initiallyExpanded: openedFromActivity)
        } else if name == "Edit" || name == "Write" || name == "MultiEdit" {
            DiffCard(toolName: name, input: input, result: result, initiallyExpanded: openedFromActivity || expandDefault(cardDefaults.editCards))
        } else if name == "Bash" {
            TerminalCard(
                input: input,
                result: result,
                running: result == nil && isLastTurn && isResponding,
                initiallyExpanded: openedFromActivity || expandDefault(cardDefaults.terminal)
            )
        } else {
            ToolUseCard(
                name: name, description: description, input: input,
                result: result, running: result == nil && isLastTurn && isResponding,
                baseURL: baseURL,
                initiallyExpanded: openedFromActivity || expandDefault(cardDefaults.shouldExpandTool(name))
            )
        }
    }

    @ViewBuilder private func subagentTag(_ meta: SubagentMeta?) -> some View {
        if let meta {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(meta.taskDescription ?? meta.agentType ?? "子任务")
                    .font(.wand(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.brandStrong)
        }
    }
}

@MainActor
final class DecisionCardExpansionState: ObservableObject {
    @Published private(set) var expanded: [String: Bool] = [:]
    func isExpanded(_ id: String) -> Bool { expanded[id] ?? false }
    func toggle(_ id: String) { expanded[id] = !isExpanded(id) }
}

private struct DecisionCardsEnvironmentKey: EnvironmentKey {
    static let defaultValue: DecisionCardExpansionState? = nil
}

private extension EnvironmentValues {
    var chatDecisionCards: DecisionCardExpansionState? {
        get { self[DecisionCardsEnvironmentKey.self] }
        set { self[DecisionCardsEnvironmentKey.self] = newValue }
    }
}

private struct ToolPreviewText: View {
    let text: String
    var color = Theme.textSecondary
    var body: some View {
        if !text.isEmpty {
            Text(text).font(.wand(size: 11, design: .monospaced))
                .foregroundStyle(color).lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DecisionToolCard: View {
    let id: String
    let label: String?
    let input: [String: JSONValue]
    let result: ToolResultInfo?
    let running: Bool
    @Environment(\.chatDecisionCards) private var sharedState
    @StateObject private var fallback = DecisionCardExpansionState()
    var body: some View {
        DecisionToolCardContent(id: id, label: label, input: input, result: result, running: running,
                                state: sharedState ?? fallback)
    }
}

private struct DecisionToolCardContent: View {
    let id: String
    let label: String?
    let input: [String: JSONValue]
    let result: ToolResultInfo?
    let running: Bool
    @ObservedObject var state: DecisionCardExpansionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var expanded: Bool { state.isExpanded(id) }
    private var tint: Color { result?.isError == true ? Theme.danger : (running ? Theme.brand : Theme.success) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let result { ToolResultBody(result: result, input: input, showsInput: true) }
                    else {
                        let details = toolInputDetail(input)
                        if !details.isEmpty {
                            Text(details).font(.wand(size: 12, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }.padding(12).transition(.opacity)
                Divider()
            }
            Button {
                withAnimation(reduceMotion ? nil : WandMotion.stateSwap) { state.toggle(id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("本地决策").font(.wand(size: 13, weight: .semibold))
                            Text("实验性").font(.wand(size: 9)).foregroundStyle(Theme.textSecondary)
                        }
                        if let label, !label.isEmpty { Text(label).font(.wand(size: 12)).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                    ZStack {
                        Circle().fill(tint).frame(width: 6, height: 6).opacity(running ? 0 : 1)
                        ProgressView().controlSize(.small).opacity(running ? 1 : 0)
                    }.frame(width: 18, height: 18)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(Theme.textSecondary)
                }.foregroundStyle(Theme.textPrimary).padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("本地决策，\(label ?? "")，\(running ? "运行中" : (result?.isError == true ? "失败" : "完成"))")
                .accessibilityValue(expanded ? "已展开" : "已收起")
        }.background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(expanded ? Theme.brand.opacity(0.3) : Theme.border))
    }
}

// MARK: - 内容块渲染

private struct BlockView: View {
    @Environment(\.chatAPI) private var api
    @Environment(\.cardExpandDefaults) private var cardDefaults
    @Environment(\.activityFoldCompact) private var compact

    let block: ContentBlock
    var showSubagentTags = true

    var body: some View {
        switch block {
        case .text(let text, let subagent):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if showSubagentTags { subagentTag(subagent) }
                    MarkdownText(text: text)
                }
            }
        case .thinking(let thinking, _, _, _):
            if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CollapsibleSection(
                    icon: "brain",
                    title: "思考过程",
                    tint: Theme.textSecondary,
                    initiallyExpanded: cardDefaults.thinking
                ) {
                    Text(thinking)
                        .font(.wand(size: compact ? 11 : 13))
                        .italic()
                        .foregroundColor(compact ? Theme.textMuted : Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        case .toolUse(_, let name, let description, let input, let subagent):
            // 兜底：正常路径已在 TurnView 配对分流，这里处理极端的落单 ToolUse。
            VStack(alignment: .leading, spacing: 4) {
                if showSubagentTags { subagentTag(subagent) }
                ToolUseCard(
                    name: name,
                    description: description,
                    input: input,
                    result: nil,
                    running: false,
                    initiallyExpanded: cardDefaults.shouldExpandTool(name)
                )
            }
        case .toolResult(let toolUseId, let text, let isError, let truncated, let images, _, let projection):
            if projection?.isDecision == true {
                DecisionToolCard(id: toolUseId, label: projection?.decisionLabel, input: [:],
                    result: ToolResultInfo(toolUseId: toolUseId, text: text, isError: isError,
                                           truncated: truncated, images: images, projection: projection), running: false)
            } else {
                if let baseURL = api?.baseURL, !images.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            WandToolImageThumbnail(baseURL: baseURL, source: image)
                        }
                    }
                }
                if !text.isEmpty || truncated {
                CollapsibleSection(
                    icon: isError ? "xmark.octagon" : "doc.text",
                    title: isError ? "执行出错" : "执行结果",
                    tint: isError ? Theme.danger : Theme.textSecondary,
                    initiallyExpanded: cardDefaults.editCards
                ) {
                    ToolResultBody(result: ToolResultInfo(
                        toolUseId: toolUseId,
                        text: text,
                        isError: isError,
                        truncated: truncated,
                        images: images,
                        projection: projection
                    ))
                }
                }
            }
        case .unknown(let type, let payload):
            UnknownBlockCard(type: type, payload: payload)
        }
    }

    @ViewBuilder private func subagentTag(_ meta: SubagentMeta?) -> some View {
        if let meta {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(meta.taskDescription ?? meta.agentType ?? "子任务")
                    .font(.wand(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.brandStrong)
        }
    }
}

/// 服务端新增内容块的显式兜底。默认折叠，保留类型和已脱敏、限长的原始载荷，
/// 便于诊断协议演进，同时避免未知内容静默消失。
private struct UnknownBlockCard: View {
    let type: String
    let payload: String

    private var displayType: String {
        let value = type.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未声明类型" : value
    }

    var body: some View {
        CollapsibleSection(
            icon: "questionmark.diamond",
            title: "未知内容 · \(displayType)",
            tint: Theme.warning
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("类型  \(displayType)")
                    .font(.wand(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Text(payload.isEmpty ? "无可显示载荷" : payload)
                    .font(.wand(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel("未知内容块，类型 \(displayType)")
    }
}

/// 原生 Markdown 渲染：块级结构独立布局，内联标记交给 AttributedString。
private struct MarkdownText: View {
    let text: String

    @Environment(\.chatAPI) private var api
    @Environment(\.serverFileLinkController) private var serverFileLinks
    @Environment(\.activityFoldCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .environment(\.openURL, serverFileOpenURLAction)
    }

    private var serverFileOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard let serverPath = WandServerFileLink.serverPath(url.absoluteString) else {
                return .systemAction
            }
            // A matched absolute path must never fall through to iOS' local file opener.
            guard let api, let serverFileLinks else { return .discarded }
            serverFileLinks.open(serverPath: serverPath, api: api)
            return .handled
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
            inlineText(content, size: compact ? 12 : 16, color: compact ? Theme.textMuted : Theme.textPrimary)
        case .heading(let level, let content):
            inlineText(content, size: headingSize(level) - (compact ? 3 : 0), weight: .semibold, color: compact ? Theme.textMuted : Theme.textPrimary)
                .padding(.top, level <= 2 ? 3 : 1)
        case .listItem(let marker, let content, let indent, let checked):
            HStack(alignment: .top, spacing: 7) {
                Text(checked.map { $0 ? "☑" : "☐" } ?? marker)
                    .font(.wand(size: 13, weight: .semibold))
                    .foregroundColor(checked == true ? Theme.success : Theme.brand)
                    .padding(.top, 2)
                inlineText(content, size: compact ? 12 : 16, color: compact ? Theme.textMuted : Theme.textPrimary)
            }
            .padding(.leading, CGFloat(indent * 14))
        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.brand)
                    .frame(width: 3)
                inlineText(content, size: compact ? 12 : 15, color: compact ? Theme.textMuted : Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
        case .code(let content, let language):
            VStack(alignment: .leading, spacing: 2) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.wand(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.wand(size: 13, design: .monospaced))
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
                    .font(.wand(size: header ? 13 : 12, weight: header ? .semibold : .regular))
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
            .font(.wand(size: size, weight: weight))
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
    if lower.hasPrefix("codex/") {
        switch String(lower.dropFirst("codex/".count)) {
        case "spawn_agent": return "启动子代理"
        case "send_input", "send_message": return "发送子任务消息"
        case "wait", "wait_agent": return "等待子代理"
        case "close_agent": return "关闭子代理"
        default: return "多 Agent 协作"
        }
    }
    if lower == "tool_search" || lower.contains("toolsearch") { return "查找可用工具" }
    if lower.contains("apply_patch") || lower.contains("patch_apply") { return "应用补丁" }
    if lower.contains("view_image") || lower.contains("imagegen") { return "处理图片" }
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
    if lower.hasPrefix("opencode/") {
        return humanizeToolName(String(name.dropFirst("OpenCode/".count)))
    }
    if lower.hasPrefix("node_repl") { return "运行 REPL" }
    if name.contains("__") {
        return humanizeToolName(name.components(separatedBy: "__").last ?? name)
    }
    if lower == "skill" { return "加载技能" }
    if lower.hasPrefix("task") || lower.contains("agent") { return "子任务" }
    return name
}

private func humanizeToolName(_ name: String) -> String {
    name
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .capitalized
}

/// 将 Provider / MCP server 信息放在独立来源标签里，不挤占工具主标题。
private func toolSourceLabel(_ name: String) -> String? {
    let lower = name.lowercased()
    if lower.hasPrefix("codex/") { return "Codex" }
    if lower.hasPrefix("opencode/") { return "OpenCode" }
    if lower.hasPrefix("node_repl") { return "REPL" }
    if name.contains("__") {
        let parts = name.components(separatedBy: "__")
        let source = parts.first?.lowercased() == "mcp" ? parts.dropFirst().first : parts.first
        let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "MCP" : String(trimmed.prefix(18))
    }
    return nil
}

/// 连续只读探索操作的紧凑进度卡。默认折叠，避免探索阶段淹没对话。
private struct ExplorationGroupCard: View {
    let tools: [ExplorationToolItem]
    var baseURL: URL? = nil
    let running: Bool
    var expandAll = false

    var body: some View {
        // 探索上下文不再是「另一张摘要卡」：整段收进同一个活动滚动窗口，
        // 避免窗口里再嵌一层「N 个调用」摘要和窗口头部的缩略信息重复。
        ActivityFoldCard(
            group: groupForTools(tools, newest: expandAll),
            baseURL: baseURL,
            isLastTurn: expandAll,
            isResponding: running
        )
    }
}

/// 只读探索工具收成一个活动窗口（和普通活动分组同一套渲染）。
private func groupForTools(
    _ tools: [ExplorationToolItem],
    newest: Bool
) -> ActivityGroup {
    let items = tools.map { tool in
        DisplayItem.tool(
            id: tool.id, name: tool.name, description: tool.description,
            input: tool.input, subagent: tool.subagent, result: tool.result
        )
    }
    let summary = summarizeActivityItems(items)
    return ActivityGroup(
        latest: summary.latest,
        meta: summary.meta,
        count: summary.count,
        items: items,
        newest: newest
    )
}

/// 工具调用卡片：图标 + 中文工具名 + 参数摘要 + 可折叠结果区。
/// 三态对齐 Web：运行中（转圈）/ 成功（左侧绿竖线）/ 失败（红弱底 + 红边框）。
private struct ToolUseCard: View {
    let name: String
    let description: String?
    let input: [String: JSONValue]
    var result: ToolResultInfo?
    var running = false
    var baseURL: URL? = nil
    var initiallyExpanded = false

    @State private var expanded = false
    @State private var appliedInitialExpansion = false

    /// Read 读到的图片路径（用于卡片内常驻缩略图，对齐 Web 端 inline-tool-image）。
    private var imagePath: String? {
        guard name == "Read" else { return nil }
        let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue
        return isImagePath(path) ? path : nil
    }

    private var isError: Bool { result?.isError == true }
    private var isSuccess: Bool { result != nil && !isError }
    private var hasBody: Bool {
        guard let result else { return false }
        return !result.text.isEmpty || result.truncated
    }
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
            if let result {
                ToolPreviewText(text: toolResultPreview(text: result.text, projection: result.projection),
                                color: result.isError ? Theme.danger : Theme.textSecondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            // 结果内联图片优先（服务端已归一化），没有时退回 Read 按路径取图；
            // 两者同时渲染会出现同一张图两个缩略图。
            if let baseURL, let resultImages = result?.images, !resultImages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(resultImages.enumerated()), id: \.offset) { _, source in
                        WandToolImageThumbnail(baseURL: baseURL, source: source)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else if let imagePath, let baseURL {
                // Read 读到图片：卡片里常驻内联缩略图（点击放大），对齐 Web。
                WandImageThumbnail(baseURL: baseURL, path: imagePath)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
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
        .onAppear {
            guard !appliedInitialExpansion else { return }
            expanded = initiallyExpanded && hasBody
            appliedInitialExpansion = true
        }
        .onChange(of: result != nil) {
            if initiallyExpanded && hasBody {
                withAnimation(WandMotion.disclosure) { expanded = true }
            }
        }
    }

    private var header: some View {
        Button {
            guard hasBody else { return }
            withAnimation(WandMotion.disclosure) { expanded.toggle() }
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
                    HStack(spacing: 6) {
                        Text(toolLabel(name))
                            .font(.wand(size: 13, weight: .semibold))
                            .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                            .lineLimit(1)
                        if let source = toolSourceLabel(name) {
                            Text(source)
                                .font(.wand(size: 9, weight: .semibold))
                                .foregroundColor(Theme.codex)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.codex.opacity(0.10)))
                        }
                    }
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.wand(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.wand(size: 10, weight: .semibold))
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
        if lower.contains("apply_patch") || lower.contains("patch_apply") { return "doc.badge.gearshape" }
        if lower.contains("view_image") || lower.contains("imagegen") { return "photo" }
        if lower.contains("edit") || lower.contains("write") { return "pencil" }
        if lower.contains("read") { return "doc.text.magnifyingglass" }
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return "magnifyingglass" }
        if lower.contains("web") || lower.contains("fetch") { return "globe" }
        if lower == "skill" { return "wand.and.stars" }
        if lower.contains("task") || lower.contains("agent") { return "person.2" }
        return "wrench.and.screwdriver"
    }

    /// 摘要优先级：description > 常见关键参数 > 第一个参数。
    private var summary: String {
        let preview = toolInputPreview(input)
        if !preview.isEmpty { return preview }
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

/// 工具结果正文：保留移动端展示上限；服务端截断时可按需加载并复制完整内容。
private struct ToolResultBody: View {
    @Environment(\.chatToolContentDidLoad) private var contentDidLoad
    @Environment(\.chatAPI) private var api
    @Environment(\.chatSessionID) private var sessionID

    let result: ToolResultInfo
    let showsInput: Bool
    @State private var fullInput: [String: JSONValue]
    @State private var fullImages: [String]
    @State private var fullIsError: Bool
    @State private var sourceToolID: String

    @State private var fullText: String
    @State private var truncated: Bool
    @State private var loading = false
    @State private var loadError: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?
    @State private var activeRequestKey = ""

    private let displayLimit = 24_000

    init(result: ToolResultInfo, input: [String: JSONValue] = [:], showsInput: Bool = false) {
        self.result = result
        self.showsInput = showsInput
        _fullInput = State(initialValue: input)
        _fullImages = State(initialValue: result.images)
        _fullIsError = State(initialValue: result.isError)
        _sourceToolID = State(initialValue: result.toolUseId)
        _fullText = State(initialValue: result.text)
        _truncated = State(initialValue: result.truncated)
    }

    private var formattedText: String { prettyStructuredToolText(fullText) }

    private var displayText: String {
        guard formattedText.count > displayLimit else { return formattedText }
        return String(formattedText.prefix(displayLimit)) + "\n…（本页仅展示前 \(displayLimit) 字）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsInput, let baseURL = api?.baseURL, !fullImages.isEmpty {
                ForEach(Array(fullImages.enumerated()), id: \.offset) { _, image in
                    WandToolImageThumbnail(baseURL: baseURL, source: image)
                }
            }
            if showsInput {
                let details = toolInputDetail(fullInput)
                if !details.isEmpty {
                    Text(String(details.prefix(displayLimit)))
                        .font(.wand(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            if !displayText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(displayText)
                        .font(.wand(size: 12, design: .monospaced))
                        .foregroundColor(fullIsError ? Theme.danger : Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.background.opacity(0.6))
                )
            }
            if truncated {
                fullContentRow
            } else if displayText.isEmpty {
                Text(fullIsError ? "工具执行失败，未返回错误详情" : "工具已完成，没有文本输出")
                    .font(.wand(size: 11))
                    .foregroundColor(fullIsError ? Theme.danger : Theme.textSecondary)
            }
            if !fullText.isEmpty {
                Button {
                    UIPasteboard.general.string = fullText
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.wand(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)
                .accessibilityLabel("复制完整工具输出")
            }
        }
        .onAppear { if truncated { loadFullContent() } }
        .onChange(of: toolResultMetadataToken(result)) { _, _ in
            cancelLoad()
            if sourceToolID != result.toolUseId {
                sourceToolID = result.toolUseId
                fullInput = [:]
                fullImages = result.images
                fullIsError = result.isError
                fullText = result.text
                truncated = result.truncated
            }
            if !result.images.isEmpty { fullImages = result.images }
            fullIsError = fullIsError || result.isError
            guard !(result.truncated && !truncated && fullText.count >= result.text.count) else { return }
            fullText = result.text
            truncated = result.truncated
            loadError = nil
            if truncated { loadFullContent() }
        }
        .onDisappear { cancelLoad() }
    }

    private var fullContentRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(loadError ?? "服务端为保证传输速度省略了部分内容")
                .font(.wand(size: 11))
                .foregroundColor(loadError == nil ? Theme.textSecondary : Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: loadFullContent) {
                if loading {
                    ProgressView().controlSize(.small).tint(Theme.brand)
                } else {
                    Text(loadError == nil ? "加载完整内容" : "重试")
                        .font(.wand(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.brand)
            .disabled(loading)
        }
    }

    private func loadFullContent() {
        guard let api, !sessionID.isEmpty, !result.toolUseId.isEmpty else {
            loadError = "无法加载完整内容"
            return
        }
        loadTask?.cancel()
        let requestID = UUID()
        let toolUseID = result.toolUseId
        let requestKey = "\(sessionID)\u{1F}\(toolUseID)"
        activeRequestID = requestID
        activeRequestKey = requestKey
        loading = true
        loadError = nil
        loadTask = Task { @MainActor in
            defer {
                if activeRequestID == requestID {
                    loading = false
                    activeRequestID = nil
                    activeRequestKey = ""
                    loadTask = nil
                }
            }
            do {
                let loaded = try await api.fetchToolContent(id: sessionID, toolUseId: toolUseID)
                try Task.checkCancellation()
                guard activeRequestID == requestID, activeRequestKey == requestKey else { return }
                guard loaded.toolUseId.isEmpty || loaded.toolUseId == toolUseID else {
                    loadError = "服务端返回了不匹配的工具结果"
                    return
                }
                fullText = loaded.text
                fullIsError = loaded.isError || result.isError
                if !loaded.images.isEmpty { fullImages = loaded.images }
                contentDidLoad?(loaded)
                if !loaded.input.isEmpty { fullInput = loaded.input }
                truncated = false
            } catch {
                guard !Task.isCancelled,
                      activeRequestID == requestID,
                      activeRequestKey == requestKey else { return }
                loadError = error.localizedDescription.isEmpty ? "加载失败，请重试" : error.localizedDescription
            }
        }
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        activeRequestID = nil
        activeRequestKey = ""
        loading = false
    }
}

private func prettyStructuredToolText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first, first == "{" || first == "[",
          let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          JSONSerialization.isValidJSONObject(object),
          let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let output = String(data: formatted, encoding: .utf8) else {
        return text
    }
    return output
}

/// 可折叠区块（thinking / tool_result 共用）。具体内容默认折叠，点击标题后展开。
private struct CollapsibleSection<Content: View>: View {
    let icon: String
    let title: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    @State private var expanded: Bool

    init(
        icon: String,
        title: String,
        tint: Color,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.tint = tint
        self.content = content
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(WandMotion.disclosure) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12))
                    Text(title).font(.wand(size: 12, weight: .medium))
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
                    .foregroundColor(Theme.permission)
                Text(title)
                    .font(.wand(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.wand(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let target, !target.isEmpty {
                Text(target)
                    .font(.wand(size: 12, design: .monospaced))
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
                .stroke(Theme.permission.opacity(0.55), lineWidth: 1.5)
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

// MARK: - 回复与历史折叠入口

private struct AssistantReplyDisclosure: View {
    let preview: String
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                if collapsed {
                    Text(preview)
                        .font(.wand(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(collapsed ? "展开" : "收起")
                    .font(.wand(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 180))
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(collapsed ? Theme.surface.opacity(0.7) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? "展开 Wand 回复，\(preview)" : "收起 Wand 回复")
        .accessibilityValue(collapsed ? "已收起" : "已展开")
    }
}

// MARK: - 历史折叠摘要卡

/// 发新消息后，把"最后一条用户消息"之前的历史折叠成这张分隔卡。展开时它上方出现
/// 完整历史，收起时只剩当前这一轮。点一下切换。对齐 Web / Android 同款行为。
private struct HistorySummaryCard: View {
    let stats: HistoryStats
    let expanded: Bool
    let onToggle: () -> Void

    private var metaText: String {
        var parts: [String] = ["\(stats.rounds) 轮对话"]
        if stats.tools > 0 { parts.append("\(stats.tools) 次工具调用") }
        if stats.agents > 0 { parts.append("\(stats.agents) 个子代理") }
        if stats.errors > 0 { parts.append("\(stats.errors) 个失败") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(expanded ? "收起历史对话" : "展开历史对话")
                        .font(.wand(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(metaText)
                        .font(.wand(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Theme.border.opacity(0.7), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 共享语义色（Web 端 --success 同款 #4F7A58）

private let chatSuccess = Theme.success

// MARK: - AskUserQuestion 交互卡片（对齐 Web 端 ask-user 卡）

/// 提问卡：头部「? 提问 · header」，body 是题目 + 选项列表 + 确认提交。
/// 未答可交互（单选/多选），已答（配对到 tool_result）转只读并高亮用户选过的项。
private struct AskUserQuestionCard: View {
    let toolUseId: String
    let questions: [AskUserQuestion]
    let result: ToolResultInfo?
    let selection: AskUserSelectionState
    var expandAll = false
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
        .onAppear { expanded = expandAll || !isAnswered }
        .onChange(of: isAnswered) { _, answered in
            // 回答送达后自动折叠（对齐 Web 已答默认折叠）；最新一轮保持完整内容。
            if answered && !expandAll {
                withAnimation(WandMotion.disclosure) { expanded = false }
            }
        }
        .onChange(of: expandAll) { _, shouldExpand in
            if shouldExpand { expanded = true }
        }
    }

    private var headerView: some View {
        Button {
            withAnimation(WandMotion.disclosure) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isAnswered ? "checkmark.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isAnswered ? chatSuccess : Theme.brand)
                    .frame(width: 22)
                Text("提问")
                    .font(.wand(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let headerLabel {
                    Text(headerLabel)
                        .font(.wand(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                if isAnswered {
                    Text(answerLines.joined(separator: ", "))
                        .font(.wand(size: 12))
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
                    .font(.wand(size: 14, weight: .medium))
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
                        .font(.wand(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.wand(size: 12))
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
                Text(selection.unavailableReason ?? (selection.submissionUnconfirmed ? "送达未确认" : selection.submitted ? "已提交…" : "确认提交"))
                    .font(.wand(size: 13, weight: .semibold))
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
    var initiallyExpanded = false

    @State private var expanded = false
    @State private var initialized = false

    private var path: String {
        input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? ""
    }
    private var fileName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
    private var isWrite: Bool { toolName == "Write" }
    private var isMultiEdit: Bool { toolName == "MultiEdit" }
    private var oldText: String { input["old_string"]?.stringValue ?? "" }
    private var newText: String {
        input["new_string"]?.stringValue ?? input["content"]?.stringValue ?? ""
    }
    private var unifiedDiff: String { input["unified_diff"]?.stringValue ?? "" }
    private var kind: String {
        (input["kind"]?.stringValue ?? (isWrite ? "add" : "update")).lowercased()
    }
    private var multiEdits: [(old: String, new: String)] {
        guard isMultiEdit else { return [] }
        return (jsonArrayField(input, "edits") ?? []).compactMap { value in
            guard let edit = value.objectValue else { return nil }
            let old = edit["old_string"]?.stringValue ?? ""
            let new = edit["new_string"]?.stringValue ?? ""
            return old.isEmpty && new.isEmpty ? nil : (old, new)
        }
    }
    private var movePath: String { input["move_path"]?.stringValue ?? "" }
    private var diffUnavailableReason: String? {
        let reason = (input["diff_unavailable_reason"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }
    private var hasDiffBody: Bool {
        !oldText.isEmpty || !newText.isEmpty || !multiEdits.isEmpty
            || !unifiedDiff.isEmpty || !movePath.isEmpty
    }

    private var statusText: String {
        guard let result else { return "执行中" }
        if result.isError {
            let text = result.text
            return (text.contains("haven't granted") || text.contains("permission")) ? "等待授权" : "失败"
        }
        if kind == "add" { return "已新增" }
        if kind == "delete" { return "已删除" }
        if !movePath.isEmpty { return "已移动" }
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
                    ForEach(Array(multiEdits.enumerated()), id: \.offset) { index, edit in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("第 \(index + 1) 处修改")
                                .font(.wand(size: 10, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                            if !edit.old.isEmpty {
                                diffColumn(label: "旧", text: edit.old, prefix: "- ", tint: Theme.danger)
                            }
                            if !edit.new.isEmpty {
                                diffColumn(label: "新", text: edit.new, prefix: "+ ", tint: chatSuccess)
                            }
                        }
                    }
                    if !unifiedDiff.isEmpty {
                        unifiedDiffBlock(unifiedDiff)
                    }
                    if !movePath.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("移动到")
                                .font(.wand(size: 10, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                            Text(movePath)
                                .font(.wand(size: 11, design: .monospaced))
                                .foregroundColor(Theme.codex)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Theme.codex.opacity(0.08))
                                )
                        }
                    }
                    if !hasDiffBody, let result, !result.isError {
                        Text(diffUnavailableReason ?? "Codex 已返回文件变更状态，但本次事件未包含差异正文。")
                            .font(.wand(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let result, result.isError, !result.text.isEmpty {
                        Text(result.text.count > 600 ? String(result.text.prefix(600)) + "…" : result.text)
                            .font(.wand(size: 11, design: .monospaced))
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
            // 默认只显示摘要行；运行状态不再强制展开具体 diff。
            if !initialized {
                expanded = initiallyExpanded
                initialized = true
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(WandMotion.disclosure) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .frame(width: 22)
                Text(fileName)
                    .font(.wand(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(path)
                    .font(.wand(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.wand(size: 11, weight: .medium))
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
                    .font(.wand(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(prefix + (text.count > 2000 ? String(text.prefix(2000)) + "\n…（已截断）" : text))
                    .font(.wand(size: 12, design: .monospaced))
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

    private func unifiedDiffBlock(_ diff: String) -> some View {
        let clipped = diff.count > 16_000
            ? String(diff.prefix(16_000)) + "\n…（差异已截断）"
            : diff
        return VStack(alignment: .leading, spacing: 3) {
            Text("统一差异")
                .font(.wand(size: 10, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(coloredUnifiedDiff(clipped))
                    .font(.wand(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.background.opacity(0.6))
            )
        }
    }

    private func coloredUnifiedDiff(_ diff: String) -> AttributedString {
        let lines = diff.components(separatedBy: .newlines)
        var output = AttributedString()
        for (index, line) in lines.enumerated() {
            var value = AttributedString(line)
            if line.hasPrefix("@@") {
                value.foregroundColor = Theme.codex
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                value.foregroundColor = Theme.textSecondary
            } else if line.hasPrefix("+") {
                value.foregroundColor = chatSuccess
            } else if line.hasPrefix("-") {
                value.foregroundColor = Theme.danger
            } else {
                value.foregroundColor = Theme.textPrimary
            }
            output.append(value)
            if index < lines.count - 1 { output.append(AttributedString("\n")) }
        }
        return output
    }
}

// MARK: - 终端卡片（Bash，对齐 Web 端 inline-terminal）

private struct TerminalCard: View {
    @Environment(\.chatToolContentDidLoad) private var contentDidLoad
    @State private var fullInput: [String: JSONValue]
    @State private var sourceToolID: String
    @Environment(\.chatAPI) private var api
    @Environment(\.chatSessionID) private var sessionID

    let input: [String: JSONValue]
    let result: ToolResultInfo?
    var running = false
    var initiallyExpanded = false

    @State private var expanded = false
    @State private var appliedInitialExpansion = false
    @State private var outputText: String
    @State private var truncated: Bool
    @State private var loadingFullOutput = false
    @State private var outputLoadError: String?
    @State private var fullOutputTask: Task<Void, Never>?
    @State private var activeOutputRequestID: UUID?
    @State private var activeOutputRequestKey = ""

    init(
        input: [String: JSONValue],
        result: ToolResultInfo?,
        running: Bool = false,
        initiallyExpanded: Bool = false
    ) {
        self.input = input
        _fullInput = State(initialValue: input)
        _sourceToolID = State(initialValue: result?.toolUseId ?? "")
        self.result = result
        self.running = running
        self.initiallyExpanded = initiallyExpanded
        _outputText = State(initialValue: result?.text ?? "")
        _truncated = State(initialValue: result?.truncated == true)
    }

    private var command: String {
        fullInput["command"]?.stringValue ?? fullInput["cmd"]?.stringValue ?? ""
    }
    private var statusColor: Color {
        guard let result else { return Theme.brand }
        return result.isError ? Theme.danger : chatSuccess
    }
    // 终端卡固定深色，亮暗主题一致（对齐 Web）。
    private let termBg = Theme.terminalBackground
    private let termText = Theme.terminalText

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text("$ " + command)
                            .font(.wand(size: 12, design: .monospaced))
                            .foregroundColor(termText)
                            .textSelection(.enabled)
                    }
                    if let result, !outputText.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(outputText.count > 12_000
                                 ? String(outputText.prefix(12_000)) + "\n…（本页仅展示前 12000 字）"
                                 : outputText)
                                .font(.wand(size: 12, design: .monospaced))
                                .foregroundColor(result.isError ? Theme.terminalError : termText.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                    if truncated, result != nil {
                        fullOutputRow
                    }
                    if !outputText.isEmpty {
                        Button {
                            UIPasteboard.general.string = outputText
                        } label: {
                            Label("复制输出", systemImage: "doc.on.doc")
                                .font(.wand(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(termText.opacity(0.65))
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
        .onAppear {
            guard !appliedInitialExpansion else { return }
            expanded = initiallyExpanded
            appliedInitialExpansion = true
            if expanded, truncated { loadFullOutput() }
        }
        .onChange(of: result != nil) {
            if initiallyExpanded {
                withAnimation(WandMotion.disclosure) { expanded = true }
            }
        }
        .onChange(of: expanded) { _, open in
            if open, truncated, !loadingFullOutput { loadFullOutput() }
        }
        .onChange(of: toolResultMetadataToken(result)) { _, _ in
            cancelFullOutputLoad()
            if sourceToolID != (result?.toolUseId ?? "") {
                sourceToolID = result?.toolUseId ?? ""
                fullInput = input
                outputText = result?.text ?? ""
                truncated = result?.truncated == true
            }
            guard !(result?.truncated == true && !truncated && outputText.count >= (result?.text.count ?? 0)) else { return }
            outputText = result?.text ?? ""
            truncated = result?.truncated == true
            outputLoadError = nil
            if expanded, truncated { loadFullOutput() }
        }
        .onChange(of: input["command"]?.stringValue ?? input["cmd"]?.stringValue) { _, command in
            if command?.isEmpty == false { fullInput = input }
        }
        .onDisappear { cancelFullOutputLoad() }
    }

    private var fullOutputRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(outputLoadError ?? "输出过长，服务端已省略部分内容")
                .font(.wand(size: 10))
                .foregroundColor(outputLoadError == nil
                    ? termText.opacity(0.60)
                    : Theme.terminalError)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: loadFullOutput) {
                if loadingFullOutput {
                    ProgressView().controlSize(.small).tint(termText)
                } else {
                    Text(outputLoadError == nil ? "加载完整输出" : "重试")
                        .font(.wand(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(termText)
            .disabled(loadingFullOutput)
        }
    }

    private func loadFullOutput() {
        guard let api, let result, !sessionID.isEmpty, !result.toolUseId.isEmpty else {
            outputLoadError = "无法加载完整输出"
            return
        }
        fullOutputTask?.cancel()
        let requestID = UUID()
        let toolUseID = result.toolUseId
        let requestKey = "\(sessionID)\u{1F}\(toolUseID)"
        activeOutputRequestID = requestID
        activeOutputRequestKey = requestKey
        loadingFullOutput = true
        outputLoadError = nil
        fullOutputTask = Task { @MainActor in
            defer {
                if activeOutputRequestID == requestID {
                    loadingFullOutput = false
                    activeOutputRequestID = nil
                    activeOutputRequestKey = ""
                    fullOutputTask = nil
                }
            }
            do {
                let loaded = try await api.fetchToolContent(id: sessionID, toolUseId: toolUseID)
                try Task.checkCancellation()
                guard activeOutputRequestID == requestID,
                      activeOutputRequestKey == requestKey else { return }
                guard loaded.toolUseId.isEmpty || loaded.toolUseId == toolUseID else {
                    outputLoadError = "服务端返回了不匹配的工具结果"
                    return
                }
                outputText = loaded.text
                if !loaded.input.isEmpty { fullInput = loaded.input }
                contentDidLoad?(loaded)
                truncated = false
            } catch {
                guard !Task.isCancelled,
                      activeOutputRequestID == requestID,
                      activeOutputRequestKey == requestKey else { return }
                outputLoadError = error.localizedDescription.isEmpty ? "加载失败，请重试" : error.localizedDescription
            }
        }
    }

    private func cancelFullOutputLoad() {
        fullOutputTask?.cancel()
        fullOutputTask = nil
        activeOutputRequestID = nil
        activeOutputRequestKey = ""
        loadingFullOutput = false
    }

    private var header: some View {
        Button {
            withAnimation(WandMotion.disclosure) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small).tint(termText)
                } else {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                }
                Text("$ " + (command.count > 80 ? String(command.prefix(77)) + "…" : command))
                    .font(.wand(size: 12, design: .monospaced))
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

/// 输入栏上方的悬浮任务状态：执行中 + 第 N/M 步 + 当前任务，点击展开任务列表。
struct TodoProgressBar: View {
    let todos: [TodoItem]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var completed: Int { todos.filter { $0.status == "completed" }.count }
    private var activeIndex: Int? { TodoItem.activeIndex(in: todos) }
    private var currentStep: Int { activeIndex.map { $0 + 1 } ?? min(completed + 1, todos.count) }
    private var activeTask: String {
        if let activeIndex {
            let active = todos[activeIndex]
            let label = (active.activeForm?.isEmpty == false) ? active.activeForm! : active.content
            if !label.isEmpty { return label }
        }
        return "准备中…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : WandMotion.detail) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    TodoRunningLabel()
                    Text("· 第 \(currentStep)/\(todos.count) 步")
                        .font(.wand(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.brand)
                    Text(activeTask)
                        .font(.wand(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "任务执行中，已完成 \(completed) 项，共 \(todos.count) 项，正在执行第 \(currentStep) 步：\(activeTask)"
            )
            .accessibilityHint(expanded ? "轻点收起待办列表" : "轻点展开待办列表")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { index, todo in
                        todoRow(todo, isActive: index == activeIndex)
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

    @ViewBuilder private func todoRow(_ todo: TodoItem, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                if todo.status == "completed" {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(chatSuccess)
                } else if isActive {
                    Circle()
                        .fill(Theme.brand)
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .stroke(Theme.textSecondary, lineWidth: 1)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 14, height: 17)
            Text(todo.content)
                .font(.wand(size: 12))
                .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)
                .strikethrough(todo.status == "completed", color: Theme.textSecondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // 进行中项高亮（对齐安卓 brandSoft 背景）。
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Theme.brand.opacity(0.1) : Color.clear)
        )
        .animation(reduceMotion ? nil : WandMotion.detail, value: isActive)
        .animation(reduceMotion ? nil : WandMotion.detail, value: todo.status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(todoStatusLabel(todo.status, isActive: isActive))：\(todo.content)")
    }

    private func todoStatusLabel(_ status: String, isActive: Bool) -> String {
        if status == "completed" { return "已完成" }
        return isActive ? "进行中" : "待处理"
    }
}

private struct TodoRunningLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            label(opacity: 1)
        } else {
            PhaseAnimator([false, true]) { dimmed in
                label(opacity: dimmed ? 0.72 : 1)
            } animation: { _ in
                WandMotion.activityPulse
            }
        }
    }

    private func label(opacity: Double) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.brand)
                .frame(width: 7, height: 7)
            Text("执行中")
                .font(.wand(size: 12, weight: .semibold))
                .foregroundColor(Theme.brand)
        }
        .opacity(opacity)
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.wand(size: 13, weight: .semibold))
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
struct PhotoLibraryPicker: UIViewControllerRepresentable {
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

// MARK: - 排队消息气泡条

/// 输入栏上方的「已排队 N 条消息」气泡条。折叠态只显示数量徽章，展开后逐条列出
/// 每条都能「立即发送(⚡)」「删除(×)」，整条尾部带「清空全部」。乐观更新由 ChatStore 负责。
private struct QueueBar: View {
    let items: [String]
    @Binding var expanded: Bool
    let inFlight: Bool
    let onPromote: (Int) -> Void
    let onDelete: (Int) -> Void
    let onEdit: (Int, String) -> Void
    let onClearAll: () -> Void
    @State private var editingIndex: Int?
    @State private var editedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded {
                VStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                        row(index: index, text: text)
                    }
                    clearAllButton
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .animation(WandMotion.disclosure, value: expanded)
        .animation(WandMotion.disclosure, value: items.count)
        .alert("编辑排队消息", isPresented: Binding(
            get: { editingIndex != nil }, set: { if !$0 { editingIndex = nil } }
        )) {
            TextField("消息", text: $editedText)
            Button("取消", role: .cancel) { editingIndex = nil }
            Button("保存") {
                if let index = editingIndex { onEdit(index, editedText) }
                editingIndex = nil
            }
        }
    }

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11))
                Text("已排队 \(items.count) 条消息")
                    .font(.wand(size: 12, weight: .medium))
                if inFlight {
                    Text("· 中断后立即发送")
                        .font(.wand(size: 10))
                        .foregroundColor(Theme.brand)
                }
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(Theme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起排队消息列表" : "展开排队消息列表")
    }

    private func row(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.wand(size: 13))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                editedText = text
                editingIndex = index
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑第 \(index + 1) 条")
            Button {
                onPromote(index)
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.brand))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("立即发送第 \(index + 1) 条")
            Button {
                onDelete(index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.danger)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.danger.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除第 \(index + 1) 条")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.background.opacity(0.5))
        )
    }

    private var clearAllButton: some View {
        Button(role: .destructive) {
            onClearAll()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                Text("清空全部")
                    .font(.wand(size: 11, weight: .semibold))
            }
            .foregroundColor(Theme.danger)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.danger.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct ConversationTurnScrubber: View {
    let itemCount: Int
    let currentItem: Int
    let currentPreview: String
    let onSelect: (Int, Bool) -> Void

    @State private var dragging = false
    @State private var lastEmittedIndex = -1

    private var displayedItem: Int {
        min(max(currentItem, 0), max(itemCount - 1, 0))
    }

    private var railHeight: CGFloat {
        CGFloat(min(max(itemCount * 5, 48), 240))
    }

    var body: some View {
        rail
            .overlay(alignment: .trailing) {
                if dragging && !currentPreview.isEmpty {
                    Text(currentPreview)
                        .font(.wand(size: 13))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minWidth: 120, maxWidth: 280, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.elevated.opacity(0.96))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Theme.border.opacity(0.55), lineWidth: 0.55)
                        )
                        .offset(x: -44)
                        .allowsHitTesting(false)
                }
            }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            ForEach(0..<itemCount, id: \.self) { index in
                let distance = abs(index - displayedItem)
                let width: CGFloat = {
                    switch distance {
                    case 0: return 30
                    case 1: return 16
                    case 2: return 11
                    default: return 7
                    }
                }()
                Capsule()
                    .fill(
                        distance == 0
                            ? Theme.brand.opacity(0.88)
                            : Theme.textMuted.opacity(0.25)
                    )
                    .frame(width: width, height: distance == 0 ? 3 : 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(index, true) }
            }
        }
        .scaleEffect(dragging ? 1.18 : 1, anchor: .trailing)
        .animation(WandMotion.scroll, value: dragging)
        .animation(WandMotion.scroll, value: displayedItem)
        .frame(width: 40, height: railHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    dragging = true
                    let ratio = itemCount == 0 ? 0 : value.location.y / max(railHeight, 1)
                    let index = min(max(Int(ratio * CGFloat(itemCount)), 0), itemCount - 1)
                    if index != lastEmittedIndex {
                        lastEmittedIndex = index
                        onSelect(index, false)
                    }
                }
                .onEnded { _ in
                    dragging = false
                    lastEmittedIndex = -1
                }
        )
    }
}

struct SearchableChoiceItem: Identifiable, Hashable {
    let id: String
    let label: String
}

struct SearchableChoiceSection: Identifiable {
    let id: String
    var title: String? = nil
    let items: [SearchableChoiceItem]
    let selectedId: String
    var searchable: Bool = false
}

struct SearchableChoiceSheet: View {
    let title: String
    var searchPrompt: String = "搜索"
    let sections: [SearchableChoiceSection]
    let onSelect: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var visibleSections: [SearchableChoiceSection] {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return sections.compactMap { section in
            if searching && !section.searchable { return nil }
            let items = section.searchable
                ? section.items.filter { matchesModelKeyword(query, id: $0.id, label: $0.label) }
                : section.items
            return SearchableChoiceSection(
                id: section.id,
                title: section.title,
                items: items,
                selectedId: section.selectedId,
                searchable: section.searchable
            )
        }
    }

    private var allowsSearch: Bool {
        sections.contains(where: \.searchable)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleSections) { section in
                    Section {
                        if section.items.isEmpty {
                            Text(allowsSearch ? "没有匹配的\(title)" : "没有可选项")
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            ForEach(section.items) { item in
                                Button {
                                    onSelect(section.id, item.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(item.label)
                                            .foregroundColor(Theme.textPrimary)
                                        Spacer()
                                        if item.id == section.selectedId {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(Theme.brand)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        if let title = section.title {
                            Text(title)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if allowsSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Theme.textMuted)
                        TextField(searchPrompt, text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}
