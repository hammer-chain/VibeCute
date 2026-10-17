import Foundation
import AVFoundation
import Darwin
#if canImport(CaptionCore)
import CaptionCore
#endif

/// One persistent local worker; at most one inference and ten seconds of PCM.
/// Overlapping windows are provisional: trigger from receipt, never pretend the
/// end of an entire segment is the acoustic endpoint of a keyword inside it.
final class WhisperKeywordSpeech: KeywordSpeechBackend {
    static let windowSeconds = 10
    private static let sampleLimit = windowSeconds * 16_000
    var onStatus: ((String, Bool) -> Void)?
    var onTranscript: ((String, SpeechProgress) -> Void)?
    var onProgress: ((SpeechProgress) -> Void)?
    var onKeyword: ((SpeechKeywordMatch, Bool) -> Void)?
    static var bundledModelPath: String {
        Bundle.main.resourceURL?.appendingPathComponent("Whisper/ggml-small-q5_1.bin").path ?? ""
    }
    private let modelPath: String
    private let workerURL: URL
    private let queue = DispatchQueue(label: "captions.whisper.input", qos: .userInitiated)
    private let writer = DispatchQueue(label: "captions.whisper.writer", qos: .utility)
    private let lock = NSLock()
    private var accepting = false
    private var pending = 0
    private var inputEpoch = 0
    private var deliveryEpoch = 0
    private var wanted = false
    private var generation = 0
    private var stream = 0
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var response = Data()
    private var ready = false
    private var converter: AVAudioConverter?
    private var rate: Double = 0
    private var lastEnd: Double?
    private var samples = [Float]()
    private var sampleOrigin: Double?
    private var lastSubmittedEnd = -Double.infinity
    private var inFlight: (stream: Int, number: Int, start: Double, end: Double)?
    private var progress = SpeechProgress()
    private var lastPublished = -Double.infinity
    private var lastText = ""
    private var spotters = JapaneseKiraKeyword.allCases.map { SpeechKeywordSpotter(keyword: $0) }
    private var matchedWindowEnds: [JapaneseKiraKeyword: Double] = [:]

