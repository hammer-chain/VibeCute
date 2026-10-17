import Foundation
import CaptionCore

enum AudioRecognitionChecks {
    static func run() {
        for rate in [16_000.0, 44_100, 48_000, 96_000, 192_000] {
            var gate = AudioRecognitionActivity()
            let frames = Int(rate / 100)
            precondition(!gate.receive(peak: 0, frames: frames, sampleRate: rate))
            precondition(gate.receive(peak: 0.00002, frames: frames, sampleRate: rate), "Quiet real audio must wake models")
            for _ in 0..<19 { precondition(gate.receive(peak: 0, frames: frames, sampleRate: rate)) }
            precondition(gate.receive(peak: 0.00002, frames: frames, sampleRate: rate), "A brief pause must not reload models")
            for _ in 0..<19 { precondition(gate.receive(peak: 0.000001, frames: frames, sampleRate: rate)) }
            precondition(!gate.receive(peak: 0.000001, frames: frames, sampleRate: rate))
            precondition(gate.receive(peak: 0.1, frames: frames, sampleRate: rate))
            precondition(gate.receive(peak: .nan, frames: frames, sampleRate: rate), "Invalid evidence cannot establish silence")
        }
        var highlight = SpeechKeywordHighlight()
        highlight.receive(.kamawanai, at: 10)
        highlight.expire(at: 13.99); precondition(highlight.keyword == .kamawanai)
        highlight.receive(.tenokouni, at: 14)
        highlight.expire(at: 17.99); precondition(highlight.keyword == .tenokouni)
        highlight.expire(at: 18); precondition(highlight.keyword == nil)
        highlight.receive(.higekidatte, at: 20); highlight.receive(.kamawanai, at: 21)
        precondition(highlight.keywords == [.higekidatte, .kamawanai])
        highlight.expire(at: 24); precondition(highlight.keywords == [.kamawanai])
        highlight.expire(at: 25); precondition(highlight.keywords.isEmpty)
        for keyword in JapaneseKiraKeyword.allCases {
            let delay = keyword.countdownDelay(primary: 3, backupExtra: 3)
            precondition(delay == (keyword.isBackup ? 6 : 3))
            var countdown = SpeechKiraCountdown()
            precondition(countdown.arm(endpoint: 10, receivedAt: 10, delay: delay))
            precondition(countdown.target == 10 + delay)
        }
        for (keyword, spellings) in [(JapaneseKiraKeyword.higekidatte, ["悲劇だって", "ひげきだって", "ヒゲキダッテ", "ﾋｹﾞｷﾀﾞｯﾃ"]),
                                     (.nikurashikute, ["憎らしくて", "にくらしくて", "ニクラシクテ", "ﾆｸﾗｼｸﾃ"])] {
            for text in spellings { precondition(JapaneseKiraKeyword.occurrenceCount(in: text, keyword: keyword) == 1) }
        }
        precondition(JapaneseKiraKeyword.occurrenceCount(in: "悲劇だっ", keyword: .higekidatte) == 0)
        precondition(JapaneseKiraKeyword.occurrenceCount(in: "憎らしく", keyword: .nikurashikute) == 0)
        var cues = SpeechCueDeduplicator()
        precondition(cues.allows(.higekidatte, at: 10, cooldown: 12))
        cues.record(.higekidatte, at: 10)
        precondition(!cues.allows(.kamawanai, at: 13, cooldown: 12))
        precondition(!cues.allows(.higekidatte, at: 15, cooldown: 12))
        precondition(cues.allows(.nikurashikute, at: 14, cooldown: 12), "Second verse is an independent cue")
        cues.record(.nikurashikute, at: 14)
        precondition(!cues.allows(.tenokouni, at: 17, cooldown: 12))
        precondition(cues.allows(.kamawanai, at: 90, cooldown: 12))
        print("PASS: backup phrase variants, longer countdowns, primary/backup and cross-backend cue deduplication")
        print("PASS: raw PCM idle/wake (five rates, quiet sound, brief pauses, sustained silence), keyword highlight/refresh/expiry")
    }
}
