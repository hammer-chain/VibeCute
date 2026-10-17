import AppKit
import ImageIO
import UniformTypeIdentifiers

enum WindowSeatSupportLossChecks {
    static func run() throws {
        let output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CAPTIONS_WINDOW_PEEK_OUTPUT"] ?? "output/deepseek-seat-support-loss")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let area=NSScreen.screens[0].visibleFrame
        var rows:[[String:Any]]=[]
        let cases:[(String,CGFloat,Double)]=[("close-half",0.5,0.5),("close",1,0.5),("close-double",2,0.5),
            ("minimize",1,1.4),("space",1,0.5),("hands-start",1,-WindowSeatArtwork.transitionDuration+0.001),
            ("hands-middle",1,-WindowSeatArtwork.transitionDuration*0.5),("loop-other-leg",1,1.6)]
        for (name,scale,offset) in cases {
            let window=NSWindow(contentRect:NSRect(x:area.midX-250,y:area.minY+170,width:500,height:280),styleMask:[.titled,.miniaturizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.orderFrontRegardless()
            RunLoop.main.run(until:Date().addingTimeInterval(0.08))
            let target=DesktopWindowTarget.resolve(UInt32(window.windowNumber),side:.left)!
            let original=NSRect(x:target.frame.midX-73.5*scale,y:target.frame.maxY+30,width:147*scale,height:226*scale)
            let controller=WindowPeekController()
            precondition(controller.start(from:original,scale:scale,requiredTarget:target,preferSeat:true))
            var returned:NSRect?,finishes=0
            controller.onReturnToEdge={returned=$0};controller.onFinish={_ in finishes+=1}
            let clock=ProcessInfo.processInfo.systemUptime+controller.duration+offset
            controller.tick(at:clock)
            let before=controller.body.frame,view=controller.body.contentView as! WindowSeatSpriteView
            let beforeImage=view.image,redraws=controller.diagnostics["seatRedraws"] as! Int
            if name=="space" {
                NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
                RunLoop.main.run(until:Date().addingTimeInterval(0.04))
                precondition(DesktopWindowTarget.resolveSeatSupport(target.id,side:target.side) != nil,"Space changes detach even an all-Spaces support that remains visible")
            } else if name=="minimize" {
                window.miniaturize(nil)
                RunLoop.main.run(until:Date().addingTimeInterval(0.7))
            } else {window.close();RunLoop.main.run(until:Date().addingTimeInterval(0.08))}
            let detach=clock+0.55
            controller.tick(at:detach)
            let first=controller.diagnostics
            precondition(controller.phase == .fallingFromWindow && first["seatFalling"] as! Bool,"\(name): \(first)")
            precondition(first["seatFallCause"] as! String == (name=="space" ? "spaceChanged" : "supportLost"))
            precondition(controller.body.frame==before && view.image === beforeImage && first["seatRedraws"] as! Int==redraws,"Detach must preserve the exact displayed pose and position, including hands and either swinging leg")
            let queries=first["seatWindowRefreshes"] as! Int
            let gif=name=="close" ? CGImageDestinationCreateWithURL(output.appendingPathComponent("support-loss-continuous.gif") as CFURL,UTType.gif.identifier as CFString,120,nil) : nil
            if let gif {CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)}
            var dropped=CGFloat.zero,stages=Set<String>()
            for i in 0..<240 {
                controller.tick(at:detach+Double(i)/60)
                if !controller.isRunning {break}
                let d=controller.diagnostics
                precondition(d["seatWindowRefreshes"] as! Int==queries,"Detached fall makes no further support queries")
                stages.insert(d["seatEntryStage"] as! String);dropped=max(dropped,before.minY-controller.body.frame.minY)
                if i%2==0,let gif {
                    let scene=NSRect(x:before.midX-210,y:area.minY,width:420,height:660)
                    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:420,pixelsHigh:660,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
                    NSColor.windowBackgroundColor.setFill();NSRect(origin:.zero,size:scene.size).fill()
                    NSGraphicsContext.current!.cgContext.translateBy(x:-scene.minX,y:-scene.minY)
                    NSColor.separatorColor.setFill();NSRect(x:scene.minX,y:area.minY,width:scene.width,height:2).fill()
                    let sprite=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                    view.cacheDisplay(in:view.bounds,to:sprite)
                    NSImage(cgImage:sprite.cgImage!,size:view.bounds.size).draw(in:controller.body.frame)
                    NSGraphicsContext.restoreGraphicsState()
                    CGImageDestinationAddImage(gif,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
                    if [0,6,12,24,42,60,84].contains(i) {try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("loss-\(i).png"))}
                }
            }
            if let gif {precondition(CGImageDestinationFinalize(gif))}
            precondition(!controller.isRunning && finishes==1 && returned != nil && dropped>150)
            precondition(stages==["失去平衡下落","落地收手坐稳"])
            precondition(returned!.minY>=area.minY-1 && returned!.minY<area.minY+90*scale,"Support loss hands back at the new floor position")
            precondition(abs(returned!.minY-original.minY)>150)
            rows.append(["case":name,"scale":scale,"detachPoseUnchanged":true,"dropPoints":dropped,"returnY":returned!.minY,"queriesAfterDetaching":0])
            window.close()
        }
        // A Space event during an explicit return must not restart a fall; an
        // event before seat contact uses the existing reversible entry motion.
        for leaving in [false,true] {
            let window=NSWindow(contentRect:NSRect(x:area.midX-250,y:area.minY+170,width:500,height:280),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.orderFrontRegardless()
            RunLoop.main.run(until:Date().addingTimeInterval(0.08))
            let target=DesktopWindowTarget.resolve(UInt32(window.windowNumber),side:.left)!
            let controller=WindowPeekController()
            precondition(controller.start(from:NSRect(x:target.frame.midX-73.5,y:target.frame.maxY+30,width:147,height:226),scale:1,requiredTarget:target,preferSeat:true))
            let clock=ProcessInfo.processInfo.systemUptime+0.2
            controller.tick(at:clock)
            if leaving {controller.stop(reason:"manual")}
            NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
            RunLoop.main.run(until:Date().addingTimeInterval(0.04))
            controller.tick(at:clock+0.01)
            precondition(!controller.isRunning || (controller.phase == .leavingWindow && !(controller.diagnostics["seatFalling"] as! Bool)))
            controller.stop(reason:"",immediate:true);window.close()
        }
        try JSONSerialization.data(withJSONObject:["passed":true,"runs":rows,"entryAndManualReturnPreserved":true],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("support-loss-validation.json"))
        print("PASS: closed, minimized and Space-changed supports fall continuously from current hands/legs at 50/100/200 percent, stop queries and land at the new floor")
    }
}
