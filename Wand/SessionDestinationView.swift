import SwiftUI
import UniformTypeIdentifiers
import Combine
import UIKit

/// 从左向右的横向滑动返回上一页，不再切到相邻会话。
/// 只认领导边缘，避免抢水平滚动的代码块、表格和终端选区。
func sessionSwipeShouldGoBack(
    startX: CGFloat,
    translation: CGSize,
    minimumDistance: CGFloat = 72,
    maximumStartX: CGFloat = 48
) -> Bool {
    guard startX >= 0, startX <= maximumStartX else { return false }
    guard translation.width >= minimumDistance else { return false }
    return abs(translation.width) > abs(translation.height)
}

/// 松手时的去留判定：默认以「滑过一半」为界——过一半才返回，不到一半就回弹取消。
/// 快速右甩即使没过一半也算完成（和系统返回手势手感一致）；已经过了大半则不再因甩速反向取消。
/// 这是纯函数，便于把「一半」这个交互契约固定成回归。
func sessionSwipeShouldCommit(
    progress: CGFloat,
    velocity: CGFloat,
    flingVelocity: CGFloat = 620
) -> Bool {
    guard progress > 0 else { return false }
    if progress >= 0.5 { return true }
    return velocity >= flingVelocity
}

/// 会话页隐藏系统导航栏后，系统 `interactivePopGestureRecognizer` 不会启动
/// （UINavigationController 在导航栏隐藏时不允许交互式 pop，改它的 delegate 也无效），
/// 所以在导航控制器视图上补一条左边缘右滑手势：只认屏幕左边缘起点，不与代码块、
/// 表格、终端选区或底部快捷键栏的水平滚动抢手势；松手达到距离阈值才返回上一页。
/// 同一条返回栈可能同时挂多个会话页，手势只保留一份，由最后出现的页面持有。
struct SessionBackSwipeEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SessionBackSwipeController {
        SessionBackSwipeController()
    }
    func updateUIViewController(_ controller: SessionBackSwipeController, context: Context) {}
}

final class SessionBackSwipeController: UIViewController, UIGestureRecognizerDelegate {
    /// 记录当前持有导航视图边缘手势的页面，避免多页重复安装导致一次滑动连退两页。
    private static var ownerKey: UInt8 = 0
    private var edgePan: UIPanGestureRecognizer?
    private var panBeginCount: Int?
    private var panStartX: CGFloat?
    /// 跟手位移期间的可视对象：当前页整体右移，上一页以视差背景露出。
    private var draggingView: UIView?
    private var parallaxView: UIImageView?
    private var parallaxDimView: UIView?
    private var commitInFlight = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installEdgePan()
        // 导航容器可能晚一拍完成挂载，补一次即可，不在每次布局里扫整棵视图。
        DispatchQueue.main.async { [weak self] in self?.installEdgePan() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 离开（被 pop 或切到别的页）就摘掉自己的手势，避免导航视图上留下失效 target。
        guard let navView = navigationController?.view,
              let owner = objc_getAssociatedObject(navView, &Self.ownerKey) as? SessionBackSwipeController,
              owner === self else { return }
        uninstallEdgePan()
        objc_setAssociatedObject(navView, &Self.ownerKey, nil, .OBJC_ASSOCIATION_ASSIGN)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === edgePan else { return true }
        guard let navView = navigationController?.view,
              (navigationController?.viewControllers.count ?? 0) > 1 else { return false }
        // 只认左侧边缘起点：内部水平滚动（代码块、表格、终端选区、快捷键栏）照常可用。
        let startX = gestureRecognizer.location(in: navView).x
        guard startX >= 0, startX <= 48 else { return false }
        // 嵌套导航栈（任务页内的会话）只有最内层可以响应，否则一次滑动会连退两层。
        guard innermostNavigationController(at: gestureRecognizer.location(in: navView), in: navView)
            === navigationController else { return false }
        panStartX = startX
        return true
    }

