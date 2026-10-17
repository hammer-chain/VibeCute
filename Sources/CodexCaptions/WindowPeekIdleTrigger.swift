import AppKit

/// One trigger per uninterrupted, observed stationary character/window pair.
struct WindowPeekIdleTrigger {
    static let defaultDelay: TimeInterval = 120
    let delay: TimeInterval
    private(set) var stationarySeconds: TimeInterval = 0
    private(set) var fired = false
    private var characterFrame: NSRect?
    private var target: DesktopWindowTarget?
    private var stationarySince: TimeInterval?
    private var lastObservation: TimeInterval?

    init(delay: TimeInterval = defaultDelay) {
        self.delay = delay.isFinite && delay > 0 ? delay : Self.defaultDelay
    }

    mutating func reset() {
        characterFrame = nil; target = nil; stationarySince = nil; lastObservation = nil
        stationarySeconds = 0; fired = false
    }

    /// The animation owns the character while active; preserve the fired latch.
    mutating func pause(at now: TimeInterval) { lastObservation = now }

    mutating func observe(character: NSRect?, target next: DesktopWindowTarget?, at now: TimeInterval,
                          harnessIdle: Bool = true, singing: Bool = false, allowNoTarget: Bool = false) -> Bool {
        guard harnessIdle, !singing, now.isFinite, let character, (next != nil || allowNoTarget) else { reset(); return false }
        let missedObservation = lastObservation.map { now < $0 || now-$0 > 2.5 } ?? false
        let changed = characterFrame.map { !Self.same($0,character) } ?? true
        let changedTarget: Bool
        switch (target, next) {
        case (nil, nil): changedTarget = false
        case let (old?, new?): changedTarget = old.id != new.id || old.ownerPID != new.ownerPID || old.side != new.side || !Self.same(old.frame,new.frame)
        default: changedTarget = true
        }
        if changed || changedTarget || missedObservation {
            characterFrame = character; target = next; stationarySince = now
            stationarySeconds = 0; fired = false
        }
        lastObservation = now
        stationarySeconds = max(0,now-(stationarySince ?? now))
        guard !fired, stationarySeconds >= delay else { return false }
        fired = true
        return true
    }

    private static func same(_ a:NSRect,_ b:NSRect) -> Bool {
        // Compare against the stationary anchor so small cumulative movement resets too.
        abs(a.minX-b.minX) < 0.5 && abs(a.minY-b.minY) < 0.5
            && abs(a.width-b.width) < 0.5 && abs(a.height-b.height) < 0.5
    }

    var diagnostics: [String:Any] {
        ["delay":delay,"stationarySeconds":stationarySeconds,"fired":fired,
         "targetWindow":target.map { $0.id as Any } ?? NSNull()]
    }
}
