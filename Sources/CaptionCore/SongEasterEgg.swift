import Foundation

/// Title evidence identifies a candidate composition, never an acoustic match.
public enum SeikanHikou {
    public static func matches(title: String) -> Bool {
        let folded = title.folding(options: [.widthInsensitive, .diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "間", with: "间").replacingOccurrences(of: "飛", with: "飞")
        let compact = folded.filter { !$0.isWhitespace && !$0.isPunctuation }
        if compact.contains("星间飞行") { return true }
        return folded.range(of: #"(?<![a-z])seikan[\s_\-]*hiko(?:u|h)?(?![a-z])"#, options: .regularExpression) != nil
    }
}

public struct NowPlayingTrack: Codable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var player: String
    public var contentID: String
    public var duration: Double?
    public var elapsed: Double?
    public var rate: Double?
    public var observedAt: TimeInterval
    public init(title: String, artist: String = "", album: String = "", player: String = "", contentID: String = "",
                duration: Double? = nil, elapsed: Double? = nil, rate: Double? = nil, observedAt: TimeInterval) {
        self.title = title; self.artist = artist; self.album = album; self.player = player; self.contentID = contentID
        self.duration = duration; self.elapsed = elapsed; self.rate = rate; self.observedAt = observedAt
    }
    public var candidate: Bool { SeikanHikou.matches(title: title) }
    public func fresh(at now: TimeInterval) -> Bool { now.isFinite && (0...4).contains(now - observedAt) }
    public func position(at now: TimeInterval) -> Double? {
        guard fresh(at: now), let elapsed, elapsed.isFinite, elapsed >= 0,
              let rate, rate.isFinite, (0...4).contains(rate) else { return nil }
        let value = elapsed + (now - observedAt) * rate
        return duration.flatMap { $0.isFinite && $0 > 0 ? min(value, $0) : nil } ?? value
    }
    /// Persist markers only against complete recording metadata, never a song alias.
    /// A player reusing identical metadata for distinct recordings remains ambiguous.
    public var recordingKey: String? {
        guard candidate, !player.isEmpty, let duration, duration.isFinite, duration > 0,
              !artist.isEmpty || !contentID.isEmpty else { return nil }
        let fields = [player, contentID, title, artist, album, String(format: "%.1f", duration)]
        return (try? JSONEncoder().encode(fields)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

public enum KiraTimeline {
    public static let frames = [24, 25, 26, 27, 28, 29, 30, 31, 24]
    public static let durations = [0.08, 0.10, 0.12, 0.12, 0.20, 0.48, 0.14, 0.14, 0.12]
    public static let accentOffset: TimeInterval = 0.42
    public static let duration = durations.reduce(0, +)
    public static func frame(at elapsed: TimeInterval) -> Int? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        var end = 0.0
        for (frame, hold) in zip(frames, durations) {
            end += hold
            if elapsed < end { return frame }
        }
        return nil
    }
}

/// Advances only on fresh, continuous, playing metadata. Never fires a cue
/// merely because a seek, reconnect, or first observation landed after it.
public struct KiraCueScheduler {
    private var previous: (key: String, position: Double, uptime: Double, rate: Double)?
    private var fired: Set<Int> = []
    public init() {}
    public mutating func sample(track: NowPlayingTrack?, cues: [Double], at now: TimeInterval) -> Bool {
        guard let track, track.candidate, let key = track.recordingKey,
              let position = track.position(at: now), let rate = track.rate, rate > 0 else {
            previous = nil; return false
        }
        defer { previous = (key, position, now, rate) }
        guard let old = previous, old.key == key else { fired.removeAll(); return false }
        let interval = now - old.uptime
        let advance = position - old.position
        let discontinuous = interval < 0 || interval > 1 || abs(advance - interval * old.rate) > 0.6
        if discontinuous {
            // Only cues ahead of the new position may be re-armed after rewind.
            fired = Set(cues.indices.filter { cues[$0] - KiraTimeline.accentOffset * rate <= position })
            return false
        }
        // Reconcile a minor backwards clock correction without double-firing.
        guard advance >= 0 else { return false }
        for (index, cue) in cues.enumerated() where cue.isFinite && cue >= 0 && !fired.contains(index) {
            let start = cue - KiraTimeline.accentOffset * rate
            if old.position < start && position >= start {
                fired.insert(index); return true
            }
        }
        return false
    }
}
