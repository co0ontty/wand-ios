#if DEBUG
import SwiftUI
import UIKit

/// Interactive native fixture. No session, API mutation, microphone or synthesized audio.
struct ChatDesignPreview: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var text = ""
    @State private var activity = AvatarFileActivity.idle
    @StateObject private var composerFocus = ComposerFocusController()
    private var focused: Bool { get { composerFocus.focused } nonmutating set { composerFocus.focused = newValue } }
    @State private var acknowledged = false
    private var editing: Bool { get { composerFocus.editing } nonmutating set { composerFocus.editing = newValue } }
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
    @State private var setting = "模型"
    @State private var selectedModel = "Sonnet"
    @State private var selectedMode = "标准"
    @State private var selectedThinking = "自动"
    @State private var previewFile: ServerFilePreviewItem?
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
                            Text("我会先阅读说明。你可以继续补充要求，附件和草稿都会保留。\n\n发送、停止任务和停止朗读是独立操作；发送状态不明确时先核对会话。").font(.body).lineSpacing(4)
                            Text("离线交互预览 · \(stage)").font(.caption).foregroundStyle(Theme.textSecondary)
                        }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }.onTapGesture { composerFocus.collapse() }.padding(.top, verticalSizeClass == .compact ? 56 : 100)
                    previewComposer.padding(.bottom, keyboard.lift)
                }.frame(width: root.size.width, height: root.size.height, alignment: .top)
            }.background(Theme.background).toolbar(.hidden, for: .navigationBar)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                    TopChatCompanion(side: CatComposerSide(rawValue: sideRaw) ?? .left, dragOffset: dragOffset) { size in
                        WorkingAvatar(id: "e_wand_default", name: "赛博虎妞", avatar: "plush-cat:v1:silver", activity: activity,
                            thinking: thinking, speaking: speaking, size: size).overlay { Color.clear.modifier(fixtureGesture) }
                    }
                    FloatingChatControls(onBack: { stage = "返回会话列表（预览）" }) {
                        Button { stage = "会话文件（预览）" } label: { FloatingChatIcon(symbol: "folder") }.accessibilityLabel("会话文件预览")
                        Menu {
                            if running { Button("停止当前任务", role: .destructive) { running = false; activity = .idle; thinking = false } }
                            if speaking { Button("暂停朗读声音") { speaking = false } }
                            Button("猫头控件间居中") { sideRaw = "left" }
                            Button("猫头向右微移") { sideRaw = "right" }
                            Button("持续通话预览") { voice = true }
                            Text("当前员工：赛博虎妞")
                            Text("目录：/工作区/Wand")
                            Button("模型设置（离线样例）") { openSetting("模型") }
                            ForEach(stages, id: \.self) { title in
                                Button(title) { apply(title) }
                            }
                        } label: { FloatingChatIcon(symbol: "ellipsis") }.accessibilityLabel("更多与预览状态")
                    }.padding(.top, verticalSizeClass == .compact ? 0 : 18)
                    }
                }
                .sheet(isPresented: $editor, onDismiss: { composing = false; focused = true }) {
                    ComposerDraftEditor(text: $text, onCompositionChange: { composing = $0 })
                }
                .sheet(isPresented: $context, onDismiss: { composerFocus.resume("settings") }) {
                    NavigationStack {
                        List {
                            Text("离线选择器样例，不修改真实配置").font(.caption)
                            ForEach(setting == "模型" ? ["Sonnet", "Opus", "长名称模型 · 完整名称与候选可在这里查看"] : setting == "权限模式" ? ["标准", "自动编辑", "全权限"] : ["自动", "低", "中", "高"], id: \.self) { option in
                                Button(option) {
                                    if setting == "模型" { selectedModel = option }
                                    else if setting == "权限模式" { selectedMode = option }
                                    else { selectedThinking = option }
                                    context = false
                                }
                            }
                        }.navigationTitle(setting).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { context = false } } }
                    }
                }
                .sheet(item: $previewFile, onDismiss: { composerFocus.resume("preview") }) { ServerFilePreviewView(item: $0) }
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
    private func focus() { composerFocus.focus(); notice = "" }
    private func openSetting(_ title: String) { setting = title; composerFocus.borrow("settings", open: true); context = true }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    private var maximumHeight: CGFloat { max(typeSize.isAccessibilitySize ? 80 : 0, composerMaximumInputHeight(compact: verticalSizeClass == .compact, keyboardVisible: keyboard.isVisible)) }
    private var previewStatus: some View {
        Text(canceling ? "松开取消" : recording ? "正在听 · 上滑取消" : processing ? "转写中…" : speaking ? "正在朗读" : running ? "处理中" : !notice.isEmpty ? notice : "正在输入")
            .font(.caption).foregroundStyle(canceling ? Theme.danger : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var fixtureGesture: CatInputGesture {
        CatInputGesture(onTap: focus, onHold: { composerFocus.borrow("voice", open: editing); recording = true; notice = "" },
            onMove: { canceling = $0 }, onRelease: { cancelled in
                recording = false; canceling = false; composerFocus.resume("voice")
                if cancelled { notice = "已取消，草稿保留" }
                else { text += text.isEmpty ? "转写后的草稿，等待我点发送。" : "\n转写后的草稿，等待我点发送。"; focus() }
            }, onDrag: { dragOffset = $0 }, onDrop: { offset in
                sideRaw = (CatComposerSide(rawValue: sideRaw) ?? .left).dropped(translation: offset).rawValue; dragOffset = 0
            })
    }
    private func openFixtureFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("离线样例-设计说明.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 420, height: 594))
        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                ("离线附件样例\n\n同一输入表面随焦点展开。关闭预览后返回原草稿。\n移除附件不会清空文字。" as NSString).draw(in: CGRect(x: 30, y: 40, width: 360, height: 480), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
            composerFocus.borrow("preview", open: true)
            previewFile = ServerFilePreviewItem(url: url)
        } catch { notice = "离线附件无法创建" }
    }
    private var previewComposer: some View {
        VStack(spacing: 4) {
            if recording || processing || speaking || running || !notice.isEmpty { previewStatus.padding(.horizontal, 16) }
            FocusComposerSurface(expanded: expanded, hasDraft: !text.isEmpty || !files.isEmpty,
                onFocus: focus, editor: {
                    VStack(alignment: .leading, spacing: 6) {
                        PendingAttachmentsPreview(baseURL: URL(string: "http://127.0.0.1:9")!, attachments: files,
                            onRemove: { file in files.removeAll { $0.savedPath == file.savedPath } },
                            onPreview: { _ in openFixtureFile() })
                        if failed {
                            Text(stage == "未知送达" ? "送达未确认，请先核对会话。" : "发送失败，草稿和附件保留。")
                                .font(.caption).foregroundStyle(Theme.danger)
                        }
                        IMEAwareComposerTextView(text: $text, placeholder: "输入消息，回车换行", isFocused: focused,
                            maximumHeight: maximumHeight, submitOnReturn: false, onFocusChange: { focused = $0 },
                            onCompositionChange: { composing = $0 }, onSubmit: {}, onHeightChange: { height = $0 })
                            .frame(height: min(maximumHeight, max(34, height)))
                    }
                }, add: {
                    Button { if files.isEmpty { files.append(fixtureFile) }; focus() } label: { Image(systemName: "plus").frame(width: 48, height: 48) }.accessibilityLabel("添加示例附件")
                }, voice: {
                    Image(systemName: recording ? "waveform" : "mic").frame(width: 48, height: 48).modifier(fixtureGesture).accessibilityLabel("语音输入")
                }, send: {
                    if running && catCapsuleShowsThirdAction(text: text) {
                        ComposerStopAction { running = false; activity = .idle; thinking = false }
                    } else if !text.isEmpty || !files.isEmpty {
                        NativeComposerActionButton(phase: .idle, turnRunning: false, hasDraft: true, canSubmit: !failed && !composing && !recording,
                            message: nil, onSend: { text = ""; files = []; composerFocus.collapse(); acknowledged = true; running = true; activity = .writing }, onStop: {})
                    }
                }, settings: {
                    HStack(spacing: 2) {
                        Button { openSetting("模型") } label: { ComposerSettingLabel(title: selectedModel) }.accessibilityLabel("模型：" + selectedModel)
                        Button { openSetting("权限模式") } label: { ComposerSettingLabel(title: selectedMode) }.accessibilityLabel("权限模式：" + selectedMode)
                        Button { openSetting("思考深度") } label: { ComposerSettingLabel(title: "思考：" + selectedThinking) }.accessibilityLabel("思考深度：" + selectedThinking)
                    }.buttonStyle(.plain)
                })
        }
        .onChange(of: keyboard.isVisible) { old, visible in if old && !visible { composerFocus.keyboardHidden() } }
    }
}
#endif
