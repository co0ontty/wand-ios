@preconcurrency import AVFoundation
import Foundation

enum WandSpeechAudio { static let queue = DispatchQueue(label: "com.wand.voice.audio") }

/// Queue-owned hardware. Cleanup must never ask AVAudioEngine to create an input
/// node on behalf of a recorder that has never acquired the microphone.
final class WandSpeechAudioHardware: @unchecked Sendable {
    let engine = AVAudioEngine()
    private var capturedInput: AVAudioInputNode?
    var sessionActive = false
    var hasInputNode: Bool { capturedInput != nil }

    func inputForRecording() -> AVAudioInputNode {
        dispatchPrecondition(condition: .onQueue(WandSpeechAudio.queue))
        if let capturedInput { return capturedInput }
        let node = engine.inputNode
        capturedInput = node
        return node
    }

    func stop(beforeDeactivation finish: () -> Void = {}) {
        dispatchPrecondition(condition: .onQueue(WandSpeechAudio.queue))
        if let input = capturedInput {
            if engine.isRunning { engine.stop() }
            input.removeTap(onBus: 0)
            capturedInput = nil
        }
        finish()
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}

enum SpeechRecognitionMode: String {
    case local, server
    static let storageKey = "wand.voiceRecognitionMode"
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "local") ?? .local }
}

struct ServerSpeechStatus: Decodable {
    struct Settings: Decodable { let model: String }
    struct Runtime: Decodable { let backend: String }
    let ready: Bool
    let reason: String?
    let settings: Settings
    let runtime: Runtime
}
struct ServerSpeechResult: Decodable { let text: String }

enum SpeechWav {
    static let sampleRate = 16_000
    static let maxPCMBytes = sampleRate * 2 * 60
    static func encode(_ pcm: Data) throws -> Data {
        guard pcm.count >= 3200, pcm.count <= maxPCMBytes, pcm.count % 2 == 0 else {
            throw NSError(domain: "WandSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音需要 0.1–60 秒，请按住麦克风说话"])
        }
        var data = Data()
        func text(_ string: String) { data.append(contentsOf: string.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(pcm.count + 36)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

/// The tap may run on an audio thread; serialize converter state and bound audio in memory.
private final class ServerSpeechAudioBuffer: @unchecked Sendable {
    // Converter and PCM are accessed only while holding lock; immutable format stays inside that lock.
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private var pcm = Data()
    private var failed = false
    private var finished = false
    init?(source: AVAudioFormat) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(SpeechWav.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: format) else { return nil }
        self.format = format; self.converter = converter
    }
    func append(_ input: AVAudioPCMBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return true } // Ignore a tap already in flight when the hardware stops.
        guard !failed else { return false }
        let count = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { failed = true; return false }
        var supplied = false, error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard result != .error, error == nil, let samples = output.int16ChannelData else { failed = true; return false }
        let bytes = Int(output.frameLength) * 2
        guard pcm.count + bytes <= SpeechWav.maxPCMBytes else { failed = true; return false }
        pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(samples[0]).assumingMemoryBound(to: UInt8.self), count: bytes))
        return true
    }
    func wav() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if !finished {
            finished = true
            // Resampling buffers the tail. noDataNow during capture is not EOF;
            // drain it on release or the last syllable is lost (48 kHz → 16 kHz).
            for _ in 0..<16 {
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
                var error: NSError?
                let result = converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
                if result == .error || error != nil {
                    throw NSError(domain: "WandSpeech", code: 3, userInfo: [NSLocalizedDescriptionKey: "录音转换失败，请重试"])
                }
                if let samples = output.int16ChannelData, output.frameLength > 0 {
                    let bytes = min(Int(output.frameLength) * 2, SpeechWav.maxPCMBytes - pcm.count)
                    if bytes > 0 { pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(samples[0]).assumingMemoryBound(to: UInt8.self), count: bytes)) }
                }
                if result == .endOfStream || output.frameLength == 0 { break }
            }
        }
        return try SpeechWav.encode(pcm)
    }
}

