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
    static func showsLightning(at time: Double) -> Bool {
        let phase = time.truncatingRemainder(dividingBy: period)
        return phase >= 1 && phase < 1.28
    }
    static func soundCycle(at time: Double) -> Int? {
        guard time.isFinite, time >= 1.55 else { return nil }
        return Int((time-1.55)/period)
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
