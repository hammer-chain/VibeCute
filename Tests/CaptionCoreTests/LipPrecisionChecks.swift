import Foundation
import CaptionCore

/// Known source-filter fixtures measure regressions, not real speech accuracy.
enum LipPrecisionChecks {
    static func run() {
        let baseline = ProcessInfo.processInfo.environment["LIP_PRECISION_BASELINE"] == "1"
        let probe = ProcessInfo.processInfo.environment["LIP_PRECISION_PROBE"] == "1"
        let rate = 16_000.0
        func vowel(_ f1: Double, _ f2: Double, pitch: Double = 125, gain: Double = 1) -> (Double) -> Float {
            let harmonics = (1...Int(4400 / pitch)).map { n -> (Double, Double) in
                let frequency = Double(n) * pitch
                let amplitude = exp(-pow((frequency - f1) / 150, 2))
                    + 0.65 * exp(-pow((frequency - f2) / 250, 2))
                return (frequency, amplitude * 0.045 * gain)
            }
            return { t in Float(harmonics.reduce(0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) }) }
        }
        func feed(_ analyzer: LiveLipAnalyzer, duration: Double, signal: (Double) -> Float) -> [LiveLipFrame] {
            (0..<Int(duration * rate)).compactMap { analyzer.consume(signal(Double($0) / rate), sampleRate: rate) }
        }
        var transitions: [[String: Any]] = []
        let pairs: [(MouthShape, Double, Double)] = [(.ah, 750, 1250), (.ee, 300, 2400), (.oo, 300, 700)]
        for from in pairs {
            for to in pairs where from.0 != to.0 {
                let analyzer = LiveLipAnalyzer()
                analyzer.scene = SoundScene(kind: .speech, speech: 0.9)
                _ = feed(analyzer, duration: 0.4, signal: vowel(from.1, from.2))
                let frames = feed(analyzer, duration: 0.12, signal: vowel(to.1, to.2))
                let delay = frames.first { $0.shape == to.0 }.map { ($0.audioTime - 0.4) * 1000 }
                transitions.append(["from": from.0.title, "to": to.0.title, "delayMs": delay as Any? ?? NSNull(),
                    "shapes": frames.map { $0.shape.title }, "f1": frames.map { $0.firstFormant ?? 0 }, "f2": frames.map { $0.secondFormant ?? 0 }])
                if !baseline && !probe { precondition(delay != nil && delay! <= 105, "120 ms vowel must appear in time: \(from.0) -> \(to.0), \(String(describing: delay))") }
            }
        }
        var quiet: [[String: Any]] = []
        for pair in pairs {
            let analyzer = LiveLipAnalyzer()
            analyzer.scene = SoundScene(kind: .speech, speech: 0.9)
            _ = feed(analyzer, duration: 0.4, signal: vowel(pair.1, pair.2))
            let frames = feed(analyzer, duration: 0.4, signal: vowel(pair.1, pair.2, gain: 0.15)).suffix(10)
            let expected: Set<MouthShape> = pair.0 == .ee ? [.ee, .narrow] : pair.0 == .ah ? [.ah, .slight] : [pair.0]
            let retained = frames.filter { expected.contains($0.shape) }.count
            quiet.append(["vowel": pair.0.title, "retainedFrames": retained, "frames": frames.count,
                          "shapes": frames.map { $0.shape.title }])
            if !baseline && !probe { precondition(retained >= 8, "A falling level must retain the vowel family: \(pair.0)") }
        }
        var pitches: [[String: Any]] = []
        for pitch in [100.0, 125, 175, 225] {
            let analyzer = LiveLipAnalyzer()
            analyzer.scene = SoundScene(kind: .singing, singing: 0.9)
            let frames = feed(analyzer, duration: 0.6, signal: vowel(750, 1250, pitch: pitch)).suffix(15)
            let correct = frames.filter { $0.shape == .ah }.count
            pitches.append(["pitchHz": pitch, "correctFrames": correct, "frames": frames.count,
                "shapes": frames.map { $0.shape.title }, "f1": frames.last?.firstFormant ?? 0, "f2": frames.last?.secondFormant ?? 0])
            if !baseline && !probe { precondition(correct >= 12, "Sustained ah must not change with pitch: \(pitch)") }
        }
        let benchmarkSignal = vowel(750, 1250)
        let pcm = (0..<16_000).map { benchmarkSignal(Double($0) / rate) }
        let benchmarkAnalyzer = LiveLipAnalyzer()
        let started = ProcessInfo.processInfo.systemUptime
        var decisions = 0
        for i in 0..<160_000 {
            if benchmarkAnalyzer.consume(pcm[i % pcm.count], sampleRate: rate) != nil { decisions += 1 }
        }
        let processingMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let report: [String: Any] = ["fixture": "Synthetic harmonic vowels; no real-language or song accuracy claim",
            "transitions120ms": transitions, "quietVowelsAfterLoud": quiet, "sustainedAhPitches": pitches,
            "processing": ["audioSeconds": 10, "decisions": decisions, "processingMs": processingMs,
                "scope": "Analyzer only, excludes signal generation, capture, model and UI"]]
        let url = URL(fileURLWithPath: "output/lip-precision/\(baseline ? "before" : probe ? "probe" : "after").json")
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("Lip precision \(baseline ? "baseline" : "checks"): \(transitions.map { ["from": $0["from"]!, "to": $0["to"]!, "delayMs": $0["delayMs"]!] })")
        if !baseline { checkDelivery() }
    }

    private static func checkDelivery() {
        let analyzer = LiveLipAnalyzer()
        let frequencies: [Double] = [625, 750, 875, 1125, 1250, 1375]
        let frames: [LiveLipFrame] = (0..<16_000).compactMap { index -> LiveLipFrame? in
            let t = Double(index) / 16_000
            var value: Double = 0
            if t <= 0.5 { for frequency in frequencies { value += 0.03 * sin(2 * Double.pi * frequency * t) } }
            return analyzer.consume(Float(value), sampleRate: 16_000)
        }
        var open = frames.first { $0.shape == .ah }!
        var closed = frames.first { $0.shape == .closed }!
        var mailbox = LiveLipMailbox()
        open.capturedAt = 1; mailbox.publish(open)
        closed.capturedAt = 1.02; mailbox.publish(closed)
        open.capturedAt = 1.04; mailbox.publish(open)
        precondition(mailbox.snapshot(at: 1.05).shape == .closed, "One callback cannot erase an unpresented closure")
        precondition(mailbox.snapshot(at: 1.06).shape == .ah, "Deliver latest vowel without replaying old results")
        closed.capturedAt = 1.01; mailbox.publish(closed)
        precondition(mailbox.snapshot(at: 1.07).shape == .ah, "Reject out-of-order audio results")
        precondition(mailbox.snapshot(at: 1.17).shape == .rest, "Expire on sample capture time, not callback completion")
        closed.capturedAt = Double.nan; mailbox.publish(closed)
        precondition(mailbox.snapshot(at: 1.18).shape == .rest)
        closed.capturedAt = 2; mailbox.publish(closed)
        open.capturedAt = 2.04; mailbox.publish(open)
        precondition(mailbox.snapshot(at: 2.08).shape == .ah, "Never replay an expired closure")
        closed.capturedAt = 3; mailbox.publish(closed)
        var rest = LiveLipFrame.silence; rest.capturedAt = 3.02; mailbox.publish(rest)
        precondition(mailbox.snapshot(at: 3.04).shape == .rest, "Silence cancels queued closure")
        precondition(mailbox.snapshot(at: .nan).shape == .rest)
        print("PASS: capture-clock delivery, stale and out-of-order rejection, short closure retention")
    }
}
