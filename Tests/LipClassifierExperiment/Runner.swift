import Foundation
import AVFoundation
import CaptionCore

@main enum LipClassifierExperiment {
    struct Clip {
        let language: String, voice: String, prompt: String, expected: MouthShape, split: String
        let samples: [Float], rate: Double
    }
    static func main() throws {
        setbuf(stdout, nil)
        let folder = URL(fileURLWithPath: "output/lip-classifier")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let prompts: [(String, String, [(String, MouthShape)])] = [
            ("ja-JP", "Kyoko", [("あ", .ah), ("い", .ee), ("う", .oo), ("え", .eh), ("お", .oh)]),
            ("zh-CN", "Tingting", [("啊", .ah), ("衣", .ee), ("乌", .oo), ("诶", .eh), ("哦", .oh)]),
            ("en-US", "Samantha", [("ah", .ah), ("ee", .ee), ("ooh", .oo), ("eh", .eh), ("oh", .oh)])
        ]
        var clips = [Clip]()
        for (language, name, vowels) in prompts {
            guard let trainingVoice = voices.first(where: { $0.language == language && $0.name == name }),
                  let heldOutVoice = voices.first(where: { $0.language == language && $0.identifier.lowercased().contains("reed") }) else {
                fatalError("Need installed training and held-out voices for \(language)")
            }
            for (voice, split, speed) in [(trainingVoice, "train", Float(0.25)),
                                           (trainingVoice, "sameVoiceFast", Float(0.55)),
                                           (heldOutVoice, "unseenVoice", Float(0.45))] {
                for (prompt, expected) in vowels {
                    let (pcm, rate) = synthesize(prompt, voice: voice, speed: speed)
                    clips.append(Clip(language: language, voice: voice.identifier, prompt: prompt,
                                      expected: expected, split: split, samples: pcm, rate: rate))
                }
            }
        }
        var templates = [LipVowelProfile.Template](), trainingRows = [[Float]]()
        for clip in clips where clip.split == "train" {
            let frames = analyze(clip, profile: nil, condition: "clean")
            let rows = frames.compactMap { $0.features }
            print("Training \(clip.language) \(clip.prompt): \(frames.count) central frames, \(rows.count) feature rows")
            precondition(rows.count >= 3, "Enough voiced training frames for \(clip.language) \(clip.prompt)")
            trainingRows += rows
            // Use two temporal centroids per voice/vowel, not test data.
            for half in [Array(rows.prefix((rows.count + 1) / 2)), Array(rows.suffix(rows.count / 2))] {
                let mean = (0..<LipMFCC.dimensions).map { d in half.reduce(Float.zero) { $0 + $1[d] } / Float(half.count) }
                templates.append(.init(shape: clip.expected, features: mean))
            }
        }
        let scale = (0..<LipMFCC.dimensions).map { d -> Float in
            let mean = trainingRows.reduce(Float.zero) { $0 + $1[d] } / Float(trainingRows.count)
            return max(1, sqrt(trainingRows.reduce(Float.zero) { $0 + pow($1[d] - mean, 2) } / Float(trainingRows.count)))
        }
        let profile = LipVowelProfile(scale: scale, templates: templates)
        precondition(profile.isValid)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: folder.appendingPathComponent("vowel-profile.json"))
        var reports = [[String: Any]]()
        for clip in clips where clip.split != "train" {
            for condition in ["clean", "quiet", "accompaniment", "reverb"] {
                let baseline = analyze(clip, profile: nil, condition: condition)
                let hybrid = analyze(clip, profile: profile, condition: condition)
                precondition(baseline.count == hybrid.count)
                let correctBefore = baseline.filter { family($0.frame.shape) == clip.expected }.count
                let correctAfter = hybrid.filter { family($0.frame.shape) == clip.expected }.count
                reports.append(["language": clip.language, "voice": clip.voice, "prompt": clip.prompt,
                    "expected": clip.expected.title, "split": clip.split, "condition": condition,
                    "frames": baseline.count, "baselineCorrect": correctBefore, "hybridCorrect": correctAfter,
                    "baselineShapes": baseline.map { $0.frame.shape.title }, "hybridShapes": hybrid.map { $0.frame.shape.title }])
            }
        }
        let groups = Dictionary(grouping: reports) { ($0["split"] as! String) + "/" + ($0["condition"] as! String) }
        let summaries = groups.keys.sorted().map { key -> [String: Any] in
            let rows = groups[key]!
            return ["group": key, "clips": rows.count,
                "baselineMeanClipAccuracy": rows.reduce(0.0) { $0 + Double($1["baselineCorrect"] as! Int) / Double(max(1, $1["frames"] as! Int)) } / Double(rows.count),
                "hybridMeanClipAccuracy": rows.reduce(0.0) { $0 + Double($1["hybridCorrect"] as! Int) / Double(max(1, $1["frames"] as! Int)) } / Double(rows.count)]
        }
        let report: [String: Any] = ["scope": "Broad-family matching on isolated local TTS vowel prompts. Middle 60% of active audio; not hand-aligned phonemes, natural songs or general accuracy. Training voices and utterances excluded from held-out split. Mixed and reverberant cases are controlled transforms, not live accompaniment.",
            "trainingClips": clips.filter { $0.split == "train" }.count, "trainingFrames": trainingRows.count,
            "summaries": summaries, "clips": reports]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("comparison.json"))
        for summary in summaries { print(summary) }
    }
    struct Observation { let frame: LiveLipFrame; let features: [Float]? }
    static func analyze(_ clip: Clip, profile: LipVowelProfile?, condition: String) -> [Observation] {
        let active = clip.samples.indices.filter { abs(clip.samples[$0]) > 0.01 }
        precondition(!active.isEmpty)
        let start = active.first!, end = active.last!
        let lower = start + (end - start) / 5, upper = end - (end - start) / 5
        let analyzer = LiveLipAnalyzer(); analyzer.collectVowelFeatures = true; analyzer.vowelProfile = profile
        analyzer.scene = SoundScene(kind: .speech, speech: 0.9)
        var rows = [Observation]()
        let echo = Int(0.065 * clip.rate)
        for (index, raw) in clip.samples.enumerated() {
            let time = Double(index) / clip.rate
            var sample = raw
            if condition == "quiet" { sample *= 0.25 }
            if condition == "accompaniment" {
                sample += Float(0.045 * sin(2 * .pi * 220 * time) + 0.025 * sin(2 * .pi * 440 * time)
                    + 0.025 * sin(2 * .pi * 660 * time))
            }
            if condition == "reverb", index >= echo { sample += clip.samples[index - echo] * 0.4 }
            if let frame = analyzer.consume(sample, sampleRate: clip.rate), (lower...upper).contains(index) {
                rows.append(Observation(frame: frame, features: analyzer.lastVowelFeatures))
            }
        }
        precondition(!rows.isEmpty)
        return rows
    }
    static func family(_ shape: MouthShape) -> MouthShape {
        switch shape { case .slight: return .ah; case .narrow: return .ee; case .roundedWide: return .oh; default: return shape }
    }
    static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice, speed: Float) -> ([Float], Double) {
        let synth = AVSpeechSynthesizer(), utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = speed
        let lock = NSLock(); var samples = [Float](), rate = 0.0, done = false
        synth.write(utterance) { buffer in
            guard let audio = buffer as? AVAudioPCMBuffer else { return }
            lock.lock(); defer { lock.unlock() }
            if audio.frameLength == 0 { done = true; return }
            guard let data = audio.floatChannelData?[0] else { return }
            rate = audio.format.sampleRate
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(audio.frameLength)))
        }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            lock.lock(); let complete = done; lock.unlock()
            if complete { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        lock.lock(); defer { lock.unlock() }
        precondition(done && rate >= 16000 && !samples.isEmpty, "Local TTS returned no audio: \(text)")
        print("Generated \(voice.name) \(voice.language) \(text) at \(speed)")
        let padding = [Float](repeating: 0, count: Int(rate * 0.1))
        return (padding + samples + padding, rate)
    }
}
