import Foundation

/// Stable atlas indices. A pose is held for the sound's duration, never looped.
public enum MouthShape: Int, CaseIterable {
    case rest, closed, ah, eh, ee, oh, oo, fv, tongue, narrow, slight, roundedWide

    public var title: String {
        switch self {
        case .rest: return "自然停顿"
        case .closed: return "双唇闭合"
        case .ah: return "大张口"
        case .eh: return "中等张口"
        case .ee: return "横向展开"
        case .oh: return "中圆口"
        case .oo: return "小撮口"
        case .fv: return "唇齿接触"
        case .tongue: return "舌尖抬起"
        case .narrow: return "窄开露齿"
        case .slight: return "轻微张口"
        case .roundedWide: return "大圆口"
        }
    }
}

public struct LiveLipFrame {
    public let shape: MouthShape
    public let level: Float
    /// A spectral heuristic, not speech recognition or source separation.
    public let voiceLike: Bool
    /// Heuristic score from spectral separation, not a calibrated probability.
    public let confidence: Float
    /// Sample-derived end time of this analysis frame, not a phoneme timestamp.
    public let audioTime: TimeInterval
    public let firstFormant: Float?
    public let secondFormant: Float?
    public var scene: SoundScene
    public let voiceGateOpen: Bool
    public var beat: BeatEstimate = .unknown
    /// Monotonic host time of the last sample used, supplied by capture.
    public var capturedAt: TimeInterval?
    public var analyzedAt: TimeInterval?
    public var captureTimeEstimated = false
    public var usedMFCC = false
    public var mfccConfidence: Float?
    public var separatedVocal = false
    /// Fresh model-confirmed laughter plus recent audible PCM, never a timer loop.
    public var laughterPriority = false
    public static let silence = LiveLipFrame(shape: .rest, level: 0, voiceLike: false,
        confidence: 0, audioTime: 0, firstFormant: nil, secondFormant: nil, scene: .warming, voiceGateOpen: false)
}

/// Bounded latest-result delivery with one unpresented closure. A large audio
/// callback may contain both a closure and its following vowel; preserve that
/// closure briefly, but never replay a queue of old mouth poses.
public struct LiveLipMailbox {
    private var latest = LiveLipFrame.silence
    private var closure: LiveLipFrame?
    private var lastCaptureTime: TimeInterval = -.infinity
    public init() {}

    public mutating func publish(_ frame: LiveLipFrame) {
        guard let time = frame.capturedAt, time.isFinite, time > lastCaptureTime else { return }
        lastCaptureTime = time
        if frame.shape == .closed && latest.shape != .closed { closure = frame }
        latest = frame
        if frame.shape == .rest || frame.laughterPriority { closure = nil }
    }

    public mutating func snapshot(at now: TimeInterval) -> LiveLipFrame {
        guard now.isFinite, let time = latest.capturedAt,
              now - time >= -0.005, now - time <= 0.12 else {
            closure = nil
            return .silence
        }
        if let saved = closure {
            closure = nil
            if let captured = saved.capturedAt, now - captured >= -0.005, now - captured <= 0.06 { return saved }
        }
        return latest
    }
}

/// A bounded visual filter: one active path and one replaceable candidate.
/// Recognition can run at 50 Hz, but every visible pose lasts at least 140 ms.
/// Existing atlas bridges keep one mouth visible; sustained targets never loop.
public struct MouthPosePlayer {
    public private(set) var displayed: MouthShape = .rest
    public var transitionTarget: MouthShape? { transition?.target }
    public var candidateTarget: MouthShape? { candidate?.shape }
    public var isTransitioning: Bool { transition != nil }
    public var laughterPriorityActive: Bool { transition?.laughter == true || (candidate?.laughter == true && candidate?.confirmed == true) }
    public private(set) var transitionsStarted = 0
    public private(set) var staleTargetsDiscarded = 0
    /// Actual audio provenance, including the intentionally delayed active path.
    public private(set) var displayedSourceCapturedAt: TimeInterval?

