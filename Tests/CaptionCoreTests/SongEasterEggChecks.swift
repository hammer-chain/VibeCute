import Foundation
import CaptionCore

enum SongEasterEggChecks {
    static func run() {
        for title in ["星間飛行", "星间飞行 / covered by XXX", "【歌ってみた】星間飛行", "Ｓｅｉｋａｎ Ｈｉｋｏｕ", "Seikan Hikō - Live", "星 間 飛 行"] {
            precondition(SeikanHikou.matches(title: title), title)
        }
        for title in ["", "星空飞行", "Kira Kira", "myseikan hikouette", "seikan hikounrelated", "ライオン"] {
            precondition(!SeikanHikou.matches(title: title), title)
        }
        func track(_ position: Double, _ now: Double, rate: Double = 1, title: String = "星間飛行 Cover A", duration: Double = 245) -> NowPlayingTrack {
            NowPlayingTrack(title: title, artist: "Singer", player: "Player", duration: duration, elapsed: position, rate: rate, observedAt: now)
        }
        let a = track(0, 0)
        precondition(a.recordingKey != track(0, 0, title: "星間飛行 Cover B").recordingKey)
        precondition(a.recordingKey != track(0, 0, duration: 280).recordingKey)
        precondition(NowPlayingTrack(title: "星間飛行", observedAt: 0).recordingKey == nil)
        precondition(a.position(at: 4.01) == nil && a.position(at: -1) == nil)
        precondition(track(20, 0, rate: 0).position(at: 1) == 20)
        precondition(track(20, 0, rate: 2).position(at: 1) == 22)
        var scheduler = KiraCueScheduler(), events = 0
        for i in 0..<120 {
            let now = Double(i) / 60
            // Hold one system snapshot between polls, UI advances at 60 Hz.
            if scheduler.sample(track: track(9, 0), cues: [10], at: now) { events += 1 }
        }
        precondition(events == 1, "One cue must fire once even with repeated metadata")
        var paused = KiraCueScheduler()
        precondition(!paused.sample(track: track(9, 0), cues: [10], at: 0))
        precondition(!paused.sample(track: track(9.6, 0.6, rate: 0), cues: [10], at: 0.6))
        precondition(!paused.sample(track: track(9.6, 0.7), cues: [10], at: 0.7), "Resume past cue must not backfire")
        var seek = KiraCueScheduler()
        precondition(!seek.sample(track: track(0, 0), cues: [10, 20], at: 0))
        precondition(!seek.sample(track: track(15, 0.1), cues: [10, 20], at: 0.1), "Forward seek skips past cue")
        precondition(!seek.sample(track: track(8, 0.2), cues: [10, 20], at: 0.2))
        var replay = 0
        for i in 1...120 {
            let now = 0.2 + Double(i) / 60
            if seek.sample(track: track(8 + Double(i) / 60, now), cues: [10, 20], at: now) { replay += 1 }
        }
        precondition(replay == 1, "Rewind re-arms a future cue")
        var fast = KiraCueScheduler()
        precondition(!fast.sample(track: track(9, 0, rate: 2), cues: [10], at: 0))
        precondition(fast.sample(track: track(9, 0, rate: 2), cues: [10], at: 0.1), "Arm lead follows playback speed")
        precondition(!fast.sample(track: nil, cues: [10], at: 0.2))
        precondition(!fast.sample(track: track(9.2, 0.3, title: "星間飛行 Cover B"), cues: [10], at: 0.3))
        precondition(KiraTimeline.frame(at: 0) == 24)
        precondition(KiraTimeline.frame(at: 0.43) == 28)
        precondition(KiraTimeline.frame(at: 0.8) == 29)
        precondition(KiraTimeline.frame(at: KiraTimeline.duration) == nil)
        precondition(KiraTimeline.frame(at: .nan) == nil)
        print("PASS: title variants/negative controls, per-recording keys, freshness, pause, seek, rewind, speed, one-shot Kira timing")
    }
}
