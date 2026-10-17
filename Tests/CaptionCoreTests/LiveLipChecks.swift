import Foundation
import CaptionCore

enum LiveLipChecks {
    static func run() {
        func feed(_ analyzer: LiveLipAnalyzer, seconds: Double = 0.5, rate: Double = 48_000,
                  signal: (Double) -> Float) -> [LiveLipFrame] {
            (0..<Int(rate * seconds)).compactMap { analyzer.consume(signal(Double($0) / rate), sampleRate: rate) }
        }
        func vowel(_ f1: Double, _ f2: Double) -> (Double) -> Float {
            let harmonics = (1...35).map { n -> (Double, Double) in
                let frequency = Double(n) * 125
                let amplitude = exp(-pow((frequency - f1) / 150, 2))
                    + 0.65 * exp(-pow((frequency - f2) / 250, 2))
                return (frequency, amplitude * 0.045)
            }
            return { t in Float(harmonics.reduce(0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) }) }
        }
        let silent = feed(LiveLipAnalyzer()) { _ in 0 }
        precondition(silent.allSatisfy { $0.shape == .rest && $0.level == 0 })
        precondition(silent.last!.scene.kind == .silence && silent.last!.scene.instruments.isEmpty)
        for frequency in [80.0, 1000.0] {
            let tone = feed(LiveLipAnalyzer()) { Float(0.2 * sin(2 * .pi * frequency * $0)) }
            precondition(tone.allSatisfy { $0.shape == .rest }, "Bass and pure alerts must not talk")
        }
        var random: UInt64 = 37
        let noise = feed(LiveLipAnalyzer()) { _ in
            random = random &* 6364136223846793005 &+ 1
            return Float(Double(random >> 32) / Double(UInt32.max) - 0.5) * 0.2
        }
        precondition(noise.filter { $0.voiceLike }.count < noise.count / 5, "Noise should not sustain a mouth")
        var shapes = Set<MouthShape>()
        for pair in [(300.0, 900.0), (750.0, 1250.0), (300.0, 2400.0), (600.0, 2300.0)] {
            let analyzer = LiveLipAnalyzer()
            let frames = feed(analyzer, signal: vowel(pair.0, pair.1))
            precondition(frames.filter(\.voiceLike).count > frames.count / 2)
            shapes.formUnion(frames.map(\.shape).filter { $0 != .rest })
            let estimates = frames.suffix(10).compactMap { frame -> (Float, Float)? in
                guard let f1 = frame.firstFormant, let f2 = frame.secondFormant else { return nil }
                return (f1, f2)
            }
            precondition(estimates.count >= 8, "Steady voiced input must provide usable formant estimates")
            let f1 = estimates.map(\.0).reduce(0, +) / Float(estimates.count)
            let f2 = estimates.map(\.1).reduce(0, +) / Float(estimates.count)
            print("Formant check: \(Int(pair.0))/\(Int(pair.1)) Hz -> \(Int(f1))/\(Int(f2)) Hz")
            precondition(abs(f1 - Float(pair.0)) < 200 && abs(f2 - Float(pair.1)) < 300,
                         "LPC must track the known vowel resonances")
            precondition(zip(frames, frames.dropFirst()).allSatisfy { abs($1.audioTime - $0.audioTime - 0.02) < 0.000001 },
                         "Analysis timestamps must follow sample time, not wall-clock scheduling")
            let tail = feed(analyzer, seconds: 0.2) { _ in 0 }
            precondition(tail.last?.shape == .rest, "Silence must close mouth within 200 ms including window tail")
            let changes = zip(frames, frames.dropFirst()).filter { $0.shape != $1.shape }.count
            precondition(changes < 5, "Sustained vowel must not jitter")
        }
        precondition(shapes.count >= 3, "Different spectra must produce distinct mouth shapes")
        let analyzer = LiveLipAnalyzer()
        precondition(analyzer.consume(.nan, sampleRate: 48_000) == nil)
        precondition(analyzer.consume(1, sampleRate: .nan) == nil)
        let rates = [44_100.0, 48_000.0, 96_000.0].map { rate in
            feed(LiveLipAnalyzer(), rate: rate, signal: vowel(750, 1250)).filter(\.voiceLike).count
        }
        precondition(rates.max()! - rates.min()! <= 1, "Decisions follow audio time across devices")
        let sustained = LiveLipAnalyzer()
        let held = feed(sustained, seconds: 2, signal: vowel(750, 1250))
        precondition(held.dropFirst(5).allSatisfy { $0.shape != .rest && $0.shape != .closed },
                     "Long vowels must hold without inserting periodic closures")
        let gap = feed(sustained, seconds: 0.10) { _ in 0 }
        precondition(gap.contains { $0.shape == .closed }, "A confirmed actual pause must preserve lip closure")
        let resume = feed(sustained, seconds: 0.3, signal: vowel(750, 1250))
        precondition(resume.last?.shape == .ah, "Speech must reopen after a short closure")
        let soft = feed(LiveLipAnalyzer(), signal: { vowel(750, 1250)($0) * 0.1 })
        precondition(soft.contains { $0.shape == .slight }, "Soft speech needs a slight-open pose")
        precondition(held.allSatisfy { $0.shape != .tongue }, "Never invent tongue phonemes from a vowel spectrum")
        checkPosePlayer()
        checkSoundScene()
        SingingChecks.run()
        BeatChecks.run()
        AubioChecks.run()
        // Known hints exercise the gating policy, not the model's accuracy.
        let priority = LiveLipAnalyzer()
        priority.scene = SoundScene(kind: .music, music: 0.9)
        let vetoed = feed(priority, signal: vowel(750, 1250))
        precondition(vetoed.allSatisfy { !$0.voiceLike && $0.shape == .rest }, "Music context suppresses vowel-like instruments")
        precondition(vetoed.last!.level > 0.1, "Raw playback level is independent of the mouth gate")
        precondition(vetoed.allSatisfy { $0.scene.kind == .music },
                     "BGM with a closed mouth gate must not be classified as pure silence")
        priority.scene = SoundScene(kind: .mixed, speech: 0.8, music: 0.7, audioTime: 0.5)
        let mixed = feed(priority, signal: vowel(750, 1250))
        precondition(mixed.filter(\.voiceLike).count > mixed.count / 2, "Human voice mixed with music must reopen")
        priority.scene = SoundScene(kind: .speech, speech: 0.9, audioTime: 1)
        let stopped = feed(priority, seconds: 0.25) { _ in 0 }
        precondition(stopped.last!.shape == .rest, "A speech hint cannot hold a silent mouth open")
        precondition(stopped.last!.scene.kind == .silence && stopped.last!.level < 0.01,
                     "Near-zero PCM confirms pure silence within 250 ms, regardless of the previous model hint")
        let bypass = LiveLipAnalyzer(); bypass.scene = SoundScene(kind: .music, music: 0.9); bypass.voicePriority = false
        precondition(feed(bypass, signal: vowel(750, 1250)).contains { $0.voiceLike }, "Priority can be disabled")
        let stale = LiveLipAnalyzer(); stale.scene = SoundScene(kind: .music, music: 0.9, audioTime: -10)
        precondition(feed(stale, signal: vowel(750, 1250)).contains { $0.voiceLike }, "Old classification cannot indefinitely suppress speech")
        print("PASS: live lip analysis (silence, alerts, noise, distinct vowels, bounded release, stable holds, device rates)")
    }

    private static func checkSoundScene() {
        let tracker = SoundSceneTracker()
        let first = tracker.receive(["music": 0.9, "piano": 0.8], at: 1)!
        precondition(first.kind == .music && first.instruments.isEmpty)
        let second = tracker.receive(["music": 0.9, "piano": 0.8], at: 1.5)!
        precondition(second.instruments == ["钢琴"])
        precondition(tracker.receive(["speech": 0.95, "music": 0.6], at: 2)!.kind == .mixed)
        precondition(tracker.receive(["singing": 0.95, "music": 0.9], at: 2.5)!.kind == .singing)
        precondition(tracker.receive(["speech": 1], at: 2) == nil, "Discard out-of-order model callbacks")
        precondition(second.fresh(at: 4).kind == .warming && second.fresh(at: 0).kind == .warming)
        precondition(SoundScene.unavailable.fresh(at: 100).kind == .unavailable)
        let invalid = tracker.receive(["speech": .nan, "singing": -.infinity, "music": 2], at: 3)!
        precondition(invalid.speech.isFinite && invalid.music <= 1)
        let labels = SoundSceneTracker()
        _ = labels.receive(["guitar": 0.8, "plucked_string_instrument": 0.9], at: 1)
        precondition(labels.receive(["guitar": 0.8, "plucked_string_instrument": 0.9], at: 1.5)!.instruments == ["吉他"])
        let quiet = SoundSceneTracker().receive(["silence": 0.99], at: 1)!
        precondition(quiet.kind == .silence)
        print("PASS: sound context (mixed vocals, singing, stable instrument hints, stale and invalid evidence, music gate and bypass)")
    }

    private static func checkPosePlayer() {
        var player = MouthPosePlayer()
        for tick in 0...100 { _ = player.sample(.ah, at: Double(tick) / 50) }
        precondition(player.displayed == .ah && player.transitionsStarted == 1, "Held speech must not loop")
        for tick in 101...130 { _ = player.sample(.oo, at: Double(tick) / 50) }
        precondition(player.displayed == .oo, "Sustained new vowel completes its bridges")
        for tick in 131...155 { _ = player.sample(.rest, at: Double(tick) / 50) }
        precondition(player.displayed == .rest, "Silence cancels pending openings and relaxes")
        print("PASS: mouth transitions (bridges, long holds and natural silence release)")
    }
}
