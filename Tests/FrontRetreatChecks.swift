import AppKit
import ImageIO
import UniformTypeIdentifiers

enum FrontRetreatChecks {
    static func run() throws {
        let art = DeepSeekFrontRetreat.shared, mascot = MascotAnimation.library[.deepseek]!
        precondition(art.available,"Eight frontal retreat frames and twelve dedicated transition poses bundled")
        let folder = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CAPTIONS_FRONT_RETREAT_OUTPUT"]
            ?? FileManager.default.currentDirectoryPath+"/output/deepseek-front-retreat")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var fingerprints = Set<Data>()
        for image in art.frames+art.transitionFrames {
            let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
            precondition(cg.width == 448 && cg.height == 640)
            let rep = NSBitmapImageRep(cgImage:cg)
            if art.frames.contains(where: { $0 === image }) { fingerprints.insert(rep.representation(using:.png,properties:[:])!) }
            var xs = [Int](), ys = [Int]()
            for y in 0..<640 { for x in 0..<448 where (rep.colorAt(x:x,y:y)?.alphaComponent ?? 0) > 0.4 {
                xs.append(x); ys.append(y)
            } }
            precondition(xs.min()! >= 8 && xs.max()! < 440 && ys.min()! > 8 && ys.max()! < 632,"Full hair, hands, feet and whale tail fit")
            precondition(abs(ys.max()!-620) <= 2,"Floor registration stays fixed")
            precondition(rep.colorAt(x:0,y:0)!.alphaComponent == 0,"Transparent background")
        }
        precondition(fingerprints.count == 8,"Eight distinct stepping poses")
        for invalid in [-1,Double.nan,Double.infinity,FrontRetreatTimeline.duration] {
            precondition(FrontRetreatTimeline.sample(at:invalid) == nil)
        }
        var previous = 0.0, frames = Set<Int>(), phases = [FrontRetreatTimeline.Phase]()
        var deltas = [Double]()
        for t in stride(from:0.0,to:FrontRetreatTimeline.duration,by:1/120) {
            let sample = FrontRetreatTimeline.sample(at:t)!
            if phases.last != sample.phase { phases.append(sample.phase) }
            if let frame = sample.frame { frames.insert(frame) }
            if let transition = sample.transitionFrame { precondition((1...11).contains(transition),"Only dedicated frontal transition poses") }
            precondition((0...1).contains(sample.offset) && abs(sample.offset-previous) < 0.025,"Continuous bounded lateral movement")
            if sample.phase == .outward { deltas.append(sample.offset-previous) }
            previous = sample.offset
        }
        precondition(frames == Set(0..<8))
        precondition(phases == [.seated,.rising,.ready,.outward,.braking,.returning,.braking,.sitting,.finished])
        precondition(deltas.filter { abs($0) < 0.000001 }.count > 15 && deltas.max()! > 0.007,"Visible pushes and pauses instead of constant velocity")
        precondition(FrontRetreatTimeline.sample(at:FrontRetreatTimeline.duration-0.001)!.offset == 0)

        // The preview starts from the actual current pixels, then ends on the same seated body it keeps afterwards.
        let endpointView = SubtitleView(frame:NSRect(x:0,y:0,width:147,height:226))
        endpointView.mode = .character; endpointView.setMascot(.deepseek,animating:false)
        func rendered() -> Data {
            let rep = endpointView.bitmapImageRepForCachingDisplay(in:endpointView.bounds)!
            endpointView.cacheDisplay(in:endpointView.bounds,to:rep)
            return rep.representation(using:.png,properties:[:])!
        }
        for scootRest in [false,true] {
            endpointView.setMascot(nil,animating:false); endpointView.setMascot(.deepseek,animating:false)
            if scootRest {
                endpointView.setScootSample(.init(frame:7,offset:0,phase:"坐稳")); endpointView.setScootSample(nil)
            }
            let before = rendered()
            endpointView.setFrontRetreatSample(FrontRetreatTimeline.sample(at:0))
            precondition(rendered() == before,"Starting from thinking or scoot rest has no refresh")
            endpointView.setFrontRetreatSample(FrontRetreatTimeline.sample(at:FrontRetreatTimeline.readyStart-0.001))
            let ready = rendered()
            endpointView.setFrontRetreatSample(FrontRetreatTimeline.sample(at:FrontRetreatTimeline.readyStart+0.001))
            precondition(rendered() == ready,"Transition into the step cycle reuses the same opaque ready pose")
            endpointView.setFrontRetreatSample(FrontRetreatTimeline.sample(at:FrontRetreatTimeline.duration-0.001))
            let finalSeat = rendered()
            endpointView.setFrontRetreatSample(nil)
            precondition(endpointView.hasScootRestPose && rendered() == finalSeat,"Recovery starts on the exact seated body")
            endpointView.setAudioMouth(3)
            precondition(endpointView.hasScootRestPose,"Speech preserves the return transition")
            endpointView.setAudioMouth(nil)
            RunLoop.main.run(until:Date().addingTimeInterval(0.5))
            precondition(!endpointView.hasScootRestPose && endpointView.seatedGazeActive,
                         "Front retreat completion restores ordinary thinking")
        }

