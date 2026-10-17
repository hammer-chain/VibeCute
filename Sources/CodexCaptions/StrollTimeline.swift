import Foundation

/// A bounded preview: rise once, turn into a light tiptoe jog, settle and sit.
public enum StrollTimeline {
    public enum Phase: String {
        case seated = "坐姿", rising = "正在起身", turning = "转向侧身"
        case walking = "侧身小跑", settling = "收步回正", sitting = "正在坐下"
    }
    public struct Step {
        public let frame: Int?
        public let duration: TimeInterval
        public let phase: Phase
        public var transitionFrame: Int? = nil
        public var launchFrame: Int? = nil
    }
    public struct Sample: Equatable {
        public let frame: Int?
        public let phase: Phase
        public var transitionFrame: Int? = nil
        public var armSwing: Double? = nil
        public var launchFrame: Int? = nil
        public var isSideFacing: Bool { launchFrame != nil || (frame ?? -1) >= 7 }
    }
    public static let walkFrames = Array(12..<24)
    public static let walkFrameDuration: TimeInterval = 0.060
    public static let walkCycles = 6
    public static func walkSample(at elapsed: TimeInterval) -> Sample {
        let time = max(0, elapsed), cycle = Double(walkFrames.count)*walkFrameDuration
        return Sample(frame:walkFrames[Int(time/walkFrameDuration)%walkFrames.count],phase:.walking,
                      armSwing:-cos(time/cycle*2*Double.pi))
    }
    public static let steps: [Step] = {
        var result = [Step(frame:nil,duration:0.65,phase:.seated)]
        result += (1...3).map { Step(frame:nil,duration:0.12,phase:.rising,transitionFrame:$0) }
        result += (2...5).map { Step(frame: $0, duration: 0.16, phase: .rising) }
        result.append(Step(frame: 6, duration: 0.3, phase: .rising))
        result += (7...9).map { Step(frame: $0, duration: 0.14, phase: .turning) }
        result += (0..<3).map { Step(frame:nil,duration:0.12,phase:.turning,launchFrame:$0) }
        // The launch ends on the exact next contact pose, rather than the old
        // walking stride, so starting travel does not replace the whole body.
        result.append(Step(frame:12,duration:walkFrameDuration,phase:.turning))
        for _ in 0..<walkCycles {
            result += walkFrames.map { Step(frame: $0, duration: walkFrameDuration, phase: .walking) }
        }
        result += [Step(frame: 11, duration: 0.14, phase: .settling),
                   Step(frame: 10, duration: 0.14, phase: .settling),
                   Step(frame: 9, duration: 0.3, phase: .settling)]
        result += [8, 7, 6].map { Step(frame: $0, duration: 0.18, phase: .settling) }
        result += [5,4,3,2].map { Step(frame:$0,duration:0.16,phase:.sitting) }
        result.append(Step(frame:nil,duration:0.12,phase:.sitting,transitionFrame:4))
        result.append(Step(frame:nil,duration:0.24,phase:.sitting,transitionFrame:3))
        result.append(Step(frame:nil,duration:0.5,phase:.seated,transitionFrame:3))
        return result
    }()
    public static var duration: TimeInterval { steps.reduce(0) { $0+$1.duration } }

    public static func sample(at elapsed: TimeInterval) -> Sample? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        var start = 0.0
        for step in steps {
            let end = start+step.duration
            if elapsed < end {
                if step.phase == .walking {
                    let walkStart = steps.prefix { $0.phase != .walking }.reduce(0) { $0+$1.duration }
                    return walkSample(at:elapsed-walkStart)
                }
                return Sample(frame:step.frame,phase:step.phase,transitionFrame:step.transitionFrame,
                              launchFrame:step.launchFrame)
            }
            start = end
        }
        return nil
    }
}
