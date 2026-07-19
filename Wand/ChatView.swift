import Combine
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 原生聊天视图：结构化消息渲染 + 原生输入栏 + 权限审批卡片。
/// 输入栏放在底部 overlay；键盘避让不走系统自动机制
/// （NavigationView push 页面 + 多行 TextField 组合下系统避让会漏抬、键盘盖住输入栏），
/// 而是 .ignoresSafeArea(.keyboard) 关掉系统行为，由 KeyboardObserver
/// 监听键盘 frame 手动抬升，行为确定。
private struct ChatBottomBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SubagentShelfHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum ChatScrollMode {
    case stickToBottom
    case manual
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

private struct ChatSessionIDEnvironmentKey: EnvironmentKey {
    static let defaultValue = ""
}

private extension EnvironmentValues {
    var chatAPI: WandAPI? {
        get { self[ChatAPIEnvironmentKey.self] }
        set { self[ChatAPIEnvironmentKey.self] = newValue }
    }

    var chatSessionID: String {
        get { self[ChatSessionIDEnvironmentKey.self] }
        set { self[ChatSessionIDEnvironmentKey.self] = newValue }
    }
}

struct ChatView: View {
    private let sessionId: String
    private let api: WandAPI

    @StateObject private var store: ChatStore
    @StateObject private var keyboard = KeyboardObserver()
    @StateObject private var speech = SpeechRecognizerService()
    @State private var draft = ""
    @State private var showQuickCommit = false
    @State private var scrollMode: ChatScrollMode = .stickToBottom
    @State private var voicePressed = false
    @State private var voiceCanceling = false
    @State private var draftNeedsExpanded = false
    @StateObject private var attachments: ComposerAttachmentController
    @State private var gitStatus: GitStatusResult?
    @StateObject private var quickCommitFeedback = QuickCommitFeedbackController()
    /// 轻点 vs 按住的计时器：按满阈值才开始录音，阈值内松手按轻点处理。
    @State private var voiceHoldWork: DispatchWorkItem?
    /// 停止任务二次确认弹窗开关：点停止按钮先弹确认，避免误触中断正在跑的任务。
    @State private var showStopConfirm = false
    /// 排队消息气泡条是否展开成列表（默认折叠成「已排队 N 条」徽章）。
    @State private var queueBarExpanded = false
    /// 历史折叠记录绝对 turn 下标。prepend 更早页会同时改变 loadedOffset 和局部下标，
    /// 但两者之和不变，因此分页不会把用户刚展开的历史重新收起。
    @State private var expandedHistoryBoundaryAbsolute: Int?
    /// 用户手动收起的助手回复，使用绝对 turn 下标避免历史 prepend 后串状态。
    @State private var collapsedAssistantTurns: Set<Int> = []
    /// 用户手动展开的历史回复；其他历史回复默认逐条收起。
    @State private var expandedHistoricalAssistantTurns: Set<Int> = []
    /// 连续工具 / 思考 / 终端活动的详情 sheet。
    @State private var activitySheet: ActivitySheetItem?
    /// 底部 overlay 的实际占位高度。ChatView 不使用 safeAreaInset 放输入栏，
    /// 避免 SwiftUI 键盘避让和 KeyboardObserver 手动抬升叠加。
    @State private var bottomBarHeight: CGFloat = 0
    @State private var subagentShelfHeight: CGFloat = 0
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
    @FocusState private var inputFocused: Bool

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
        _store = StateObject(wrappedValue: ChatStore(sessionId: sessionId, api: api))
        _attachments = StateObject(wrappedValue: ComposerAttachmentController(sessionId: sessionId, api: api))
    }

