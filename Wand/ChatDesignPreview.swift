#if DEBUG
import SwiftUI
import UIKit

/// Interactive native fixture. No session or API mutation.
struct ChatDesignPreview: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var identityMetrics = ChatIdentityLayoutMetrics()
    @State private var text = ""
    @State private var activity = AvatarFileActivity.idle
    @StateObject private var composerFocus = ComposerFocusController()
    private var focused: Bool { get { composerFocus.focused } nonmutating set { composerFocus.focused = newValue } }
    @State private var acknowledged = false
    private var editing: Bool { get { composerFocus.editing } nonmutating set { composerFocus.editing = newValue } }
    @State private var thinking = false
    @AppStorage(CatComposerSide.preferenceKey) private var sideRaw = CatComposerSide.left.rawValue
    @State private var dragOffset: CGFloat = 0
    @State private var notice = ""
    @State private var height: CGFloat = 34
    @State private var composing = false
    @State private var files: [UploadedFile] = []
    @State private var failed = false
    @State private var running = false
    @State private var context = false
    @State private var setting = "模型"
    @State private var selectedModel = "Sonnet"
    @State private var selectedMode = "标准"
    @State private var selectedThinking = "自动"
    @State private var previewFile: ServerFilePreviewItem?
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
                            Text("我会先阅读说明。你可以继续补充要求，附件和草稿都会保留。\n\n发送与停止任务是独立操作；发送状态不明确时先核对会话。").font(.body).lineSpacing(4)
                            Text("离线交互预览 · \(stage)").font(.caption).foregroundStyle(Theme.textSecondary)
                            if !fixtureImages.isEmpty {
                                // 生产视图本身：缩略图自适应放大 + 全屏滑动切换。
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(fixtureImages.enumerated()), id: \.offset) { index, source in
                                        WandToolImageThumbnail(baseURL: URL(string: "https://127.0.0.1:1")!, source: source,
                                                               group: fixtureImages, groupIndex: index)
                                    }
                                }
                            }
                        }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }.clipped().onTapGesture { composerFocus.collapse() }.padding(.top, identityMetrics.clearance)
                    previewComposer.padding(.bottom, keyboard.lift)
                }.frame(width: root.size.width, height: root.size.height, alignment: .top)
            }.background(Theme.background).toolbar(.hidden, for: .navigationBar)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                    TopChatCompanion(side: CatComposerSide(rawValue: sideRaw) ?? .left, dragOffset: dragOffset,
                        title: "赛博虎妞", status: running ? "任务执行中" : "离线交互预览") { size in
                        WorkingAvatar(id: "e_wand_default", name: "赛博虎妞", avatar: "plush-cat:v1:silver", activity: activity,
                            thinking: thinking, size: size).overlay { Color.clear.modifier(fixtureGesture) }
                    }
                    FloatingChatControls(onBack: { stage = "返回会话列表（预览）" }) {
                        Button { stage = "会话文件（预览）" } label: { FloatingChatIcon(symbol: "folder") }.accessibilityLabel("会话文件预览")
                        Menu {
                            if running { Button("停止当前任务", role: .destructive) { running = false; activity = .idle; thinking = false } }
                            Button("猫头控件间居中") { sideRaw = "left" }
                            Button("猫头向右微移") { sideRaw = "right" }
                            Text("当前员工：赛博虎妞")
                            Text("目录：/工作区/Wand")
                            Button("模型设置（离线样例）") { openSetting("模型") }
                            ForEach(stages, id: \.self) { title in
                                Button(title) { apply(title) }
                            }
                        } label: { FloatingChatIcon(symbol: "ellipsis") }.accessibilityLabel("更多与预览状态")
                    }
                    }
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
    private let stages = ["思考中", "阅读中", "书写中", "流式文本", "右侧阅读", "有稿运行", "仅附件", "图片组", "空态", "短按文字", "附件", "附件取消", "发送确认", "失败保稿", "未知送达", "收起草稿"]
    /// 三种比例的离线图片，验证缩略图自适应上限与全屏查看器翻页；data URI 不走网络、不需要凭据。
    @State private var fixtureImages: [String] = []
    private func focus() { composerFocus.focus(); notice = "" }
    private func openSetting(_ title: String) { setting = title; composerFocus.borrow("settings", open: true); context = true }
    private func apply(_ title: String) {
        stage = title; context = false
        failed = false; running = false; activity = .idle; acknowledged = false; files = []; focused = false
        editing = false; thinking = false; notice = ""; text = ""; fixtureImages = []
        switch title {
        case "思考中": running = true; thinking = true
        case "阅读中": running = true; activity = .reading
        case "书写中": running = true; activity = .writing
        case "流式文本": running = true
        case "右侧阅读": sideRaw = CatComposerSide.right.rawValue; running = true; activity = .reading
        case "有稿运行": text = "请补充检查安全区"; running = true
        case "仅附件": files = [fixtureFile]; editing = true
        case "图片组": fixtureImages = Self.fixtureImageSources()
        case "短按文字": focus()
        case "附件": text = "请结合附件检查设计。"; files = [fixtureFile]; focus()
        case "附件取消": text = "请结合附件检查设计。"; focus()
        case "发送确认": acknowledged = true; running = true; activity = .reading
        case "失败保稿", "未知送达": text = "保留这条完整草稿，不自动重发。"; files = [fixtureFile]; failed = true
        case "收起草稿": text = "未发送的草稿仍保留"
        default: break
        }
    }
    @Environment(\.dynamicTypeSize) private var typeSize
    private var maximumHeight: CGFloat { max(typeSize.isAccessibilitySize ? 80 : 0, composerMaximumInputHeight(compact: verticalSizeClass == .compact, keyboardVisible: keyboard.isVisible)) }
    private var previewStatus: some View {
        Text(running ? "处理中" : !notice.isEmpty ? notice : "正在输入")
            .font(.caption).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var fixtureGesture: CatInputGesture {
        CatInputGesture(onTap: focus, onDrag: { dragOffset = $0 }, onDrop: { offset in
                sideRaw = (CatComposerSide(rawValue: sideRaw) ?? .left).dropped(translation: offset).rawValue; dragOffset = 0
            })
    }
    /// 横、竖、方三张离线色块图，用来肉眼区分全屏查看器的不同页。
    static func fixtureImageSources() -> [String] {
        [(CGSize(width: 1600, height: 600), "横 1600×600", UIColor.systemBlue),
         (CGSize(width: 600, height: 1600), "竖 600×1600", UIColor.systemRed),
         (CGSize(width: 900, height: 900), "方 900×900", UIColor.systemGreen)].map { spec in
            let renderer = UIGraphicsImageRenderer(size: spec.0)
            let image = renderer.image { _ in
                spec.2.setFill()
                UIRectFill(CGRect(origin: .zero, size: spec.0))
                (spec.1 as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: min(spec.0.width, spec.0.height) / 8),
                    .foregroundColor: UIColor.white,
                ])
            }
            guard let data = image.pngData() else { return "" }
            return "data:image/png;base64," + data.base64EncodedString()
        }.filter { !$0.isEmpty }
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
            if running || !notice.isEmpty { previewStatus.padding(.horizontal, 16) }
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
                }, send: {
                        NativeComposerActions(phase: .idle, turnRunning: running, hasDraft: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty,
                            canSubmit: !failed && !composing,
                            message: nil, sendLabel: running ? "继续发送（排队）" : "发送消息",
                            onSend: { text = ""; files = []; composerFocus.collapse(); acknowledged = true; running = true; activity = .writing },
                            onStop: { running = false; activity = .idle; thinking = false })
                }, settings: {
                    ComposerSettingsStrip(model: selectedModel, mode: selectedMode, thinking: selectedThinking,
                        onModel: { openSetting("模型") }, onMode: { openSetting("权限模式") }, onThinking: { openSetting("思考深度") })
                }, actionCount: ComposerActionPresentation(phase: .idle, turnRunning: running,
                    hasDraft: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty).slotCount)
        }
        .onChange(of: keyboard.isVisible) { old, visible in if old && !visible { composerFocus.keyboardHidden() } }
    }
}

