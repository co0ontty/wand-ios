import AVFoundation
import Combine
import Speech

/// 「按住说话」语音识别服务：AVAudioEngine 采集麦克风 + SFSpeechRecognizer 流式转写。
///
/// 端侧优先：设备已下载当前语言的听写模型时（supportsOnDeviceRecognition），
/// 强制 requiresOnDeviceRecognition —— 音频完全不出设备、无时长配额；
/// 否则自动降级 Apple 服务器识别（需网络，单次约 1 分钟上限，按住说话短句足够）。
///
/// 转写状态始终是「当前最优完整文本」（覆盖式，非增量），
/// 与 Web 端 updateVoiceTranscript(text) 的协议语义一致。
final class SpeechRecognizerService: NSObject, ObservableObject {
    /// 当前累积转写文本（覆盖式更新）。
    @Published private(set) var transcript = ""
    /// 录音进行中（音频引擎已成功启动）。
    @Published private(set) var isRecording = false
    /// 本次会话是否走端侧模型（false = 降级服务器识别）。
    @Published private(set) var usingOnDevice = false

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pendingCommit: ((String) -> Void)?
    private var commitFallback: DispatchWorkItem?
    /// 会话代数：旧任务的迟到回调用它过滤。
    private var generation = 0
    /// start() 是异步链（两次权限回调）；用户提前松手时置 false，阻止迟到的启动。
    private var startRequested = false

    /// 松手后等待 final 结果的最长时间，超时按当前 partial 提交，避免卡住。
    private static let finalResultGrace: TimeInterval = 0.9

    // MARK: - 识别器选择

    /// 按候选顺序找可用识别器：跟系统语言 → 简体中文 → 英文。
    /// SFSpeechRecognizer(locale:) 对不支持的 locale 返回 nil，逐个回落即可。
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        var candidates = Locale.preferredLanguages
        candidates.append(contentsOf: ["zh-CN", "en-US"])
        for identifier in candidates {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               recognizer.isAvailable || recognizer.supportsOnDeviceRecognition {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }

    // MARK: - 权限

    /// 依次请求语音识别 + 麦克风权限，结果回调在主线程。
    private static func requestPermissions(_ completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    completion(false, "语音识别权限被拒绝，请到 设置 > Wand 中开启")
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        completion(granted, granted ? nil : "麦克风权限被拒绝，请到 设置 > Wand 中开启")
                    }
                }
            }
        }
    }

    // MARK: - 开始 / 结束

    /// 开始录音转写；失败时回调错误文案（主线程）。
    func start(onError: @escaping (String) -> Void) {
        guard !isRecording else { return }
        startRequested = true
        Self.requestPermissions { [weak self] granted, message in
            guard let self else { return }
            // 首次使用弹权限框时用户多半已松手；startRequested 已被 stop() 清掉，不再启动。
            guard self.startRequested else { return }
            guard granted else {
                self.startRequested = false
                onError(message ?? "权限被拒绝")
                return
            }
            self.beginSession(onError: onError)
        }
    }

    /// 松手结束。cancelled 时直接丢弃；否则限时等 final 结果，把最终文本交给 commit。
    /// commit 只在文本非空时回调（主线程）。
    func stop(cancelled: Bool, commit: ((String) -> Void)? = nil) {
        startRequested = false
        guard isRecording || task != nil else { return }
        isRecording = false
        stopEngine()
        request?.endAudio()

        if cancelled {
            cleanup(cancelTask: true)
            transcript = ""
            return
        }
        pendingCommit = commit
        let work = DispatchWorkItem { [weak self] in self?.finishCommitIfPending() }
        commitFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalResultGrace, execute: work)
    }

    // MARK: - 内部实现

    private func beginSession(onError: @escaping (String) -> Void) {
        guard !isRecording else { return }
        cleanup(cancelTask: true)

        guard let recognizer = Self.makeRecognizer(),
              recognizer.isAvailable || recognizer.supportsOnDeviceRecognition else {
            startRequested = false
            onError("当前设备语音识别不可用")
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // 端侧模型可用：强制不走网络。
            request.requiresOnDeviceRecognition = true
            usingOnDevice = true
        } else {
            usingOnDevice = false
        }
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                startRequested = false
                onError("无法访问麦克风音频")
                return
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cleanup(cancelTask: true)
            startRequested = false
            onError("启动录音失败：\(error.localizedDescription)")
            return
        }

        generation += 1
        let myGeneration = generation
        transcript = ""
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.generation == myGeneration else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finishCommitIfPending()
                    }
                }
                if error != nil {
                    // 录音中出错则终止本次会话；松手后的取消/结束错误属预期，仅触发兜底提交。
                    if self.isRecording {
                        self.isRecording = false
                        self.stopEngine()
                    }
                    self.finishCommitIfPending()
                }
            }
        }
    }

    /// 提交当前文本（final 到达或限时兜底触发，二者只生效一次）。
    private func finishCommitIfPending() {
        commitFallback?.cancel()
        commitFallback = nil
        guard let commit = pendingCommit else {
            cleanup(cancelTask: true)
            return
        }
        pendingCommit = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup(cancelTask: true)
        transcript = ""
        if !text.isEmpty { commit(text) }
    }

    private func stopEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func cleanup(cancelTask: Bool) {
        if cancelTask { task?.cancel() }
        task = nil
        request = nil
    }
}
