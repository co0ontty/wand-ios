import SwiftUI
import UniformTypeIdentifiers
import Combine

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

struct SessionDestinationView: View {
    let session: SessionSnapshot
    let api: WandAPI

    @ViewBuilder var body: some View {
        if session.isStructured {
            ChatView(sessionId: session.id, api: api)
        } else {
            PtySessionView(session: session, api: api)
        }
    }
}

/// PTY 会话的原生外壳：套用与 ChatView 一致的原生导航头（provider 徽章 + 标题 +
/// cwd），中间嵌入 embed=terminal 的 WebView 只渲染终端黑窗，底部输入栏走原生组件。
/// 这样 PTY 会话不再是「直接打开整张网页版」，而是和对话模式同样的原生观感，
/// 只是内容区换成了那块黑色终端窗口。
private struct PtySessionView: View {
    let session: SessionSnapshot
    let api: WandAPI

    @StateObject private var store: ChatStore
    @StateObject private var terminalWebModel = WebViewModel()
    @StateObject private var keyboard = KeyboardObserver()
    @StateObject private var speech = SpeechRecognizerService()
    @State private var draft = ""
    @State private var showStopConfirm = false
    @State private var showQuickCommit = false
    @StateObject private var attachments: ComposerAttachmentController
    @State private var voicePressed = false
    @State private var voiceCanceling = false
    @State private var draftNeedsExpanded = false
    @State private var composerInputHeight: CGFloat = 34
    @State private var composerIsComposing = false
    /// 底部快捷栏左上角的拉手控制：折叠时只露出快捷键栏，展开时在快捷键栏上方
    /// 滑出输入抽屉（文本框 + 发送 + 语音 + 附件）。默认折叠，给终端留出最大可视区。
    @State private var inputDrawerOpen = false
    @State private var voiceHoldWork: DispatchWorkItem?
    @State private var gitStatus: GitStatusResult?
    @StateObject private var quickCommitFeedback = QuickCommitFeedbackController()
    @FocusState private var inputFocused: Bool

    private var ptyBackground: Color {
        Color(red: 0.090, green: 0.071, blue: 0.059)
    }

    init(session: SessionSnapshot, api: WandAPI) {
        self.session = session
        self.api = api
        _store = StateObject(wrappedValue: ChatStore(sessionId: session.id, api: api))
        _attachments = StateObject(wrappedValue: ComposerAttachmentController(sessionId: session.id, api: api))
    }

