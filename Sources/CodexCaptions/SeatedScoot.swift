import AppKit

/// Three seated pushes out, a pause, then three pushes back to the preview anchor.
enum SeatedScootTimeline {
    struct Sample: Equatable {
        let frame: Int
        let offset: Double
        let phase: String
        var pushPhase: Double = 0
    }
    static let cycle = 1.12
    static let duration = 8.52
    static func sample(at t: TimeInterval) -> Sample? {
        guard t.isFinite, t >= 0, t < duration else { return nil }
        if t < 0.6 { return Sample(frame: 0, offset: 0, phase: "坐姿准备") }
        let returning = t >= 4.56
        let start = returning ? 4.56 : 0.6
        let elapsed = t-start
        if !returning && elapsed >= cycle*3 {
            return Sample(frame: 7, offset: 3, phase: "坐稳停留")
        }
        if returning && elapsed >= cycle*3 {
            return Sample(frame: 7, offset: 0, phase: "回到坐姿")
        }
        let step = min(2, Int(elapsed/cycle))
        let p = (elapsed-Double(step)*cycle)/cycle
        // Translation happens while the palms push, never during preparation/recovery.
        let push = min(1, max(0, (p-0.25)/0.375))
        let eased = push*push*(3-2*push)
        let distance = Double(step)+eased
        return Sample(frame: min(7, Int(p*8)), offset: returning ? 3-distance : distance,
            phase: returning ? "坐着向左挪动" : "坐着向右挪动")
    }
}

final class DeepSeekScoot {
    static let shared = DeepSeekScoot()
    let frames: [NSImage]
    var available: Bool { frames.count == 8 }
    private init() {
        frames = (0..<8).compactMap { index in
            let folder = "DeepSeekThinking/Scoot", name = String(format: "frame-%02d", index)
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder)
                ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder)
            return url.flatMap { NSImage(contentsOf: $0) }
        }
    }
    func draw(_ sample: SeatedScootTimeline.Sample, animation: MascotAnimation, in rect: NSRect) {
        guard available else { return }
        let wide = NSRect(x:rect.midX-rect.width*448/384/2,y:rect.minY,width:rect.width*448/384,height:rect.height)
        frames[sample.frame].draw(in: wide, from: .zero, operation: .sourceOver, fraction: 1)
    }

    func drawRest(animation: MascotAnimation, mouth: Int?, in rect: NSRect, at time: Double, motionAmount: CGFloat) {
        guard available else { return }
        let wide = NSRect(x:rect.midX-rect.width*448/384/2,y:rect.minY,width:rect.width*448/384,height:rect.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.concatenate(animation.seatedTransform(in:wide,at:time,amount:motionAmount))
        frames[7].draw(in:wide,from:.zero,operation:.sourceOver,fraction:1)
        if let mouth { animation.drawMouth(mouth,in:wide,anchor:NSRect(x:192,y:257,width:31,height:25)) }
        NSGraphicsContext.restoreGraphicsState()
    }
}
