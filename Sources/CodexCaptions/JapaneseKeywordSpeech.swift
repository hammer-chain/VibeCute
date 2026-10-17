import Foundation
import AVFoundation
import Speech
import CaptionCore

/// Only on-device ja-JP. No cloud fallback, microphone, or audio/transcript files.
/// All Speech task state lives on one queue; input buffering is bounded.
final class JapaneseKeywordSpeech {
    var onStatus: ((String, Bool) -> Void)?
    var onTranscript: ((String, SpeechProgress) -> Void)?
    var onProgress: ((SpeechProgress) -> Void)?
    var onKeyword: ((SpeechKeywordMatch, Bool) -> Void)?
    private let queue = DispatchQueue(label: "captions.speech.japanese", qos: .userInitiated)
    private let inputLock = NSLock()
    private var accepting = false
    private var pending = 0
    private var inputEpoch = 0
    private var wanted = false
    private var generation = 0
    private var taskGeneration = 0
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var origin: TimeInterval?
    private var lastEnd: TimeInterval?
    private var rate: Double = 0
    private var lastAudible: TimeInterval = -.infinity
    private var spotters = JapaneseKiraKeyword.allCases.map { SpeechKeywordSpotter(keyword: $0) }
    private var recent: [Chunk] = []
    private var retryAt: TimeInterval = 0
    private var failures = 0
    private var progress = SpeechProgress()
    private var lastProgressAt: TimeInterval = -.infinity
    private var lastText = ""
    private var nextRequestReason = "首次启动"
    private struct Chunk { let samples: [Float]; let rate: Double; let start: TimeInterval
        var end: TimeInterval { start + Double(samples.count) / rate }
    }

