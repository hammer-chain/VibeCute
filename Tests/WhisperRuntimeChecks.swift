import Foundation
import AVFoundation

/// Streams a known fixture through the production resampler/worker/spotter.
/// No system capture or audio playback. Main run loop delivers production callbacks.
@main enum WhisperRuntimeChecks {
    static func main() throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("worker model fixture.wav") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[3]))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let rate = file.processingFormat.sampleRate
        let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let backend = WhisperKeywordSpeech(modelPath: args[2], workerURL: URL(fileURLWithPath: args[1]))
        var ready = false, failed = false, texts = [String](), matches = [SpeechKeywordMatch]()
        var results = 0
        backend.onStatus = { text, running in
            print(text); ready = running
            if text.contains("失败") || text.contains("退出") || text.contains("超时") || text.contains("无效") { failed = true }
        }
        backend.onProgress = { results = max(results, $0.resultCount) }
        backend.onTranscript = { text, _ in if texts.last != text { texts.append(text); print("TRANSCRIPT: \(text)") } }
        backend.onKeyword = { match, _ in matches.append(match); print("MATCH: \(match.keyword.rawValue)") }
        backend.setEnabled(true)
        func spin(until condition: () -> Bool, timeout: Double) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        spin(until: { ready || failed }, timeout: 65)
        precondition(ready && !failed, "Worker must load a real multilingual model")
        // 0.5s lead-in, 4s tail; source fixture remains in memory.
        let audio = [Float](repeating: 0, count: Int(rate * 0.5)) + pcm + [Float](repeating: 0, count: Int(rate * 4))
        var cursor = 0
        let origin = ProcessInfo.processInfo.systemUptime
        while cursor < audio.count, !failed {
            let count = min(Int(rate * 0.025), audio.count - cursor)
            let endTime = origin + Double(cursor + count) / rate
            spin(until: { ProcessInfo.processInfo.systemUptime >= endTime }, timeout: 1)
            backend.submit(Array(audio[cursor..<cursor+count]), sampleRate: rate, startedAt: origin + Double(cursor) / rate)
            cursor += count
        }
        spin(until: { failed }, timeout: 3)
        backend.setEnabled(false)
        spin(until: { !ready }, timeout: 2)
        precondition(!failed && results > 0, "Real worker must return results")
        let expected = ProcessInfo.processInfo.environment["WHISPER_EXPECT"] ?? "構わない"
        if expected == "none" { precondition(matches.isEmpty, "Negative fixture must not trigger") }
        else {
            for keyword in expected.split(separator: ",").map(String.init) {
                precondition(matches.contains { $0.keyword.rawValue == keyword }, "Expected keyword absent: \(keyword) \(texts)")
                precondition(matches.filter { $0.keyword.rawValue == keyword }.count == 1, "Overlap must not replay a keyword")
            }
            precondition(matches.allSatisfy { $0.endpoint == nil }, "Window result must use arrival-time timing")
        }
        print("PASS: real worker, streaming \(Int(rate)) Hz resampling, \(results) results, \(matches.count) matches, overlap deduplication and shutdown")
    }
}
