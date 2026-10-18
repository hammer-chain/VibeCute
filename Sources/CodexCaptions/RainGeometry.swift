// Pure Swift; global logical points, x rightwards and y downwards (Quartz).
struct RainPoint: Equatable {
    var x: Double
    var y: Double
    static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: Self, scale: Double) -> Self { Self(x: a.x * scale, y: a.y * scale) }
}
struct RainRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    func expanded(_ amount: Double) -> Self {
        Self(x: x - amount, y: y - amount, width: width + 2 * amount, height: height + 2 * amount)
    }
    func contains(_ point: RainPoint) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }
}
struct RainHit {
    var time: Double // Parameter t in origin + direction * t; not seconds.
    var point: RainPoint
    var normal: RainPoint // Outward-facing surface normal.
}

struct RainBasinImpact {
    var source: String
    var hit: RainHit
    var scale: Double
}

/// Registered steel dome, at most nine points. Coordinates match rain/window
/// geometry (global Quartz points). The bounding box rejects distant drops.
struct RainBasinSurface {
    let source: String
    let points: [RainPoint]
    let bounds: RainRect
    let scale: Double
    init?(source: String, points: [RainPoint], scale: Double) {
        guard (2...9).contains(points.count), scale.isFinite, scale > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        self.source = source; self.points = points; self.scale = scale
        let xs = points.map(\.x), ys = points.map(\.y)
        bounds = RainRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
    }
    func overlaps(_ region: RainRect) -> Bool {
        bounds.maxX >= region.x && bounds.x <= region.maxX && bounds.maxY >= region.y && bounds.y <= region.maxY
    }
    func firstImpact(from start: RainPoint, to end: RainPoint) -> RainHit? {
        guard end.y > start.y,
              max(start.x,end.x) >= bounds.x, min(start.x,end.x) <= bounds.maxX,
              max(start.y,end.y) >= bounds.y, min(start.y,end.y) <= bounds.maxY else { return nil }
        let r = RainPoint(x:end.x-start.x,y:end.y-start.y)
        func cross(_ a: RainPoint,_ b: RainPoint) -> Double { a.x*b.y-a.y*b.x }
        var best: RainHit?
        for (a,b) in zip(points,points.dropFirst()) {
            let s = RainPoint(x:b.x-a.x,y:b.y-a.y), q = RainPoint(x:a.x-start.x,y:a.y-start.y)
            let denominator = cross(r,s)
            guard abs(denominator) > 1e-9 else { continue }
            let t = cross(q,s)/denominator, u = cross(q,r)/denominator
            guard t >= 0, t <= 1, u >= 0, u <= 1, best == nil || t < best!.time else { continue }
            let length = (s.x*s.x+s.y*s.y).squareRoot()
            guard length > 0 else { continue }
            var normal = RainPoint(x:s.y/length,y:-s.x/length)
            if normal.y > 0 { normal = normal * -1 }
            best = RainHit(time:t,point:start+r*t,normal:normal)
        }
        return best
    }
}

// Slab intersection works for vertical rays, angled rays, sides and thin windows.
// maxTime = 1 tests the complete swept segment; infinity tests a ray.
func rayHit(origin: RainPoint, direction: RainPoint, rect: RainRect,
            maxTime: Double = .infinity) -> RainHit? {
    guard rect.width > 0, rect.height > 0, maxTime >= 0,
          direction.x != 0 || direction.y != 0 else { return nil }
    var near = -Double.infinity
    var far = Double.infinity
    var normal = RainPoint(x: 0, y: 0)
    for axis in 0..<2 {
        let start = axis == 0 ? origin.x : origin.y
        let delta = axis == 0 ? direction.x : direction.y
        let lower = axis == 0 ? rect.x : rect.y
        let upper = axis == 0 ? rect.maxX : rect.maxY
        if abs(delta) < 1e-12 {
            if start < lower || start > upper { return nil }
            continue
        }
        let a = (lower - start) / delta
        let b = (upper - start) / delta
        let entry = min(a, b)
        let leave = max(a, b)
        if entry > near {
            near = entry
            let sign = delta > 0 ? -1.0 : 1.0
            normal = axis == 0 ? RainPoint(x: sign, y: 0) : RainPoint(x: 0, y: sign)
        }
        far = min(far, leave)
        if near > far { return nil }
    }
    guard far >= 0, near <= maxTime else { return nil }
    let t = max(0, near)
    return RainHit(time: t, point: origin + direction * t, normal: normal)
}

struct RoofField {
    var windows: [RainRect] = []
    // Trace backwards into the wind. A blocked upstream ray means rain cannot
    // reach this point, including the diagonal shadow beyond a window's bottom.
    func isSheltered(_ point: RainPoint, wind: Double, padding: Double = 0) -> Bool {
        windows.contains { rect in
            guard rect.width > 0, rect.height > 0 else { return false }
            return rayHit(origin: point, direction: RainPoint(x: -wind, y: -1), rect: rect.expanded(padding)) != nil
        }
    }
    func firstImpact(from start: RainPoint, to end: RainPoint, padding: Double = 0) -> RainHit? {
        let delta = RainPoint(x: end.x - start.x, y: end.y - start.y)
        var nearest: RainHit?
        for rect in windows where rect.width > 0 && rect.height > 0 {
            if let hit = rayHit(origin: start, direction: delta, rect: rect.expanded(padding), maxTime: 1),
               nearest == nil || hit.time < nearest!.time {
                nearest = hit
            }
        }
        return nearest
    }
}

