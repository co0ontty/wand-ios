import AVFoundation
import Combine
import SwiftUI

enum VoiceCallPhase: String { case off, listening, submitting, waiting, speaking, paused, approval, error }

@MainActor protocol CallRecognition: AnyObject {
    var transcriptUpdates: AnyPublisher<String, Never> { get }
    var requiresFinalResult: Bool { get set }
    func start(api: WandAPI?, onError: @escaping (String) -> Void)
    func stop(cancelled: Bool, commit: ((String) -> Void)?)
}
extension SpeechRecognizerService: CallRecognition {
    var transcriptUpdates: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
}

@MainActor protocol CallSession: AnyObject {
    var isStructured: Bool { get }
    var snapshot: SessionSnapshot? { get }
    var loading: Bool { get }
    var loadError: String? { get }
    var permissionBlocked: Bool { get }
    var pendingEscalation: EscalationRequest? { get }
    var isResponding: Bool { get }
    var connected: Bool { get }
    var status: String { get }
    var messages: [ConversationTurn] { get }
    var unconfirmedInput: String? { get }
    var inputFeedbackMessage: String? { get }
    var api: WandAPI { get }
    func callSend(text: String, onAccepted: @escaping () -> Void, onFailure: @escaping () -> Void) -> Bool
}
extension ChatStore: CallSession {
    func callSend(text: String, onAccepted: @escaping () -> Void, onFailure: @escaping () -> Void) -> Bool {
        send(text: text, onAccepted: onAccepted, onFailure: onFailure)
    }
}

/// Platform speech is replaceable; no credentials or remote TTS service.
@MainActor protocol CallTextSpeaker: AnyObject {
    var playbackUpdates: AnyPublisher<Bool, Never> { get }
    func speak(_ text: String, finished: @escaping () -> Void) throws
    func stop()
}

@MainActor final class SystemCallTextSpeaker: NSObject, CallTextSpeaker, AVSpeechSynthesizerDelegate {
    @Published private var playing = false
    var playbackUpdates: AnyPublisher<Bool, Never> { $playing.eraseToAnyPublisher() }
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var completion: (() -> Void)?
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String, finished: @escaping () -> Void) throws {
        stop()
        let language = text.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil ? "zh-CN" : (Locale.preferredLanguages.first ?? "zh-CN")
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            throw NSError(domain: "WandVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统朗读语音不可用，请检查语言设置"])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let value = AVSpeechUtterance(string: text)
        value.voice = voice
        utterance = value; completion = finished
        synthesizer.speak(value)
    }
    func stop() {
        playing = false; completion = nil; utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.playing = true
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.playing = false
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.playing = false
            let done = self.completion
            self.completion = nil; self.utterance = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            done?()
        }
    }
}

/// Read only spoken projection. Full markdown and tool output remain in ChatStore.
func callSpokenSummary(_ text: String) -> String {
    var result = text.replacingOccurrences(of: "(?s)```.*?```", with: "。代码已保留在聊天记录中。", options: .regularExpression)
    result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "https?://\\S+", with: "链接见聊天记录", options: .regularExpression)
        .replacingOccurrences(of: "(?m)^\\s*[#>*]+\\s*", with: "", options: .regularExpression)
        .replacingOccurrences(of: "`", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if result.count > 900 { result = String(result.prefix(900)) + "。完整回复请查看聊天记录。" }
    return result.isEmpty ? "回复已完成，详细结果请查看聊天记录。" : result
}

