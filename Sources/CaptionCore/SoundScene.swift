import Foundation

public enum SoundSceneKind: String {
    case warming, unavailable, speech, singing, mixed, music, other, silence, laughter
    public var title: String {
        switch self {
        case .warming: return "正在判断声音类型"
        case .unavailable: return "分类不可用 · 基础检测"
        case .speech: return "讲话"
        case .singing: return "歌声"
        case .mixed: return "人声与音乐"
        case .music: return "音乐 · 暂未检测到人声"
        case .other: return "其他声音"
        case .silence: return "安静"
        case .laughter: return "笑声"
        }
    }
}

/// Model scores are evidence, not calibrated probabilities or source loudness.
public struct SoundScene {
    public let kind: SoundSceneKind
    public let speech: Float
    public let singing: Float
    public let music: Float
    public let laughter: Float
    public let instruments: [String]
    public let audioTime: TimeInterval
    public var vocal: Float { max(speech, singing, kind == .laughter ? laughter : 0) }
    public var ready: Bool { kind != .warming && kind != .unavailable }
    public static let warming = SoundScene(kind: .warming)
    public static let unavailable = SoundScene(kind: .unavailable)

    public init(kind: SoundSceneKind, speech: Float = 0, singing: Float = 0, music: Float = 0, laughter: Float = 0,
                instruments: [String] = [], audioTime: TimeInterval = 0) {
        self.kind = kind; self.speech = speech; self.singing = singing; self.music = music
        self.laughter = laughter.isFinite ? max(0, min(1, laughter)) : 0
        self.instruments = instruments; self.audioTime = audioTime
    }
    public func fresh(at time: TimeInterval) -> SoundScene {
        guard ready else { return self }
        let maximumAge = kind == .laughter ? 0.8 : 2.0
        return time - audioTime > maximumAge || audioTime - time > 0.25 ? .warming : self
    }
}

/// A slower classifier selects context; it never schedules the mouth frames.
public final class SoundSceneTracker {
    /// Verified against SNClassifySoundRequest(.version1).knownClassifications.
    public static let laughterLabels = ["laughter", "belly_laugh", "chuckle_chortle", "giggling", "snicker", "baby_laughter"]
    private var smoothed: [String: Float] = [:]
    private var kind = SoundSceneKind.warming, pending = SoundSceneKind.warming
    private var pendingVotes = 0
    private var lastTime: TimeInterval = -.infinity
    private var instrumentVotes: [String: Int] = [:]
    public init() {}

    public func receive(_ scores: [String: Float], at time: TimeInterval) -> SoundScene? {
        guard time.isFinite, time > lastTime else { return nil }
        lastTime = time
        for key in Set(smoothed.keys).union(scores.keys) {
            let raw = scores[key].flatMap { $0.isFinite ? max(0, min(1, $0)) : nil } ?? 0
            let old = smoothed[key] ?? raw
            let alpha: Float = raw > old ? 0.85 : 0.55
            smoothed[key] = old + alpha * (raw - old)
        }
        func score(_ labels: [String]) -> Float { labels.map { smoothed[$0] ?? 0 }.max() ?? 0 }
        let speech = score(["speech", "whispering", "shout", "yell", "chatter", "babble"])
        let singing = score(["singing", "choir_singing", "yodeling", "rapping", "humming"])
        // Strong laughter gets the first new model result, before other labels.
        // Use raw evidence for priority so smoothed decay cannot prolong a laugh.
        let laughter = Self.laughterLabels.compactMap { scores[$0] }.filter(\.isFinite).map { max(0, min(1, $0)) }.max() ?? 0
        let families: [[(String, [String])]] = [
            [("吉他", ["guitar", "guitar_strum", "guitar_tapping"]), ("电吉他", ["electric_guitar"]), ("木吉他", ["acoustic_guitar"])],
            [("贝斯", ["bass_guitar", "double_bass"])],
            [("键盘", ["keyboard_musical"]), ("钢琴", ["piano", "electric_piano"]), ("合成器", ["synthesizer", "organ", "electronic_organ"])],
            [("鼓与打击乐", ["percussion", "drum_kit", "drum", "snare_drum", "bass_drum", "cymbal", "hi_hat"])],
            [("弦乐", ["bowed_string_instrument", "orchestra"]), ("小提琴", ["violin_fiddle"]), ("大提琴", ["cello"])],
            [("管乐", ["wind_instrument", "brass_instrument", "trumpet", "trombone"]), ("萨克斯", ["saxophone"]), ("长笛", ["flute"])],
            [("弹拨弦乐", ["plucked_string_instrument", "harp", "banjo", "ukulele", "sitar", "zither", "mandolin"])]
        ]
        let ranked = families.compactMap { family in family.map { ($0.0, score($0.1)) }.max { $0.1 < $1.1 } }
            .sorted { $0.1 > $1.1 }
        let music = max(score(["music"]), ranked.first?.1 ?? 0)
        let vocal = max(speech, singing, laughter)
        let candidate: SoundSceneKind
        if laughter >= 0.25 { candidate = .laughter }
        else if score(["silence"]) > 0.65 { candidate = .silence }
        else if singing >= 0.25 && singing > speech * 1.1 { candidate = .singing }
        else if speech >= 0.2 && music >= 0.2 { candidate = .mixed }
        else if vocal >= 0.25 { candidate = .speech }
        else if music >= 0.3 { candidate = .music }
        else { candidate = .other }
        if candidate == pending { pendingVotes += 1 } else { pending = candidate; pendingVotes = 1 }
        if (kind == .warming && candidate != .laughter) || pendingVotes >= 2
            || (candidate != .laughter && vocal > 0.7) || laughter >= 0.4
            || (kind == .laughter && candidate != .laughter) { kind = candidate }
        let present = Set(ranked.filter { $0.1 >= 0.2 }.map(\.0))
        for name in Set(instrumentVotes.keys).union(present) {
            instrumentVotes[name] = present.contains(name) ? min(3, (instrumentVotes[name] ?? 0) + 1) : 0
        }
        let hasGuitar = ranked.contains { ["吉他", "电吉他", "木吉他", "贝斯"].contains($0.0) && $0.1 >= 0.2 }
        let instruments = ranked.filter {
            $0.1 >= 0.2 && (instrumentVotes[$0.0] ?? 0) >= 2 && !($0.0 == "弹拨弦乐" && hasGuitar)
        }.prefix(2).map(\.0)
        return SoundScene(kind: kind, speech: speech, singing: singing, music: music, laughter: laughter,
                          instruments: instruments, audioTime: time)
    }
}

/// Fast attack/release with conservative music veto. A model hint alone never
/// opens a silent mouth, and expired hints never keep suppressing new speech.
struct VoiceActivityGate {
    private var attack = 0, release = 0
    private(set) var isOpen = false
    mutating func update(candidate: Bool, scene: SoundScene) -> Bool {
        let veto = scene.ready && scene.vocal < 0.16 &&
            (scene.music > 0.38 || scene.kind == .other || scene.kind == .silence)
        if candidate && !veto {
            attack += 1; release = 0
            if attack >= (scene.vocal > 0.4 ? 1 : 2) { isOpen = true }
        } else {
            attack = 0; release += 1
            if veto || release >= 4 { isOpen = false }
        }
        return isOpen
    }
}
