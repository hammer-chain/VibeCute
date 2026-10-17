import Foundation
import CaptionCore

enum VocalDSPChecks {
    static func run() {
        for rate in [16000.0, 44100, 48000, 96000, 192000] {
            let count = Int(rate / 5)
            let stereo = (0..<count).flatMap { i -> [Float] in
                let value = Float(sin(2 * .pi * 3000 * Double(i) / rate))
                return [value, -value]
            }
            let one = VocalStereoResampler(sampleRate: rate).consume(stereo: stereo, capturedStart: 100)
            let streaming = VocalStereoResampler(sampleRate: rate)
            var partitioned = [Float](), end: Double?
            for start in stride(from: 0, to: count, by: 137) {
                let finish = min(count, start + 137)
                let chunk = streaming.consume(stereo: Array(stereo[(start * 2)..<(finish * 2)]),
                    capturedStart: 100 + Double(start) / rate)
                partitioned.append(contentsOf: chunk.stereo); end = chunk.capturedEnd ?? end
            }
            precondition(partitioned == one.stereo && end == one.capturedEnd, "Packet boundaries must not change samples or time")
            let expected = Int(ceil(Double(count - 32) * 44100 / rate))
            precondition(one.stereo.count / 2 == expected)
            let duration = Double(expected) / 44100
            precondition(abs(one.capturedEnd! - (100 + duration)) < 1e-8)
            precondition(stride(from: 0, to: one.stereo.count, by: 2).allSatisfy { abs(one.stereo[$0] + one.stereo[$0 + 1]) < 1e-6 })
            let steady = stride(from: 256, to: one.stereo.count, by: 2).map { one.stereo[$0] }
            let rms = sqrt(steady.reduce(Float.zero) { $0 + $1 * $1 } / Float(steady.count))
            precondition(abs(rms - Float(sqrt(0.5))) < 0.006, "Keep speech-band energy")
        }
        let downsample = VocalStereoResampler(sampleRate: 96000)
        let high = (0..<9600).flatMap { i -> [Float] in
            let value = Float(sin(2 * .pi * 35000 * Double(i) / 96000)); return [value, value]
        }
        let alias = downsample.consume(stereo: high, capturedStart: 0).stereo.dropFirst(256)
        let aliasRMS = sqrt(alias.reduce(Float.zero) { $0 + $1 * $1 } / Float(alias.count))
        precondition(aliasRMS < 0.002, "Reject frequencies above the destination Nyquist")
        let dc = VocalStereoResampler(sampleRate: 48000).consume(stereo: [Float](repeating: 0.25, count: 4096), capturedStart: 0).stereo
        precondition(dc.dropFirst(256).allSatisfy { abs($0 - 0.25) < 1e-6 })
        let analyzer = LiveLipAnalyzer(audioTimeOrigin: 100, trackTempo: false)
        var frame: LiveLipFrame?
        for _ in 0..<1024 { frame = analyzer.consume(0, sampleRate: 16000) ?? frame }
        precondition(abs(frame!.audioTime - 100.064) < 1e-8)
        print("Vocal DSP checks passed: packet boundaries, rates, stereo, alias suppression, capture clock")
    }
}
