import Foundation
import CaptionCore

enum SpeechKeywordChecks {
    static func run() {
        for text in ["構わない", "かまわない", "カマワナイ", "ｶﾏﾜﾅｲ", "構わ無い", "かまわ 無い", "構わ、ない"] {
            precondition(JapaneseKiraKeyword.normalize(text).contains("かまわない"), text)
        }
        for text in ["構わなくても", "かまない", "かわらない", "", "キラッ"] {
            precondition(!JapaneseKiraKeyword.normalize(text).contains("かまわない"), text)
        }
        for text in ["手の甲に", "てのこうに", "テノコウニ", "ﾃﾉｺｳﾆ", "手のこうに", "ての甲に", "手ノ甲ニ", "手の 甲、に"] {
            precondition(JapaneseKiraKeyword.occurrenceCount(in: text, keyword: .tenokouni) == 1, text)
        }
        for text in ["手の甲", "手の甲が", "手のひらに", "構わない", "てのこう", ""] {
            precondition(JapaneseKiraKeyword.occurrenceCount(in: text, keyword: .tenokouni) == 0, text)
        }
        let handWords = [SpeechWord("手の", timestamp: 0, duration: 0),
                         SpeechWord("甲", timestamp: 1, duration: 0.5), SpeechWord("に", timestamp: 1.5, duration: 0.2)]
        precondition(JapaneseKiraKeyword.endpoint(in: handWords, keyword: .tenokouni) == 1.7)
        var bothSpotters = JapaneseKiraKeyword.allCases.map { SpeechKeywordSpotter(keyword: $0) }
        func matchBoth(_ text: String, at now: Double) -> [SpeechKeywordMatch] {
            bothSpotters.indices.compactMap { index in
                bothSpotters[index].receive(text: text, words: [], requestNumber: 1, origin: 0, inputEnd: now, at: now)
            }
        }
        precondition(matchBoth("それでも構わない", at: 10).map(\.keyword) == [.kamawanai])
        precondition(matchBoth("それでも構わない。手の甲", at: 10.5).isEmpty)
        precondition(matchBoth("それでも構わない。手の甲に触れました", at: 11).map(\.keyword) == [.tenokouni],
                     "One keyword's cooldown must not suppress the other keyword")
        precondition(matchBoth("それでも構わない。てのこうに触れました", at: 12).isEmpty,
                     "Changing kanji to kana must not replay either keyword")
        precondition(matchBoth("それでも構わない。手の甲に触れました", at: 25).isEmpty)
        precondition(matchBoth("それでも構わない。手の甲に触れました。また手の甲に", at: 26).map(\.keyword) == [.tenokouni])
        var together = JapaneseKiraKeyword.allCases.map { SpeechKeywordSpotter(keyword: $0) }
        let simultaneous = together.indices.compactMap { index in
            together[index].receive(text: "構わない。手の甲に", words: [], requestNumber: 1, origin: 0, inputEnd: 2, at: 2)
        }
        precondition(simultaneous.map(\.keyword) == [.kamawanai, .tenokouni], "Both phrases in one callback must be reported")
        print("PASS: both keyword forms, complete phrase matching, split hand phrase, independent cooldown and per-phrase deduplication")
        let words = [SpeechWord("涙", timestamp: 0, duration: 1), SpeechWord("構わ", timestamp: 1, duration: 0.8), SpeechWord("ない", timestamp: 1.8, duration: 0.4)]
        precondition(abs(JapaneseKiraKeyword.endpoint(in: words)! - 2.2) < 0.001)
        precondition(JapaneseKiraKeyword.endpoint(in: [SpeechWord("構わない", timestamp: 0, duration: 0)]) == nil)
        precondition(JapaneseKiraKeyword.endpoint(in: [SpeechWord("構わない", timestamp: .nan, duration: 1)]) == nil)
        let sentence = "劇だって構わないあなたと生きたい嫌われるにまたあなたに行"
        precondition(JapaneseKiraKeyword.occurrenceCount(in: sentence) == 1)
        var spotter = SpeechKeywordSpotter()
        let untimed = [SpeechWord(sentence, timestamp: 0, duration: 0)]
        let first = spotter.receive(text: sentence, words: untimed, requestNumber: 1, origin: 0, inputEnd: 10, at: 10.4)
        precondition(first != nil && first?.endpoint == nil, "A keyword inside an untimed partial sentence must trigger")
        precondition(spotter.receive(text: sentence, words: untimed, requestNumber: 1, origin: 0, inputEnd: 11, at: 11) == nil)
        precondition(spotter.receive(text: "構わなくて", words: [], requestNumber: 1, origin: 0, inputEnd: 12, at: 12) == nil)
        precondition(spotter.receive(text: sentence, words: untimed, requestNumber: 1, origin: 0, inputEnd: 25, at: 25) == nil,
                     "A partial rewrite removing/readding the phrase must not replay even after cooldown")
        precondition(spotter.receive(text: sentence, words: untimed, requestNumber: 2, origin: 9, inputEnd: 15, at: 15) == nil,
                     "Overlapping request must not replay an arrival-time match")
        let chorus = spotter.receive(text: "構わない", words: [SpeechWord("構わない", timestamp: 10, duration: 1)],
                                    requestNumber: 3, origin: 69, inputEnd: 80, at: 80.3, timingIsFinal: true)
        precondition(chorus?.endpoint == 80, "A later chorus can trigger with the audio timestamp")
        precondition(spotter.receive(text: "構わない", words: [SpeechWord("構わない", timestamp: 0, duration: 1)],
                                    requestNumber: 4, origin: 79, inputEnd: 90, at: 90, timingIsFinal: true) == nil,
                     "A delayed duplicate across requests must still be suppressed")
        let late = spotter.receive(text: "構わない", words: [SpeechWord("構わない", timestamp: 0, duration: 1)],
                                   requestNumber: 5, origin: 99, inputEnd: 110, at: 110, timingIsFinal: true)
        precondition(late?.endpoint == 100, "Old but valid timing must remain old for the late-result warning")
        var fallback = SpeechKeywordSpotter()
        let invalidFuture = fallback.receive(text: "構わない", words: [SpeechWord("構わない", timestamp: 200, duration: 1)],
                                             requestNumber: 1, origin: 0, inputEnd: 5, at: 5, timingIsFinal: true)
        precondition(invalidFuture != nil && invalidFuture?.endpoint == nil)
        var interim = SpeechKeywordSpotter()
        let provisional = interim.receive(text: "構わない", words: [SpeechWord("構わない", timestamp: 0.001, duration: 0.011)],
                                          requestNumber: 1, origin: 0, inputEnd: 10, at: 10)
        precondition(provisional != nil && provisional?.endpoint == nil,
                     "Nonzero provisional timestamps must not suppress a live text hit as too late")
        precondition(interim.receive(text: "構わない", words: [SpeechWord("構わない", timestamp: 9, duration: 0.5)],
                                    requestNumber: 1, origin: 0, inputEnd: 12, at: 12, timingIsFinal: true) == nil,
                     "Final timing must not replay a phrase already triggered from a partial")
        var fullTextOnly = SpeechKeywordSpotter()
        precondition(fullTextOnly.receive(text: sentence, words: [], requestNumber: 1, origin: 0, inputEnd: 5, at: 5) != nil)
        let mixed = [SpeechWord("構わ", timestamp: 0, duration: 0), SpeechWord("ない", timestamp: 1, duration: 0.3)]
        precondition(JapaneseKiraKeyword.endpoint(in: mixed) == 1.3, "Missing timing in an earlier segment must not discard its text")
        var countdown = SpeechKiraCountdown()
        precondition(countdown.arm(endpoint: 10, receivedAt: 10.6, delay: 3))
        precondition(abs(countdown.remaining(at: 11)! - 2) < 0.001)
        precondition(!countdown.arm(endpoint: 10.2, receivedAt: 11, delay: 3))
        precondition(countdown.takeStart(at: 12.5) == nil)
        precondition(abs(countdown.takeStart(at: 12.59)! - 12.58) < 0.001)
        precondition(countdown.takeStart(at: 12.6) == nil)
        precondition(!countdown.arm(endpoint: 10, receivedAt: 14, delay: 3), "Late ASR must not start a new full countdown")
        precondition(!countdown.arm(endpoint: late!.endpoint!, receivedAt: late!.receivedAt, delay: 3))
        precondition(countdown.arm(endpoint: first!.endpoint ?? first!.receivedAt, receivedAt: first!.receivedAt, delay: 3))
        precondition(abs(countdown.target! - 13.4) < 0.001, "Untimed text uses an explicitly labeled arrival-time countdown")
        countdown.cancel()
        precondition(countdown.arm(endpoint: 20, receivedAt: 20.2, delay: 3))
        countdown.cancel(); precondition(countdown.takeStart(at: 23) == nil)
        precondition(countdown.arm(endpoint: 30, receivedAt: 30.2, delay: 3))
        precondition(countdown.takeStart(at: 35) == nil && countdown.target == nil, "After UI sleep, skip overdue gesture")
        print("PASS: Japanese forms, split segments, invalid timestamps, partial deduplication, delayed ASR compensation, cancel and overdue suppression")
        var progress = SpeechProgress()
        precondition(progress.inputLabel(at: 100).contains("尚未收到 PCM"))
        progress.requestNumber = 1; progress.streamStartedAt = 100; progress.inputEnd = 104
        progress.receive(words: [SpeechWord("見つめ合う", timestamp: 2, duration: 1)], origin: 100,
                         at: 104, isFinal: true, textChanged: true)
        precondition(progress.wordToResultDelay == 1 && progress.textChangedAt == 104)
        progress.receive(words: [SpeechWord("見つめ合う", timestamp: 2, duration: 1)], origin: 100,
                         at: 106, isFinal: true, textChanged: false)
        precondition(progress.resultReceivedAt == 106 && progress.textChangedAt == 104)
        precondition(progress.resultLabel(at: 107).contains("文字 3.0 秒未变化"))
        progress.receive(words: [SpeechWord("見つめ合う", timestamp: 2, duration: 1),
                                 SpeechWord("して", timestamp: 0, duration: 0)], origin: 100,
                         at: 107, isFinal: false, textChanged: true)
        precondition(progress.wordToResultDelay == nil && progress.wordEnd == nil,
                     "Unknown latest word timing must not reuse an older word")
        precondition(progress.timingLabel.contains("延迟未知"))
        progress.receive(words: [SpeechWord("して", timestamp: 20, duration: 1)], origin: 100,
                         at: 107, isFinal: false, textChanged: false)
        precondition(progress.wordToResultDelay == nil, "Reject timing beyond submitted audio")
        progress.receive(words: [SpeechWord("構わない", timestamp: 0.001, duration: 0.011)], origin: 100,
                         at: 107, isFinal: false, textChanged: true)
        precondition(progress.wordToResultDelay == nil && progress.timingLabel.contains("尚未定稿"),
                     "Provisional times must not be shown as measured recognition lag")
        progress.requestNumber = 2; progress.inputEnd = 145
        progress.receive(words: [SpeechWord("構わない", timestamp: 1, duration: 1)], origin: 142,
                         at: 145, isFinal: true, textChanged: true)
        precondition(progress.wordEnd == 144 && progress.wordToResultDelay == 1)
        precondition(progress.timingLabel.contains("44.0 秒") && progress.resultLabel(at: 145).contains("定稿"))
        progress.requestNumber = 3
        precondition(progress.resultLabel(at: 146).contains("上一段结果"))
        precondition(progress.inputLabel(at: 150).contains("输入已停"))
        print("PASS: ASR partial/final timing, no-timestamp state, unchanged-text age, request rollover and input stall")
    }
}
