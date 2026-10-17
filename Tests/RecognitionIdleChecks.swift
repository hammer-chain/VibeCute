import Foundation
import AVFoundation
import CaptionCore
import Darwin

private final class ProbeBackend: KeywordSpeechBackend {
    var onStatus: ((String, Bool) -> Void)?
    var onTranscript: ((String, SpeechProgress) -> Void)?
    var onProgress: ((SpeechProgress) -> Void)?
    var onKeyword: ((SpeechKeywordMatch, Bool) -> Void)?
    var enabled = false
    var inputs: [(Int, Double)] = []
    func setEnabled(_ value: Bool) { enabled = value }
    func submit(_ samples: [Float], sampleRate: Double, startedAt: Double) { inputs.append((samples.count, startedAt)) }
    func resetStream() {}
}

@main enum RecognitionIdleChecks {
    static func spin(_ seconds: Double, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    static func workers() -> [String] {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        child.arguments = ["-P", String(getpid()), "-f", "captions-whisper"]
        child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        try! child.run(); child.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.split(separator: "\n").map(String.init)
    }
    static func main() throws {
        // The shared facade must cancel either backend and reject old callbacks.
        for engine in SpeechEngine.allCases {
            var made: [ProbeBackend] = [], hits = 0
            let facade = KeywordSpeech(backendFactory: { _, _ in let b = ProbeBackend(); made.append(b); return b })
            facade.onKeyword = { _, _ in hits += 1 }
            facade.setEnabled(true, engine: engine)
            precondition(made.isEmpty, "Initial silence must not instantiate ASR")
            for i in 0..<80 { facade.submit([Float](repeating: 0.01, count: 400), sampleRate: 16_000, startedAt: Double(i)/40) }
            facade.setAudioActive(true)
            let old = made.last!; precondition(old.enabled)
            old.onStatus?("ready", true)
            precondition(old.inputs.count <= 8 && old.inputs.reduce(0) { $0 + $1.0 } == 32_000, "Replay must preserve onset within backend queue bound")
            facade.setAudioActive(false); precondition(!old.enabled)
            var spotter = SpeechKeywordSpotter()
            let late = spotter.receive(text: "構わない", words: [], requestNumber: 1, origin: 0, inputEnd: 2, at: 2)!
            old.onKeyword?(late, true)
            precondition(hits == 0, "Cancelled backend must not deliver a stale keyword")
            facade.setAudioActive(true); precondition(made.count == 2 && made.last!.enabled)
            facade.setEnabled(false, engine: engine); precondition(!made.last!.enabled)
        }
        print("PASS: both backends deferred at idle, stopped/resumed, startup PCM preserved, stale callbacks rejected")

        let args = CommandLine.arguments
        precondition(args.count == 4, "worker model fixture")
        var activity: [Bool] = [], matches: [JapaneseKiraKeyword] = [], results = 0, ready = false, madeClassifiers = 0
        weak var classifier: SoundContextClassifier?
        var classifierOrigins: [Double] = []
        let facade = KeywordSpeech(backendFactory: { _, path in
            WhisperKeywordSpeech(modelPath: path, workerURL: URL(fileURLWithPath: args[1]))
        })
        facade.onStatus = { text, running in print(text); ready = running }
        facade.onProgress = { results = max(results, $0.resultCount) }
        facade.onKeyword = { match, _ in matches.append(match.keyword) }
        let audio = RealtimeAudio(speech: facade, classifierFactory: { rate, origin in
            let c = SoundContextClassifier(sampleRate: rate, audioTimeOrigin: origin)
            classifierOrigins.append(origin); classifier = c; madeClassifiers += 1; return c
        })
        audio.onRecognitionActivity = { activity.append($0) }
        facade.setEnabled(true, engine: .whisper, modelPath: args[2])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[3]))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let rate = file.processingFormat.sampleRate
        let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        var cursor = 0
        let origin = ProcessInfo.processInfo.systemUptime
        func stream(_ samples: [Float]) {
            var offset = 0
            while offset < samples.count {
                let count = min(Int(rate * 0.025), samples.count-offset)
                let end = origin + Double(cursor+count)/rate
                spin(1, until: { ProcessInfo.processInfo.systemUptime >= end })
                let block = Array(samples[offset..<offset+count])
                audio.consumeRecognitionPCM(block, peak: block.map(abs).max() ?? 0, sampleRate: rate, startedAt: origin+Double(cursor)/rate)
                cursor += count; offset += count
                spin(0.001)
            }
        }
        stream([Float](repeating: 0, count: Int(rate)))
        precondition(workers().isEmpty && classifier == nil && madeClassifiers == 0, "No models during initial digital silence")
        // Low-amplitude real input wakes the exact production pipeline.
        stream([Float](repeating: 0.00002, count: Int(rate * 0.5)))
        spin(5, until: { ready && !workers().isEmpty })
        precondition(ready && !workers().isEmpty && classifier != nil)
        let initialWorker = workers()
        // A short gap must not tear down or reload either model.
        stream([Float](repeating: 0, count: Int(rate * 0.1)))
        precondition(workers() == initialWorker && classifier != nil)
        stream(pcm)
        // Allow ASR completion without changing the acoustic activity decision.
        stream([Float](repeating: 0.00002, count: Int(rate * 1.5)))
        precondition(results > 0 && matches.contains(.kamawanai), "Real worker must recognize the known phrase after cold wake")
        stream([Float](repeating: 0, count: Int(rate * 0.3)))
        spin(5, until: { workers().isEmpty && classifier == nil && !ready })
        precondition(workers().isEmpty && classifier == nil && !ready, "Silence must unload native ASR process and SoundAnalysis object")
        let beforeWake = madeClassifiers
        stream([Float](repeating: 0.00002, count: Int(rate * 0.5)))
        spin(5, until: { ready && !workers().isEmpty })
        precondition(ready && !workers().isEmpty && madeClassifiers > beforeWake && classifier != nil)
        stream([Float](repeating: 0.00002, count: Int(rate * 1.5)))
        spin(3, until: { classifier?.snapshot().ready == true })
        precondition(classifierOrigins.last! > classifierOrigins.first!)
        precondition(classifier!.snapshot().audioTime >= classifierOrigins.last! + 1,
                     "Restarted classification must share the ongoing PCM clock, not look expired to the mouth analyzer")
        stream([Float](repeating: 0, count: Int(rate * 0.3)))
        spin(5, until: { workers().isEmpty && classifier == nil })
        precondition(workers().isEmpty && classifier == nil)
        audio.shutdown(); spin(0.1)
        let summary: [String: Any] = ["passed":true,"scope":"Offline PCM -> production RealtimeAudio recognition pipeline; real SoundAnalysis and native Whisper, no system capture", "keywordMatches":matches.map(\.rawValue),"results":results,"classifiersCreated":madeClassifiers,"classifierOrigins":classifierOrigins,"classificationClockPreserved":true,"activityTransitions":activity,"workerUnloadedOnSilence":true,"classifierReleasedOnSilence":true,"wakesAfterSilence":true]
        let out = URL(fileURLWithPath: "output/whisper/recognition-idle.json")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted,.sortedKeys]).write(to: out)
        print("PASS: real classifier/Whisper unloaded on silence, cold wake, recognized phrase, short-gap stability and second wake")
    }
}
