import Foundation
import AVFoundation
import SoundAnalysis

@main enum LaughterModelChecks {
    static func main() throws {
        let rate = 16_000.0
        let path = CommandLine.arguments[1]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let pcm: [Float] = data.withUnsafeBytes { bytes in Array(bytes.bindMemory(to: Float.self)) }
        precondition(pcm.count > 16_000 && pcm.allSatisfy(\.isFinite))
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        precondition(Set(SoundSceneTracker.laughterLabels).isSubset(of: Set(request.knownClassifications)))
        let classifier = SoundContextClassifier(sampleRate: rate)
        defer { classifier.stop() }
        let analyzer = LiveLipAnalyzer(trackTempo: false)
        var player = MouthPosePlayer(), prior = BeforeMouthPosePlayer()
        var observations = [[String: Any]](), scenes = [[String: Any]]()
        var oldChanges = [Double](), newChanges = [Double](), previous = MouthShape.rest, oldPrevious = MouthShape.rest
        var firstLaughter: Double?, firstScheduled: Double?, activeFrames = 0, decisions = 0
        let duration = Double(pcm.count) / rate
        // 100 ms submissions and real-time pacing exercise the existing queue,
        // not an unbounded offline feed that would trigger deliberate drops.
        for block in 0..<Int((duration + 1.5) * 10) {
            let scene = classifier.snapshot()
            analyzer.scene = scene
            scenes.append(["time": Double(block) / 10, "kind": scene.kind.rawValue, "laughter": scene.laughter,
                           "speech": scene.speech, "singing": scene.singing, "music": scene.music, "sceneTime": scene.audioTime])
            var samples = [Float](); samples.reserveCapacity(1600)
            for offset in 0..<1600 {
                let index = block * 1600 + offset
                let sample: Float = index < pcm.count ? pcm[index] : 0
                samples.append(sample)
                if var frame = analyzer.consume(sample, sampleRate: rate) {
                    let time = Double(index + 1) / rate
                    frame.capturedAt = time
                    let old = prior.sample(frame, at: time), new = player.sample(frame, at: time)
                    if frame.laughterPriority { activeFrames += 1; if firstLaughter == nil { firstLaughter = time } }
                    if player.laughterPriorityActive && firstScheduled == nil { firstScheduled = time }
                    if old != oldPrevious { oldChanges.append(time); oldPrevious = old }
                    if new != previous { newChanges.append(time); previous = new }
                    decisions += 1
                    observations.append(["time": time, "rawShape": frame.shape.rawValue, "before": old.rawValue, "after": new.rawValue,
                        "priority": frame.laughterPriority, "scheduled": player.laughterPriorityActive, "scene": frame.scene.kind.rawValue])
                }
            }
            classifier.submit(samples)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        precondition(activeFrames >= 10, "The real system model must detect audible laughter in this recording")
        precondition(firstScheduled != nil && firstScheduled! - firstLaughter! <= 0.061, "Model-confirmed laughter gets scheduling priority within 40–60 ms of fresh audio")
        precondition(observations.suffix(8).allSatisfy { ($0["after"] as! Int) == 0 && !($0["priority"] as! Bool) }, "Recorded laughter must finish naturally at rest")
        let maximum = newChanges.map { first in newChanges.filter { $0 >= first && $0 < first + 1 - 1e-8 }.count }.max() ?? 0
        precondition(maximum <= 8)
        var processing = [[String: Any]]()
        // Repeat the exact real PCM at 16 kHz: full DSP + player cost, model/UI
        // excluded. Cold setup and three 30-second rounds are reported separately.
        for version in ["before", "after"] {
            var times = [Double](), cold = 0.0, counts = [Int]()
            for round in 0..<3 {
                let start = ProcessInfo.processInfo.systemUptime
                let old = version == "before" ? BeforeLiveLipAnalyzer(trackTempo: false) : nil
                let new = version == "after" ? LiveLipAnalyzer(trackTempo: false) : nil
                var oldPlayer = BeforeMouthPosePlayer(), newPlayer = MouthPosePlayer(), count = 0
                let hint = SoundScene(kind: .laughter, laughter: 0.9)
                for index in 0..<480_000 {
                    let time = Double(index + 1) / rate
                    // Identical current contexts isolate the new laughter policy.
                    let fresh = SoundScene(kind: hint.kind, laughter: hint.laughter, audioTime: floor(time * 2) / 2)
                    if index % 1600 == 0 { old?.scene = fresh; new?.scene = fresh }
                    let frame = old?.consume(pcm[index % pcm.count], sampleRate: rate)
                        ?? new?.consume(pcm[index % pcm.count], sampleRate: rate)
                    if var frame {
                        frame.capturedAt = time
                        if old != nil { _ = oldPlayer.sample(frame, at: time) }
                        else { _ = newPlayer.sample(frame, at: time) }
                        count += 1
                    }
                    if round == 0 && index == 1023 { cold = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                }
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000); counts.append(count)
            }
            processing.append(["version": version, "audioSeconds": 30, "decisions": counts,
                               "coldSetupAndFirstWindowMs": cold, "processingMs": times, "medianMs": times.sorted()[1]])
        }
        let report: [String: Any] = ["passed": true, "fixtureSeconds": duration, "analysisFrames": decisions,
            "laughterPriorityFrames": activeFrames, "firstPriorityAudioTime": firstLaughter!, "firstScheduledAudioTime": firstScheduled!,
            "maxVisibleChangesPerSecond": maximum, "processing": processing, "observations": scenes,
            "supportedLabels": SoundSceneTracker.laughterLabels,
            "scope": "One public-domain real laughter recording via genuine SoundAnalysis; scheduling/cadence and cost, not population accuracy"]
        let folder = URL(fileURLWithPath: "output/laughter-priority")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("model-validation.json"))
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("model-mouth-trace.json"))
        print("PASS: real laughter \(activeFrames) priority frames; first schedule delay \((firstScheduled! - firstLaughter!) * 1000) ms; max \(maximum) changes/s")
        print("Processing: \(processing)")
    }
}
