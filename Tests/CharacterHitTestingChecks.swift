import AppKit

enum CharacterHitTestingChecks {
    private final class ClickReceiver: NSView {
        var clicks = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }
    static func run() {
        let overlays = ProjectOverlays()
        let sources: [CaptionMascot] = [.codex, .deepseek, .claude, .opencode]
        overlays.update([], font: 18, opacity: 0.7, bottom: 60, screenIndex: 0,
            movable: true, focusedID: "", restingMascots: Set(sources),
            characterBindings: [.codex: .codex, .deepseek: .deepseek, .claude: .pinkBear, .opencode: .deepseekCutout])
        let controllers = sources.map { overlays.character(for: $0)! }
        controllers.forEach { $0.panel.setFrameOrigin(NSPoint(x: 600, y: 400)) }
        OverlayGeometryChecks.settle()
        func check(_ ok: Bool, _ text: String) { OverlayGeometryChecks.require(ok, text) }
        for controller in controllers {
            let view = controller.subtitle
            check(!view.containsVisibleCharacter(at: NSPoint(x: 1, y: 1)), "transparent margin does not hit \(view.mascotArtwork)")
            var solid: NSPoint?
            for y in stride(from: 10.0, to: Double(view.bounds.height), by: 8) {
                for x in stride(from: 5.0, to: Double(view.bounds.width), by: 8) {
                    let point = NSPoint(x: x, y: y)
                    if view.containsVisibleCharacter(at: point) { solid = point; break }
                }
                if solid != nil { break }
            }
            check(solid != nil, "visible pixels accept a hit for \(view.mascotArtwork)")
            let origin = controller.panel.frame.origin
            controller.refreshCharacterMouseTransparency(at: NSPoint(x: origin.x + 1, y: origin.y + 1))
            check(controller.panel.ignoresMouseEvents, "native window passes transparent pixels through for \(view.mascotArtwork)")
            controller.refreshCharacterMouseTransparency(at: NSPoint(x: origin.x + solid!.x, y: origin.y + solid!.y))
            check(!controller.panel.ignoresMouseEvents, "native window accepts visible pixels for \(view.mascotArtwork)")
            controller.panel.beginManualDrag()
            controller.refreshCharacterMouseTransparency(at: NSPoint(x: -1000, y: -1000))
            check(!controller.panel.ignoresMouseEvents, "an ongoing drag stays captured outside the silhouette")
            controller.panel.finishManualDragIfReleased(buttonDown: false)
        }
        // Find a point where the upper fish is transparent and the lower dragon
        // is visible. Native window flags must leave the lower character available.
        let lower = controllers[0], upper = controllers[1]
        var overlapPoint: NSPoint?
        for y in stride(from: 8.0, to: Double(lower.subtitle.bounds.height), by: 4) {
            for x in stride(from: 4.0, to: Double(lower.subtitle.bounds.width), by: 4) {
                let screen = NSPoint(x: lower.panel.frame.minX + x, y: lower.panel.frame.minY + y)
                if [NSPoint(x: x, y: y), NSPoint(x: x - 2, y: y), NSPoint(x: x + 2, y: y), NSPoint(x: x, y: y - 2), NSPoint(x: x, y: y + 2)].allSatisfy({ lower.subtitle.containsVisibleCharacter(at: $0) })
                    && !upper.subtitle.containsVisibleCharacter(at: NSPoint(x: screen.x - upper.panel.frame.minX, y: screen.y - upper.panel.frame.minY)) {
                    overlapPoint = screen; break
                }
            }
            if overlapPoint != nil { break }
        }
        check(overlapPoint != nil, "different actual character silhouettes contain a transparent-over-visible overlap")
        upper.panel.orderFrontRegardless()
        overlays.refreshCharacterMouseTransparency(at: overlapPoint!)
        check(upper.panel.ignoresMouseEvents && !lower.panel.ignoresMouseEvents,
            "transparent upper character leaves the visible lower character draggable")
        overlays.refreshCharacterMouseTransparency(at: NSPoint(x: 601, y: 401))
        check(controllers.allSatisfy { $0.panel.ignoresMouseEvents }, "all transparent character windows leave underlying app content available")
        let samples = controllers.reduce(0) { $0 + $1.subtitle.characterHitSamples }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10_000 { overlays.refreshCharacterMouseTransparency(at: NSPoint(x: -1000, y: -1000)) }
        check(controllers.reduce(0) { $0 + $1.subtitle.characterHitSamples } == samples,
            "10,000 outside-pointer events do not render or sample character artwork")
        let outsideElapsed = ProcessInfo.processInfo.systemUptime - start
        let insideStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { overlays.refreshCharacterMouseTransparency(at: overlapPoint!) }
        print("INFO: 3 characters, 10,000 outside events: \(outsideElapsed)s; 1,000 overlap events: \(ProcessInfo.processInfo.systemUptime - insideStart)s; reusable 4-byte sampling buffer per character; no new timer")
        if CGPreflightPostEventAccess() {
            // Exercise WindowServer delivery, rather than forwarding a click
            // ourselves. An opaque fixture window catches all test clicks.
            controllers[2].panel.orderOut(nil)
            controllers.prefix(2).forEach { $0.panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10) }
            let background = NSPanel(contentRect: lower.panel.frame.union(upper.panel.frame),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            background.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 9)
            let receiver = ClickReceiver(frame: NSRect(origin: .zero, size: background.frame.size))
            background.contentView = receiver; background.orderFrontRegardless()
            let originalPointer = NSEvent.mouseLocation
            let screenHeight = NSScreen.screens[0].frame.maxY
            func pumpEvents() {
                let deadline = Date().addingTimeInterval(0.25)
                while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    if event.type == .leftMouseDown { print("INFO: mouse-down window \(event.windowNumber), fixture \(background.windowNumber), lower \(lower.panel.windowNumber), upper \(upper.panel.windowNumber)") }
                    NSApp.sendEvent(event)
                }
            }
            func post(_ type: CGEventType, _ point: NSPoint) {
                // Flush outgoing window changes before asking WindowServer to
                // route an input event, then dispatch the delivered event.
                pumpEvents()
                CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: point.x, y: screenHeight - point.y), mouseButton: .left)?.post(tap: .cghidEventTap)
                pumpEvents()
            }
            var draggedSource: String?
            overlays.onCharacterDragStarted = { draggedSource = $0 }
            upper.panel.orderFrontRegardless()
            post(.mouseMoved, overlapPoint!)
            overlays.refreshCharacterMouseTransparency(at: overlapPoint!)
            post(.leftMouseDown, overlapPoint!); post(.leftMouseUp, overlapPoint!)
            overlays.finishReleasedCharacterDrags()
            print("INFO: WindowServer drag receiver: \(draggedSource ?? "none"); background clicks: \(receiver.clicks)")
            check(draggedSource == "codex", "WindowServer delivers a click through the transparent upper character to the lower dragon")
            let blank = NSPoint(x: 601, y: 401)
            post(.mouseMoved, blank)
            overlays.refreshCharacterMouseTransparency(at: blank)
            print("INFO: blank point pass-through flags: \(lower.panel.ignoresMouseEvents), \(upper.panel.ignoresMouseEvents); dragging: \(lower.panel.isManuallyDragging)")
            post(.leftMouseDown, blank); post(.leftMouseUp, blank)
            check(receiver.clicks == 1, "WindowServer delivers a click through all transparent characters to another native window")
            background.orderOut(nil)
            post(.mouseMoved, originalPointer)
        } else {
            print("INFO: synthetic input permission unavailable; verified native ignoresMouseEvents flags, not WindowServer click delivery")
        }
        sources.forEach { overlays.setSourceHidden($0, true) }
    }
}
