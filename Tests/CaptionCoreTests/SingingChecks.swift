import Foundation
import CaptionCore

enum SingingChecks {
    static func run() {
        func context(_ time: Double, singing: Float = 0.8, speech: Float = 0.05) -> SoundScene {
            SoundScene(kind: .singing, speech: speech, singing: singing, music: 0.8,
                       audioTime: floor(time * 2) / 2)
        }
        var player = SingingPerformance()
        for step in 0..<100 {
            let time = Double(step) / 50
            precondition(player.sample(scene: context(time, singing: 0, speech: 0.8), level: 0.3, at: time) == nil,
                         "Speech with music must stay seated")
        }
        for step in 100..<120 { _ = player.sample(scene: context(Double(step) / 50), level: 0.3, at: Double(step) / 50) }
        _ = player.sample(scene: .warming, level: 0.3, at: 2.4)
        precondition(player.phase == .seated, "Brief singing glitches must not trigger")
        for step in 125..<170 { _ = player.sample(scene: context(Double(step) / 50), level: 0.3, at: Double(step) / 50) }
        precondition(player.phase == .rising)
        let rise = player.frameIndex!
        _ = player.sample(scene: .warming, level: 0, at: 3.7)
        precondition(player.phase == .rising &&
                     SingingTimeline.risingFrames.firstIndex(of: player.frameIndex!)! >= SingingTimeline.risingFrames.firstIndex(of: rise)!,
                     "Detection loss cannot interrupt rising")
        _ = player.sample(scene: context(4.6), level: 0.3, at: 4.6)
        precondition(player.phase == .singing && player.frameIndex! >= 16)
        _ = player.sample(scene: .warming, level: 0, at: 6.5)
        precondition(player.phase == .singing, "Uncertain classification alone must not be treated as silence")
        _ = player.sample(scene: .warming, level: 0, at: 10.7)
        precondition(player.phase == .sitting)
        _ = player.sample(scene: context(11), level: 0.4, at: 11)
        precondition(player.phase == .sitting, "A new song hint cannot reverse a half-completed sit-down")
        _ = player.sample(scene: .warming, level: 0, at: 12)
        precondition(player.phase == .seated && player.frameIndex == nil)
        for step in 0..<100 {
            let time = 13 + Double(step) / 50
            _ = player.sample(scene: context(13), level: 0.5, at: time)
        }
        precondition(player.phase == .seated, "Repeated UI polls of one model result are not sustained evidence")
        _ = player.sample(scene: context(15), level: 0.5, at: 15, enabled: false)
        precondition(player.phase == .seated)
        _ = player.sample(scene: context(1), level: 0, at: 1)
        precondition(player.phase == .seated, "Silence and clock reset are safe")
        var slow = SingingPerformance()
        for time in [0.0, 0.5, 1.0, 2.3] { _ = slow.sample(scene: context(time), level: 0.3, at: time) }
        precondition(slow.phase == .singing && slow.frameIndex == 16)
        for (time, frame) in [(2.6, 17), (3.0, 17), (3.35, 20), (3.7, 20),
                              (4.1, 21), (4.5, 21), (4.6, 21), (4.8, 22), (4.95, 22), (5.24, 23), (5.31, 16)] {
            _ = slow.sample(scene: context(time), level: 0.3, at: time)
            precondition(slow.frameIndex == frame,
                         "Equal quarter-cycle pose arrivals must not return from the right lean early")
        }
        // These visible pose landmarks must remain equally spaced even if
        // transition frames/holds change. Include wraparound to the next lean.
        var starts: [Int: Double] = [:], phase = 0.0
        for (frame, fraction) in zip(SingingTimeline.singingFrames, SingingTimeline.singingFractions) {
            starts[frame] = phase; phase += fraction
        }
        precondition(abs(phase - 1) < 1e-12)
        let arrivals = [starts[17]!, starts[20]!, starts[21]!, starts[22]!, starts[17]! + 1]
        for (a, b) in zip(arrivals, arrivals.dropFirst()) {
            precondition(abs((b - a) - 0.25) < 1e-12, "Left, neutral, right, neutral arrivals must share one interval")
        }
        precondition(SingingTimeline.singingFrame(at: 0.78) == 21 && SingingTimeline.singingFrame(at: 0.80) == 22)
        for (anchor, pose) in zip(SingingTimeline.keyPosePhases, [17, 20, 21, 22]) {
            for offset in [-0.03, 0, 0.10] {
                precondition(SingingTimeline.singingFrame(at: anchor + offset) == pose,
                             "Key poses must hold both before and after the musical accent")
            }
        }
        // An attack can gently catch a nearby arrival before BPM locks. It
        // changes velocity, not the current pose or accumulated phase directly.
        var free = SingingPerformance()
        for time in [0.0, 0.5, 1.0, 2.3, 2.48] { _ = free.sample(scene: context(time), level: 0.3, at: time) }
        var accented = free, stale = free
        let onset = BeatEstimate(audioTime: 2.5, lastAccentTime: 2.48)
        _ = free.sample(scene: context(2.5), level: 0.3, at: 2.5)
        _ = accented.sample(scene: context(2.5), level: 0.3, at: 2.5, beat: onset)
        _ = stale.sample(scene: context(2.5), level: 0.3, at: 2.5,
                         beat: BeatEstimate(audioTime: 2.5, lastAccentTime: 1))
        precondition(accented.trackedBPM == nil && accented.cycleProgress > free.cycleProgress &&
                     accented.cycleProgress - free.cycleProgress < 0.001 && accented.frameIndex == free.frameIndex,
                     "Unlocked strong attacks only nudge a nearby arrival; they must not snap the pose")
        precondition(stale.cycleProgress == free.cycleProgress, "Old attacks cannot steer today's animation")
        var repeated = accented, missing = accented
        for step in 126...160 {
            let time = Double(step) / 50
            _ = repeated.sample(scene: context(time), level: 0.3, at: time,
                beat: BeatEstimate(audioTime: time, lastAccentTime: 2.48))
            _ = missing.sample(scene: context(time), level: 0.3, at: time)
            precondition(repeated.cycleProgress == missing.cycleProgress,
                         "Repeated UI polls of one attack may not repeatedly pull the animation")
        }
        var buffer = free
        _ = buffer.sample(scene: context(4.82), level: 0.3, at: 4.82)
        var bufferAttack = buffer
        _ = buffer.sample(scene: context(4.84), level: 0.3, at: 4.84)
        _ = bufferAttack.sample(scene: context(4.84), level: 0.3, at: 4.84,
            beat: BeatEstimate(audioTime: 4.84, lastAccentTime: 4.82))
        precondition(bufferAttack.cycleProgress == buffer.cycleProgress,
                     "An attack in the return buffer must not invent a fourth motion accent")
        var interlude = SingingPerformance()
        for time in [0.0, 0.5, 1.0, 2.3] { _ = interlude.sample(scene: context(time), level: 0.3, at: time) }
        for step in 24...320 {
            let time = Double(step) / 10
            let music = SoundScene(kind: .music, music: 0.8, audioTime: floor(time * 2) / 2)
            _ = interlude.sample(scene: music, level: 0.3, at: time)
            precondition(interlude.phase == .singing, "A 30-second instrumental interlude must keep standing")
        }
        var frozen = interlude
        var silence = interlude
        _ = silence.sample(scene: SoundScene(kind: .silence, audioTime: 32.02), level: 0, at: 32.02)
        precondition(silence.phase == .sitting, "Confirmed pure silence must start sitting immediately")
        _ = silence.sample(scene: .warming, level: 0, at: 33.23)
        precondition(silence.phase == .seated, "Immediate silence exit still completes a smooth sit-down")
        var audible = interlude
        _ = audible.sample(scene: SoundScene(kind: .silence, audioTime: 32.02), level: 0.2, at: 32.02)
        precondition(audible.phase == .singing, "A silence model label must not override clearly audible audio")
        var partialRise = SingingPerformance()
        for time in [0.0, 0.5, 1.0, 1.4] { _ = partialRise.sample(scene: context(time), level: 0.3, at: time) }
        let pose = partialRise.frameIndex
        _ = partialRise.sample(scene: SoundScene(kind: .silence, audioTime: 1.42), level: 0, at: 1.42)
        precondition(partialRise.phase == .sitting && partialRise.frameIndex == pose,
                     "Silence during rising returns immediately from the current pose without a height jump")
        _ = partialRise.sample(scene: .warming, level: 0, at: 2.0)
        precondition(partialRise.phase == .seated)
        for step in 321...381 {
            _ = frozen.sample(scene: SoundScene(kind: .music, music: 0.8, audioTime: 32), level: 0.3, at: Double(step) / 10)
        }
        precondition(frozen.phase == .sitting, "Repeated stale music evidence cannot hold standing indefinitely")
        for step in 321...380 {
            _ = interlude.sample(scene: .warming, level: 0, at: Double(step) / 10)
            precondition(interlude.phase == (step < 380 ? .singing : .sitting), "Exit after six seconds without music")
        }
        var speech = SingingPerformance()
        for time in [0.0, 0.5, 1.0, 2.3] { _ = speech.sample(scene: context(time), level: 0.3, at: time) }
        for step in 30...71 {
            let time = Double(step) / 10
            _ = speech.sample(scene: context(time, singing: 0, speech: 0.8), level: 0.3, at: time)
        }
        precondition(speech.phase == .sitting, "Four seconds of confirmed speech exits even with BGM")
        var tempo = SingingPerformance()
        for time in [0.0, 0.5, 1.0, 2.3] { _ = tempo.sample(scene: context(time), level: 0.3, at: time) }
        var lastFrame = tempo.frameIndex!, lastDuration = tempo.cycleDuration
        for step in 116...650 {
            let time = Double(step) / 50, bpm = time < 7 ? 60.0 : 360.0
            let beat = BeatEstimate(bpm: bpm, confidence: 0.9, audioTime: time,
                lastBeatTime: floor(time / (60 / bpm)) * (60 / bpm),
                lastAccentTime: floor(time / (60 / bpm)) * (60 / bpm))
            let frame = tempo.sample(scene: context(time), level: 0.3, at: time, beat: beat)!
            precondition(frame == lastFrame || frame == SingingTimeline.singingFrames[(SingingTimeline.singingFrames.firstIndex(of: lastFrame)! + 1) % 8],
                         "Tempo/phase changes may not skip or reverse a body pose")
            precondition(abs(tempo.cycleDuration - lastDuration) < 0.05, "Tempo change must be gradual")
            precondition(SingingTimeline.cycleDurationRange.contains(tempo.cycleDuration))
            lastFrame = frame; lastDuration = tempo.cycleDuration
        }
        precondition(abs(tempo.cycleDuration - 480 / 360.0) < 0.08, "360 BPM must approach eight beats per cycle")
        let tempoCases: [(Double, Double, Double)] = [(60.0, 4.0, 1.0), (90.0, 8.0 / 3, 1),
            (120.0, 2.0, 1), (120.01, 480 / 120.01, 2), (144.0, 10.0 / 3, 2),
            (180.0, 8.0 / 3, 2), (240.0, 2.0, 2), (360.0, 4.0 / 3, 2)]
        for (bpm, expectedCycle, beatsPerSegment) in tempoCases {
            var clock = SingingPerformance()
            for step in 0...1250 {
                let t = Double(step) / 50
                let beat = BeatEstimate(bpm: bpm, confidence: 0.9, audioTime: t,
                    lastBeatTime: floor(t / (60 / bpm)) * (60 / bpm),
                    lastAccentTime: floor(t / (60 / bpm)) * (60 / bpm))
                _ = clock.sample(scene: context(t), level: 0.3, at: t, beat: beat)
            }
            precondition(abs(clock.cycleDuration - expectedCycle) < 0.00001,
                         "Each segment must take one beat through 120 BPM, two beats strictly above")
            let before = clock.cycleProgress, period = beatsPerSegment * 60 / bpm, t = 25 + period
            let beat = BeatEstimate(bpm: bpm, confidence: 0.9, audioTime: t, lastBeatTime: t)
            _ = clock.sample(scene: context(t), level: 0.3, at: t, beat: beat)
            let advance = (clock.cycleProgress - before + 1).truncatingRemainder(dividingBy: 1)
            precondition(abs(advance - 0.25) < 0.00001, "The selected one/two-beat interval advances one quarter-cycle without distortion")
        }
        let heldDuration = tempo.cycleDuration, heldBPM = tempo.trackedBPM
        for step in 651...850 {
            let time = Double(step) / 50
            _ = tempo.sample(scene: context(time), level: 0.3, at: time)
            precondition(tempo.cycleDuration <= heldDuration + 0.001 && tempo.trackedBPM == heldBPM,
                         "A missing tempo estimate must hold the previous speed instead of slowing to the default")
        }
        SingingPhaseChecks.run()
        print("PASS: singing action (long BGM interlude, immediate pure-silence exit, partial-rise continuity, uncertain/stale evidence, speech exit, three accents plus buffer, bounded tempo, unlocked attack nudges, no jumps)")
    }
}
