import Foundation
import CaptionCore

enum MouthTransitionChecks {
    static func run() {
        func feed(_ player: inout MouthPosePlayer, from start: Double, through end: Double,
                  shape: (Double) -> MouthShape, fps: Double = 60, confidence: Float = 0.9) -> [(Double, MouthShape)] {
            (Int((start * fps).rounded())...Int((end * fps).rounded())).map { tick in
                let now = Double(tick) / fps
                return (now, player.sample(shape(now), observedAt: floor(now * 50 + 1e-8) / 50,
                                          confidence: confidence, at: now))
            }
        }
        var player = MouthPosePlayer()
        let held = feed(&player, from: 0, through: 2, shape: { _ in .ah })
        precondition(held.contains { $0.1 == .slight } && held.contains { $0.1 == .eh })
        precondition(held.filter { $0.0 >= 0.4 }.allSatisfy { $0.1 == .ah })
        precondition(player.transitionsStarted == 1, "Long vowels never restart or loop")
        // Confident 20/40 ms errors, including closed/rest, cannot chop a long vowel.
        let noisy = feed(&player, from: 2.02, through: 4, shape: { now in
            let tick = Int((now * 50).rounded()) % 25
            return tick == 3 ? .ee : tick == 8 ? .closed : tick == 13 ? .rest : .ah
        })
        precondition(noisy.allSatisfy { $0.1 == .ah }, "Short errors and dropouts must retain a long vowel")
        let stopped = feed(&player, from: 4.02, through: 4.6, shape: { _ in .rest })
        precondition(stopped.filter { $0.0 >= 4.4 }.allSatisfy { $0.1 == .rest })
        precondition(stopped.contains { $0.1 == .slight }, "Release closes through an existing small opening")

        // Confirmation is acoustic evidence, never repeated polling of one frame.
        player = MouthPosePlayer()
        _ = player.sample(.oo, observedAt: 0, confidence: 0.9, at: 0)
        _ = player.sample(.oo, observedAt: 0, confidence: 0.9, at: 0.1)
        precondition(!player.isTransitioning && player.displayed == .rest)
        _ = player.sample(.oo, observedAt: 0.08, confidence: 0.9, at: 0.10)
        precondition(!player.isTransitioning, "A capture gap cannot manufacture continuity")
        _ = player.sample(.oo, observedAt: 0.10, confidence: 0.9, at: 0.10)
        _ = player.sample(.oo, observedAt: 0.12, confidence: 0.9, at: 0.12)
        _ = player.sample(.oo, observedAt: 0.14, confidence: 0.9, at: 0.14)
        _ = player.sample(.oo, observedAt: 0.16, confidence: 0.9, at: 0.16)
        precondition(player.isTransitioning)
        for now in [0.3, 0.45, 0.6] { _ = player.sample(.oo, observedAt: 0.16, confidence: 0.9, at: now) }
        precondition(player.displayed == .rest && !player.isTransitioning, "Expired PCM relaxes without reopening")
        let starts = player.transitionsStarted
        _ = player.sample(.ah, observedAt: .nan, confidence: 1, at: 0.61)
        _ = player.sample(.ah, observedAt: 0.9, confidence: 1, at: 0.62)
        _ = player.sample(.ah, observedAt: 0.61, confidence: 1, at: 0.60)
        precondition(player.displayed == .rest && starts == player.transitionsStarted)

        // Independent latest candidate, natural bridge ordering and target dwell.
        player = MouthPosePlayer()
        _ = feed(&player, from: 0, through: 0.5, shape: { _ in .ah })
        let route = feed(&player, from: 0.52, through: 1.3, shape: { _ in .oo })
        let sequence = route.map(\.1).reduce(into: [MouthShape]()) { result, shape in
            if result.last != shape { result.append(shape) }
        }
        precondition(sequence == [.ah, .eh, .oh, .oo], "Wide to round uses single-mouth bridges")
        let transient = feed(&player, from: 1.32, through: 1.36, shape: { _ in .ee })
        precondition(transient.allSatisfy { $0.1 == .oo })
        let closure = feed(&player, from: 1.38, through: 1.8, shape: { _ in .closed })
        precondition(closure.last?.1 == .closed, "A sustained actual closure remains visible")
        _ = feed(&player, from: 1.82, through: 2.5, shape: { _ in .ah })
        precondition(player.displayed == .ah)

        var cases: [[String: Any]] = []
        for fps in [30.0, 60, 120] {
            for interval in [0.02, 0.04, 0.10, 0.16, 0.24, 0.32] {
                player = MouthPosePlayer()
                let shapes: [MouthShape] = [.ah, .oo, .ee, .eh]
                let poses = feed(&player, from: 0, through: 6.6, shape: { now in
                    now < 6 ? shapes[Int((floor(now * 50) / 50) / interval) % shapes.count] : .rest
                }, fps: fps)
                var changes: [Double] = []
                for (previous, next) in zip(poses, poses.dropFirst()) where previous.1 != next.1 { changes.append(next.0) }
                precondition(zip(changes, changes.dropFirst()).allSatisfy { $1 - $0 + 1e-8 >= 0.14 },
                             "Every visible bridge, closure and target obeys the cadence")
                let maxPerSecond = changes.map { first in changes.filter { $0 >= first && $0 < first + 1 - 1e-8 }.count }.max() ?? 0
                precondition(maxPerSecond <= 8, "Never switch a dozen times per second at \(fps) Hz")
                precondition(poses.contains { $0.0 < 1 && $0.1 != .rest && $0.1 != .closed },
                             "Continuous rapid speech must open even without a stable vowel")
                precondition(poses.filter { $0.0 >= 6.4 }.allSatisfy { $0.1 == .rest }, "No queued mouth after silence")
                cases.append(["fps": fps, "inputChangeMs": interval * 1000,
                              "visibleChanges": changes.count, "maxChangesInOneSecond": maxPerSecond])
            }
        }
        // A delayed UI tick advances one bridge, never catches up several frames.
        player = MouthPosePlayer()
        _ = feed(&player, from: 0, through: 0.1, shape: { _ in .ah })
        precondition(player.sample(.ah, at: 1) == .eh)
        precondition(player.sample(.ah, at: 1.01) == .eh)
        precondition(player.sample(.ah, at: 1.15) == .ah)
        // Rapid speech resumes after a short dropout: onset evidence starts anew.
        player = MouthPosePlayer()
        let resumed = feed(&player, from: 0, through: 1, shape: { now in
            if (0.06..<0.10).contains(now) { return .rest }
            return Int(now * 50) % 2 == 0 ? .ah : .ee
        })
        precondition(resumed.filter { $0.0 >= 0.5 }.allSatisfy { $0.1 == .slight },
                     "A dropout cannot permanently disable the rapid-speech opening")
        let report: [String: Any] = ["passed": true, "cases": cases,
            "minimumVisiblePoseMs": 140, "destinationHoldMs": 220,
            "checks": ["long vowel hold", "transient closure/dropout rejected", "natural bridges",
                       "real closure", "polling is not evidence", "stale and invalid PCM", "no catch-up burst"],
            "scope": "Controlled input/controller checks; not language phoneme accuracy"]
        let url = URL(fileURLWithPath: "output/lip-sustain/controller-validation.json")
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("PASS: held vowels, confirmed closures, natural bridges, <=8 visible changes/s at 30/60/120 Hz")
    }
}