    var body: some View {
        GeometryReader { root in
            ZStack {
                ptyBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        WebContainerView(
                            serverURL: api.baseURL,
                            token: api.token,
                            sessionId: session.id,
                            embedTerminal: true,
                            embedNativeInput: true,
                            webViewModel: terminalWebModel
                        )
                        terminalScaleControls
                            .padding(.top, 10)
                            .padding(.trailing, 10)
                            .opacity(terminalWebModel.phase == .ready ? 1 : 0)
                            .allowsHitTesting(terminalWebModel.phase == .ready)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomBar(safeBottom: root.safeAreaInsets.bottom)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleStatus }
            ToolbarItem(placement: .navigationBarTrailing) {
                GitChangesToolbarButton(status: gitStatus, phase: quickCommitFeedback.phase) {
                    showQuickCommit = true
                }
            }
        }
        .toolbarBackground(ptyBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
            terminalWebModel.onEmbeddedTerminalTap = handleEmbeddedTerminalTap
            store.start()
            refreshGitStatus()
        }
        .onChange(of: showQuickCommit) { _, showing in
            if !showing { refreshGitStatus() }
        }
        .onDisappear { store.shutdown() }
        .overlay(alignment: .top) { connectionBanner }
        .overlay(alignment: .top) { toastView }
        .wandKeyboardShortcuts(ptyKeyboardShortcuts)
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
                inputFocused = true
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
                isEnabled: keyboardShortcutsActive && terminalWebModel.phase == .ready
            ) {
                terminalWebModel.refreshEmbeddedTerminal()
            },
            WandKeyboardShortcutAction(
                id: "zoom-terminal-in",
                title: "放大终端",
                key: "=",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && terminalWebModel.phase == .ready
            ) {
                terminalWebModel.adjustEmbeddedTerminalScale(delta: 0.25)
            },
            WandKeyboardShortcutAction(
                id: "zoom-terminal-out",
                title: "缩小终端",
                key: "-",
                modifiers: .command,
                isEnabled: keyboardShortcutsActive && terminalWebModel.phase == .ready
            ) {
                terminalWebModel.adjustEmbeddedTerminalScale(delta: -0.25)
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
                terminalWebModel.adjustEmbeddedTerminalScale(delta: -0.25)
            }
            Text(terminalWebModel.terminalScaleLabel)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.92))
                .frame(width: 42, height: 28)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .accessibilityLabel("终端缩放 \(terminalWebModel.terminalScaleLabel)")
            terminalScaleButton(systemName: "plus", accessibilityLabel: "放大终端") {
                terminalWebModel.adjustEmbeddedTerminalScale(delta: 0.25)
            }
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 3)
            terminalScaleButton(systemName: "arrow.clockwise", accessibilityLabel: "刷新终端") {
                terminalWebModel.refreshEmbeddedTerminal()
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

    private func bottomBar(safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            if voicePressed {
                voiceBubble
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if inputDrawerOpen {
                inputBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            terminalShortcutBar
        }
        .padding(.bottom, safeBottom + keyboard.lift)
        .animation(.easeOut(duration: 0.2), value: keyboard.lift)
        .animation(.easeOut(duration: 0.22), value: inputDrawerOpen)
    }

    /// 终端快捷键栏：始终可见，左端第一个是输入抽屉的拉手（上箭头/键盘图标），
    /// 点击或上拉展开输入抽屉；其后是高频 PTY 按键。对称 Android PtyShortcutBar。
    /// 包在水平 ScrollView 里：拉手 + 9 个按键的最小宽度合计远超 iPhone 屏宽，
    /// 若用固定 HStack 会把整条 bottomBar（以及 WebView、输入抽屉）撑到 ~750pt 宽，
    /// 导致横向溢出 + 抽屉里发送按钮被推到屏幕外「无法发送」。横向滚动后栏宽恒等于屏宽。
    private var terminalShortcutBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                inputDrawerHandle
                ForEach(TerminalShortcuts.defaults) { shortcut in
                    terminalShortcutKey(shortcut)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 50)
        .background(ptyBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    private var inputDrawerHandle: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return HStack(spacing: 5) {
            Image(systemName: inputDrawerOpen ? "keyboard.fill" : "keyboard")
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: inputDrawerOpen ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(inputDrawerOpen ? Theme.brand : Color.white.opacity(0.82))
        .frame(height: 40)
        .frame(minWidth: 56)
        .padding(.horizontal, 6)
        .background(
            shape.fill(inputDrawerOpen
                ? Theme.brand.opacity(0.18)
                : Color.white.opacity(0.08))
        )
        .overlay(
            shape.stroke(
                inputDrawerOpen ? Theme.brand.opacity(0.45) : Color.white.opacity(0.14),
                lineWidth: 0.7
            )
        )
        .contentShape(shape)
        .accessibilityLabel(inputDrawerOpen ? "收起输入框" : "展开输入框")
        .onTapGesture { toggleInputDrawer() }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    // 向上拉展开、向下拉收起，给「拉手」一个真实的方向手势。
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
            .font(.system(size: compact ? 15 : 12, weight: .semibold, design: .monospaced))
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
        inputDrawerOpen.toggle()
        if inputDrawerOpen {
            focusNativeInput()
        }
    }

    /// 唤起原生输入：先压住网页侧 xterm 隐藏 textarea（readonly + blur），再把
    /// 焦点交给抽屉里的文本框。IMEAwareComposerTextView 内部带多次重试，
    /// 转场动画/WKWebView 抢焦点导致的单次失败会自动补上。
    private func focusNativeInput() {
        terminalWebModel.suppressEmbeddedTerminalIme()
        if inputDrawerOpen { inputFocused = true }
    }

    /// 点终端黑窗：nativeInput 模式下网页侧不可能弹键盘，直接展开输入抽屉并聚焦。
    private func handleEmbeddedTerminalTap() {
        if !inputDrawerOpen { inputDrawerOpen = true }
        focusNativeInput()
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
            voiceMode: voicePressed,
            contentNeedsSpace: draftNeedsExpanded || !attachments.attachments.isEmpty
        )
    }

    private var inputBar: some View {
        NativeComposerShell(
            expanded: inputExpanded,
            focused: inputFocused,
            onFocusInput: {
                inputFocused = true
            },
            collapsedLeading: { composerActionsMenu },
            inputContent: { ptyTextField },
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

    private var terminalGlyph: some View {
        Image(systemName: "terminal")
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
    }

    private var ptyTextField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.attachments.isEmpty {
                PendingAttachmentsPreview(
                    baseURL: api.baseURL,
                    attachments: attachments.attachments,
                    onRemove: attachments.remove
                )
            }
            IMEAwareComposerTextView(
                text: $draft,
                placeholder: ptyComposerPlaceholder,
                isFocused: inputFocused,
                disableAutocorrect: true,
                onFocusChange: { focused in
                    inputFocused = focused
                    if focused {
                        terminalWebModel.suppressEmbeddedTerminalIme()
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
            .padding(.leading, inputExpanded ? 6 : 2)
            .padding(.trailing, inputExpanded ? 4 : 0)
            .padding(.vertical, inputExpanded ? 4 : 2)
            .frame(minHeight: inputExpanded ? 32 : 34)
            .frame(height: max(inputExpanded ? 32 : 34, composerInputHeight))
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
            .gesture(voiceTapOrHoldGesture(onTap: { inputFocused = true }))
            .accessibilityLabel("语音输入")
            .accessibilityValue(voicePressed ? "正在录音" : "长按录音")
    }

    private var terminalChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
            Text("终端")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.textSecondary.opacity(0.10)))
        .overlay(Capsule().stroke(Theme.textSecondary.opacity(0.22), lineWidth: 1))
    }

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

    private var ptyComposerPlaceholder: String {
        if voicePressed {
            return voiceCanceling ? "松开取消" : "松开结束 · 上滑取消"
        }
        return "输入终端命令"
    }

    private var voiceBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: voiceCanceling ? "xmark.circle.fill" : "waveform.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(voiceCanceling ? Theme.danger : Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voiceCanceling ? "松开取消" : (speech.transcript.isEmpty ? "正在聆听…" : speech.transcript))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(voiceCanceling ? Theme.danger : Theme.textPrimary)
                        .lineLimit(3)
                    Text(speech.usingOnDevice ? "端侧识别" : "语音识别")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((voiceCanceling ? Theme.danger : Theme.brand).opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var canSend: Bool {
        composerDraftIsSendable(
            draft,
            hasAttachments: !attachments.attachments.isEmpty,
            isComposing: composerIsComposing
        )
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = buildAttachmentPrompt(attachments.attachments, body: draft)
        let restoreDraft = draft
        let restoreAttachments = attachments.attachments
        draft = ""
        attachments.attachments.removeAll()
        sendPtyInput(text, restoreDraft: restoreDraft, restoreAttachments: restoreAttachments)
        inputFocused = true
    }

    private func sendPtyInput(_ text: String, restoreDraft: String, restoreAttachments: [UploadedFile]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await store.sendPtyTerminalInput(trimmed)
            } catch {
                if draft.isEmpty { draft = restoreDraft }
                if attachments.attachments.isEmpty { attachments.attachments = restoreAttachments }
                store.toast = error.localizedDescription
            }
        }
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

    private static let voiceCancelThreshold: CGFloat = 60
    private static let voiceHoldThreshold: TimeInterval = 0.18

    private func voiceTapOrHoldGesture(onTap: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if voiceHoldWork == nil && !voicePressed {
                    let work = DispatchWorkItem {
                        voiceHoldWork = nil
                        startVoiceRecording()
                    }
                    voiceHoldWork = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Self.voiceHoldThreshold,
                        execute: work
                    )
                }
                if voicePressed {
                    voiceCanceling = value.translation.height < -Self.voiceCancelThreshold
                }
            }
            .onEnded { _ in
                if let work = voiceHoldWork {
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

    private func appendTranscriptToDraft(_ text: String) {
        draft = appendingVoiceTranscript(text, to: draft)
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
                    .font(.system(size: 13, weight: .medium))
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

    private var titleStatus: some View {
        HStack(spacing: 8) {
            let provider = store.snapshot?.provider ?? session.provider
            // 与 Android 一致：透明底，只展示品牌 logo。
            BrandLogo(provider: provider, color: Color.white.opacity(0.9))
                .frame(width: 18, height: 18)
                .frame(width: 26, height: 26)

            VStack(spacing: 0) {
                Text(store.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 175)
                    .topicTitleRhythm(store.titleGenerating)
                if let cwd = session.cwd, !cwd.isEmpty {
                    WandPathRevealText(path: cwd, fontSize: 9, color: Color.white.opacity(0.58), staggerWindow: 0)
                        .frame(width: 175)
                }
            }
        }
        .shadow(color: Color.black.opacity(0.26), radius: 3, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(WandProvider(normalizing: store.snapshot?.provider ?? session.provider).title)，\(store.displayTitle)")
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 7) {
                Text(trailingTimeLabel)
                    .font(.system(size: 10, weight: .medium))
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
                        .font(.system(size: 10.5, weight: .medium))
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
        WandProvider(normalizing: session.provider) == .codex ? Theme.codex : Theme.brand
    }

    private var durationLabel: String {
        SessionTimeFormatting.duration(startedAt: session.startedAt, endedAt: session.endedAt)
    }

    private var trailingTimeLabel: String {
        if session.status == "running" || session.isResponding || session.hasPendingPermission {
            return durationLabel.isEmpty ? "" : "已运行 \(durationLabel)"
        }
        return SessionTimeFormatting.relativeTime(for: session.endedAt ?? session.startedAt)
    }

    private var statusTint: Color {
        if session.hasPendingPermission { return .orange }
        if session.isResponding || ["running", "thinking"].contains(session.status ?? "") { return .green }
        if ["waiting-input", "waiting_input", "reconnecting"].contains(session.status ?? "") { return .orange }
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
                    .font(.system(size: 10.5, weight: .semibold))
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
                    .font(.system(size: 15, weight: .semibold))
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
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(loading ? providerTint : Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 46)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(providerTint)
                Text("可恢复")
                    .font(.system(size: 10.5, weight: .medium))
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
        WandProvider(normalizing: history.provider) == .codex ? Theme.codex : Theme.brand
    }

    private var relativeTime: String {
        SessionTimeFormatting.relativeTime(for: history.timestamp)
    }

}
