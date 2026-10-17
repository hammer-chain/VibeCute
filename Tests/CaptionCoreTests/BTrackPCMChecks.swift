import Foundation
import CaptionCore

/// Replay generated PCM through the actual analyzer with a fixed music hint.
/// Separates classifier gating from tempo tracking; does not measure live capture.
enum BTrackPCMChecks {
    static func run(directory: String) throws {
        let root = URL(fileURLWithPath: directory)
        var results: [[String: Any]] = []
        let tempi = (ProcessInfo.processInfo.environment["PCM_TEMPOS"] ?? "60,120,240").split(separator: ",").compactMap { Int($0) }
        for bpm in tempi {
            let data = try Data(contentsOf: root.appendingPathComponent("kick-\(bpm)bpm.wav"))
            precondition(String(data: data.prefix(4), encoding: .ascii) == "RIFF" && data.count >= 44)
            let analyzer = LiveLipAnalyzer(); analyzer.tempoEngine = TempoEngine(rawValue: ProcessInfo.processInfo.environment["PCM_TEMPO_ENGINE"] ?? "btrack") ?? .btrack
            var lines = ["audioTime,expectedBPM,rawBPM,bpm,confidence,lastBeatTime"]
            var values: [Double] = [], firstCorrect: Double?
            let started = Date()
            for offset in stride(from: 44, to: data.count - 1, by: 2) {
                let bits = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
                let sample = Float(Int16(bitPattern: bits)) / 32768
                let time = Double((offset - 44) / 2) / 44_100
                analyzer.scene = SoundScene(kind: .music, music: 0.9, audioTime: time)
                if let frame = analyzer.consume(sample, sampleRate: 44_100) {
                    analyzer.drainTempoAnalysis()
                    let beat = frame.beat
                    lines.append("\(frame.audioTime),\(bpm),\(beat.rawBPM.map(String.init(describing:)) ?? ""),\(beat.bpm.map(String.init(describing:)) ?? ""),\(beat.confidence),\(beat.lastBeatTime.map(String.init(describing:)) ?? "")")
                    if beat.reliable, let value = beat.bpm {
                        if time >= 10 { values.append(value) }
                        if firstCorrect == nil && abs(value - Double(bpm)) / Double(bpm) < 0.1 { firstCorrect = time }
                    }
                }
            }
            values.sort()
            let result: [String: Any] = ["engine": analyzer.tempoEngine.rawValue, "expectedBPM": bpm, "medianBPM": values.isEmpty ? NSNull() : values[values.count / 2] as Any,
                "steadyReliableFrames": values.count, "firstCorrectAt": firstCorrect.map { $0 as Any } ?? NSNull(),
                "processingSeconds": Date().timeIntervalSince(started), "scope": "32-second PCM, fixed music context"]
            results.append(result); print(result)
            try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("\(analyzer.tempoEngine.rawValue)-pcm-\(bpm)bpm.csv"), atomically: true, encoding: .utf8)
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("\(ProcessInfo.processInfo.environment["PCM_TEMPO_ENGINE"] ?? "btrack")-pcm-summary.json"))
    }
}
