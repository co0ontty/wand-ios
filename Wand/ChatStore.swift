import Foundation
import Combine

/// AskUserQuestion 卡片的本地选择状态（对齐 Web 端 state.askUserSelections）。
struct AskUserSelectionState {
    /// questionIndex → 已选 optionIndex 集合。
    var selected: [Int: Set<Int>] = [:]
    var submitted = false
}

/// 单个会话的状态机：拉取快照、订阅 WebSocket、合并增量推送、发送输入与权限决策。
/// 合流规则对齐浏览器端 websocket.ts：
///   - init / messages 全量 → 直接替换
///   - incremental + lastMessage → 末条同 role 时替换，否则按 messageCount 追加
///   - chunk-only 事件是终端视图的，聊天视图直接忽略
@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ConversationTurn] = []
    @Published var isResponding = false
    @Published var status: String = "running"
    @Published var queuedMessages: [String] = []
    @Published var pendingEscalation: EscalationRequest?
    /// PTY 旧式权限提示（permissionBlocked 为 true 但没有结构化 escalation 时）。
    @Published var legacyPermissionPrompt: PermissionRequestInfo?
    @Published var permissionBlocked = false
    @Published var currentTaskTitle: String?
    @Published var connected = true
    @Published var loading = true
    @Published var loadError: String?
    @Published var toast: String?
    @Published var availableModels: [ModelInfo] = []
    @Published var defaultModel: String?
    @Published var selectedModel: String?
    @Published var thinkingEffort = "off"
    /// 服务端全局卡片默认展开偏好；旧服务端缺字段时安全回退为全部收起。
    @Published var cardDefaults = CardExpandDefaults()
    /// 当前执行模式（managed / full-access / auto-edit / default / native）。
    /// 输入栏的模式徽标读它，可中途切换（结构化会话下一轮生效）。
    @Published var mode = "default"
    /// AskUserQuestion 卡片的选择状态（toolUseId → 各题已选项 + 是否已提交）。
    /// 放 store 而非卡片 @State：流式推送会整条替换消息重建视图，局部状态会丢。
    @Published var askUserSelections: [String: AskUserSelectionState] = [:]

    // 消息窗口化：messages 是完整历史的「后缀」，loadedOffset = messages[0] 的绝对下标，
    // messageTotal = 完整 turn 数。loadedOffset > 0 表示顶部还有更早的可加载。
    @Published private(set) var loadedOffset = 0
    @Published private(set) var messageTotal = 0
    /// 块级窗口：messages[0] 被切掉的头部块数（0=该 turn 完整），及该 turn 的完整块数。
    /// 滚动到顶时先按块翻完 messages[0] 的头部，再按 turn 往前翻更早的整条。
    @Published private(set) var leadingBlockOffset = 0
    @Published private(set) var leadingBlockTotal = 0
    @Published private(set) var loadingEarlier = false
    private let earlierPageSize = 40
    private let earlierBlockPageSize = 40
    var canLoadEarlier: Bool { leadingBlockOffset > 0 || loadedOffset > 0 }
    var displayTitle: String { snapshot?.displayTitle ?? "对话详情" }
    var titleGenerating: Bool { snapshot?.titleGenerating == true }

    let sessionId: String
    let api: WandAPI
    @Published private(set) var snapshot: SessionSnapshot?
    private let socket: WandSocket
    /// SwiftUI 的 NavigationStack 会在 pop 后短暂缓存 destination；同一个详情再次出现时，
    /// @StateObject 可能仍是原来的 ChatStore。active 区分「对象初始化过」与「页面当前可见」，
    /// 让关闭过 socket 的 store 能安全恢复，而不是被 started 守卫永久挡住。
    private var started = false
    private var active = false
    private var initialLoadInProgress = false
    private var queuePromotePending = false
    private var autoResumeAttempted = false
    /// 模型、思考与模式设置各自只接受最后一次请求的回包。三个接口都会返回完整
    /// SessionSnapshot，不能让较早回包通过 apply(snapshot:) 覆盖另一项的新选择。
    private var modelUpdateRevision = 0
    private var thinkingUpdateRevision = 0
    private var modeUpdateRevision = 0
    /// 模型、思考与模式共用同一条服务端 mutation 尾队列。revision 只能防旧回包改 UI，
    /// 串行队列进一步保证服务端按用户调用顺序处理，最终落盘不会 A/B 反序。
    private var settingsMutationTail: Task<Void, Never>?
    /// 模型切换把不支持的档位收敛为 off 后，等模型请求成功再串行提交思考设置。
    /// 快速再次切模型时由最新模型请求接管这次同步。
    private var thinkingEffortNeedsSync = false
    private var modelsLoaded = false
    /// 模型目录的普通加载与用户手动刷新可能重叠；只有最新请求可以写回 UI。
    private var modelCatalogRevision = 0

    var isStructured: Bool { snapshot?.isStructured ?? true }
    var sessionEnded: Bool { ["exited", "failed", "stopped"].contains(status) }

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
        self.socket = WandSocket(baseURL: api.baseURL)
        // init/resync/全量快照也按块级窗口下发（与 REST getSession 的 blockBudget 对齐）。
        self.socket.blockBudget = WandAPI.chatBlockWindow
    }

    // MARK: - 生命周期

    func start() {
        guard !active else {
            wlog("session", "start() 跳过 session=\(sessionId)（页面已激活）")
            return
        }
        active = true

        // 首次 REST 加载还没结束时也要立刻恢复实时连接。旧逻辑在这里直接 return，
        // 而上一次 shutdown 已关 socket，快速返回再打开会一直等 REST + 模型 + 配置
        // 三段请求收尾，看起来像页面卡死。
        guard !initialLoadInProgress else {
            wlog("session", "start() session=\(sessionId)（首次加载未完，立即恢复实时连接）")
            connectSocket()
            return
        }

        // destination 被 NavigationStack 复用时，重新打开已经关闭的 socket，并重新读取
        // 服务端当前缓存的模型目录。目录刷新由服务端负责，客户端只消费最新快照。
        guard !started else {
            wlog("session", "start() session=\(sessionId)（恢复缓存详情连接）")
            connectSocket()
            if snapshot != nil {
                Task { [weak self] in await self?.loadModels() }
            }
            return
        }
        started = true
        initialLoadInProgress = true
        wlog("session", "start() session=\(sessionId)")

        // WandSocket 的回调已保证主线程，用 assumeIsolated 接回 MainActor 隔离，
        // 不用 Task 包装——Task 不保证 FIFO，会打乱增量合流顺序。
        socket.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        socket.onConnectionChange = { [weak self] up in
            MainActor.assumeIsolated { self?.connected = up }
        }

        // 实时连接不能被模型目录、卡片默认值等辅助请求挡住。WS init 本身能提供一份
        // 会话快照；即使 REST 短暂失败，详情也有机会自行恢复。
        connectSocket()

        Task {
            var initialSnapshot: SessionSnapshot?
            do {
                let snap = try await api.getSession(id: sessionId)
                apply(snapshot: snap)
                initialSnapshot = snap
                wlog("session", "REST 快照 session=\(sessionId) msgs=\(snap.messages?.count ?? -1) status=\(snap.status ?? "?") structured=\(snap.isStructured) responding=\(snap.isResponding)")
            } catch {
                loadError = error.localizedDescription
                wlog("session", "REST 快照失败 session=\(sessionId): \(error.localizedDescription)")
            }
            loading = false
            initialLoadInProgress = false

            // 模型和卡片偏好不影响会话可操作性，后台加载即可。模型依赖 snapshot 的
            // provider，所以只在 REST 拿到快照后发起，避免用 Claude 默认值误判。
            if initialSnapshot != nil {
                Task { [weak self] in await self?.loadModels() }
            }
            Task { [weak self] in await self?.loadCardDefaults() }

            if active, let initialSnapshot {
                await autoResumeFailedPtyIfNeeded(initialSnapshot)
            }
        }
    }

    /// 先登记订阅再连接：覆盖首次 REST 尚未完成时快速返回、socket 从未订阅过的情形。
    private func connectSocket() {
        socket.subscribe(sessionId: sessionId)
        socket.connect()
    }

    func shutdown() {
        guard active else { return }
        active = false
        connected = false
        wlog("session", "shutdown() session=\(sessionId)（视图销毁，关闭 socket）")
        socket.close()
    }

    /// 回前台健康检查：先判断再行动，避免无谓重连。
    /// connect() 每次会 generation += 1 新建 task，幂等但有握手成本，所以用 connected 守卫；
    /// 无论是否重连都拉一份最新快照（requestResync 未订阅时自身 no-op），消除后台期间可能的过期状态。
    func handleEnterForeground() {
        if !connected { socket.connect() }
        socket.requestResync()
        if snapshot != nil {
            Task { [weak self] in await self?.loadModels() }
        }
    }

    /// 退后台：本期刻意不 close()。
    /// iOS 进后台会很快冻结 socket，回前台时 handleEnterForeground 已做健康检查 + 重连，
    /// 主动 close 只会徒增回前台的重连延迟。留作 no-op；若实测后台耗电明显再改为 socket.close()。
    func handleEnterBackground() {
        // no-op（见上方注释的取舍说明）
    }

    // MARK: - 推送合流

    /// 应用一份「窗口化」快照消息（init / 全量 output / ended / REST）。
    /// 关键约束：
    ///   - 绝不用「空」覆盖「非空」——停止/重连/丢帧时服务端可能回推空 messages，
    ///     直接赋值会清光历史（用户报「点停止后历史没了」）。
    ///   - 不丢弃用户已翻页加载的更早消息——快照只含尾部窗口时，把本地比该窗口更早的
    ///     前缀拼回去，再接上快照尾部。
    private func applyWindowedMessages(
        _ incoming: [ConversationTurn]?, offset: Int?, total: Int?,
        leadingOffset: Int? = nil, leadingTotal: Int? = nil
    ) {
        applyMessageWindow(
            mergingWindowedMessages(
                current: messageWindow,
                incoming: incoming,
                offset: offset,
                total: total,
                leadingOffset: leadingOffset,
                leadingTotal: leadingTotal
            )
        )
    }

    private var messageWindow: SessionMessageWindow {
        SessionMessageWindow(
            messages: messages,
            loadedOffset: loadedOffset,
            messageTotal: messageTotal,
            leadingBlockOffset: leadingBlockOffset,
            leadingBlockTotal: leadingBlockTotal
        )
    }

    private func applyMessageWindow(_ window: SessionMessageWindow) {
        messages = window.messages
        loadedOffset = window.loadedOffset
        messageTotal = window.messageTotal
        leadingBlockOffset = window.leadingBlockOffset
        leadingBlockTotal = window.leadingBlockTotal
    }

    private func apply(snapshot snap: SessionSnapshot) {
        self.snapshot = snap
        applyWindowedMessages(snap.messages, offset: snap.messageOffset, total: snap.messageTotal,
                              leadingOffset: snap.leadingBlockOffset, leadingTotal: snap.leadingBlockTotal)
        status = snap.status ?? status
        isResponding = snap.isResponding
        queuedMessages = snap.queuedMessages ?? []
        pendingEscalation = snap.pendingEscalation
        permissionBlocked = snap.permissionBlocked ?? (snap.pendingEscalation != nil)
        currentTaskTitle = snap.currentTaskTitle
        selectedModel = snap.selectedModel
        thinkingEffort = snap.thinkingEffort ?? "off"
        mode = snap.mode ?? mode
        if snap.pendingEscalation != nil { legacyPermissionPrompt = nil }
        publishPresence()
    }

    private func publishPresence() {
        guard let snapshot else { return }
        if sessionEnded {
            SessionPresenceController.shared.end(sessionId: sessionId, immediately: true)
        } else if pendingEscalation != nil || permissionBlocked || legacyPermissionPrompt != nil {
            SessionPresenceController.shared.start(
                sessionId: sessionId,
                title: snapshot.displayTitle,
                provider: snapshot.provider,
                state: .permission,
                taskTitle: currentTaskTitle,
                queuedCount: queuedMessages.count
            )
        } else if isResponding {
            SessionPresenceController.shared.start(
                sessionId: sessionId,
                title: snapshot.displayTitle,
                provider: snapshot.provider,
                taskTitle: currentTaskTitle,
                queuedCount: queuedMessages.count
            )
        } else {
            SessionPresenceController.shared.end(sessionId: sessionId)
        }
    }

    private func handle(_ event: WsIncoming) {
        guard event.sessionId == sessionId || event.sessionId == nil else {
            wlog("ws", "丢弃事件 type=\(event.type) 来自 session=\(event.sessionId ?? "nil")，当前 session=\(sessionId)")
            return
        }
        switch event.type {
        case "init":
            if let data = event.data {
                applyWsSnapshot(data)
                // REST 失败后若 WS init 成功，说明详情已经可用，不能继续保留失败页。
                loadError = nil
                loading = false
                wlog("ws", "init session=\(sessionId) msgs=\(data.messages?.count ?? -1) status=\(data.status ?? "?")")
            }
        case "output":
            if let data = event.data { applyOutput(data) }
        case "status":
            if let data = event.data { applyStatus(data) }
        case "ended":
            if let data = event.data {
                applyWindowedMessages(data.messages, offset: data.messageOffset, total: data.messageTotal,
                                      leadingOffset: data.leadingBlockOffset, leadingTotal: data.leadingBlockTotal)
                status = data.status ?? "exited"
                isResponding = false
                applyCommonFields(data)
            } else {
                status = "exited"
                isResponding = false
            }
            publishPresence()
        case "error":
            if let message = event.error, !message.isEmpty {
                toast = message
                wlog("ws", "error session=\(sessionId): \(message)")
            }
        default:
            break
        }
    }

    /// init 的 data 就是一份完整 SessionSnapshot（以 WsData 超集形状承接）。
    private func applyWsSnapshot(_ data: WsData) {
        applyWindowedMessages(data.messages, offset: data.messageOffset, total: data.messageTotal,
                              leadingOffset: data.leadingBlockOffset, leadingTotal: data.leadingBlockTotal)
        status = data.status ?? status
        if let s = data.structuredState { isResponding = s.inFlight ?? false }
        applyCommonFields(data)
        if snapshot == nil, let id = data.id {
            // 极端情况：REST 快照还没回来 WS init 先到，补一份最小 snapshot。
            snapshot = SessionSnapshot(
                id: id, sessionKind: data.sessionKind, provider: data.provider,
                runner: data.runner, command: data.command, cwd: data.cwd,
                mode: data.mode, status: data.status, exitCode: data.exitCode,
                startedAt: data.startedAt, endedAt: data.endedAt, archived: data.archived,
                summary: data.summary, currentTaskTitle: data.currentTaskTitle,
                selectedModel: data.selectedModel, thinkingEffort: data.thinkingEffort,
                claudeSessionId: data.claudeSessionId,
                messages: nil, messageOffset: data.messageOffset, messageTotal: data.messageTotal,
                queuedMessages: data.queuedMessages,
                structuredState: data.structuredState, pendingEscalation: data.pendingEscalation,
                permissionBlocked: data.permissionBlocked,
                autoApprovePermissions: data.autoApprovePermissions
            )
            snapshot?.title = data.title
            snapshot?.description = data.description
            snapshot?.titleGenerating = data.titleGenerating
        }
        publishPresence()
    }

    private func applyOutput(_ data: WsData) {
        let incremental = data.incremental ?? false
        if let msgs = data.messages {
            // 全量赢（窗口合并：空不覆盖非空、保留已加载的更早前缀）。
            applyWindowedMessages(msgs, offset: data.messageOffset, total: data.messageTotal,
                                  leadingOffset: data.leadingBlockOffset, leadingTotal: data.leadingBlockTotal)
        } else if incremental, let incoming = data.lastMessage {
            applyMessageWindow(
                applyingIncrementalMessage(
                    incoming,
                    expectedCount: data.messageCount ?? 0,
                    to: messageWindow
                )
            )
        }
        if let responding = data.isResponding { isResponding = responding }
        applyCommonFields(data)
        publishPresence()
    }

    private func applyStatus(_ data: WsData) {
        if let s = data.status { status = s }
        applyCommonFields(data)
        // PTY 旧式权限提示：status 事件带 permissionRequest（无结构化 escalation 时启用）。
        if let prompt = data.permissionRequest, pendingEscalation == nil {
            legacyPermissionPrompt = prompt
            permissionBlocked = true
        }
        publishPresence()
    }

    private func applyCommonFields(_ data: WsData) {
        if let title = data.title { snapshot?.title = title }
        if let description = data.description { snapshot?.description = description }
        if let summary = data.summary, snapshot?.summary != summary {
            snapshot = snapshot.map { current in
                var updated = current
                updated.summary = summary
                return updated
            }
        }
        if let generating = data.titleGenerating { snapshot?.titleGenerating = generating }
        if let s = data.structuredState { isResponding = s.inFlight ?? isResponding }
        if let q = data.queuedMessages { queuedMessages = q }
        if let esc = data.pendingEscalation {
            pendingEscalation = esc
            legacyPermissionPrompt = nil
        }
        if let blocked = data.permissionBlocked {
            permissionBlocked = blocked
            if !blocked {
                pendingEscalation = nil
                legacyPermissionPrompt = nil
            }
        }
        if let title = data.currentTaskTitle { currentTaskTitle = title }
        if let model = data.selectedModel { selectedModel = model }
        if let effort = data.thinkingEffort { thinkingEffort = effort }
        if let m = data.mode { mode = m }
    }

    // MARK: - 用户动作

    /// 发送一条消息。PTY 会话走 chat 视图语义：文本和 Enter 分两次发，
    /// 对齐 Web 端 getTerminalSubmitChunks，避免回车被并入粘贴内容。
    func send(text: String, forcePtyChat: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let structured = forcePtyChat ? false : isStructured
        let queueing = structured && isResponding && status == "running"
        if queueing, lastSubmittedStructuredInput() == trimmed {
            toast = "与上一条消息相同，已忽略，不会加入排队。"
            return
        }
        let previousMessages = messages
        let previousQueue = queuedMessages
        if structured {
            if queueing {
                queuedMessages.append(trimmed)
                toast = "已加入排队，等当前回复完成会自动发送。"
            } else {
                messages.append(ConversationTurn(role: "user", content: [.text(text: trimmed, subagent: nil)]))
                isResponding = true
            }
            publishPresence()
        }
        Task {
            do {
                if structured {
                    // 结构化回复通过事件流持续更新；HTTP 只需确认服务端已接收。
                    // 若等待整轮完成，首轮生成标题与模型回复可能超过 30 秒并被误报为网络超时。
                    let accepted = try await api.sendInput(
                        id: sessionId,
                        input: trimmed,
                        respondImmediately: !queueing
                    )
                    // HTTP 202 已包含服务端刚接受的 canonical snapshot。立刻应用它，
                    // 再向 socket 请求一次校准：这样 WS 正在重连/首帧丢失时，发送后也
                    // 不会停在乐观 loading 状态直到下一条推送到来。
                    apply(snapshot: accepted)
                    socket.requestResync()
                } else {
                    try await sendPtyChatInput(trimmed)
                }
            } catch {
                toast = error.localizedDescription
                if structured {
                    if queueing { queuedMessages = previousQueue }
                    else {
                        messages = previousMessages
                        isResponding = false
                    }
                }
            }
        }
    }

    private func lastSubmittedStructuredInput() -> String? {
        if let queued = queuedMessages.reversed()
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return queued
        }
        guard let lastUser = messages.reversed().first(where: { $0.role == "user" }) else { return nil }
        let text = lastUser.content.compactMap { block -> String? in
            if case .text(let value, _) = block { return value }
            return nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        for block in lastUser.content {
            if case .toolResult(_, let value, _, _, _) = block {
                let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return result.isEmpty ? nil : result
            }
        }
        return nil
    }

    private func sendPtyChatInput(_ text: String) async throws {
        try await sendPtyInput(text, view: "chat")
    }

    func sendPtyTerminalInput(_ text: String) async throws {
        try await sendPtyInput(text, view: "terminal")
    }

    private func sendPtyInput(_ text: String, view: String) async throws {
        try await ensurePtyRunningForInput()
        let submission = ptyInputSubmission(text: text, view: view)
        let textSnapshot = try await api.sendInput(
            id: sessionId,
            input: submission.text.input,
            view: submission.text.view,
            shortcutKey: submission.text.shortcutKey
        )
        apply(snapshot: textSnapshot)
        try await Task.sleep(nanoseconds: 30_000_000)
        let enterSnapshot = try await api.sendInput(
            id: sessionId,
            input: submission.enter.input,
            view: submission.enter.view,
            shortcutKey: submission.enter.shortcutKey
        )
        apply(snapshot: enterSnapshot)
    }

    private func ensurePtyRunningForInput() async throws {
        guard !isStructured, status != "running" else { return }
        toast = "正在恢复会话…"
        _ = try await resumeEndedPtySession(showToast: false)
    }

    private func shouldAutoResumeFailedPty(_ snap: SessionSnapshot) -> Bool {
        guard !snap.isStructured else { return false }
        guard snap.status == "failed" else { return false }
        return !(snap.claudeSessionId ?? "").isEmpty
    }

    private func autoResumeFailedPtyIfNeeded(_ snap: SessionSnapshot) async {
        guard !autoResumeAttempted, shouldAutoResumeFailedPty(snap) else { return }
        autoResumeAttempted = true
        toast = "正在恢复失败会话…"
        do {
            _ = try await resumeEndedPtySession(showToast: false)
            toast = "会话已恢复"
        } catch {
            toast = error.localizedDescription
        }
    }

    @discardableResult
    private func resumeEndedPtySession(showToast: Bool) async throws -> SessionSnapshot {
        let snap = try await api.resumeSession(id: sessionId)
        apply(snapshot: snap)
        socket.requestResync()
        if showToast { toast = "会话已恢复" }
        return snap
    }

    func setModel(_ model: String?) {
        let previousModel = selectedModel
        let previousThinkingEffort = thinkingEffort
        let previouslyNeededThinkingSync = thinkingEffortNeedsSync

        modelUpdateRevision &+= 1
        let modelRevision = modelUpdateRevision
        selectedModel = model

        let initialThinkingRevision = claimThinkingResetIfNeeded(model: model)
        enqueueSettingsMutation { [self] in
            let modelSnapshot: SessionSnapshot
            do {
                modelSnapshot = try await api.setModel(id: sessionId, model: model)
            } catch {
                guard modelRevision == modelUpdateRevision else { return }
                selectedModel = previousModel
                var retryPendingAutoReset = false
                if let initialThinkingRevision,
                   initialThinkingRevision == thinkingUpdateRevision {
                    thinkingEffort = previousThinkingEffort
                    thinkingEffortNeedsSync = previouslyNeededThinkingSync
                    retryPendingAutoReset = previouslyNeededThinkingSync
                }
                toast = error.localizedDescription
                if retryPendingAutoReset
                    || !supportsThinkingEffort(thinkingEffort, model: previousModel) {
                    setThinkingEffort("off")
                }
                return
            }

            guard modelRevision == modelUpdateRevision else { return }
            // 此接口只确认模型字段；完整快照里的 thinkingEffort 可能已落后。
            selectedModel = modelSnapshot.selectedModel

            let thinkingRevision = initialThinkingRevision
                ?? claimThinkingResetIfNeeded(model: modelSnapshot.selectedModel)
            guard let thinkingRevision,
                  thinkingRevision == thinkingUpdateRevision else { return }

            do {
                let effortSnapshot = try await api.setThinkingEffort(
                    id: sessionId,
                    thinkingEffort: "off"
                )
                guard modelRevision == modelUpdateRevision,
                      thinkingRevision == thinkingUpdateRevision else { return }
                thinkingEffort = effortSnapshot.thinkingEffort ?? "off"
                thinkingEffortNeedsSync = false
            } catch {
                guard modelRevision == modelUpdateRevision,
                      thinkingRevision == thinkingUpdateRevision else { return }
                // 模型已由服务端接受，不能把它回滚成只存在于本地的旧值。
                thinkingEffort = modelSnapshot.thinkingEffort ?? previousThinkingEffort
                thinkingEffortNeedsSync = true
                toast = error.localizedDescription
            }
        }
    }

    func setThinkingEffort(_ effort: String) {
        let previous = thinkingEffort
        let previouslyNeededSync = thinkingEffortNeedsSync

        thinkingUpdateRevision &+= 1
        let revision = thinkingUpdateRevision
        thinkingEffortNeedsSync = false
        thinkingEffort = effort
        enqueueSettingsMutation { [self] in
            do {
                let snap = try await api.setThinkingEffort(id: sessionId, thinkingEffort: effort)
                guard revision == thinkingUpdateRevision else { return }
                // 此接口只确认思考字段；完整快照里的 selectedModel 可能已落后。
                thinkingEffort = snap.thinkingEffort ?? effort
            } catch {
                guard revision == thinkingUpdateRevision else { return }
                thinkingEffort = previous
                thinkingEffortNeedsSync = previouslyNeededSync
                toast = error.localizedDescription
            }
        }
    }

    private func enqueueSettingsMutation(
        _ mutation: @escaping @MainActor () async -> Void
    ) {
        let previous = settingsMutationTail
        settingsMutationTail = Task { @MainActor in
            _ = await previous?.result
            await mutation()
        }
    }

    /// 返回本次自动 off 同步所拥有的 revision；nil 表示当前档位有效且无需补写。
    private func claimThinkingResetIfNeeded(model: String?) -> Int? {
        if !supportsThinkingEffort(thinkingEffort, model: model) {
            thinkingEffort = "off"
            thinkingEffortNeedsSync = true
        }
        guard thinkingEffortNeedsSync else { return nil }
        thinkingUpdateRevision &+= 1
        return thinkingUpdateRevision
    }

    private func supportsThinkingEffort(_ effort: String, model: String?) -> Bool {
        let provider = WandProvider(normalizing: snapshot?.provider).rawValue
        // Codex 档位依赖模型目录；目录还没回来时不能拿 legacy 回退误判动态档位。
        if provider == WandProvider.codex.rawValue && !modelsLoaded { return true }
        return thinkingEffortOptions(
            provider: provider,
            selectedModel: model,
            defaultModel: defaultModel,
            models: availableModels
        ).contains { $0.id == effort }
    }

    /// 中途切换执行模式（乐观更新，失败回滚）。codex 会话固定 full-access，调用方负责拦。
    func setMode(_ newMode: String) {
        let previous = mode
        modeUpdateRevision &+= 1
        let revision = modeUpdateRevision
        mode = newMode
        enqueueSettingsMutation { [self] in
            do {
                let snap = try await api.setMode(id: sessionId, mode: newMode)
                guard revision == modeUpdateRevision else { return }
                // 此接口只确认模式字段，避免完整快照覆盖模型或思考的新选择。
                mode = snap.mode ?? newMode
            } catch {
                guard revision == modeUpdateRevision else { return }
                mode = previous
                toast = error.localizedDescription
            }
        }
    }

    /// 从服务端读取当前持久化目录。`modelCatalogRevision` 只用于忽略过期 GET 回包；
    /// CLI 探测与缓存更新由服务端的自动/管理员刷新完成。
    private func loadModels() async {
        modelCatalogRevision &+= 1
        let revision = modelCatalogRevision
        let thinkingRevision = thinkingUpdateRevision

        let response: ModelsResponse
        do {
            response = try await api.models()
        } catch {
            guard revision == modelCatalogRevision else { return }
            return
        }
        guard !Task.isCancelled, revision == modelCatalogRevision else { return }
        let provider = WandProvider(normalizing: snapshot?.provider).rawValue
        availableModels = response.models(for: provider)
        defaultModel = response.defaultModelId(for: provider)
        modelsLoaded = true
        // 刷新过程中用户若已手动调整思考档位，不能让旧请求回包替他重置选择。
        if thinkingRevision == thinkingUpdateRevision,
           !supportsThinkingEffort(thinkingEffort, model: selectedModel) {
            setThinkingEffort("off")
        }
    }

    private func loadCardDefaults() async {
        guard let config = try? await api.serverConfig() else {
            cardDefaults = CardExpandDefaults()
            return
        }
        cardDefaults = config.cardDefaults ?? CardExpandDefaults()
    }

    // MARK: - AskUserQuestion 交互（对齐 Web 端 __askSelect / __askSubmit）

    /// 点选一个选项：单选点同一项取消、换选项替换；多选逐项 toggle。已提交后不可改。
    func toggleAskOption(toolUseId: String, questionIndex: Int, optionIndex: Int, multiSelect: Bool) {
        var sel = askUserSelections[toolUseId] ?? AskUserSelectionState()
        guard !sel.submitted else { return }
        var current = sel.selected[questionIndex] ?? []
        if multiSelect {
            if current.contains(optionIndex) { current.remove(optionIndex) } else { current.insert(optionIndex) }
        } else {
            current = current.contains(optionIndex) ? [] : [optionIndex]
        }
        sel.selected[questionIndex] = current
        askUserSelections[toolUseId] = sel
    }

    /// 提交答案：每道题一行、同题多选 ", " 连接（对齐 Web），走与普通消息相同的输入通道。
    /// 答案不乐观插入用户气泡——服务端会把它作为 tool_result 回推、卡片转只读态。
    func submitAskUser(toolUseId: String, answerText: String) {
        var sel = askUserSelections[toolUseId] ?? AskUserSelectionState()
        guard !sel.submitted else { return }
        sel.submitted = true
        askUserSelections[toolUseId] = sel
        if isStructured { isResponding = true }
        Task {
            do {
                if isStructured {
                    try await api.sendInput(id: sessionId, input: answerText, respondImmediately: true)
                } else {
                    try await api.sendInput(id: sessionId, input: answerText + "\n", view: "chat")
                }
            } catch {
                toast = error.localizedDescription
                var rollback = askUserSelections[toolUseId] ?? AskUserSelectionState()
                rollback.submitted = false
                askUserSelections[toolUseId] = rollback
                if isStructured { isResponding = false }
            }
        }
    }

    /// 停止当前回复：结构化会话调 stop（杀掉当前回合），PTY 发 Esc 中断。
    func stopResponding(forcePtyChat: Bool = false) {
        Task {
            do {
                if !forcePtyChat && isStructured {
                    let snap = try await api.stopSession(id: sessionId)
                    apply(snapshot: snap)
                } else {
                    try await api.sendInput(id: sessionId, input: "\u{1B}", view: "chat", shortcutKey: "esc")
                }
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    /// 权限决策。结构化 escalation 走 resolve 端点；PTY 旧式提示走 approve/deny。
    func resolvePermission(_ resolution: String) {
        if let esc = pendingEscalation {
            pendingEscalation = nil
            permissionBlocked = false
            Task {
                do {
                    let snap = try await api.resolveEscalation(sessionId: sessionId, requestId: esc.requestId, resolution: resolution)
                    apply(snapshot: snap)
                } catch {
                    toast = error.localizedDescription
                    socket.requestResync()
                }
            }
        } else if legacyPermissionPrompt != nil {
            legacyPermissionPrompt = nil
            permissionBlocked = false
            Task {
                do {
                    let snap: SessionSnapshot
                    if resolution == "deny" {
                        snap = try await api.denyPermission(sessionId: sessionId)
                    } else {
                        snap = try await api.approvePermission(sessionId: sessionId)
                    }
                    apply(snapshot: snap)
                } catch {
                    toast = error.localizedDescription
                    socket.requestResync()
                }
            }
        }
    }

    // MARK: - 排队消息

    /// 当前是否处于「inFlight」（结构化会话且 running 时回复在跑），用于判断 promote 是否要 interrupt。
    var queueInFlight: Bool {
        isStructured && status == "running" && isResponding
    }

    /// 立即发送第 index 条排队消息（乐观剥掉本地、失败回滚）。对齐 Web queueBarPromoteIndex。
    func promoteQueued(index: Int) {
        guard isStructured else { return }
        guard !queuePromotePending else { return }
        let queue = queuedMessages
        guard index >= 0, index < queue.count else { return }
        let picked = queue[index]
        let previous = queue
        let next = Array(queue[..<index]) + Array(queue[(index + 1)...])
        let inFlight = queueInFlight
        queuePromotePending = true
        queuedMessages = next
        toast = inFlight ? "已请求中断当前回复，立即发送这条。" : "已立即发送这条消息。"
        Task {
            do {
                let snap = try await api.promoteQueued(id: sessionId, index: index, expectedText: picked)
                apply(snapshot: snap)
            } catch {
                queuedMessages = previous
                toast = error.localizedDescription
            }
            queuePromotePending = false
        }
    }

    /// 删除第 index 条排队消息（乐观剥掉本地、失败回滚）。
    func deleteQueued(index: Int) {
        guard isStructured else { return }
        let queue = queuedMessages
        guard index >= 0, index < queue.count else { return }
        let previous = queue
        queuedMessages = Array(queue[..<index]) + Array(queue[(index + 1)...])
        Task {
            do {
                try await api.deleteQueued(id: sessionId, index: index)
            } catch {
                queuedMessages = previous
                toast = error.localizedDescription
            }
        }
    }

    /// 清空全部排队消息（乐观清空、失败回滚）。
    func clearQueued() {
        guard isStructured else { return }
        let previous = queuedMessages
        guard !previous.isEmpty else { return }
        queuedMessages = []
        Task {
            do {
                try await api.clearQueued(id: sessionId)
                toast = "已清空 \(previous.count) 条排队消息。"
            } catch {
                queuedMessages = previous
                toast = error.localizedDescription
            }
        }
    }

    /// 加载更早的一页（滚动到顶时触发）。两阶段：先按「块」翻完 messages[0] 这条 turn
    /// 被切掉的头部（块级窗口），再按「整条 turn」往前翻更早的会话。
    func loadEarlier() {
        guard !loadingEarlier else { return }
        if leadingBlockOffset > 0 {
            loadEarlierBlocks()
        } else if loadedOffset > 0 {
            loadEarlierTurns()
        }
    }

    /// 翻 messages[0] 更早的块：把这条 turn 被切掉的头部按页 prepend 回它的 content。
    private func loadEarlierBlocks() {
        let turnIndex = loadedOffset
        let currentBlockOffset = leadingBlockOffset
        let leadingRole = messages.first?.role
        guard currentBlockOffset > 0, let leadingRole else { return }
        loadingEarlier = true
        Task {
            do {
                let page = try await api.fetchEarlierBlocks(
                    id: sessionId, turn: turnIndex,
                    blockOffset: currentBlockOffset, blockLimit: earlierBlockPageSize
                )
                // 仅当起点没被其它更新改动、且 messages[0] 仍是同一条 turn 时才 prepend，避免错位。
                if loadedOffset == turnIndex, leadingBlockOffset == currentBlockOffset,
                   let head = messages.first, head.role == leadingRole, !page.blocks.isEmpty {
                    messages[0] = ConversationTurn(role: head.role, content: page.blocks + head.content)
                    leadingBlockOffset = page.blockOffset
                    leadingBlockTotal = max(leadingBlockTotal, page.blockTotal)
                }
            } catch {
                toast = error.localizedDescription
            }
            loadingEarlier = false
        }
    }

    /// 翻更早的整条 turn：messages[0] 已完整、其前面还有更早 turn 时，prepend 整条并前移 loadedOffset。
    private func loadEarlierTurns() {
        let currentOffset = loadedOffset
        let newOffset = max(0, currentOffset - earlierPageSize)
        let limit = currentOffset - newOffset
        guard limit > 0 else { return }
        loadingEarlier = true
        Task {
            do {
                let page = try await api.fetchMessages(id: sessionId, offset: newOffset, limit: limit)
                // 仅当本地起点没被其它更新改动时才 prepend，避免错位重复。
                if loadedOffset == currentOffset {
                    messages.insert(contentsOf: page.messages, at: 0)
                    loadedOffset = newOffset
                    messageTotal = max(messageTotal, page.total)
                    // 整条翻页拿到的最旧一条是完整 turn，leading 归零并指向新的 messages[0]。
                    leadingBlockOffset = 0
                    leadingBlockTotal = messages.first?.content.count ?? 0
                }
            } catch {
                toast = error.localizedDescription
            }
            loadingEarlier = false
        }
    }

    /// 会话已结束时按 claudeSessionId 原地恢复（服务端 reuseId 复用本会话）。
    func resume() {
        Task {
            do {
                _ = try await resumeEndedPtySession(showToast: true)
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}