func mobileOperationParityScenario(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard let value = environment["WAND_DEBUG_MOBILE_PARITY"], ["tools", "task", "new"].contains(value) else { return nil }
    return value
}

/// Bounded native regression surfaces. Only a loopback fixture server is accepted;
/// the harness never creates a real model execution or uses a live credential.
struct MobileOperationParityPreview: View {
    let scenario: String
    private let api: WandAPI
    @StateObject private var workspaceStore: WorkspaceStore
    @State private var formOpen = false
    @State private var outcome = "尚未提交"
    @State private var running = true
    @State private var failed = false
    @State private var initialSessionID: String?
    @State private var fixtureVerified = false
    @State private var fixtureError = false
    @State private var fixtureRevision = 0
    private struct FixtureIdentity: Decodable { let identity: String }
    private let workspace = Workspace(id: "fixture-w", name: "回放目录", cwd: "/fixture", defaultProvider: .pi, layout: nil, createdAt: "", lastOpenedAt: nil)
    private let task = WorkspaceTask(id: "fixture-task", workspaceId: "fixture-w", name: "窗口导航回放", worktree: nil, layout: nil, status: "active", createdAt: "", lastOpenedAt: nil)
    init(scenario: String) {
        self.scenario = scenario
        let supplied = ProcessInfo.processInfo.environment["WAND_DEBUG_PARITY_ORIGIN"].flatMap(URL.init(string:))
        let origin = supplied.flatMap { $0.host == "127.0.0.1" && $0.scheme == "http" ? $0 : nil }
            ?? URL(string: "http://127.0.0.1:9")!
        let api = WandAPI(baseURL: origin, token: nil)
        self.api = api
        _workspaceStore = StateObject(wrappedValue: WorkspaceStore(api: api, serverID: ServerProfiles.stableID(for: origin)))
    }
    private var items: [DisplayItem] {
        [.plain(.thinking(thinking: "检查回放参数与状态，不调用模型。", subagent: nil, occurredAt: "2026-10-18T12:00:00Z")),
         .tool(id: "fixture-call", name: "Lookup", description: "检查参数与结果", input: ["query": .string("short preview"), "__wandToolActivity": .object(["occurredAt": .string("2026-10-18T12:00:01Z")])], subagent: nil,
             result: running ? nil : ToolResultInfo(toolUseId: "fixture-call", text: failed ? "隔离回放：调用失败" : "隔离回放：调用完成", isError: failed, truncated: false))]
    }
    var body: some View {
        Group {
            if fixtureVerified { surface }
            else if fixtureError {
                VStack { Text("隔离服务未就绪；不会连接真实执行路径"); Button("重试隔离服务") { fixtureRevision += 1 } }
            } else { ProgressView("验证隔离回放服务…") }
        }.task(id: fixtureRevision) {
            fixtureError = false
            do {
                let identity = try await api.request(FixtureIdentity.self, method: "GET", path: "/__wand_mobile_parity_fixture")
                guard identity.identity == "wand-mobile-operation-fixture-v1" else { fixtureError = true; return }
                fixtureVerified = true
            } catch { fixtureError = true }
        }
    }
    private var surface: some View {
        NavigationStack {
            if scenario == "task" {
                WorkspaceTaskView(workspace: workspace, task: task, api: api, store: workspaceStore,
                    initialSessionId: initialSessionID, onSessionPresentationChanged: { initialSessionID = $0 })
            } else if scenario == "new" {
                VStack(spacing: 16) {
                    Text("新建交互隔离回放").font(.headline)
                    Text(outcome).accessibilityIdentifier("parity-outcome")
                    Button("打开新建对话") { formOpen = true }.buttonStyle(WandPrimaryButtonStyle())
                }.padding(16)
                .task { await workspaceStore.loadWorkspaceIndex(); await workspaceStore.loadTaskGroups(force: true) }
                .sheet(isPresented: $formOpen) {
                    WorkspaceNewTaskSheet(api: api, store: workspaceStore, initialCwd: "/fixture", workspaceId: "fixture-w") { result in
                        outcome = result.runID != nil ? "已接受团队运行" : result.session != nil ? "已接受会话" : "已接受任务分组"
                    }.presentationDetents([.large])
                }
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("工具状态隔离回放").font(.headline)
                            HStack {
                                Button(running ? "结束运行" : "重新运行") { running.toggle(); failed = false }
                                Button("显示失败") { running = false; failed = true }
                            }.buttonStyle(WandQuietButtonStyle())
                            ActivityFoldCard(group: ActivityGroup(latest: "", meta: "", count: 2, items: items, newest: true),
                                baseURL: api.baseURL, isLastTurn: true, isResponding: running, timelinePolicyOverride: true)
                            ToolUseCard(name: "InputOnly", description: "仅参数调用，可在运行中查看", input: ["query": .string("完整参数回放")], running: running)
                            AssistantItemView(item: .tool(id: "edit-fixture", name: "Edit", description: nil,
                                input: ["file_path": .string("fixture.swift"), "old_string": .string("before"), "new_string": .string("after")], subagent: nil,
                                result: running ? nil : ToolResultInfo(toolUseId: "edit-fixture", text: "done", isError: failed, truncated: false)),
                                isLastTurn: true, isResponding: running)
                        }.padding(16)
                    }.environment(\.chatViewportHeight, viewport.size.height)
                }
                .environment(\.chatAPI, api).environment(\.chatSessionID, "fixture-session")
            }
        }.background(Theme.background)
    }
}
#endif
