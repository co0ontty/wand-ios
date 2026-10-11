#if DEBUG
import SwiftUI

/// Interactive native fixture. No session, API mutation, microphone or synthesized audio.
struct ChatDesignPreview: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var text = ""
    @State private var activity = AvatarFileActivity.idle
    @State private var focused = false
    @State private var acknowledged = false
    @State private var editing = false
    @State private var recording = false
    @State private var canceling = false
    @State private var processing = false
    @State private var speaking = false
    @State private var thinking = false
    @AppStorage(CatComposerSide.preferenceKey) private var sideRaw = CatComposerSide.left.rawValue
    @State private var dragOffset: CGFloat = 0
    @State private var notice = ""
    @State private var height: CGFloat = 34
    @State private var composing = false
    @State private var files: [UploadedFile] = []
    @State private var failed = false
    @State private var running = false
    @State private var editor = false
    @State private var context = false
    @State private var voice = false
    @State private var stage = "空态"
    @StateObject private var keyboard = KeyboardObserver()
    private let fixtureFile = UploadedFile(originalName: "设计说明.pdf", savedPath: "/fixture/设计说明.pdf", size: 4096, mimeType: "application/pdf")
    private var expanded: Bool {
        catComposerExpanded(editing: editing, focused: focused, keyboard: keyboard.isVisible, failed: failed, unconfirmed: failed)
    }
    var body: some View {
        NavigationStack {
            GeometryReader { root in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("帮我整理这份设计说明，先检查交互，再列出需要修改的地方。")
                                .font(.body).padding(12).background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 16))
                            HStack(spacing: 6) {
                                ContactAvatar(id: "e_wand_default", avatar: "plush-cat:v1:silver", size: 28)
                                Text("赛博虎妞").font(.subheadline.weight(.semibold))
                                Text("14:32").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Text("我会先阅读说明。你可以继续补充要求，附件和草稿都会保留。\n\n发送、停止任务和停止朗读是独立操作；发送状态不明确时先核对会话。").font(.body).lineSpacing(4)
                            Text("离线交互预览 · \(stage)").font(.caption).foregroundStyle(Theme.textSecondary)
                        }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }.padding(.top, 56)
                    previewComposer.padding(.bottom, keyboard.lift)
                }.frame(width: root.size.width, height: root.size.height, alignment: .top)
            }.background(Theme.background).toolbar(.hidden, for: .navigationBar)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .overlay(alignment: .top) {
                    FloatingChatControls(onBack: { stage = "返回会话列表（预览）" }) {
                        Button { focused = false; voice = true } label: { FloatingChatIcon(symbol: "phone") }.accessibilityLabel("持续通话预览")
                        Button { stage = "会话文件（预览）" } label: { FloatingChatIcon(symbol: "folder") }.accessibilityLabel("会话文件预览")
                        Menu {
                            if running { Button("停止当前任务", role: .destructive) { running = false; activity = .idle; thinking = false } }
                            if speaking { Button("暂停朗读声音") { speaking = false } }
                            Text("当前员工：赛博虎妞")
                            Text("目录：/工作区/Wand")
                            Button("会话上下文") { context = true }
                            ForEach(stages, id: \.self) { title in
                                Button(title) { apply(title) }
                            }
                        } label: { FloatingChatIcon(symbol: "ellipsis") }.accessibilityLabel("更多与预览状态")
                    }
                }
                .sheet(isPresented: $editor, onDismiss: { composing = false; focused = true }) {
                    ComposerDraftEditor(text: $text, onCompositionChange: { composing = $0 })
                }
                .sheet(isPresented: $context) {
                    NavigationStack { List {
                        LabeledContent("模型与思考", value: "Wand Agent · 默认")
                        LabeledContent("运行目录", value: "/工作区/Wand")
                        LabeledContent("执行模式", value: "标准")
                        Button("优化提示词（预览）") { context = false }
                    }.navigationTitle("会话上下文").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { context = false } } } }
                }
                .confirmationDialog("语音入口（预览，无录音）", isPresented: $voice, titleVisibility: .visible) {
                    Button("按住麦克风 · 转为草稿") { stage = "按住说话仅填入草稿" }
                    Button("持续通话 · 自动发送与播报") { stage = "持续通话须确认员工与目录" }
                }
                .task {
                    if let side = ProcessInfo.processInfo.environment["WAND_DEBUG_CHAT_SIDE"] { sideRaw = side }
                    if let initial = ProcessInfo.processInfo.environment["WAND_DEBUG_CHAT_STAGE"] { apply(initial) }
                    guard ProcessInfo.processInfo.environment["WAND_DEBUG_CHAT_AUTOPLAY"] == "1" else { return }
                    for title in stages {
                        guard !Task.isCancelled else { return }; apply(title)
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
        }
    }
    private let stages = ["思考中", "阅读中", "书写中", "流式文本", "右侧阅读", "有稿运行", "仅附件", "空态", "短按文字", "按住说话", "上滑取消", "已取消", "转写中", "转写草稿", "附件", "附件取消", "发送确认", "失败保稿", "未知送达", "无声音", "权限未开启", "正在朗读", "收起草稿"]
    private func focus() { editing = true; focused = true; notice = "" }
    private func apply(_ title: String) {
        stage = title; editor = false; context = false; voice = false
        failed = false; running = false; activity = .idle; acknowledged = false; files = []; focused = false
        editing = false; recording = false; canceling = false; processing = false; speaking = false; thinking = false; notice = ""; text = ""
        switch title {
        case "思考中": running = true; thinking = true
        case "阅读中": running = true; activity = .reading
        case "书写中": running = true; activity = .writing
        case "流式文本": running = true
        case "右侧阅读": sideRaw = CatComposerSide.right.rawValue; running = true; activity = .reading
        case "有稿运行": text = "请补充检查安全区"; running = true
        case "仅附件": files = [fixtureFile]; editing = true
        case "短按文字": focus()
        case "按住说话": recording = true
        case "上滑取消": recording = true; canceling = true
        case "已取消": notice = "已取消，草稿保留"
        case "转写中": processing = true
        case "转写草稿": text = "继续检查键盘遮挡，转写后由我确认发送。"; focus()
        case "附件": text = "请结合附件检查设计。"; files = [fixtureFile]; focus()
        case "附件取消": text = "请结合附件检查设计。"; focus()
        case "发送确认": acknowledged = true; running = true; activity = .reading
        case "失败保稿", "未知送达": text = "保留这条完整草稿，不自动重发。"; files = [fixtureFile]; failed = true
        case "无声音": notice = "没有听到声音，请再试一次"
        case "权限未开启": notice = "麦克风未开启，可继续打字"
        case "正在朗读": speaking = true
        case "收起草稿": text = "未发送的草稿仍保留"
        default: break
        }
    }
    private var maximumHeight: CGFloat { composerMaximumInputHeight(compact: verticalSizeClass == .compact, keyboardVisible: keyboard.isVisible) }
    private var previewStatus: some View {
        Text(canceling ? "松开取消" : recording ? "正在听 · 上滑取消" : processing ? "转写中…" : speaking ? "正在朗读" : running ? "处理中" : !notice.isEmpty ? notice : "正在输入")
            .font(.caption).foregroundStyle(canceling ? Theme.danger : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var fixtureGesture: CatInputGesture {
        CatInputGesture(onTap: focus, onHold: { recording = true; focused = false; notice = "" },
            onMove: { canceling = $0 }, onRelease: { cancelled in
                recording = false; canceling = false
                if cancelled { notice = "已取消，草稿保留" }
                else { text += text.isEmpty ? "转写后的草稿，等待我点发送。" : "\n转写后的草稿，等待我点发送。"; focus() }
            }, onDrag: { dragOffset = $0 }, onDrop: { offset in
                sideRaw = (CatComposerSide(rawValue: sideRaw) ?? .left).dropped(translation: offset).rawValue; dragOffset = 0
            })
    }
    private var previewComposer: some View {
        CatComposerSurface(expanded: expanded, hasDraft: !text.isEmpty || !files.isEmpty,
            statusVisible: recording || processing || speaking || running || !notice.isEmpty,
            side: CatComposerSide(rawValue: sideRaw) ?? .left, dragOffset: dragOffset,
            face: { size in
                WorkingAvatar(id: "e_wand_default", name: "赛博虎妞", avatar: "plush-cat:v1:silver", activity: activity,
                    thinking: thinking, speaking: speaking, size: size).overlay { Color.clear.modifier(fixtureGesture) }
            }, status: { previewStatus }, editor: {
                VStack(alignment: .leading, spacing: 6) {
                    PendingAttachmentsPreview(baseURL: URL(string: "http://127.0.0.1:9")!, attachments: files,
                        onRemove: { file in files.removeAll { $0.savedPath == file.savedPath } })
                    if text.isEmpty && !files.isEmpty {
                        Button("发送附件") { files = []; editing = false; running = true; activity = .reading }
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .trailing)
                    }
                    if failed {
                        Text(stage == "未知送达" ? "送达未确认，请先核对会话。" : "发送失败，草稿和附件保留。")
                            .font(.caption).foregroundStyle(Theme.danger)
                    }
                    IMEAwareComposerTextView(text: $text, placeholder: "输入消息，回车换行", isFocused: focused,
                        maximumHeight: maximumHeight, submitOnReturn: false, onFocusChange: { focused = $0 },
                        onCompositionChange: { composing = $0 }, onSubmit: {}, onHeightChange: { height = $0 })
                        .frame(height: min(maximumHeight, max(34, height)))
                }
            }, tools: {
                HStack(spacing: 0) {
                    Button { files.append(fixtureFile) } label: { Image(systemName: "plus").frame(width: 48, height: 48) }.accessibilityLabel("添加示例附件")
                    Button { focused = false; context = true } label: { ComposerContextLabel() }
                    if composerOffersExpandedEditor(text: text, measuredHeight: height, maximumHeight: maximumHeight) {
                        Button { focused = false; editor = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 48, height: 48) }.accessibilityLabel("展开编辑长消息")
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "mic").frame(width: 48, height: 48).modifier(fixtureGesture)
                    Button { context = true } label: { Image(systemName: "ellipsis").frame(width: 48, height: 48) }.accessibilityLabel("更多输入设置")
                }.foregroundStyle(Theme.textSecondary)
            }, actions: {
                HStack(spacing: 0) {
                    Image(systemName: "mic").frame(width: 48, height: 48)
                        .modifier(CatInputGesture(onTap: focus, onHold: { recording = true; focused = false },
                            onMove: { canceling = $0 }, onRelease: { cancelled in recording = false; canceling = false; if !cancelled { text = "转写草稿，等待确认发送。"; focus() } }))
                    Button(action: focus) { Image(systemName: "keyboard").frame(width: 48, height: 48) }.accessibilityLabel("展开文字输入")
                    if catCapsuleShowsThirdAction(text: text) {
                        Button {
                            if running { running = false; activity = .idle }
                            else { text = ""; files = []; focused = false; editing = false; acknowledged = true; running = true; activity = .writing }
                        } label: { Image(systemName: running ? "stop.fill" : "arrow.up").frame(width: 48, height: 48) }
                            .disabled(!running && (failed || composing)).accessibilityLabel(running ? "停止当前任务" : "发送消息")
                    }
                }.foregroundStyle(Theme.textPrimary)

            })
            .onChange(of: keyboard.isVisible) { _, visible in if !visible && !focused && !recording { editing = false } }
    }
}
#endif
