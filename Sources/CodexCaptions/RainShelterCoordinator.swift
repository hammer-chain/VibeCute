import AppKit
#if canImport(CaptionCore)
import CaptionCore
#endif

/// Per-visible-whale ownership. Shares the rain overlay's existing 10Hz window
/// snapshot, plans at 2Hz and moves at <=30Hz using the existing app clock.
final class RainShelterCoordinator {
    private struct Actor {
        var motion: RainShelterMotion
        var route: RainShelterRoute
        var lastPlan = -Double.infinity
        var scale = 0.0
        var screen = CGRect.zero
        var controlling = false
        var fallbackAnchor: CGPoint?
    }
    private let overlays: ProjectOverlays
    private var actors: [CaptionMascot: Actor] = [:]
    private var cooldown: [CaptionMascot: Double] = [:]
    private var lastTick = -Double.infinity
    private(set) var plans = 0
    private(set) var ticks = 0
    var sources: Set<CaptionMascot> { Set(actors.keys) }
    init(overlays: ProjectOverlays) { self.overlays = overlays }
    private func stop(_ source: CaptionMascot) {
        if actors[source]?.controlling == true { overlays.endBackdropRelocation(for:source) }
        overlays.clearRainShelter(for:source); actors.removeValue(forKey:source)
    }
    func stopAll() { for source in Array(actors.keys) { stop(source) } }
    func update(_ snapshot: RainShelterSnapshot, enabled: Bool, at now: Double) {
        guard enabled, !snapshot.suspended else { stopAll(); return }
        guard snapshot.raining || !actors.isEmpty else { return }
        let slot = floor(now*30)
        guard slot > lastTick else { return }; lastTick = slot; ticks += 1
        let visible = overlays.rainShelterActors
        let present = Set(visible.map(\.source))
        for source in Array(actors.keys) where !present.contains(source) { stop(source) }
        for (source,character) in visible {
            guard !character.panel.isManuallyDragging, !character.subtitle.dragReaction.active,
                  character.subtitle.screenEdgeDock == nil, !character.subtitle.headPatActive,
                  !overlays.backdropRelocationInterrupted(for:source) || actors[source]?.controlling != true,
                  let screen = character.panel.screen else {
                stop(source); cooldown[source] = now+3; continue
            }
            guard now >= cooldown[source,default:0] else { continue }
            if actors[source] == nil {
                guard snapshot.raining, DeepSeekRainArtwork.shared.available else { continue }
                let origin = character.panel.frame.origin
                actors[source] = Actor(motion:RainShelterMotion(origin:origin,at:now),
                    route:.pace(minX:origin.x,maxX:origin.x,y:origin.y))
            }
            guard var actor = actors[source] else { continue }
            let scale = Double(character.subtitle.layoutScale)
            if now-actor.lastPlan >= 0.5 || actor.scale != scale || actor.screen != screen.visibleFrame {
                actor.lastPlan = now; actor.scale = scale; actor.screen = screen.visibleFrame; plans += 1
                let body = DeepSeekRainArtwork.body(in:character.subtitle.bounds,scale:scale)
                var allowed = overlays.rainShelterAllowedOrigins(for:source,in:screen.visibleFrame)
                if allowed.isNull {
                    let a = screen.visibleFrame
                    allowed = CGRect(x:a.minX-body.minX,y:a.minY-body.minY,
                        width:max(0,a.width-body.width),height:max(0,a.height-body.height))
                }
                let window: CGRect? = snapshot.frontWindow.flatMap { roof in
                    guard let main = NSScreen.screens.first else { return nil }
                    return CGRect(x:roof.x,y:main.frame.maxY-roof.maxY,width:roof.width,height:roof.height)
                }
                actor.route = RainShelterPlanner.route(origin:actor.motion.origin,anchor:actor.fallbackAnchor ?? actor.motion.origin,
                    body:body,allowed:allowed,window:window,wind:snapshot.wind,scale:scale)
                if case .pace = actor.route {
                    if actor.fallbackAnchor == nil { actor.fallbackAnchor = actor.motion.origin }
                } else { actor.fallbackAnchor = nil }
            }
            let previous = actor.motion.phase
            let sample = actor.motion.update(at:now,raining:snapshot.raining,route:actor.route,scale:scale)
            if sample.frame != nil || actor.controlling {
                if !actor.controlling { overlays.beginBackdropRelocation(for:source); actor.controlling = true }
                overlays.applyRainShelter(sample,for:source)
                if sample.phase == .sheltered && previous != .sheltered { overlays.saveRainShelterPosition(for:source) }
            }
            actors[source] = actor
            if sample.phase == .idle { stop(source) }
        }
    }
    var diagnostics: [String: Any] {
        ["actors":actors.map { source,actor in
            ["source":source.rawValue,"phase":actor.motion.phase.rawValue,
             "x":actor.motion.origin.x,"y":actor.motion.origin.y,
             "fallback":{ if case .pace = actor.route { return true }; return false }()] as [String:Any]
        },"plans":plans,"ticks":ticks,"windowQueries":0,"maxMovementHz":30,"maxPlanningHzPerActor":2]
    }
}
