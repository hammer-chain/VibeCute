import Foundation

/// Audio evidence selects a complete action, never an individual body frame.
/// Explicit disabling cancels immediately. Confirmed acoustic silence can end
/// rising from its current pose; classifier flicker cannot reverse a transition.
public struct SingingPerformance {
    public enum Phase: String { case seated, rising, singing, sitting }
    public private(set) var phase = Phase.seated
    public private(set) var frameIndex: Int?
    private var phaseStart: TimeInterval = 0
    private var lastSample: TimeInterval = -.infinity
    private var lastSong: TimeInterval = -.infinity
    private var lastMusic: TimeInterval = -.infinity
    private var lastMusicEvidence: TimeInterval = -.infinity
    private var speechStart: TimeInterval?
    private var lastSpeech: TimeInterval = -.infinity
    private var lastSpeechEvidence: TimeInterval = -.infinity
    private var cyclePhase: Double = 0
    public var cycleProgress: Double { cyclePhase - floor(cyclePhase) }
    private var lastAccentTime: TimeInterval = -.infinity
    private var accentVelocity: Double = 0
    private var phaseCorrection: Double = 0
    public private(set) var alignedAccentTime: TimeInterval = -.infinity
    public private(set) var accentPhaseErrorSeconds: Double?
    public private(set) var phaseAlignmentCount = 0
    private var sittingFromStep = SingingTimeline.risingFrames.count - 1
    public private(set) var cycleDuration: TimeInterval = SingingTimeline.defaultCycleDuration
    public private(set) var trackedBPM: Double?
    private var targetCycleDuration: TimeInterval = SingingTimeline.defaultCycleDuration
    private var candidateStart: TimeInterval?
    private var firstEvidenceTime: TimeInterval?
    private var lastEvidenceTime: TimeInterval = -.infinity
    public static let transitionDuration = SingingTimeline.transitionDuration
    public static let releaseDuration: TimeInterval = 6
    public static let speechReleaseDuration: TimeInterval = 4
    public init() {}
    /// A detector change starts a fresh estimate while preserving body timing.
    public mutating func forgetTempo() {
        trackedBPM = nil; phaseCorrection = 0; lastAccentTime = -.infinity
        alignedAccentTime = -.infinity; accentPhaseErrorSeconds = nil
    }


