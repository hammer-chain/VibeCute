import Foundation
import CaptionCore

enum AubioChecks {
    static func stream(bpm: Double, rate: Double = 16_000, duration: Double = 20,
                       stopAt: Double = .infinity, doubleAt: Double = .infinity,
                       musical: Bool = true, preservePitch: Bool = true, contextGap: ClosedRange<Double>? = nil) -> [LiveLipFrame] {
        let analyzer = LiveLipAnalyzer()
        var result: [LiveLipFrame] = []
        for index in 0..<Int(rate * duration) {
            let time = Double(index) / rate
            analyzer.scene = contextGap?.contains(time) == true ? .warming : SoundScene(kind: musical ? .music : .speech,
                speech: musical ? 0 : 0.9, music: musical ? 0.9 : 0,
                audioTime: floor(time * 2) / 2)
            let source = time < doubleAt ? time : doubleAt + (time - doubleAt) * 2
            let carrier = preservePitch ? time : source
            let offset = source.truncatingRemainder(dividingBy: 60 / bpm)
            let sample = time < stopAt ? 0.4 * exp(-offset * 65) *
                (sin(2 * .pi * 100 * carrier) + 0.6 * sin(2 * .pi * 1700 * carrier)) : 0
            if let frame = analyzer.consume(Float(sample), sampleRate: rate) { result.append(frame) }
        }
        return result
    }
    static func variableStream(preservePitch: Bool = true, weakSubdivisions: Bool = false) -> [LiveLipFrame] {
        let analyzer = LiveLipAnalyzer()
        var frames: [LiveLipFrame] = []
        var sourceTime = 0.0
        for index in 0..<16_000 * 64 {
            let time = Double(index) / 16_000
            let speed = time < 14 ? 1.0 : time < 28 ? 2.0 : time < 48 ? 0.5 : 1.0
            sourceTime += speed / 16_000
            analyzer.scene = SoundScene(kind: .music, music: 0.9, audioTime: floor(time * 2) / 2)
            let carrier = preservePitch ? time : sourceTime
            let offset = sourceTime.truncatingRemainder(dividingBy: 60 / 130)
            var value = 0.4 * exp(-offset * 65) *
                (sin(2 * .pi * 100 * carrier) + 0.6 * sin(2 * .pi * 1700 * carrier))
            if weakSubdivisions {
                let hatOffset = sourceTime.truncatingRemainder(dividingBy: 30 / 130)
                value += 0.035 * exp(-hatOffset * 100) * sin(2 * .pi * 4200 * carrier)
            }
            value += 0.01 * sin(2 * .pi * 220 * carrier)
            if let frame = analyzer.consume(Float(value), sampleRate: 16_000) { frames.append(frame) }
        }
        return frames
    }
    static func run() {
        var measurements: [[String: Any]] = []
        TempoScaleChecks.run()
        var rateChanges: [[String: Any]] = []
        for (preservePitch, hats) in [(true, false), (false, true)] {
            let variable = variableStream(preservePitch: preservePitch, weakSubdivisions: hats)
            var body = SingingPerformance()
            var durations: [Double: Double] = [:]
            for frame in variable {
                let time = frame.audioTime
                let song = SoundScene(kind: .singing, singing: 0.9, music: 0.9, audioTime: floor(time * 2) / 2)
                _ = body.sample(scene: song, level: 0.3, at: time, beat: frame.beat)
                precondition(SingingTimeline.cycleDurationRange.contains(body.cycleDuration))
                for boundary in [14.0, 28, 48, 64] where time < boundary { durations[boundary] = body.cycleDuration }
            }
            precondition(durations[28]! < durations[14]! - 0.2 && durations[48]! > durations[28]! + 0.4,
                         "The body must speed up at 2x, slow down at 0.5x, and always stay within its natural range")
            for (start, end, expected) in [(10.0, 14.0, 130.0), (23.0, 28.0, 260.0), (43.0, 48.0, 65.0), (59.0, 64.0, 130.0)] {
                let section = variable.filter { (start..<end).contains($0.audioTime) }
                let raw = section.compactMap { $0.beat.rawBPM }.sorted()
                let selected = section.filter { $0.beat.reliable }.compactMap { $0.beat.bpm }.sorted()
                precondition(!selected.isEmpty)
                let median = selected[selected.count / 2]
                precondition(abs(median - expected) / expected < 0.06,
                             "Continuous 1x→2x→0.5x→1x PCM must change the selected tempo without relying on playback metadata")
                let changedAt = expected == 260 ? 14.0 : expected == 65 ? 28.0 : 48.0
                let caughtUp = expected == 130 && start == 10 ? nil : variable.first { frame in
                    frame.audioTime > changedAt && frame.beat.reliable && abs((frame.beat.bpm ?? 0) - expected) / expected < 0.06
                }?.audioTime
                rateChanges.append(["expectedBPM": expected, "selectedBPM": median,
                    "rawBPM": raw[raw.count / 2], "preservesPitch": preservePitch, "weakSubdivisions": hats,
                    "afterSwitchSeconds": caughtUp.map { $0 - changedAt } as Any? ?? NSNull()])
                print("Variable tempo: \(expected) BPM -> \(median), raw \(raw[raw.count/2])")
            }
        }
        for bpm in [60.0, 75, 90, 120, 160, 180, 240, 320, 360] {
            let frames = stream(bpm: bpm)
            precondition(frames.allSatisfy { $0.beat.engine == .aubio }, "The default PCM path must actually use aubio")
            let locked = frames.filter { $0.beat.reliable }
            precondition(!locked.isEmpty, "Regular percussion must acquire an aubio grid")
            let estimate = locked.last!.beat.bpm!
            let exact = abs(estimate - bpm) / bpm < 0.05
            precondition(exact, "Regular percussion after scale correction should be within five percent")
            precondition(locked.allSatisfy { frame in
                let beat = frame.beat.lastBeatTime!
                return beat <= frame.audioTime && frame.audioTime - beat <= 2
            }, "aubio's grid stays on the actual PCM sample clock")
            measurements.append(["inputBPM": bpm, "estimatedBPM": estimate,
                "firstLockSeconds": locked.first!.audioTime, "exactWithinFivePercent": exact,
                "rawConfidence": frames.last!.beat.confidence])
            print("Aubio: \(bpm) -> \(estimate) BPM, first lock \(locked.first!.audioTime)s")
        }
        precondition(stream(bpm: 120, duration: 12, musical: false).allSatisfy { !$0.beat.reliable },
                     "Speech context may not publish musical tempo")
        let briefGap = stream(bpm: 120, duration: 16, contextGap: 10...10.8)
        let uncertain = briefGap.filter { (10.1...10.7).contains($0.audioTime) }
        precondition(uncertain.allSatisfy { !$0.beat.reliable }, "Uncertain contexts suppress tempo output")
        precondition(briefGap.contains { (10.9...11.7).contains($0.audioTime) && $0.beat.reliable },
                     "A brief classifier gap must resume the grid without another eight-second warm-up")
        let stopped = stream(bpm: 120, duration: 20, stopAt: 12)
        precondition(stopped.contains { $0.beat.reliable } && !stopped.last!.beat.reliable,
                     "Aubio's predicted grid must not keep inventing beats after silence")
        let quiet = stream(bpm: 120, duration: 12, stopAt: 0)
        precondition(quiet.allSatisfy { !$0.beat.reliable }, "Silence cannot acquire a tempo")
        let device = stream(bpm: 120, rate: 48_000, duration: 16).last!.beat
        precondition(device.engine == .aubio && device.reliable && abs(device.bpm! - 120) < 6,
                     "Device sample rates must resample into the same aubio clock")
        for (bpm, preservePitch) in [(90.0, true), (160.0, false)] {
            let frames = stream(bpm: bpm, duration: 28, doubleAt: 10, preservePitch: preservePitch)
            let before = frames.last { $0.audioTime < 10 && $0.beat.reliable }!.beat.bpm!
            let after = frames.last { $0.beat.reliable }!.beat.bpm!
            precondition(abs(after - bpm * 2) / (bpm * 2) < 0.05)
            if bpm == 90 {
                precondition(abs(after - 180) < 9, "90 to 180 BPM PCM playback must replace the old aubio estimate")
                var body = SingingPerformance(), previousDuration = 0.0
                for frame in frames {
                    let time = frame.audioTime
                    let scene = SoundScene(kind: .singing, singing: 0.9, music: 0.9, audioTime: floor(time * 2) / 2)
                    _ = body.sample(scene: scene, level: 0.3, at: time, beat: frame.beat)
                    precondition(SingingTimeline.cycleDurationRange.contains(body.cycleDuration))
                    if time < 10 { previousDuration = body.cycleDuration }
                }
                precondition(abs(body.cycleDuration - previousDuration) < 0.25,
                             "90 to 180 BPM should preserve body speed by assigning two beats per segment")
            }
            measurements.append(["inputBPM": bpm, "doubledInputBPM": bpm * 2,
                "beforeEstimate": before, "afterEstimate": after, "preservesPitch": preservePitch,
                "exactWithinFivePercent": abs(after - bpm * 2) / (bpm * 2) < 0.05])
        }
        // Switch in place; old phase and confidence must not leak into a fresh
        // detector, and switching must not affect the independent lip pipeline.
        let analyzer = LiveLipAnalyzer()
        for index in 0..<16_000 * 16 {
            let time = Double(index) / 16_000
            analyzer.scene = SoundScene(kind: .music, music: 0.9, audioTime: time)
            let pulse = 0.4 * exp(-time.truncatingRemainder(dividingBy: 0.5) * 65) * sin(2 * .pi * 100 * time)
            _ = analyzer.consume(Float(pulse), sampleRate: 16_000)
        }
        for engine in [TempoEngine.spectral, .aubio] {
            analyzer.tempoEngine = engine
            var frame: LiveLipFrame?
            for index in 0..<640 {
                let time = 16 + Double(index) / 16_000
                analyzer.scene = SoundScene(kind: .music, music: 0.9, audioTime: time)
                frame = analyzer.consume(0, sampleRate: 16_000) ?? frame
            }
            precondition(frame!.beat.engine == engine && !frame!.beat.reliable,
                         "Changing detector starts a fresh grid without old confidence")
        }
        let report: [String: Any] = ["passed": true, "engine": "aubio 0.4.9",
            "PCMRate": 16_000, "hopSamples": 128, "windowSamples": 1024,
            "measurements": measurements, "continuousRateChanges": rateChanges, "scope": "Synthetic streaming PCM, not a real-song accuracy benchmark"]
        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("output/deepseek-singing/aubio-tempo-validation.json")
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        print("PASS: native aubio tempo (PCM grid, 90→180 speed change, bounded body speed, silence expiry, speech gate, device rates, detector switching; harmonic correction and repeated 1x/2x/0.5x switches)")
    }
}
