import SwiftUI
import UniformTypeIdentifiers
import Combine
import UIKit

/// Hidden-bar chat pages keep their floating controls, but the gesture itself is
/// UIKit's interactive pop. Never render/animate copies of either page.
struct SessionBackSwipeEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SessionBackSwipeController {
        SessionBackSwipeController()
    }
    func updateUIViewController(_ controller: SessionBackSwipeController, context: Context) {
        controller.installNativeGesture()
    }
    static func dismantleUIViewController(_ controller: SessionBackSwipeController, coordinator: ()) {
        controller.releaseAfterTransition()
    }
}

final class SessionBackSwipeController: UIViewController, UIGestureRecognizerDelegate {
    private static var ownerKey: UInt8 = 0
    private final class WeakOwner {
        weak var controller: SessionBackSwipeController?
        init(_ controller: SessionBackSwipeController) { self.controller = controller }
    }
    private weak var managedGesture: UIGestureRecognizer?
    private weak var managedNavigation: UINavigationController?
    private weak var originalDelegate: UIGestureRecognizerDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installNativeGesture()
        DispatchQueue.main.async { [weak self] in self?.installNativeGesture() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installNativeGesture()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        releaseAfterTransition()
    }

    func installNativeGesture() {
        guard viewIfLoaded?.window != nil, let nav = navigationController,
              let top = nav.topViewController?.viewIfLoaded, view.isDescendant(of: top),
              nav.viewControllers.count > 1, nav.transitionCoordinator == nil,
              let pop = nav.interactivePopGestureRecognizer else { return }
        if managedGesture === pop, pop.delegate === self {
            if !pop.isEnabled { pop.isEnabled = true }
            return
        }
        if let owner = (objc_getAssociatedObject(nav, &Self.ownerKey) as? WeakOwner)?.controller,
           owner !== self { owner.restoreNativeGesture() }
        restoreNativeGesture()
        managedNavigation = nav
        managedGesture = pop
        originalDelegate = pop.delegate
        // Preserve UIKit's recognizer, targets, transition driver and both live
        // controllers. Only the hidden/custom-back-button eligibility is bridged.
        pop.delegate = self
        pop.isEnabled = true
        objc_setAssociatedObject(nav, &Self.ownerKey, WeakOwner(self), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func releaseAfterTransition() {
        if let transition = navigationController?.transitionCoordinator {
            // Do not change a recognizer's delegate while the finger is driving
            // it. Cancellation must return to the very same page and gesture.
            transition.animate(alongsideTransition: nil) { _ in
                if self.viewIfLoaded?.window != nil,
                   let top = self.navigationController?.topViewController?.viewIfLoaded,
                   self.view.isDescendant(of: top) {
                    self.installNativeGesture()
                } else {
                    self.restoreNativeGesture()
                }
            }
        } else {
            restoreNativeGesture()
        }
    }

    private func restoreNativeGesture() {
        if let gesture = managedGesture, gesture.delegate === self { gesture.delegate = originalDelegate }
        if let nav = managedNavigation,
           let owner = (objc_getAssociatedObject(nav, &Self.ownerKey) as? WeakOwner)?.controller,
           owner === self {
            objc_setAssociatedObject(nav, &Self.ownerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        managedGesture = nil
        managedNavigation = nil
        originalDelegate = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === managedGesture else {
            return originalDelegate?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
        }
        guard let nav = managedNavigation, nav.viewControllers.count > 1,
              nav.transitionCoordinator == nil, nav.presentedViewController == nil,
              let top = nav.topViewController?.viewIfLoaded,
              view.isDescendant(of: top) else { return false }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: other) ?? false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: other) ?? false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: other) ?? false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }
}

/// 同一详情打开流程尚未稳定前，不允许第二次请求改写 selection。
/// 选中另一会话但没有动画中的打开操作时（例如 iPad 双栏）仍然允许切换。
func shouldBeginSessionOpen(
    requestedID: String,
    currentSelection: String?,
    openingSessionID: String?
) -> Bool {
    openingSessionID == nil && currentSelection != requestedID
}

extension Notification.Name {
    static let wandBeginSessionSelection = Notification.Name("wandBeginSessionSelection")
}

/// 宿主页面（任务模式）交给会话的动作。会话可见时宿主不再叠第二条顶栏，
/// 这些动作并进会话自己的「更多」菜单，保持一条栏且不丢入口。
struct SessionHostAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var isEnabled = true
    let action: () -> Void

