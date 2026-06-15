import Foundation

/// /ws 的 WebSocket 客户端：订阅单个会话，处理 init/output/status/ended 推送、
/// 应用层 ping/pong、seq 间隙检测（自动 resync）、断线指数退避重连与 40s 看门狗。
/// 复用 SelfSignedSession 的 URLSession，自签证书与 session cookie 自动生效。
/// 所有状态读写与回调都在主线程上。
final class WandSocket {
    /// 解析后的服务端推送，主线程回调。
    var onEvent: ((WsIncoming) -> Void)?
    /// 连接状态变化（true=已连上），主线程回调。
    var onConnectionChange: ((Bool) -> Void)?

    private let baseURL: URL
    /// 块级窗口预算：>0 时在 subscribe 里带给服务端，init/resync/全量快照只下发最近这么多个块。
    var blockBudget: Int = 0
    private var task: URLSessionWebSocketTask?
    private var subscribedSessionId: String?
    private var lastSeqBySession: [String: Int] = [:]
    private var lastMessageAt = Date()
    private var watchdog: Timer?
    private var reconnectDelay: TimeInterval = 1
    private var closed = false
    /// 当前连接的代号，旧连接的回调用它识别后丢弃，避免互相干扰。
    private var generation = 0

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    deinit {
        watchdog?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - 生命周期

    func connect() {
        closed = false
        openSocket()
        startWatchdog()
    }

    func close() {
        closed = true
        watchdog?.invalidate()
        watchdog = nil
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func subscribe(sessionId: String) {
        subscribedSessionId = sessionId
        lastSeqBySession[sessionId] = nil
        sendJSON(subscribePayload(sessionId))
    }

    /// subscribe 负载：带上块级窗口预算（>0 时），让 init/resync 与全量快照都按块窗口化。
    private func subscribePayload(_ sessionId: String) -> [String: Any] {
        var payload: [String: Any] = ["type": "subscribe", "sessionId": sessionId]
        if blockBudget > 0 { payload["blockBudget"] = blockBudget }
        return payload
    }

    func requestResync() {
        guard let id = subscribedSessionId else { return }
        lastSeqBySession[id] = nil
        sendJSON(["type": "resync", "sessionId": id])
    }

    // MARK: - 内部

    private var wsURL: URL? {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        comps?.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        comps?.path = "/ws"
        comps?.query = nil
        return comps?.url
    }

    private func openSocket() {
        guard !closed, let url = wsURL else { return }
        wlog("ws", "openSocket \(url.absoluteString) session=\(subscribedSessionId ?? "nil")")
        generation += 1
        let gen = generation
        let socket = SelfSignedSession.shared.session.webSocketTask(with: url)
        // 默认 maximumMessageSize 仅 1 MiB：活跃会话的流式 output、init/resync 全量快照
        // （消息里塞满工具输出时）单帧轻松破 1MB，超限会让 receive 直接报错断开 ——
        // 表现为「每隔几秒断一次、不停重连」。浏览器 WebSocket 没有此限制，所以仅 iOS 受影响。
        // 调到 64 MiB，远超任何单条会话快照。
        socket.maximumMessageSize = 64 * 1024 * 1024
        task = socket
        lastMessageAt = Date()
        socket.resume()
        onConnectionChange?(true)
        // 重新订阅当前会话；服务端会推一份 init 快照，相当于天然 resync。
        if let id = subscribedSessionId {
            lastSeqBySession[id] = nil
            sendJSON(subscribePayload(id))
        }
        receiveNext(socket, generation: gen)
    }

    private func receiveNext(_ socket: URLSessionWebSocketTask, generation gen: Int) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let error):
                    let ns = error as NSError
                    wlog("ws", "receive 失败 domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
                    self.scheduleReconnect()
                case .success(let message):
                    self.lastMessageAt = Date()
                    self.reconnectDelay = 1
                    if case .string(let text) = message {
                        self.handleText(text)
                    }
                    self.receiveNext(socket, generation: gen)
                }
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let incoming = try? JSONDecoder().decode(WsIncoming.self, from: data) else { return }

        switch incoming.type {
        case "ping":
            sendJSON(["type": "pong", "t": incoming.t ?? 0])
            return
        case "resync_required":
            requestResync()
            return
        case "init":
            if let id = incoming.sessionId, let seq = incoming.seq {
                lastSeqBySession[id] = seq
            }
        case "output":
            // seq 间隙说明服务端因背压丢过事件，主动要一份全量快照。
            if let id = incoming.sessionId, let seq = incoming.seq {
                if let last = lastSeqBySession[id], seq > last + 1 {
                    wlog("ws", "seq 间隙 \(last)→\(seq)，请求 resync session=\(id)")
                    lastSeqBySession[id] = seq
                    requestResync()
                    return
                }
                lastSeqBySession[id] = seq
            }
        default:
            break
        }
        onEvent?(incoming)
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    // MARK: - 重连与看门狗

    private func scheduleReconnect() {
        guard !closed else { return }
        wlog("ws", "断线，\(reconnectDelay)s 后重连 session=\(subscribedSessionId ?? "nil")")
        onConnectionChange?(false)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed, self.task == nil else { return }
            self.openSocket()
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        // 服务端每 20s 发应用层 ping；40s 没收到任何消息视为半开连接，强制重建。
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, !self.closed, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastMessageAt) > 40 {
                wlog("ws", "看门狗：40s 无消息，强制重连 session=\(self.subscribedSessionId ?? "nil")")
                self.lastMessageAt = Date()
                self.scheduleReconnect()
            }
        }
    }
}