        let suite = "captions-front-retreat-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = CharacterPositionStore(defaults:defaults), overlays = ProjectOverlays(positionStore:store)
        let items = [OverlayItem(id:"front",text:"先让一让，马上挪开！",header:"DeepSeek",title:"急退",active:true,mascot:.deepseek),
                     OverlayItem(id:"codex",text:"独立字幕",header:"Codex",title:"Codex",active:true,mascot:.codex)]
        let area = NSScreen.screens[0].visibleFrame
        for movable in [true,false] {
            func update() { overlays.update(items,font:28,opacity:0.68,bottom:90,screenIndex:0,movable:movable,focusedID:"front") }
            update()
            let character = overlays.character(for:.deepseek)!, codex = overlays.character(for:.codex)!
            let bubble = overlays.controller(for:"front")!
            let original = character.panel.frame, originalBubble = bubble.panel.frame, other = codex.panel.frame
            let saved = store.anchor(for:"deepseek",in:area)!
            for time in [0,FrontRetreatTimeline.outwardStart+0.3,FrontRetreatTimeline.brakeStart+0.1,FrontRetreatTimeline.returnStart+0.9] {
                overlays.setDeepSeekFrontRetreat(FrontRetreatTimeline.sample(at:time))
                let frame = character.panel.frame, dx = frame.minX-original.minX
                precondition(frame.minY == original.minY && frame.size == original.size,"No vertical window drift or reflow")
                precondition(abs(bubble.panel.frame.minX-originalBubble.minX-dx) < 1,"Caption follows actual horizontal motion")
                precondition(codex.panel.frame == other,"Codex remains independent")
                update(); overlays.flushPositions()
                precondition(character.panel.frame == frame,"Refresh preserves transient movement")
                precondition(store.anchor(for:"deepseek",in:area) == saved,"Preview does not overwrite position memory")
                precondition(!character.subtitle.strollMirrored,"No left/right face or asymmetric-tail mirroring")
            }
            overlays.setDeepSeekFrontRetreat(nil); update()
            precondition(character.panel.frame == original && bubble.panel.frame == originalBubble,"Stop restores actual original anchor")
            precondition(character.subtitle.frontRetreatSample == nil)
            overlays.setDeepSeekFrontRetreat(FrontRetreatTimeline.sample(at:FrontRetreatTimeline.brakeStart+0.1))
            update()
            overlays.setDeepSeekFrontRetreat(nil)
            overlays.update([],font:28,opacity:0.68,bottom:90,screenIndex:0,movable:movable,focusedID:"")
            update()
            precondition(character.panel.frame == original,"Hide/show after stop retains original anchor")
        }
        // At the right edge, move left and keep the whole attached caption group within the display.
        overlays.update(items,font:28,opacity:0.68,bottom:90,screenIndex:0,movable:true,focusedID:"front")
        let character = overlays.character(for:.deepseek)!, bubble = overlays.controller(for:"front")!
        character.panel.setFrameOrigin(NSPoint(x:character.panel.frame.minX+area.maxX-bubble.panel.frame.maxX,y:character.panel.frame.minY))
        RunLoop.main.run(until:Date().addingTimeInterval(0.03))
        let edgeOrigin = character.panel.frame
        overlays.setDeepSeekFrontRetreat(FrontRetreatTimeline.sample(at:FrontRetreatTimeline.brakeStart-0.02))
        precondition(character.panel.frame.minX < edgeOrigin.minX && bubble.panel.frame.minX >= area.minX)
        precondition(overlays.deepSeekFrontRetreatPhase == FrontRetreatTimeline.Phase.returning.rawValue,"Labels follow inward edge route")
        overlays.setDeepSeekFrontRetreat(nil)
        precondition(character.panel.frame == edgeOrigin)
        let view = character.subtitle
        view.setFrontRetreatSample(FrontRetreatTimeline.sample(at:2))
        view.setMascot(.deepseek,animating:true,pinkBear:true)
        precondition(view.frontRetreatSample == nil,"Changing binding clears the new action")
        overlays.update([],font:28,opacity:0.68,bottom:90,screenIndex:0,movable:true,focusedID:"")

        let contact = bitmap(896,640)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:contact)
        NSColor(calibratedWhite:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:896,height:640).fill()
        for (i,image) in art.frames.enumerated() { image.draw(in:NSRect(x:i%4*224,y:(1-i/4)*320,width:224,height:320)) }
        NSGraphicsContext.restoreGraphicsState()
        try contact.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("contact-sheet.png"))
        let transitionContact = bitmap(896,960)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:transitionContact)
        NSColor(calibratedWhite:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:896,height:960).fill()
        for (i,frame) in art.transitionFrames.enumerated() { frame.draw(in:NSRect(x:i%4*224,y:(2-i/4)*320,width:224,height:320)) }
        NSGraphicsContext.restoreGraphicsState()
        try transitionContact.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("transition-contact-sheet.png"))
        let count = Int(ceil(FrontRetreatTimeline.duration*30))
        let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("front-retreat.gif") as CFURL,UTType.gif.identifier as CFString,count,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<count {
            let sample = FrontRetreatTimeline.sample(at:min(Double(i)/30,FrontRetreatTimeline.duration-0.001))!
            let image = bitmap(360,240)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:image)
            NSColor(calibratedWhite:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:360,height:240).fill()
            art.draw(sample,animation:mascot,in:NSRect(x:20+sample.offset*168,y:12,width:147,height:210),fromScootRest:true)
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(gif,image.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        let result: [String:Any] = ["passed":true,"frames":frames.sorted(),"phases":phases.map(\.rawValue),
                                  "duration":FrontRetreatTimeline.duration,"cycleDurations":FrontRetreatTimeline.cycleDurations,
                                  "dedicatedTransitionFrames":art.transitionFrames.count,"noEndpointRefresh":true,"variableVelocity":true,"bubbleFollows":true,
                                  "independentCodex":true,"positionMemoryPreserved":true,"edgeRoute":true]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("geometry-validation.json"))
        print("PASS: eight frontal retreat poses, fixed floor, variable step velocity, both directions, bubble sync, independent sources, memory preservation and stop restoration")
    }
    private static func bitmap(_ w: Int,_ h: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,
                         hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    }
}
