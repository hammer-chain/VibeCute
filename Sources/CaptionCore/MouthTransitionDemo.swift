import Foundation

/// Deterministic target stream for checking the real renderer without playback.
public enum MouthTransitionDemo {
    public static let duration: TimeInterval = 4
    public static func frame(elapsed: TimeInterval, startedAt: TimeInterval) -> LiveLipFrame {
        let sampleTime = floor(max(0, elapsed) * 50) / 50
        let shape: MouthShape
        switch sampleTime {
        case 0.3..<1: shape = .ah
        case 1..<1.4: shape = Int((sampleTime - 1) / 0.04) % 2 == 0 ? .ee : .oo
        case 1.4..<1.6: shape = .ee
        case 1.6..<1.64: shape = .closed
        case 1.64..<2.2: shape = .oo
        case 2.2..<2.22: shape = .ah
        case 2.22..<2.24: shape = .ee
        case 2.24..<2.4: shape = .oo
        case 2.4..<3: shape = .ah
        default: shape = .rest
        }
        let active = shape != .rest
        var frame = LiveLipFrame(shape: shape, level: active ? 0.35 : 0,
            voiceLike: active && shape != .closed, confidence: 0.9, audioTime: sampleTime,
            firstFormant: nil, secondFormant: nil,
            scene: SoundScene(kind: active ? .speech : .silence, speech: active ? 0.9 : 0, audioTime: sampleTime),
            voiceGateOpen: active)
        frame.capturedAt = startedAt + sampleTime
        frame.analyzedAt = startedAt + sampleTime
        return frame
    }
}
