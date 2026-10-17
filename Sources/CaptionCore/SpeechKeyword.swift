import Foundation

public struct SpeechWord: Equatable {
    public let text: String
    public let timestamp: Double
    public let duration: Double
    public init(_ text: String, timestamp: Double, duration: Double) {
        self.text = text; self.timestamp = timestamp; self.duration = duration
    }
}

/// The timestamps refer to the audio sent to one recognition request.
/// A segment endpoint is an ASR estimate, not a measured phoneme/VAD boundary.
public enum JapaneseKiraKeyword: String, CaseIterable {
    case kamawanai = "構わない"
    case tenokouni = "手の甲に"
    case higekidatte = "悲劇だって"
    case nikurashikute = "憎らしくて"

    public var isBackup: Bool { self == .higekidatte || self == .nikurashikute }
    public var cueGroup: Int { self == .kamawanai || self == .higekidatte ? 0 : 1 }
    public func countdownDelay(primary: Double, backupExtra: Double) -> Double {
        primary + (isBackup ? backupExtra : 0)
    }

    public var reading: String {
        switch self {
        case .kamawanai: return "かまわない"
        case .tenokouni: return "てのこうに"
        case .higekidatte: return "ひげきだって"
        case .nikurashikute: return "にくらしくて"
        }
    }
    public static var displayList: String { allCases.map(\.rawValue).joined(separator: " / ") }

    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.widthInsensitive], locale: Locale(identifier: "ja_JP"))
        let kana = folded.applyingTransform(.hiraganaToKatakana, reverse: true) ?? folded
        return kana.filter { !$0.isWhitespace && !$0.isPunctuation }
            .replacingOccurrences(of: "構わ無い", with: "かまわない")
            .replacingOccurrences(of: "構わない", with: "かまわない")
            .replacingOccurrences(of: "かまわ無い", with: "かまわない")
            .replacingOccurrences(of: "手の甲", with: "てのこう")
            .replacingOccurrences(of: "手のこう", with: "てのこう")
            .replacingOccurrences(of: "ての甲", with: "てのこう")
            .replacingOccurrences(of: "悲劇", with: "ひげき")
            .replacingOccurrences(of: "憎らしくて", with: "にくらしくて")
    }
    public static func occurrenceCount(in text: String, keyword: Self = .kamawanai) -> Int {
        normalize(text).components(separatedBy: keyword.reading).count - 1
    }
    public static func endpoints(in words: [SpeechWord], keyword: Self = .kamawanai) -> [Double?] {
        var combined = "", endTimes: [Double?] = []
        // Normalize across segment boundaries too: 「構わ」「ない」.
        // Interim segments can contain real text with no timing. Keep the text.
        for word in words {
            combined += word.text
            let count = occurrenceCount(in: combined, keyword: keyword)
            let end = word.timestamp + word.duration
            let valid = word.timestamp.isFinite && word.timestamp >= 0 && word.duration.isFinite && word.duration > 0 && end.isFinite
            while endTimes.count < count { endTimes.append(valid ? end : nil) }
        }
        return endTimes
    }
    public static func endpoint(in words: [SpeechWord], keyword: Self = .kamawanai) -> Double? {
        endpoints(in: words, keyword: keyword).last ?? nil
    }
}

public struct SpeechKeywordMatch: Equatable {
    public let keyword: JapaneseKiraKeyword
    /// Nil means the keyword was found in text, but Apple supplied no usable timing.
    public let endpoint: Double?
    public let receivedAt: Double
}

/// Consume each textual occurrence once, including partial revisions without
/// timestamps. A short cooldown also covers the overlapping request rollover.
public struct SpeechKeywordSpotter {
    public let keyword: JapaneseKiraKeyword
    private var requestNumber: Int?
    private var consumedCount = 0
    private var lastReceived: Double = -.infinity
    private var lastEndpoint: Double = -.infinity
    public init(keyword: JapaneseKiraKeyword = .kamawanai) { self.keyword = keyword }
    public mutating func receive(text: String, words: [SpeechWord], requestNumber: Int,
                                 origin: Double, inputEnd: Double, at now: Double,
                                 timingIsFinal: Bool = false) -> SpeechKeywordMatch? {
        guard origin.isFinite, inputEnd.isFinite, now.isFinite else { return nil }
        if self.requestNumber != requestNumber {
            self.requestNumber = requestNumber; consumedCount = 0
        }
        let count = JapaneseKiraKeyword.occurrenceCount(in: text, keyword: keyword)
        guard count > consumedCount else { return nil }
        consumedCount = count
        guard now - lastReceived >= 8 else { return nil }
        let ends = JapaneseKiraKeyword.endpoints(in: words, keyword: keyword)
        var endpoint: Double?
        // In live ja-JP tests, even nonzero interim times preceded the spoken
        // audio by seconds. Do not interpret these provisional values as latency.
        if timingIsFinal, ends.count == count, let relative = ends.last ?? nil {
            let absolute = origin + relative
            if absolute.isFinite, absolute <= inputEnd + 0.2, absolute <= now + 0.2 {
                endpoint = absolute
            }
        }
        if let endpoint {
            guard endpoint - lastEndpoint >= 8 else { return nil }
            lastEndpoint = endpoint
        }
        lastReceived = now
        // Retain old valid timestamps: the scheduler must report late recognition,
        // not disguise a late result as a fresh arrival-time countdown.
        return SpeechKeywordMatch(keyword: keyword, endpoint: endpoint, receivedAt: now)
    }
}

public struct SpeechKiraCountdown {
    public private(set) var target: Double?
    public private(set) var lastLatency: Double?
    public init() {}
    @discardableResult
    public mutating func arm(endpoint: Double, receivedAt: Double, delay: Double) -> Bool {
        guard endpoint.isFinite, receivedAt.isFinite, delay.isFinite,
              (-0.2...8).contains(receivedAt - endpoint), (0.5...14).contains(delay), target == nil,
              endpoint + delay - KiraTimeline.accentOffset >= receivedAt - 0.2 else { return false }
        target = endpoint + delay; lastLatency = max(0, receivedAt - endpoint)
        return true
    }
    public mutating func cancel() { target = nil }
    public func remaining(at now: Double) -> Double? { target.map { max(0, $0 - now) } }
    /// Returns the intended animation start, allowing one late UI frame to catch up.
    public mutating func takeStart(at now: Double) -> Double? {
        guard let target, now.isFinite, now >= target - KiraTimeline.accentOffset else { return nil }
        self.target = nil
        let start = target - KiraTimeline.accentOffset
        return now - start <= 0.25 ? start : nil
    }
}

/// Both phrases for one cue, and multiple ASR backends, represent one action.
/// Only record an armed countdown: a rejected late backup must not block a primary.
public struct SpeechCueDeduplicator {
    private var last: [Int: Double] = [:]
    public init() {}
    public func allows(_ keyword: JapaneseKiraKeyword, at now: Double, cooldown: Double) -> Bool {
        now.isFinite && cooldown.isFinite && now - (last[keyword.cueGroup] ?? -.infinity) >= cooldown
    }
    public mutating func record(_ keyword: JapaneseKiraKeyword, at now: Double) { last[keyword.cueGroup] = now }
}
