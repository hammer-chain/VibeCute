import AppKit

private struct Drop {
    var point: RainPoint
    var speed: Double
    var length: Double
}
private struct Splash {
    var point: RainPoint
    var velocity: RainPoint
    var life: Double
    var radius: Double
}

final class RainView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    let region: RainRect
    private var drops: [Drop] = []
    private var splashes: [Splash] = []
    private var birthBudget = 0.0
    private var field = RoofField()
    private var settings = RainSettings()
    private var enabled = true
    private var elapsed = 0.0
    private var stormSeed: UInt64 = 0
    private var lightningShape: WeatherLightningShape?
    private var lightningKey: String?
    // A shared 256 KiB halo, instead of shading full-screen gradients every flash.
    private static let lightningGlow: CGImage? = {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:0,
            space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [NSColor(calibratedRed:0.65,green:0.8,blue:1,alpha:0.24).cgColor,
                      NSColor(calibratedRed:0.4,green:0.65,blue:1,alpha:0.07).cgColor,
                      NSColor(calibratedRed:0.4,green:0.65,blue:1,alpha:0).cgColor] as CFArray
        guard let glow = CGGradient(colorsSpace:space,colors:colors,locations:[0,0.35,1]) else { return nil }
        bitmap.drawRadialGradient(glow,startCenter:CGPoint(x:128,y:128),startRadius:0,
            endCenter:CGPoint(x:128,y:128),endRadius:128,options:[])
        return bitmap.makeImage()
    }()
    private var snowflakes: [Splash] = []
    private(set) var basinImpacts: [RainBasinImpact] = []
    private(set) var basinHits = 0
    var particleCount: Int { drops.count + splashes.count + snowflakes.count }

    init(frame: NSRect, region: RainRect) {
        self.region = region
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func clear() {
        basinImpacts.removeAll(keepingCapacity:true)
        drops.removeAll()
        splashes.removeAll()
        birthBudget = 0
        snowflakes.removeAll(); elapsed = 0
        needsDisplay = true
    }

    private func addSplash(at hit: RainHit) {
        guard region.contains(hit.point), splashes.count <= 596 else { return }
        let radius = 0.9 * settings.size
        // Start outside the hit surface. Floor particles are above the screen
        // bottom and launched upwards, so they survive long enough to be seen.
        let origin = hit.point + hit.normal * (radius + 1)
        for direction in [-1.0, -0.5, 0.5, 1.0] {
            let vx = hit.normal.x != 0
                ? hit.normal.x * Double.random(in: 35...90)
                : direction * Double.random(in: 35...90)
            splashes.append(Splash(point: origin,
                velocity: RainPoint(x: vx, y: -Double.random(in: 55...110)),
                life: 0.35, radius: radius))
        }
    }

    func step(dt: Double, field: RoofField, enabled: Bool, settings: RainSettings, weatherTime: Double? = nil,
              basins: [RainBasinSurface] = [], stormSeed: UInt64 = 0) {
        self.stormSeed = stormSeed
        basinImpacts.removeAll(keepingCapacity:true)
        // Preserve particles during live slider drags. Every surviving drop is
        // checked against the new wind's backwards ray and updated size below;
        // only newly sheltered drops are removed, never the whole rain field.
        if self.settings.style != settings.style { clear() }
        self.settings = settings
        self.field = field
        self.enabled = enabled
        guard enabled else { clear(); return }
        elapsed = weatherTime ?? (elapsed + dt)
        if settings.style == .snow {
            stepSnow(dt: dt, field: field); needsDisplay = true; return
        }
        let radius = 0.5 * settings.size
        // Entry flux is proportional to projected top + upwind side length.
        // Sampling both edges avoids an empty upwind wedge under angled rain.
        let topWeight = region.width
        let sideWeight = abs(settings.wind) * region.height
        let totalWeight = topWeight + sideWeight
        birthBudget += dt * totalWeight * 0.075 * settings.quantity
        let count = min(Int(birthBudget), 100)
        birthBudget -= Double(count)
        for _ in 0..<count where drops.count < 1600 {
            let point: RainPoint
            if Double.random(in: 0..<totalWeight) < topWeight {
                point = RainPoint(x: Double.random(in: region.x..<region.maxX), y: region.y)
            } else {
                point = RainPoint(x: settings.wind > 0 ? region.x : region.maxX,
                                  y: Double.random(in: region.y..<region.maxY))
            }
            if !field.isSheltered(point, wind: settings.wind, padding: radius) {
                drops.append(Drop(point: point, speed: Double.random(in: 540...840), length: Double.random(in: 10...22)))
            }
        }
        var survivors: [Drop] = []
        survivors.reserveCapacity(drops.count)
        let activeBasins = basins.prefix(2)
        for var drop in drops {
            if field.isSheltered(drop.point, wind: settings.wind, padding: radius) { continue }
            let verticalDistance = drop.speed * settings.speed * dt
            let next = drop.point + RainPoint(x: settings.wind * verticalDistance, y: verticalDistance)
            let windowHit = field.firstImpact(from: drop.point, to: next, padding: radius)
            let groundHit = floorImpact(from: drop.point, to: next, floorY: region.maxY - radius)
            let hit: RainHit?
            if let a = windowHit, let b = groundHit { hit = a.time <= b.time ? a : b }
            else { hit = windowHit ?? groundHit }
            if !activeBasins.isEmpty {
                var basinHit: RainBasinImpact?
                for basin in activeBasins {
                    if let contact = basin.firstImpact(from:drop.point,to:next),
                       (hit == nil || contact.time < hit!.time),
                       (basinHit == nil || contact.time < basinHit!.hit.time),
                       !field.isSheltered(contact.point,wind:settings.wind) {
                        basinHit = RainBasinImpact(source:basin.source,hit:contact,scale:basin.scale)
                    }
                }
                if let basinHit {
                    basinHits += 1
                    if basinImpacts.count < 12 { basinImpacts.append(basinHit) }
                    continue // Steel stops the drop; the splash draws above the mascot.
                }
            }
            if let hit = hit {
                addSplash(at: hit)
                continue
            }
            drop.point = next
            if region.contains(next) { survivors.append(drop) }
        }
        drops = survivors
        splashes = splashes.compactMap { old in
            var s = old
            s.life -= dt
            s.point = s.point + s.velocity * dt
            s.velocity.y += 420 * dt
            guard s.life > 0, s.point.y + s.radius < region.maxY,
                  s.point.x >= region.x, s.point.x <= region.maxX,
                  !field.isSheltered(s.point, wind: settings.wind, padding: s.radius),
                  field.firstImpact(from: old.point, to: s.point, padding: s.radius) == nil else { return nil }
            return s
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        guard enabled else { return }
        switch settings.style {
        case .snow:
            context.setFillColor(NSColor(white: 1, alpha: 0.8).cgColor)
            context.beginPath()
            for flake in snowflakes {
                context.addEllipse(in: CGRect(x: flake.point.x - region.x, y: flake.point.y - region.y,
                                              width: flake.radius * 2, height: flake.radius * 2))
            }
            context.fillPath(); return
        case .thunder: drawLightning(context)
        case .rain: break
        }
        context.setLineWidth(CGFloat(settings.size))
        context.setLineCap(.round)
        context.setStrokeColor(NSColor(calibratedRed: 0.62, green: 0.79, blue: 0.96, alpha: 0.48).cgColor)
        context.beginPath()
        let directionLength = (1 + settings.wind * settings.wind).squareRoot()
        for drop in drops {
            let lengthY = drop.length * settings.size / directionLength
            context.move(to: CGPoint(x: drop.point.x - settings.wind * lengthY - region.x,
                                    y: drop.point.y - lengthY - region.y))
            context.addLine(to: CGPoint(x: drop.point.x - region.x, y: drop.point.y - region.y))
        }
        context.strokePath()
        for splash in splashes {
            context.setFillColor(NSColor(calibratedRed: 0.72, green: 0.86, blue: 1, alpha: 0.65 * splash.life / 0.35).cgColor)
            context.fillEllipse(in: CGRect(x: splash.point.x - region.x - splash.radius,
                y: splash.point.y - region.y - splash.radius, width: splash.radius * 2, height: splash.radius * 2))
        }
    }

    private func stepSnow(dt: Double, field: RoofField) {
        birthBudget += dt * region.width * 0.012
        let count = min(Int(birthBudget), 20); birthBudget -= Double(count)
        for _ in 0..<count where snowflakes.count < 240 {
            let point = RainPoint(x: Double.random(in: region.x...region.maxX), y: region.y)
            if !field.isSheltered(point, wind: 0) {
                snowflakes.append(Splash(point: point, velocity: RainPoint(x: Double.random(in: -12...12), y: Double.random(in: 35...80)),
                                         life: Double.random(in: 0...6.28), radius: Double.random(in: 1.2...3)))
            }
        }
        snowflakes = snowflakes.compactMap { old in
            var flake = old
            flake.point = flake.point + RainPoint(x: flake.velocity.x + sin(elapsed + flake.life) * 15, y: flake.velocity.y) * dt
            guard region.contains(flake.point), !field.isSheltered(flake.point, wind: 0),
                  field.firstImpact(from: old.point, to: flake.point) == nil else { return nil }
            return flake
        }
    }

    private func drawLightning(_ context: CGContext) {
        guard WeatherStormTiming.showsLightning(at: elapsed, seed: stormSeed) else { return }
        let event = WeatherStormTiming.event(at:elapsed,seed:stormSeed)
        let key = "\(stormSeed)-\(event.cycle)"
        if lightningKey != key {
            lightningShape = WeatherLightningShape(seed:stormSeed,cycle:event.cycle); lightningKey = key
        }
        guard let shape = lightningShape else { return }
        let age = elapsed-event.lightningAt
        let pulse = age < 0.055 ? 1.0 : age < 0.10 ? 0.22 : age < 0.16 ? 0.95 : age < 0.21 ? 0.18 : 0.55
        func point(_ p: RainPoint) -> CGPoint { CGPoint(x:p.x*bounds.width,y:p.y*bounds.height) }
        context.saveGState(); defer { context.restoreGState() }
        // Local illumination fades out around the bolt; no opaque full-screen wash.
        if let glow = Self.lightningGlow {
            context.setAlpha(pulse); context.interpolationQuality = .none
            let radius = min(bounds.width,bounds.height)*0.5
            let center = point(shape.trunk[9])
            context.draw(glow,in:CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
            context.setAlpha(1)
        }
        func path(_ points: [RainPoint], width: CGFloat, alpha: Double, white: Bool = false) {
            context.beginPath(); context.move(to:point(points[0]))
            for p in points.dropFirst() { context.addLine(to:point(p)) }
            context.setLineWidth(width); context.setLineJoin(.round); context.setLineCap(.round)
            context.setStrokeColor(NSColor(calibratedRed:white ? 1 : 0.65,
                green:white ? 1 : 0.82,blue:1,alpha:alpha*pulse).cgColor)
            context.strokePath()
        }
        path(shape.trunk,width:18,alpha:0.07)
        path(shape.trunk,width:8,alpha:0.23)
        for branch in shape.branches {
            path(branch,width:5,alpha:0.16); path(branch,width:1.25,alpha:0.85,white:true)
        }
        path(shape.trunk,width:3.5,alpha:0.95)
        path(shape.trunk,width:1.6,alpha:1,white:true)
    }
}