    var body: some View {
        GeometryReader { root in
            ZStack(alignment: .bottom) {
            WandAmbientBackground()

                mainContent
                    .padding(.bottom, bottomBarHeight + subagentShelfHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dismissKeyboardOnTap()

                VStack(spacing: 0) {
                    if shouldShowSubagentShelf {
                        SubagentActivityShelf(
                            activities: subagentActivities,
                            isResponding: store.isResponding,
                            baseURL: store.api.baseURL,
                            askSelections: store.askUserSelections,
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
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SubagentShelfHeightKey.self,
                                    value: proxy.size.height + 6
                                )
                            }
                        )
                    }
                    bottomBarOverlay(safeBottom: root.safeAreaInsets.bottom)
                }
                .onPreferenceChange(SubagentShelfHeightKey.self) { height in
                    let next = shouldShowSubagentShelf ? height : 0
                    if abs(next - subagentShelfHeight) > 0.5 {
                        subagentShelfHeight = next
                    }
                }
                .onChange(of: shouldShowSubagentShelf) { _, showing in
                    if !showing { subagentShelfHeight = 0 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 点消息区任意空白处收起键盘；输入栏作为底部 overlay 不受影响，
        // 点发送 / 权限按钮不会误收。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                providerBadge
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .principal) {
                navigationStatus
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .navigationBarTrailing) {
                GitChangesToolbarButton(status: gitStatus, phase: quickCommitFeedback.phase) {
                    showQuickCommit = true
                }
            }
        }
        // 关掉系统键盘避让，统一交给 KeyboardObserver 手动抬升（见 bottomBar），
        // 避免「系统抬一次 + 手动抬一次」叠加或两边都不抬的不确定行为。
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
        .sheet(item: $activitySheet) { sheet in
            ActivityDetailSheet(
                group: sheet.group,
                baseURL: api.baseURL,
                isLastTurn: sheet.turnIndex == store.messages.count - 1,
                isResponding: store.isResponding,
                askSelections: store.askUserSelections,
                onAskToggle: { toolUseId, qIdx, optIdx, multi in
                    store.toggleAskOption(
                        toolUseId: toolUseId, questionIndex: qIdx,
                        optionIndex: optIdx, multiSelect: multi
                    )
                },
                onAskSubmit: { toolUseId, answerText in
                    activitySheet = nil
                    expandedHistoryBoundaryAbsolute = nil
                    scrollMode = .stickToBottom
                    store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled()
        }
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
        .onAppear {
            attachments.setToastHandler { store.toast = $0 }
            store.start()
            refreshGitStatus()
        }
        .onChange(of: showQuickCommit) { _, showing in
            if !showing { refreshGitStatus() }
        }
        .onDisappear { store.shutdown() }
        .onChange(of: scenePhase) { _, newPhase in
            wlog("session", "scenePhase=\(newPhase) session=\(sessionId)")
            if newPhase == .active { store.handleEnterForeground() }
            else if newPhase == .background { store.handleEnterBackground() }
        }
        .overlay(alignment: .top) { connectionBanner }
        .animation(.easeInOut(duration: 0.2), value: store.connected)
        .overlay(alignment: .top) { toastView }
        .environment(\.cardExpandDefaults, store.cardDefaults)
        .environment(\.chatAPI, api)
        .environment(\.chatSessionID, sessionId)
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
        !showQuickCommit
            && !attachments.showFileImporter
            && !attachments.showPhotoPicker
            && !showStopConfirm
            && activitySheet == nil
    }

    @ViewBuilder private var mainContent: some View {
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
                        // 用户浏览到顶部时自动加载更早消息。哨兵不再要求点击；每次 prepend 后
                        // 会恢复原阅读锚点，使哨兵退出视口，避免一次到顶连续翻完全部历史。
                        if store.canLoadEarlier {
                            HStack(spacing: 8) {
                                Spacer()
                                if store.loadingEarlier {
                                    ProgressView().controlSize(.small).tint(Theme.brand)
                                    Text("正在加载更早消息…")
                                        .font(.system(size: 12, weight: .medium))
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
                        }
                        if store.isResponding {
                            LiveTurnStatusRow(
                                usage: store.messages.last?.role == "assistant"
                                    ? store.messages.last?.usage
                                    : nil,
                                taskTitle: store.currentTaskTitle
                            )
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
                                scrollMode = .manual
                                requestEarlierMessagesIfNeeded()
                            }
                        }
                )
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
                    scrollToActiveTarget(proxy)
                }
                .onChange(of: store.loading) { _, loading in
                    if !loading { scrollToActiveTarget(proxy) }
                }
                .onChange(of: keyboard.lift) {
                    scrollToActiveTarget(proxy)
                }
                .onChange(of: bottomBarHeight) {
                    // 聚焦、语音模式、附件和权限卡都会改变输入区高度。
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
            let historical = turnIndex < lastUserTurnIndex
            let collapsed = historical
                ? !expandedHistoricalAssistantTurns.contains(absoluteTurn)
                : collapsedAssistantTurns.contains(absoluteTurn)
            AssistantReplyDisclosure(
                preview: preview,
                collapsed: collapsed,
                onToggle: {
                    if collapsed {
                        if historical {
                            expandedHistoricalAssistantTurns.insert(absoluteTurn)
                        } else {
                            collapsedAssistantTurns.remove(absoluteTurn)
                        }
                    } else {
                        if historical {
                            expandedHistoricalAssistantTurns.remove(absoluteTurn)
                        } else {
                            collapsedAssistantTurns.insert(absoluteTurn)
                        }
                    }
                }
            )
        case .turn(let index, let turn):
            let turnView = TurnView(
                turn: turn,
                baseURL: store.api.baseURL,
                isLastTurn: index == store.messages.count - 1,
                isResponding: store.isResponding,
                compactUser: false,
                askSelections: store.askUserSelections,
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
                askSelections: store.askUserSelections,
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
                    && tools.contains { $0.result == nil }
            )
        case .activityGroup(let turnIndex, let group, let id):
            if store.cardDefaults.toolGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(identifiedDisplayItems(group.items)) { identified in
                        AssistantItemView(
                            item: identified.item,
                            baseURL: store.api.baseURL,
                            isLastTurn: turnIndex == store.messages.count - 1,
                            isResponding: store.isResponding,
                            askSelections: store.askUserSelections,
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
                    }
                }
            } else {
                ActivitySummaryRow(group: group) {
                    activitySheet = ActivitySheetItem(id: id, turnIndex: turnIndex, group: group)
                }
            }
        case .usageSummary(_, let usage, let isLive):
            UsageSummaryRow(usage: usage, isLive: isLive)
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

    private var shouldShowSubagentShelf: Bool {
        store.isStructured && (store.isResponding || !subagentActivities.isEmpty)
    }

    private var groupedMessageItems: [MessageDisplayItem] {
        let base = collapseActivityItems(
            flattenAssistantTurns(
                groupExplorationTurns(store.messages),
                liveTurnIndex: store.isResponding ? latestAssistantTurnIndex : nil
            ),
            latestTurnIndex: latestAssistantTurnIndex ?? -1,
            isResponding: store.isResponding
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
            if turnIndex < lastUserTurnIndex {
                return expandedHistoricalAssistantTurns.contains(absoluteTurn)
            }
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
        .padding(.bottom, 12 + subagentShelfHeight)
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
                withAnimation(.easeOut(duration: 0.22)) {
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
                withAnimation(.easeOut(duration: 0.22)) { scroll() }
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

    private var providerTint: Color {
        switch currentProvider {
        case .codex: return Theme.codex
        case .claude, .opencode, .grok, .qoder: return Theme.brand
        }
    }

    private var sessionLaunchPanel: some View {
        let provider = currentProvider
        let tint = providerTint
        return VStack(spacing: 14) {
            BrandLogo(provider: store.snapshot?.provider, color: tint.opacity(0.94))
                .frame(width: 36, height: 36)
            Text("开始新的 \(provider.title) 对话")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("输入消息，让它帮你完成任务")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            launchContextControls
        }
        .padding(.horizontal, 32)
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
        }
    }

    private var launchModelMenu: some View {
        launchOptionMenu(
            title: "模型",
            value: launchModelLabel,
            icon: "cpu"
        ) {
            modelButton(id: nil, label: "默认 · \(defaultModelLabel)")
            ForEach(store.availableModels.filter { $0.id != "default" }) { model in
                modelButton(id: model.id, label: model.label)
            }
        }
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

    private func launchOptionMenu<Content: View>(
        title: String,
        value: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    Text(value)
                        .font(.system(size: 12, weight: .semibold))
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
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("轻点选择\(title)")
    }

    private func modelButton(id: String?, label: String) -> some View {
        Button {
            store.setModel(id)
        } label: {
            let currentModel = store.selectedModel
            let selected = id == nil
                ? (currentModel == nil || currentModel?.isEmpty == true || currentModel == "default")
                : currentModel == id
            if selected {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var thinkingLevels: [ThinkingEffortOption] {
        thinkingEffortOptions(
            provider: store.snapshot?.provider ?? "claude",
            selectedModel: store.selectedModel,
            defaultModel: store.defaultModel,
            models: store.availableModels
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

    /// 顶栏左侧 provider 标识：与会话列表 / Android 一致，仅展示透明底品牌 logo。
    private var providerBadge: some View {
        let provider = currentProvider
        let tint = providerTint
        return BrandLogo(provider: store.snapshot?.provider, color: tint.opacity(0.94))
            .frame(width: 18, height: 18)
            .frame(width: 26, height: 26)
            .accessibilityLabel(provider.title)
    }

    private var navigationStatus: some View {
        VStack(spacing: 0) {
            Text(navigationStatusTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190)
                .topicTitleRhythm(store.titleGenerating)
            if let cwd = store.snapshot?.cwd, !cwd.isEmpty {
                WandPathRevealText(path: cwd, fontSize: 8, color: Theme.textMuted, staggerWindow: 0)
                    .frame(width: 190)
            }
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

    private func bottomBarOverlay(safeBottom: CGFloat) -> some View {
        bottomBar
            .padding(.bottom, safeBottom)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChatBottomBarHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
            .onPreferenceChange(ChatBottomBarHeightKey.self) { height in
                if abs(height - bottomBarHeight) > 0.5 {
                    bottomBarHeight = height
                }
            }
            .animation(.easeOut(duration: 0.2), value: keyboard.lift)
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
                QueueBar(
                    items: store.queuedMessages,
                    expanded: $queueBarExpanded,
                    inFlight: store.queueInFlight,
                    onPromote: { store.promoteQueued(index: $0) },
                    onDelete: { store.deleteQueued(index: $0) },
                    onClearAll: { store.clearQueued() }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            inputBar
        }
        // 手动键盘避让：观察器只返回键盘在底部安全区上方的高度。
        .padding(.bottom, keyboard.lift)
        .animation(.easeInOut(duration: 0.2), value: store.pendingEscalation)
    }

    /// 聚焦或正在按住语音时展开；失焦后草稿和附件保留。
    /// 对齐 Codex App：默认是一条胶囊，点进去（聚焦）才长出底部控制行。
    private var inputExpanded: Bool {
        composerShouldExpand(
            focused: inputFocused,
            voiceMode: voicePressed,
            contentNeedsSpace: draftNeedsExpanded || !attachments.attachments.isEmpty
        )
    }

    private var inputBar: some View {
        NativeComposerShell(
            expanded: inputExpanded,
            focused: inputFocused,
            onFocusInput: { inputFocused = true },
            collapsedLeading: { composerActionsMenu },
            inputContent: { composerInputContent },
            collapsedTrailing: { trailingButtons },
            expandedControls: { controlRow }
        )
        .confirmationDialog(
            "确定要停止当前正在运行的任务吗？",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("停止", role: .destructive) { store.stopResponding() }
            Button("取消", role: .cancel) {}
        }
    }

    /// 文本框只处理系统文本编辑；语音手势由外侧独立按钮承载。
    @ViewBuilder private var composerInputContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.attachments.isEmpty {
                PendingAttachmentsPreview(
                    baseURL: api.baseURL,
                    attachments: attachments.attachments,
                    onRemove: attachments.remove
                )
            }
            growingTextField
                .focused($inputFocused)
                .padding(.leading, inputExpanded ? 6 : 2)
                .padding(.trailing, inputExpanded ? 4 : 0)
                .padding(.vertical, inputExpanded ? 4 : 2)
                .frame(minHeight: inputExpanded ? 32 : 34)
                .contentShape(Rectangle())
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ComposerInputHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                .onPreferenceChange(ComposerInputHeightPreferenceKey.self) { height in
                    draftNeedsExpanded = !draft.isEmpty && height > 36
                }
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
            .gesture(voiceTapOrHoldGesture(onTap: { inputFocused = true }))
            .accessibilityLabel("语音输入")
            .accessibilityValue(voicePressed ? "正在录音" : "长按录音")
    }

    /// 展开态底部控制行：+ / 模式徽标 / 模型·思考徽标 / 发送·停止。
    /// 把原本散落在右上角的会话设置（模型 + 思考深度）+ 模式开关全部收拢到这里。
    private var controlRow: some View {
        HStack(spacing: ComposerMetrics.actionSpacing) {
            ViewThatFits(in: .horizontal) {
                controlChipGroup(compact: false)
                controlChipGroup(compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            trailingButtons
        }
    }

    private func controlChipGroup(compact: Bool) -> some View {
        HStack(spacing: ComposerMetrics.actionSpacing) {
            composerActionsMenu
            if store.isStructured {
                modeChip(compact: compact)
                modelThinkingChip(compact: compact)
            }
        }
    }

    /// 发送 / 停止按钮组：
    /// - 运行中且无草稿 → 唯一按钮是白底停止（对齐 Codex 的白圆黑方块）；
    /// - 有草稿 → 发送按钮（运行中时左侧追加一个红色停止，可一边排队一边停）。
    @ViewBuilder private var trailingButtons: some View {
        if store.isResponding && !canSend {
            composerVoiceButton
            stopButtonPrimary
        } else {
            if store.isResponding {
                stopButtonSecondary
            }
            composerVoiceButton
            sendButton
        }
    }

    private var stopButtonPrimary: some View {
        Button { showStopConfirm = true } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.surface)
                .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
                .background(Circle().fill(Theme.textPrimary))
                .overlay(Circle().stroke(Theme.border.opacity(0.25), lineWidth: 0.5))
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .accessibilityLabel("停止任务")
    }

    private var stopButtonSecondary: some View {
        Button { showStopConfirm = true } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
                .background(Circle().fill(Theme.danger))
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .accessibilityLabel("停止任务")
    }

    private var sendButton: some View {
        Button(action: sendDraft) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(canSend ? Theme.surface : Theme.textSecondary.opacity(0.55))
                .frame(width: ComposerMetrics.actionVisualSize, height: ComposerMetrics.actionVisualSize)
                .background(
                    Circle().fill(canSend ? Theme.textPrimary : Theme.textSecondary.opacity(0.16))
                )
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("发送")
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

    private static func modeIcon(_ id: String) -> String {
        switch id {
        case "managed": return "sparkles"
        case "full-access": return "lock.open.fill"
        case "auto-edit": return "pencil"
        case "native": return "terminal"
        default: return "lock"
        }
    }

    /// 高权限模式（托管 / 全权限）用橙色提示，其余用次要色。
    private var modeTint: Color {
        (store.mode == "full-access" || store.mode == "managed") ? .orange : Theme.textSecondary
    }

    private func modeChip(compact _: Bool = false) -> some View {
        let provider = currentProvider
        let isCodex = provider == .codex
        let supportedModeIDs = provider.supportedModeIDs
        let currentModeLabel = Self.modeLabel(store.mode)
        return Menu {
            ForEach(Self.sessionModes.filter { supportedModeIDs.contains($0.id) }, id: \.id) { option in
                Button {
                    store.setMode(option.id)
                } label: {
                    if store.mode == option.id {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            chipLabel(
                icon: Self.modeIcon(store.mode),
                text: currentModeLabel,
                tint: modeTint,
                showsText: false,
                maxTextWidth: 0
            )
        }
        .disabled(isCodex)
        .buttonStyle(.plain)
        .accessibilityLabel(
            isCodex
                ? "执行模式：\(currentModeLabel)，Codex 会话固定"
                : "执行模式：\(currentModeLabel)"
        )
    }

    private func modelThinkingChip(compact: Bool = false) -> some View {
        Menu {
            Section("模型") {
                modelButton(id: nil, label: "默认 · \(defaultModelLabel)")
                ForEach(store.availableModels.filter { $0.id != "default" }) { model in
                    modelButton(id: model.id, label: model.label)
                }
            }
            Section("思考深度") {
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
        } label: {
            chipLabel(
                icon: "cpu",
                text: modelThinkingText,
                tint: thinkingTint,
                showsText: !compact,
                maxTextWidth: compact ? 94 : 140
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("模型与思考深度")
        .accessibilityValue("模型 \(shortModelLabel)，思考深度 \(thinkingLabel(store.thinkingEffort))")
        .accessibilityHint("轻点选择模型或思考深度")
    }

    private var modelThinkingText: String {
        let model = shortModelLabel
        return "\(model) · \(thinkingShortLabel(store.thinkingEffort))"
    }

    private var thinkingTint: Color {
        switch store.thinkingEffort {
        case "standard": return .green
        case "deep": return .orange
        case "max": return Theme.danger
        default: return Theme.brand
        }
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

    /// 控制行通用胶囊徽标：图标 + 文字 + 弱色底。
    private func chipLabel(
        icon: String,
        text: String,
        tint: Color,
        showsText: Bool = true,
        maxTextWidth: CGFloat = 140
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            if showsText {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxTextWidth)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
        }
        .foregroundColor(tint)
        .padding(.horizontal, showsText ? 9 : 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 1))
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
        Menu {
            Button {
                attachments.showPhotoPicker = true
            } label: {
                Label("从相册选择", systemImage: "photo.on.rectangle")
            }
            .disabled(attachments.isUploading)

            Button {
                attachments.showFileImporter = true
            } label: {
                Label("从文件选择", systemImage: "paperclip")
            }
            .disabled(attachments.isUploading)
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
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .accessibilityLabel("更多操作")
    }

    /// 多行自增高输入框（iOS 26+ 唯一支持形态）。
    private var growingTextField: some View {
        TextField(composerPlaceholder, text: $draft, axis: .vertical)
            .lineLimit(1...5)
            .font(.system(size: 16))
            .foregroundColor(Theme.textPrimary)
            .tint(Theme.brand)
            .submitLabel(.send)
            .wandSubmitOnHardwareReturn(isEnabled: { keyboardShortcutsActive && canSend }, perform: sendDraft)
    }

    private var composerPlaceholder: String {
        if voicePressed {
            return voiceCanceling ? "松开手指，取消输入" : "松开结束 · 上滑取消"
        }
        return "输入消息"
    }

    private var canSend: Bool {
        // 结构化会话不存在「已结束」终止态：停止只回到 idle，真失败也能再发消息触发
        // 服务端 --resume 续接。所以发送只看草稿是否非空，不再被 sessionEnded 卡死。
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.attachments.isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = buildAttachmentPrompt(attachments.attachments, body: draft)
        draft = ""
        attachments.attachments.removeAll()
        scrollMode = .stickToBottom
        store.send(text: text)
        // 清空 draft 后，权限卡/todo bar 的插入移除可能让 @FocusState 丢焦点、键盘收起，
        // 用户得再点一次输入框才能继续。发送后主动保持焦点。
        inputFocused = true
    }

    // MARK: - 按住说话（端侧语音识别）

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
        draft = appendingVoiceTranscript(text, to: draft)
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
    /// assistant turn 的统一展开/收起入口；正文仍保持块级懒加载。
    case assistantHeader(turnIndex: Int, preview: String)
    /// 摊平后的单个 assistant 内容块（见 flattenAssistantTurns / AssistantItemView）。
    case assistantItem(turnIndex: Int, item: DisplayItem)
    case explorationGroup(tools: [ExplorationToolItem], lastTurnIndex: Int)
    case activityGroup(turnIndex: Int, group: ActivityGroup, id: String)
    /// 当前 assistant turn 的 token / cost 摘要。
    case usageSummary(turnIndex: Int, usage: TurnUsage?, isLive: Bool)
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
        let keys = tools.map { !$0.id.isEmpty ? $0.id : ($0.result?.toolUseId ?? $0.name) }
        return "exploration:\(keys.joined(separator: "|"))"
    case .activityGroup(_, let group, _):
        return "activity:\(absoluteTurn):\(group.items.map(displayItemIdentity).joined(separator: "|"))"
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

private func displayItemIdentity(_ item: DisplayItem) -> String {
    switch item {
    case .tool(let id, let name, _, _, _, let result):
        let key = !id.isEmpty ? id : (result?.toolUseId ?? "")
        return key.isEmpty ? "tool:\(name)" : "tool:\(key)"
    case .explorationGroup(let tools):
        let keys = tools.map { !$0.id.isEmpty ? $0.id : ($0.result?.toolUseId ?? $0.name) }
        return "exploration:\(keys.joined(separator: "|"))"
    case .plain(let block):
        switch block {
        case .toolUse(let id, let name, _, _, _):
            return id.isEmpty ? "tool-use:\(name)" : "tool-use:\(id)"
        case .toolResult(let id, _, _, _, _):
            return id.isEmpty ? "tool-result" : "tool-result:\(id)"
        case .text(let text, _):
            return "text:\(text.hashValue)"
        case .thinking(let text, _):
            return "thinking:\(text.hashValue)"
        case .unknown(let type, let payload):
            return "unknown:\(type):\(payload.hashValue)"
        }
    }
}

private struct ActivityGroup {
    let summary: String
    let items: [DisplayItem]
    let running: Bool
}

private struct ActivitySheetItem: Identifiable {
    let id: String
    let turnIndex: Int
    let group: ActivityGroup
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
            case .toolResult(_, _, let isError, _, let subagent):
                if isError { errors += 1 }
                if let tid = subagent?.taskId, !tid.isEmpty { agentIds.insert(tid) }
            case .text(_, let subagent), .thinking(_, let subagent):
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
    isResponding: Bool
) -> [MessageDisplayItem] {
    var out: [MessageDisplayItem] = []
    var pending: [(turnIndex: Int, item: DisplayItem)] = []
    var groupOrdinal = 0

    func flushPending() {
        guard !pending.isEmpty else { return }
        let turnIndex = pending.last?.turnIndex ?? -1
        let displayItems = pending.map(\.item)
        let running = displayItems.contains {
            isActivityItemRunning($0, turnIndex: turnIndex, latestTurnIndex: latestTurnIndex, isResponding: isResponding)
        }
        let group = ActivityGroup(
            summary: activitySummary(displayItems, running: running),
            items: displayItems,
            running: running
        )
        out.append(.activityGroup(
            turnIndex: turnIndex,
            group: group,
            id: "activity-\(turnIndex)-\(groupOrdinal)"
        ))
        groupOrdinal += 1
        pending.removeAll(keepingCapacity: true)
    }

    for item in items {
        if case .assistantItem(let turnIndex, let displayItem) = item {
            if shouldSkipActivityItem(displayItem) {
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
    return out
}

private func shouldSkipActivityItem(_ item: DisplayItem) -> Bool {
    guard case .tool(let id, let name, _, let input, let subagent, _) = item else { return false }
    return subagent?.taskId == id
        && (name == "Task" || name == "Agent" || input["subagent_type"]?.stringValue?.isEmpty == false)
}

private func isCollapsibleActivityItem(_ item: DisplayItem) -> Bool {
    switch item {
    case .plain(let block):
        if case .text = block { return false }
        if case .thinking = block { return false }
        if case .unknown = block { return false }
        return true
    case .explorationGroup:
        return true
    case .tool(_, let name, _, let input, _, _):
        if name == "AskUserQuestion" { return false }
        if name == "Read", isReadImageTool(name: name, input: input) { return false }
        return true
    }
}

private func isActivityItemRunning(
    _ item: DisplayItem,
    turnIndex: Int,
    latestTurnIndex: Int,
    isResponding: Bool
) -> Bool {
    guard isResponding, turnIndex == latestTurnIndex else { return false }
    switch item {
    case .tool(_, _, _, _, _, let result):
        return result == nil
    case .explorationGroup(let tools):
        return tools.contains { $0.result == nil }
    case .plain(let block):
        if case .thinking = block { return true }
        return false
    }
}

private func activityTools(_ items: [DisplayItem]) -> [ExplorationToolItem] {
    items.flatMap { item -> [ExplorationToolItem] in
        switch item {
        case .tool(let id, let name, let description, let input, let subagent, let result):
            return [ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            )]
        case .explorationGroup(let tools):
            return tools
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
        case .toolResult(_, _, let isError, _, _):
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

private func activityToolSummary(description: String?, input: [String: JSONValue]) -> String {
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
        case .explorationGroup(let group):
            tools.append(contentsOf: group)
        case .tool(let id, let name, let description, let input, let subagent, let result)
            where isGroupableExplorationTool(name: name, input: input):
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
        if resultIndex >= 0, case .toolResult(let resultID, let text, let isError, let truncated, _) = content[resultIndex] {
            consumed.insert(resultIndex)
            result = ToolResultInfo(
                toolUseId: resultID.isEmpty ? id : resultID,
                text: text,
                isError: isError,
                truncated: truncated
            )
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
           isGroupableExplorationTool(name: name, input: input) {
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

/// 探索分组判定：是探索工具，且不是 Read 读图（后者要单独显示缩略图）。
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

    /// 解析上传附件前缀：图片渲染缩略图、其余渲染文件块，正文保持在下方气泡。
    private var parsedUser: ParsedUserMessage {
        parseUserAttachmentMessage(userText)
    }

    private var userBubble: some View {
        let parsed = parsedUser
        let canCompact = compactUser && shouldCompactUserBody(parsed.body)
        let collapsed = canCompact && !userExpanded
        return VStack(alignment: .trailing, spacing: 6) {
            if !parsed.attachmentPaths.isEmpty {
                attachmentsView(parsed.attachmentPaths)
            }
            if !parsed.body.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(parsed.body)
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .lineLimit(collapsed ? 2 : nil)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                        if canCompact {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    userExpanded.toggle()
                                }
                            } label: {
                                Text(collapsed ? "展开" : "收起")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.86))
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
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        HStack(spacing: 3) {
                            Text(chip.0)
                            Text(chip.1)
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 13))
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

private struct ActivitySummaryRow: View {
    let group: ActivityGroup
    let onOpen: () -> Void

    private var tint: Color {
        group.running ? Theme.brand : Theme.textSecondary
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: activityIconName(group.items))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 20)
                Text(group.summary)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary.opacity(0.8))
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ActivityDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: ActivityGroup
    var baseURL: URL? = nil
    var isLastTurn = false
    var isResponding = false
    var askSelections: [String: AskUserSelectionState] = [:]
    var onAskToggle: (String, Int, Int, Bool) -> Void = { _, _, _, _ in }
    var onAskSubmit: (String, String) -> Void = { _, _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("执行详情")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text(group.summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.background.opacity(0.7)))
                        .frame(maxWidth: 220, alignment: .trailing)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭执行详情")
                }
                ForEach(identifiedDisplayItems(group.items)) { identified in
                    AssistantItemView(
                        item: identified.item,
                        baseURL: baseURL,
                        isLastTurn: isLastTurn,
                        isResponding: isResponding,
                        askSelections: askSelections,
                        onAskToggle: onAskToggle,
                        onAskSubmit: onAskSubmit
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .background { WandAmbientBackground() }
    }
}

private func activityIconName(_ items: [DisplayItem]) -> String {
    if let firstTool = activityTools(items).first {
        let kind = activityKind(firstTool.name)
        switch kind {
        case "read": return "doc.text.magnifyingglass"
        case "command": return "terminal"
        case "search": return "magnifyingglass"
        case "edit": return "pencil"
        case "web": return "globe"
        case "todo": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }
    if let first = items.first, case .plain(.thinking) = first {
        return "brain"
    }
    return "wrench.and.screwdriver"
}

private struct SubagentActivityShelf: View {
    let activities: [SubagentActivity]
    let isResponding: Bool
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
        if activities.isEmpty { return isResponding ? "正在协调子任务" : "暂无子任务" }
        if runningCount > 0 { return "\(runningCount) 个正在运行" }
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
                if isResponding && activities.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.brand)
                        .accessibilityLabel("正在协调子任务")
                }
            }

            if !activities.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activities, id: \.id) { activity in
                            activityChip(activity)
                        }
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
        .onAppear { reconcileSelection() }
        .onChange(of: activities.map(\.id)) { _, _ in reconcileSelection() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("子 Agent 活动，\(summary)")
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
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded = expanded }
        }
    }

    private func reconcileSelection() {
        guard !activities.isEmpty else {
            selectedActivityID = nil
            isExpanded = false
            return
        }
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
                .frame(maxHeight: 250)
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
        case .explorationGroup(let tools):
            for tool in tools {
                hasher.combine(tool.id)
                hasher.combine(tool.result?.text)
                hasher.combine(tool.result?.isError)
                hasher.combine(tool.result?.truncated)
            }
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
private struct AssistantItemView: View {
    @Environment(\.cardExpandDefaults) private var cardDefaults

    let item: DisplayItem
    var baseURL: URL? = nil
    var isLastTurn = false
    var isResponding = false
    var askSelections: [String: AskUserSelectionState] = [:]
    var onAskToggle: (String, Int, Int, Bool) -> Void = { _, _, _, _ in }
    var onAskSubmit: (String, String) -> Void = { _, _ in }
    var showSubagentTags = true

    var body: some View {
        switch item {
        case .plain(let block):
            BlockView(block: block, showSubagentTags: showSubagentTags)
        case .tool(let id, let name, let description, let input, let subagent, let result):
            VStack(alignment: .leading, spacing: 4) {
                if showSubagentTags { subagentTag(subagent) }
                toolView(
                    id: id, name: name, description: description,
                    input: input, result: result
                )
            }
        case .explorationGroup(let tools):
            ExplorationGroupCard(
                tools: tools,
                baseURL: baseURL,
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
            DiffCard(toolName: name, input: input, result: result, initiallyExpanded: cardDefaults.editCards)
        } else if name == "Bash" {
            TerminalCard(
                input: input,
                result: result,
                running: result == nil && isLastTurn && isResponding,
                initiallyExpanded: cardDefaults.terminal
            )
        } else {
            ToolUseCard(
                name: name, description: description, input: input,
                result: result, running: result == nil && isLastTurn && isResponding,
                baseURL: baseURL,
                initiallyExpanded: cardDefaults.shouldExpandTool(name)
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
    @Environment(\.cardExpandDefaults) private var cardDefaults

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
        case .thinking(let thinking, _):
            if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CollapsibleSection(
                    icon: "brain",
                    title: "思考过程",
                    tint: Theme.textSecondary,
                    initiallyExpanded: cardDefaults.thinking
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
        case .toolResult(let toolUseId, let text, let isError, let truncated, _):
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
                        truncated: truncated
                    ))
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
                    .font(.system(size: 11, weight: .medium))
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
            tint: .orange
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("类型  \(displayType)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Text(payload.isEmpty ? "无可显示载荷" : payload)
                    .font(.system(size: 11, design: .monospaced))
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
    @Environment(\.cardExpandDefaults) private var cardDefaults

    let tools: [ExplorationToolItem]
    var baseURL: URL? = nil
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
                    ForEach(identifiedExplorationTools(tools)) { identified in
                        let tool = identified.item
                        ToolUseCard(
                            name: tool.name,
                            description: tool.description,
                            input: tool.input,
                            result: tool.result,
                            running: tool.result == nil && running,
                            baseURL: baseURL,
                            initiallyExpanded: cardDefaults.inlineTools
                        )
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
        .onAppear {
            if cardDefaults.toolGroup { expanded = true }
        }
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
            if let imagePath, let baseURL {
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
                withAnimation(.easeInOut(duration: 0.15)) { expanded = true }
            }
        }
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
                    HStack(spacing: 6) {
                        Text(toolLabel(name))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                            .lineLimit(1)
                        if let source = toolSourceLabel(name) {
                            Text(source)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Theme.codex)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.codex.opacity(0.10)))
                        }
                    }
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
    @Environment(\.chatAPI) private var api
    @Environment(\.chatSessionID) private var sessionID

    let result: ToolResultInfo

    @State private var fullText: String
    @State private var truncated: Bool
    @State private var loading = false
    @State private var loadError: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?
    @State private var activeRequestKey = ""

    private let displayLimit = 24_000

    init(result: ToolResultInfo) {
        self.result = result
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
            if !displayText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(displayText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(result.isError ? Theme.danger : Theme.textPrimary)
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
                Text(result.isError ? "工具执行失败，未返回错误详情" : "工具已完成，没有文本输出")
                    .font(.system(size: 11))
                    .foregroundColor(result.isError ? Theme.danger : Theme.textSecondary)
            }
            if !fullText.isEmpty {
                Button {
                    UIPasteboard.general.string = fullText
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)
                .accessibilityLabel("复制完整工具输出")
            }
        }
        .onChange(of: result.text) { _, text in
            cancelLoad()
            fullText = text
            truncated = result.truncated
            loadError = nil
        }
        .onChange(of: result.toolUseId) { _, _ in
            cancelLoad()
            fullText = result.text
            truncated = result.truncated
            loadError = nil
        }
        .onDisappear { cancelLoad() }
    }

    private var fullContentRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(loadError ?? "服务端为保证传输速度省略了部分内容")
                .font(.system(size: 11))
                .foregroundColor(loadError == nil ? Theme.textSecondary : Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: loadFullContent) {
                if loading {
                    ProgressView().controlSize(.small).tint(Theme.brand)
                } else {
                    Text(loadError == nil ? "加载完整内容" : "重试")
                        .font(.system(size: 11, weight: .semibold))
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

/// 可折叠区块（thinking / tool_result 共用）。工具结果默认折叠，思考过程默认展开。
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

// MARK: - 回复与历史折叠入口

private struct AssistantReplyDisclosure: View {
    let preview: String
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.brand)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.brand.opacity(0.12)))
                Text("Wand")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if collapsed {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(collapsed ? "展开" : "收起")
                    .font(.system(size: 11, weight: .semibold))
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

private struct InlineHistoryChip: View {
    let count: Int
    var expanded = false
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(expanded ? -90 : 0))
                Text(expanded ? "收起上文" : "已收起 \(count) 轮")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(Capsule(style: .continuous).fill(Theme.surface))
            .overlay(Capsule(style: .continuous).stroke(Theme.border, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起上文" : "展开已收起的 \(count) 轮上文")
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(metaText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
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
        .onChange(of: isAnswered) { _, answered in
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
                                .font(.system(size: 10, weight: .semibold))
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
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                            Text(movePath)
                                .font(.system(size: 11, design: .monospaced))
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
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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
            // 默认只显示摘要行；运行状态不再强制展开具体 diff。
            if !initialized {
                expanded = initiallyExpanded
                initialized = true
            }
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

    private func unifiedDiffBlock(_ diff: String) -> some View {
        let clipped = diff.count > 16_000
            ? String(diff.prefix(16_000)) + "\n…（差异已截断）"
            : diff
        return VStack(alignment: .leading, spacing: 3) {
            Text("统一差异")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(coloredUnifiedDiff(clipped))
                    .font(.system(size: 11, design: .monospaced))
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
        self.result = result
        self.running = running
        self.initiallyExpanded = initiallyExpanded
        _outputText = State(initialValue: result?.text ?? "")
        _truncated = State(initialValue: result?.truncated == true)
    }

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
                    if let result, !outputText.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(outputText.count > 12_000
                                 ? String(outputText.prefix(12_000)) + "\n…（本页仅展示前 12000 字）"
                                 : outputText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(result.isError ? Color(red: 0.95, green: 0.55, blue: 0.5) : termText.opacity(0.85))
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
                                .font(.system(size: 10, weight: .semibold))
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
        }
        .onChange(of: result != nil) {
            if initiallyExpanded {
                withAnimation(.easeInOut(duration: 0.15)) { expanded = true }
            }
        }
        .onChange(of: result?.text) { _, text in
            cancelFullOutputLoad()
            outputText = text ?? ""
            truncated = result?.truncated == true
            outputLoadError = nil
        }
        .onChange(of: result?.toolUseId) { _, _ in
            cancelFullOutputLoad()
            outputText = result?.text ?? ""
            truncated = result?.truncated == true
            outputLoadError = nil
        }
        .onDisappear { cancelFullOutputLoad() }
    }

    private var fullOutputRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(outputLoadError ?? "输出过长，服务端已省略部分内容")
                .font(.system(size: 10))
                .foregroundColor(outputLoadError == nil
                    ? termText.opacity(0.60)
                    : Color(red: 0.95, green: 0.55, blue: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: loadFullOutput) {
                if loadingFullOutput {
                    ProgressView().controlSize(.small).tint(termText)
                } else {
                    Text(outputLoadError == nil ? "加载完整输出" : "重试")
                        .font(.system(size: 10, weight: .semibold))
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
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    TodoRunningLabel()
                    Text("· 第 \(currentStep)/\(todos.count) 步")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.brand)
                    Text(activeTask)
                        .font(.system(size: 12))
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
                .font(.system(size: 12))
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
        .animation(reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0), value: isActive)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0), value: todo.status)
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
                .smooth(duration: 1.2, extraBounce: 0)
            }
        }
    }

    private func label(opacity: Double) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.brand)
                .frame(width: 7, height: 7)
            Text("执行中")
                .font(.system(size: 12, weight: .semibold))
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
    let onClearAll: () -> Void

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
        .animation(.easeInOut(duration: 0.18), value: expanded)
        .animation(.easeInOut(duration: 0.18), value: items.count)
    }

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11))
                Text("已排队 \(items.count) 条消息")
                    .font(.system(size: 12, weight: .medium))
                if inFlight {
                    Text("· 中断后立即发送")
                        .font(.system(size: 10))
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
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
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
                    .font(.system(size: 11, weight: .semibold))
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
