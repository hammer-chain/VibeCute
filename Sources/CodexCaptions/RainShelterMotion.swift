import Foundation

/// AppKit coordinates throughout. Destinations must fit inside the foreground
/// window itself; its rain shadow below the bottom edge is not a destination.
enum RainShelterRoute: Equatable {
    case shelter(CGPoint)
    case pace(minX: Double, maxX: Double, y: Double)
}

enum RainShelterPlanner {
    /// AppKit artwork bounds against the existing Quartz window snapshot.
    /// A rain shadow below a window or a partial overlap is not containment.
    static func isInsideWindow(body: CGRect, windows: [RainRect], displayTop: Double) -> Bool {
        guard !body.isEmpty, !body.isNull else { return false }
        return windows.contains { window in
            CGRect(x:window.x,y:displayTop-window.maxY,width:window.width,height:window.height).contains(body)
        }
    }

    static func route(origin: CGPoint, anchor: CGPoint, body: CGRect, allowed: CGRect,
                      window: CGRect?, wind: Double, scale: Double, windows: [CGRect] = []) -> RainShelterRoute {
        func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
        guard !allowed.isNull, allowed.width >= 0, allowed.height >= 0 else {
            return .pace(minX: origin.x, maxX: origin.x, y: origin.y)
        }
        let margin = 8 * scale
        func destination(in window: CGRect) -> CGPoint? {
            guard window.width > 1, window.height > 1, wind.isFinite else { return nil }
            // Intersect the window's full-body interior with the legal group
            // origins (including caption/screen constraints), not just one edge.
            let loX = max(allowed.minX,window.minX+margin-body.minX)
            let hiX = min(allowed.maxX,window.maxX-margin-body.maxX)
            let bottomY = window.minY+margin-body.minY
            let loY = max(allowed.minY,bottomY)
            let hiY = min(allowed.maxY,window.maxY-margin-body.maxY)
            guard loX <= hiX, loY <= hiY else { return nil }
            let y = (loY...hiY).contains(bottomY) ? bottomY : clamp(origin.y,loY,hiY)
            return CGPoint(x:clamp(origin.x,loX,hiX),y:y)
        }
        if let window, let point = destination(in:window) { return .shelter(point) }
        for candidate in windows {
            if let window, candidate == window { continue }
            if let point = destination(in:candidate) { return .shelter(point) }
        }
        let center = clamp(anchor.x,allowed.minX,allowed.maxX)
        return .pace(minX:max(allowed.minX,center-56*scale),
                     maxX:min(allowed.maxX,center+56*scale),
                     y:clamp(anchor.y,allowed.minY,allowed.maxY))
    }
}

struct RainShelterSample: Equatable {
    enum Phase: String { case idle, raising, running, lowering, stowing, sheltered }
    var origin: CGPoint
    var frame: Int?
    var mirrored: Bool
    var phase: Phase
}

/// No timers, IO or window queries. Driven by the app's existing animation clock.
struct RainShelterMotion {
    // Frame 22 places the basin down; go straight to frame 25's reaching pose.
    // Frames 23/24 sit upright before reaching again and are intentionally skipped.
    static let entryDuration = 1.6, exitDuration = 1.5, stowDuration = 1.2
    private(set) var origin: CGPoint
    private(set) var phase: RainShelterSample.Phase = .idle
    private var phaseStart: Double
    private var lastTime: Double
    private var runStart: Double
    private var mirrored = false
    private var headingRight = true
    init(origin: CGPoint, at now: Double) {
        self.origin = origin
        phaseStart = now; lastTime = now; runStart = now
    }
    mutating func update(at now: Double, raining: Bool, route: RainShelterRoute, scale: Double) -> RainShelterSample {
        let dt = max(0,min(0.1,now-lastTime)); lastTime = now
        func target() -> CGPoint {
            switch route {
            case .shelter(let p): return p
            case .pace(let lo,let hi,let y): return CGPoint(x:headingRight ? hi : lo,y:y)
            }
        }
        func needsTravel() -> Bool {
            if case .pace = route { return true }
            return hypot(target().x-origin.x,target().y-origin.y) > 1
        }
        if !raining {
            if phase == .raising || phase == .running { phase = .lowering; phaseStart = now }
            else if phase == .sheltered { phase = .idle }
        } else if phase == .idle || phase == .sheltered {
            if needsTravel() { phase = .raising; phaseStart = now }
            else { phase = .sheltered }
        }
        if phase == .raising, now-phaseStart >= Self.entryDuration {
            phase = .running; phaseStart = now; runStart = now
        }
        if phase == .running {
            let p = target(), dx = p.x-origin.x, dy = p.y-origin.y, distance = hypot(dx,dy)
            if abs(dx) > 0.1 { mirrored = dx < 0 }
            let step = 130*scale*dt
            if distance <= step || distance < 0.01 {
                origin = p
                switch route {
                case .shelter: phase = .lowering; phaseStart = now
                case .pace: headingRight.toggle()
                }
            } else {
                origin.x += dx/distance*step; origin.y += dy/distance*step
            }
        }
        if phase == .lowering, now-phaseStart >= Self.exitDuration {
            phase = .stowing; phaseStart += Self.exitDuration
        }
        if phase == .stowing, now-phaseStart >= Self.stowDuration {
            phase = raining ? .sheltered : .idle
        }
        let frame: Int?
        switch phase {
        case .idle: frame = nil
        case .raising: frame = min(7,Int(max(0,now-phaseStart)/0.2))
        case .running: frame = 8+Int(max(0,now-runStart)/0.1)%8
        case .lowering: frame = 16+min(5,Int(max(0,now-phaseStart)/0.25))
        case .stowing: frame = 24+min(7,Int(max(0,now-phaseStart)/0.15))
        case .sheltered: frame = nil
        }
        return RainShelterSample(origin:origin,frame:frame,
            mirrored:mirrored && (phase == .running || (phase == .lowering && (frame ?? 24)<18)),phase:phase)
    }
}