    var menuAction: SessionMenuAction {
        SessionMenuAction(id: id, title: title, symbol: symbol, isEnabled: isEnabled, action: action)
    }
}

struct SessionDestinationView: View {
    let session: SessionSnapshot
    let api: WandAPI
    var showsNavigationChrome: Bool = true
    var onCompletionVisible: ((SessionSnapshot) -> Void)? = nil
    var sharedChatStore: ChatStore? = nil
    var hostActions: [SessionHostAction] = []
    /// 归属工作区任务的任务名，会话顶栏主标题的真源；独立会话不传，回落会话标题。
    var hostTitle: String? = nil

    @ViewBuilder var body: some View {
        Group {
            if session.isStructured {
                ChatView(sessionId: session.id, api: api, showsNavigationChrome: showsNavigationChrome,
                         onCompletionVisible: onCompletionVisible, sharedStore: sharedChatStore,
                         initialSnapshot: session, hostActions: hostActions, hostTitle: hostTitle)
            } else {
                PtySessionView(session: session, api: api, showsNavigationChrome: showsNavigationChrome,
                               onCompletionVisible: onCompletionVisible, hostActions: hostActions,
                               hostTitle: hostTitle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// UIKit/SwiftTerm PTY surface. ChatStore owns draft/input/permission semantics;
/// PtyTerminalStore owns only checkpoint replay, rendering, ACK and native keyboard input.
private struct PtySessionView: View {
    @Environment(\.usesSystemHomeNavigation) private var usesSystemNavigation
    let session: SessionSnapshot
    let api: WandAPI
    let showsNavigationChrome: Bool
    let onCompletionVisible: ((SessionSnapshot) -> Void)?
    let hostActions: [SessionHostAction]
    let hostTitle: String?
    @State private var viewVisible = false

    @StateObject private var store: ChatStore
    @StateObject private var terminal: PtyTerminalStore
    @StateObject private var keyboard = KeyboardObserver()
    @StateObject private var composerDraft: ComposerDraftState
    private var draft: String { composerDraft.text }
    @State private var showStopConfirm = false
    @State private var showQuickCommit = false
    @StateObject private var attachments: ComposerAttachmentController
    @State private var draftNeedsExpanded = false
    @State private var composerInputHeight: CGFloat = 32
    @State private var composerIsComposing = false
    /// 底部快捷栏左上角的拉手控制：折叠时只露出快捷键栏，展开时在快捷键栏上方
    /// 滑出输入抽屉（文本框 + 发送 + 附件）。默认折叠，给终端留出最大可视区。
    @State private var inputDrawerOpen = false
    @State private var composerActionsOpen = false
    @State private var gitStatus: GitStatusResult?
    @StateObject private var quickCommitFeedback = QuickCommitFeedbackController()
    @StateObject private var sessionFiles: SessionFilesStore
    /// 与 ChatView 相同：UIKit 输入框不能绑 @FocusState，否则键盘会被立刻 resign。
    @State private var inputFocused = false
    @Environment(\.scenePhase) private var scenePhase

    private var ptyBackground: Color {
        Theme.terminalBackground
    }

    init(session: SessionSnapshot, api: WandAPI, showsNavigationChrome: Bool = true,
         onCompletionVisible: ((SessionSnapshot) -> Void)? = nil, hostActions: [SessionHostAction] = [],
         hostTitle: String? = nil) {
        self.session = session
        self.api = api
        self.showsNavigationChrome = showsNavigationChrome
        self.onCompletionVisible = onCompletionVisible
        self.hostActions = hostActions
        self.hostTitle = hostTitle
        let chatStore = ChatStore(sessionId: session.id, api: api)
        _store = StateObject(wrappedValue: chatStore)
        _terminal = StateObject(wrappedValue: PtyTerminalStore(sessionId: session.id, api: api))
        _sessionFiles = StateObject(wrappedValue: SessionFilesStore(service: api))
        _composerDraft = StateObject(wrappedValue: chatStore.composerDraft)
        _attachments = StateObject(wrappedValue: chatStore.composerDraft.attachments)
    }

    var body: some View {
        GeometryReader { root in
            ZStack {
                ptyBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        NativeTerminalSurface(terminal: terminal.terminal)
                        if terminal.loading { ProgressView().tint(Theme.terminalText).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        if let error = terminal.error {
                            VStack { Text(error).font(.footnote).foregroundStyle(Theme.terminalText); Button("重新同步") { terminal.refresh() } }
                                .padding(12).background(Theme.terminalBackground).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        terminalScaleControls
                            .padding(.top, 10)
                            .padding(.trailing, 10)
                            .opacity(terminal.ready ? 1 : 0)
                            .allowsHitTesting(terminal.ready)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomBar(
                        maximumInputHeight: min(160, max(60, (root.size.height - keyboard.lift) * 0.35))
                    )
                }
            }
        }
        .background { if !usesSystemNavigation { SessionBackSwipeEnabler().allowsHitTesting(false) } }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsNavigationChrome ? .visible : .automatic, for: .navigationBar)
        .toolbar {
            if showsNavigationChrome {
                ToolbarItem(placement: .principal) { titleStatus }
                    .sharedBackgroundVisibility(.hidden)
            }
            if #available(iOS 27.1, *), usesSystemNavigation {
                ToolbarOverflowMenu { terminalMenuItems }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu { terminalMenuItems } label: {
                        Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("更多会话功能")
                }
            }
        }
        .wandToolbarSurface(enabled: showsNavigationChrome, colorScheme: .dark)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(
                sessionId: session.id,
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
        .onChange(of: completionVisibilityToken) { _, _ in publishCompletionVisibility() }
        .onChange(of: store.loading) { _, loading in
            if !loading { sendPendingInitialMessage() }
        }
        .onChange(of: canSend) { _, ready in
            if ready { sendPendingInitialMessage() }
        }
        .onAppear {
            if !viewVisible { store.attachView() }
            viewVisible = true
            let activeStore = store
            attachments.setToastHandler { [weak activeStore] in activeStore?.toast = $0 }
            attachments.setPtyPasteHandler { [weak activeStore] files in
                guard let activeStore else { throw CancellationError() }
                try await activeStore.pasteUploadedPathsIntoPty(files)
            }
            terminal.terminal.provider = session.provider
            terminal.terminal.onTerminalFocus = { composerActionsOpen = false; inputFocused = false; inputDrawerOpen = false }
            terminal.terminal.onPasteImages = attachments.handlePastedImageData
            terminal.start()
            sendPendingInitialMessage()
            refreshGitStatus()
        }
        .onChange(of: showQuickCommit) { _, showing in
            if !showing { refreshGitStatus() }
        }
        .onChange(of: composerDraft.text) { _, value in
            if value.isEmpty {
                draftNeedsExpanded = false
                composerInputHeight = 32
            }
        }
        .onDisappear {
            if viewVisible { store.detachView() }
            viewVisible = false
            terminal.shutdown()
            terminal.terminal.onTerminalFocus = nil
            terminal.terminal.onPasteImages = nil
            inputDrawerOpen = false
            inputFocused = false
            composerInputHeight = 32
            draftNeedsExpanded = false
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { store.handleEnterForeground(); terminal.foreground(); refreshGitStatus() }
            else if newPhase == .background { store.handleEnterBackground() }
        }
        .overlay(alignment: .top) { connectionBanner }
        .overlay(alignment: .bottom) { toastView }
        .wandKeyboardShortcuts(ptyKeyboardShortcuts)
    }

    private var completionVisibilityToken: String {
        "\(viewVisible):\(scenePhase):\(store.loading):\(store.loadError == nil):\(showQuickCommit):\(showStopConfirm):\(attachments.showPhotoPicker):\(attachments.showFileImporter):\(store.snapshot?.completionRevision ?? 0):\(store.isResponding):\(store.permissionBlocked):\(store.pendingEscalation != nil):\(store.snapshot?.archived == true)"
    }

    private func publishCompletionVisibility() {
        guard viewVisible, scenePhase == .active, !store.loading, store.loadError == nil,
              !showQuickCommit, !showStopConfirm, !attachments.showPhotoPicker,
              !attachments.showFileImporter, let snapshot = store.snapshot else { return }
        onCompletionVisible?(snapshot)
    }

    private var ptyKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "focus-input",
                title: "聚焦输入",
                key: "l",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && !inputFocused
            ) {
                // 抽屉折叠时文本框不在视图树里，必须先展开才能聚焦。
                if !inputDrawerOpen { inputDrawerOpen = true }
                focusNativeInput()
            },
            WandKeyboardShortcutAction(
                id: "send",
                title: "发送终端命令",
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
                id: "refresh-terminal",
                title: "刷新终端",
                key: "r",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && terminal.ready
            ) {
                terminal.refresh()
            },
            WandKeyboardShortcutAction(
                id: "zoom-terminal-in",
                title: "放大终端",
                key: "=",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && terminal.ready
            ) {
                terminal.adjustScale(0.25)
            },
            WandKeyboardShortcutAction(
                id: "zoom-terminal-out",
                title: "缩小终端",
                key: "-",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && terminal.ready
            ) {
                terminal.adjustScale(-0.25)
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
    }

    private var terminalScaleControls: some View {
        HStack(spacing: 2) {
            terminalScaleButton(systemName: "minus", accessibilityLabel: "缩小终端") {
                terminal.adjustScale(-0.25)
            }
            Text(terminal.scaleLabel)
                .font(.wand(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.92))
                .frame(width: 42, height: 28)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .accessibilityLabel("终端缩放 \(terminal.scaleLabel)")
            terminalScaleButton(systemName: "plus", accessibilityLabel: "放大终端") {
                terminal.adjustScale(0.25)
            }
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 3)
            terminalScaleButton(systemName: "arrow.clockwise", accessibilityLabel: "刷新终端") {
                terminal.refresh()
            }
        }
        .padding(4)
        .wandGlassCapsule()
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    private func terminalScaleButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color.white.opacity(0.94))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func bottomBar(maximumInputHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if inputDrawerOpen {
                inputBar(maximumHeight: maximumInputHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            terminalShortcutBar
        }
        // GeometryReader already excludes the bottom safe area; lift only above it.
        .padding(.bottom, keyboard.lift)
        .animation(WandMotion.scroll, value: keyboard.lift)
        .animation(WandMotion.scroll, value: inputDrawerOpen)
    }

    /// 终端快捷键栏：输入入口固定在左侧，只有快捷键区域横向滚动，避免窄屏时输入入口被带走。
    private var terminalShortcutBar: some View {
        HStack(spacing: 0) {
            inputDrawerHandle
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(TerminalShortcuts.defaults) { shortcut in
                        terminalShortcutKey(shortcut)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ptyBackground.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.border.opacity(0.8), lineWidth: 0.7)
        )
        .padding(.horizontal, 8)
    }

    private var inputDrawerHandle: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return HStack(spacing: 2) {
            Image(systemName: inputDrawerOpen ? "square.and.pencil" : "pencil")
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: inputDrawerOpen ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(inputDrawerOpen ? Theme.brand : Theme.textPrimary)
        .frame(height: 40)
        .frame(minWidth: 44)
        .padding(.horizontal, 8)
        .background(
            shape.fill(inputDrawerOpen
                ? Theme.brand.opacity(0.18)
                : Theme.surface.opacity(0.92))
        )
        .overlay(
            shape.stroke(Theme.border.opacity(0.85), lineWidth: 0.6)
        )
        .contentShape(shape)
        .accessibilityLabel(inputDrawerOpen ? "收起草稿输入框" : "展开草稿输入框")
        .accessibilityHint("点击终端可直接输入；草稿支持多行编辑后发送")
        .onTapGesture { toggleInputDrawer() }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -10, !inputDrawerOpen {
                        toggleInputDrawer()
                    } else if value.translation.height > 10, inputDrawerOpen {
                        toggleInputDrawer()
                    }
                }
        )
    }

    private func terminalShortcutKey(_ shortcut: TerminalShortcut) -> some View {
        let compact = shortcut.label.count <= 2
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Text(shortcut.label)
            .font(.wand(size: compact ? 15 : 12, weight: .semibold, design: .monospaced))
            .foregroundColor(Color.white.opacity(0.9))
            .frame(height: 40)
            .frame(minWidth: compact ? 42 : 52)
            .padding(.horizontal, compact ? 10 : 12)
            .background(shape.fill(Color.white.opacity(0.08)))
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.6))
            .contentShape(shape)
            .accessibilityLabel(shortcut.accessibilityLabel)
            .onTapGesture { sendTerminalShortcut(shortcut) }
    }

