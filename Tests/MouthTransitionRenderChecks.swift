import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@main enum MouthTransitionRenderChecks {
    static func main() throws {
        let folder = URL(fileURLWithPath: "output/lip-sustain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var before = BeforeMouthPosePlayer(), after = MouthPosePlayer()
        var rows = [[String: Any]]()
        let count = 200
        let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("before-after.gif") as CFURL,
            UTType.gif.identifier as CFString, count, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for tick in 0..<count {
            let now = Double(tick) / 50
            let frame = MouthTransitionDemo.frame(elapsed: now, startedAt: 0)
            let old = before.sample(frame.shape, at: now)
            let new = after.sample(frame, at: now)
            rows.append(["time": now, "target": frame.shape.rawValue, "before": old.rawValue,
                "after": new.rawValue, "transitionTarget": after.transitionTarget.map { $0.rawValue as Any } ?? NSNull(),
                "transitionsStarted": after.transitionsStarted])
            let bitmap = render(old: old, new: new)
            CGImageDestinationAddImage(gif, bitmap.cgImage!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.02]] as CFDictionary)
            if [19, 20, 21, 53, 54, 55, 81, 83, 84, 123, 124, 125, 151, 152].contains(tick) {
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: folder.appendingPathComponent(String(format: "transition-%03d.png", tick)))
            }
        }
        precondition(CGImageDestinationFinalize(gif))
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("render-trace.json"))
        let closure = rows.filter { (1.6..<1.72).contains($0["time"] as! Double) }
        precondition(closure.allSatisfy { $0["after"] as! Int != MouthShape.closed.rawValue },
                     "A 40 ms closure must not interrupt a sustained vowel")
        precondition(rows.filter { $0["time"] as! Double > 3.4 }.allSatisfy { $0["after"] as! Int == 0 })
        try checkNativeSpeech(folder: folder)
        print("PASS: actual atlas before/after rendering, transient closure filtering and natural release")
    }

    private static func render(old: MouthShape, new: MouthShape) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 460,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 960, height: 460).fill()
        for (column, character) in [CaptionMascot.codex, .codex, .deepseek, .deepseek].enumerated() {
            let animation = MascotAnimation.library[character]!
            let pose = column % 2 == 0 ? old : new
            let rect = NSRect(x: Double(column) * 240 + 15, y: 15, width: 210, height: 280)
            animation.drawSeated(mouth: pose.rawValue, in: rect, at: 0, motionAmount: 0)
            let crop = NSRect(x: animation.mouthRect.midX - 27, y: animation.mouthRect.midY - 21, width: 54, height: 42)
            let full = NSImage(size: NSSize(width: 384, height: 512))
            full.lockFocus()
            animation.drawSeated(mouth: pose.rawValue, in: NSRect(x: 0, y: 0, width: 384, height: 512), at: 0, motionAmount: 0)
            full.unlockFocus()
            full.draw(in: NSRect(x: Double(column) * 240 + 66, y: 300, width: 108, height: 84), from: crop,
                      operation: .sourceOver, fraction: 1)
            let title = (column % 2 == 0 ? "Before" : "After") + " · " + pose.title
            (title as NSString).draw(at: NSPoint(x: Double(column) * 240 + 24, y: 412),
                withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                 .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)])
        }
        return bitmap
    }

    /// Natural PCM exercises the controller with existing acoustic estimates.
    /// Transcript timing is deliberately not treated as phoneme ground truth.
    private static func checkNativeSpeech(folder: URL) throws {
        var reports = [[String: Any]]()
        for (language, text) in [("zh-CN", "妈妈慢慢说，爸爸抱宝宝。啊，衣，乌。"),
                                 ("ja-JP", "まま、ぱぱ。あ、い、う。ゆっくり話します。"),
                                 ("en-US", "Mama and papa. Ah, ee, oo. Now we stop.")] {
            let synth = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: language)
            precondition(utterance.voice != nil, "Need local TTS voice: \(language)")
            let lock = NSLock()
            var pcm: [Float] = [], rate = 0.0, done = false
            synth.write(utterance) { buffer in
                guard let audio = buffer as? AVAudioPCMBuffer else { return }
                lock.lock(); defer { lock.unlock() }
                if audio.frameLength == 0 { done = true; return }
                guard let channel = audio.floatChannelData?[0] else { return }
                rate = audio.format.sampleRate
                pcm.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(audio.frameLength)))
            }
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                lock.lock(); let complete = done; lock.unlock()
                if complete { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            lock.lock(); let complete = done, signal = pcm, sampleRate = rate; lock.unlock()
            precondition(complete && sampleRate >= 16_000 && !signal.isEmpty, "TTS must produce PCM")
            let analyzer = LiveLipAnalyzer()
            analyzer.scene = SoundScene(kind: .unavailable)
            var frames = [LiveLipFrame]()
            for (index, sample) in signal.enumerated() {
                if var frame = analyzer.consume(sample, sampleRate: sampleRate) {
                    frame.capturedAt = Double(index + 1) / sampleRate
                    frames.append(frame)
                }
            }
            let duration = Double(signal.count) / sampleRate
            for index in 0..<Int(sampleRate * 0.5) {
                if var frame = analyzer.consume(0, sampleRate: sampleRate) {
                    frame.capturedAt = duration + Double(index + 1) / sampleRate
                    frames.append(frame)
                }
            }
            var player = MouthPosePlayer(), oldPlayer = BeforeMouthPosePlayer(), cursor = 0, poses = [MouthShape]()
            var changes = [Double](), oldChanges = [Double](), previous = MouthShape.rest, oldPrevious = MouthShape.rest
            var rawClosures = 0, visibleClosures = 0
            for tick in 0...Int((duration + 0.5) * 60) {
                let now = Double(tick) / 60
                while cursor + 1 < frames.count, frames[cursor + 1].capturedAt! <= now { cursor += 1 }
                if frames[cursor].capturedAt! <= now {
                    let frame = frames[cursor]
                    if frame.shape == .closed { rawClosures += 1 }
                    let pose = player.sample(frame, at: now)
                    let oldPose = oldPlayer.sample(frame, at: now)
                    if pose != previous { changes.append(now); previous = pose }
                    if oldPose != oldPrevious { oldChanges.append(now); oldPrevious = oldPose }
                    if pose == .closed { visibleClosures += 1 }
                    poses.append(pose)
                }
            }
            precondition(poses.contains { $0 != .rest && $0 != .closed }, "Speech must drive a mouth")
            precondition(poses.suffix(5).allSatisfy { $0 == .rest }, "No pose playback after natural speech ends")
            let maxChanges = changes.map { first in changes.filter { $0 >= first && $0 < first + 1 - 1e-8 }.count }.max() ?? 0
            let oldMax = oldChanges.map { first in oldChanges.filter { $0 >= first && $0 < first + 1 - 1e-8 }.count }.max() ?? 0
            precondition(maxChanges <= 8, "Natural speech must obey the visible cadence including bridges")
            reports.append(["language": language, "audioSeconds": duration, "analysisFrames": frames.count,
                "rawClosureDisplayTicks": rawClosures, "visibleClosureTicks": visibleClosures,
                "transitionsStarted": player.transitionsStarted, "endsAtRest": poses.last == .rest,
                "mainMaxVisibleChangesPerSecond": oldMax, "newMaxVisibleChangesPerSecond": maxChanges,
                "phonemeAccuracyMeasured": false])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("native-speech-validation.json"))
        print("PASS: Chinese/Japanese/English in-memory TTS, bounded visible cadence and natural release (not phoneme accuracy)")
    }
}
