import Foundation
import AVFoundation

/// Native integration probe. Speech and accompaniment are generated in memory;
/// no audio file, microphone, playback or network service is involved.
@main enum SoundContextChecks {
    static func main() throws {
        let speech = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "This is a live voice test. The character should follow the person speaking while background music continues. A short pause should close the mouth. We are checking speech and music together.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        let collected = NSLock()
        var voice: [Float] = [], voiceRate = 0.0, complete = false
        speech.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            collected.lock(); defer { collected.unlock() }
            if pcm.frameLength == 0 { complete = true; return }
            guard let channel = pcm.floatChannelData?[0] else { return }
            voiceRate = pcm.format.sampleRate
            voice.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            collected.lock(); let done = complete; collected.unlock()
            if done { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(complete && voice.count > 16_000 && voiceRate > 0, "Local speech synthesis must return PCM")
        let rate = 16_000.0
        let normalized: [Float] = (0..<Int(Double(voice.count) / voiceRate * rate)).map { i in
            let index = min(voice.count - 1, Int(Double(i) / rate * voiceRate))
            return voice[index]
        }
        let peak = max(0.01, normalized.map { abs($0) }.max() ?? 1)
        let voicePCM = normalized.map { $0 / peak * 0.3 }
        let classifier = SoundContextClassifier(sampleRate: rate)
        defer { classifier.stop() }
        let priority = LiveLipAnalyzer(), baseline = LiveLipAnalyzer()
        baseline.voicePriority = false
        var observations: [[String: Any]] = []
        var totals: [String: [String: Int]] = [:]
        // Harmonic plucked arpeggio is intentionally a challenge for spectral VAD.
        func music(_ t: Double) -> Float {
            let notes = [261.63, 329.63, 392.0, 523.25, 440.0, 349.23, 293.66, 392.0]
            let step = Int(t / 0.25)
            var value = 0.0
            for offset in 0...5 where step >= offset {
                let age = t - Double(step - offset) * 0.25
                let frequency = notes[(step - offset) % notes.count]
                let decay = exp(-age * 3) * min(1, age * 150)
                for h in 1...7 {
                    value += decay * sin(2 * .pi * frequency * Double(h) * t) / pow(Double(h), 1.4)
                }
            }
            return Float(value * 0.07)
        }
        let segments: [(String, Double)] = [("speech", 5), ("music", 6), ("mixed", 8), ("silence", 3)]
        var position = 0
        for (name, duration) in segments {
            var counts = ["frames": 0, "baselineOpen": 0, "priorityOpen": 0, "freshContext": 0, "vocalContext": 0]
            for block in 0..<Int(duration * 10) {
                let samples: [Float] = (0..<1600).map { i in
                    let local = block * 1600 + i
                    let t = Double(local) / rate
                    let vocal = voicePCM[local % voicePCM.count]
                    switch name {
                    case "speech": return vocal
                    case "music": return music(t)
                    case "mixed": return vocal + music(t)
                    default: return 0
                    }
                }
                let scene = classifier.snapshot()
                priority.scene = scene
                for sample in samples {
                    if let raw = baseline.consume(sample, sampleRate: rate) {
                        if block >= 20 && raw.voiceLike { counts["baselineOpen"]! += 1 }
                    }
                    if let frame = priority.consume(sample, sampleRate: rate), block >= 20 {
                        counts["frames"]! += 1
                        if frame.voiceLike { counts["priorityOpen"]! += 1 }
                        if frame.scene.ready { counts["freshContext"]! += 1 }
                        if frame.scene.vocal >= 0.2 { counts["vocalContext"]! += 1 }
                    }
                }
                classifier.submit(samples)
                position += samples.count
                observations.append(["segment": name, "time": Double(position) / rate,
                    "kind": scene.kind.rawValue, "speech": scene.speech, "singing": scene.singing,
                    "music": scene.music, "instruments": scene.instruments, "sceneTime": scene.audioTime])
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            totals[name] = counts
            print("\(name): \(counts)")
        }
        precondition(totals["speech"]!["vocalContext"]! > 0, "Native model must recognize this speech fixture")
        precondition(totals["mixed"]!["priorityOpen"]! > 0, "Mixed voice must remain responsive")
        precondition(totals["music"]!["baselineOpen"]! > 0 && totals["music"]!["priorityOpen"]! < totals["music"]!["baselineOpen"]! / 4,
                     "Context should suppress this known instrumental false positive")
        precondition(totals["silence"]!["priorityOpen"]! == 0, "Silence must close mouth")
        let report: [String: Any] = ["fixtures": "In-memory English system TTS plus synthetic plucked arpeggio; not a real-song accuracy benchmark",
            "totalsAfterFirstTwoSeconds": totals, "observations": observations]
        let url = URL(fileURLWithPath: "output/audio-context-validation.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("PASS: native offline classifier, mixed-voice response, silence and streaming timestamps")
    }
}
