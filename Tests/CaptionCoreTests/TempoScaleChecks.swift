import Foundation
import CaptionCore

enum TempoScaleChecks {
    static func run() {
        func reference(_ time: Double, _ bpm: Double, confidence: Float = 0.9,
                       frozenAttack: Double? = nil) -> BeatEstimate {
            let attack = frozenAttack ?? floor(time / (60 / bpm)) * (60 / bpm)
            return BeatEstimate(bpm: bpm, confidence: confidence, audioTime: time,
                                lastBeatTime: attack, lastAccentTime: attack)
        }
        // Reproduce the reported defect even when aubio NEVER changes its raw
        // 130 BPM. No playback speed setting is supplied to the production code.
        var resolver = TempoScaleResolver()
        for step in 0..<1200 {
            let time = Double(step) / 50
            let bpm = time < 5 ? 130.0 : time < 10 ? 260.0 : time < 18 ? 65.0 : 130.0
            let selected = resolver.sample(rawBPM: 130, reference: reference(time, bpm), at: time)!
            if (7.5..<10).contains(time) { precondition(selected == 260) }
            if (13..<18).contains(time) { precondition(selected == 65) }
            if time > 21 { precondition(selected == 130) }
        }
        var repeated = TempoScaleResolver(), weak = TempoScaleResolver(), sporadic = TempoScaleResolver()
        for step in 0..<200 {
            let time = Double(step) / 50
            _ = repeated.sample(rawBPM: 130, reference: reference(time, 260, frozenAttack: 0), at: time)
            _ = weak.sample(rawBPM: 130, reference: reference(time, 260, confidence: 0.4), at: time)
            _ = sporadic.sample(rawBPM: 130, reference: reference(time, step % 50 < 20 ? 260 : 130), at: time)
            precondition(repeated.multiplier == 1 && weak.multiplier == 1 && sporadic.multiplier == 1,
                         "Duplicate attacks, weak or short-lived subdivisions must not select another level")
        }
        var held = TempoScaleResolver()
        for step in 0..<150 {
            let time = Double(step) / 50
            _ = held.sample(rawBPM: 130, reference: reference(time, 260), at: time)
        }
        precondition(held.multiplier == 2)
        for step in 150..<250 {
            let time = Double(step) / 50
            precondition(held.sample(rawBPM: 130, reference: .unknown, at: time) == 260,
                         "A missing reference must hold the established scale")
        }
        precondition(held.sample(rawBPM: 260, reference: reference(5, 260), at: 5) == 260 && held.multiplier == 1,
                     "Aubio catching up must remove the old multiplier rather than double twice")
        precondition(held.sample(rawBPM: .nan, reference: .unknown, at: 5.02) == nil)
        print("PASS: tempo scale (frozen aubio raw 130 with 1×→2×→0.5×→1×, fresh attack confirmation, noisy/repeated veto, lost-reference hold, no double correction)")
    }
}
