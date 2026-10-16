import Foundation

/// UI-only transport. No PTY process ownership and no input replay on reconnect.
protocol PtySocketTransport: AnyObject {
    var onEvent: ((WsIncoming) -> Void)? { get set }
    var onConnectionChange: ((Bool) -> Void)? { get set }
    var onResync: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func connect()
    func close()
    func subscribe(sessionId: String, ptyAck: Bool)
    func requestResync()
    @discardableResult func sendPtyInput(_ text: String, userInput: Bool, shortcutKey: String?) -> Bool
    func resizePty(cols: Int, rows: Int)
    func acknowledgePty(bytes: Int)
    func reconnectForForeground()
}

final class WandSocket: PtySocketTransport {
    var onEvent: ((WsIncoming) -> Void)?
    var onConversationPreview: ((ConversationSessionUpdate) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onResync: (() -> Void)?
    var onError: ((String) -> Void)?
    var blockBudget = 0
    let endpointSession: SelfSignedSession
    private let baseURL: URL
    private let prepareConnection: (() async throws -> Void)?
    private var preparation: Task<Void, Never>?
    private var task: URLSessionWebSocketTask?
    private var subscribedSessionId: String?
    private var ptyAck = false
    private var awaitingSnapshot = true
    private var lastSeq: Int?
    private var lastMessageAt = Date()
    private var watchdog: Timer?
    private var reconnectDelay: TimeInterval = 1
    private var closed = true
    private var connected = false
    private var generation = 0
    private var sendQueue: [String] = []
    private var queuedBytes = 0
    private var sending = false
    private static let queueLimit = 2 * 1024 * 1024

    init(baseURL: URL, prepareConnection: (() async throws -> Void)? = nil) {
        self.baseURL = baseURL
        self.prepareConnection = prepareConnection
        endpointSession = SelfSignedSession.forEndpoint(baseURL)
    }
    deinit {
        preparation?.cancel(); watchdog?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
    }
    func connect() {
        guard closed, !endpointSession.isRetired else { return }
        closed = false; openSocket(); startWatchdog()
    }
    func close() {
        closed = true; watchdog?.invalidate(); watchdog = nil; invalidateConnection()
    }
    func subscribe(sessionId: String, ptyAck: Bool = false) {
        subscribedSessionId = sessionId; self.ptyAck = ptyAck
        awaitingSnapshot = true; lastSeq = nil; sendSubscription()
    }
    func subscriptionPayload() -> [String: Any]? {
        guard let id = subscribedSessionId else { return nil }
        var payload: [String: Any] = ["type": "subscribe", "sessionId": id, "capabilities": ["ptyAck": ptyAck]]
        if blockBudget > 0 { payload["blockBudget"] = blockBudget }
        return payload
    }
    private func sendSubscription() { if let payload = subscriptionPayload() { sendJSON(payload) } }
    func requestResync() {
        guard let id = subscribedSessionId else { return }
        awaitingSnapshot = true; onResync?()
        sendJSON(["type": "resync", "sessionId": id])
    }
    @discardableResult
    func sendPtyInput(_ text: String, userInput: Bool = true, shortcutKey: String? = nil) -> Bool {
        guard connected, !awaitingSnapshot, let id = subscribedSessionId else { return false }
        let frames = PtyTerminalInput.chunks(text).map { chunk -> [String: Any] in
            var payload: [String: Any] = ["type": "pty_input", "sessionId": id, "data": chunk, "userInput": userInput]
            if let shortcutKey { payload["shortcutKey"] = shortcutKey }
            else if userInput && chunk == "\r" { payload["shortcutKey"] = "enter_text" }
            return payload
        }
        return !frames.isEmpty && enqueue(frames)
    }
    func resizePty(cols: Int, rows: Int) {
        guard connected, !awaitingSnapshot, let id = subscribedSessionId,
              PtyTerminalSnapshot.validSize(cols: cols, rows: rows) else { return }
        sendJSON(["type": "pty_resize", "sessionId": id, "cols": cols, "rows": rows])
    }
    func acknowledgePty(bytes: Int) {
        guard ptyAck, bytes > 0, let id = subscribedSessionId else { return }
        sendJSON(["type": "pty_ack", "sessionId": id, "bytes": bytes])
    }
    func reconnectForForeground() {
        guard !closed, !endpointSession.isRetired else { return }
        invalidateConnection(); reconnectDelay = 1; openSocket(); startWatchdog()
    }
    private func openSocket() {
        guard !closed, !endpointSession.isRetired, let url = WandEndpoint.webSocketURL(baseURL: baseURL) else { return }
        generation += 1; let gen = generation
        awaitingSnapshot = true; lastSeq = nil
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await prepareConnection?()
                guard !closed, !endpointSession.isRetired, gen == generation, !Task.isCancelled else { return }
                let socket = endpointSession.session.webSocketTask(with: url)
                // Render permits a 64 MiB checkpoint; Node also wraps it in a bounded session DTO.
                socket.maximumMessageSize = 80 * 1024 * 1024
                task = socket; lastMessageAt = Date(); socket.resume()
                sendSubscription(); receiveNext(socket, generation: gen)
            } catch {
                guard !closed, gen == generation else { return }
                reportFailure(error)
                onError?(error.localizedDescription); scheduleReconnect()
            }
        }
    }
    private func receiveNext(_ socket: URLSessionWebSocketTask, generation gen: Int) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed, gen == self.generation else { return }
                guard !self.endpointSession.isRetired else { self.close(); return }
                switch result {
                case .failure(let error):
                    self.reportFailure(error); self.scheduleReconnect()
                case .success(let message):
                    self.lastMessageAt = Date(); self.reconnectDelay = 1
                    if !self.connected { self.connected = true; self.onConnectionChange?(true) }
                    switch message {
                    case .string(let text): self.handle(Data(text.utf8))
                    case .data(let data): self.handle(data)
                    @unknown default: break
                    }
                    self.receiveNext(socket, generation: gen)
                }
            }
        }
    }
    // Internal entrypoint for deterministic tests. UI callbacks remain FIFO on the main thread.
    func handle(_ data: Data) {
        guard let incoming = try? JSONDecoder().decode(WsIncoming.self, from: data) else { return }
        if incoming.type == "ping" { sendJSON(["type": "pong", "t": incoming.t ?? 0]); return }
        if incoming.type == "notification" {
            struct PreviewEnvelope: Decodable { let data: ConversationSessionUpdate }
            if let preview = try? JSONDecoder().decode(PreviewEnvelope.self, from: data) { onConversationPreview?(preview.data) }
        }
        guard incoming.sessionId == nil || incoming.sessionId == "__system__" || incoming.sessionId == subscribedSessionId else { return }
        switch incoming.type {
        case "resync_required": requestResync(); return
        case "init": lastSeq = incoming.seq; awaitingSnapshot = false
        case "output":
            if awaitingSnapshot || (incoming.seq != nil && lastSeq != nil && incoming.seq! <= lastSeq!) {
                acknowledgePty(bytes: incoming.ptyBytes ?? 0); return
            }
            if let seq = incoming.seq, let lastSeq, seq > lastSeq + 1 {
                acknowledgePty(bytes: incoming.ptyBytes ?? 0); requestResync(); return
            }
            if let seq = incoming.seq { lastSeq = seq }
        default: break
        }
        onEvent?(incoming)
    }
    private func sendJSON(_ payload: [String: Any]) { _ = enqueue([payload]) }
    @discardableResult
    private func enqueue(_ payloads: [[String: Any]]) -> Bool {
        guard task != nil, !closed, !endpointSession.isRetired else { return false }
        var frames: [String] = [], bytes = 0
        for payload in payloads {
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else { return false }
            frames.append(text); bytes += data.count
        }
        guard queuedBytes + bytes <= Self.queueLimit else {
            reportFailure(NSError(domain: "WandSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebSocket send queue exceeded its byte limit"]))
            onError?("终端发送积压，连接已重置；未确认的输入不会自动重发。")
            scheduleReconnect(); return false
        }
        sendQueue.append(contentsOf: frames); queuedBytes += bytes; drainSendQueue(); return true
    }
    private func drainSendQueue() {
        guard !sending, let socket = task, let text = sendQueue.first else { return }
        sending = true; let gen = generation
        socket.send(.string(text)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let error {
                    self.reportFailure(error)
                    self.onError?("发送结果未确认；请核对终端输出，输入不会自动重发。")
                    self.scheduleReconnect(); return
                }
                self.sendQueue.removeFirst(); self.queuedBytes -= text.utf8.count; self.sending = false
                self.drainSendQueue()
            }
        }
    }
    private func reportFailure(_ error: Error) {
        guard !closed, !endpointSession.isRetired else { return }
        WandAPI(baseURL: baseURL, token: nil).reportClientFeedback(event: "websocket_error", feature: "realtime", error: error)
    }
    private func invalidateConnection() {
        generation += 1; preparation?.cancel(); preparation = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        sendQueue.removeAll(); queuedBytes = 0; sending = false
        awaitingSnapshot = true; connected = false; onConnectionChange?(false)
    }
    private func scheduleReconnect() {
        guard !closed else { return }
        if endpointSession.isRetired { close(); return }
        invalidateConnection(); let gen = generation, delay = reconnectDelay
        reconnectDelay = min(30, reconnectDelay * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed, gen == self.generation else { return }; self.openSocket()
        }
    }
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, !self.closed, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastMessageAt) > 40 {
                self.reportFailure(NSError(domain: "WandSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "WebSocket heartbeat timed out after 40 seconds"]))
                self.scheduleReconnect()
            }
        }
    }
}
