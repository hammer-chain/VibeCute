import Foundation
@testable import CaptionCore

enum LaughterChecks {
    static func run() {
        for label in SoundSceneTracker.laughterLabels {
            let tracker = SoundSceneTracker()
            _ = tracker.receive(["music": 0.9], at: 0)
            let scene = tracker.receive([label: 0.8, "speech": 0.9, "singing": 0.95, "music": 0.95], at: 0.5)!
            precondition(scene.kind == .laughter && scene.vocal >= 0.8, "First strong \(label) outranks ordinary labels")
            precondition(scene.fresh(at: 1.31).kind == .warming, "Laughter expires in 800 ms")
            let next = tracker.receive(["music": 0.9], at: 1)!
            precondition(next.kind != .laughter && next.laughter == 0, "No smoothed laughter tail after new evidence")
        }
        let weak = SoundSceneTracker()
        precondition(SoundSceneTracker().receive(["giggling": 0.3, "speech": 0.95], at: 0)!.kind != .laughter,
                     "Cold start or strong speech cannot accidentally promote weak laughter")
        _ = weak.receive(["music": 0.9], at: 0)
        let uncertain = weak.receive(["giggling": 0.3], at: 0.5)!
        precondition(uncertain.kind != .laughter && uncertain.vocal == 0,
                     "One weak laugh result cannot bypass the music voice gate")
        precondition(weak.receive(["giggling": 0.3], at: 1)!.kind == .laughter)
        precondition(weak.receive(["laughter": .nan], at: 1.5)!.laughter == 0)
        precondition(weak.receive(["laughter": 1], at: 1.4) == nil)

        let analyzer = LiveLipAnalyzer(trackTempo: false)
        analyzer.scene = SoundScene(kind: .laughter, music: 0.9, laughter: 0.9)
        func feed(seconds: Double, signal: (Double) -> Float) -> [LiveLipFrame] {
            (0..<Int(seconds * 16_000)).compactMap { analyzer.consume(signal(Double($0) / 16_000), sampleRate: 16_000) }
        }
        precondition(feed(seconds: 0.3, signal: { _ in 0 }).allSatisfy { !$0.laughterPriority && $0.shape == .rest },
                     "A laugh label alone cannot animate silence")
        // A known vowel-like burst establishes PCM activity, with classifier hints
        // testing policy independently of real laughter-model accuracy.
        let frequencies: [Double] = [625, 750, 875, 1125, 1250, 1375]
        let bursts = feed(seconds: 0.45) { t in
            if t.truncatingRemainder(dividingBy: 0.16) > 0.12 { return 0 }
            return Float(frequencies.reduce(0) { $0 + 0.04 * sin(2 * .pi * $1 * t) })
        }
        precondition(bursts.filter(\.laughterPriority).count > bursts.count / 2, "Confirmed laugh survives audible breathing gaps and music")
        precondition(bursts.filter(\.laughterPriority).allSatisfy { [.ah, .eh].contains($0.shape) }, "Laugh uses coherent open-mouth shapes")
        let quiet = feed(seconds: 0.25, signal: { _ in 0 })
        precondition(quiet.suffix(4).allSatisfy { !$0.laughterPriority && $0.shape == .rest })

        func frame(_ shape: MouthShape, at time: Double, laugh: Bool) -> LiveLipFrame {
            var frame = LiveLipFrame(shape: shape, level: 0.3, voiceLike: true, confidence: 0.9,
                audioTime: time, firstFormant: nil, secondFormant: nil,
                scene: SoundScene(kind: laugh ? .laughter : .speech, speech: laugh ? 0 : 0.9, laughter: laugh ? 0.9 : 0), voiceGateOpen: true)
            frame.capturedAt = time; frame.laughterPriority = laugh
            return frame
        }
        var metrics = [[String: Any]]()
        for fps in [30.0, 60, 120] {
            var player = MouthPosePlayer(), previous = MouthShape.rest, changes = [Double]()
            var preempted = false, ordinaryWasActive = false, laughAt: Double?
            for tick in 0...Int(fps * 2.6) {
                let now = Double(tick) / fps, captured = floor(now * 50 + 1e-8) / 50
                let laugh = captured >= 0.26 && captured < 1.6
                let target: MouthShape = captured < 0.26 ? .oo : laugh ? .ah : .rest
                if captured < 0.26 && player.transitionTarget == .oo { ordinaryWasActive = true }
                let pose = player.sample(frame(target, at: captured, laugh: laugh), at: now)
                if player.laughterPriorityActive && player.transitionTarget != .oo { preempted = true }
                if pose == .ah && laughAt == nil { laughAt = now }
                if pose != previous { changes.append(now); previous = pose }
                if now >= 2.1 { precondition(pose == .rest, "Laugh finishes without a stale ordinary target") }
            }
            precondition(ordinaryWasActive && preempted && laughAt != nil && laughAt! < 0.8,
                         "Laugh replaces an in-progress ordinary vowel without its destination dwell")
            precondition(zip(changes, changes.dropFirst()).allSatisfy { $1 - $0 >= 0.14 - 1e-8 })
            let maximum = changes.map { first in changes.filter { $0 >= first && $0 < first + 1 - 1e-8 }.count }.max() ?? 0
            precondition(maximum <= 8)
            metrics.append(["fps": fps, "laughTargetReachedAt": laughAt!, "maxVisibleChangesPerSecond": maximum])
        }
        var mailbox = LiveLipMailbox()
        mailbox.publish(frame(.closed, at: 1, laugh: false))
        mailbox.publish(frame(.ah, at: 1.02, laugh: true))
        precondition(mailbox.snapshot(at: 1.03).laughterPriority, "A queued ordinary closure cannot delay laughter")
        var singing = SingingPerformance()
        for i in 0..<100 {
            let t = Double(i) / 10
            _ = singing.sample(scene: SoundScene(kind: .laughter, singing: 0.9, laughter: 0.8, audioTime: t), level: 0.3, at: t)
        }
        precondition(singing.phase == .seated, "Laughter with a competing singing score cannot initiate singing")
        let report: [String: Any] = ["passed": true, "labels": SoundSceneTracker.laughterLabels, "scheduling": metrics,
            "checks": ["strong laugh has first-result priority", "weak label needs confirmation", "freshness and silence", "audible burst breath hold", "ordinary closure discarded", "singing veto", "global visible cadence"],
            "scope": "Controlled model scores and synthetic PCM; real-model detection tested separately"]
        let folder = URL(fileURLWithPath: "output/laughter-priority")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("core-validation.json"))
        print("PASS: laughter recognition priority, audible PCM gate, natural preemption, no singing false trigger and <=8 changes/s")
    }
}
