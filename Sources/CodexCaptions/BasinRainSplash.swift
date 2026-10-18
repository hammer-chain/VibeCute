import AppKit

/// World-space splash particles keep their trajectory when the character runs.
/// At most 64 per character, advanced by the existing shelter animation clock.
struct BasinRainSplash {
    private struct Particle {
        var origin: RainPoint
        var velocity: RainPoint
        var birth: Double
        var radius: Double
        var scale: Double
    }
    private var particles: [Particle] = []
    private(set) var clock = 0.0
    var count: Int { particles.count }
    mutating func clear() { particles.removeAll(keepingCapacity:true) }
    mutating func add(_ impact: RainBasinImpact, at now: Double) {
        clock = now
        for direction in [-1.0,-0.45,0.45,1.0] where particles.count < 64 {
            let s = impact.scale
            particles.append(Particle(origin:impact.hit.point+impact.hit.normal*(1.2*s),
                velocity:RainPoint(x:direction*Double.random(in:18...43)*s+impact.hit.normal.x*18*s,
                                   y:-Double.random(in:45...76)*s),
                birth:now,radius:Double.random(in:0.65...1.15)*s,scale:s))
        }
    }
    @discardableResult mutating func advance(at now: Double) -> Bool {
        let had = !particles.isEmpty
        clock = now
        particles.removeAll { now-$0.birth >= 0.36 || now < $0.birth }
        return had
    }
    func draw(in context: CGContext, panelOrigin: CGPoint, displayTop: Double) {
        for p in particles {
            let age = max(0,clock-p.birth)
            guard age < 0.36 else { continue }
            let world = p.origin+p.velocity*age+RainPoint(x:0,y:150*p.scale*age*age)
            let x = world.x-panelOrigin.x, y = displayTop-world.y-panelOrigin.y
            let alpha = 0.95*(1-age/0.36)
            context.setStrokeColor(NSColor(calibratedRed:0.76,green:0.91,blue:1,alpha:alpha).cgColor)
            context.setLineWidth(p.radius*1.3)
            context.setLineCap(.round)
            context.move(to:CGPoint(x:x,y:y))
            context.addLine(to:CGPoint(x:x+p.velocity.x*0.018,y:y-(p.velocity.y+300*p.scale*age)*0.018))
            context.strokePath()
            if age < 0.09 {
                let ox = p.origin.x-panelOrigin.x, oy = displayTop-p.origin.y-panelOrigin.y
                context.setStrokeColor(NSColor(white:1,alpha:0.32*(1-age/0.09)).cgColor)
                context.strokeEllipse(in:CGRect(x:ox-2.5*p.scale,y:oy-0.8*p.scale,width:5*p.scale,height:1.6*p.scale))
            }
        }
    }
}
