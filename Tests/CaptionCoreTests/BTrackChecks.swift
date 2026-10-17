import Foundation
import CaptionCore

enum BTrackChecks {
    static func run() {
        for engine in [TempoEngine.aubio, .btrack] {
            for rate in [16_000.0, 48_000.0] {
                for bpm in [90.0, 120, 160] {
                    let analyzer = LiveLipAnalyzer()
                    analyzer.tempoEngine = engine
                    var last = BeatEstimate.unknown
                    var locked = 0
                    let start = Date()
                    for index in 0..<Int(rate * 24) {
                        let t = Double(index) / rate
                        analyzer.scene = SoundScene(kind: .music, music: 0.9, audioTime: t)
                        let offset = t.truncatingRemainder(dividingBy: 60 / bpm)
                        let value = t < 20 ? 0.4 * exp(-offset * 65) * (sin(2 * .pi * 100 * t) + 0.6 * sin(2 * .pi * 1700 * t)) : 0
                        if let frame = analyzer.consume(Float(value), sampleRate: rate) {
                            if frame.beat.reliable {
                                locked += 1
                                precondition(abs(frame.beat.bpm! - bpm) < bpm * 0.1)
                            }
                            last = frame.beat
                        }
                    }
                    print("\(engine) \(rate)Hz \(bpm)BPM: 24s audio in \(Date().timeIntervalSince(start))s; reliable frames \(locked)")
                    precondition(locked > 0 && !last.reliable, "Must lock real pulses then expire in silence")
                    analyzer.tempoEngine = .spectral
                    analyzer.tempoEngine = .btrack
                    for index in 0..<Int(rate * 3) {
                        let t = 24 + Double(index) / rate
                        analyzer.scene = SoundScene(kind: .speech, speech: 0.9, audioTime: t)
                        let offset = t.truncatingRemainder(dividingBy: 60 / bpm)
                        let pulse = 0.4 * exp(-offset * 65) * sin(2 * .pi * 100 * t)
                        if let frame = analyzer.consume(Float(pulse), sampleRate: rate) { precondition(!frame.beat.reliable) }
                    }
                }
            }
        }
        print("PASS BTrack streaming, sample rates, silence, speech and engine reset")
    }
}