/// Server batch speech uses only microphone permission, never Apple's speech service.
/// Public methods/callbacks run on main; AVAudioSession/engine work is serialized off main.
@MainActor
final class ServerSpeechRecorder {
    private let hardware = WandSpeechAudioHardware()
    private let queue = WandSpeechAudio.queue
    private var audio: ServerSpeechAudioBuffer?
    private var request: Task<Void, Never>?
    private var limit: DispatchWorkItem?
    private var generation = 0
    private var requested = false
    private var recording = false
    private var api: WandAPI?
    private var errorHandler: ((String) -> Void)?
    private var stateHandler: ((Bool, Bool) -> Void)?

    deinit {
        request?.cancel(); limit?.cancel()
        let hardware = hardware
        queue.async { hardware.stop() }
    }
    func start(api: WandAPI, state: @escaping (Bool, Bool) -> Void, onError: @escaping (String) -> Void) {
        cancel()
        requested = true; self.api = api; errorHandler = onError; stateHandler = state
        let captured = generation
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await api.speechStatus()
                guard self.requested, self.generation == captured, !Task.isCancelled else { return }
                guard status.ready else { self.fail(status.reason ?? "服务端识别未就绪，请检查语音设置", generation: captured); return }
                if AVAudioApplication.shared.recordPermission == .granted { self.begin(generation: captured); return }
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self, self.requested, self.generation == captured else { return }
                        if granted { self.begin(generation: captured) }
                        else { self.fail("麦克风权限被拒绝，请到系统设置开启", generation: captured) }
                    }
                }
            } catch { if !Task.isCancelled { self.fail(error.localizedDescription, generation: captured) } }
        }
    }
    private func begin(generation captured: Int) {
        let hardware = hardware
        queue.async { [weak self] in
            do {
                let engine = hardware.engine
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                hardware.sessionActive = true
                let node = hardware.inputForRecording(), format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0, let audio = ServerSpeechAudioBuffer(source: format) else {
                    throw NSError(domain: "WandSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "麦克风音频格式不可用"])
                }
                node.removeTap(onBus: 0)
                node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    if !audio.append(buffer) {
                        DispatchQueue.main.async { self?.fail("录音数据异常或达到 60 秒上限，请分段录音", generation: captured) }
                    }
                }
                engine.prepare(); try engine.start()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == captured, self.requested else { return }
                    self.audio = audio; self.recording = true; self.stateHandler?(true, false)
                    let work = DispatchWorkItem { [weak self] in self?.fail("语音最长 60 秒，请分段录音", generation: captured) }
                    self.limit = work; DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
                }
            } catch { DispatchQueue.main.async { self?.fail("录音启动失败：\(error.localizedDescription)", generation: captured) } }
        }
    }
    func finish(commit: ((String) -> Void)?) {
        requested = false; limit?.cancel(); limit = nil
        guard recording, let audio, api != nil else { cancel(); return }
        recording = false; stateHandler?(false, true)
        let captured = generation
        let hardware = hardware
        queue.async { [weak self] in
            hardware.stop()
            let result = Result { try audio.wav() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == captured, let api = self.api else { return }
                self.audio = nil
                switch result {
                case .failure(let error): self.fail(error.localizedDescription, generation: captured)
                case .success(let wav):
                    self.request = Task { @MainActor [self] in
                        do {
                            let text = try await api.transcribeSpeech(wav)
                            guard self.generation == captured, !Task.isCancelled else { return }
                            self.stateHandler?(false, false); self.errorHandler = nil
                            self.request = nil
                            if !text.isEmpty { commit?(text) }
                        } catch { if !Task.isCancelled { self.fail(error.localizedDescription, generation: captured) } }
                    }
                }
            }
        }
    }
    private func fail(_ message: String, generation captured: Int) {
        guard captured == generation else { return }
        let handler = errorHandler
        cancel(); handler?(message)
    }
    func cancel() {
        generation &+= 1; requested = false; recording = false
        request?.cancel(); request = nil; limit?.cancel(); limit = nil
        audio = nil; api = nil; errorHandler = nil
        stateHandler?(false, false); stateHandler = nil
        let hardware = hardware
        queue.async { hardware.stop() }
    }
}
