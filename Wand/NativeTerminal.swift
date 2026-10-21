import Combine
import Foundation
import SwiftUI
import SwiftTerm
import UIKit

/// Render/legacy checkpoint: ANSI plus an ordered write/resize tail, not xterm state.
struct PtyTerminalSnapshot: Decodable {
    struct Operation: Decodable {
        let type: String
        let data: String?
        let cols: Int?
        let rows: Int?
    }
    let version: Int
    let data: String?
    let cols: Int
    let rows: Int
    let pending: [Operation]?
    private enum CodingKeys: String, CodingKey { case version, data, cols, rows, pending }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        version = (try? c?.decode(Int.self, forKey: .version)) ?? -1
        data = try? c?.decode(String.self, forKey: .data)
        cols = (try? c?.decode(Int.self, forKey: .cols)) ?? 0
        rows = (try? c?.decode(Int.self, forKey: .rows)) ?? 0
        pending = try? c?.decode([Operation].self, forKey: .pending)
    }
    static func validSize(cols: Int, rows: Int) -> Bool { (1...1000).contains(cols) && (1...1000).contains(rows) }
    var isReplayable: Bool {
        guard version == 1, data != nil, Self.validSize(cols: cols, rows: rows), let pending else { return false }
        return pending.allSatisfy {
            $0.type == "data" ? $0.data != nil : $0.type == "resize" && Self.validSize(cols: $0.cols ?? 0, rows: $0.rows ?? 0)
        }
    }
    var finalSize: (Int, Int) {
        if let operation = pending?.last(where: { $0.type == "resize" }), let cols = operation.cols, let rows = operation.rows { return (cols, rows) }
        return (cols, rows)
    }
}