    private func toggleInputDrawer() {
        composerActionsOpen = false
        let opening = !inputDrawerOpen
        inputDrawerOpen = opening
        if opening {
            // 先释放原生终端的 IME，再展开抽屉并聚焦。
            // 顺序很重要：inputDrawerOpen 与 inputFocused 同帧置位，避免 inputExpanded
            // 用旧值算错一帧高度（抽屉刚展开却按折叠态布局，输入框看起来异常大）。
            focusNativeInput()
        } else {
            inputFocused = false
            terminal.terminal.focusTerminal()
        }
    }

    /// 原生终端与草稿互斥持有 IME；释放终端预编辑后聚焦草稿，不把预编辑误发到 PTY。
    /// 注意：inputDrawerOpen 必须先于本次调用置位（见 toggleInputDrawer / 快捷键），
    /// 否则 inputFocused 与 inputDrawerOpen 不同帧会导致布局闪烁。
    private func focusNativeInput() {
        terminal.terminal.blurTerminal()
        if inputDrawerOpen { inputFocused = true }
    }

    private func sendTerminalShortcut(_ shortcut: TerminalShortcut) {
        let bytes = shortcut.bytes
        guard !bytes.isEmpty else { return }
        Task {
            do {
                try await store.sendPtyShortcut(bytes, shortcutKey: "ios-\(shortcut.id)")
            } catch {
                store.toast = error.localizedDescription
            }
        }
    }

