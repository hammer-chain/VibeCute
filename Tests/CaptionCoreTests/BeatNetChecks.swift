import Foundation
import CaptionCore

enum BeatNetChecks {
    static func run() {
        func feed(_ analyzer: LiveLipAnalyzer, seconds: Double, origin: Double = 0,
                  musical: Bool = true, quiet: Bool = false, drain: Bool = true) -> [BeatEstimate] {
            var result: [BeatEstimate] = []
            for i in 0..<Int(seconds * 16_000) {
                let t = origin + Double(i) / 16_000
                analyzer.scene = SoundScene(kind: musical ? .music : .speech,
                    speech: musical ? 0 : 0.9, music: musical ? 0.9 : 0, audioTime: t)
                let offset = t.truncatingRemainder(dividingBy: 0.5)
                let pulse = quiet ? 0 : 0.65 * exp(-offset * 60) * sin(2 * .pi * 100 * t)
                if let frame = analyzer.consume(Float(pulse), sampleRate: 16_000) {
                    if drain { analyzer.drainTempoAnalysis() }
                    result.append(frame.beat)
                }
            }
            analyzer.drainTempoAnalysis()
            return result
        }
        let analyzer = LiveLipAnalyzer(); analyzer.tempoEngine = .beatnet
        let beats = feed(analyzer, seconds: 10)
        precondition(beats.contains { $0.reliable && abs(($0.bpm ?? 0) - 120) < 12 }, "BeatNet must lock the 120 BPM reference")
        precondition(beats.last!.droppedBatches == 0, "Drained offline replay cannot lose input")
        precondition(!feed(analyzer, seconds: 4, origin: 10, quiet: true).last!.reliable, "Silence expires a locked phase")
        precondition(feed(analyzer, seconds: 3, origin: 14, musical: false).allSatisfy { !$0.reliable }, "Speech veto")
        analyzer.tempoEngine = .spectral; analyzer.tempoEngine = .beatnet
        precondition(feed(analyzer, seconds: 1, origin: 17, quiet: true).allSatisfy { !$0.reliable }, "Switch discards previous model phase")
        let overloaded = LiveLipAnalyzer(); overloaded.tempoEngine = .beatnet
        let accelerated = feed(overloaded, seconds: 30, drain: false)
        print("BeatNet accelerated replay dropped batches: \(accelerated.last?.droppedBatches ?? 0) (hardware dependent)")
        precondition(!feed(overloaded, seconds: 3, origin: 30, quiet: true).last!.reliable)
        let oldPath = ProcessInfo.processInfo.environment["CAPTIONS_BEATNET_RUNTIME"]
        setenv("CAPTIONS_BEATNET_RUNTIME", "/nonexistent-beatnet-test-runtime", 1)
        defer {
            if let oldPath { setenv("CAPTIONS_BEATNET_RUNTIME", oldPath, 1) }
            else { unsetenv("CAPTIONS_BEATNET_RUNTIME") }
        }
        let missing = LiveLipAnalyzer(); missing.tempoEngine = .beatnet
        precondition(feed(missing, seconds: 4).allSatisfy { $0.engine == .beatnet && $0.bpm == nil }, "Missing model produces no mislabeled fallback")
        print("PASS BeatNet runtime: 120 BPM lock, silence, speech, switch reset, accelerated input, missing runtime")
    }
}
