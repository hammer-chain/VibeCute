import Foundation
import CaptionCore

precondition(BuildProfile.isRelease)
precondition(TempoEngine.available == [.beatnet] && LipMatchingEngine.available == [.mfcc])
setenv("CAPTIONS_BEATNET_RUNTIME", "/nonexistent-override-must-be-ignored", 1)
let root = Bundle.main.resourceURL!
let missing = CommandLine.arguments.contains("--missing-runtime")
let analyzer = LiveLipAnalyzer()
analyzer.tempoEngine = .btrack
precondition(analyzer.tempoEngine == .beatnet)
if !missing {
    precondition(BeatNetRuntime.availability.contains("运行时已安装"))
    let profile = try JSONDecoder().decode(LipVowelProfile.self, from: Data(contentsOf: root.appendingPathComponent("LipVowels.json")))
    precondition(profile.isValid)
    analyzer.vowelProfile = profile
    let mfcc = LipMFCC()
    var power = [Float](repeating: 0.001, count: 512)
    power[40] = 4; power[80] = 2
    let features = mfcc.features(power: power)!
    let quieter = mfcc.features(power: power.map { $0 * 0.01 })!
    precondition(zip(features, quieter).allSatisfy { abs($0 - $1) < 0.0001 })
    precondition(mfcc.features(power: Array(repeating: 0, count: 512)) == nil)
}
func feed(_ seconds: Double, origin: Double, quiet: Bool = false, speech: Bool = false, drain: Bool = true) -> [BeatEstimate] {
    var results = [BeatEstimate]()
    for i in 0..<Int(seconds * 16000) {
        let time = origin + Double(i) / 16000
        analyzer.scene = SoundScene(kind: speech ? .speech : .music, speech: speech ? 0.9 : 0, music: speech ? 0 : 0.9, audioTime: time)
        let offset = time.truncatingRemainder(dividingBy: 0.5)
        let sample = quiet ? 0 : 0.65 * exp(-offset * 60) * sin(2 * .pi * 100 * time)
        if let frame = analyzer.consume(Float(sample), sampleRate: 16000) {
            if drain { analyzer.drainTempoAnalysis() }
            results.append(frame.beat)
        }
    }
    analyzer.drainTempoAnalysis()
    return results
}
let start = ProcessInfo.processInfo.systemUptime
if missing {
    let beats = feed(5, origin: 0)
    precondition(beats.allSatisfy { $0.engine == .beatnet && $0.bpm == nil })
    print("PASS release missing-runtime: no alternate engine or developer-cache fallback")
} else {
    let beats = feed(12, origin: 0)
    precondition(beats.contains { $0.reliable && abs(($0.bpm ?? 0) - 120) < 12 })
    precondition(beats.last!.droppedBatches == 0)
    precondition(!feed(4, origin: 12, quiet: true).last!.reliable)
    precondition(feed(3, origin: 16, speech: true).allSatisfy { !$0.reliable })
    let overload = feed(12, origin: 19, drain: false)
    precondition(!feed(4, origin: 31, quiet: true).last!.reliable)
    print("PASS release DSP: 120 BPM lock, silence expiry, speech veto, overload recovery, MFCC gain invariance; accelerated dropped batches=\(overload.last?.droppedBatches ?? 0)")
}
let elapsed = ProcessInfo.processInfo.systemUptime - start
print("Controlled offline input: \(missing ? 5 : 35) seconds, wall time=\(String(format: "%.3f", elapsed)) seconds; final Release core objects, no profiler; not live-audio acceptance")
