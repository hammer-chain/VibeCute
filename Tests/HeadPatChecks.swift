import AppKit
import ImageIO
import UniformTypeIdentifiers

enum HeadPatChecks {
    static let stroke: [CGFloat] = (0...30).map { i in
        let segment = min(2, i/10), p = CGFloat(i-segment*10)/10
        return segment == 1 ? 0.75-p*0.5 : 0.25+p*0.5
    }
    static func run() throws {
        func check(_ value: Bool, _ message: String) { OverlayGeometryChecks.require(value, message) }
        func detect(_ points: [NSPoint?], interval: Double = 0.02) -> Int {
            var gesture = HeadPatGesture(), hits = 0
            for (i, point) in points.enumerated() {
                if gesture.update(point, at: Double(i)*interval) { hits += 1 }
            }
            return hits
        }
        let pat = stroke.map { Optional(NSPoint(x: $0, y: 0.5)) }
        check(detect(pat) == 1, "one deliberate back-and-forth triggers one head pat")
        let natural = [NSPoint(x: 0.20, y: 0.20), NSPoint(x: 0.52, y: 0.28),
            NSPoint(x: 0.86, y: 0.46), NSPoint(x: 0.61, y: 0.31), NSPoint(x: 0.26, y: 0.18)]
        check(detect(natural, interval: 0.10) == 1, "a natural diagonal arc triggers without requiring a horizontal line")
        check(detect(pat, interval: 0.06) == 1, "a slower deliberate stroke is accepted")
        let accelerated = [NSPoint(x: 0.1, y: 0.3), NSPoint(x: 0.8, y: 0.6),
            NSPoint(x: 0.9, y: 0.5), NSPoint(x: 0.8, y: 0.4), NSPoint(x: 0.1, y: 0.3)]
        check(detect(accelerated, interval: 0.08) == 1, "ordinary mouse acceleration no longer clears the gesture")
        check(detect(Array(repeating: NSPoint(x: 0.5, y: 0.5), count: 200)) == 0, "stationary hover does not trigger")
        check(detect((0..<100).map { NSPoint(x: 0.5+($0%2 == 0 ? 0.01 : -0.01), y: 0.5) }) == 0, "small cursor jitter does not trigger")
        check(detect((0..<30).map { NSPoint(x: CGFloat($0)/30, y: 0.5) }) == 0, "a single pass does not trigger")
        check(detect(stroke.map { NSPoint(x: 0.5, y: $0) }) == 0, "vertical movement does not trigger")
        check(detect(pat, interval: 0.001) == 0, "a rapid zigzag does not trigger")
        check(detect(pat, interval: 0.5) == 0, "strokes separated by pauses do not accumulate")
        check(detect(pat + pat + pat) == 1, "cooldown prevents continuous strokes from spamming reactions")
        check(detect(pat.enumerated().map { $0.offset%9 == 0 ? nil : $0.element }) == 1, "brief contour gaps do not erase deliberate petting")
        check(detect(Array(pat.prefix(11)) + Array(repeating: nil, count: 16) + Array(pat[11..<21])) == 0,
            "a sustained departure cannot connect separate strokes")
        check(HeadPatReaction.sample(elapsed: 0)!.amount == 0 && HeadPatReaction.sample(elapsed: 1.4) == nil,
            "reaction starts neutral and ends within 1.4 seconds")

        let folder = URL(fileURLWithPath: "output/head-pat")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var cases = 0
        let roles: [(CaptionMascot, Bool)] = [(.codex, false), (.deepseek, false), (.codex, true), (.deepseekCutout, false)]
        func perform(_ view: SubtitleView, pressed: Bool = false, visibleHit: Bool = true) {
            let start = ProcessInfo.processInfo.systemUptime-0.60
            let head = view.headPatRegion
            for (i, x) in stroke.enumerated() {
                view.observeHeadPat(at: NSPoint(x: head.minX+x*head.width, y: head.midY),
                    pressed: pressed, visibleHit: visibleHit, now: start+Double(i)*0.02)
            }
        }
        for (role, bear) in roles {
            for scale in [0.5, 1.0, 2.0] {
                let controller = OverlayController(), view = controller.subtitle
                controller.update(text: "", context: "", title: "", live: false, mascot: role,
                    font: 18, opacity: 0, bottom: 60, screenIndex: 0, movable: false,
                    visible: true, scale: scale, mode: .character, pinkBear: bear)
                OverlayGeometryChecks.settle()
                let head = view.headPatRegion
                check(head.width > 0 && head.height > 0 && view.bounds.contains(NSPoint(x: head.midX, y: head.midY)),
                    "head region stays inside \(view.mascotArtwork) at \(scale)x")
                check(view.containsVisibleCharacter(at: NSPoint(x: head.midX, y: head.midY)),
                    "head region follows visible artwork for \(view.mascotArtwork) at \(scale)x")
                if role != .deepseekCutout {
                    let sprite = view.seatedSpriteRect
                    let forehead = NSPoint(x: sprite.minX+sprite.width*0.60, y: sprite.minY+sprite.height*0.66)
                    check(head.contains(forehead) && view.containsVisibleCharacter(at: forehead),
                        "visible forehead no longer falls below the old narrow strip")
                    check(!head.contains(NSPoint(x: sprite.midX, y: sprite.minY+sprite.height*0.40)),
                        "body movement remains outside the expanded head region")
                }
                perform(view, pressed: true)
                check(!view.headPatActive, "pressed mouse cannot pet or interrupt dragging")
                perform(view, visibleHit: false)
                check(!view.headPatActive, "transparent pixels cannot pet")
                perform(view)
                check(view.headPatActive && view.headPatCount == 1, "pat works with fixed character at \(scale)x")
                let anchor = controller.panel.frame
                if scale == 1 && !bear {
                    let name = role.rawValue
                    let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(name)-reaction.gif") as CFURL,
                        UTType.gif.identifier as CFString, 42, nil)!
                    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                    let start = ProcessInfo.processInfo.systemUptime
                    for i in 0..<42 {
                        let deadline = start+Double(i)/30
                        while ProcessInfo.processInfo.systemUptime < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
                        view.advanceHeadPat()
                        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        CGImageDestinationAddImage(gif, bitmap.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0/30]] as CFDictionary)
                        if i == 15 { try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(name)-reaction.png")) }
                    }
                    check(CGImageDestinationFinalize(gif), "complete native-view reaction preview writes")
                }
                view.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime+1.5)
                OverlayGeometryChecks.settle()
                check(!view.headPatActive && !view.seatedMotionAnimating, "idle extra clock stops when reaction completes")
                check(controller.panel.frame == anchor, "pat never moves the native window or subtitle anchor")
                if role == .deepseek {
                    view.setPerformanceFrame(0); perform(view)
                    check(!view.headPatActive, "singing/performance pose excludes head pats")
                    view.setPerformanceFrame(nil)
                    view.enterScreenEdge(.left); perform(view)
                    check(!view.headPatActive, "screen-edge animation excludes head pats")
                }
                view.setMascot(nil, animating: false)
                check(!view.headPatActive, "hiding/changing character clears its reaction")
                controller.panel.orderOut(nil); cases += 1
            }
        }

        // Compare complete pointer dispatch on the same four visible characters.
        let overlays = ProjectOverlays()
        overlays.update([], font: 18, opacity: 0.7, bottom: 80, screenIndex: 0, movable: false, focusedID: "",
            restingMascots: [.codex, .deepseek, .claude, .opencode],
            characterBindings: [.codex: .codex, .deepseek: .deepseek, .claude: .pinkBear, .opencode: .deepseekCutout])
        OverlayGeometryChecks.settle()
        let fish = overlays.character(for: .deepseek)!
        let h = fish.subtitle.headPatRegion
        let inside = NSPoint(x: fish.panel.frame.minX+h.midX, y: fish.panel.frame.minY+h.midY)
        func measure(_ point: NSPoint, count: Int, recognize: Bool) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<count { overlays.refreshCharacterMouseTransparency(at: point, recognizeHeadPat: recognize) }
            return ProcessInfo.processInfo.systemUptime-start
        }
        let outside = NSPoint(x: -10000, y: -10000)
        let samples = overlays.characterDiagnostics.compactMap { $0["headPat"] as? [String: Any] }.compactMap { $0["pointerSamples"] as? Int }.reduce(0,+)
        let outsideBaseline = measure(outside, count: 10000, recognize: false)
        let outsidePat = measure(outside, count: 10000, recognize: true)
        let insideBaseline = measure(inside, count: 1000, recognize: false)
        let insidePat = measure(inside, count: 1000, recognize: true)
        check(overlays.characterDiagnostics.allSatisfy { ($0["headPat"] as? [String: Any])?["count"] as? Int == 0 },
            "11,000 dispatches with stationary pointers never trigger a gesture")
        check(outsidePat < 1 && insidePat < 2, "complete four-character event dispatch stays within bounded desktop budget")
        let result: [String: Any] = ["passed": true, "geometryCases": cases, "characters": 4,
            "environment": "native AppKit graphical session; development geometry executable",
            "outsideEvents": 10000, "insideEvents": 1000, "outsideBaselineSeconds": outsideBaseline,
            "outsidePatSeconds": outsidePat, "insideBaselineSeconds": insideBaseline, "insidePatSeconds": insidePat,
            "headPatSamplesBefore": samples, "stateBytes": MemoryLayout<HeadPatGesture>.stride,
            "extraSpriteBytes": 0, "extraPersistentTimers": 0, "networkRequests": 0, "modelCalls": 0,
            "budgetAssumption": "4 characters, 120 pointer events/s; gesture work below 0.5ms/event; reaction 30Hz for 1.4s",
            "boundary": "controlled geometry and native view rendering; real signed app input tested separately"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        overlays.update([], font: 18, opacity: 0.7, bottom: 80, screenIndex: 0, movable: false, focusedID: "", characterBindings: [:])
    }
}
