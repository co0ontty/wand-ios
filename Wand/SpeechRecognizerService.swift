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
    private var runtimeErrorHandler: ((String) -> Void)?
    private var commitFallback: DispatchWorkItem?
    /// 会话代数：旧任务的迟到回调用它过滤。
    private var generation = 0
    private var audioPipelineStopped = true
    /// start() 是异步链（两次权限回调）；用户提前松手时置 false，阻止迟到的启动。
    private var startRequested = false

    /// 缓存的识别器：构造一次（遍历 Locale 候选），后续按下复用。
    private lazy var cachedRecognizer: SFSpeechRecognizer? = Self.makeRecognizer()

    deinit {
        let engine = audioEngine
        let request = request
        let task = task
        audioQueue.async {
            Self.teardownAudioPipeline(
                engine: engine,
                request: request,
                task: task,
                cancelTask: true
            )
        }
    }

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
        guard !isRecording, !startRequested else { return }
        if pendingCommit != nil { finishCommitIfPending() }
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
        let activeRequest = request
        let activeTask = task

        if cancelled {
            commitFallback?.cancel()
            commitFallback = nil
            pendingCommit = nil
            runtimeErrorHandler = nil
            cleanup(cancelTask: true)
            transcript = ""
            return
        }
        stopAudioPipeline(
            request: activeRequest,
            task: activeTask,
            cancelTask: false
        )
        audioPipelineStopped = true
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
        runtimeErrorHandler = onError
        if recognizer.supportsOnDeviceRecognition {
            // 端侧模型可用：强制不走网络。
            request.requiresOnDeviceRecognition = true
            usingOnDevice = true
        } else {
            usingOnDevice = false
        }
        request.addsPunctuation = true
        self.request = request
        audioPipelineStopped = false

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
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    // request 是本轮不可变对象；不跨音频线程读取 self.request，避免清理竞态。
                    request.append(buffer)
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
            DispatchQueue.main.async { [self] in
                guard self.generation == myGeneration else { return }
                // 用户在冷启窗口内已松手 → 这次 start 是迟到的，拆掉引擎、不进录音态。
                guard self.startRequested else {
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
                                if self.pendingCommit != nil {
                                    self.finishCommitIfPending()
                                } else {
                                    self.failRuntime("语音识别已结束，请松开后重试")
                                }
                            }
                        }
                        if let error {
                            // 松手后的结束/取消错误属预期；按住期间失败必须复位页面手势状态。
                            if self.isRecording {
                                self.failRuntime("语音识别失败：\(error.localizedDescription)")
                            } else {
                                self.finishCommitIfPending()
                            }
                        }
                    }
                }
            }
        }
    }

    /// 运行期失败统一复位服务和调用页面，避免手势 UI 停在“正在聆听”。
    private func failRuntime(_ message: String) {
        guard isRecording else { return }
        let handler = runtimeErrorHandler
        runtimeErrorHandler = nil
        startRequested = false
        isRecording = false
        cleanup(cancelTask: true)
        transcript = ""
        handler?(message)
    }

    /// 后台启动失败的统一收尾（回主线程报错 + 清理）。
    private func failStart(generation: Int, message: String, onError: @escaping (String) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
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
        runtimeErrorHandler = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup(cancelTask: true)
        transcript = ""
        if !text.isEmpty { commit(text) }
    }

    /// 停止硬件、结束 request、取消 task、释放音频会话全部在同一串行队列执行。
    /// 闭包只捕获本轮对象，不依赖 self 存活，页面销毁后也能完成清理。
    private func stopAudioPipeline(
        request: SFSpeechAudioBufferRecognitionRequest?,
        task: SFSpeechRecognitionTask?,
        cancelTask: Bool
    ) {
        let engine = audioEngine
        audioQueue.async {
            Self.teardownAudioPipeline(
                engine: engine,
                request: request,
                task: task,
                cancelTask: cancelTask
            )
        }
    }

    private static func teardownAudioPipeline(
        engine: AVAudioEngine,
        request: SFSpeechAudioBufferRecognitionRequest?,
        task: SFSpeechRecognitionTask?,
        cancelTask: Bool
    ) {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if cancelTask { task?.cancel() }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func cleanup(cancelTask: Bool) {
        let activeRequest = request
        let activeTask = task
        request = nil
        task = nil
        if cancelTask {
            generation &+= 1
            let requestToEnd = audioPipelineStopped ? nil : activeRequest
            audioPipelineStopped = true
            stopAudioPipeline(
                request: requestToEnd,
                task: activeTask,
                cancelTask: true
            )
        }
    }
}