    deinit { request?.endAudio(); task?.cancel() }

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.wanted != enabled else { return }
            self.wanted = enabled; self.generation += 1; self.stopTask()
            self.spotters = JapaneseKiraKeyword.allCases.map { SpeechKeywordSpotter(keyword: $0) }
            self.failures = 0; self.retryAt = 0
            self.progress = SpeechProgress(); self.lastText = ""; self.nextRequestReason = "首次启动"
            self.publishProgress(force: true)
            guard enabled else { self.report("Apple Speech 已关闭", running: false); return }
            self.prepare()
        }
    }

    private func prepare() {
        guard wanted else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")) else {
            report("本机不支持 Apple Speech 日语", running: false); return
        }
        self.recognizer = recognizer
        // Check before authorization so a missing model never causes an
        // unnecessary privacy prompt or silently switches to Apple's servers.
        guard recognizer.supportsOnDeviceRecognition else {
            report("缺少日语离线模型：在系统设置的键盘听写中添加日语，下载完成后重试", running: false); return
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: activate()
        case .notDetermined:
            report("等待系统语音识别授权", running: false)
            let token = generation
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                self?.queue.async { [weak self] in
                    guard let self, self.wanted, token == self.generation else { return }
                    if status == .authorized { self.activate() }
                    else { self.report("未获语音识别权限，请在系统设置中允许VibeCute", running: false) }
                }
            }
        case .denied, .restricted:
            report("语音识别权限未允许，请在系统设置中检查", running: false)
        @unknown default: report("无法确定语音识别权限", running: false)
        }
    }

    private func activate() {
        guard wanted, recognizer?.supportsOnDeviceRecognition == true, recognizer?.isAvailable == true else {
            report("日语离线识别暂不可用，请稍后重试", running: false); return
        }
        inputLock.lock(); accepting = true; inputLock.unlock()
        report("日语离线识别已就绪 · 等待系统声音", running: true)
    }

    func submit(_ samples: [Float], sampleRate: Double, startedAt: TimeInterval) {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate >= 16_000, startedAt.isFinite else { return }
        inputLock.lock()
        guard accepting, pending < 8 else { inputLock.unlock(); return }
        pending += 1; let epoch = inputEpoch; inputLock.unlock()
        let chunk = Chunk(samples: samples, rate: sampleRate, start: startedAt)
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.inputLock.lock(); self.pending -= 1; self.inputLock.unlock() }
            self.inputLock.lock(); let current = self.inputEpoch; self.inputLock.unlock()
            guard self.wanted, epoch == current else { return }
            self.consume(chunk)
        }
    }

    /// Device switching is a new clock/format, not a continuation of old words.
    func resetStream() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopTask()
            self.nextRequestReason = "音频设备重新连接"
            if self.wanted, self.recognizer?.supportsOnDeviceRecognition == true,
               SFSpeechRecognizer.authorizationStatus() == .authorized { self.activate() }
        }
    }

    private func consume(_ chunk: Chunk) {
        guard ProcessInfo.processInfo.systemUptime >= retryAt else { return }
        if let end = lastEnd, abs(chunk.start - end) > 0.12 || rate != chunk.rate {
            stopTask(); activate()
            nextRequestReason = "音频输入中断或格式改变"
        }
        if request == nil { startTask(rate: chunk.rate, origin: chunk.start) }
        guard request != nil else { return }
        if let origin, chunk.end - origin >= 45 {
            let overlap = recent
            stopTask(); activate()
            nextRequestReason = "45 秒续接（重叠 2 秒）"
            startTask(rate: chunk.rate, origin: overlap.first?.start ?? chunk.start)
            for old in overlap { append(old) }
        }
        append(chunk)
        recent.append(chunk)
        recent.removeAll { chunk.end - $0.end > 2 }
    }

    private func startTask(rate: Double, origin: TimeInterval) {
        guard wanted, let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            stopTask(); report("日语离线识别暂不可用，请检查模型和权限后重试", running: false); return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Bias gently towards the real keyword, not an entire expected lyric.
        request.contextualStrings = JapaneseKiraKeyword.allCases.map(\.rawValue)
        self.request = request; self.origin = origin; self.rate = rate
        progress.requestNumber += 1; progress.requestReason = nextRequestReason
        lastText = ""
        publishProgress(force: true)
        taskGeneration += 1; let token = taskGeneration
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.queue.async { [weak self] in
                guard let self, self.wanted, self.taskGeneration == token else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let result {
                    self.failures = 0
                    let fullText = result.bestTranscription.formattedString
                    let text = String(fullText.suffix(160))
                    let words = result.bestTranscription.segments.map {
                        SpeechWord($0.substring, timestamp: $0.timestamp, duration: $0.duration)
                    }
                    if let origin = self.origin {
                        self.progress.receive(words: words, origin: origin, at: now, isFinal: result.isFinal,
                                              textChanged: fullText != self.lastText)
                    }
                    self.lastText = fullText
                    let progress = self.progress
                    DispatchQueue.main.async { [weak self] in self?.onTranscript?(text, progress) }
                    self.publishProgress(force: true)
                    if let origin = self.origin, let inputEnd = self.lastEnd {
                        for index in self.spotters.indices {
                            if let match = self.spotters[index].receive(text: fullText, words: words,
                                requestNumber: progress.requestNumber, origin: origin, inputEnd: inputEnd, at: now,
                                timingIsFinal: result.isFinal) {
                                let audible = now - self.lastAudible < 3
                                DispatchQueue.main.async { [weak self] in self?.onKeyword?(match, audible) }
                            }
                        }
                    }
                    if result.isFinal {
                        self.stopTask(); self.activate(); self.nextRequestReason = "上一轮已定稿"
                    }
                }
                if let error {
                    self.failures += 1
                    self.stopTask()
                    self.nextRequestReason = "识别错误后重试"
                    self.retryAt = now + min(15, pow(2, Double(self.failures)))
                    if self.failures >= 3 {
                        self.report("Apple Speech 连续失败（\((error as NSError).code)），请检查日语资源后重试", running: false)
                    } else {
                        self.activate()
                        self.report("日语识别中断（\((error as NSError).code)）· 稍后重试", running: false)
                    }
                }
            }
        }
        report("正在离线识别日语 · 等待「\(JapaneseKiraKeyword.displayList)」", running: true)
    }

    private func append(_ chunk: Chunk) {
        guard let request, let format = AVAudioFormat(standardFormatWithSampleRate: chunk.rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { src in buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count) }
        if chunk.samples.contains(where: { abs($0) > 0.003 }) {
            lastAudible = chunk.end; progress.audibleEnd = chunk.end
        }
        request.append(buffer); lastEnd = chunk.end
        if progress.streamStartedAt == nil { progress.streamStartedAt = chunk.start }
        progress.inputEnd = chunk.end
        publishProgress()
    }

    private func publishProgress(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastProgressAt >= 0.25 else { return }
        lastProgressAt = now
        let value = progress
        DispatchQueue.main.async { [weak self] in self?.onProgress?(value) }
    }

    private func stopTask() {
        inputLock.lock(); accepting = false; inputEpoch += 1; inputLock.unlock()
        taskGeneration += 1; request?.endAudio(); task?.cancel()
        task = nil; request = nil; origin = nil; lastEnd = nil; recent.removeAll(); lastAudible = -.infinity
    }
    private func report(_ message: String, running: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(message, running) }
    }
}
