import AppKit
import ImageIO
import UniformTypeIdentifiers

enum SeatedScootChecks {
    static func run() throws {
        let art = DeepSeekScoot.shared, mascot = MascotAnimation.library[.deepseek]!
        precondition(art.available)
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAPTIONS_SCOOT_OUTPUT"]
            ?? FileManager.default.currentDirectoryPath+"/output/deepseek-scoot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for image in art.frames {
            let rep = NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            var minX = 448, maxX = 0, minY = 512, maxY = 0
            for y in 0..<512 { for x in 0..<448 where (rep.colorAt(x:x,y:y)?.alphaComponent ?? 0) > 0.4 {
                minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
            } }
            precondition(minX >= 8 && maxX < 440 && minY >= 3 && maxY < 509, "Full seated silhouette fits the canvas")
            precondition(abs(maxY-492) <= 2, "Feet stay on the floor")
        }
        // The effort expression must retain visible blue irises in BOTH eyes.
        let effort = NSBitmapImageRep(cgImage: art.frames[5].cgImage(forProposedRect:nil,context:nil,hints:nil)!)
        for eye in [CGRect(x:154,y:233,width:28,height:23), CGRect(x:233,y:221,width:28,height:24)] {
            var irisPixels = 0
            for y in Int(eye.minY)..<Int(eye.maxY) { for x in Int(eye.minX)..<Int(eye.maxX) {
                let color = effort.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if color.blueComponent > 0.3 && color.blueComponent > color.redComponent*1.4
                    && color.greenComponent > color.redComponent*1.2 { irisPixels += 1 }
            } }
            precondition(irisPixels > 120, "Scooting uses a small squint, never fully closed eyes")
        }
        precondition(SeatedScootTimeline.sample(at:-1) == nil)
        precondition(SeatedScootTimeline.sample(at:.nan) == nil)
        precondition(SeatedScootTimeline.sample(at:SeatedScootTimeline.duration) == nil)
        var previous = 0.0
        for t in stride(from:0.0,to:SeatedScootTimeline.duration,by:1/60) {
            let s = SeatedScootTimeline.sample(at:t)!
            precondition((0...3).contains(s.offset) && abs(s.offset-previous) < 0.07, "Bounded continuous motion")
            previous = s.offset
        }
        let suite = "captions-scoot-checks-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = CharacterPositionStore(defaults:defaults)
        let overlays = ProjectOverlays(positionStore:store)
        let items = [OverlayItem(id:"scoot",text:"坐着挪动",header:"DeepSeek",title:"挪动",active:true,mascot:.deepseek),
                     OverlayItem(id:"codex",text:"独立角色",header:"Codex",title:"Codex",active:true,mascot:.codex)]
        func update() { overlays.update(items,font:28,opacity:0.68,bottom:90,screenIndex:0,movable:true,focusedID:"scoot") }
        update()
        let character = overlays.character(for:.deepseek)!, codex = overlays.character(for:.codex)!
        let bubble = overlays.controller(for:"scoot")!
        let area = NSScreen.screens[0].visibleFrame
        let saved = store.anchor(for:"deepseek",in:area)!
        let origin = character.panel.frame, bubbleOrigin = bubble.panel.frame, otherOrigin = codex.panel.frame
        for t in [0.0, 1.4, 3.98, 5.7, 7.8] {
            overlays.setDeepSeekScoot(SeatedScootTimeline.sample(at:t))
            RunLoop.main.run(until:Date().addingTimeInterval(0.025))
            let dx = character.panel.frame.minX-origin.minX
            precondition(character.panel.frame.minY == origin.minY && character.panel.frame.size == origin.size)
            precondition(abs(bubble.panel.frame.minX-bubbleOrigin.minX-dx) < 1, "Bubble follows actual movement")
            precondition(codex.panel.frame == otherOrigin, "Other source stays independent")
            update() // Caption/layout refresh must not lose the temporary animation position.
            overlays.flushPositions()
            precondition(store.anchor(for:"deepseek",in:area) == saved, "Temporary movement never enters position memory")
        }
        overlays.setDeepSeekScoot(nil); update()
        precondition(character.panel.frame == origin && bubble.panel.frame == bubbleOrigin, "Stop restores position")
        precondition(character.subtitle.scootSample == nil)
        // Check interruption at a nonzero offset and repeated playback.
        overlays.setDeepSeekScoot(SeatedScootTimeline.sample(at:3.98))
        precondition(abs(character.panel.frame.minX-origin.minX) > 20)
        overlays.setDeepSeekScoot(nil); update()
        precondition(character.panel.frame == origin)
        // At the right edge, choose the leftward route and keep the whole group visible.
        let shift = area.maxX-bubble.panel.frame.maxX
        character.panel.setFrameOrigin(NSPoint(x:character.panel.frame.minX+shift,y:origin.minY))
        RunLoop.main.run(until:Date().addingTimeInterval(0.03))
        update()
        let edgeOrigin = character.panel.frame
        overlays.setDeepSeekScoot(SeatedScootTimeline.sample(at:3.98))
        precondition(character.panel.frame.minX < edgeOrigin.minX, "Edge routes inward")
        precondition(bubble.panel.frame.minX >= area.minX && bubble.panel.frame.maxX <= area.maxX+1)
        overlays.setDeepSeekScoot(SeatedScootTimeline.sample(at:2.2))
        precondition(overlays.deepSeekScootPhase == "坐着向左挪动", "Displayed direction follows the edge route")
        overlays.setDeepSeekScoot(nil); update()
        precondition(character.panel.frame == edgeOrigin)
        // Both directions land on the same pose, then resume ordinary thinking.
        let view = SubtitleView(frame:NSRect(x:0,y:0,width:147,height:226))
        view.mode = .character; view.setMascot(.deepseek,animating:true)
        func rendered() -> Data {
            let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:rep)
            return rep.representation(using:.png,properties:[:])!
        }
        view.setScootSample(SeatedScootTimeline.sample(at:4.1))
        let rightRest = rendered()
        view.setScootSample(SeatedScootTimeline.sample(at:SeatedScootTimeline.duration-0.01))
        let leftRest = rendered()
        precondition(rightRest == leftRest, "Left and right use an identical opaque resting frame")
        view.setScootSample(nil)
        precondition(view.hasScootRestPose && rendered() == leftRest, "Recovery starts on the exact landing frame")
        view.setAudioMouth(3)
        precondition(view.hasScootRestPose, "Speech does not interrupt the landing transition")
        view.setAudioMouth(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.5))
        precondition(!view.hasScootRestPose && view.seatedGazeActive && view.mascotAnimating,
                     "Scoot completion restores ordinary thinking and gaze")
        // A new action cancels the return timer without a stale seated redraw.
        view.setScootSample(.init(frame:7,offset:0,phase:"坐稳")); view.setScootSample(nil)
        view.setStrollSample(StrollTimeline.sample(at:1))
        RunLoop.main.run(until:Date().addingTimeInterval(0.5))
        precondition(!view.hasScootRestPose && view.strollSample != nil && !view.seatedGazeActive)
        view.setStrollSample(nil)
        view.setScootSample(.init(frame:7,offset:0,phase:"坐稳")); view.setScootSample(nil)
        let recovery = CGImageDestinationCreateWithURL(folder.appendingPathComponent("thinking-recovery.gif") as CFURL,
            UTType.gif.identifier as CFString,75,nil)!
        CGImageDestinationSetProperties(recovery,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        var recoveredFrames = Set<Data>()
        for i in 0..<75 {
            let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:rep)
            if i >= 12 { recoveredFrames.insert(rep.representation(using:.png,properties:[:])!) }
            CGImageDestinationAddImage(recovery,rep.cgImage!,
                [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
            if [0,4,8,12,40].contains(i) {
                try rep.representation(using:.png,properties:[:])!
                    .write(to:folder.appendingPathComponent("recovery-\(i).png"))
            }
            RunLoop.main.run(until:Date().addingTimeInterval(0.04))
        }
        precondition(CGImageDestinationFinalize(recovery))
        precondition(!view.hasScootRestPose && view.seatedGazeActive)
        precondition(recoveredFrames.count > 1, "Recovered thinking visibly blinks over a full cycle")
        view.setMascot(.deepseek,animating:false)
        let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("seated-scoot.gif") as CFURL,
            UTType.gif.identifier as CFString,214,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<214 {
            let s = SeatedScootTimeline.sample(at:min(Double(i)/25,SeatedScootTimeline.duration-0.001))!
            let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:288,pixelsHigh:196,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:image)
            NSColor(calibratedWhite:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:288,height:196).fill()
            art.draw(s,animation:mascot,in:NSRect(x:24+s.offset*32,y:12,width:126,height:168))
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(gif,image.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        overlays.update([],font:28,opacity:0.68,bottom:90,screenIndex:0,movable:true,focusedID:"")
        print("PASS: eight seated sprites, visible blue irises during the effort expression, fixed floor, continuous scoot, bubble sync, independent Codex, position memory, inward edge route and stop restoration; default-size GIF exported")
    }
}