    public static let minimumPoseDuration: TimeInterval = 0.14
    public static let destinationHoldDuration: TimeInterval = 0.22
    private let maximumAge: TimeInterval = 0.12
    private struct Candidate {
        var shape: MouthShape
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var confirmed: Bool
        var laughter: Bool
    }
    private struct Transition {
        var target: MouthShape
        var path: [MouthShape]
        var index: Int = 0
        var capturedAt: TimeInterval?
        var laughter: Bool
    }
    private var candidate: Candidate?
    private var transition: Transition?
    private var lastObservation: TimeInterval = -.infinity
    private var lastDisplayTime: TimeInterval = -.infinity
    private var changedAt: TimeInterval = -.infinity
    private var reachedAt: TimeInterval = -.infinity
    private var openSince: TimeInterval?
    private var lastOpenObservation: TimeInterval = -.infinity

    public init() {}

    /// Trusted, continuously observed input for previews and timed schedules.
    public mutating func sample(_ target: MouthShape, at time: TimeInterval) -> MouthShape {
        sample(target, observedAt: time, confidence: 1, at: time)
    }

    public mutating func sample(_ frame: LiveLipFrame, at time: TimeInterval) -> MouthShape {
        guard let captured = frame.capturedAt else { return expire(at: time) }
        return sample(frame.shape, observedAt: captured, confidence: frame.confidence,
                      laughterPriority: frame.laughterPriority, at: time)
    }

    public mutating func sample(_ target: MouthShape, observedAt captured: TimeInterval,
                                confidence: Float, laughterPriority: Bool = false, at time: TimeInterval) -> MouthShape {
        guard time.isFinite, time >= lastDisplayTime else { return displayed }
        lastDisplayTime = time
        if captured.isFinite, time - captured >= -0.005, time - captured <= maximumAge,
           captured > lastObservation {
            lastObservation = captured
            observe(target, captured: captured, confidence: confidence, laughter: laughterPriority, at: time)
        }
        guard time - lastObservation <= maximumAge else { return expire(at: time) }
        return advance(at: time)
    }

    private mutating func observe(_ shape: MouthShape, captured: TimeInterval,
                                  confidence: Float, laughter: Bool, at time: TimeInterval) {
        let score = confidence.isFinite ? max(0, min(1, confidence)) : 0
        if shape != .rest && shape != .closed {
            if openSince == nil || captured - lastOpenObservation > 0.06 { openSince = captured }
            lastOpenObservation = captured
        } else { openSince = nil }
        if candidate?.shape == shape && candidate?.laughter == laughter {
            if captured - candidate!.lastSeen > 0.06 {
                candidate!.firstSeen = captured; candidate!.confirmed = false
            }
            candidate!.lastSeen = captured
        } else {
            candidate = Candidate(shape: shape, firstSeen: captured, lastSeen: captured, confirmed: false, laughter: laughter)
        }
        // Even a strong classification needs independent fresh observations.
        // Brief closures/dropouts cannot chop a held vowel into repeated syllables.
        let confirmation: TimeInterval = laughter ? 0.04 : shape == .rest || shape == .closed ? 0.06 : score >= 0.6 ? 0.08 : 0.12
        if captured - candidate!.firstSeen + 1e-9 >= confirmation { candidate!.confirmed = true }
        if transition?.target == shape { transition!.capturedAt = captured }
        if displayed == shape && transition == nil { displayedSourceCapturedAt = captured }
        if displayed == .slight && transition == nil && !candidate!.confirmed && openSince != nil {
            displayedSourceCapturedAt = captured
        }
        if candidate!.confirmed && (shape == .rest || shape == .closed), transition?.target != shape {
            // Confirmed silence cancels opening, then closes from the visible pose.
            transition = nil
            begin(shape, capturedAt: captured, at: time)
        } else if candidate!.confirmed && laughter && transition?.laughter != true {
            // Laughter discards the ordinary candidate/path and starts from the
            // actually visible mouth. The 140 ms pose floor still applies.
            transition = nil
            begin(shape, capturedAt: captured, laughter: true, at: time)
        }
    }