enum PtyTerminalInput {
    static func chunks(_ text: String, maxBytes: Int = 16 * 1024) -> [String] {
        var chunks: [String] = [], current = "", count = 0
        for scalar in text.unicodeScalars {
            let bytes = scalar.utf8.count
            if count + bytes > max(4, maxBytes) { chunks.append(current); current = ""; count = 0 }
            current.unicodeScalars.append(scalar); count += bytes
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

func normalizedTerminalScale(_ scale: Double) -> Double {
    guard scale.isFinite else { return 1 }
    return (min(2, max(0.5, scale)) * 4).rounded() / 4
}

/// UIKit/SwiftTerm owns terminal parsing, scrolling, text selection and native IME.
/// Wand owns only the network boundary; it never starts a local process here.
final class NativeTerminalView: TerminalView, TerminalViewDelegate {
    var onInput: ((String, Bool, String?) -> Void)?
    var onSizeChange: ((Int, Int) -> Void)?
    var onPasteImages: (([(data: Data, name: String?, mimeType: String?)]) -> Void)?
    var onTerminalFocus: (() -> Void)?
    var provider: String?
    private var restoring = false
    private var feeding = false
    private var suppressingInput = false
    static let canvasColor = UIColor(red: 0x17 / 255, green: 0x12 / 255, blue: 0x0f / 255, alpha: 1)
    static let inkColor = UIColor(red: 0xf4 / 255, green: 0xee / 255, blue: 0xe6 / 255, alpha: 1)

    init() {
        super.init(frame: .zero, font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            options: TerminalOptions(cols: 80, rows: 24, cursorStyle: .steadyBlock, scrollback: 5000, kittyImageCacheLimitBytes: 16 * 1024 * 1024))
        terminalDelegate = self
        nativeBackgroundColor = Self.canvasColor; nativeForegroundColor = Self.inkColor; caretColor = Self.inkColor
        optionAsMetaKey = false; returnByteSequence = [13]
        keyboardAppearance = .dark; autocorrectionType = .no; spellCheckingType = .no
        inputAccessoryView = nil // The host keeps its shortcut row fixed; do not add a second toolbar.
        accessibilityLabel = "原生终端"; accessibilityIdentifier = "wand.native-terminal"
        bellStyle = .none
        let colors: [UInt32] = [0x2A2420, 0xE06A62, 0x8FBF7A, 0xE2B15A, 0x7AA2C4, 0xC58AD4, 0x6BB5B0, 0xD7CBBE,
            0x6E6258, 0xF28C82, 0x91D39D, 0xF0C56A, 0x9EC0DC, 0xD7A4E4, 0x8ED0CB, 0xF4EEE6]
        installColors(colors.map { SwiftTerm.Color(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255)) })
        TerminalView.textInputDebugEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func feedOutput(_ text: String) {
        feeding = true
        let reporting = allowMouseReporting, terminal = getTerminal()
        if !terminal.isCurrentBufferAlternate && terminal.mouseMode == .off { allowMouseReporting = false }
        defer { allowMouseReporting = reporting; feeding = false }
        // SwiftTerm's feedFinish queues the display update for the next frame and
        // its scroller callback already keeps a following viewport at the bottom.
        // Do not force scrolling while a chunk is being parsed: it bypasses the
        // display batching when the viewport moves and fights manual scrolling.
        feed(text: text)
        if reporting && (terminal.isCurrentBufferAlternate || terminal.mouseMode != .off) { selection.active = false }
    }
    @discardableResult
    func restore(_ data: WsData) -> Bool {
        // An unsupported checkpoint must not silently replay the raw suffix as a complete screen.
        guard data.terminalState?.isReplayable != false, data.terminalState != nil || data.output != nil else { return false }
        restoring = true; defer { restoring = false }
        let position = scrollPosition, browsing = canScroll && position < 1
        let terminal = getTerminal(); terminal.resetToInitialState(); selection.active = false
        nativeBackgroundColor = Self.canvasColor; nativeForegroundColor = Self.inkColor
        if let checkpoint = data.terminalState, let screen = checkpoint.data {
            resizeKeepingTerminalState(cols: checkpoint.cols, rows: checkpoint.rows); feedOutput(screen)
            for operation in checkpoint.pending ?? [] {
                if operation.type == "resize", let cols = operation.cols, let rows = operation.rows {
                    resizeKeepingTerminalState(cols: cols, rows: rows)
                } else if let text = operation.data { feedOutput(text) }
            }
        } else {
            if let cols = data.ptyCols, let rows = data.ptyRows, PtyTerminalSnapshot.validSize(cols: cols, rows: rows) {
                resizeKeepingTerminalState(cols: cols, rows: rows)
            }
            feedOutput(data.output ?? "")
        }
        refit(); scroll(toPosition: browsing ? position : 1)
        // scroll(toPosition:) skips updateScroller when the row is unchanged.
        // The row-based API also synchronizes contentSize in that case.
        scrollTo(row: terminal.buffer.yDisp, notifyAccessibility: false); setNeedsDisplay()
        return true
    }
    func refit() {
        let terminal = getTerminal(), ideal = getOptimalFrameSize()
        guard bounds.width > 0, bounds.height > 0, ideal.width > 0, ideal.height > 0 else { return }
        let cols = max(1, min(1000, Int(bounds.width / (ideal.width / CGFloat(terminal.cols)))))
        let rows = max(1, min(1000, Int(bounds.height / (ideal.height / CGFloat(terminal.rows)))))
        resizeKeepingTerminalState(cols: cols, rows: rows)
    }
    /// Resize the emulator without TerminalView.resize(), whose documented
    /// implementation performs a soft reset. The row-based scroll API also
    /// updates contentSize when the viewport row itself has not changed.
    private func resizeKeepingTerminalState(cols: Int, rows: Int) {
        guard PtyTerminalSnapshot.validSize(cols: cols, rows: rows), cols != getTerminal().cols || rows != getTerminal().rows else { return }
        getTerminal().resize(cols: cols, rows: rows)
        if !restoring {
            scrollTo(row: getTerminal().buffer.yDisp, notifyAccessibility: false)
            setNeedsDisplay(bounds)
            onSizeChange?(cols, rows)
        }
    }
    func setScale(_ scale: Double) {
        font = UIFont(name: "JetBrainsMono-Regular", size: CGFloat(14 * normalizedTerminalScale(scale)))
            ?? .monospacedSystemFont(ofSize: CGFloat(14 * normalizedTerminalScale(scale)), weight: .regular)
        refit()
    }
    func focusTerminal() { if window != nil { _ = becomeFirstResponder() } }
    func blurTerminal() {
        suppressingInput = true; defer { suppressingInput = false }
        markedTextRange = nil // A programmatic drawer/selection change must not commit phonetic preedit remotely.
        _ = resignFirstResponder()
    }
    override func becomeFirstResponder() -> Bool {
        if !selection.active { onTerminalFocus?() }
        return super.becomeFirstResponder()
    }
    override func paste(_ sender: Any?) {
        if let data = UIPasteboard.general.image?.pngData(), let onPasteImages {
            onPasteImages([(data, "clipboard.png", "image/png")]); return
        }
        guard let text = UIPasteboard.general.string else { return }
        pasteText(text)
    }
    func pasteText(_ text: String) {
        let bracketed = getTerminal().bracketedPasteMode || shouldBracketPtyPaste(provider: provider)
        let sequence = buildTerminalPasteSequence(text, bracketed: bracketed)
        guard !restoring, !sequence.isEmpty else { return }
        onInput?(sequence, true, "paste")
    }
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !restoring, !suppressingInput, !data.isEmpty else { return }
        onInput?(String(decoding: data, as: UTF8.self), false, nil)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !restoring, !suppressingInput, !data.isEmpty else { return }
        onInput?(String(decoding: data, as: UTF8.self), true, nil)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if !restoring && !feeding { onSizeChange?(newCols, newRows) }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    // OSC52/Kitty clipboard are remote requests, not explicit native Copy/Paste.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }
}

@MainActor
final class PtyTerminalStore: ObservableObject {
    @Published private(set) var loading = true
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    @Published private(set) var scale: Double
    let terminal = NativeTerminalView()
    private let sessionId: String
    private let socket: any PtySocketTransport
    private let defaults: UserDefaults
    private var started = false
    private var painted = false
    private var lastSize: String?
    private var resizeWork: DispatchWorkItem?
    var scaleLabel: String { "\(Int(scale * 100))%" }
    init(sessionId: String, api: WandAPI, socket: (any PtySocketTransport)? = nil, defaults: UserDefaults = .standard) {
        self.sessionId = sessionId; self.defaults = defaults
        self.socket = socket ?? WandSocket(baseURL: api.baseURL, prepareConnection: { _ = try await api.getSession(id: sessionId) })
        let saved = defaults.double(forKey: "wand.nativeTerminalScale")
        scale = saved > 0 ? normalizedTerminalScale(saved) : 1
        terminal.setScale(scale)
        terminal.onInput = { [weak self] text, user, shortcut in self?.send(text, userInput: user, shortcutKey: shortcut) }
        terminal.onSizeChange = { [weak self] cols, rows in DispatchQueue.main.async { self?.resize(cols: cols, rows: rows) } }
        self.socket.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }
        self.socket.onConnectionChange = { [weak self] connected in MainActor.assumeIsolated {
            guard let self, self.started else { return }
            if !connected { self.ready = false; self.loading = !self.painted; self.lastSize = nil }
        } }
        self.socket.onResync = { [weak self] in MainActor.assumeIsolated { self?.ready = false } }
        self.socket.onError = { [weak self] message in MainActor.assumeIsolated {
            guard let self, self.started else { return }; self.error = message; self.loading = false; self.ready = false
        } }
    }
    func start() {
        guard !started else { return }; started = true; loading = !painted
        socket.subscribe(sessionId: sessionId, ptyAck: true); socket.connect()
    }
    func shutdown() { started = false; ready = false; resizeWork?.cancel(); resizeWork = nil; socket.close(); terminal.blurTerminal() }
    func refresh() { error = nil; if started { socket.requestResync() } else { start() } }
    func foreground() { if started { socket.reconnectForForeground() } }
    func handle(_ event: WsIncoming) {
        guard started, event.sessionId == sessionId else { return }
        switch event.type {
        case "init":
            guard let data = event.data, terminal.restore(data) else {
                ready = false; loading = false; error = "服务端终端快照不受支持，请检查 Render 版本"; return
            }
            ready = true; painted = true; loading = false; error = nil; lastSize = nil
            resize(cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
        case "output":
            if ready, let text = event.data?.chunk { terminal.feedOutput(text) }
            socket.acknowledgePty(bytes: event.ptyBytes ?? 0) // After synchronous parser consumption, including skipped frames.
        case "pty_error": ready = false; loading = false; error = "终端操作未确认，请核对输出并重新同步，勿重复执行。"
        case "error": ready = false; loading = false; error = event.error ?? "终端请求失败"
        default: break
        }
    }
    @discardableResult
    func send(_ text: String, userInput: Bool = true, shortcutKey: String? = nil) -> Bool {
        guard started, ready else { if userInput { error = "终端未就绪，输入未发送，请连接后重试" }; return false }
        let sent = socket.sendPtyInput(text, userInput: userInput, shortcutKey: shortcutKey)
        if !sent && userInput { error = "终端输入未发送，请检查连接后重试" }
        return sent
    }
    private func resize(cols: Int, rows: Int) {
        guard PtyTerminalSnapshot.validSize(cols: cols, rows: rows) else { return }
        resizeWork?.cancel(); let size = "\(cols)x\(rows)"
        guard started, ready, size != lastSize else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, started, ready else { return }; lastSize = size; socket.resizePty(cols: cols, rows: rows)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    func adjustScale(_ delta: Double) {
        scale = normalizedTerminalScale(scale + delta); defaults.set(scale, forKey: "wand.nativeTerminalScale"); terminal.setScale(scale)
    }
}

struct NativeTerminalSurface: UIViewRepresentable {
    let terminal: NativeTerminalView
    func makeUIView(context: Context) -> NativeTerminalView { terminal }
    func updateUIView(_ uiView: NativeTerminalView, context: Context) {}
    static func dismantleUIView(_ uiView: NativeTerminalView, coordinator: ()) { uiView.blurTerminal() }
}