    private var inputExpanded: Bool {
        composerShouldExpand(
            focused: inputFocused,
            contentNeedsSpace: draftNeedsExpanded || !attachments.attachments.isEmpty
        )
    }

    private func inputBar(maximumHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            if composerActionsOpen {
                ComposerAttachmentPanel(onPhoto: {
                    composerActionsOpen = false; attachments.showPhotoPicker = true
                }, onFile: {
                    composerActionsOpen = false; attachments.showFileImporter = true
                }) { EmptyView() }
            }
        NativeComposerShell(
            expanded: inputExpanded,
            focused: inputFocused,
            onFocusInput: focusNativeInput,
            collapsedLeading: { composerActionsMenu },
            inputContent: { ptyTextField(maximumHeight: maximumHeight) },
            collapsedTrailing: {
                trailingButtons
            },
            expandedControls: {
                HStack(spacing: ComposerMetrics.actionSpacing) {
                    composerActionsMenu
                    terminalChip
                    Spacer(minLength: 0)
                    trailingButtons
                }
            }
        )
        }
        .onChange(of: inputDrawerOpen) { _, open in if !open { composerActionsOpen = false } }
        .onKeyPress(.escape) {
            if composerActionsOpen { composerActionsOpen = false; return .handled }
            return .ignored
        }
        .confirmationDialog(
            "确定要停止当前正在运行的任务吗？",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("停止", role: .destructive) { stopPtyInput() }
            Button("取消", role: .cancel) {}
        }
    }

    private var composerActionsMenu: some View {
        ComposerAddButton(expanded: composerActionsOpen, uploading: attachments.isUploading) {
            composerActionsOpen.toggle()
        }
    }

    private func ptyTextField(maximumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.attachments.isEmpty {
                PendingAttachmentsPreview(
                    baseURL: api.baseURL,
                    attachments: attachments.attachments,
                    onRemove: attachments.remove
                )
            }
            IMEAwareComposerTextView(
                text: $composerDraft.text,
                placeholder: ptyComposerPlaceholder,
                isFocused: inputFocused,
                disableAutocorrect: true,
                maximumHeight: maximumHeight,
                submitOnReturn: false,
                onPasteImages: { items in
                    attachments.handlePastedImageData(items)
                },
                onFocusChange: { focused in
                    inputFocused = focused
                    if focused {
                        terminal.terminal.blurTerminal()
                    }
                },
                onCompositionChange: { composerIsComposing = $0 },
                onSubmit: sendDraft,
                onHeightChange: { height in
                    composerInputHeight = height
                    draftNeedsExpanded = !draft.isEmpty && height > 36
                }
            )
            .wandSubmitOnHardwareReturn(isEnabled: { keyboardShortcutsActive && canSend }, perform: sendDraft)
            // 高度只约束 UITextView 本体，padding 不能吃掉已经测好的可视行。
            .frame(height: inputExpanded ? max(32, composerInputHeight) : 34)
            .padding(.leading, inputExpanded ? 6 : 2)
            .padding(.trailing, inputExpanded ? 4 : 0)
            .padding(.vertical, inputExpanded ? 4 : 2)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
            Text("草稿 · 回车换行")
                .font(.wand(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .wandGlassCapsule()
    }

    @ViewBuilder private var trailingButtons: some View {
        if store.isResponding && canSend {
            stopButtonSecondary
        }
        sendButton
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
        NativeComposerActionButton(
            phase: store.inputFeedback,
            turnRunning: store.isResponding,
            hasDraft: composerIsComposing || composerDraftIsSendable(
                draft, hasAttachments: !attachments.attachments.isEmpty, isComposing: false
            ),
            canSubmit: canSend,
            message: store.inputFeedbackMessage,
            onSend: sendDraft,
            onStop: { showStopConfirm = true }
        )
    }

    private var ptyComposerPlaceholder: String {
        return "编辑草稿，点击 ↑ 发送"
    }

    private var canSend: Bool {
        !store.inputSending && !attachments.isUploading && composerDraftIsSendable(
            draft,
            hasAttachments: !attachments.attachments.isEmpty,
            isComposing: composerIsComposing
        )
    }

    private func sendPendingInitialMessage() {
        guard !store.loading, store.loadError == nil,
              composerDraft.claimInitialSend(when: canSend) else { return }
        sendDraft()
    }

    private func sendDraft() {
        guard canSend else { return }
        composerActionsOpen = false
        let submission = composerDraft.submission()
        composerDraft.submitted(submission)
        Task {
            defer { composerDraft.finishInitialSend() }
            do {
                try await store.sendPtyTerminalInput(submission.prompt)
                composerDraft.accepted(submission)
            } catch {
                if isDefiniteInputRejection(error) { composerDraft.rejected(submission) }
                // Draft remains in this session's memory. The shared submit button owns
                // rejection/unknown-delivery feedback; never reconstruct or retry input.
            }
        }
        inputFocused = true
    }

    private func stopPtyInput() {
        Task {
            do {
                try await store.sendPtyShortcut("\u{1B}", shortcutKey: "esc")
            } catch {
                store.toast = error.localizedDescription
            }
        }
    }

    private func refreshGitStatus() {
        Task {
            do {
                gitStatus = try await api.gitStatus(sessionId: session.id)
            } catch {
                guard gitStatus == nil, !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                gitStatus = try? await api.gitStatus(sessionId: session.id)
            }
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

    @ViewBuilder private var toastView: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.wand(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.82)))
                .padding(.horizontal, 12)
                .padding(.bottom, 88)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + wandNoticeDuration(toast)) {
                        if store.toast == toast { store.toast = nil }
                    }
                }
        }
    }

    @ViewBuilder private var terminalMenuItems: some View {
        SessionActionPalette(actions: terminalPrimaryActions)
        if !hostActions.isEmpty {
            Section { SessionActionPalette(actions: hostActions.map(\.menuAction)) }
        }
    }

    private var terminalPrimaryActions: [SessionMenuAction] {
        var actions = [SessionMenuAction(id: "files", title: "会话文件", symbol: "folder") {
            sessionFiles.show(cwd: store.snapshot?.cwd ?? session.cwd ?? "")
        }]
        // 终端会话的 git 入口和结构化会话同一套规则：工作区干净、状态未知也保留。
        if let commit = GitQuickCommitMenuAction(status: gitStatus, phase: quickCommitFeedback.phase,
            hasCwd: !(store.snapshot?.cwd ?? session.cwd ?? "").isEmpty,
            action: { showQuickCommit = true }).item {
            actions.append(commit)
        }
        return actions
    }

    private var topIdentity: (title: String, subtitle: String) {
        chatTopIdentity(taskTitle: hostTitle, sessionTitle: store.displayTitle,
            employeeName: store.displayEmployeeName ?? store.snapshot?.providerLabel ?? session.employeeName,
            cwd: store.snapshot?.cwd ?? session.cwd)
    }

    @ViewBuilder private var titleStatus: some View {
        let identity = topIdentity
        let attention = ChatTopAttention.resolve(connected: store.connected,
            blocked: store.permissionBlocked || store.pendingEscalation != nil,
            sending: store.inputSending, responding: store.isResponding, status: store.status)
        HStack(alignment: .center, spacing: 6) {
            // 胶囊里的头像固定左侧，标题是任务名，小字是「员工名 · 目录缩写」，
            // 运行与异常只以一个状态点呈现。
            if attention != .quiet {
                Circle().fill(attention.color).frame(width: 6, height: 6)
                    .topicTitleRhythm(attention == .running)
                    .accessibilityHidden(true)
            }
            TopCapsuleTitle(title: identity.title, subtitle: identity.subtitle.isEmpty ? nil : identity.subtitle,
                avatarID: topAvatarIdentity.id, avatarName: topAvatarIdentity.name, avatarValue: topAvatarIdentity.avatar,
                avatarSize: 30,
                titleColor: Color.white.opacity(0.88), subtitleColor: Color.white.opacity(0.58),
                titleSize: 13, subtitleSize: 9, subtitleTruncation: .middle)
                .environment(\.colorScheme, .dark)
                .topicTitleRhythm(store.titleGenerating)
        }
        .shadow(color: Color.black.opacity(0.26), radius: 3, x: 0, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chatTopReadback(title: identity.title, subtitle: identity.subtitle, status: topStatusText))
    }

    /// 顶栏胶囊左侧头像的身份：当前会话的员工优先，没有员工时回落到默认伙伴。
    private var topAvatarIdentity: (id: String, name: String, avatar: String) {
        let employeeID = store.displayEmployee?.id ?? store.snapshot?.employeeId ?? session.employeeId ?? ""
        if !employeeID.isEmpty {
            let name = store.displayEmployeeName ?? session.employeeName ?? ""
            let avatar = store.displayEmployeeAvatar ?? session.employeeAvatar ?? ""
            return (employeeID, name, avatar)
        }
        return ("e_wand_default", "赛博虎妞", "plush-cat:v1:silver")
    }

    /// 终端会话的状态文案只给读屏播报，视觉由状态点与底部输入区承担。
    private var topStatusText: String {
        if !store.connected { return "连接已断开" }
        if store.permissionBlocked || store.pendingEscalation != nil { return "等待你的确认" }
        if store.inputSending { return "正在发送" }
        if store.isResponding { return "正在处理" }
        return "可以继续对话"
    }
}