@MainActor final class VoiceCallController: ObservableObject {
    @Published private(set) var phase: VoiceCallPhase = .off
    @Published private(set) var isSpeaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var notice = ""
    let recognition: any CallRecognition
    private let speaker: any CallTextSpeaker
    private weak var store: (any CallSession)?
    private var generation = 0
    private var accepted = false
    private var submitted = false
    private var startingUserCount = 0
    private var listeningTarget: [String?] = []
    private var silence: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(recognition: (any CallRecognition)? = nil, speaker: (any CallTextSpeaker)? = nil) {
        self.recognition = recognition ?? SpeechRecognizerService(); self.speaker = speaker ?? SystemCallTextSpeaker()
        self.recognition.requiresFinalResult = true
        self.recognition.transcriptUpdates.sink { [weak self] value in self?.changedTranscript(value) }.store(in: &subscriptions)
        self.speaker.playbackUpdates.sink { [weak self] playing in
            guard let self else { return }
            self.isSpeaking = playing && self.phase == .speaking
        }.store(in: &subscriptions)
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] notification in
                // Ignore our own recording/playback category changes.
                if notification.name == AVAudioSession.routeChangeNotification,
                   (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.categoryChange.rawValue { return }
                Task { @MainActor in self?.pause("音频已中断，点继续恢复通话") }
            }.store(in: &subscriptions)
        }
    }
    var active: Bool { phase != .off }
    var ownsInput: Bool { [.listening, .submitting, .waiting, .speaking].contains(phase) }
    func start(store: any CallSession) {
        guard store.isStructured, store.snapshot?.employeeId != nil, store.snapshot?.cwd?.isEmpty == false,
              !store.loading, store.loadError == nil, store.snapshot?.archived != true else {
            notice = "请先选择员工与工作目录，打开可用的结构化会话"; phase = .error; return
        }
        self.store = store
        if store.unconfirmedInput != nil { fail("上一条送达结果未知，请先核对聊天记录"); return }
        if store.permissionBlocked || store.pendingEscalation != nil { phase = .approval; notice = "请在聊天中确认执行权限"; return }
        if store.isResponding { phase = .paused; notice = "当前任务仍在执行，完成后点继续"; return }
        listen()
    }
    func resume() { guard let store else { return }; start(store: store) }
    func interrupt() {
        guard phase == .speaking else { return }
        speaker.stop(); listen()
    }
    func pause(_ message: String) {
        guard active else { return }
        let uncertain = phase == .submitting && submitted
        invalidate(); phase = uncertain ? .error : .paused
        notice = uncertain ? "提交期间已暂停，请先核对送达记录；不会自动重发" : message
    }
    func end() { invalidate(); phase = .off; notice = ""; transcript = ""; store = nil }
    private func invalidate() {
        isSpeaking = false
        generation += 1; silence?.cancel(); limit?.cancel()
        recognition.stop(cancelled: true, commit: nil); speaker.stop(); accepted = false
        submitted = false
    }
    private func listen() {
        guard let store else { return }
        invalidate(); transcript = ""; notice = SpeechRecognitionMode.selected == .server ? "服务端识别：请点说完了结束录音" : "说完后自动发送，也可点说完了"; phase = .listening
        listeningTarget = [store.snapshot?.id, store.snapshot?.employeeId, store.snapshot?.cwd, store.snapshot?.provider]
        let token = generation
        recognition.start(api: store.api) { [weak self] message in
            guard let self, self.generation == token else { return }
            self.fail(message)
        }
        limit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .listening else { return }
            if self.transcript.isEmpty { self.pause("未检测到语音，点继续重新聆听") }
            else { self.finishListening() }
        }
    }
    private func changedTranscript(_ value: String) {
        guard phase == .listening else { return }
        transcript = value
        silence?.cancel()
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = generation
        silence = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .listening else { return }
            self.finishListening()
        }
    }
    func finishListening() {
        guard phase == .listening else { return }
        silence?.cancel(); limit?.cancel(); phase = .submitting
        let token = generation
        recognition.stop(cancelled: false) { [weak self] text in
            guard let self, self.generation == token, self.phase == .submitting else { return }
            self.submit(text)
        }
        // Empty recognition has no commit callback; keep the call bounded.
        limit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .submitting else { return }
            self.fail("未获得有效转写或发送回执，请核对记录后继续")
        }
    }
    private func submit(_ text: String) {
        guard let store else { return }
        transcript = text
        guard listeningTarget == [store.snapshot?.id, store.snapshot?.employeeId, store.snapshot?.cwd, store.snapshot?.provider],
              store.connected, store.isStructured, !store.loading, store.loadError == nil,
              store.snapshot?.archived != true, store.unconfirmedInput == nil else {
            fail("会话目标或连接状态已变化，请核对转写后继续"); return
        }
        guard !store.isResponding, !store.permissionBlocked, store.pendingEscalation == nil else {
            fail("当前执行未结束，请保留转写并在聊天中核对"); return
        }
        startingUserCount = store.messages.filter { $0.role == "user" }.count
        let token = generation
        submitted = true
        let sent = store.callSend(text: text, onAccepted: { [weak self] in
            guard let self, self.generation == token else { return }
            self.limit?.cancel(); self.accepted = true; self.phase = .waiting; self.notice = "正在处理，完整回复会保留在聊天中"
            self.update()
        }, onFailure: { [weak self] in
            guard let self, self.generation == token else { return }
            self.fail(store.inputFeedbackMessage ?? "发送失败，转写已保留")
        })
        if !sent { fail(store.inputFeedbackMessage ?? "暂时无法发送，转写已保留") }
    }
    /// Called from the existing store's published state, never from a second poller.
    func update() {
        guard active, let store else { return }
        if store.unconfirmedInput != nil { fail("送达结果未知，请先核对聊天记录；不会自动重发"); return }
        if !store.connected { pause("连接已断开，恢复连接后点继续"); return }
        if store.permissionBlocked || store.pendingEscalation != nil {
            invalidate(); phase = .approval; notice = "需要执行确认，请在聊天中处理后继续"; return
        }
        guard phase == .waiting, accepted, !store.isResponding else { return }
        if let message = store.snapshot?.structuredState?.lastError, !message.isEmpty { fail("任务失败，请查看聊天记录"); return }
        guard store.status != "failed", store.status != "exited", store.snapshot?.archived != true else { fail("任务已结束或失败，请查看聊天记录"); return }
        let userCount = store.messages.filter { $0.role == "user" }.count
        guard userCount > startingUserCount, let user = store.messages.lastIndex(where: { $0.role == "user" }) else { return }
        let replies = store.messages.dropFirst(user + 1).filter { $0.role == "assistant" }
        guard !replies.isEmpty else { fail("没有可播报的回复，请查看聊天记录"); return }
        let text = replies.flatMap(\.content).compactMap { block -> String? in
            if case .text(let text, let subagent) = block, subagent == nil { return text }; return nil
        }.joined(separator: "\n")
        phase = .speaking; notice = "正在播报 · 点插话开始下一轮"; accepted = false
        let token = generation
        do { try speaker.speak(callSpokenSummary(text)) { [weak self] in
            guard let self, self.generation == token, self.phase == .speaking else { return }
            self.listen()
        } } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) { invalidate(); phase = .error; notice = message }
}

