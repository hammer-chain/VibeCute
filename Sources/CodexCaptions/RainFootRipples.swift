import Foundation

struct RainFootprint {
    var source: String
    var point: RainPoint // Foot baseline, global Quartz coordinates.
    var scale: Double
}
struct RainFootRipple {
    var point: RainPoint
    var birth: Double
    var scale: Double
    static let lifetime = 1.05
}

/// World-space footsteps share the rain clock. No IO, timers or unbounded trails.
struct RainFootRipples {
    private struct Track {
        var point: RainPoint
        var scale: Double
        var distance = 0.0
        var lastStep = -Double.infinity
        var left = false
    }
    private var tracks: [String: Track] = [:]
    private(set) var rings: [RainFootRipple] = []
    private(set) var emitted = 0
    private var clock: Double?
    mutating func clear() { tracks.removeAll(keepingCapacity:true); rings.removeAll(keepingCapacity:true); clock = nil }
    mutating func advance(at now: Double, feet: [RainFootprint], field: RoofField, wind: Double) {
        guard now.isFinite else { clear(); return }
        if let clock, now < clock { clear() }
        clock = now
        rings.removeAll { now-$0.birth >= RainFootRipple.lifetime || field.isSheltered($0.point,wind:wind) }
        var next: [String: Track] = [:]
        for foot in feet.prefix(16) {
            guard foot.point.x.isFinite, foot.point.y.isFinite, foot.scale.isFinite,
                  (0.2...4).contains(foot.scale) else { continue }
            var track = tracks[foot.source] ?? Track(point:foot.point,scale:foot.scale)
            let dx = foot.point.x-track.point.x, dy = foot.point.y-track.point.y
            let distance = hypot(dx,dy)
            let old = track.point
            track.point = foot.point
            if abs(track.scale-foot.scale) > 0.001 || distance > 100*foot.scale ||
               field.isSheltered(foot.point,wind:wind) || field.isSheltered(old,wind:wind) ||
               field.firstImpact(from:old,to:foot.point) != nil {
                track.distance = 0; track.scale = foot.scale
                next[foot.source] = track; continue
            }
            if distance < 0.35*foot.scale {
                track.distance = 0
            } else {
                track.distance += distance
                if track.distance >= 30*foot.scale, now-track.lastStep >= 0.24 {
                    let point = RainPoint(x:foot.point.x+(track.left ? -10 : 10)*foot.scale,y:foot.point.y)
                    if !field.isSheltered(point,wind:wind) {
                        if rings.count >= 32 { rings.removeFirst() }
                        rings.append(RainFootRipple(point:point,birth:now,scale:foot.scale))
                        emitted += 1
                        track.lastStep = now; track.left.toggle()
                    }
                    track.distance = 0
                }
            }
            next[foot.source] = track
        }
        tracks = next
    }
}
