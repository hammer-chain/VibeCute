import Foundation

/// Streaming stereo windowed-sinc conversion to the separator's 44.1 kHz clock.
/// 32 input samples of lookahead are reflected in the original capture timestamps.
public final class VocalStereoResampler {
    private let rate: Double
    private let kernels: [[Float]]
    private var left = [Float](repeating: 0, count: 128), right = [Float](repeating: 0, count: 128)
    private var received = 0
    private var nextPosition = 0.0
    private var origin: Double?
    public init(sampleRate: Double) {
        precondition(sampleRate.isFinite && sampleRate >= 16000 && sampleRate <= 192000)
        rate = sampleRate
        let cutoff = 0.45 * min(1, 44100 / sampleRate)
        kernels = (0..<256).map { phase in
            let fraction = Double(phase) / 256
            var coefficients = (0..<64).map { tap -> Float in
                let distance = Double(tap - 31) - fraction
                let sinc = abs(distance) < 1e-9 ? 2 * cutoff : sin(2 * .pi * cutoff * distance) / (.pi * distance)
                let window = 0.42 - 0.5 * cos(2 * .pi * Double(tap) / 63) + 0.08 * cos(4 * .pi * Double(tap) / 63)
                return Float(sinc * window)
            }
            let sum = coefficients.reduce(0, +)
            for i in coefficients.indices { coefficients[i] /= sum }
            return coefficients
        }
    }
    public func consume(stereo: [Float], capturedStart: Double) -> (stereo: [Float], capturedEnd: Double?) {
        guard stereo.count % 2 == 0, capturedStart.isFinite else { return ([], nil) }
        if origin == nil { origin = capturedStart }
        var result = [Float](), last: Double?
        result.reserveCapacity(Int(Double(stereo.count) * 44100 / rate) + 8)
        for frame in 0..<(stereo.count / 2) {
            left[received % 128] = stereo[2 * frame].isFinite ? stereo[2 * frame] : 0
            right[received % 128] = stereo[2 * frame + 1].isFinite ? stereo[2 * frame + 1] : 0
            received += 1
            while Int(floor(nextPosition)) + 32 < received {
                let base = Int(floor(nextPosition)), fraction = nextPosition - floor(nextPosition)
                let kernel = kernels[min(255, Int(fraction * 256))]
                var l: Float = 0, r: Float = 0
                for tap in 0..<64 {
                    let index = base + tap - 31
                    if index >= 0 { l += left[index % 128] * kernel[tap]; r += right[index % 128] * kernel[tap] }
                }
                result.append(l); result.append(r)
                last = origin! + nextPosition / rate + 1 / 44100.0
                nextPosition += rate / 44100
            }
        }
        return (result, last)
    }
}