func floorImpact(from start: RainPoint, to end: RainPoint, floorY: Double) -> RainHit? {
    guard end.y > start.y, start.y <= floorY, end.y >= floorY else { return nil }
    let t = (floorY - start.y) / (end.y - start.y)
    return RainHit(time: t, point: RainPoint(x: start.x + (end.x - start.x) * t, y: floorY), normal: RainPoint(x: 0, y: -1))
}

enum DesktopWeatherStyle: String { case rain, snow, thunder }

/// One clock shared by every display and the single audio owner. A distant
/// rumble follows each local bolt; neither display count nor redraws multiply it.
enum WeatherStormTiming {
    static let period = 12.0
    struct Event {
        var cycle: Int
        var lightningAt: Double
        var soundAt: Double
        var gain: Double
    }
    // Stateless seeded samples: every display and sound use exactly the same event.
    // Keep each bolt + delayed rumble within its slot, with no catch-up backlog.
    static func event(at time: Double, seed: UInt64 = 0) -> Event {
        let cycle = Int(max(0, time.isFinite ? time : 0) / period)
        func sample(_ lane: UInt64) -> Double {
            var x = seed &+ UInt64(cycle) &* 0x9e3779b97f4a7c15 &+ lane
            x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
            x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
            x ^= x >> 31
            return Double(x >> 11) / 9007199254740992
        }
        let bolt = Double(cycle) * period + 1 + sample(1) * 4
        return Event(cycle: cycle, lightningAt: bolt, soundAt: bolt + 0.45 + sample(2) * 1.05,
                     gain: 0.65 + sample(3) * 0.35)
    }
    static func showsLightning(at time: Double, seed: UInt64 = 0) -> Bool {
        let event = event(at: time, seed: seed)
        return time >= event.lightningAt && time < event.lightningAt + 0.28
    }
    static func soundCycle(at time: Double, seed: UInt64 = 0) -> Int? {
        let event = event(at: time, seed: seed)
        return time >= event.soundAt ? event.cycle : nil
    }
}

/// Fixed-size normalized geometry, generated once per bolt, never per draw.
struct WeatherLightningShape {
    var trunk: [RainPoint]
    var branches: [[RainPoint]]
    init(seed: UInt64, cycle: Int) {
        var state = seed &+ UInt64(cycle) &* 0x9e3779b97f4a7c15
        func random() -> Double {
            state &+= 0x9e3779b97f4a7c15
            var x = state
            x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
            x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
            return Double((x ^ (x >> 31)) >> 11) / 9007199254740992
        }
        let startX = 0.2 + random()*0.6, startY = 0.02 + random()*0.1
        let length = 0.4 + random()*0.45, drift = (random()-0.5)*0.55
        trunk = (0...18).map { i in
            let t = Double(i)/18
            return RainPoint(x:min(0.95,max(0.05,startX+drift*t+(i == 0 ? 0 : (random()-0.5)*0.065))),
                             y:startY+length*t)
        }
        branches = []
        let count = 3 + Int(random()*4)
        for branch in 0..<count {
            let root = trunk[3 + branch*2 + Int(random()*2)]
            let direction = random() < 0.5 ? -1.0 : 1.0
            let reach = 0.08 + random()*0.16
            branches.append((0...5).map { i in
                let t = Double(i)/5
                return RainPoint(x:root.x+direction*reach*t+(i == 0 ? 0 : (random()-0.5)*0.035),
                                 y:root.y+t*(0.08+reach*0.45))
            })
        }
    }
}

enum DesktopWeatherPreview: String, CaseIterable, Identifiable {
    case drizzle = "小雨", rain = "中雨", heavyRain = "大雨", snow = "下雪", thunder = "雷雨"
    var id: String { rawValue }
    var settings: RainSettings {
        switch self {
        case .drizzle: return RainSettings(size: 0.7, speed: 0.65, quantity: 0.4)
        case .rain: return RainSettings()
        case .heavyRain: return RainSettings(size: 1.5, speed: 1.6, wind: 0.35, quantity: 2.8)
        case .snow: return RainSettings(style: .snow)
        case .thunder: return RainSettings(size: 1.3, speed: 1.4, wind: -0.25, quantity: 2, style: .thunder)
        }
    }
}

struct RainSettings: Equatable {
    var size = 1.0
    var speed = 1.0
    var wind = 0.0 // Horizontal / vertical velocity; positive means blowing right.
    var quantity = 1.0
    var style: DesktopWeatherStyle = .rain
}

func quartzRect(appKit rect: RainRect, mainDisplayTop: Double) -> RainRect {
    RainRect(x: rect.x, y: mainDisplayTop - rect.maxY, width: rect.width, height: rect.height)
}
