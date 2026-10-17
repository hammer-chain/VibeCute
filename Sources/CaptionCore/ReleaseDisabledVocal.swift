#if VIBECUTE_RELEASE
import Foundation

/// Disabled compatibility surface: no worker, queue, resampler or model is linked.
public final class VocalSeparationPipeline {
    public struct Output {
        public let samples: [Float]
        public let capturedEnd: Double
        public let audioTimeEnd: Double
        public let reset: Bool
        public let captureTimeEstimated: Bool
    }
    public struct Status {
        public init() {}
        public var message = "使用原始声音"
        public var running = false
        public var failed = false
        public var processed = 0
        public var dropped = 0
    }
    public var onOutput: ((Output) -> Void)?
    public init(directory: URL) {}
    public func snapshot() -> Status { Status() }
    public func submit(stereo: [Float], sampleRate: Double, capturedStart: Double, audioTimeStart: Double, estimated: Bool) {}
    public func stop() {}
}
#endif
