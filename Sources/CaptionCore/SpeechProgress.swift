import Foundation

/// Timing is estimated by ASR. A gap after the last recognized word is not
/// evidence that the engine is still processing that gap (it may have missed it).
public struct SpeechProgress: Equatable {
    public var requestNumber = 0
    public var requestReason = ""
    public var streamStartedAt: Double?
    public var inputEnd: Double?
    public var audibleEnd: Double?
    public var resultReceivedAt: Double?
    public var textChangedAt: Double?
    public var resultRequestNumber = 0
    public var resultCount = 0
    public var textChangeCount = 0
    public var isFinal = false
    public var wordEnd: Double?
    public var wordToResultDelay: Double?
    public init() {}

    public mutating func receive(words: [SpeechWord], origin: Double, at now: Double,
                                 isFinal: Bool, textChanged: Bool) {
        resultReceivedAt = now; resultRequestNumber = requestNumber
        resultCount += 1; self.isFinal = isFinal
        if textChanged { textChangedAt = now; textChangeCount += 1 }
        wordEnd = nil; wordToResultDelay = nil
        // Do not substitute an earlier word when the newest word has no timing.
        guard isFinal, let last = words.last, origin.isFinite, now.isFinite,
              last.timestamp.isFinite, last.timestamp >= 0,
              last.duration.isFinite, last.duration > 0, let inputEnd else { return }
        let end = origin + last.timestamp + last.duration
        guard end.isFinite, end <= inputEnd + 0.2, end <= now + 0.2 else { return }
        wordEnd = end; wordToResultDelay = max(0, now - end)
    }

    public func inputLabel(at now: Double) -> String {
        guard let inputEnd, let streamStartedAt else { return "音频输入：尚未收到 PCM" }
        let age = max(0, now - inputEnd)
        return String(format: "音频已送入 %.1f 秒 · %.1f 秒前%@", max(0, inputEnd - streamStartedAt), age,
                      age > 2 ? "（输入已停）" : (audibleEnd.map { now - $0 < 2 } == true ? "（有声）" : "（静音）"))
    }

    public func resultLabel(at now: Double) -> String {
        guard let resultReceivedAt else { return "尚无识别结果" }
        let phase = resultRequestNumber != requestNumber ? "上一段结果" : (isFinal ? "本轮定稿" : "临时结果，可能改写")
        return String(format: "%@ · %.1f 秒前返回 · 文字 %.1f 秒未变化", phase,
                      max(0, now - resultReceivedAt), max(0, now - (textChangedAt ?? resultReceivedAt)))
    }

    public var timingLabel: String {
        guard resultReceivedAt != nil else { return "等待词时间，暂不能估计识别延迟" }
        guard isFinal else { return "临时词时间尚未定稿 · 延迟未知" }
        guard let wordToResultDelay, let wordEnd, let streamStartedAt else {
            return "Apple 未提供有效词时间 · 延迟未知"
        }
        return String(format: "末词位于输入 %.1f 秒 · 词末→返回约 %.2f 秒%@",
                      max(0, wordEnd - streamStartedAt), wordToResultDelay, isFinal ? "" : "（临时估计）")
    }
}