    /// 触摸点落在哪一层导航栈里。嵌套的 NavigationStack 各自有一条边缘 pan，
    /// 同时开始就会一次退两级，所以只让命中视图所属的那一层处理。
    private func innermostNavigationController(at point: CGPoint, in navView: UIView) -> UINavigationController? {
        guard var view = navView.hitTest(point, with: nil) else { return navigationController }
        while true {
            if let nav = view.next as? UINavigationController { return nav }
            guard let parent = view.superview else { return navigationController }
            view = parent
        }
    }

    /// 与内部滚动视图的 pan 同时识别：边缘右滑不能被列表/代码块/终端滚动吞掉，
    /// 而我们的手势只在左侧边缘起步（shouldBegin 把关），不会影响内容内部横滑。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === edgePan || other === edgePan
    }

    private func installEdgePan() {
        guard let navView = navigationController?.view else { return }
        if let owner = objc_getAssociatedObject(navView, &Self.ownerKey) as? SessionBackSwipeController {
            if owner === self, edgePan?.view === navView { return }
            owner.uninstallEdgePan()
        }
        // 用普通 pan + 自判边缘，而不是 UIScreenEdgePanGestureRecognizer：
        // 后者与隐藏导航栏的导航栈/内部滚动视图存在系统级优先级冲突，实测收不到事件。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.maximumNumberOfTouches = 1
        navView.addGestureRecognizer(pan)
        objc_setAssociatedObject(navView, &Self.ownerKey, self, .OBJC_ASSOCIATION_ASSIGN)
        edgePan = pan
    }

    private func uninstallEdgePan() {
        resetDragState()
        if let edgePan {
            edgePan.view?.removeGestureRecognizer(edgePan)
        }
        edgePan = nil
    }

    @objc private func handleEdgePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            panBeginCount = navigationController?.viewControllers.count ?? 0
            beginInteractivePop(pan)
        case .changed:
            updateInteractivePop(pan)
        case .ended, .cancelled, .failed:
            panStartX = nil
            defer { panBeginCount = nil }
            guard pan.state == .ended,
                  let nav = navigationController, nav.viewControllers.count > 1,
                  nav.viewControllers.count == panBeginCount,
                  // 系统交互式 pop 若已启动，它自己会完成返回，这里不能再退一次。
                  nav.transitionCoordinator == nil else {
                cancelInteractivePop()
                return
            }
            // 以「拖了多少比例」而不是固定距离判定：滑到一半左右松手就返回，不到一半回弹。
            let width = max(nav.view.bounds.width, 1)
            let translation = pan.translation(in: pan.view)
            finishInteractivePop(
                progress: min(max(translation.x, 0) / width, 1),
                velocity: pan.velocity(in: pan.view).x
            )
        default:
            break
        }
    }

    // MARK: - 跟手返回动画

    /// 起手：把「当前页」和「上一页」各渲染成一张快照，垫在导航视图里做纯图层动画。
    /// 不去改 SwiftUI 托管页面的 frame/transform —— 它会在下一次布局把改动抹掉，
    /// 表现为拖动时内容错位、方向反向。快照层归自己管，位移完全可控。
    private func beginInteractivePop(_ pan: UIPanGestureRecognizer) {
        guard !commitInFlight, draggingView == nil,
              let nav = navigationController, nav.viewControllers.count > 1 else { return }
        // 减少动态效果：不做位移，松手后瞬时切页（finish 里处理）。
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let width = max(nav.view.bounds.width, 1)
        let previous = nav.viewControllers[nav.viewControllers.count - 2]
        // 当前页快照失败就放弃跟手（不能只拖上一页、不拖当前页）；
        // 上一页快照失败则用主题底色垫底，仍然保留完整的跟手位移。
        guard let currentImage = renderedSnapshot(of: nav.topViewController) else { return }
        let previousImage = renderedSnapshot(of: previous)

        // 上一页在下：起点左移一个视差量，右滑时向右归位。
        let previousLayer = UIImageView(image: previousImage)
        previousLayer.frame = nav.view.bounds
        previousLayer.contentMode = .scaleAspectFill
        previousLayer.backgroundColor = previousImage == nil ? UIColor(Theme.background) : nil
        previousLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previousLayer.isUserInteractionEnabled = false
        previousLayer.transform = CGAffineTransform(
            translationX: -width * WandMotion.backSwipeParallaxRatio, y: 0
        )
        let dim = UIView(frame: previousLayer.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = .black
        dim.alpha = WandMotion.backSwipeDimOpacity
        dim.isUserInteractionEnabled = false
        previousLayer.addSubview(dim)

        // 当前页在上：1:1 跟随手指向右移出，带一层向左的投影。
        let currentLayer = UIImageView(image: currentImage)
        currentLayer.frame = nav.view.bounds
        currentLayer.contentMode = .scaleAspectFill
        currentLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentLayer.isUserInteractionEnabled = false
        currentLayer.layer.shadowColor = UIColor.black.cgColor
        currentLayer.layer.shadowOffset = CGSize(width: -6, height: 0)
        currentLayer.layer.shadowRadius = 12
        currentLayer.layer.shadowOpacity = 0

        nav.view.addSubview(previousLayer)
        nav.view.addSubview(currentLayer)
        parallaxView = previousLayer
        parallaxDimView = dim
        draggingView = currentLayer
    }

    /// 跟手：当前页 1:1 跟随手指，上一页按比例做视差并从暗到亮，位移越大越接近完成态。
    private func updateInteractivePop(_ pan: UIPanGestureRecognizer) {
        guard let nav = navigationController, let current = draggingView else { return }
        let width = max(nav.view.bounds.width, 1)
        let offset = max(0, pan.translation(in: nav.view).x)
        let progress = min(offset / width, 1)
        current.transform = CGAffineTransform(translationX: offset, y: 0)
        current.layer.shadowOpacity = Float(WandMotion.backSwipeDimOpacity * progress)
        let parallax = width * WandMotion.backSwipeParallaxRatio
        parallaxView?.transform = CGAffineTransform(translationX: -parallax * (1 - progress), y: 0)
        parallaxDimView?.alpha = WandMotion.backSwipeDimOpacity * (1 - progress)
    }

    /// 松手：按已拖进度决定补完返回还是回弹取消。两者都是同一段动效的两种收尾，
    /// 并且都以「当前停在的位置」为起点，所以中途松手时看到的就是一半→接着走。
    private func finishInteractivePop(progress: CGFloat, velocity: CGFloat) {
        guard let nav = navigationController else {
            cancelInteractivePop()
            return
        }
        let committed = sessionSwipeShouldCommit(progress: progress, velocity: velocity)
        // 没有跟手图层（减少动态效果、或快照渲染失败）：不做位移，只按同一个判定结果切页。
        guard let current = draggingView else {
            if committed, nav.viewControllers.count > 1 {
                nav.popViewController(animated: !UIAccessibility.isReduceMotionEnabled)
            }
            return
        }
        let width = max(nav.view.bounds.width, 1)
        let offset = max(0, current.transform.tx)
        commitInFlight = true
        if committed {
            // 从当前位置补完到整屏：时长按剩余距离缩短，避免「过半了还要等一长段」。
            let remaining = max(0, width - offset) / width
            UIView.animate(withDuration: 0.26 * Double(max(remaining, 0.35)), delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction]) {
                current.transform = CGAffineTransform(translationX: width, y: 0)
                current.layer.shadowOpacity = Float(WandMotion.backSwipeDimOpacity)
                self.parallaxView?.transform = .identity
                self.parallaxDimView?.alpha = 0
            } completion: { _ in
                // 先把页面真正 pop 掉，再撤掉快照；顺序反了会露出下面那张快照闪一帧。
                if nav.viewControllers.count > 1 { nav.popViewController(animated: false) }
                self.resetDragState()
                self.commitInFlight = false
            }
        } else {
            // 回弹：带一点初速回来，手感更接近系统返回手势。
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.92,
                           initialSpringVelocity: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                current.transform = .identity
                current.layer.shadowOpacity = 0
                self.parallaxView?.transform = CGAffineTransform(
                    translationX: -width * WandMotion.backSwipeParallaxRatio, y: 0
                )
                self.parallaxDimView?.alpha = WandMotion.backSwipeDimOpacity
            } completion: { _ in
                self.resetDragState()
                self.commitInFlight = false
            }
        }
    }

    /// 手势被打断（系统转场抢先、或页面已不在栈里）：不切页，沿原路收回。
    private func cancelInteractivePop() {
        guard let current = draggingView else { return }
        let width = max(navigationController?.view.bounds.width ?? 1, 1)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            current.transform = .identity
            current.layer.shadowOpacity = 0
            self.parallaxView?.transform = CGAffineTransform(
                translationX: -width * WandMotion.backSwipeParallaxRatio, y: 0
            )
            self.parallaxDimView?.alpha = WandMotion.backSwipeDimOpacity
        } completion: { _ in
            self.resetDragState()
        }
    }

    /// 撤掉跟手图层。只删自己加的两个快照视图，不碰页面本体。
    private func resetDragState() {
        draggingView?.removeFromSuperview()
        draggingView = nil
        parallaxView?.removeFromSuperview()
        parallaxView = nil
        parallaxDimView = nil
    }

    /// 把一页渲染成快照。页面对应视图可能还没尺寸（从没显示过），
    /// 那就临时按导航视图尺寸布局一次，渲染完立刻还原，避免改坏它的布局。
    private func renderedSnapshot(of controller: UIViewController?) -> UIImage? {
        guard let nav = navigationController, let target = controller?.view else { return nil }
        let size = nav.view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let needsFrame = target.bounds.size.width < 1 || target.bounds.size.height < 1
        let originalFrame = target.frame
        if needsFrame {
            target.frame = CGRect(origin: .zero, size: size)
            target.layoutIfNeeded()
        }
        defer { if needsFrame { target.frame = originalFrame } }
        let bounds = target.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        return renderer.image { context in
            target.layer.render(in: context.cgContext)
        }
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
        .background { SessionBackSwipeEnabler().allowsHitTesting(false) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsNavigationChrome ? .visible : .automatic, for: .navigationBar)
        .toolbar {
            if showsNavigationChrome {
                ToolbarItem(placement: .principal) { titleStatus }
                    .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { sessionFiles.show(cwd: store.snapshot?.cwd ?? session.cwd ?? "") } label: {
                    Image(systemName: "folder").frame(width: 44, height: 44)
                }.accessibilityLabel("会话文件")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                GitChangesToolbarButton(status: gitStatus, phase: quickCommitFeedback.phase) {
                    showQuickCommit = true
                }
            }
            // 任务模式隐藏了宿主顶栏，任务动作并进这条栏。
            if !hostActions.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Section("任务") {
                            ForEach(hostActions) { item in
                                Button(item.title, systemImage: item.symbol, action: item.action)
                                    .disabled(!item.isEnabled)
                            }
                        }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("任务操作")
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
            if newPhase == .active { store.handleEnterForeground(); terminal.foreground() }
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
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.58))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 6)
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
        .background(Capsule().fill(Theme.textSecondary.opacity(0.10)))
        .overlay(Capsule().stroke(Theme.textSecondary.opacity(0.22), lineWidth: 1))
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
            gitStatus = try? await api.gitStatus(sessionId: session.id)
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

    @ViewBuilder private var titleStatus: some View {
        let identity = chatTopIdentity(taskTitle: hostTitle, sessionTitle: store.displayTitle,
            employeeName: store.displayEmployeeName ?? store.snapshot?.providerLabel ?? session.employeeName,
            cwd: store.snapshot?.cwd ?? session.cwd)
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
                fill: Color.white.opacity(0.08), stroke: Color.white.opacity(0.12),
                titleColor: Color.white.opacity(0.88), subtitleColor: Color.white.opacity(0.58),
                titleSize: 13, subtitleSize: 9, titleWidth: 210, subtitleTruncation: .middle)
                .topicTitleRhythm(store.titleGenerating)
        }
        .frame(maxWidth: .infinity)
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