    public mutating func sample(scene: SoundScene, level: Float, at now: TimeInterval,
                                enabled: Bool = true, beat: BeatEstimate = .unknown, beatDeliveryAge: TimeInterval = 0) -> Int? {
        guard now.isFinite else { return frameIndex }
        if !enabled || now < lastSample {
            self = SingingPerformance(); return nil
        }
        let elapsed = lastSample.isFinite ? max(0, now - lastSample) : 0
        lastSample = now
        // A quiet vocal gap with audible BGM is music, not silence. The analyzer
        // confirms near-zero PCM separately; missing/stale classification is not
        // evidence of silence. Veto a model silence label while sound is audible.
        let silent = scene.kind == .silence && level.isFinite && level < 0.01
        // Speech with BGM is not singing. Require a singing-family model score
        // and actual sound, and don't count repeated UI polls as new evidence.
        let song = !silent && scene.kind != .laughter && scene.ready && scene.singing >= 0.3 && scene.singing > scene.speech * 1.15 && level > 0.008
        if song {
            if candidateStart == nil { candidateStart = now; firstEvidenceTime = scene.audioTime }
            if scene.audioTime > lastEvidenceTime { lastEvidenceTime = scene.audioTime; lastSong = now }
        } else {
            candidateStart = nil; firstEvidenceTime = nil
        }
        if scene.ready && level > 0.008 && (song || scene.music >= 0.3) && scene.audioTime > lastMusicEvidence {
            lastMusicEvidence = scene.audioTime; lastMusic = now
        }
        let speaking = scene.ready && level > 0.008 && scene.speech >= 0.45 && scene.speech > scene.singing * 1.5
        if speaking {
            if speechStart == nil { speechStart = now }
            if scene.audioTime > lastSpeechEvidence { lastSpeechEvidence = scene.audioTime; lastSpeech = now }
        } else { speechStart = nil }
        switch phase {
        case .seated:
            if let start = candidateStart, let evidence = firstEvidenceTime,
               now - start >= 0.8, lastEvidenceTime - evidence >= 0.45, now - lastSong < 1 {
                phase = .rising; phaseStart = now
                trackedBPM = nil
                cycleDuration = SingingTimeline.defaultCycleDuration; targetCycleDuration = cycleDuration
                lastAccentTime = -.infinity; accentVelocity = 0
                phaseCorrection = 0; alignedAccentTime = -.infinity; accentPhaseErrorSeconds = nil
            }
        case .rising:
            if silent {
                // Start the return from the displayed pose, never teleport to
                // full height just to play the complete sitting atlas.
                sittingFromStep = SingingTimeline.risingFrames.firstIndex(of: frameIndex ?? 0) ?? 0
                phase = .sitting; phaseStart = now
            } else if now - phaseStart >= Self.transitionDuration {
                phase = .singing; phaseStart = now; cyclePhase = 0
            }
        case .singing:
            let speechConfirmed = speechStart.map { now - $0 >= Self.speechReleaseDuration && now - lastSpeech < 1 } ?? false
            if silent || now - lastMusic >= Self.releaseDuration || speechConfirmed {
                sittingFromStep = SingingTimeline.risingFrames.count - 1
                phase = .sitting; phaseStart = now
            }
        case .sitting:
            if now - phaseStart >= Double(sittingFromStep + 1) * SingingTimeline.transitionFrameDuration {
                phase = .seated; candidateStart = nil; firstEvidenceTime = nil
            }
        }
        switch phase {
        case .seated: frameIndex = nil
        case .rising, .sitting:
            let frames = SingingTimeline.risingFrames
            let limit = phase == .rising ? frames.count - 1 : sittingFromStep
            let step = min(limit, Int((now - phaseStart) / SingingTimeline.transitionFrameDuration))
            frameIndex = frames[phase == .rising ? step : limit - step]
        case .singing:
            if beat.reliable, let bpm = beat.bpm {
                trackedBPM = bpm
                // Four equal segments: one beat up to 120 BPM, two above. Preserve phase while
                // smoothly converging to the new tempo.
                let range = SingingTimeline.cycleDurationRange
                targetCycleDuration = max(range.lowerBound, min(range.upperBound,
                    SingingTimeline.segmentsPerCycle * SingingTimeline.beatsPerSegment(forBPM: bpm) * 60 / bpm))
                // Phase calibration keeps this nominal BPM-derived period.
                accentVelocity = 0
            }
            let tempoStable = beat.reliable && abs(cycleDuration - targetCycleDuration) < targetCycleDuration * 0.05
            if !tempoStable { phaseCorrection = 0; accentPhaseErrorSeconds = nil }
            // A lost estimate holds the last target, not a slower fallback.
            cycleDuration += (1 - exp(-elapsed / 1.5)) * (targetCycleDuration - cycleDuration)
            accentVelocity *= exp(-elapsed / 0.25)
            if !beat.reliable, let onset = beat.lastAccentTime, onset.isFinite, beat.audioTime.isFinite,
               onset > lastAccentTime, (0...0.12).contains(beat.audioTime - onset) {
                lastAccentTime = onset
                // Only catch nearby arrivals. Never force a fourth accent,
                // jump frames, or turn an off-beat attack into a pose reversal.
                let errors = SingingTimeline.accentPhases.map { arrival -> Double in
                    let difference = arrival - cycleProgress
                    return difference - round(difference)
                }
                if let error = errors.min(by: { abs($0) < abs($1) }), abs(error) <= 0.06 {
                    accentVelocity = max(-0.025, min(0.025, error * 0.8))
                }
            }
            if tempoStable, let onset = beat.lastAccentTime, onset.isFinite,
               beat.audioTime.isFinite, beatDeliveryAge.isFinite, beatDeliveryAge >= 0,
               onset > lastAccentTime {
                lastAccentTime = onset
                let age = beat.audioTime - onset + beatDeliveryAge
                // One-beat subdivisions cannot pull a two-beat gesture back and forth.
                if (0...0.35).contains(age), onset - alignedAccentTime >= cycleDuration * 0.25 * 0.65 {
                    let phaseAtOnset = cyclePhase + (elapsed - age) / cycleDuration
                    var nearest = Double.infinity
                    for arrival in SingingTimeline.keyPosePhases {
                        let distance = arrival - phaseAtOnset
                        let wrapped = distance - round(distance)
                        if abs(wrapped) < abs(nearest) { nearest = wrapped }
                    }
                    // Acquire any initial offset; once aligned, reject halfway subdivisions.
                    if !alignedAccentTime.isFinite || abs(nearest) <= 0.115 {
                        phaseCorrection = nearest
                        alignedAccentTime = onset
                        accentPhaseErrorSeconds = nearest * cycleDuration
                        phaseAlignmentCount += 1
                    }
                }
            }
            let range = SingingTimeline.cycleDurationRange
            let velocity = max(1 / range.upperBound, min(1 / range.lowerBound,
                1 / cycleDuration + accentVelocity))
            if now > phaseStart {
                let budget = elapsed / cycleDuration * 0.10
                let correction = tempoStable ? max(-budget, min(budget, phaseCorrection)) : 0
                cyclePhase += elapsed * velocity + correction
                phaseCorrection -= correction
            }
            frameIndex = SingingTimeline.singingFrame(at: cyclePhase)
        }
        return frameIndex
    }
}
