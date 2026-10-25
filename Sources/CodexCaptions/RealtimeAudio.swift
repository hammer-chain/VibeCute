import AppKit
import CoreAudio
import AVFoundation
import CaptionCore

enum AudioCharacterTarget: String, CaseIterable, Identifiable {
    case both, codex, deepseek, claude, doubao, opencode, zcode, workbuddy, companion
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "所有已开启的角色"
        case .codex: return "Codex 的角色"
        case .deepseek: return "DeepSeek Harness 的角色"
        case .claude: return "Claude Code 的角色"
        case .doubao: return "豆包工作的角色"
        case .opencode: return "OpenCode 的角色"
        case .zcode: return "zcode 的角色"
        case .workbuddy: return "WorkBuddy 的角色"
        case .companion: return "不绑定 Harness 的角色"
        }
    }
    var mascots: Set<CaptionMascot> {
        self == .both ? Set(CaptionMascot.allCases) : [CaptionMascot(rawValue: rawValue)!]
    }
}

/// Core Audio tap captures the live output mix without changing playback.
/// PCM stays on the IO queue; the UI polls a single latest-result mailbox.
final class RealtimeAudio {
    var onStatus: ((String, Bool) -> Void)?
    var onRecognitionActivity: ((Bool) -> Void)?
    let speech: KeywordSpeech
    private let makeClassifier: (Double, Double) -> SoundContextClassifier
    private let control = DispatchQueue(label: "captions.audio.control", qos: .userInitiated)
    private let io = DispatchQueue(label: "captions.audio.analysis", qos: .userInteractive)
    private let lock = NSLock()
    private var mailbox = LiveLipMailbox()
    private var gain: Float = 1
    private var voicePriority = true
    private var vowelProfile: LipVowelProfile?
    private var vocalRequested = false
    private var vocalDirectory: URL?
    // Separation, its analyzer, and source switching belong to the IO queue.
    private var vocalPipeline: VocalSeparationPipeline?
    private var vocalAnalyzer: LiveLipAnalyzer?
    private var vocalGeneration = 0
    private var captureActive = false
    private var latestRawFrame = LiveLipFrame.silence
    private var lastVocalEnd: Double?
    private var vocalUsed = false
    private var separationStatus = VocalSeparationPipeline.Status()
    private var tempoEngine = BuildProfile.defaultTempo
    private var classifier: SoundContextClassifier?
    // Recognition state belongs to the serial IO queue, including teardown.
    private var recognitionActivity = AudioRecognitionActivity()
    private var recognitionActive = false
    private var lastPCMReceivedAt: Double?
    private var captureGeneration = 0
    private var recognitionAudioTime = 0.0
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var output = AudioObjectID(kAudioObjectUnknown)
    private var sampleRate: Double = 0
    private var timer: DispatchSourceTimer?
    private var wanted = false
    private var connected = false // control queue only
    private var retryAt: TimeInterval = 0
    private var retryDelay: TimeInterval = 2
    // Allows deterministic lifecycle checks without touching system devices/permissions.
    struct CaptureHooks {
        var start: () throws -> Void
        var stop: () -> Void
        var needsReconnect: () throws -> Bool
    }
    private let captureHooks: CaptureHooks?

    init(speech: KeywordSpeech = KeywordSpeech(), captureHooks: CaptureHooks? = nil, classifierFactory: @escaping (Double, Double) -> SoundContextClassifier = {
        SoundContextClassifier(sampleRate: $0, audioTimeOrigin: $1)
    }) {
        self.speech = speech; self.captureHooks = captureHooks; makeClassifier = classifierFactory
    }

    func setSensitivity(_ value: Double) {
        lock.lock(); gain = Float(value); lock.unlock()
    }
    func setVoicePriority(_ value: Bool) {
        lock.lock(); voicePriority = value; lock.unlock()
    }

    func setVowelProfile(_ profile: LipVowelProfile?) {
        lock.lock(); vowelProfile = profile?.isValid == true ? profile : nil; lock.unlock()
    }

    func setVocalSeparation(_ enabled: Bool, directory: URL?) {
        guard BuildProfile.experiments else { return }
        lock.lock()
        let changed = vocalRequested != enabled || vocalDirectory != directory
        vocalRequested = enabled; vocalDirectory = directory; lock.unlock()
        if changed { io.async { [weak self] in self?.configureVocalPipeline() } }
    }

