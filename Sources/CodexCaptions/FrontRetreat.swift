import AppKit

/// Face the viewer throughout: frontal rise, quick lateral retreat, brake, reverse and sit.
enum FrontRetreatTimeline {
    enum Phase: String {
        case seated = "坐姿准备", rising = "正面起身", ready = "抬手准备"
        case outward = "正面向右急退", braking = "收步停稳", returning = "正面向左急退"
        case sitting = "正面坐下", finished = "回到坐姿"
    }
    struct Sample: Equatable {
        let frame: Int?
        let transitionFrame: Int?
        let offset: Double
        let phase: Phase
    }
    static let riseDurations = [0.12,0.12,0.12,0.14,0.14,0.14,0.14,0.14,0.14,0.12,0.12]
    static let cycleDurations = [0.72,0.64,0.58]
    static let returnDurations = [0.60,0.58,0.70]
    static let frameWeights = [0.12,0.09,0.14,0.12,0.10,0.10,0.15,0.18]
    static let riseStart = 0.35
    static let readyStart = riseStart+riseDurations.reduce(0,+)
    static let outwardStart = readyStart+0.16
    static let brakeStart = outwardStart+cycleDurations.reduce(0,+)
    static let returnStart = brakeStart+0.28
    static let sittingStart = returnStart+returnDurations.reduce(0,+)+0.20
    static let sittingDuration = 1.42
    static let duration = sittingStart+sittingDuration+0.35

    // Automatic avoidance is a single trip, with the preview's frontal rise and step poses.
    static func relocationCycles(distance: Double, scale: CGFloat) -> [Double] {
        Array(repeating:0.64,count:max(1,Int(ceil(distance/(56*scale)))))
    }
    static func relocationDuration(distance: Double, scale: CGFloat) -> Double {
        outwardStart+relocationCycles(distance:distance,scale:scale).reduce(0,+)+0.28+sittingDuration+0.35
    }
    static func relocationSample(at t: Double, distance: Double, scale: CGFloat, leftward: Bool) -> Sample? {
        guard t.isFinite, t >= 0, t < relocationDuration(distance:distance,scale:scale) else { return nil }
        if t < outwardStart { return sample(at:t) }
        let cycles = relocationCycles(distance:distance,scale:scale)
        let end = outwardStart+cycles.reduce(0,+)
        if t < end {
            let step = travel(t-outwardStart,durations:cycles,returning:leftward)
            return pose(step.frame,offset:leftward ? 1-step.offset : step.offset,phase:step.phase)
        }
        if t < end+0.28 { return pose(leftward ? 0 : 7,offset:1,phase:.braking) }
        return relocationSitting(at:t-end-0.28)
    }
    static func relocationSitting(at t: Double) -> Sample {
        if t >= sittingDuration { return pose(nil,transition:3,offset:1,phase:.finished) }
        return pose(nil,transition:max(3,10-Int(max(0,t)/sittingDuration*8)),offset:1,phase:.sitting)
    }

    static func sample(at t: Double) -> Sample? {
        guard t.isFinite, t >= 0, t < duration else { return nil }
        if t < riseStart { return pose(nil,offset:0,phase:.seated) }
        if t < readyStart {
            var elapsed = t-riseStart
            for (frame,duration) in riseDurations.enumerated() {
                if elapsed < duration {
                    return pose(nil,transition:frame+1,offset:0,phase:.rising)
                }
                elapsed -= duration
            }
        }
        if t < outwardStart { return pose(0,offset:0,phase:.ready) }
        if t < brakeStart { return travel(t-outwardStart,durations:cycleDurations,returning:false) }
        if t < returnStart { return pose(7,offset:1,phase:.braking) }
        let returnEnd = returnStart+returnDurations.reduce(0,+)
        if t < returnEnd { return travel(t-returnStart,durations:returnDurations,returning:true) }
        if t < sittingStart { return pose(0,offset:0,phase:.braking) }
        if t < sittingStart+sittingDuration {
            let p = (t-sittingStart)/sittingDuration
            let frame = max(3,10-Int(p*8))
            return pose(nil,transition:frame,offset:0,phase:.sitting)
        }
        return pose(nil,transition:3,offset:0,phase:.finished)
    }
    private static func travel(_ elapsed: Double,durations: [Double],returning: Bool) -> Sample {
        var local = elapsed
        for (cycle,duration) in durations.enumerated() {
            if local < duration {
                let p = local/duration
                var edge = 0.0, frame = 7
                for (i,weight) in frameWeights.enumerated() {
                    edge += weight
                    if p < edge { frame = i; break }
                }
                // Two weight transfers per cycle. The body travels on push/landing, eases between steps.
                func pulse(_ a: Double,_ b: Double) -> Double {
                    let q = min(1,max(0,(p-a)/(b-a)))
                    return q*q*(3-2*q)
                }
                let progress = (Double(cycle)+0.5*pulse(0.12,0.43)+0.5*pulse(0.57,0.90))/Double(durations.count)
                return pose(returning ? 7-frame : frame,offset:returning ? 1-progress : progress,
                            phase:returning ? .returning : .outward)
            }
            local -= duration
        }
        return pose(returning ? 0 : 7,offset:returning ? 0 : 1,phase:.braking)
    }
    private static func pose(_ frame: Int?,transition: Int? = nil,offset: Double,phase: Phase) -> Sample {
        Sample(frame:frame,transitionFrame:transition,offset:offset,phase:phase)
    }
}

final class DeepSeekFrontRetreat {
    static let shared = DeepSeekFrontRetreat()
    let frames: [NSImage]
    let transitionFrames: [NSImage]
    var available: Bool { frames.count == 8 && transitionFrames.count == 12 && DeepSeekScoot.shared.available }
    private init() {
        frames = (0..<8).compactMap { index in
            let folder = "DeepSeekThinking/FrontRetreat", name = String(format:"frame-%02d",index)
            let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder)
            return url.flatMap { NSImage(contentsOf:$0) }
        }
        transitionFrames = (0..<12).compactMap { index in
            let folder = "DeepSeekThinking/FrontRetreat/Transition", name = String(format:"frame-%02d",index)
            let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder)
            return url.flatMap { NSImage(contentsOf:$0) }
        }
    }
    func draw(_ sample: FrontRetreatTimeline.Sample,animation: MascotAnimation,in rect: NSRect,
              fromScootRest: Bool = false,entryImage: NSImage? = nil,entryRect: NSRect? = nil) {
        guard available else { return }
        let seated = NSRect(x:rect.midX-rect.width*384/448/2,y:rect.minY,
                            width:rect.width*384/448,height:rect.height*512/640)
        func rest() { DeepSeekScoot.shared.draw(.init(frame:7,offset:0,phase:"坐稳"),animation:animation,in:seated) }
        if sample.phase == .seated {
            if let entryImage, let entryRect {
                entryImage.draw(in:entryRect,from:.zero,operation:.sourceOver,fraction:1)
            } else if fromScootRest { rest() }
            else { animation.frames[0].draw(in:seated,from:.zero,operation:.sourceOver,fraction:1) }
            return
        }
        if let frame = sample.frame {
            frames[frame].draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
        } else if let frame = sample.transitionFrame {
            // Both endpoint handoffs reuse their original opaque artwork, rather than dissolving into it.
            if frame == 3 || (fromScootRest && frame < 3) { rest() }
            else if frame == 11 { frames[0].draw(in:rect,from:.zero,operation:.sourceOver,fraction:1) }
            else { transitionFrames[frame].draw(in:rect,from:.zero,operation:.sourceOver,fraction:1) }
        }
    }
}
