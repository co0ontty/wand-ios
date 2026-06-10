import Foundation
import Combine

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

    let sessionId: String
    let api: WandAPI
    @Published private(set) var snapshot: SessionSnapshot?
    private let socket: WandSocket
    private var started = false

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
            socket.connect()
            socket.subscribe(sessionId: sessionId)
        }
    }

    func shutdown() {
        socket.close()
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
        if snap.pendingEscalation != nil { legacyPermissionPrompt = nil }
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
                selectedModel: data.selectedModel, claudeSessionId: data.claudeSessionId,
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
