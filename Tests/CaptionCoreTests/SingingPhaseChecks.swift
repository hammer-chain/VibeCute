import Foundation
import CaptionCore

enum SingingPhaseChecks {
    static func run() {
        let cases: [(Double, Double)] = [100.0, 120, 160, 180].flatMap { bpm in
            [0.01, 0.17, 0.24].map { (bpm, $0) }
        }
        for (bpm, accentOrigin) in cases {
            var player = SingingPerformance()
            let beatPeriod = 60 / bpm, deliveryAge = 0.04
            let nominal = bpm > 120 ? 480 / bpm : 240 / bpm
            var lastFrame: Int?, errors: [Double] = []
            var samples: [(Double, Int)] = [], landings: [(Double, Int)] = []
            var last = BeatEstimate.unknown
            for step in 0...3000 {
                let t = Double(step) / 50
                let onset = accentOrigin + floor((t - 0.10 - accentOrigin) / beatPeriod) * beatPeriod
                let beat = BeatEstimate(bpm: bpm, confidence: 0.9, audioTime: t - deliveryAge,
                    lastBeatTime: onset, lastAccentTime: onset)
                let scene = SoundScene(kind: .singing, singing: 0.9, music: 0.9, audioTime: t)
                let frame = player.sample(scene: scene, level: 0.3, at: t, beat: beat, beatDeliveryAge: deliveryAge)
                if player.phase == .singing, let frame {
                    if let lastFrame {
                        let sequence = SingingTimeline.singingFrames
                        precondition(frame == lastFrame || frame == sequence[(sequence.firstIndex(of: lastFrame)! + 1) % sequence.count],
                                     "Phase calibration cannot jump or reverse a displayed pose")
                    }
                    if t > 40 && frame != lastFrame && [17,20,21,22].contains(frame) {
                        let intendedAnchor = t + 0.04 * nominal
                        let nearestBeat = accentOrigin + round((intendedAnchor - accentOrigin) / beatPeriod) * beatPeriod
                        errors.append(abs(intendedAnchor - nearestBeat))
                        landings.append((nearestBeat, frame))
                    }
                    samples.append((t, frame))
                    lastFrame = frame
                }
                last = beat
            }
            precondition(player.phaseAlignmentCount > 20)
            precondition(!errors.isEmpty && errors.max()! < 0.035,
                         "Pose entry must lead the known accent by 0.04 cycles within 35ms, including observation lag")
            for (accent, pose) in landings where accent + 0.08 * nominal < 60 {
                for offset in [-0.02, 0, 0.08] {
                    let target = accent + offset * nominal
                    let visible = samples.min { abs($0.0 - target) < abs($1.0 - target) }!
                    precondition(visible.1 == pose, "The actual displayed key pose must span both sides of the known accent")
                }
            }
            precondition(abs(player.cycleDuration - nominal) < 0.00001, "Calibration cannot change nominal beat scaling")
            print("Phase lock \(bpm) BPM, offset \(accentOrigin)s: \(errors.count) pose arrivals, max \(errors.max()! * 1000)ms, accepted accents \(player.phaseAlignmentCount)")
            let accepted = player.phaseAlignmentCount
            for step in 3001...3050 {
                let t = Double(step) / 50
                let repeated = BeatEstimate(bpm: bpm, confidence: 0.9, audioTime: t,
                    lastBeatTime: last.lastBeatTime, lastAccentTime: last.lastAccentTime)
                _ = player.sample(scene: SoundScene(kind: .singing, singing: 0.9, music: 0.9, audioTime: t), level: 0.3, at: t, beat: repeated)
            }
            precondition(player.phaseAlignmentCount == accepted, "A repeated attack cannot be applied twice")
            player.forgetTempo()
            precondition(player.accentPhaseErrorSeconds == nil && player.alignedAccentTime == -.infinity)
        }
        print("PASS accent phase calibration: late observations, four poses, one/two beats, monotonic frames, deduplication, detector reset")
    }
}
