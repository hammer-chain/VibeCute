import Foundation

@main enum LipSustainChecks {
    static let rate = 16_000.0
    static func main() throws {
        let folder = URL(fileURLWithPath: "output/lip-sustain")
        var cases: [[String: Any]] = []
        var timeline: [[String: Any]] = []
        // Identical timestamped observations isolate visual scheduling from DSP.
        for interval in [0.04, 0.16, 0.24] {
            var old = MainMouthPosePlayer(), new = MouthPosePlayer()
            var rows = [(Double, MouthShape, MouthShape)]()
            for tick in 0...330 {
                let now = Double(tick) / 50
                let shapes: [MouthShape] = [.ah, .oo, .ee, .eh]
                let shape: MouthShape = now < 0.8 ? .ah : now < 5.8 ? shapes[Int((now - 0.8) / interval) % 4] : .rest
                let before = old.sample(shape, observedAt: now, confidence: 0.9, at: now)
                let after = new.sample(shape, observedAt: now, confidence: 0.9, at: now)
                rows.append((now, before, after))
                if interval == 0.16 { timeline.append(["time": now, "target": shape.rawValue, "before": before.rawValue, "after": after.rawValue]) }
            }
            let oldChanges = changes(rows.map { ($0.0, $0.1) }), newChanges = changes(rows.map { ($0.0, $0.2) })
            precondition(maxPerSecond(newChanges) <= 8)
            cases.append(["inputChangeMs": interval * 1000, "mainMaxChangesPerSecond": maxPerSecond(oldChanges),
                          "newMaxChangesPerSecond": maxPerSecond(newChanges), "mainChanges": oldChanges.count, "newChanges": newChanges.count])
        }
        // Harmonic source-filter PCM with 5 Hz vibrato, changing loudness and
        // genuine 20 ms dropouts: a held vowel must not become repeated syllables.
        var acoustic = [[String: Any]]()
        for (name, f1, f2, gain) in [("ah", 750.0, 1250.0, 0.13), ("ee", 300, 2400, 0.20), ("oo", 300, 700, 0.4)] {
            let pcm = vowel(f1: f1, f2: f2, gain: gain, seconds: 4, modulate: true)
            let old = MainLiveLipAnalyzer(trackTempo: false), new = LiveLipAnalyzer(trackTempo: false)
            old.scene = SoundScene(kind: .speech, speech: 0.9); new.scene = old.scene
            var oldPlayer = MainMouthPosePlayer(), newPlayer = MouthPosePlayer()
            var oldPoses = [(Double, MouthShape)](), newPoses = [(Double, MouthShape)]()
            var rawBefore = [MouthShape](), rawAfter = [MouthShape]()
            for (index, sample) in pcm.enumerated() {
                let before = old.consume(sample, sampleRate: rate), after = new.consume(sample, sampleRate: rate)
                if var before, var after {
                    let now = Double(index + 1) / rate
                    before.capturedAt = now; after.capturedAt = now
                    oldPoses.append((now, oldPlayer.sample(before, at: now)))
                    newPoses.append((now, newPlayer.sample(after, at: now)))
                    if now > 0.8 { rawBefore.append(before.shape); rawAfter.append(after.shape) }
                }
            }
            let settled = newPoses.filter { $0.0 > 0.8 }
            precondition(settled.allSatisfy { $0.1 != .closed && $0.1 != .rest }, "Modulated \(name) must stay open")
            precondition(maxPerSecond(changes(newPoses)) <= 8)
            acoustic.append(["vowel": name, "audioSeconds": 4,
                "rawMainChanges": zip(rawBefore, rawBefore.dropFirst()).filter { $0 != $1 }.count,
                "rawNewChanges": zip(rawAfter, rawAfter.dropFirst()).filter { $0 != $1 }.count,
                "mainVisibleChanges": changes(oldPoses).count, "newVisibleChanges": changes(newPoses).count,
                "newLongVowelClosures": settled.filter { $0.1 == .rest || $0.1 == .closed }.count])
        }
        let pcm = vowel(f1: 750, f2: 1250, gain: 1, seconds: 1, modulate: false)
        var performance = [[String: Any]]()
        for version in ["main", "new"] {
            var times = [Double](), decisionCounts = [Int](), coldMs = 0.0
            for round in 0..<3 {
                let start = ProcessInfo.processInfo.systemUptime
                let old = version == "main" ? MainLiveLipAnalyzer(trackTempo: false) : nil
                let new = version == "new" ? LiveLipAnalyzer(trackTempo: false) : nil
                var oldPlayer = MainMouthPosePlayer(), newPlayer = MouthPosePlayer(), decisions = 0
                for index in 0..<480_000 {
                    let frame = old?.consume(pcm[index % pcm.count], sampleRate: rate)
                        ?? new?.consume(pcm[index % pcm.count], sampleRate: rate)
                    if var frame {
                        frame.capturedAt = Double(index + 1) / rate
                        if old != nil { _ = oldPlayer.sample(frame, at: frame.capturedAt!) }
                        else { _ = newPlayer.sample(frame, at: frame.capturedAt!) }
                        decisions += 1
                    }
                    if round == 0 && index == 1023 { coldMs = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                }
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000); decisionCounts.append(decisions)
            }
            precondition(decisionCounts.allSatisfy { $0 == 1497 })
            performance.append(["version": version, "audioSecondsPerRound": 30, "decisions": decisionCounts,
                                "coldSetupAndFirstWindowMs": coldMs, "pipelineProcessingMs": times,
                                "medianMs": times.sorted()[1], "tempoTracking": false])
        }
        try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("before-after-trace.json"))
        let report: [String: Any] = ["passed": true, "controllerComparison": cases, "sustainedPCM": acoustic,
            "performance": performance, "scope": "Synthetic PCM + analyzer + player; excludes capture, sound model, UI and phoneme accuracy"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("comparison.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }

    static func changes(_ rows: [(Double, MouthShape)]) -> [Double] {
        zip(rows, rows.dropFirst()).compactMap { $0.1 != $1.1 ? $1.0 : nil }
    }
    static func maxPerSecond(_ changes: [Double]) -> Int {
        changes.map { first in changes.filter { $0 >= first && $0 < first + 1 - 1e-8 }.count }.max() ?? 0
    }
    static func vowel(f1: Double, f2: Double, gain: Double, seconds: Double, modulate: Bool) -> [Float] {
        let harmonics = (1...35).map { n -> (Double, Double) in
            let frequency = Double(n) * 125
            return (Double(n), exp(-pow((frequency - f1) / 150, 2)) + 0.65 * exp(-pow((frequency - f2) / 250, 2)))
        }
        var phase = 0.0
        return (0..<Int(seconds * rate)).map { index in
            let t = Double(index) / rate
            let pitch = modulate ? 125 + 8 * sin(2 * .pi * 5 * t) : 125
            phase += 2 * .pi * pitch / rate
            let amplitude = gain * (modulate ? 1 + 0.25 * sin(2 * .pi * 4 * t) : 1)
            let dropout = modulate && t > 0.8 && t.truncatingRemainder(dividingBy: 0.7) < 0.02
            return dropout ? 0 : Float(harmonics.reduce(0) { $0 + $1.1 * sin($1.0 * phase) } * 0.045 * amplitude)
        }
    }
}
