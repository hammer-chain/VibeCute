import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum WindowPeekChecks {
    static func checkWithdrawalArtwork() throws {
        let folder=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CAPTIONS_WINDOW_PEEK_OUTPUT"] ?? "output/deepseek-withdraw-v6")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var checks:[[String:Any]]=[]
        for scale in [0.5,1.0,2.0] {for mirrored in [false,true] {
            let view=WindowPeekSpriteView(frame:NSRect(x:0,y:0,width:147*scale,height:(226+WindowPeekArtwork.lowerBodyExtension*147/448)*scale))
            view.layoutScale=scale;view.mirrored=mirrored;view.peekFrame=2
            func render(_ progress:Double,opaque:Bool=false)->NSBitmapImageRep {
                view.concealment=progress
                let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(view.bounds.width)),pixelsHigh:Int(ceil(view.bounds.height)),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
                if opaque {NSColor(calibratedWhite:0.96,alpha:1).setFill();view.bounds.fill()}
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState();return rep
            }
            func top(_ rep:NSBitmapImageRep)->Int {
                for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide where rep.colorAt(x:x,y:y)!.alphaComponent>0.8 {return y}}
                return rep.pixelsHigh
            }
            let jump=abs(top(render(0.54-0.00001))-top(render(0.54+0.00001)))
            precondition(jump<=2,"Release jumps vertically by \(jump) pixels")
            precondition(top(render(0.9999))==Int(ceil(view.bounds.height)),"Final retreat must be fully concealed")
            checks.append(["scale":scale,"mirrored":mirrored,"releaseTopJumpPixels":jump])
            if scale==1 && !mirrored {
                let gif=CGImageDestinationCreateWithURL(folder.appendingPathComponent("withdraw-artwork.gif") as CFURL,UTType.gif.identifier as CFString,115,nil)!
                CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
                for i in 0..<115 {
                    let rep=render(max(0,min(1,(-0.3+Double(i)/50)/WindowPeekArtwork.withdrawalDuration)),opaque:true)
                    CGImageDestinationAddImage(gif,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.02]] as CFDictionary)
                }
                precondition(CGImageDestinationFinalize(gif))
            }
        }}
        try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("release-continuity.json"))
        print("PASS: withdrawal release pixel continuity in both directions at 50/100/200 percent, fully concealed endpoint")
    }
    static func run() throws {
        let folder = ProcessInfo.processInfo.environment["CAPTIONS_WINDOW_PEEK_OUTPUT"].map { URL(fileURLWithPath:$0) }
            ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/deepseek-window-peek")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try checkMotionAssets(folder:folder)
        try checkRenderedBodySize(folder:folder)
        let controller = WindowPeekController()
        let screen = NSScreen.screens.first!.visibleFrame
        let original = NSRect(x:screen.midX+350,y:screen.midY-130,width:147,height:226)
        precondition(controller.start(from:original,scale:1,forceFixture:true,hold:2.5),controller.status)
        precondition(controller.movementSpeed == 150,"Window hiding uses the jog speed by default")
        let started = ProcessInfo.processInfo.systemUptime
        let area = controller.fixture!.frame.union(original).insetBy(dx:-180,dy:-35)
        let count = Int((controller.duration+4)/0.04)
        let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("walk-behind-and-peek.gif") as CFURL,
            UTType.gif.identifier as CFString,count,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        var phases: [String] = [], moved = Set<String>()
        var rows: [[String:Any]] = [], seenHidden = false, seenGrip = false, seenParked = false
        var approachFrames = Set<Int>(), enterFrames = Set<Int>()
        var withdrawalChecks: [[String:Any]] = []
        var entryArea:NSRect?,entryImages:[CGImage]=[]
        for i in 0..<count {
            controller.tick(at:started+Double(i)*0.04)
            RunLoop.main.run(until:Date().addingTimeInterval(0.006))
            precondition(controller.isRunning)
            let phase = controller.phase.rawValue
            if phases.last != phase { phases.append(phase) }
            if controller.phase == .approaching { moved.insert(NSStringFromRect(controller.body.frame)) }
            if controller.phase == .approaching {
                let sample = controller.bodyView.stroll
                precondition(sample.phase == .walking && sample.armSwing != nil,"Both moving stages use the shared jog with swinging arms")
                if controller.phase == .approaching { approachFrames.insert(sample.frame!) }

            }
            if controller.phase == .entering {
                precondition(controller.bodyView.entryFrame != nil && controller.bodyView.coverFrame == nil)
                enterFrames.insert(controller.bodyView.entryFrame!)
            }
            let row = controller.diagnostics
            rows.append(row)
            if let grip=row["entryGripScreenX"] as? CGFloat {
                precondition(abs(grip-controller.target!.edgeX)<1.1,"Gripping hands stay on real border within native pixel rounding: \(grip) vs \(controller.target!.edgeX)")
            }
            if controller.body.level == .normal && controller.body.frame.intersects(controller.target!.frame) {
                let ids = row["windowOrder"] as! [Int]
                let target = Int(controller.target!.id)
                precondition(ids.firstIndex(of:target)! < ids.firstIndex(of:controller.body.windowNumber)!,
                             "Walking sprite must be physically below the real target window")
            }
            if controller.phase == .hidden {
                seenHidden = true
                precondition(controller.target!.frame.contains(controller.coveredBodyRect),"Face, palms, torso and feet are physically behind the wall")
                if let cg = controller.renderFixtureScene(in:area) { try save(cg,to:folder.appendingPathComponent("hidden.png")) }
            }
            if controller.phase == .peeking {
                seenGrip = true
                let target = controller.target!, unit = controller.peek.frame.width/448
                let gripX = controller.peek.frame.minX+(target.side == .left ? 352 : 96)*unit
                let gripY = controller.peek.frame.minY+8+WindowPeekArtwork.gripY*unit
                precondition(abs(gripX-target.edgeX) < 1.1 && abs(gripY-target.gripY) < 1.1,"Hands must grip the actual border")
                let ids = row["windowOrder"] as! [Int]
                precondition(ids.firstIndex(of:controller.peek.windowNumber)! < ids.firstIndex(of:Int(target.id))!,
                             "Head/hands must be physically above the window")
                if controller.peekView.peekFrame == 2, let cg = controller.renderFixtureScene(in:area) {
                    try save(cg,to:folder.appendingPathComponent("peeking.png"))
                }
            }
            if controller.phase == .parked {
                seenParked = true
                precondition(controller.target!.frame.contains(controller.coveredBodyRect),"Body stays behind the window")
                precondition(controller.peekView.concealment == 1,"Peek is fully withdrawn; the complete bracing pose remains underneath")
                if let cg = controller.renderFixtureScene(in:area) { try save(cg,to:folder.appendingPathComponent("parked.png")) }
            }
            if [.turning,.entering,.hidden].contains(controller.phase) {
                if entryArea == nil { entryArea=controller.body.frame.insetBy(dx:-60,dy:-20) }
                entryImages.append(controller.renderFixtureScene(in:entryArea!)!)
            }
            let cg = controller.renderFixtureScene(in:area)!
            CGImageDestinationAddImage(gif,cg,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        let entryGif=CGImageDestinationCreateWithURL(folder.appendingPathComponent("turn-and-hide-closeup.gif") as CFURL,UTType.gif.identifier as CFString,entryImages.count,nil)!
        CGImageDestinationSetProperties(entryGif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for image in entryImages {CGImageDestinationAddImage(entryGif,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)}
        precondition(CGImageDestinationFinalize(entryGif))
        precondition(moved.count > 5 && seenHidden && seenGrip && seenParked)
        precondition(phases == ["起身","小跑到窗口旁","转向窗口","侧步收身藏到窗口后面","藏在窗口后面","扒着窗口探头","缩回窗口后面","停在窗口后"],"Incomplete action: \(phases)")
        precondition(approachFrames == Set(StrollTimeline.walkFrames) && enterFrames == Set(1...9),
            "All twelve approach jog frames and nine articulated entry poses play")
        let stationaryBody = controller.body.frame, stationaryPeek = controller.peek.frame
        controller.tick(at:started+controller.duration+120)
        precondition(controller.isRunning && controller.phase == .parked && controller.fixture != nil)
        precondition(controller.body.frame == stationaryBody && controller.peek.frame == stationaryPeek,"Never automatically walk back")
        try checkConcealedArtwork(controller.bodyView,folder:folder)
        withdrawalChecks.append(try checkWithdrawal(controller,folder:folder))
        controller.stop()
        precondition(!controller.isRunning && !controller.body.isVisible && !controller.peek.isVisible && controller.fixture == nil)

        // Test both borders, then live move/resize and target close.
        var tracked: [[String:Any]] = []
        for side in DesktopWindowTarget.Side.all {
            let start = NSRect(x:side == .left ? screen.midX-400 : screen.midX+350,y:screen.midY-130,width:147,height:226)
            precondition(controller.start(from:start,scale:1,forceFixture:true,speed:140,hold:8))
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            let base = ProcessInfo.processInfo.systemUptime
            var holdClock = base
            for i in 0..<800 {
                holdClock = base+Double(i)*0.05
                controller.tick(at:holdClock)
                RunLoop.main.run(until:Date().addingTimeInterval(0.003))
                if controller.phase == .parked { break }
            }
            precondition(controller.target?.side == side && controller.body.isVisible,controller.status)
            withdrawalChecks.append(try checkWithdrawal(controller,folder:folder))
            // The tail-reveal replay advances the injected clock 1.6 seconds
            // beyond parking; target changes must continue after that replay.
            holdClock = max(holdClock,base+controller.duration+1.65)+0.3
            let old = controller.fixture!.frame
            // Move inward so this tracking fixture keeps the body covered;
            // moves that expose it are verified by checkRecovery below.
            let shift:CGFloat = side == .left ? -8 : 8
            controller.fixture!.setFrame(old.offsetBy(dx:shift,dy:5),display:true)
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            holdClock += 0.2
            controller.tick(at:holdClock)
            let movedTarget = DesktopWindowTarget.resolve(CGWindowID(controller.fixture!.windowNumber),side:side)!
            precondition(abs(movedTarget.frame.minX-old.minX-shift) < 1.1)
            controller.fixture!.setFrame(NSRect(x:old.minX+shift,y:old.minY+5,width:old.width+45,height:old.height+35),display:true)
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            holdClock += 0.2
            controller.tick(at:holdClock)
            let target = controller.target!, unit = controller.peek.frame.width/448
            precondition(abs(controller.peek.frame.minX+(side == .left ? 352 : 96)*unit-target.edgeX) < 1.1)
            precondition(abs(controller.peek.frame.minY+8+WindowPeekArtwork.gripY*unit-target.gripY) < 1.1)
            tracked.append(controller.diagnostics)
            controller.fixture!.close()
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            controller.tick(at:holdClock+0.2)
            precondition(controller.isRecovering && controller.phase == .startled)
            let loss = holdClock+0.2
            controller.tick(at:loss+controller.recoveryDuration+0.001)
            precondition(!controller.isRunning && !controller.body.isVisible && !controller.peek.isVisible)
        }
        for scale: CGFloat in [0.5,2] {
            precondition(controller.start(from:original,scale:scale,forceFixture:true,speed:160,hold:4))
            RunLoop.main.run(until:Date().addingTimeInterval(0.04))
            let base = ProcessInfo.processInfo.systemUptime
            for i in 0..<800 {
                controller.tick(at:base+Double(i)*0.05)
                RunLoop.main.run(until:Date().addingTimeInterval(0.002))
                if controller.phase == .parked { break }
            }
            precondition(controller.isRunning && controller.body.isVisible,controller.status)
            let target = controller.target!, unit = controller.peek.frame.width/448
            let gripX = controller.peek.frame.minX+(target.side == .left ? 352 : 96)*unit
            let gripY = controller.peek.frame.minY+8*scale+WindowPeekArtwork.gripY*unit
            precondition(abs(gripX-target.edgeX)<1.1 && abs(gripY-target.gripY)<1.1,"Scaled hands must grip border")
            precondition(target.frame.contains(controller.coveredBodyRect),"Scaled body must fit behind window")
            controller.tick(at:base+controller.duration+1.2)
            try checkConcealedArtwork(controller.bodyView,folder:folder)
            withdrawalChecks.append(try checkWithdrawal(controller,folder:folder))
            controller.stop()
        }
        try checkRecovery(folder:folder)
        let overlays = ProjectOverlays()
        let items = [OverlayItem(id:"peek-deepseek",text:"保留字幕位置",header:"DeepSeek",title:"",active:true,mascot:.deepseek),
                     OverlayItem(id:"peek-codex",text:"独立角色",header:"Codex",title:"",active:true,mascot:.codex)]
        func update() { overlays.update(items,font:20,opacity:0.6,bottom:50,screenIndex:0,movable:true,focusedID:"peek-deepseek") }
        update()
        let before = overlays.character(for:.deepseek)!.panel.frame
        let codex = overlays.character(for:.codex)!.panel.frame
        overlays.setSourceHidden(.deepseek,true); update()
        precondition(!overlays.character(for:.deepseek)!.panel.isVisible)
        precondition(overlays.character(for:.codex)!.panel.isVisible && overlays.character(for:.codex)!.panel.frame == codex)
        overlays.setSourceHidden(.deepseek,false); update()
        precondition(overlays.character(for:.deepseek)!.panel.isVisible && overlays.character(for:.deepseek)!.panel.frame == before)
        let allowed = overlays.deepSeekAllowedOrigins
        let endpoint = NSRect(x:allowed.minX,y:before.minY,width:before.width,height:before.height)
        overlays.setSourceHidden(.deepseek,true)
        overlays.finishDeepSeekWindowRecovery(at:endpoint)
        overlays.setSourceHidden(.deepseek,false); update(); update()
        precondition(abs(overlays.character(for:.deepseek)!.panel.frame.minX-endpoint.minX)<1,
            "Finishing recovery keeps the reached edge after subsequent layout updates")
        precondition(overlays.character(for:.codex)!.panel.frame == codex)
        overlays.update([],font:20,opacity:0.6,bottom:50,screenIndex:0,movable:true,focusedID:"",
            restingMascots:[.deepseek])
        precondition(overlays.character(for:.deepseek)!.panel.isVisible && !overlays.character(for:.deepseek)!.subtitle.mascotAnimating,
            "Idle character remains visible without a stale caption or working animation")
        try JSONSerialization.data(withJSONObject:["passed":true,"phases":phases,"physicalWindowOrdering":true,
            "joggingPositions":moved.count,"defaultJogSpeed":WindowPeekController.jogSpeed,
            "approachJogFrames":approachFrames.sorted(),"enterJogFrames":enterFrames.sorted(),
            "armSwingInBothStages":true,"windowMoveResizeClose":true,"explicitStopRestoresOriginalPosition":true,"returnToEdgeRetained":true,
            "withdrawalContinuity":withdrawalChecks,
            "persistentPositionWithTailSwing":true,"visibleParts":["tail emerging after complete concealment"],"scales":[0.5,1,2],
            "independentCodexUnchanged":true,"borders":["left","right"],"tracking":tracked],
            options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("geometry-validation.json"))
        try JSONSerialization.data(withJSONObject:["passed":true,"checks":withdrawalChecks],options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("withdrawal-validation.json"))
        print("PASS: real window occlusion, full bracing pose, larger pivoting tail, both borders and scales, continuous withdrawal, move/minimize/close reaction, covered-face return and retained edge anchor; GIFs exported")
    }
    private static func checkWithdrawal(_ controller:WindowPeekController,folder:URL) throws -> [String:Any] {
        let now = ProcessInfo.processInfo.systemUptime
        let base = now-controller.elapsed, begin = controller.duration-WindowPeekArtwork.withdrawalDuration
        let view = controller.peekView
        func pixels() -> Data {
            let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:rep)
            return rep.representation(using:.png,properties:[:])!
        }
        controller.tick(at:base+begin-0.0001)
        precondition(controller.phase == .peeking)
        let before = pixels(), frozenFrame = view.peekFrame
        controller.tick(at:base+begin+0.0001)
        precondition(controller.phase == .withdrawing)
        precondition(view.peekFrame == frozenFrame && pixels() == before,"Withdrawal begins on the exact last peeking pixels")
        var frames=Set<Int>(),articulatedPixels=Set<Data>()
        for progress in stride(from:0.0,to:0.96,by:0.02) {
            controller.tick(at:base+begin+WindowPeekArtwork.withdrawalDuration*progress)
            precondition(view.peekFrame == frozenFrame,"Withdrawal keeps its canonical entry pose while articulated artwork plays")
            frames.insert(WindowPeekArtwork.withdrawalFrame(at:progress))
            articulatedPixels.insert(pixels())
        }
        precondition(frames == Set(0..<8) && articulatedPixels.count>8,"All eight changing shoulder/arm poses play through withdrawal")
        func visibleTop(at progress:Double)->Int {
            controller.tick(at:base+begin+WindowPeekArtwork.withdrawalDuration*progress)
            let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:rep)
            for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {
                if rep.colorAt(x:x,y:y)!.alphaComponent>0.8 {return y}
            }}
            preconditionFailure("Release must still show the character")
        }
        let releaseJump=abs(visibleTop(at:0.54-0.00001)-visibleTop(at:0.54+0.00001))
        precondition(releaseJump<=2,"Releasing the hand must not jump vertically: \(releaseJump) pixels")
        controller.tick(at:base+controller.duration-0.0001)
        precondition(controller.phase == .withdrawing)
        let last = pixels()
        controller.tick(at:base+controller.duration+0.001)
        precondition(pixels() == last,"Last withdrawal pixels and parked pixels are identical")
        view.needsDisplay = false; controller.bodyView.needsDisplay = false
        controller.tick(at:base+controller.duration+0.12)
        precondition(!view.needsDisplay && pixels() == last,
            "Only the tail layer animates; no peek sprite refresh after concealment")
        var tailCounts:[Int]=[]
        for time in [0.0,0.19,0.3,0.5,0.7,0.9,1.1] {
            controller.tick(at:base+controller.duration+time)
            controller.bodyView.tailAngle=0
            let body=controller.bodyView,rep=body.bitmapImageRepForCachingDisplay(in:body.bounds)!
            body.cacheDisplay(in:body.bounds,to:rep)
            var count=0
            for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {
                let px=(CGFloat(x)+0.5)/CGFloat(rep.pixelsWide)*448
                let canonical=body.mirrored ? 448-px : px
                if canonical < WindowHideArtwork.wallX && rep.colorAt(x:x,y:y)!.alphaComponent>0.5 {count+=1}
            }}
            tailCounts.append(count)
        }
        precondition(tailCounts.prefix(3).allSatisfy {$0==0},"Character fully conceals before tail emerges")
        precondition(tailCounts.dropFirst(3).contains {$0>20},"Tail swings into view along its overhead arc")
        precondition(tailCounts.last!>20,"Tail eventually emerges at full size")
        if view.layoutScale == 1 {
            let side = controller.target!.side.rawValue
            let area = controller.peek.frame.insetBy(dx:-50,dy:-15)
            // Replay the view in its actual front panel for the scene export;
            // the endpoint check above already ordered this panel out.
            controller.peek.order(.above,relativeTo:Int(controller.target!.id))
            let count = 115
            let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("withdraw-\(side).gif") as CFURL,
                UTType.gif.identifier as CFString,count,nil)!
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            for index in 0..<count {
                let time = -0.3+Double(index)/50
                view.peekFrame = frozenFrame
                view.concealment = time < 0 ? nil : min(1,time/WindowPeekArtwork.withdrawalDuration)
                view.needsDisplay = true
                CGImageDestinationAddImage(gif,controller.renderFixtureScene(in:area)!,
                    [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.02]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(gif))
            controller.peek.orderOut(nil)
            view.needsDisplay = false
            let revealGIF=CGImageDestinationCreateWithURL(folder.appendingPathComponent("tail-reveal-\(side).gif") as CFURL,
                UTType.gif.identifier as CFString,65,nil)!
            CGImageDestinationSetProperties(revealGIF,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            let revealArea=controller.body.frame.insetBy(dx:-35,dy:-12)
            for index in 0..<65 {
                controller.tick(at:base+controller.duration+Double(index)/40)
                CGImageDestinationAddImage(revealGIF,controller.renderFixtureScene(in:revealArea)!,
                    [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.025]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(revealGIF))
            let tailGIF = CGImageDestinationCreateWithURL(folder.appendingPathComponent("parked-tail-\(side).gif") as CFURL,
                UTType.gif.identifier as CFString,90,nil)!
            CGImageDestinationSetProperties(tailGIF,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            let closeup = controller.body.frame.insetBy(dx:-35,dy:-12)
            for index in 0..<90 {
                controller.bodyView.tailAngle = WindowHideArtwork.tailAngle(at:Double(index)/25)
                controller.bodyView.needsDisplay = true
                CGImageDestinationAddImage(tailGIF,controller.renderFixtureScene(in:closeup)!,
                    [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(tailGIF))
        }
        return ["side":controller.target!.side.rawValue,"scale":view.layoutScale,"frozenFrame":frozenFrame!,
            "entryExact":true,"articulatedFrames":8,"releaseTopJumpPixels":releaseJump,
            "tailRevealPixelCounts":tailCounts,
            "parkedEndpointExact":true,"noPeekRefresh":true]
    }
    private static func checkConcealedArtwork(_ view:WindowPeekSpriteView,folder:URL) throws {
        precondition(view.braceAmount == 1 && WindowHideArtwork.shared.available)
        let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:rep)
        let unit = view.bounds.width/448
        var tailArea = 0.0, face = 0, palms = 0, feet = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard (rep.colorAt(x:x,y:y)?.alphaComponent ?? 0) > 0.5 else { continue }
            let px = (CGFloat(x)+0.5)*view.bounds.width/CGFloat(rep.pixelsWide)/unit
            let nx = view.mirrored ? 448-px : px
            let ny = (view.bounds.height-(CGFloat(y)+0.5)*view.bounds.height/CGFloat(rep.pixelsHigh)-8*view.layoutScale)/unit
            if nx < WindowHideArtwork.wallX && (90...265).contains(ny) {
                tailArea += Double(view.bounds.width*view.bounds.height/CGFloat(rep.pixelsWide*rep.pixelsHigh))
            }
            if nx > 270 && (380...500).contains(ny) { face += 1 }
            if (125...175).contains(nx) && (290...445).contains(ny) { palms += 1 }
            if nx > 200 && ny < 75 { feet += 1 }
        } }
        // The previous cropped tip occupied at most 56×80 source pixels.
        precondition(tailArea > Double(56*80*unit*unit)*1.4,"Exposed tail area is materially larger than the former tip")
        precondition(face > 10 && palms > 5 && feet > 5,"Complete head, both bracing palms and feet remain loaded behind the wall")
        let old = rep.representation(using:.png,properties:[:])!
        view.tailAngle += 0.05; view.needsDisplay = true
        view.cacheDisplay(in:view.bounds,to:rep)
        precondition(old != rep.representation(using:.png,properties:[:])!,"Tail visibly changes with its small pivot swing")
        view.tailAngle -= 0.05
        if view.layoutScale == 1 { try old.write(to:folder.appendingPathComponent("complete-bracing-sprite.png")) }
    }
    private static func checkRenderedBodySize(folder:URL) throws {
        var checks:[[String:Any]]=[]
        for scale in [0.5,1.0,2.0] {for mirrored in [false,true] {
            let view=WindowPeekSpriteView(frame:NSRect(x:0,y:0,width:147*scale,
                height:(226+WindowPeekArtwork.lowerBodyExtension*147/448)*scale))
            view.layoutScale=scale;view.mirrored=mirrored
            func height() -> Int {
                let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                view.cacheDisplay(in:view.bounds,to:rep)
                var top=rep.pixelsHigh,bottom=0
                for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide where rep.colorAt(x:x,y:y)!.alphaComponent>0.8 {
                    top=min(top,y);bottom=max(bottom,y)
                }}
                precondition(top<bottom,"Complete character must remain visible")
                return bottom-top+1
            }
            view.entryFrame=WindowHideArtwork.finalEntryFrame;view.tailReveal=0
            let standing=height()
            view.entryFrame=nil;view.peekFrame=2
            let peeking=height()
            view.concealment=0
            let withdrawing=height()
            precondition(abs(Double(peeking)/Double(standing)-1)<0.04,
                "Full-body peek must match standing size: \(peeking) versus \(standing)")
            precondition(withdrawing==peeking,"Withdrawal must begin at the same character size")
            checks.append(["scale":scale,"mirrored":mirrored,"standingHeight":standing,
                "peekingHeight":peeking,"withdrawalHeight":withdrawing])
        }}
        try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks],options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("body-size-validation.json"))
    }
    private static func checkMotionAssets(folder:URL) throws {
        let art=DeepSeekStroll.shared,hide=WindowHideArtwork.shared
        for image in WindowPeekArtwork.shared.frames+WindowPeekArtwork.shared.withdrawFrames {
            let rep=NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            precondition(rep.pixelsWide==448 && rep.pixelsHigh==832,"Full-body peek canvas includes lower legs")
        }
        precondition(art.launchFrames.count == 4 && hide.entryFrames.count == 12 && hide.coverFrames.count == 8 && hide.coverPrepFrames.count == 4)
        let prefix=StrollTimeline.steps.prefix { $0.phase != .walking }
        precondition(prefix.compactMap(\.launchFrame) == [0,1,2],"Running preparation includes knee bend, weight transfer and push-off")
        let launchEnd=prefix.reduce(0) { $0+$1.duration }
        let view=WindowPeekSpriteView(frame:NSRect(x:0,y:0,width:147,height:226))
        func pixels()->Data {let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:rep);return rep.representation(using:.png,properties:[:])!}
        for mirrored in [false,true] {
            view.mirrored=mirrored
            view.stroll=StrollTimeline.sample(at:launchEnd-0.001)!
            let before=pixels();view.stroll=StrollTimeline.sample(at:launchEnd)!
            precondition(pixels() == before,"Launch hands, face and contact foot agree exactly with first jog pose")
            view.entryFrame=WindowHideArtwork.finalEntryFrame;view.tailAngle=0.035
            let finalStep=pixels();view.entryFrame=nil;view.braceAmount=1
            precondition(pixels() == finalStep,"Last side-step agrees exactly with final edge grip including swinging tail")
            view.braceAmount=nil
            view.coverPrepFrame=3
            let handsUp=pixels();view.coverPrepFrame=nil;view.coverFrame=0
            precondition(pixels()==handsUp,"Last hands-up pose must meet the first covered jog contact in both directions")
            view.coverFrame=nil
        }
        for image in hide.coverFrames {
            let rep=NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            precondition(rep.pixelsWide==448 && rep.pixelsHigh==640,"Covered return uses eight complete 448x640 sprites")
        }
        try JSONSerialization.data(withJSONObject:["passed":true,"launchContactExactBothDirections":true,
            "entryGripExactBothDirections":true,"coverContactExactBothDirections":true,"coverFrames":8],options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("motion-assets-validation.json"))
    }
    private static func checkRecovery(folder:URL) throws {
        let screen = NSScreen.screens.first!.visibleFrame
        var evidence:[[String:Any]] = []
        for (side,action) in [(DesktopWindowTarget.Side.left,"move"),(.right,"close"),(.left,"minimize")] {
            let controller = WindowPeekController()
            let original = NSRect(x:screen.midX+(side == .left ? -400 : 350),y:screen.midY-130,width:147,height:226)
            precondition(controller.start(from:original,scale:1,forceFixture:true,speed:150,hold:2))
            let ready = Date().addingTimeInterval(1)
            while DesktopWindowTarget.resolve(controller.target!.id,side:side) == nil && Date() < ready {
                RunLoop.main.run(until:Date().addingTimeInterval(0.02))
            }
            precondition(DesktopWindowTarget.resolve(controller.target!.id,side:side) != nil,"Fixture must be visible in WindowServer before advancing its clock")
            let base = ProcessInfo.processInfo.systemUptime
            controller.tick(at:base+controller.duration+0.1)
            precondition(controller.isRunning && controller.fixture != nil,"Parking fixture failed: \(controller.status)")
            let stationary = controller.body.frame
            let window = controller.fixture!
            let beforeLoss = controller.renderFixtureScene(in:screen)!
            if action == "move" { window.setFrameOrigin(NSPoint(x:screen.maxX+100,y:screen.midY)) }
            else if action == "close" { window.close() }
            else { window.miniaturize(nil) }
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
            let loss = base+controller.duration+0.3
            controller.tick(at:loss)
            precondition(controller.isRecovering && controller.phase == .startled)
            precondition(controller.body.frame == stationary && !controller.peek.isVisible,"Window loss reveals the full body at the same position")
            let endpoint = controller.recoveryDestination!, duration = controller.recoveryDuration
            let area = stationary.union(endpoint).insetBy(dx:-70,dy:-25).intersection(screen).integral
            var returned:NSRect?
            controller.onReturnToEdge = { returned = $0 }
            let count = Int(ceil(duration/0.05))
            let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("recovery-\(side.rawValue)-\(action).gif") as CFURL,
                UTType.gif.identifier as CFString,count+8,nil)!
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            let before = beforeLoss.cropping(to:CGRect(x:area.minX-screen.minX,y:screen.maxY-area.maxY,
                width:area.width,height:area.height))!
            for _ in 0..<8 {
                CGImageDestinationAddImage(gif,before,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.05]] as CFDictionary)
            }
            var phases:[String] = [], last = stationary.origin, headDirections = Set<Int>(), jogFrames = Set<Int>()
            for i in 0..<count {
                controller.tick(at:loss+Double(i)*0.05)
                if controller.isRunning {
                    if phases.last != controller.phase.rawValue { phases.append(controller.phase.rawValue) }
                    let origin = controller.body.frame.origin
                    precondition(hypot(origin.x-last.x,origin.y-last.y)<7,"No teleporting through reaction, return or sitting")
                    last = origin
                    if [.startled,.lookingLeft,.lookingRight].contains(controller.phase) {
                        precondition(origin == stationary.origin && controller.bodyView.braceAmount == 1)
                        headDirections.insert(Int(controller.bodyView.headTurn.rounded()))
                    }
                    if controller.phase == .returning {
                        precondition(controller.bodyView.whistleTime == nil && controller.bodyView.coverFrame != nil)
                        jogFrames.insert(controller.bodyView.coverFrame!)
                    }
                    if action == "move" && [0,18,30,70].contains(i) {
                        let rep = controller.bodyView.bitmapImageRepForCachingDisplay(in:controller.bodyView.bounds)!
                        controller.bodyView.cacheDisplay(in:controller.bodyView.bounds,to:rep)
                        try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("reaction-\(i).png"))
                    }
                }
                let image = controller.renderFixtureScene(in:area)!
                CGImageDestinationAddImage(gif,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.05]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(gif))
            controller.tick(at:loss+duration+0.001)
            precondition(phases == ["愣了一下","向左看看","向右看看","松手捂住脸","捂脸小跑回屏幕边缘","若无其事坐好"])
            precondition(headDirections == [0,1,2] && jogFrames == Set(0..<8))
            precondition(returned == endpoint && !controller.isRunning)
            precondition(endpoint.minX == screen.minX+8 || endpoint.maxX == screen.maxX-8,"Return reaches the nearest screen edge")
            evidence.append(["action":action,"side":side.rawValue,"phases":phases,"continuousPosition":true,
                "fullBodyRevealedInPlace":true,"headDirections":headDirections.sorted(),"coveredFaceJogFrames":jogFrames.sorted(),
                "bothHandsCoverFace":true,"endpoint":[endpoint.minX,endpoint.minY]])
        }
        try JSONSerialization.data(withJSONObject:["passed":true,"runs":evidence],options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("recovery-geometry-validation.json"))
    }
    private static func save(_ cg:CGImage,to url:URL) throws {
        let rep = NSBitmapImageRep(cgImage:cg)
        try rep.representation(using:.png,properties:[:])!.write(to:url)
    }
}

private extension DesktopWindowTarget.Side {
    static var all: [DesktopWindowTarget.Side] { [.left,.right] }
}
