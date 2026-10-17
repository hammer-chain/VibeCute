import Foundation
import CaptionCore

enum BeatChecks {
    static func run() {
        func train(bpm: Double, rate: Double = 16_000, musical: Bool = true,
                   stopAt: Double = 10, doubleAfter: Double = .infinity, irregular: Bool = false,
                   weakSubdivisions: Bool = false, preservePitch: Bool = true) -> [LiveLipFrame] {
            let analyzer = LiveLipAnalyzer()
            analyzer.tempoEngine = .spectral
            var frames: [LiveLipFrame] = []
            let irregularOnsets = [0.0, 0.31, 0.88, 1.76, 2.15, 2.91, 3.39, 4.35, 4.70, 5.37, 5.78, 6.67, 7.20]
            for index in 0..<Int(rate * 10) {
                let t = Double(index) / rate
                analyzer.scene = SoundScene(kind: musical ? .music : .speech, speech: musical ? 0 : 0.9,
                    music: musical ? 0.9 : 0, audioTime: floor(t * 2) / 2)
                // Change the audio timeline itself: all attacks/decays speed up,
                // unlike inserting an extra weaker hi-hat between unchanged beats.
                let sourceTime = t >= doubleAfter ? doubleAfter + (t - doubleAfter) * 2 : t
                let carrierTime = preservePitch ? t : sourceTime
                let interval = 60 / bpm / (weakSubdivisions ? 2 : 1)
                let weak = weakSubdivisions && Int(floor(sourceTime / interval)) % 2 == 1
                let offset = irregular ? t - irregularOnsets.last(where: { $0 <= t })! :
                    sourceTime.truncatingRemainder(dividingBy: interval)
                let pulse = t < stopAt ? (weak ? 0.07 : 0.4) * exp(-offset * 65) *
                    (sin(2 * .pi * 100 * carrierTime) + 0.6 * sin(2 * .pi * 1700 * carrierTime)) : 0
                if let frame = analyzer.consume(Float(pulse), sampleRate: rate) { frames.append(frame) }
            }
            return frames
        }
        for bpm in [60.0, 90, 120, 160, 240, 320, 360] {
            let frames = train(bpm: bpm)
            let locked = frames.filter { $0.beat.reliable }
            precondition(frames.contains { !$0.beat.reliable && $0.beat.lastAccentTime != nil },
                         "Strong attacks must be available before enough beats exist to lock BPM")
            precondition(!locked.isEmpty, "Regular \(bpm) BPM percussion must acquire a rhythm")
            let estimate = locked.last!.beat.bpm!
            print("Beat check: \(bpm) BPM -> \(estimate) BPM, first lock \(locked.first!.audioTime)s")
            precondition(abs(estimate - bpm) / bpm < 0.08, "Regular percussion tempo should be within eight percent")
        }
        precondition(train(bpm: 120, musical: false).allSatisfy { !$0.beat.reliable },
                     "Speech context must not activate music tracking")
        let device = train(bpm: 120, rate: 48_000).last!.beat
        precondition(device.reliable && abs(device.bpm! - 120) < 5, "Beat timing uses audio samples across device rates")
        for (bpm, preservePitch) in [(90.0, true), (160.0, false)] {
            let frames = train(bpm: bpm, doubleAfter: 4, preservePitch: preservePitch)
            let doubled = frames.last!.beat
            print("Beat speed change: \(bpm) -> \(doubled.bpm ?? 0) BPM, confidence \(doubled.confidence)")
            precondition(doubled.reliable && abs(doubled.bpm! - bpm * 2) < bpm * 0.12,
                         "A sustained 2x playback change must replace the old tempo, with or without pitch preservation")
            if bpm == 90 {
                var player = SingingPerformance(), before = 0.0
                for frame in frames {
                    let time = frame.audioTime
                    let song = SoundScene(kind: .singing, singing: 0.9, music: 0.9, audioTime: floor(time * 2) / 2)
                    _ = player.sample(scene: song, level: 0.3, at: time, beat: frame.beat)
                    if time < 4 { before = player.cycleDuration }
                }
                precondition(abs(player.cycleDuration - 8.0 / 3) < 0.12 && abs(player.cycleDuration - before) < 0.25,
                             "90 to 180 BPM changes to two beats per segment, preserving the body tempo")
            }
        }
        let subdivisions = train(bpm: 90, weakSubdivisions: true).last!.beat
        precondition(subdivisions.reliable && abs(subdivisions.bpm! - 90) < 8,
                     "Weaker subdivisions should retain the strong main beat")
        let stopped = train(bpm: 120, stopAt: 5)
        precondition(stopped.contains { $0.beat.reliable } && !stopped.last!.beat.reliable,
                     "A locked rhythm must expire when the audio stops")
        precondition(train(bpm: 120, irregular: true).allSatisfy { !$0.beat.reliable },
                     "Irregular sounds should not produce a confident tempo")
        let analyzer = LiveLipAnalyzer()
        var quiet = LiveLipFrame.silence
        for index in 0..<16_000 * 3 {
            analyzer.scene = SoundScene(kind: .music, music: 0.9, audioTime: Double(index) / 16_000)
            if let frame = analyzer.consume(0, sampleRate: 16_000) { quiet = frame }
        }
        precondition(!quiet.beat.reliable, "A music hint cannot invent beats from silence")
        var tracker = BeatTracker()
        let power = [Float](repeating: 0, count: 512)
        precondition(!tracker.sample(power: power, rms: 0, at: .nan, musical: true).reliable)
        precondition(!BeatEstimate(bpm: .infinity, confidence: 1, audioTime: 1, lastBeatTime: 1).reliable)
        print("PASS: streaming rhythm (60–360 BPM, real 2x playback with/without pitch preservation, body acceleration, weak subdivisions, irregular hits, missing rhythm, speech veto, silence)")
    }
}