    private mutating func advance(at time: TimeInterval) -> MouthShape {
        if let pending = candidate, time - pending.lastSeen > maximumAge {
            staleTargetsDiscarded += 1; candidate = nil
        }
        if var active = transition {
            guard time - changedAt + 1e-9 >= Self.minimumPoseDuration else { return displayed }
            // Advance once per display tick; missed UI ticks never cause a burst
            // of catch-up poses. The latest candidate replaces all earlier ones.
            let next = active.index < active.path.count ? active.path[active.index] : active.target
            active.index += 1
            show(next, capturedAt: active.capturedAt, at: time)
            if next == active.target {
                transition = nil; reachedAt = time
            } else { transition = active }
            return displayed
        }
        if let next = candidate, next.confirmed, next.shape != displayed,
           (next.laughter || time - reachedAt + 1e-9 >= Self.destinationHoldDuration) {
            begin(next.shape, capturedAt: next.lastSeen, laughter: next.laughter, at: time)
        } else if displayed == .rest, let since = openSince,
                  lastOpenObservation - since + 1e-9 >= 0.08,
                  time - reachedAt + 1e-9 >= Self.destinationHoldDuration {
            // Rapid speech can contain no stable vowel at all. Show one small
            // opening after sustained voice, then wait for a reliable family.
            begin(.slight, capturedAt: lastOpenObservation, at: time)
        }
        return displayed
    }

    private mutating func begin(_ target: MouthShape, capturedAt: TimeInterval?, laughter: Bool = false, at time: TimeInterval) {
        guard target != displayed else { return }
        // Closing uses one small opening, avoiding extra syllables on release.
        let route = target == .rest || target == .closed
            ? (displayed == .slight || displayed == .closed ? [] : [.slight])
            : Self.path(from: displayed, to: target).filter { $0 != displayed }
        transition = Transition(target: target, path: route, capturedAt: capturedAt, laughter: laughter)
        transitionsStarted += 1
        _ = advance(at: time)
    }

    private mutating func show(_ shape: MouthShape, capturedAt: TimeInterval?, at time: TimeInterval) {
        if shape != displayed { displayed = shape; changedAt = time }
        displayedSourceCapturedAt = capturedAt
    }

    private mutating func expire(at time: TimeInterval) -> MouthShape {
        guard time.isFinite, time >= lastDisplayTime else { return displayed }
        lastDisplayTime = time
        if candidate != nil { staleTargetsDiscarded += 1; candidate = nil }
        openSince = nil; lastOpenObservation = -.infinity
        if transition?.target != .rest {
            if transition != nil { staleTargetsDiscarded += 1 }
            transition = nil
            begin(.rest, capturedAt: nil, at: time)
        } else { _ = advance(at: time) }
        if displayed == .rest { displayedSourceCapturedAt = nil }
        return displayed
    }

    /// Semantic bridges made from existing, single-mouth artwork. Intermediate
    /// frames are motion aids and do not claim the intervening phoneme occurred.
    public static func path(from: MouthShape, to: MouthShape) -> [MouthShape] {
        let wide: Set<MouthShape> = [.ah, .roundedWide]
        let spread: Set<MouthShape> = [.ee, .narrow, .fv, .tongue]
        let rounded: Set<MouthShape> = [.oh, .oo, .roundedWide]
        var route: [MouthShape]
        if to == .rest && [.closed, .slight].contains(from) { route = [from] }
        else if to == .rest { route = wide.contains(from) ? [.eh, .slight] : [.slight] }
        else if [.rest, .closed].contains(from) && wide.contains(to) { route = [.slight, .eh] }
        else if [.rest, .closed].contains(from) && rounded.contains(to) { route = [.slight, .oh] }
        else if [.rest, .closed].contains(from) && spread.contains(to) { route = [.slight, .narrow] }
        else if from == .ah && to == .oo { route = [.eh, .oh] }
        else if from == .ah && rounded.contains(to) { route = [.eh] }
        else if from == .roundedWide && to == .oo { route = [.oh] }
        else if from == .oo && wide.contains(to) { route = [.oh, .eh] }
        else if spread.contains(from) && rounded.contains(to) { route = [.slight, .oh] }
        else if rounded.contains(from) && spread.contains(to) { route = [.slight, .narrow] }
        else if wide.contains(from) && spread.contains(to) { route = [.eh, .narrow] }
        else if spread.contains(from) && wide.contains(to) { route = [.eh] }
        else { route = [from] }
        route = route.filter { $0 != from && $0 != to }
        return route.isEmpty ? [from] : route
    }
}