// MARK: - 列表行

struct SessionRow: View {
    let session: SessionSnapshot
    let selecting: Bool
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(selected ? Theme.brand : Theme.textSecondary)
                            .accessibilityLabel(selected ? "已选中" : "未选中")
                    } else {
                        providerMark
                    }
                }
                .frame(width: 46, height: 30)

                Text(session.displayTitle)
                    .font(.wand(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 7) {
                Text(trailingTimeLabel)
                    .font(.wand(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 46)
                statusIndicator
                if let cwd = session.cwd, !cwd.isEmpty {
                    WandPathRevealText(path: cwd, fontSize: 10, color: Theme.textMuted)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(statusLabel)
                        .font(.wand(size: 10.5, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .wandGlassCard(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(session.isStructured ? "聊天模式" : "终端模式")，\(statusLabel)")
    }

    /// 左侧助手标识：只展示 provider 品牌 logo（透明底，对齐 Android ProviderMark）。
    private var providerMark: some View {
        BrandLogo(provider: session.provider, color: providerTint.opacity(0.94))
            .frame(width: 26, height: 26)
            .frame(width: 38, height: 38)
            .accessibilityLabel("\(session.providerLabel)，\(statusLabel)")
    }

    private var providerTint: Color {
        Theme.providerColor(session.provider)
    }

    private var durationLabel: String {
        SessionTimeFormatting.duration(startedAt: session.startedAt, endedAt: session.endedAt)
    }

    private var trailingTimeLabel: String {
        if session.isResponding || session.hasPendingPermission {
            return durationLabel.isEmpty ? "" : "已运行 \(durationLabel)"
        }
        return SessionTimeFormatting.relativeTime(for: session.endedAt ?? session.startedAt)
    }

    private var statusTint: Color {
        if session.hasPendingPermission { return Theme.permission }
        if session.isResponding || ["running", "thinking"].contains(session.status ?? "") { return Theme.success }
        if ["waiting-input", "waiting_input", "reconnecting"].contains(session.status ?? "") { return Theme.warning }
        if session.status == "failed" { return Theme.danger }
        return Theme.textSecondary.opacity(0.62)
    }

    private var prominentStatus: Bool {
        session.hasPendingPermission
            || session.isResponding
            || ["running", "thinking", "waiting-input", "waiting_input", "reconnecting"]
                .contains(session.status ?? "")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if prominentStatus {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 5, height: 5)
                Text(statusLabel)
                    .font(.wand(size: 10.5, weight: .semibold))
                    .foregroundColor(statusTint)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } else {
            Circle()
                .fill(statusTint)
                .frame(width: 5, height: 5)
                .accessibilityLabel(statusLabel)
        }
    }

    private var statusLabel: String {
        if session.hasPendingPermission { return "待授权" }
        if session.isResponding { return "回复中" }
        switch session.status ?? "" {
        case "running": return "运行中"
        case "thinking": return "思考中"
        case "waiting-input", "waiting_input": return "等待输入"
        case "reconnecting": return "重连中"
        case "idle": return "空闲"
        case "exited", "stopped": return "已结束"
        case "failed": return "失败"
        default:
            if let status = session.status, !status.isEmpty { return status }
            return "未知"
        }
    }
}

struct HistorySessionRow: View {
    let history: HistorySession
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                BrandLogo(provider: history.provider, color: providerTint.opacity(0.94))
                    .frame(width: 23, height: 23)
                    .frame(width: 46, height: 30)
                Text(history.firstUserMessage.isEmpty ? "空会话" : history.firstUserMessage)
                    .font(.wand(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if loading {
                    ProgressView().tint(providerTint).controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: 7) {
                Text(loading ? "恢复中" : relativeTime)
                    .font(.wand(size: 10, weight: .medium))
                    .foregroundColor(loading ? providerTint : Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 46)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(providerTint)
                Text("可恢复")
                    .font(.wand(size: 10.5, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                if !history.cwd.isEmpty {
                    Text("·").foregroundColor(Theme.textMuted.opacity(0.55))
                    WandPathRevealText(path: history.cwd, fontSize: 10, color: Theme.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .wandGlassCard(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityValue(loading ? "聊天模式，正在恢复" : "聊天模式，可恢复")
    }

    private var providerTint: Color {
        Theme.providerColor(history.provider)
    }

    private var relativeTime: String {
        SessionTimeFormatting.relativeTime(for: history.timestamp)
    }

}
