import Foundation

/// One request in flight and one replaceable input packet. Missed audio resets
/// both resampling and model state; old results never become current mouth audio.
public final class VocalSeparationPipeline {
    public struct Output {
        public let samples: [Float]
        public let capturedEnd: Double
        public let audioTimeEnd: Double
        public let reset: Bool
        public let captureTimeEstimated: Bool
    }
    public struct Status {
        public init() {}
        public var message = "正在准备人声分离…"
        public var running = false
        public var failed = false
        public var processed = 0
        public var dropped = 0
    }
    private struct Packet {
        let stereo: [Float], rate: Double, capturedStart: Double, audioTimeStart: Double, estimated: Bool
    }
    private let queue = DispatchQueue(label: "captions.vocal.worker", qos: .userInitiated)
    private let lock = NSLock()
    private let directory: URL
    private var transport: VocalWorkerTransport?
    private var pending: Packet?
    private var stopped = false, draining = false
    private var state = Status()
    private var resampler: VocalStereoResampler?
    private var formatRate = 0.0, expectedStart: Double?
    private var accumulated = [Float]()
    private var segmentCaptureStart = 0.0, segmentAudioStart = 0.0
    private var needsReset = true
    private var outputNeedsReset = true
    public var onOutput: ((Output) -> Void)?
    public init(directory: URL) { self.directory = directory }
    public func snapshot() -> Status { lock.lock(); defer { lock.unlock() }; return state }
    public func submit(stereo: [Float], sampleRate: Double, capturedStart: Double, audioTimeStart: Double, estimated: Bool) {
        guard sampleRate.isFinite, (16000...192000).contains(sampleRate), stereo.count % 2 == 0,
              stereo.count <= 8192, !stereo.isEmpty, capturedStart.isFinite, audioTimeStart.isFinite else { return }
        lock.lock()
        guard !stopped, !state.failed else { lock.unlock(); return }
        if pending != nil { state.dropped += 1 }
        pending = Packet(stereo: stereo, rate: sampleRate, capturedStart: capturedStart, audioTimeStart: audioTimeStart, estimated: estimated)
        let schedule = !draining; draining = true; lock.unlock()
        if schedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        do {
            if transport == nil {
                let created = try VocalWorkerTransport(directory: directory)
                lock.lock()
                if stopped { lock.unlock(); created.stop(); return }
                transport = created; state.running = true; state.message = "人声分离已运行"; lock.unlock()
            }
            while true {
                lock.lock()
                guard !stopped, let packet = pending else { draining = false; lock.unlock(); return }
                pending = nil; lock.unlock()
                // Skip input already outside the mouth freshness budget.
                if ProcessInfo.processInfo.systemUptime - packet.capturedStart > 0.12 {
                    expectedStart = nil; lock.lock(); state.dropped += 1; lock.unlock(); continue
                }
                let discontinuity = formatRate != packet.rate || expectedStart == nil || abs(packet.capturedStart - expectedStart!) > 0.002
                if discontinuity {
                    resampler = VocalStereoResampler(sampleRate: packet.rate); formatRate = packet.rate
                    segmentCaptureStart = packet.capturedStart; segmentAudioStart = packet.audioTimeStart
                    accumulated.removeAll(keepingCapacity: true); needsReset = true; outputNeedsReset = true
                }
                expectedStart = packet.capturedStart + Double(packet.stereo.count / 2) / packet.rate
                let converted = resampler!.consume(stereo: packet.stereo, capturedStart: packet.capturedStart)
                accumulated.append(contentsOf: converted.stereo)
                guard let convertedEnd = converted.capturedEnd else { continue }
                while accumulated.count >= 1024 {
                    let remainingFrames = (accumulated.count - 1024) / 2
                    let capturedEnd = convertedEnd - Double(remainingFrames) / 44100
                    let batch = Array(accumulated.prefix(1024)); accumulated.removeFirst(1024)
                    let reset = needsReset; needsReset = false
                    let result = try transport!.transact(stereo: batch, capturedEnd: capturedEnd, reset: reset)
                    lock.lock(); let cancelled = stopped; state.processed += 1; lock.unlock()
                    if cancelled { return }
                    guard ProcessInfo.processInfo.systemUptime - result.capturedEnd <= 0.12 else {
                        outputNeedsReset = true
                        lock.lock(); state.dropped += 1; lock.unlock(); continue
                    }
                    let resetAnalyzer = outputNeedsReset; outputNeedsReset = false
                    onOutput?(Output(samples: result.samples, capturedEnd: result.capturedEnd,
                        audioTimeEnd: segmentAudioStart + result.capturedEnd - segmentCaptureStart,
                        reset: resetAnalyzer, captureTimeEstimated: packet.estimated))
                }
            }
        } catch {
            lock.lock(); state.running = false; state.failed = true
            state.message = "人声分离不可用，使用原始声音"; pending = nil; draining = false
            let current = transport; transport = nil; lock.unlock(); current?.stop()
        }
    }
    public func stop() {
        lock.lock(); stopped = true; pending = nil; let current = transport; lock.unlock(); current?.stop()
    }
    deinit { stop() }
}
