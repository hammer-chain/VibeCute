import Foundation
import AVFoundation
import CaptionCore

@main enum VocalSeparationExperiment {
    static let rate = 44100.0
    static let folder = URL(fileURLWithPath: "output/vocal-separation")
    static let runtime = URL(fileURLWithPath: ".build/vocal-separation/runtime")
    static func main() throws {
        setbuf(stdout, nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--runtime-checks") { try VocalRuntimeChecks.run(); return }
        let accompaniment = try load("karaoke", start: 45, seconds: 8)
        var reports = [[String: Any]]()
        for language in ["ja-JP", "zh-CN", "en-US"] {
            let voice = AVSpeechSynthesisVoice(language: language)!
            let prompts: [(String, MouthShape)] = language == "ja-JP" ? [("あー", .ah), ("いー", .ee), ("うー", .oo)]
                : language == "zh-CN" ? [("啊", .ah), ("衣", .ee), ("乌", .oo)] : [("ah", .ah), ("ee", .ee), ("ooh", .oo)]
            for (prompt, shape) in prompts {
                let vocal = synthesize(prompt, voice: voice)
                let padding = Int(rate * 0.7)
                let reference = [Float](repeating: 0, count: padding) + vocal + [Float](repeating: 0, count: padding)
                let rms = sqrt(reference.reduce(Float.zero) { $0 + $1 * $1 } / Float(reference.count))
                for snr in [0.0, -6.0] {
                    let bed: [(Float, Float)] = (0..<reference.count).map { i in accompaniment[i % accompaniment.count] }
                    var bedEnergy: Float = 0
                    for pair in bed { bedEnergy += (pair.0 * pair.0 + pair.1 * pair.1) * Float(0.5) }
                    let bedRMS: Float = sqrt(bedEnergy / Float(bed.count))
                    let bedGain = rms / max(0.0001, bedRMS) / Float(pow(10, snr / 20))
                    var stereo = [Float](), mixture = [Float]()
                    for i in reference.indices {
                        let left: Float = reference[i] + bed[i].0 * bedGain
                        let right: Float = reference[i] + bed[i].1 * bedGain
                        stereo.append(left); stereo.append(right); mixture.append((left + right) * Float(0.5))
                    }
                    let separated = try separate(stereo)
                    let range = padding..<(padding + vocal.count)
                    let clean = frames(reference), before = frames(mixture), after = frames(separated)
                    let scored = clean.indices.filter { range.contains(Int(clean[$0].audioTime * rate)) && clean[$0].voiceLike }
                    let beforeAgreement = scored.filter { family(before[$0].shape) == family(clean[$0].shape) }.count
                    let afterAgreement = scored.filter { family(after[$0].shape) == family(clean[$0].shape) }.count
                    reports.append(["language": language, "voice": voice.identifier, "prompt": prompt, "expectedFamily": shape.title,
                        "snrDb": snr, "frames": scored.count, "mixtureCleanAgreement": beforeAgreement, "separatedCleanAgreement": afterAgreement,
                        "mixtureSISDR": siSDR(mixture, reference), "separatedSISDR": siSDR(separated, reference),
                        "referenceShapeAccuracy": scored.filter { family(clean[$0].shape) == shape }.count])
                    print(reports.last!)
                }
            }
        }
        var songs = [[String: Any]]()
        for name in ["original", "karaoke", "jazz"] {
            let stereo = try load(name, start: name == "jazz" ? 0 : 45, seconds: 8)
            let mixture = stereo.map { ($0.0 + $0.1) * 0.5 }
            let separated = try separate(stereo.flatMap { [$0.0, $0.1] })
            let before = frames(mixture), after = frames(separated)
            let beforePower = mixture.reduce(Float.zero) { $0 + $1 * $1 }
            let afterPower = separated.reduce(Float.zero) { $0 + $1 * $1 }
            songs.append(["source": name, "seconds": Double(mixture.count) / rate,
                "vocalToMixPowerDb": 10 * log10(max(1e-12, afterPower) / max(1e-12, beforePower)),
                "rawVoiceLikeFrames": before.filter(\.voiceLike).count, "separatedVoiceLikeFrames": after.filter(\.voiceLike).count,
                "scope": "File-window acoustics with scene unavailable; no live scene classifier or manual mouth labels"])
            print(songs.last!)
        }
        let report: [String: Any] = ["controlled": reports, "realFileWindows": songs,
            "scope": "Local TTS + actual accompaniment, source-aligned clean-reference agreement and SI-SDR. Clean analyzer can be wrong; agreement is not phoneme accuracy. File windows are not live playback. PCM only in memory."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("quality-comparison.json"))
    }
    static func separate(_ stereo: [Float]) throws -> [Float] {
        let worker = try VocalWorkerTransport(directory: runtime); defer { worker.stop() }
        let frames = stereo.count / 2, padded = (frames + 1023) / 1024 * 1024
        let input = stereo + [Float](repeating: 0, count: (padded - frames + 128) * 2)
        var output = [Float]()
        for start in stride(from: 0, to: padded + 128, by: 1024) {
            let end = min(padded + 128, start + 1024)
            let result = try worker.transact(stereo: Array(input[(start*2)..<(end*2)]), capturedEnd: Double(end) / rate, reset: start == 0)
            output.append(contentsOf: result.samples)
        }
        precondition(output.count >= frames)
        return Array(output.prefix(frames))
    }
    static func frames(_ pcm: [Float]) -> [LiveLipFrame] {
        let analyzer = LiveLipAnalyzer(); analyzer.scene = .unavailable
        return pcm.compactMap { analyzer.consume($0, sampleRate: rate) }
    }
    static func family(_ shape: MouthShape) -> MouthShape {
        switch shape { case .slight: return .ah; case .narrow: return .ee; case .roundedWide: return .oh; default: return shape }
    }
    static func siSDR(_ estimate: [Float], _ reference: [Float]) -> Double {
        let dot = zip(estimate, reference).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let energy = reference.reduce(0.0) { $0 + Double($1) * Double($1) }
        let alpha = dot / max(1e-12, energy)
        let residual = zip(estimate, reference).reduce(0.0) { $0 + pow(Double($1.0) - alpha * Double($1.1), 2) }
        return 10 * log10(max(1e-12, alpha * alpha * energy) / max(1e-12, residual))
    }
    static func resample(_ samples: [[Float]], rate inputRate: Double) -> [[Float]] {
        let source = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: AVAudioChannelCount(samples.count))!
        let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(samples.count))!
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples[0].count))!
        input.frameLength = input.frameCapacity
        for channel in samples.indices { samples[channel].withUnsafeBufferPointer { input.floatChannelData![channel].update(from: $0.baseAddress!, count: $0.count) } }
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(samples[0].count) * rate / inputRate) + 256))!
        let converter = AVAudioConverter(from: source, to: target)!
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var supplied = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        precondition(error == nil && output.frameLength > 0)
        return samples.indices.map { Array(UnsafeBufferPointer(start: output.floatChannelData![$0], count: Int(output.frameLength))) }
    }
    static func load(_ name: String, start: Double, seconds: Double) throws -> [(Float, Float)] {
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: ".build/whisper/song-tests/sources/\(name).wav"))
        audio.framePosition = AVAudioFramePosition(start * audio.processingFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(seconds * audio.processingFormat.sampleRate))!
        try audio.read(into: buffer)
        let channels = (0..<Int(buffer.format.channelCount)).prefix(2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
        let converted = resample(channels, rate: buffer.format.sampleRate)
        return converted[0].indices.map { (converted[0][$0], converted[converted.count - 1][$0]) }
    }
    static func synthesize(_ prompt: String, voice: AVSpeechSynthesisVoice) -> [Float] {
        let synth = AVSpeechSynthesizer(), utterance = AVSpeechUtterance(string: prompt)
        utterance.voice = voice; utterance.rate = 0.25
        let lock = NSLock(); var pcm = [Float](), inputRate = 0.0, done = false
        synth.write(utterance) { buffer in
            guard let audio = buffer as? AVAudioPCMBuffer else { return }
            lock.lock(); defer { lock.unlock() }
            if audio.frameLength == 0 { done = true; return }
            inputRate = audio.format.sampleRate
            pcm.append(contentsOf: UnsafeBufferPointer(start: audio.floatChannelData![0], count: Int(audio.frameLength)))
        }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            lock.lock(); let complete = done; lock.unlock()
            if complete { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        lock.lock(); defer { lock.unlock() }; precondition(done && !pcm.isEmpty)
        return resample([pcm], rate: inputRate)[0]
    }
}
