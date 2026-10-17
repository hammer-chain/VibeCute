import AppKit

/// Constant-space gesture recognition. Coordinates are relative to the head,
/// so gesture distances do not change with the user's character scale.
struct HeadPatGesture {
    private var previous: (point: NSPoint, time: TimeInterval)?
    private var startedAt: TimeInterval = 0
    private var startX: CGFloat = 0
    private var extremeX: CGFloat = 0
    private var direction: CGFloat = 0
    private var reversals = 0
    private var travel: CGFloat = 0
    private var cooldownUntil: TimeInterval = 0

    mutating func reset() {
        previous = nil; direction = 0; reversals = 0; travel = 0
    }

    mutating func update(_ point: NSPoint?, at time: TimeInterval) -> Bool {
        guard time.isFinite, time >= cooldownUntil else { reset(); return false }
        // Hair gaps and a briefly crossed contour must not erase an otherwise
        // deliberate stroke. Far-away pointers and button presses reset at
        // the caller; a sustained absence still clears the candidate here.
        guard let point, point.x.isFinite, point.y.isFinite else {
            if let last = previous, time-last.time <= 0.18 { return false }
            reset(); return false
        }
        guard let last = previous else {
            previous = (point, time); startedAt = time
            startX = point.x; extremeX = point.x
            return false
        }
        let dt = time - last.time
        guard dt > 0 else { return false }
        let dx = point.x - last.point.x, dy = point.y - last.point.y
        // A single pass already fails the reversal/duration checks. Rejecting
        // mouse speed here discarded ordinary accelerated physical movement.
        if dt > 0.45 || time - startedAt > 2.4 {
            reset(); return update(point, at: time)
        }
        // Repeated hover refreshes and subpixel jitter do not extend a stroke.
        guard hypot(dx, dy) >= 0.012 else { return false }
        previous = (point, time)
        travel += abs(dx)
        if direction == 0 {
            guard abs(point.x - startX) >= 0.12 else { return false }
            direction = point.x > startX ? 1 : -1
            extremeX = point.x
        } else if (point.x - extremeX) * direction >= 0 {
            extremeX = point.x
        } else if abs(point.x - extremeX) >= 0.12 {
            reversals += 1; direction = -direction; extremeX = point.x
        }
        guard reversals >= 1, travel >= 0.50, time - startedAt >= 0.22 else { return false }
        cooldownUntil = time + 2.2
        reset()
        return true
    }
}

/// A short, complete-pose response, followed by the latest ordinary animation.
/// No new sprites, texture caches, or persistent animation clocks are needed.
enum HeadPatReaction {
    static let duration: TimeInterval = 1.4
    struct Sample {
        let progress: CGFloat
        let amount: CGFloat
        let angle: CGFloat
        let dip: CGFloat
        let frame: Int
    }
    static func sample(elapsed: TimeInterval) -> Sample? {
        guard elapsed >= 0, elapsed < duration else { return nil }
        let p = CGFloat(elapsed / duration)
        func smooth(_ x: CGFloat) -> CGFloat { let v = min(1, max(0, x)); return v*v*(3-2*v) }
        let amount = smooth(p / 0.15) * (1 - smooth((p - 0.70) / 0.30))
        return Sample(progress: p, amount: amount,
            angle: sin(p * 4 * .pi) * 0.022 * amount, dip: -2 * amount,
            frame: p < 0.12 ? 0 : p < 0.24 ? 3 : p < 0.68 ? 4 : p < 0.82 ? 3 : 0)
    }
    static func transform(_ sample: Sample, anchor: NSPoint, scale: CGFloat) -> CGAffineTransform {
        let c = cos(sample.angle), s = sin(sample.angle)
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
            tx: anchor.x - c*anchor.x + s*anchor.y,
            ty: anchor.y - s*anchor.x - c*anchor.y + sample.dip*scale)
    }
    private static let heart: NSBezierPath = {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: -0.5))
        path.curve(to: NSPoint(x: -0.48, y: 0.18), controlPoint1: NSPoint(x: -0.18, y: -0.30), controlPoint2: NSPoint(x: -0.62, y: -0.02))
        path.curve(to: NSPoint(x: 0, y: 0.20), controlPoint1: NSPoint(x: -0.42, y: 0.55), controlPoint2: NSPoint(x: -0.12, y: 0.50))
        path.curve(to: NSPoint(x: 0.48, y: 0.18), controlPoint1: NSPoint(x: 0.12, y: 0.50), controlPoint2: NSPoint(x: 0.42, y: 0.55))
        path.curve(to: NSPoint(x: 0, y: -0.5), controlPoint1: NSPoint(x: 0.62, y: -0.02), controlPoint2: NSPoint(x: 0.18, y: -0.30))
        path.close(); return path
    }()
    static func drawHearts(_ sample: Sample, head: NSRect, bounds: NSRect, scale: CGFloat) {
        for index in 0..<2 {
            let age = sample.progress - CGFloat(index)*0.16
            guard age > 0, age < 0.75 else { continue }
            let alpha = min(1, age/0.12) * min(1, (0.75-age)/0.20) * 0.85
            let size = (index == 0 ? 9.0 : 7.0) * scale
            let x = min(bounds.maxX-size, max(bounds.minX+size, head.maxX + CGFloat(index == 0 ? -3 : 6)*scale))
            let y = min(bounds.maxY-size, head.midY + (8+age*20)*scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.translateBy(x: x, y: y)
            NSGraphicsContext.current?.cgContext.scaleBy(x: size, y: size)
            NSColor(srgbRed: 1, green: 0.46, blue: 0.62, alpha: alpha).setFill()
            heart.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
