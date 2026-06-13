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
///
/// 启动延迟优化（解决「按下去很久识别框才出现」）：
///   1. 已授权时走同步快路径，跳过 requestAuthorization + requestRecordPermission
///      的两次系统异步往返 + 两次 main-hop。
///   2. AVAudioSession.setActive(true) / audioEngine.start() 这些会阻塞主线程的重活
///      统一丢到串行 audioQueue 后台执行，主线程只改 @Published 状态。
///   3. recognizer 缓存（不再每次按下都遍历 Locale 重建）。
///   4. prewarm()：进入语音模式时提前构造 recognizer + setCategory（不 setActive，
///      避免过早 duck 用户音频）+ 触发授权，把首次冷启成本前移。
final class SpeechRecognizerService: NSObject, ObservableObject {
    /// 当前累积转写文本（覆盖式更新）。
    @Published private(set) var transcript = ""
    /// 录音进行中（音频引擎已成功启动）。
    @Published private(set) var isRecording = false
    /// 本次会话是否走端侧模型（false = 降级服务器识别）。
    @Published private(set) var usingOnDevice = false

    private let audioEngine = AVAudioEngine()
    /// 所有 AVAudioSession / audioEngine 调用都走这条串行队列，序列化消除竞争、
    /// 且把 setActive/start 的阻塞挡在主线程之外。
    private let audioQueue = DispatchQueue(label: "com.wand.voice.audio")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pendingCommit: ((String) -> Void)?
    private var commitFallback: DispatchWorkItem?
    /// 会话代数：旧任务的迟到回调用它过滤。
    private var generation = 0
    /// start() 是异步链（两次权限回调）；用户提前松手时置 false，阻止迟到的启动。
    private var startRequested = false

    /// 缓存的识别器：构造一次（遍历 Locale 候选），后续按下复用。
    private lazy var cachedRecognizer: SFSpeechRecognizer? = Self.makeRecognizer()

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

    /// 已授权同步判定：两项都 .authorized/.granted 时可走快路径、零异步 hop。
    private static func alreadyAuthorized() -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return false }
        return AVAudioApplication.shared.recordPermission == .granted
    }

    /// 依次请求语音识别 + 麦克风权限，结果回调在主线程。
    private static func requestPermissions(_ completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    completion(false, "语音识别权限被拒绝，请到 设置 > Wand 中开启")
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        completion(granted, granted ? nil : "麦克风权限被拒绝，请到 设置 > Wand 中开启")
                    }
                }
            }
        }
    }

    // MARK: - 预热

    /// 进入语音模式时调用：把「首次冷启」成本前移到用户还没按下时。
    /// 只做无副作用的轻量预热——构造 recognizer、setCategory（不 setActive，不抢硬件、不 duck）、
    /// 触发授权（已授权则 noop）。真正的 setActive/start 仍留到按下时做。
    func prewarm() {
        // 触发 recognizer 懒加载（遍历 Locale 的成本前移）。
        _ = cachedRecognizer
        // 未授权时提前弹授权框；已授权时是空操作，但会把双 hop 前移。
        if !Self.alreadyAuthorized() {
            Self.requestPermissions { _, _ in }
        }
        audioQueue.async {
            // setCategory 不抢音频硬件、不 duck，可安全提前；幂等。
            try? AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker]
            )
        }
    }

    // MARK: - 开始 / 结束

    /// 开始录音转写；失败时回调错误文案（主线程）。
    func start(onError: @escaping (String) -> Void) {
        guard !isRecording else { return }
        startRequested = true

        // 快路径：已授权 → 零异步 hop，直接进会话。
        if Self.alreadyAuthorized() {
            beginSession(onError: onError)
            return
        }

        // 慢路径：首次授权，走异步权限链。
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

        // —— 主线程：廉价、纯状态 ——
        guard let recognizer = cachedRecognizer,
              recognizer.isAvailable || recognizer.supportsOnDeviceRecognition else {
            startRequested = false
            onError("当前设备语音识别不可用")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // 端侧模型可用：强制不走网络。
            request.requiresOnDeviceRecognition = true
            usingOnDevice = true
        } else {
            usingOnDevice = false
        }
        request.addsPunctuation = true
        self.request = request

        generation += 1
        let myGeneration = generation
        transcript = ""

        // —— 后台串行队列：setActive + engine.start 的阻塞重活，挡在主线程之外 ——
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                let input = self.audioEngine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0 else {
                    self.failStart(generation: myGeneration, message: "无法访问麦克风音频", onError: onError)
                    return
                }
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    // tap 回调在音频后台线程；append 跨线程是 API 设计支持的用法。
                    self?.request?.append(buffer)
                }
                self.audioEngine.prepare()
                try self.audioEngine.start()
            } catch {
                self.failStart(generation: myGeneration,
                               message: "启动录音失败：\(error.localizedDescription)",
                               onError: onError)
                return
            }

            // —— 回主线程：起 recognitionTask + 置 @Published ——
            DispatchQueue.main.async {
                guard self.generation == myGeneration else { return }
                // 用户在冷启窗口内已松手 → 这次 start 是迟到的，拆掉引擎、不进录音态。
                guard self.startRequested else {
                    self.stopEngine() // 派发到 audioQueue，保持 engine/session 调用串行
                    self.cleanup(cancelTask: true)
                    return
                }
                self.isRecording = true
                self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
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
        }
    }

    /// 后台启动失败的统一收尾（回主线程报错 + 清理）。
    private func failStart(generation: Int, message: String, onError: @escaping (String) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.stopEngine() // 派发到 audioQueue，保持 engine/session 调用串行
            self.cleanup(cancelTask: true)
            self.startRequested = false
            self.isRecording = false
            onError(message)
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

    /// 停掉音频引擎 + deactivate 会话。所有 engine/session 调用走 audioQueue 串行，
    /// 保持「先 stop I/O 再 deactivate」顺序（否则触发 deactivate-with-running-I/O 的长阻塞报错）。
    private func stopEngine() {
        audioQueue.async { [weak self] in
            self?.teardownEngine()
        }
    }

    /// 实际的引擎拆除（必须在 audioQueue 上执行）。
    private func teardownEngine() {
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
