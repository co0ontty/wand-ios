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
    @Published var selectedModel: String?
    @Published var thinkingEffort = "off"
    /// AskUserQuestion 卡片的选择状态（toolUseId → 各题已选项 + 是否已提交）。
    /// 放 store 而非卡片 @State：流式推送会整条替换消息重建视图，局部状态会丢。
    @Published var askUserSelections: [String: AskUserSelectionState] = [:]

    let sessionId: String
    let api: WandAPI
    @Published private(set) var snapshot: SessionSnapshot?
    private let socket: WandSocket
    private var started = false

    // Live Activity（灵动岛）状态：started = 本会话当前在聚合长条里有条目；
    // sawResponding 防止 PTY 会话在 isResponding 尚未变 true 时被立即收掉。
    private var liveActivityStarted = false
    private var liveActivitySawResponding = false

    var isStructured: Bool { snapshot?.isStructured ?? true }
    var sessionEnded: Bool { ["exited", "failed", "stopped"].contains(status) }

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
        self.socket = WandSocket(baseURL: api.baseURL)
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        // WandSocket 的回调已保证主线程，用 assumeIsolated 接回 MainActor 隔离，
        // 不用 Task 包装——Task 不保证 FIFO，会打乱增量合流顺序。
        socket.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        socket.onConnectionChange = { [weak self] up in
            MainActor.assumeIsolated { self?.connected = up }
        }

        Task {
            do {
                let snap = try await api.getSession(id: sessionId)
                apply(snapshot: snap)
                loading = false
            } catch {
                loading = false
                loadError = error.localizedDescription
            }
            await loadModels()
            socket.connect()
            socket.subscribe(sessionId: sessionId)
        }
    }

    func shutdown() {
        socket.close()
    }

    /// 回前台健康检查：先判断再行动，避免无谓重连。
    /// connect() 每次会 generation += 1 新建 task，幂等但有握手成本，所以用 connected 守卫；
    /// 无论是否重连都拉一份最新快照（requestResync 未订阅时自身 no-op），消除后台期间可能的过期状态。
    func handleEnterForeground() {
        if !connected { socket.connect() }
        socket.requestResync()
    }

    /// 退后台：本期刻意不 close()。
    /// iOS 进后台会很快冻结 socket，回前台时 handleEnterForeground 已做健康检查 + 重连，
    /// 主动 close 只会徒增回前台的重连延迟。留作 no-op；若实测后台耗电明显再改为 socket.close()。
    func handleEnterBackground() {
        // no-op（见上方注释的取舍说明）
    }

    // MARK: - 推送合流

    private func apply(snapshot snap: SessionSnapshot) {
        self.snapshot = snap
        if let msgs = snap.messages { messages = msgs }
        status = snap.status ?? status
        isResponding = snap.isResponding
        queuedMessages = snap.queuedMessages ?? []
        pendingEscalation = snap.pendingEscalation
        permissionBlocked = snap.permissionBlocked ?? (snap.pendingEscalation != nil)
        currentTaskTitle = snap.currentTaskTitle
        selectedModel = snap.selectedModel
        thinkingEffort = snap.thinkingEffort ?? "off"
        if snap.pendingEscalation != nil { legacyPermissionPrompt = nil }
        refreshLiveActivity()
    }

    private func handle(_ event: WsIncoming) {
        guard event.sessionId == sessionId || event.sessionId == nil else { return }
        switch event.type {
        case "init":
            if let data = event.data {
                applyWsSnapshot(data)
                loading = false
            }
        case "output":
            if let data = event.data { applyOutput(data) }
        case "status":
            if let data = event.data { applyStatus(data) }
        case "ended":
            if let data = event.data {
                if let msgs = data.messages { messages = msgs }
                status = data.status ?? "exited"
                isResponding = false
                applyCommonFields(data)
            } else {
                status = "exited"
                isResponding = false
            }
        case "error":
            if let message = event.error, !message.isEmpty { toast = message }
        default:
            break
        }
        refreshLiveActivity()
    }

    // MARK: - Live Activity（灵动岛）

    /// 按当前状态同步 Live Activity：回复中 / 待授权更新；
    /// 会话退出 / 被杀立即从聚合长条里移除（不展示结束态）；
    /// 回复成功结束则切「已完成」短暂保留后由控制器自动移除。
    private func refreshLiveActivity() {
        if sessionEnded {
            SessionLiveActivityController.shared.end(sessionId: sessionId, immediately: true)
            liveActivityStarted = false
            liveActivitySawResponding = false
        } else if permissionBlocked {
            liveActivitySawResponding = true
            SessionLiveActivityController.shared.start(
                sessionId: sessionId, title: snapshot?.displayTitle ?? "Wand 会话",
                provider: snapshot?.provider, state: .permission, taskTitle: currentTaskTitle,
                queuedCount: queuedMessages.count
            )
            liveActivityStarted = true
        } else if isResponding {
            liveActivitySawResponding = true
            SessionLiveActivityController.shared.start(
                sessionId: sessionId, title: snapshot?.displayTitle ?? "Wand 会话",
                provider: snapshot?.provider, taskTitle: currentTaskTitle,
                queuedCount: queuedMessages.count
            )
            liveActivityStarted = true
        } else if liveActivitySawResponding {
            SessionLiveActivityController.shared.end(sessionId: sessionId)
            liveActivityStarted = false
            liveActivitySawResponding = false
        }
    }

    /// init 的 data 就是一份完整 SessionSnapshot（以 WsData 超集形状承接）。
    private func applyWsSnapshot(_ data: WsData) {
        if let msgs = data.messages { messages = msgs }
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
                messages: nil, queuedMessages: data.queuedMessages,
                structuredState: data.structuredState, pendingEscalation: data.pendingEscalation,
                permissionBlocked: data.permissionBlocked,
                autoApprovePermissions: data.autoApprovePermissions
            )
        }
    }

    private func applyOutput(_ data: WsData) {
        let incremental = data.incremental ?? false
        if let msgs = data.messages {
            // 全量赢
            messages = msgs
        } else if incremental, let incoming = data.lastMessage {
            let expected = data.messageCount ?? 0
            if let last = messages.last, last.role == incoming.role {
                messages[messages.count - 1] = incoming
            } else if messages.count < expected || expected == 0 {
                messages.append(incoming)
            }
        }
        if let responding = data.isResponding { isResponding = responding }
        applyCommonFields(data)
    }

    private func applyStatus(_ data: WsData) {
        if let s = data.status { status = s }
        applyCommonFields(data)
        // PTY 旧式权限提示：status 事件带 permissionRequest（无结构化 escalation 时启用）。
        if let prompt = data.permissionRequest, pendingEscalation == nil {
            legacyPermissionPrompt = prompt
            permissionBlocked = true
        }
    }

    private func applyCommonFields(_ data: WsData) {
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
    }

    // MARK: - 用户动作

    /// 发送一条消息。PTY 会话走 chat 视图语义（结尾补换行），结构化会话直接发文本。
    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 乐观插入用户消息，等服务端推送修正。
        if isStructured {
            messages.append(ConversationTurn(role: "user", content: [.text(text: trimmed, subagent: nil)]))
            isResponding = true
        }
        // 把本会话加入灵动岛聚合长条（开关关闭 / iOS < 16.1 时是 no-op）。
        SessionLiveActivityController.shared.start(
            sessionId: sessionId,
            title: snapshot?.displayTitle ?? "Wand 会话",
            provider: snapshot?.provider,
            taskTitle: currentTaskTitle,
            queuedCount: queuedMessages.count
        )
        liveActivityStarted = true
        liveActivitySawResponding = isStructured
        Task {
            do {
                if isStructured {
                    try await api.sendInput(id: sessionId, input: trimmed)
                } else {
                    try await api.sendInput(id: sessionId, input: trimmed + "\n", view: "chat")
                }
            } catch {
                toast = error.localizedDescription
                if isStructured { isResponding = false }
                SessionLiveActivityController.shared.end(sessionId: sessionId, immediately: true)
                liveActivityStarted = false
                liveActivitySawResponding = false
            }
        }
    }

    func setModel(_ model: String?) {
        let previous = selectedModel
        selectedModel = model
        Task {
            do {
                let snap = try await api.setModel(id: sessionId, model: model)
                apply(snapshot: snap)
            } catch {
                selectedModel = previous
                toast = error.localizedDescription
            }
        }
    }

    func setThinkingEffort(_ effort: String) {
        let previous = thinkingEffort
        thinkingEffort = effort
        Task {
            do {
                let snap = try await api.setThinkingEffort(id: sessionId, thinkingEffort: effort)
                apply(snapshot: snap)
            } catch {
                thinkingEffort = previous
                toast = error.localizedDescription
            }
        }
    }

    private func loadModels() async {
        guard let response = try? await api.models() else { return }
        availableModels = snapshot?.provider == "codex" ? response.codexModels : response.models
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
                    try await api.sendInput(id: sessionId, input: answerText)
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
    func stopResponding() {
        Task {
            do {
                if isStructured {
                    try await api.stopSession(id: sessionId)
                    isResponding = false
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
                    if resolution == "deny" {
                        _ = try await api.denyPermission(sessionId: sessionId)
                    } else {
                        _ = try await api.approvePermission(sessionId: sessionId)
                    }
                } catch {
                    toast = error.localizedDescription
                    socket.requestResync()
                }
            }
        }
    }

    /// 会话已结束时按 claudeSessionId 原地恢复（服务端 reuseId 复用本会话）。
    func resume() {
        Task {
            do {
                let snap = try await api.resumeSession(id: sessionId)
                apply(snapshot: snap)
                socket.requestResync()
                toast = "会话已恢复"
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}
