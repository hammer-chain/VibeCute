import Foundation

/// Resolve aubio's rhythmic level using an independently stable onset grid.
/// Only simple period ratios are eligible; this is not playback-rate metadata.
public struct TempoScaleResolver {
    public private(set) var multiplier: Double = 1
    private var previousRaw: Double?
    private var pending: Double?
    private var pendingStart: TimeInterval = 0
    private var pendingAttacks = 0
    private var lastAttack: TimeInterval = -.infinity
    private var lastReference: TimeInterval = -.infinity
    private var lastSample: TimeInterval = -.infinity
    public init() {}

    public mutating func sample(rawBPM: Double?, reference: BeatEstimate, at time: TimeInterval) -> Double? {
        guard time.isFinite else { return nil }
        if time < lastSample { self = TempoScaleResolver() }
        lastSample = time
        guard let rawBPM, rawBPM.isFinite, (60...360).contains(rawBPM) else {
            if time - lastReference > 2 { pending = nil; pendingAttacks = 0 }
            return nil
        }
        if let previousRaw, abs(rawBPM - previousRaw) / previousRaw > 0.2 {
            // Aubio itself has changed level: don't apply yesterday's factor.
            multiplier = 1; pending = nil; pendingAttacks = 0
        }
        previousRaw = rawBPM
        let fresh = reference.reliable && (0...0.12).contains(time - reference.audioTime)
        if fresh, let bpm = reference.bpm, reference.confidence >= 0.7,
           let attack = reference.lastAccentTime, (0...2).contains(time - attack) {
            let factors = [0.25, 1.0 / 3, 0.5, 1, 2, 3, 4]
            let eligible = factors.filter { (58...370).contains(rawBPM * $0) }
            let best = eligible.min { abs(log(rawBPM * $0 / bpm)) < abs(log(rawBPM * $1 / bpm)) }
            if let best, abs(rawBPM * best - bpm) / bpm <= 0.1 {
                lastReference = time
                if best == multiplier { pending = nil; pendingAttacks = 0 }
                else {
                    if pending != best { pending = best; pendingStart = time; pendingAttacks = 0 }
                    if attack > lastAttack { pendingAttacks += 1 }
                    // One loud hit, repeated UI polls and weak subdivisions may
                    // not reinterpret the rhythmic level of a whole song.
                    if time - pendingStart >= 1.5 && pendingAttacks >= 3 {
                        multiplier = best; pending = nil; pendingAttacks = 0
                    }
                }
                lastAttack = max(lastAttack, attack)
            } else { pending = nil; pendingAttacks = 0 }
        } else if time - lastReference > 0.3 {
            pending = nil; pendingAttacks = 0
        }
        let result = rawBPM * multiplier
        guard (58...370).contains(result) else { return nil }
        // Permit FFT quantization at the supported range boundaries.
        return max(60, min(360, result))
    }
}
