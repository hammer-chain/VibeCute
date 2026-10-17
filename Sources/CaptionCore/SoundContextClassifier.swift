import AVFoundation
import SoundAnalysis

/// Slow context runs off the audio callback. At most 600 ms of pending PCM is
/// retained; overload drops old chunks rather than delaying live mouth frames.
public final class SoundContextClassifier: NSObject, SNResultsObserving {
    private struct Chunk { let samples: [Float]; let position: AVAudioFramePosition }
    private let worker = DispatchQueue(label: "captions.audio.context", qos: .utility)
    private let lock = NSLock()
    private let rate: Double, chunkSize: Int
    private let audioTimeOrigin: Double
    private var pending: [Chunk] = []
    private var draining = false, stopped = false
    private var result = SoundScene.warming
    private var stream: SNAudioStreamAnalyzer?
    private let tracker = SoundSceneTracker()
    // Only the serial capture queue calls submit.
    private var accumulator: [Float] = []
    private var position: AVAudioFramePosition = 0

    public init(sampleRate: Double, audioTimeOrigin: Double = 0) {
        rate = sampleRate; chunkSize = max(1, Int(sampleRate / 10))
        self.audioTimeOrigin = audioTimeOrigin.isFinite && audioTimeOrigin >= 0 ? audioTimeOrigin : 0
        super.init()
        worker.async { [self] in
            guard !isStopped else { return }
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
                let analyzer = SNAudioStreamAnalyzer(format: format)
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                request.windowDuration = CMTime(seconds: 1, preferredTimescale: 48_000)
                request.overlapFactor = 0.5
                try analyzer.add(request, withObserver: self)
                stream = analyzer
            } catch { publish(.unavailable) }
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func snapshot() -> SoundScene { lock.lock(); defer { lock.unlock() }; return result }
    private func publish(_ scene: SoundScene) {
        lock.lock(); defer { lock.unlock() }
        if !stopped { result = scene }
    }

    public func submit(_ samples: [Float]) {
        guard !isStopped else { return }
        accumulator.append(contentsOf: samples)
        while accumulator.count >= chunkSize {
            let chunk = Chunk(samples: Array(accumulator.prefix(chunkSize)), position: position)
            position += AVAudioFramePosition(chunkSize)
            accumulator.removeFirst(chunkSize)
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            if pending.count >= 6 { pending.removeFirst() }
            pending.append(chunk)
            let schedule = !draining; draining = true
            lock.unlock()
            if schedule { worker.async { [self] in drainOne() } }
        }
    }

    private func drainOne() {
        lock.lock()
        guard !stopped, !pending.isEmpty else { draining = false; lock.unlock(); return }
        let chunk = pending.removeFirst()
        lock.unlock()
        if let stream, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)) {
            buffer.frameLength = buffer.frameCapacity
            chunk.samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
            }
            stream.analyze(buffer, atAudioFramePosition: chunk.position)
        }
        worker.async { [self] in drainOne() }
    }

    public func stop() {
        lock.lock(); stopped = true; pending.removeAll(); lock.unlock()
        worker.async { [self] in stream?.removeAllRequests(); stream = nil }
    }

    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let scores = Dictionary(classification.classifications.map { ($0.identifier, Float($0.confidence)) },
                                uniquingKeysWith: max)
        let time = audioTimeOrigin + CMTimeRangeGetEnd(classification.timeRange).seconds
        worker.async { [self] in
            guard !isStopped, let scene = tracker.receive(scores, at: time) else { return }
            publish(scene)
        }
    }
    public func request(_ request: SNRequest, didFailWithError error: Error) { publish(.unavailable) }
}
