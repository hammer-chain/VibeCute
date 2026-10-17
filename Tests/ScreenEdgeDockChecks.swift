import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ScreenEdgeDockChecks {
    static func run() throws {
        let output = URL(fileURLWithPath: "output/screen-edge-hover")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let artwork = ScreenEdgeArtwork.shared
        let decodeSeconds = ProcessInfo.processInfo.systemUptime - decodeStart
        precondition(artwork.frames.count == 8 && artwork.transitions.count == 8)
        let all = artwork.frames + artwork.transitions
        precondition(all.allSatisfy { $0.width == 384 && $0.height == 512 })
        let bytes = all.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        precondition(bytes <= 16 * 1024 * 1024)
        // Atlas neighbors previously left floating ear/tail fragments here.
        // These margins are visibly separate from the complete current poses.
        let emptyMargins = [
            [1, 0, 325, 12, 377], [3, 0, 349, 17, 415], [5, 0, 160, 14, 182],
            [6, 0, 141, 30, 199], [6, 0, 227, 12, 262],
            [6, 0, 270, 18, 350], [6, 0, 417, 5, 444]
        ]
        for margin in emptyMargins {
            let bitmap = NSBitmapImageRep(cgImage: artwork.transitions[margin[0]])
            for y in margin[2]..<margin[4] { for x in margin[1]..<margin[3] {
                // The generated atlas retains isolated 1/255-alpha noise;
                // visible detached fragments must be completely absent.
                precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent <= 1.0 / 255.0 + 0.00001,
                    "transition \(margin[0]) has floating atlas residue at \(x),\(y)")
            }}
        }
        // Real posture frames, reversal and both fully visible endpoint holds.
        var playback = ScreenEdgePlayback()
        for frame in 0..<8 {
            precondition(playback.transitionFrame == frame)
            precondition(!playback.advance())
        }
        precondition(playback.phase == .peeking)
        for _ in 0..<20 { _ = playback.advance() }
        precondition(playback.loopStep == 0 && !playback.isPlaying, "docked characters rest until hovered")
        playback.setHovering(true)
        for _ in 0..<6 { _ = playback.advance() }
        precondition(playback.loopFrame != 0 && playback.isPlaying)
        playback.setHovering(false)
        precondition(playback.loopFrame == 0 && playback.isPlaying)
        for _ in 0..<ScreenEdgePlayback.peekSteps { _ = playback.advance() }
        precondition(playback.peekLean == 0 && !playback.isPlaying)
        playback.exit()
        for frame in (0..<8).reversed() {
            precondition(playback.transitionFrame == frame)
            precondition(playback.advance() == (frame == 0))
        }
        playback = ScreenEdgePlayback()
        for _ in 0..<3 { _ = playback.advance() }
        playback.exit(); _ = playback.advance()
        precondition(playback.step == 2)
        playback.enter(); _ = playback.advance()
        precondition(playback.step == 3, "reversing a transition must not jump to an endpoint")

        // Native drag chooses the display under the real pointer. Run this
        // controlled fixture on that display instead of assuming screen zero.
        let screenIndex = NSScreen.screens.firstIndex { $0.frame.contains(NSEvent.mouseLocation) } ?? 0
        let screen = NSScreen.screens[screenIndex], area = screen.visibleFrame
        let overlays = ProjectOverlays()
        var factor = 1.0
        var item = OverlayItem(id: "dock", text: "拖到屏幕边缘", header: "DSH", title: "边缘吸附", active: false, mascot: .deepseek)
        func update() {
            overlays.update([item], font: 24, opacity: 0.7, bottom: 46, screenIndex: screenIndex,
                movable: true, focusedID: "dock", characterScale: factor)
        }
        overlays.onCharacterDockChanged = { update() }
        update(); OverlayGeometryChecks.settle()
        let panel = overlays.character.panel, view = overlays.character.subtitle
        let bubble = overlays.controller(for: "dock")!.panel
        let started = ProcessInfo.processInfo.systemUptime
        var outsidePointerSeconds = 0.0, hoverPointerSeconds = 0.0
        var outsidePointerSamples = 0, hoverPointerSamples = 0
        var pointerBenchmarkMeasured = false
        var physicalEdges: [String] = []
        var edgeFrameCallbacks = 0
        var hoverDisplacements: [[String: Any]] = []
        let onEdgeFrame = view.onScreenEdgeFrame
        view.onScreenEdgeFrame = { edgeFrameCallbacks += 1; onEdgeFrame?() }
        for scale in [0.5, 1.0, 2.0] {
            factor = scale; update(); OverlayGeometryChecks.settle()
            for side in [ScreenEdgeDock.Side.left, .right] {
                // An adjacent display makes this a crossing route, rather
                // than a physical desktop edge that this fixture can dock at.
                let probe = NSPoint(x: side == .left ? screen.frame.minX-1 : screen.frame.maxX+1,
                    y: area.minY+70+134*CGFloat(scale))
                if NSScreen.screens.contains(where: { $0 !== screen && $0.frame.contains(probe) }) {
                    print("INFO: shared \(side) display boundary at \(scale)x excluded from physical-edge fixture")
                    continue
                }
                physicalEdges.append("\(side.rawValue)@\(scale)x")
                panel.beginManualDrag()
                panel.setFrameOrigin(NSPoint(x: side == .left ? screen.frame.minX : screen.frame.maxX - panel.frame.width,
                    y: area.minY + 70))
                OverlayGeometryChecks.settle()
                panel.finishManualDragIfReleased(buttonDown: false)
                precondition(view.screenEdgeDock == side && view.screenEdgePlayback?.phase == .entering && !bubble.isVisible,
                    "dock \(String(describing: view.screenEdgeDock)), expected \(side), phase \(String(describing: view.screenEdgePlayback?.phase)), bubble visible \(bubble.isVisible)")
                let entryStart = panel.frame.minX
                // Advance deterministically using the same existing clock callback.
                for _ in 0..<8 { view.advanceScreenEdgeFrame() }
                precondition(view.screenEdgePlayback?.phase == .peeking)
                precondition(side == .left ? panel.frame.minX < entryStart : panel.frame.minX > entryStart)
                let hidden = ScreenEdgeDock.hiddenWidth(for: panel.frame.width, scale: scale)
                let physicalPlane = side == .left ? panel.frame.minX + hidden : panel.frame.maxX - hidden
                precondition(abs(physicalPlane - (side == .left ? screen.frame.minX : screen.frame.maxX)) < 1)
                precondition(!view.seatedGazeActive && !view.seatedMotionAnimating)
                let fullRect = ScreenEdgeDock.artworkRect(in: view.bounds, scale: scale)
                precondition(view.bounds.contains(fullRect), "whole anatomy must fit in the movable window")
                // Hover must hit the exposed artwork, not the transparent panel.
                let visible = panel.frame.intersection(screen.frame)
                var solid: NSPoint?, blank: NSPoint?
                for y in stride(from: visible.minY + 1, to: visible.maxY, by: max(1, scale)) {
                    for x in stride(from: visible.minX + 0.5, to: visible.maxX, by: max(0.5, scale / 2)) {
                        let point = NSPoint(x: x, y: y)
                        let local = view.convert(panel.convertPoint(fromScreen: point), from: nil)
                        if view.containsVisibleCharacter(at: local, screenEdgeIdle: true) {
                            if solid == nil { solid = point }
                        } else if blank == nil { blank = point }
                    }
                    if solid != nil && blank != nil { break }
                }
                precondition(solid != nil && blank != nil)
                let controller = overlays.character
                controller.refreshCharacterMouseTransparency(at: blank!, leftButtonDown: false)
                for _ in 0..<20 { view.advanceScreenEdgeFrame() }
                precondition(view.screenEdgePlayback?.loopStep == 0 && !view.screenEdgePlayback!.isPlaying)
                var enteredFrames = Set<Int>()
                let positionBeforeHover = panel.frame
                let callbacksBeforeHover = edgeFrameCallbacks
                controller.refreshCharacterMouseTransparency(at: solid!, leftButtonDown: false)
                for _ in 0..<ScreenEdgePlayback.peekSteps {
                    view.advanceScreenEdgeFrame()
                    controller.refreshCharacterMouseTransparency(at: solid!, leftButtonDown: false)
                    precondition(view.screenEdgePlayback!.hovering,
                        "peek movement must retain a stationary pointer: \(scale), \(side), \(solid!), \(positionBeforeHover), \(panel.frame)")
                }
                precondition(edgeFrameCallbacks == callbacksBeforeHover + ScreenEdgePlayback.peekSteps)
                let callbacksAfterPeek = edgeFrameCallbacks
                for _ in 0..<16 {
                    view.advanceScreenEdgeFrame()
                    controller.refreshCharacterMouseTransparency(at: solid!, leftButtonDown: false)
                    precondition(view.screenEdgePlayback!.hovering, "moving artwork must not flicker at a stationary pointer")
                    enteredFrames.insert(view.screenEdgePlayback!.loopFrame)
                }
                precondition(enteredFrames.count == 8, "hover starts the complete peek loop")
                precondition(view.screenEdgePlayback!.peekLean == 1)
                hoverDisplacements.append(["scale": scale, "side": side.rawValue,
                    "requested": ScreenEdgeDock.peekRevealWidth(scale: scale) * (side == .left ? 1 : -1),
                    "actual": panel.frame.minX - positionBeforeHover.minX])
                precondition(edgeFrameCallbacks == callbacksAfterPeek, "peek loops must not move the native window")
                // The pointer can follow the newly revealed face outside its
                // resting silhouette without stopping the animation.
                var revealed: NSPoint?
                let peekVisible = panel.frame.intersection(screen.frame)
                for y in stride(from: peekVisible.minY + 1, to: peekVisible.maxY, by: max(1, scale)) {
                    for x in stride(from: peekVisible.minX + 0.5, to: peekVisible.maxX, by: max(0.5, scale / 2)) {
                        let point = NSPoint(x: x, y: y)
                        let local = view.convert(panel.convertPoint(fromScreen: point), from: nil)
                        if !view.containsVisibleCharacter(at: local, screenEdgeIdle: true)
                            && view.containsVisibleCharacter(at: local, screenEdgeIdle: true, peekLean: 1) {
                            revealed = point; break
                        }
                    }
                    if revealed != nil { break }
                }
                precondition(revealed != nil, "hover must reveal more of the head")
                controller.refreshCharacterMouseTransparency(at: revealed!, leftButtonDown: false)
                precondition(view.screenEdgePlayback!.hovering, "the revealed face must remain hoverable")
                controller.refreshCharacterMouseTransparency(at: solid!, leftButtonDown: true)
                precondition(!view.screenEdgePlayback!.hovering && view.screenEdgePlayback!.loopFrame == 0)
                controller.refreshCharacterMouseTransparency(at: solid!, leftButtonDown: false)
                controller.refreshCharacterMouseTransparency(at: NSPoint(x: area.midX, y: area.maxY), leftButtonDown: false)
                precondition(!view.screenEdgePlayback!.hovering)
                for _ in 0..<ScreenEdgePlayback.peekSteps { view.advanceScreenEdgeFrame() }
                precondition(abs(panel.frame.minX - positionBeforeHover.minX) < 0.01, "withdraw must restore the dock anchor")
                view.needsDisplay = false
                for _ in 0..<20 { view.advanceScreenEdgeFrame() }
                precondition(!view.needsDisplay, "resting ticks must not request new drawing")
                if scale == 1 && !pointerBenchmarkMeasured {
                    let outside = NSPoint(x: area.midX, y: area.maxY)
                    let samplesBeforeOutside = view.characterHitSamples
                    let outsideStart = ProcessInfo.processInfo.systemUptime
                    for _ in 0..<10_000 {
                        controller.refreshCharacterMouseTransparency(at: outside, leftButtonDown: false)
                    }
                    outsidePointerSeconds = ProcessInfo.processInfo.systemUptime - outsideStart
                    outsidePointerSamples = view.characterHitSamples - samplesBeforeOutside
                    precondition(outsidePointerSamples == 0 && !view.needsDisplay,
                        "pointer movement outside the panel must skip artwork sampling and redraw")
                    controller.refreshCharacterMouseTransparency(at: solid!, leftButtonDown: false)
                    for _ in 0..<ScreenEdgePlayback.peekSteps {
                        view.advanceScreenEdgeFrame()
                        controller.refreshCharacterMouseTransparency(at: solid!, leftButtonDown: false)
                    }
                    let samplesBeforeHover = view.characterHitSamples
                    let hoverStart = ProcessInfo.processInfo.systemUptime
                    for _ in 0..<1_000 {
                        controller.refreshCharacterMouseTransparency(at: solid!, leftButtonDown: false)
                    }
                    hoverPointerSeconds = ProcessInfo.processInfo.systemUptime - hoverStart
                    hoverPointerSamples = view.characterHitSamples - samplesBeforeHover
                    precondition(hoverPointerSamples <= 3_000, "hover work must remain bounded per pointer event")
                    controller.refreshCharacterMouseTransparency(at: outside, leftButtonDown: false)
                    for _ in 0..<ScreenEdgePlayback.peekSteps { view.advanceScreenEdgeFrame() }
                    pointerBenchmarkMeasured = true
                }
                panel.beginManualDrag()
                panel.finishManualDragIfReleased(buttonDown: false)
                precondition(view.screenEdgePlayback?.phase == .peeking, "a click must preserve the peek loop")
                let position = panel.frame
                item = OverlayItem(id: "dock", text: "吸附时更新的最新字幕", header: "DSH", title: "边缘吸附", active: true, mascot: .deepseek)
                update(); OverlayGeometryChecks.settle()
                precondition(panel.frame == position && !bubble.isVisible)
                // Exit begins on the FIRST inward movement while the button is held.
                panel.beginManualDrag()
                panel.setFrameOrigin(NSPoint(x: position.minX + (side == .left ? 40 : -40) * scale, y: position.minY))
                OverlayGeometryChecks.settle()
                panel.finishManualDragIfReleased(buttonDown: true)
                precondition(panel.isManuallyDragging && view.screenEdgePlayback?.phase == .exiting)
                let heldStep = view.screenEdgePlayback!.step
                view.advanceScreenEdgeFrame()
                precondition(view.screenEdgePlayback?.step == max(0, heldStep - 1))
                // Move fully inside before release; all frames are now complete.
                panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: position.minY))
                OverlayGeometryChecks.settle()
                panel.finishManualDragIfReleased(buttonDown: false)
                precondition(view.screenEdgePlayback?.phase == .exiting && !bubble.isVisible)
                for _ in 0..<8 { view.advanceScreenEdgeFrame() }
                precondition(view.screenEdgeDock == nil && bubble.isVisible)
                precondition(overlays.controller(for: "dock")!.subtitle.text == "吸附时更新的最新字幕")
            }
        }
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        precondition(ScreenEdgeDock.candidate(for: NSRect(x: 0, y: 100, width: 147, height: 226), on: primary, screens: [primary, left], scale: 1) == nil)
        precondition(ScreenEdgeDock.candidate(for: NSRect(x: -1920, y: 100, width: 147, height: 226), on: left, screens: [primary, left], scale: 1)?.side == .left)
        let costStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10_000 {
            _ = ScreenEdgeDock.candidate(for: NSRect(x: 1293, y: 100, width: 147, height: 226), on: primary, screens: [primary, left], scale: 1)
        }
        let cost = ProcessInfo.processInfo.systemUptime - costStart
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 294, pixelsHigh: 452, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context; context.cgContext.scaleBy(x: 2, y: 2)
        let bounds = NSRect(x: 0, y: 0, width: 147, height: 226)
        let drawStart = ProcessInfo.processInfo.systemUptime
        for step in 0..<2_000 {
            context.cgContext.clear(bounds)
            ScreenEdgeDock.draw(frame: step % 8, transition: step % 2 == 0 ? step % 8 : nil,
                in: bounds, side: .left, scale: 1, peekLean: step % 2 == 1 ? 1 : 0)
        }
        let drawSeconds = ProcessInfo.processInfo.systemUptime - drawStart
        // Physical-screen clipped loop. No lower skirt/legs may peek alone.
        for frame in 0..<8 {
            // Lower-body source pixels remain behind the actual screen plane,
            // including a two-pixel allowance for resampling at its border.
            let source = NSBitmapImageRep(cgImage: artwork.frames[frame])
            for y in 340..<512 { for x in 0..<384 {
                if source.colorAt(x: x, y: y)!.alphaComponent > 0.1 {
                    let angle = ScreenEdgeArtwork.peekAngle
                    let revealedX = 210 + (CGFloat(x) - 210) * cos(angle)
                        + (CGFloat(512 - y) - 60) * sin(angle)
                    precondition(revealedX + 2 < ScreenEdgeArtwork.peekEdgeX,
                        "lower body must stay behind the screen during the half-head peek")
                }
            }}
          for lean in [CGFloat(0), 1] {
            context.cgContext.clear(bounds)
            context.cgContext.saveGState(); context.cgContext.clip(to: bounds)
            context.cgContext.translateBy(x: -ScreenEdgeDock.hiddenWidth(for: 147, scale: 1)
                + ScreenEdgeDock.peekRevealWidth(scale: 1) * lean, y: 0)
            ScreenEdgeDock.draw(frame: frame, in: bounds, side: .left, scale: 1, peekLean: lean)
            context.cgContext.restoreGState()
            var headPixels = 0, lowerPixels = 0
            for y in 0..<452 { for x in 0..<294 {
                if bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.1 {
                    headPixels += 1
                    if y > 380 { lowerPixels += 1 }
                }
            }}
            precondition(headPixels > 100 && lowerPixels == 0, "only naturally connected head/hands may peek")
          }
        }
        NSGraphicsContext.restoreGraphicsState()
        precondition(!physicalEdges.isEmpty && pointerBenchmarkMeasured, "at least one physical edge and pointer benchmark must run")
        print("PASS: resting dock, pixel hover trigger, 3-frame peek/withdraw, revealed face hover, stable 8-frame loop, no exposed lower body, pointer exit/button pause, no idle redraw, reversible entry/exit, drag-away; physical edges \(physicalEdges.joined(separator: ", ")); shared/negative screen decisions")
        print("INFO: 16 cached frames: \(bytes) bytes; first decode \(decodeSeconds)s; 2000 full Retina draws \(drawSeconds)s; 10000 edge decisions \(cost)s")
        print("INFO: 10000 outside pointer events: \(outsidePointerSeconds)s, \(outsidePointerSamples) artwork samples; 1000 hovered events: \(hoverPointerSeconds)s, \(hoverPointerSamples) artwork samples")
        try JSONSerialization.data(withJSONObject: ["passed": true, "assetDecodedBytes": bytes,
            "assetDecodeSeconds": decodeSeconds, "retinaDrawCount": 2_000, "drawSeconds": drawSeconds,
            "physicalEdges": physicalEdges,
            "edgeDecisionCount": 10_000, "decisionSeconds": cost, "newTimers": 0,
            "outsidePointerEventCount": 10_000, "outsidePointerSeconds": outsidePointerSeconds,
            "outsidePointerArtworkSamples": outsidePointerSamples,
            "hoverPointerEventCount": 1_000, "hoverPointerSeconds": hoverPointerSeconds,
            "hoverPointerArtworkSamples": hoverPointerSamples,
            "entryFrames": 8, "exitFrames": 8, "frameTickSeconds": 0.16,
            "hoverTransitionFrames": ScreenEdgePlayback.peekSteps, "hoverLeanDegrees": 20,
            "hoverWindowDisplacements": hoverDisplacements,
            "geometrySeconds": ProcessInfo.processInfo.systemUptime - started,
            "scope": "Controlled native AppKit geometry and drawing; whole-app performance not measured"], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("geometry-validation.json"))
    }
}