    func vocalStatus() -> VocalSeparationPipeline.Status {
        lock.lock(); defer { lock.unlock() }; return separationStatus
    }

    private func configureVocalPipeline() {
        vocalGeneration += 1; vocalPipeline?.stop(); vocalPipeline = nil
        vocalAnalyzer = nil; lastVocalEnd = nil; vocalUsed = false
        lock.lock()
        let requested = vocalRequested, directory = vocalDirectory
        mailbox = LiveLipMailbox(); separationStatus = VocalSeparationPipeline.Status()
        separationStatus.message = requested ? "静音 / 等待声音 · 人声分离已停止" : "使用原始声音"
        lock.unlock()
        // Use raw PCM activity, never mouth sensitivity or the scene classifier.
        // Do not load a separator during initial silence; sustained silence
        // releases the worker and model instead of retaining an idle process.
        guard captureActive, requested, recognitionActive else { return }
        guard let directory else {
            lock.lock(); separationStatus.failed = true
            separationStatus.message = "分离模型不可用，使用原始声音"; lock.unlock(); return
        }
        let token = vocalGeneration
        lock.lock(); separationStatus.message = "正在准备人声分离…"; lock.unlock()
        let pipeline = VocalSeparationPipeline(directory: directory)
        pipeline.onOutput = { [weak self] result in
            self?.io.async { [weak self] in
                guard let self, self.captureActive, self.vocalGeneration == token else { return }
                self.consumeVocal(result)
            }
        }
        vocalPipeline = pipeline
    }

