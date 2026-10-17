import Foundation

/// Raw, unamplified PCM evidence; classification and the mouth sensitivity must
/// not turn quiet music into silence. Short gaps do not unload models.
public struct AudioRecognitionActivity {
    public private(set) var active = false
    private var quietSeconds = 0.0
    public init() {}
    @discardableResult
    public mutating func receive(peak: Float, frames: Int, sampleRate: Double) -> Bool {
        guard frames > 0, sampleRate.isFinite, sampleRate > 0, peak.isFinite, peak >= 0 else { return active }
        if peak > 0.00001 { active = true; quietSeconds = 0 }
        else {
            quietSeconds += Double(frames) / sampleRate
            if quietSeconds >= 0.2 { active = false }
        }
        return active
    }
}

/// A confirmed keyword remains visible briefly even if ASR revises the text or
/// pure silence immediately stops the model after the phrase.
public struct SpeechKeywordHighlight {
    public private(set) var keyword: JapaneseKiraKeyword?
    private var until: [JapaneseKiraKeyword: Double] = [:]
    public var keywords: Set<JapaneseKiraKeyword> { Set(until.keys) }
    public init() {}
    public mutating func receive(_ keyword: JapaneseKiraKeyword, at now: Double) {
        guard now.isFinite else { return }
        self.keyword = keyword; until[keyword] = now + 4
    }
    public mutating func expire(at now: Double) {
        until = until.filter { now < $0.value }
        if let keyword, until[keyword] == nil { self.keyword = until.max(by: { $0.value < $1.value })?.key }
    }
}
