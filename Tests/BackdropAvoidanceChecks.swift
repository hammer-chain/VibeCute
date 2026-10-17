import AppKit
import ImageIO

/// Real pixel fixtures exercise uniformity without OCR.
enum BackdropAvoidanceChecks {
    static func scene(_ mode: String) -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:900,pixelsHigh:600,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedWhite:0.97,alpha:1).setFill(); NSRect(x:0,y:0,width:900,height:600).fill()
        if mode == "texture" {
            for y in stride(from:0,to:600,by:8) { for x in stride(from:0,to:900,by:8) {
                ((x+y)%16 == 0 ? NSColor.systemBlue : NSColor.systemOrange).setFill()
                NSRect(x:x,y:y,width:8,height:8).fill()
            } }
        }
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:18,weight:.medium),.foregroundColor:NSColor.black]
        if mode == "texture" {
            NSColor(calibratedWhite:0.97,alpha:1).setFill(); NSRect(x:210,y:95,width:90,height:45).fill()
        }
        if mode == "near" || mode == "near-zh" || mode == "texture" {
            ((mode == "near-zh" ? "文字" : "TEXT") as NSString).draw(at:NSPoint(x:223,y:110),withAttributes:attrs)
        }
        if mode == "far" || mode == "middle" {
            for y in stride(from:30,to:470,by:30) {
                ((mode == "middle" ? "Visible document words cover this entire reading area." : "Visible document words cover this entire reading area and even further.") as NSString)
                    .draw(at:NSPoint(x:60,y:y),withAttributes:attrs)
            }
        }
        return bitmap.cgImage!
    }
    static func run() throws {
        let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/backdrop-avoidance")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let mascot = MascotAnimation.library[.deepseek]!
        let silhouette = BackdropSilhouette(image:mascot.frames[0].cgImage(forProposedRect:nil,context:nil,hints:nil)!)
        let frame = CGRect(x:0,y:0,width:900,height:600)
        let sprite = CGRect(x:180,y:30,width:126,height:168), origin = CGPoint(x:169.5,y:22)
        let allowed = CGRect(x:30,y:22,width:690,height:100)
        var results: [[String:Any]] = []
        for mode in ["near","near-zh","middle","far","texture","blank"] {
            let image = scene(mode)
            let desktop = try BackdropScene.analyze(image,frame:frame,at:0)
            let p = BackdropAvoidancePlanner.plan(scene:desktop,silhouette:silhouette,sprite:sprite,
                panelOrigin:origin,allowedOrigins:allowed,scale:1)
            switch mode {
            case "near", "near-zh":
                precondition(desktop.isObstructed(silhouette:silhouette,sprite:sprite), "Pixel contrast detects non-uniform background")
                precondition(p?.movement == .scoot, "Near pure whitespace uses seated scoot")
            case "middle": precondition(p?.movement == .frontRetreat, "Middle whitespace uses frontal retreat")
            case "far": precondition(p?.movement == .walk, "Far pure whitespace uses standing walk")
            case "texture":
                precondition(desktop.isObstructed(silhouette:silhouette,sprite:sprite))
                precondition(p == nil, "No destination inside textured background")
            default: precondition(p == nil, "No move on uniform background")
            }
            if let p { precondition(desktop.isBlank(p.destinationBody), "Whole destination is uniform") }
            if mode == "near" || mode == "middle" || mode == "far" {
                let landing = silhouette.worldBounds(in:sprite).insetBy(dx:-14,dy:-8)
                let seatedPlan = BackdropAvoidancePlanner.plan(scene:desktop,silhouette:silhouette,sprite:sprite,
                    panelOrigin:origin,allowedOrigins:allowed,scale:1,destinationBounds:landing)!
                let movedSeat = landing.offsetBy(dx:seatedPlan.to.x-origin.x,dy:seatedPlan.to.y-origin.y)
                precondition(seatedPlan.destinationBody.contains(movedSeat) && desktop.isBlank(seatedPlan.destinationBody),
                    "Final wider seated body fits destination whitespace")
            }
            let entry: [String:Any] = ["fixture":mode,"obstructed":desktop.isObstructed(silhouette:silhouette,sprite:sprite),"movement":p?.movement.rawValue ?? "none","distance":p?.distance ?? 0]
            results.append(entry)
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("fixture-\(mode).png"))
            print("PASS: pixel uniformity \(mode): \(entry)")
        }
        // Pixel-only semantics: two individually solid regions must still share one color.
        func patch(_ color: NSColor, _ rect: CGRect?) -> CGImage {
            let b = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:900,pixelsHigh:600,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:b)
            NSColor.white.setFill(); frame.fill()
            color.setFill(); (rect ?? frame).fill()
            NSGraphicsContext.restoreGraphicsState()
            return b.cgImage!
        }
        for color in [NSColor.black, .systemBlue, .white] {
            let solid = try BackdropScene.analyze(patch(color,nil),frame:frame,at:0)
            precondition(!solid.isObstructed(silhouette:silhouette,sprite:sprite))
        }
        let body = silhouette.worldBounds(in:sprite)
        let half = CGRect(x:body.midX,y:body.minY,width:body.width/2,height:body.height)
        let shape = try BackdropScene.analyze(patch(.systemBlue,half),frame:frame,at:0)
        precondition(shape.isObstructed(silhouette:silhouette,sprite:sprite), "Non-text colored shape triggers")
        let noise = try BackdropScene.analyze(patch(NSColor(calibratedWhite:0.99,alpha:1),half),frame:frame,at:0)
        precondition(!noise.isObstructed(silhouette:silhouette,sprite:sprite), "Tiny color variation is tolerated")
        let corner = CGRect(x:sprite.minX,y:sprite.maxY-8,width:8,height:8)
        let cornerScene = try BackdropScene.analyze(patch(.black,corner),frame:frame,at:0)
        precondition(!cornerScene.isObstructed(silhouette:silhouette,sprite:sprite), "Transparent corner is ignored")

        let translated = try BackdropScene.analyze(scene("near"),frame:CGRect(x:-900,y:130,width:900,height:600),at:0)
        let translatedPlan = BackdropAvoidancePlanner.plan(scene:translated,silhouette:silhouette,
            sprite:sprite.offsetBy(dx:-900,dy:130),panelOrigin:CGPoint(x:origin.x-900,y:origin.y+130),
            allowedOrigins:allowed.offsetBy(dx:-900,dy:130),scale:1)
        precondition(translatedPlan?.movement == .scoot, "Negative display coordinates and pixel Y-axis map correctly")

        let desktop = try BackdropScene.analyze(scene("near"),frame:frame,at:0)
        let plan = BackdropAvoidancePlanner.plan(scene:desktop,silhouette:silhouette,sprite:sprite,panelOrigin:origin,allowedOrigins:allowed,scale:1)!
        let singingPlan = BackdropAvoidancePlanner.plan(scene:desktop,silhouette:silhouette,sprite:sprite,
            panelOrigin:origin,allowedOrigins:allowed,scale:1,singing:true)!
        precondition(singingPlan.movement == .singingStep && desktop.isBlank(singingPlan.destinationBody),
            "Singing uses direct standing movement even for nearby whitespace")
        for scale: CGFloat in [0.5,1,1.42,2] {
            for (distance,expected): (Double,BackdropAvoidancePlan.Movement) in [
                (8,.scoot),(120,.scoot),(120.01,.frontRetreat),(360,.frontRetreat),(360.01,.walk)] {
                precondition(BackdropAvoidancePlanner.movement(distance:distance*scale,scale:scale,singing:false) == expected)
                precondition(BackdropAvoidancePlanner.movement(distance:distance*scale,scale:scale,singing:true) == .singingStep)
            }
        }
        var trigger = BackdropAvoidanceTrigger()
        precondition(!trigger.observe(plan,at:0) && trigger.needsQuickConfirmation)
        precondition(trigger.observe(plan,at:0.25) && !trigger.needsQuickConfirmation,
                     "Stable destination confirms after one fast fresh scan")
        trigger.reset()
        precondition(!trigger.observe(plan,at:0) && trigger.needsQuickConfirmation)
        let changed = BackdropAvoidancePlan(from:plan.from,to:CGPoint(x:plan.to.x+50,y:plan.to.y),
            movement:plan.movement,destinationBody:plan.destinationBody)
        precondition(!trigger.observe(changed,at:0.25) && !trigger.needsQuickConfirmation,
                     "Changed target is rejected and cannot cause continuous fast polling")
        trigger.reset(until:1)
        precondition(!trigger.observe(plan,at:0.5) && !trigger.needsQuickConfirmation)
        precondition(!trigger.observe(plan,at:1) && trigger.observe(plan,at:2.5))
        trigger.reset(until:12)
        precondition(!trigger.observe(plan,at:4) && !trigger.observe(plan,at:12) && trigger.observe(plan,at:13.5))
        for movement in [BackdropAvoidancePlan.Movement.scoot,.frontRetreat,.walk,.singingStep] {
            let p = BackdropAvoidancePlan(from:origin,to:CGPoint(x:origin.x+(movement == .scoot ? 80 : -320),y:origin.y+15),movement:movement,destinationBody:.zero)
            let player = BackdropRelocation(); player.start(p,scale:1,at:10)
            var last = origin
            var frames = Set<Int>(), launchFrames=Set<Int>()
            for t in stride(from:0.0,to:player.duration,by:1/60) {
                let sample = player.sample(at:10+t)!
                precondition(hypot(sample.origin.x-last.x,sample.origin.y-last.y) < 7, "Continuous travel")
                if movement == .scoot { precondition(sample.stroll == nil && sample.scoot != nil) }
                if movement == .frontRetreat {
                    precondition(sample.frontRetreat != nil && sample.stroll == nil && sample.scoot == nil && !sample.mirrored,
                        "Frontal relocation uses its own artwork without face mirroring")
                    if let f = sample.frontRetreat?.frame { frames.insert(f) }
                    precondition(sample.origin.x <= last.x+0.00001, "Single trip never returns to the source")
                }
                if movement == .singingStep {
                    precondition(sample.stroll == nil && sample.scoot == nil && (32..<40).contains(sample.performanceFrame ?? -1),
                        "Standing movement has no rise, sit or seated scoot")
                    precondition(sample.mirrored, "Left travel uses mirrored step artwork")
                }
                if let f=sample.stroll?.launchFrame {
                    launchFrames.insert(f)
                    precondition(sample.mirrored,"Leftward background relocation mirrors every launch pose")
                }
                if let f = sample.stroll?.frame { frames.insert(f) }
                last = sample.origin
            }
            precondition(hypot(last.x-p.to.x,last.y-p.to.y) < 0.1)
            precondition(player.sample(at:10+player.duration) == nil)
            if movement == .frontRetreat { precondition(frames == Set(0..<8)) }
            if movement == .walk { precondition(Set(StrollTimeline.walkFrames).isSubset(of:frames) && launchFrames == Set(0..<3)) }
            if movement == .frontRetreat {
                player.start(p,scale:1,at:0)
                let interrupted = player.sample(at:FrontRetreatTimeline.outwardStart+0.3)!.origin
                player.settle(at:interrupted,now:3)
                precondition(player.sample(at:3)!.origin == interrupted && player.sample(at:3)!.frontRetreat?.phase == .sitting)
                precondition(player.sample(at:3+FrontRetreatTimeline.sittingDuration+0.35) == nil)
            }
            if movement == .singingStep {
                player.start(p,scale:1,at:0); player.settle(at:origin,now:0.2)
                precondition(player.sample(at:0.2) == nil, "Changed destination stops standing travel without sitting")
            }
        }
        checkManualDragEvents()
        try checkWindows()
        try JSONSerialization.data(withJSONObject:["passed":true,"analysisMode":"uniformity","pixelChecks":["solidBlack","solidBlue","solidWhite","nonTextShape","slightNoise","transparentCorner"],"fixtures":results],options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("analysis-validation.json"))
        print("PASS: pixel contrast, pure-region selection, near/far, alpha silhouette, display mapping, debounce, continuous motion, parent bubbles and committed final anchors")
    }
    private static func checkManualDragEvents() {
        final class DragPanel: SubtitlePanel {
            var destination: CGPoint?
            var onDrag: (() -> Void)?
            override func performDrag(with event: NSEvent) {
                precondition(isManuallyDragging)
                onDrag?()
                if let destination { setFrameOrigin(destination) }
            }
        }
        let panel = DragPanel(contentRect:CGRect(x:200,y:200,width:100,height:100),
                              styleMask:.borderless,backing:.buffered,defer:false)
        panel.tracksCharacterDrag = true; panel.isMovableByWindowBackground = true
        var phases: [String] = []
        panel.onManualDragStarted = { precondition(panel.isManuallyDragging); phases.append("start") }
        panel.onDrag = { phases.append("nativeDrag") }
        panel.onManualDragEnded = { moved in
            precondition(!panel.isManuallyDragging)
            phases.append(moved ? "moved" : "click")
        }
        let event = NSEvent.mouseEvent(with:.leftMouseDown,location:CGPoint(x:50,y:50),modifierFlags:[],
            timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        panel.destination = CGPoint(x:280,y:230)
        panel.sendEvent(event)
        panel.finishManualDragIfReleased(buttonDown:false)
        precondition(phases == ["start","nativeDrag","moved"] && panel.frame.origin == panel.destination)
        phases = []; panel.destination = nil
        panel.sendEvent(event)
        panel.finishManualDragIfReleased(buttonDown:false)
        precondition(phases == ["start","nativeDrag","click"], "A click is not a completed position change")
        phases = []; panel.setFrameOrigin(CGPoint(x:350,y:230))
        precondition(phases.isEmpty, "Programmatic motion never schedules a manual drag check")
        panel.onManualDragStarted = nil; panel.onManualDragEnded = nil; panel.onDrag = nil
        print("PASS: native drag completes once, tracks holding, ignores clicks and programmatic motion")
    }
    private static func checkWindows() throws {
        let suite = "captions-avoidance-checks-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = CharacterPositionStore(defaults:defaults), overlays = ProjectOverlays(positionStore:store)
        let items = [OverlayItem(id:"deepseek",text:"避让检查",header:"DeepSeek",title:"避让",active:true,mascot:.deepseek),
            OverlayItem(id:"codex",text:"独立来源",header:"Codex",title:"Codex",active:true,mascot:.codex)]
        for movement in [BackdropAvoidancePlan.Movement.scoot,.frontRetreat,.walk] {
            for movable in [true,false] {
                func update() { overlays.update(items,font:24,opacity:0.6,bottom:30,screenIndex:0,movable:movable,focusedID:"deepseek") }
                update()
                let c = overlays.character(for:.deepseek)!, bubble = overlays.controller(for:"deepseek")!, other = overlays.character(for:.codex)!
                let source = c.panel.frame, b = bubble.panel.frame, otherFrame = other.panel.frame
                let originalAnchor = store.anchor(for:"deepseek",in:NSScreen.screens[0].visibleFrame)
                let allowed = overlays.deepSeekAllowedOrigins
                let destination = CGPoint(x:min(source.minX+80,allowed.maxX),y:source.minY)
                let plan = BackdropAvoidancePlan(from:source.origin,to:destination,movement:movement,destinationBody:.zero)
                let player = BackdropRelocation(); player.start(plan,scale:1,at:0)
                overlays.beginDeepSeekRelocation()
                for t in stride(from:0.0,to:player.duration,by:0.08) {
                    overlays.applyDeepSeekRelocation(player.sample(at:t)!)
                    update()
                    precondition(abs(bubble.panel.frame.minX-b.minX-(c.panel.frame.minX-source.minX)) < 1)
                    precondition(other.panel.frame == otherFrame)
                    overlays.flushPositions()
                    precondition(store.anchor(for:"deepseek",in:NSScreen.screens[0].visibleFrame) == originalAnchor)
                }
                precondition(!overlays.deepSeekRelocationInterrupted, "Our own movement and redraw are not manual drags")
                let endpointPixels = c.subtitle.bitmapImageRepForCachingDisplay(in:c.subtitle.bounds)!
                c.subtitle.cacheDisplay(in:c.subtitle.bounds,to:endpointPixels)
                overlays.endDeepSeekRelocation(); update()
                if movement == .frontRetreat {
                    let finalPixels = c.subtitle.bitmapImageRepForCachingDisplay(in:c.subtitle.bounds)!
                    c.subtitle.cacheDisplay(in:c.subtitle.bounds,to:finalPixels)
                    precondition(endpointPixels.representation(using:.png,properties:[:]) == finalPixels.representation(using:.png,properties:[:]),
                        "Automatic retreat keeps the same seated pixels after arrival")
                    precondition(c.subtitle.frontRetreatSample == nil && c.subtitle.hasScootRestPose)
                }
                precondition(abs(c.panel.frame.minX-destination.x) < 1 && c.subtitle.scootSample == nil)
                precondition(store.anchor(for:"deepseek",in:NSScreen.screens[0].visibleFrame)?.x == c.panel.frame.midX)
                if movable {
                    overlays.beginDeepSeekRelocation()
                    c.panel.setFrameOrigin(CGPoint(x:c.panel.frame.minX-30,y:c.panel.frame.minY))
                    RunLoop.main.run(until:Date().addingTimeInterval(0.03))
                    precondition(overlays.deepSeekRelocationInterrupted, "Manual drag interrupts automatic relocation")
                    overlays.endDeepSeekRelocation()
                }
            }
        }
        overlays.update([],font:24,opacity:0.6,bottom:30,screenIndex:0,movable:true,focusedID:"")
    }
}