    private func consumeVocal(_ output: VocalSeparationPipeline.Output) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - output.capturedEnd <= 0.12, now - output.capturedEnd >= -0.005,
              !output.samples.isEmpty, !latestRawFrame.laughterPriority else { return }
        let duration = Double(output.samples.count) / 44100
        let start = output.capturedEnd - duration
        if output.reset || vocalAnalyzer == nil || lastVocalEnd.map({ abs(start - $0) > 0.002 }) == true {
            vocalAnalyzer = LiveLipAnalyzer(audioTimeOrigin: output.audioTimeEnd - duration, trackTempo: false)
        }
        lastVocalEnd = output.capturedEnd
        let analyzer = vocalAnalyzer!
        lock.lock(); analyzer.sensitivity = gain; analyzer.voicePriority = voicePriority
        analyzer.vowelProfile = vowelProfile; lock.unlock()
        analyzer.scene = latestRawFrame.scene
        var results = [LiveLipFrame]()
        for (index, sample) in output.samples.enumerated() {
            if var frame = analyzer.consume(sample, sampleRate: 44100) {
                frame.capturedAt = start + Double(index + 1) / 44100
                frame.analyzedAt = ProcessInfo.processInfo.systemUptime
                frame.captureTimeEstimated = output.captureTimeEstimated
                frame.separatedVocal = true
                // Body motion and the scene display continue following the full mix.
                frame.beat = latestRawFrame.beat; frame.scene = latestRawFrame.scene
                results.append(frame)
            }
        }
        guard !results.isEmpty else { return }
        lock.lock()
        if !vocalUsed { mailbox = LiveLipMailbox(); vocalUsed = true }
        separationStatus.message = "已使用分离人声"
        for frame in results { mailbox.publish(frame) }
        lock.unlock()
    }

    func setTempoEngine(_ value: TempoEngine) {
        let value = BuildProfile.isRelease ? .beatnet : value
        lock.lock(); tempoEngine = value; lock.unlock()
    }

    func snapshot() -> LiveLipFrame {
        lock.lock(); defer { lock.unlock() }
        return mailbox.snapshot(at: ProcessInfo.processInfo.systemUptime)
    }

    func setEnabled(_ enabled: Bool) {
        control.async { [weak self] in
            guard let self, self.wanted != enabled else { return }
            self.wanted = enabled
            self.timer?.cancel(); self.timer = nil
            self.tearDown()
            self.retryAt = 0; self.retryDelay = 2
            guard enabled else { self.report("系统声音口型已关闭", running: false); return }
            guard #available(macOS 14.2, *) else {
                self.report("系统声音口型需要 macOS 14.2 或更新版本", running: false); return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.control)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.monitorConnection() }
            self.timer = timer; timer.resume()
            self.begin()
        }
    }

    @available(macOS 14.2, *)
    private func monitorConnection() {
        guard wanted else { return }
        if connected {
            let changed: Bool
            if let captureHooks { changed = (try? captureHooks.needsReconnect()) ?? true }
            else {
                let current = try? defaultOutput()
                let format: AudioStreamBasicDescription? = try? read(tap, kAudioTapPropertyFormat)
                changed = current != output || format?.mSampleRate != sampleRate
            }
            if changed { tearDown(); retryAt = 0; retryDelay = 2 }
        }
        if !connected, ProcessInfo.processInfo.systemUptime >= retryAt { begin() }
        io.async { [weak self] in
            guard let self, let last = self.lastPCMReceivedAt,
                  ProcessInfo.processInfo.systemUptime - last > 1 else { return }
            self.recognitionActivity = AudioRecognitionActivity()
            self.updateRecognitionActivity(false)
        }
    }

    @available(macOS 14.2, *)
    private func begin() {
        report("正在连接系统声音… 首次使用请允许系统录音", running: false)
        do {
            if let captureHooks { try captureHooks.start() } else { try createTap() }
            connected = true; retryAt = 0; retryDelay = 2
            report("已连接系统声音 · 实时近似口型", running: true)
        } catch {
            tearDown()
            let delay = retryDelay
            retryAt = ProcessInfo.processInfo.systemUptime + delay
            retryDelay = min(30, delay * 2)
            report("无法连接系统声音：\(error.localizedDescription)。将在约 \(Int(delay)) 秒后自动重试，请检查设备和系统录音权限。", running: false)
        }
    }

    @available(macOS 14.2, *)
    private func createTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "VibeCute · 实时口型"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "创建系统声音采集")
        output = try defaultOutput()
        let uid: CFString = try read(output, kAudioDevicePropertyDeviceUID)
        var format: AudioStreamBasicDescription = try read(tap, kAudioTapPropertyFormat)
        guard let pcm = AVAudioFormat(streamDescription: &format),
              pcm.commonFormat == .pcmFormatFloat32, format.mSampleRate >= 16_000 else {
            throw CaptureError(message: "当前输出设备的声音格式不受支持")
        }
        sampleRate = format.mSampleRate
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VibeCute实时口型",
            kAudioAggregateDeviceUIDKey: "app.vibecute.audio.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                              kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate), "连接输出设备")
        let analyzer = LiveLipAnalyzer()
        let rate = sampleRate
        io.sync { captureActive = true; configureVocalPipeline() }
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, io) { [weak self] _, input, inputTime, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mData != nil else { return }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(first.mNumberChannels)))
            let startedAt = ProcessInfo.processInfo.systemUptime
            let hasHostTime = inputTime.pointee.mFlags.contains(.hostTimeValid)
            let bufferStart = hasHostTime ? AVAudioTime.seconds(forHostTime: inputTime.pointee.mHostTime)
                : startedAt - Double(frames) / rate
            self.lock.lock(); analyzer.sensitivity = self.gain
            analyzer.voicePriority = self.voicePriority; analyzer.tempoEngine = self.tempoEngine
            analyzer.vowelProfile = self.vowelProfile; self.lock.unlock()
            analyzer.scene = self.classifier?.snapshot() ?? (self.recognitionActive ? .warming : SoundScene(kind: .silence))
            var contextSamples = [Float](); contextSamples.reserveCapacity(frames)
            var stereoSamples = [Float]()
            if self.vocalPipeline != nil { stereoSamples.reserveCapacity(frames * 2) }
            var results = [LiveLipFrame]()
            var peak: Float = 0
            for index in 0..<frames {
                var mono: Float = 0, channels: Float = 0
                var left: Float = 0, right: Float = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let n = Int(buffer.mNumberChannels)
                    guard (index + 1) * n * MemoryLayout<Float>.size <= Int(buffer.mDataByteSize) else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for channel in 0..<n {
                        let sample = samples[index * n + channel]
                        let safe = sample.isFinite ? sample : 0
                        if channels == 0 { left = safe }; if channels == 1 { right = safe }
                        peak = max(peak, abs(safe)); mono += safe
                        channels += 1
                    }
                }
                let sample = mono / max(1, channels)
                if self.vocalPipeline != nil { stereoSamples.append(left); stereoSamples.append(channels < 2 ? left : right) }
                contextSamples.append(sample.isFinite ? sample : 0)
                if var frame = analyzer.consume(sample, sampleRate: rate) {
                    frame.capturedAt = bufferStart + Double(index + 1) / rate
                    frame.analyzedAt = ProcessInfo.processInfo.systemUptime
                    frame.captureTimeEstimated = !hasHostTime
                    results.append(frame)
                }
            }
            if let frame = results.last { self.latestRawFrame = frame }
            let chunkAudioStart = self.recognitionAudioTime
            // Resolve idle/wake before submitting to the optional separator.
            self.consumeRecognitionPCM(contextSamples, peak: peak, sampleRate: rate, startedAt: bufferStart)
            if let pipeline = self.vocalPipeline {
                pipeline.submit(stereo: stereoSamples, sampleRate: rate, capturedStart: bufferStart,
                    audioTimeStart: chunkAudioStart, estimated: !hasHostTime)
                var status = pipeline.snapshot()
                if status.running && !status.failed { status.message = self.vocalUsed ? "已使用分离人声" : "正在分析，暂用原始声音" }
                self.lock.lock(); self.separationStatus = status; self.lock.unlock()
            }
            self.lock.lock()
            let freshVocal = !self.latestRawFrame.laughterPriority && self.vocalUsed && !(self.separationStatus.failed) &&
                self.lastVocalEnd.map { ProcessInfo.processInfo.systemUptime - $0 <= 0.12 } == true
            if !freshVocal {
                if self.vocalUsed {
                    self.mailbox = LiveLipMailbox(); self.vocalUsed = false
                    if !self.separationStatus.failed {
                        self.separationStatus.message = self.latestRawFrame.laughterPriority
                            ? "笑声优先 · 使用原始声音" : "分析未跟上，暂用原始声音"
                    }
                }
                for result in results { self.mailbox.publish(result) }
            }
            self.lock.unlock()
        }, "读取实时声音")
        try check(AudioDeviceStart(aggregate, proc), "启动系统声音采集")
    }

    /// Called by a serial PCM source (live capture or an offline streaming host).
    func consumeRecognitionPCM(_ samples: [Float], peak: Float, sampleRate: Double, startedAt: Double) {
        lastPCMReceivedAt = ProcessInfo.processInfo.systemUptime
        let active = recognitionActivity.receive(peak: peak, frames: samples.count, sampleRate: sampleRate)
        if active && classifier == nil { classifier = makeClassifier(sampleRate, recognitionAudioTime) }
        updateRecognitionActivity(active)
        classifier?.submit(samples)
        // The facade keeps bounded pre-roll while stopped; no model receives it.
        speech.submit(samples, sampleRate: sampleRate, startedAt: startedAt)
        recognitionAudioTime += Double(samples.count) / sampleRate
    }

    private func updateRecognitionActivity(_ active: Bool) {
        if !active { classifier?.stop(); classifier = nil }
        guard active != recognitionActive else { return }
        recognitionActive = active
        lock.lock(); let requested = vocalRequested; lock.unlock()
        if requested || vocalPipeline != nil { configureVocalPipeline() }
        publishRecognitionActivity(active)
    }

    private func publishRecognitionActivity(_ active: Bool) {
        lock.lock(); let token = captureGeneration; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.captureGeneration; self.lock.unlock()
            guard token == current else { return }
            self.speech.setAudioActive(active)
            self.onRecognitionActivity?(active)
        }
    }

    private func defaultOutput() throws -> AudioObjectID {
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "读取音频设备")
        return pointer.load(as: T.self)
    }

    private func tearDown() {
        lock.lock(); captureGeneration += 1; lock.unlock()
        connected = false
        captureHooks?.stop()
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        io.sync {
            captureActive = false; vocalGeneration += 1
            vocalPipeline?.stop(); vocalPipeline = nil; vocalAnalyzer = nil
            latestRawFrame = .silence; lastVocalEnd = nil; vocalUsed = false
            classifier?.stop(); classifier = nil
            recognitionActivity = AudioRecognitionActivity(); recognitionActive = false; lastPCMReceivedAt = nil
            recognitionAudioTime = 0
            publishRecognitionActivity(false)
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if #available(macOS 14.2, *), tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = AudioObjectID(kAudioObjectUnknown); tap = AudioObjectID(kAudioObjectUnknown)
        lock.lock(); mailbox = LiveLipMailbox(); lock.unlock()
    }

    func shutdown() { control.sync { wanted = false; timer?.cancel(); timer = nil; tearDown() } }

    private func report(_ message: String, running: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(message, running) }
    }
    private func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr { throw CaptureError(message: "\(action)失败（\(status)）") }
    }
    private struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