struct VoiceCallPanel: View {
    @ObservedObject var call: VoiceCallController
    var onStopTask: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: call.phase == .speaking ? "speaker.wave.2" : "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("结束") { call.end() }.frame(minHeight: 48).accessibilityLabel("结束通话")
            }
            Text(call.notice).font(.footnote).foregroundStyle(Theme.textSecondary)
            if !call.transcript.isEmpty { Text(call.transcript).font(.body).lineLimit(4).textSelection(.enabled) }
            HStack {
                if call.phase == .listening { Button("说完了") { call.finishListening() } }
                if call.phase == .speaking { Button("插话") { call.interrupt() } }
                if [.paused, .approval, .error].contains(call.phase) { Button("继续") { call.resume() } }
                if [.listening, .waiting, .speaking, .submitting].contains(call.phase) { Button("暂停") { call.pause("通话已暂停，点继续恢复") } }
                if call.phase == .waiting, let onStopTask { Button("停止任务", role: .destructive, action: onStopTask) }
            }.buttonStyle(.bordered).frame(minHeight: 48)
        }.padding(12).foregroundStyle(Theme.textPrimary).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
    }
    private var title: String {
        switch call.phase {
        case .off: return "语音通话"
        case .listening: return "正在聆听"
        case .submitting: return "正在转写与发送"
        case .waiting: return "正在处理"
        case .speaking: return "正在播报"
        case .paused: return "通话已暂停"
        case .approval: return "等待执行确认"
        case .error: return "通话需要处理"
        }
    }
}

/// Global entry reuses existing authorized sessions and the native employee/directory picker.
struct VoiceCallLaunchView: View {
    let api: WandAPI
    let serverID: String
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionSnapshot] = []
    @State private var employees: [SiliconEmployee] = []
    @State private var selected: SessionSnapshot?
    @State private var creating = false
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    ChatView(sessionId: selected.id, api: api, offersInitialCall: true)
                } else {
                    List {
                        Section {
                            Text("选择员工已有的工作会话，或先选择员工与工作目录新建会话。开始前会显示通话目标。").font(.subheadline)
                            Button("选择员工与目录") { creating = true }.frame(minHeight: 48)
                        }
                        Section("已有员工会话") {
                            if loading { ProgressView().accessibilityLabel("正在加载会话") }
                            if let error {
                                Text(error).foregroundStyle(Theme.danger)
                                Button("重试") { Task { await load() } }
                            }
                            if !loading && sessions.isEmpty && error == nil { Text("暂无员工会话，请先选择员工与目录").foregroundStyle(Theme.textSecondary) }
                            ForEach(sessions) { session in
                                Button { selected = session } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(employees.first(where: { $0.id == session.employeeId })?.name ?? session.displayTitle).font(.headline)
                                        Text(session.cwd ?? "").font(.caption).foregroundStyle(Theme.textSecondary)
                                        Text(session.displayTitle).font(.caption).foregroundStyle(Theme.textSecondary)
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    }.task { await load() }
                }
            }.navigationTitle("语音通话").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button(selected == nil ? "关闭" : "返回") { if selected == nil { dismiss() } else { selected = nil } } } }
        }.sheet(isPresented: $creating) {
            NewSessionView(api: api, hostServerID: serverID, voiceCallOnly: true) { snapshot, targetServerID in
                guard targetServerID == serverID else { error = "请在目标服务器打开新会话开始通话"; creating = false; return }
                selected = snapshot; creating = false
            }
        }
    }
    private func load() async {
        loading = true; error = nil
        do {
            async let people = api.listContactEmployees()
            async let available = api.listSessions()
            let (peers, rows) = try await (people, available)
            guard !Task.isCancelled else { return }
            employees = peers
            sessions = rows.filter { $0.isStructured && $0.employeeId != nil && $0.cwd?.isEmpty == false && $0.archived != true }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }
}
