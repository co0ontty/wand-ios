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

    // Chat/notification leases share one wire for the exact endpoint identity.
    // PTY transports never opt in: their ACK/input/backpressure lifecycle remains independent.
    private final class WeakPeer { weak var value: WandSocket?; init(_ value: WandSocket) { self.value = value } }
    private final class WeakHub { weak var value: ChatHub?; init(_ value: ChatHub) { self.value = value } }
    private static var chatHubs: [ObjectIdentifier: WeakHub] = [:]
    private var chatHub: ChatHub?
    /// Internal diagnostics also allow protocol tests to drive the real shared wire.
    var sharedConnection: WandSocket { chatHub?.host ?? self }
    var activeChatLeases: Int { chatHub?.peers.values.compactMap(\.value).filter { !$0.closed }.count ?? 0 }
    private let leaseID = UUID()
    private var wireFrame: ((DecodedFrame) -> Void)?
    private var wireReady: (() -> Void)?

    static func sharedChat(api: WandAPI) -> WandSocket {
        let owner: AnyObject = api
        chatHubs = chatHubs.filter { $0.value.value != nil }
        let key = ObjectIdentifier(owner)
        let hub: ChatHub
        if let existing = chatHubs[key]?.value, existing.owner === owner { hub = existing }
        else {
            hub = ChatHub(owner: owner, host: WandSocket(baseURL: api.baseURL))
            chatHubs[key] = WeakHub(hub)
        }
        let peer = WandSocket(baseURL: api.baseURL)
        peer.chatHub = hub
        return peer
    }
    private final class ChatHub {
        weak var owner: AnyObject?
        let host: WandSocket
        var peers: [UUID: WeakPeer] = [:]
        private var lastRecovery = Date.distantPast
        init(owner: AnyObject, host: WandSocket) {
            self.owner = owner; self.host = host
            host.wireFrame = { [weak self] frame in
                guard let self else { return }
                for peer in peers.values.compactMap(\.value) where !peer.closed { peer.deliver(frame) }
            }
            host.wireReady = { [weak self] in
                guard let self else { return }
                for peer in peers.values.compactMap(\.value) where !peer.closed { peer.sendSubscription() }
            }
            host.onConnectionChange = { [weak self] up in
                guard let self else { return }
                for peer in peers.values.compactMap(\.value) where !peer.closed {
                    peer.connected = up
                    if !up { peer.awaitingSnapshot = true; peer.lastSeq = nil }
                    peer.onConnectionChange?(up)
                }
            }
            host.onError = { [weak self] error in
                for peer in self?.peers.values.compactMap(\.value) ?? [] { peer.onError?(error) }
            }
        }
        func add(_ peer: WandSocket) {
            peers[peer.leaseID] = WeakPeer(peer)
            if host.closed { host.connect() }
            else { peer.connected = host.connected; peer.onConnectionChange?(host.connected); peer.sendSubscription() }
        }
        func release(_ id: String) {
            if !peers.values.contains(where: { $0.value?.subscribedSessionId == id && $0.value?.closed == false }) {
                host.sendJSON(["type": "unsubscribe", "sessionId": id])
            }
        }
        func remove(_ peer: WandSocket) {
            peers.removeValue(forKey: peer.leaseID)
            peers = peers.filter { $0.value.value != nil }
            if let id = peer.subscribedSessionId, !peers.values.contains(where: { $0.value?.subscribedSessionId == id && $0.value?.closed == false }) {
                host.sendJSON(["type": "unsubscribe", "sessionId": id])
            }
            if peers.isEmpty { host.close() }
        }
        func send(_ payload: [String: Any]) {
            var payload = payload
            if payload["type"] as? String == "subscribe" { payload["mode"] = "add" }
            host.sendJSON(payload)
        }
        func recover(_ peer: WandSocket) {
            if host.connected && Date().timeIntervalSince(host.lastMessageAt) < 35 { peer.requestResync(); return }
            guard Date().timeIntervalSince(lastRecovery) > 1 else { return }
            lastRecovery = Date()
            host.invalidateConnection(); host.openSocket(); host.startWatchdog()
        }
    }

    var onEvent: ((WsIncoming) -> Void)?
    var onConversationChanged: (() -> Void)?
    var onConversationPreview: ((ConversationSessionUpdate) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onResync: (() -> Void)?
    var onError: ((String) -> Void)?
    var blockBudget = 0
    var byteBudget = 0
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
    private let decodeQueue = DispatchQueue(label: "app.wand.socket.decode", qos: .userInitiated)
    private static let queueLimit = 2 * 1024 * 1024

    init(baseURL: URL, prepareConnection: (() async throws -> Void)? = nil) {
        self.baseURL = baseURL
        self.prepareConnection = prepareConnection
        endpointSession = SelfSignedSession.forEndpoint(baseURL)
    }
    deinit {
        chatHub?.remove(self)
        preparation?.cancel(); watchdog?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
    }
    func connect() {
        guard closed, !endpointSession.isRetired else { return }
        closed = false
        if let chatHub { chatHub.add(self); return }
        openSocket(); startWatchdog()
    }
    func close() {
        closed = true
        if let chatHub { chatHub.remove(self); connected = false; awaitingSnapshot = true; return }
        watchdog?.invalidate(); watchdog = nil; invalidateConnection()
    }
    func subscribe(sessionId: String, ptyAck: Bool = false) {
        let previous = subscribedSessionId
        subscribedSessionId = sessionId; self.ptyAck = ptyAck
        if let previous, previous != sessionId { chatHub?.release(previous) }
        awaitingSnapshot = true; lastSeq = nil; sendSubscription()
    }
    func subscriptionPayload() -> [String: Any]? {
        guard let id = subscribedSessionId else { return nil }
        var payload: [String: Any] = ["type": "subscribe", "sessionId": id, "compactTools": true,
                                      "capabilities": ["ptyAck": ptyAck]]
        if blockBudget > 0 {
            payload["blockBudget"] = blockBudget
            payload["omitStructuredOutput"] = true
        }
        if byteBudget > 0 { payload["byteBudget"] = byteBudget }
        return payload
    }
    private func sendSubscription() { if !closed, let payload = subscriptionPayload() { sendJSON(payload) } }
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
        if let chatHub { chatHub.recover(self); return }
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
                wireReady?()
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
            // Decode before entering the UI queue, one frame at a time. Do not
            // receive the next frame until delivery, preserving FIFO/backpressure.
            guard let self else { return }
            self.decodeReceived(result) { [weak self] frame in
                guard let self, !self.closed, gen == self.generation else { return }
                guard !self.endpointSession.isRetired else { self.close(); return }
                switch result {
                case .failure(let error):
                    self.reportFailure(error); self.scheduleReconnect()
                case .success:
                    self.lastMessageAt = Date(); self.reconnectDelay = 1
                    if !self.connected { self.connected = true; self.onConnectionChange?(true) }
                    if let frame { self.deliver(frame) }
                    self.receiveNext(socket, generation: gen)
                }
            }
        }
    }

    // Shared with transport tests: decoding is serial/off-main; delivery stays on main.
    func decodeReceived(_ result: Result<URLSessionWebSocketTask.Message, Error>, completion: @escaping (DecodedFrame?) -> Void) {
        decodeQueue.async {
            let frame: DecodedFrame?
            switch result {
            case .success(.string(let text)): frame = Self.decode(Data(text.utf8))
            case .success(.data(let data)): frame = Self.decode(data)
            default: frame = nil
            }
            DispatchQueue.main.async { completion(frame) }
        }
    }

    struct DecodedFrame {
        let incoming: WsIncoming
        let preview: ConversationSessionUpdate?
    }

    static func decode(_ data: Data) -> DecodedFrame? {
        guard let incoming = try? JSONDecoder().decode(WsIncoming.self, from: data) else { return nil }
        struct PreviewEnvelope: Decodable { let data: ConversationSessionUpdate }
        let preview = incoming.type == "notification"
            ? (try? JSONDecoder().decode(PreviewEnvelope.self, from: data))?.data : nil
        return DecodedFrame(incoming: incoming, preview: preview)
    }

    // Internal entrypoint for deterministic tests. UI callbacks remain FIFO on the main thread.
    func handle(_ data: Data) {
        if let frame = Self.decode(data) { deliver(frame) }
    }

    private func deliver(_ frame: DecodedFrame) {
        let incoming = frame.incoming
        if incoming.type == "ping" { sendJSON(["type": "pong", "t": incoming.t ?? 0]); return }
        if let wireFrame { wireFrame(frame); return }
        if let preview = frame.preview { onConversationPreview?(preview) }
        if incoming.type == "notification", ["conversations-changed", "ai-team-run", "silicon-employee-definition", "ai-team-definition"].contains(incoming.data?.kind ?? "") { onConversationChanged?() }
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
    private func sendJSON(_ payload: [String: Any]) {
        if let chatHub { if !closed { chatHub.send(payload) }; return }
        _ = enqueue([payload])
    }
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