    init(modelPath: String = "", workerURL: URL? = nil) {
        self.modelPath = modelPath.isEmpty ? Self.bundledModelPath : modelPath
        self.workerURL = workerURL ?? Bundle.main.resourceURL!.appendingPathComponent("Whisper/captions-whisper")
    }
    deinit {
        output?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.wanted != enabled else { return }
            self.wanted = enabled; self.stopWorker(); self.clearStream()
            self.spotters = JapaneseKiraKeyword.allCases.map { SpeechKeywordSpotter(keyword: $0) }
            self.matchedWindowEnds = [:]
            guard enabled else { self.report("whisper.cpp 已关闭", false); return }
            self.startWorker()
        }
    }
    func resetStream() {
        queue.async { [weak self] in self?.clearStream() }
    }
    private func clearStream() {
        lock.lock(); inputEpoch += 1; deliveryEpoch += 1; lock.unlock()
        stream += 1; samples.removeAll(keepingCapacity: true); converter = nil
        sampleOrigin = nil; lastEnd = nil; rate = 0; lastSubmittedEnd = -.infinity
        matchedWindowEnds = [:]
        progress = SpeechProgress(); progress.requestReason = "重叠音频窗口 · 按返回时刻计时"
        lastText = ""; publish(force: true)
    }
    private func startWorker() {
        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            report("缺少 Whisper 组件：请运行 scripts/prepare_whisper.sh 后重新构建", false); return
        }
        guard FileManager.default.isReadableFile(atPath: modelPath) else {
            report("未找到 Whisper 模型，请选择多语言 ggml .bin 模型", false); return
        }
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.executableURL = workerURL; child.arguments = [modelPath]
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        let token = generation
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                guard let self, self.generation == token, self.wanted else { return }
                self.receive(data)
            }
        }
        child.terminationHandler = { [weak self] child in
            self?.queue.async { [weak self] in
                guard let self, self.generation == token, self.wanted else { return }
                self.fail("Whisper 进程已退出（\(child.terminationStatus)），请重试识别")
            }
        }
        process = child; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try child.run()
            // Only the worker owns these ends after launch; EOF then terminates it.
            try? stdinPipe.fileHandleForReading.close(); try? stdoutPipe.fileHandleForWriting.close()
            report("正在加载 Whisper · \(URL(fileURLWithPath: modelPath).lastPathComponent)", false)
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.generation == token, !self.ready else { return }
                self.fail("Whisper 模型加载超时，请重试或选择较小模型")
            }
        } catch { fail("无法启动 Whisper：\(error.localizedDescription)") }
    }
    private func stopWorker() {
        generation += 1
        lock.lock(); accepting = false; inputEpoch += 1; deliveryEpoch += 1; lock.unlock()
        output?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? input?.close(); try? output?.close()
        process = nil; input = nil; output = nil; ready = false; inFlight = nil; response.removeAll()
    }
    private func fail(_ message: String) { stopWorker(); clearStream(); report(message, false) }

    func submit(_ inputSamples: [Float], sampleRate: Double, startedAt: TimeInterval) {
        guard sampleRate.isFinite, (16_000...192_000).contains(sampleRate), startedAt.isFinite,
              !inputSamples.isEmpty, inputSamples.count <= Int(sampleRate) else { return }
        lock.lock()
        guard accepting, pending < 8 else { lock.unlock(); return }
        pending += 1; let epoch = inputEpoch; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            self.lock.lock(); let current = self.inputEpoch; self.lock.unlock()
            guard self.wanted, self.ready, epoch == current else { return }
            self.consume(inputSamples, sampleRate, startedAt)
        }
    }
    private func consume(_ pcm: [Float], _ sampleRate: Double, _ start: Double) {
        if let lastEnd, abs(start - lastEnd) > 0.12 || sampleRate != rate { clearStream() }
        if converter == nil {
            guard let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                  let value = AVAudioConverter(from: source, to: target) else { return }
            value.primeMethod = .none; converter = value; rate = sampleRate; sampleOrigin = start
        }
        guard let converter,
              let source = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(pcm.count)),
              let target = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(pcm.count) * 16_000 / sampleRate) + 32)) else { return }
        source.frameLength = source.frameCapacity
        pcm.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false, error: NSError?
        let status = converter.convert(to: target, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        guard status != .error, error == nil else { fail("Whisper 音频转换失败，请重试"); return }
        samples.append(contentsOf: UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
        if samples.count > Self.sampleLimit {
            let excess = samples.count - Self.sampleLimit; samples.removeFirst(excess)
            sampleOrigin = (sampleOrigin ?? start) + Double(excess) / 16_000
        }
        let end = start + Double(pcm.count) / sampleRate
        lastEnd = end; progress.inputEnd = end
        if progress.streamStartedAt == nil { progress.streamStartedAt = start }
        if pcm.contains(where: { abs($0) > 0.003 }) { progress.audibleEnd = end }
        publish(); inferIfReady()
    }
    private func inferIfReady() {
        guard ready, inFlight == nil, let input, let origin = sampleOrigin,
              samples.count >= 32_000, let end = lastEnd, end - lastSubmittedEnd >= 1,
              ProcessInfo.processInfo.systemUptime - end < 1,
              progress.audibleEnd.map({ end - $0 < 2 }) == true else { return }
        lastSubmittedEnd = end; progress.requestNumber += 1
        let number = progress.requestNumber, token = generation, streamToken = stream
        inFlight = (stream, number, origin, end)
        var count = UInt32(samples.count).littleEndian
        var data = Data(bytes: &count, count: 4)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch {
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token else { return }; self.fail("Whisper 音频传输中断，请重试")
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.generation == token, self.inFlight?.stream == streamToken,
                  self.inFlight?.number == number else { return }
            self.fail("Whisper 推理超时，请重试或选择较小模型")
        }
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { fail("Whisper 连接已关闭，请重试识别"); return }
        response.append(data)
        guard response.count <= 65_536 else { fail("Whisper 返回过长，已停止"); return }
        while let end = response.firstIndex(of: 10) {
            let line = Data(response[..<end]); response.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                fail("Whisper 返回格式无效"); return
            }
            if let error = value["error"] as? String { fail("Whisper：\(error)"); return }
            if value["ready"] as? Bool == true {
                ready = true; clearStream()
                lock.lock(); accepting = true; lock.unlock()
                report("Whisper 本机日语已就绪 · \(URL(fileURLWithPath: modelPath).lastPathComponent)", true)
            } else if let text = value["text"] as? String, let request = inFlight {
                inFlight = nil
                let now = ProcessInfo.processInfo.systemUptime
                if request.stream == stream {
                    progress.receive(words: [], origin: request.start, at: now, isFinal: false, textChanged: text != lastText)
                    lastText = text
                    let value = progress
                    emit { $0.onTranscript?(String(text.suffix(160)), value) }; publish(force: true)
                    // Slow/paused input must never replay a stale keyword as fresh.
                    if now - request.end <= 2 {
                        for index in spotters.indices {
                            let keyword = spotters[index].keyword
                            guard request.start >= (matchedWindowEnds[keyword] ?? -.infinity) else { continue }
                            if let match = spotters[index].receive(text: text, words: [], requestNumber: request.number,
                                    origin: request.start, inputEnd: request.end, at: now) {
                                matchedWindowEnds[keyword] = request.end
                                let audible = progress.audibleEnd.map { now - $0 < 3 } ?? false
                                emit { $0.onKeyword?(match, audible) }
                            }
                        }
                    } else { report("Whisper 结果迟到 · 已跳过动作，继续处理最新窗口", true) }
                }
                inferIfReady()
            }
        }
    }
    private func publish(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPublished >= 0.25 else { return }
        lastPublished = now; let value = progress
        emit { $0.onProgress?(value) }
    }
    private func report(_ text: String, _ running: Bool) { emit { $0.onStatus?(text, running) } }
    private func emit(_ callback: @escaping (WhisperKeywordSpeech) -> Void) {
        lock.lock(); let epoch = deliveryEpoch; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.deliveryEpoch; self.lock.unlock()
            if epoch == current { callback(self) }
        }
    }
}
