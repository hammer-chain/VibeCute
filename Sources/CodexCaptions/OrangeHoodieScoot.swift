import AppKit

/// Small seated weight shifts using the existing artwork. No new atlas, timer,
/// per-tick decoding, body crossfade, or independent face transform.
enum OrangeHoodieScoot {
    struct Pose: Equatable {
        let progress: Double
        let direction: CGFloat
        var transform: CGAffineTransform {
            let p = min(1,max(0,progress))
            let envelope = pow(sin(.pi*p),2)
            let angle = direction*0.09*envelope*(1-2*p)
            // Coordinates are the original 384x512 seated canvas.
            let pivot = CGPoint(x:192,y:20)
            return CGAffineTransform(translationX:direction*3*envelope,y:6*envelope)
                .translatedBy(x:pivot.x,y:pivot.y).rotated(by:angle)
                .translatedBy(x:-pivot.x,y:-pivot.y)
        }
    }
    static func draw(_ pose: Pose, frame: Int, in rect: NSRect) {
        let context = NSGraphicsContext.current!.cgContext
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.translateBy(x:rect.minX,y:rect.minY)
        context.scaleBy(x:rect.width/384,y:rect.height/512)
        context.concatenate(pose.transform)
        MascotAnimation.orangeHoodie.drawSeated(frame:frame,mouth:nil,
            in:NSRect(x:0,y:0,width:384,height:512),at:0,motionAmount:0)
    }
}
