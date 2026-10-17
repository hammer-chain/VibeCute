import Foundation

/// A local rhythm estimate, not a calibrated probability or a bar/downbeat detector.
public struct BeatEstimate {
    public let bpm: Double?
    public let rawBPM: Double?
    public let engine: TempoEngine
    public let referenceBPM: Double?
    public let tempoMultiplier: Double
    /// BeatNet worker batches discarded on overload; zero for synchronous engines.
    public let droppedBatches: Int
    /// Last BeatNet 100 ms inference batch wall time; not capture-to-display latency.
    public let processingMs: Double
    public let confidence: Float
    public let audioTime: TimeInterval
    public let lastBeatTime: TimeInterval?
    /// A detected strong attack, available before a stable BPM is known.
    /// It is not necessarily the first beat of a musical bar.
    public let lastAccentTime: TimeInterval?
    public static let unknown = BeatEstimate()
    public init(bpm: Double? = nil, confidence: Float = 0, audioTime: TimeInterval = 0,
                lastBeatTime: TimeInterval? = nil, lastAccentTime: TimeInterval? = nil,
                engine: TempoEngine = .spectral, rawBPM: Double? = nil,
                referenceBPM: Double? = nil, tempoMultiplier: Double = 1, droppedBatches: Int = 0, processingMs: Double = 0) {
        self.bpm = bpm; self.confidence = confidence; self.audioTime = audioTime; self.lastBeatTime = lastBeatTime
        self.lastAccentTime = lastAccentTime; self.engine = engine; self.rawBPM = rawBPM ?? bpm
        self.referenceBPM = referenceBPM; self.tempoMultiplier = tempoMultiplier
        self.droppedBatches = droppedBatches; self.processingMs = processingMs
    }
    public var reliable: Bool {
        guard let bpm, let lastBeatTime else { return false }
        return bpm.isFinite && (60...360).contains(bpm) && confidence.isFinite && (engine == .aubio ? confidence >= 0.01 : confidence >= 0.55) &&
            audioTime.isFinite && lastBeatTime.isFinite && (0...2).contains(audioTime - lastBeatTime)
    }
}

/// Positive log-spectral flux, adaptive local peaks, then consistent onset
/// intervals. All storage is bounded; no PCM history or file preprocessing.
public struct BeatTracker {
    private var previousSpectrum = [Float](repeating: 0, count: 512)
    private var mean: Float = 0, previous: Float = 0, beforePrevious: Float = 0
    private var previousTime: TimeInterval = 0, previousRMS: Float = 0
    private var beforePreviousRMS: Float = 0
    private var lastTime: TimeInterval = -.infinity
    private struct Onset { let time: TimeInterval; let strength: Float }
    private var onsets: [Onset] = []
    private var period: Double?
    private var confidence: Float = 0
    private var lastBeat: TimeInterval?
    private var lastAccent: TimeInterval?
    private var active = false
    private var pendingPeriod: Double?
    private var pendingSince: TimeInterval = 0
    public init() {}

    public mutating func sample(power: [Float], rms: Float, at time: TimeInterval, musical: Bool) -> BeatEstimate {
        guard time.isFinite, rms.isFinite, power.count >= 512 else { return .unknown }
        if time <= lastTime || !musical {
            self = BeatTracker(); lastTime = time
            return .unknown
        }
        lastTime = time
        var flux: Float = 0
        for bin in 4..<384 {
            let value = log1p(sqrt(max(0, power[bin])) * 0.25)
            flux += max(0, value - previousSpectrum[bin]) * (bin < 20 ? 2 : 1)
            previousSpectrum[bin] = value
        }
        flux /= 380
        if !active { active = true; flux = 0 }
        if previous > beforePrevious && previous >= flux && previous > mean * 1.7 + 0.002 &&
            previousRMS > 0.002 && previousTime - (onsets.last?.time ?? -.infinity) >= 0.10 {
            // Capture the whole attack, not only the FFT-peak instant. Window
            // alignment otherwise makes equal fast beats appear strong/weak.
            receiveOnset(at: previousTime, strength: max(rms, max(previousRMS, beforePreviousRMS)))
        }
        mean += 0.035 * (flux - mean)
        beforePrevious = previous; previous = flux; previousTime = time
        beforePreviousRMS = previousRMS; previousRMS = rms
        if let latest = onsets.last, time - latest.time > 2 {
            onsets.removeAll(keepingCapacity: true); period = nil; confidence = 0; lastBeat = nil; lastAccent = nil; pendingPeriod = nil
        }
        return BeatEstimate(bpm: period.map { 60 / $0 }, confidence: confidence,
                            audioTime: time, lastBeatTime: lastBeat, lastAccentTime: lastAccent)
    }

    private mutating func receiveOnset(at time: TimeInterval, strength: Float) {
        onsets.append(Onset(time: time, strength: strength))
        onsets.removeAll { time - $0.time > 6 }
        if onsets.count > 64 { onsets.removeFirst(onsets.count - 64) }
        // Weak subdivisions do not replace the main pulse. Strong beats can
        // accelerate together when the entire playback timeline changes.
        let strengths = onsets.map(\.strength).sorted()
        let reference = strengths[strengths.count * 3 / 4]
        if strength >= reference * 0.65 { lastAccent = time }
        let strong = onsets.filter { $0.strength >= reference * 0.5 }
        let intervals = zip(strong, strong.dropFirst()).map { $1.time - $0.time }
        guard intervals.count >= 4, time - strong[0].time >= 1.5 else { return }
        let recent = Array(intervals.suffix(8))
        // Fold only outside the supported range; never force a valid doubled
        // tempo back toward an old estimate.
        let normalized = recent.map { gap -> Double in
            var folded = gap
            // Allow one analysis hop of timing quantization at 60/360 BPM.
            while folded < 0.15 { folded *= 2 }
            while folded > 1.03 { folded /= 2 }
            return folded
        }
        let sorted = normalized.sorted(), center = sorted[sorted.count / 2]
        let tolerance = max(0.025, center * 0.12)
        let consistent = normalized.filter { abs($0 - center) <= tolerance }
        confidence = Float(consistent.count) / Float(recent.count)
        guard confidence >= 0.7 else { pendingPeriod = nil; return }
        let candidate = max(1.0 / 6, min(1, consistent.reduce(0, +) / Double(consistent.count)))
        if let current = period, abs(candidate - current) > current * 0.2 {
            if pendingPeriod.map({ abs(candidate - $0) > $0 * 0.12 }) ?? true {
                pendingPeriod = candidate; pendingSince = time
            }
            // Require sustained new timing, including a real 2x/0.5x change.
            guard time - pendingSince >= 1 else { return }
            period = candidate; pendingPeriod = nil; lastBeat = time
        } else {
            period = period.map { $0 + 0.18 * (candidate - $0) } ?? candidate
            pendingPeriod = nil
        }
        if let lastBeat, let period, time - lastBeat <= 2 {
            let beats = max(1, round((time - lastBeat) / period))
            let predicted = lastBeat + beats * period
            if abs(time - predicted) < period * 0.2 {
                self.lastBeat = predicted + max(-0.025, min(0.025, (time - predicted) * 0.25))
            }
        } else { lastBeat = time }
    }
}
