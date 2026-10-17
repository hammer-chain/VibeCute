import AppKit
import ImageIO
import UniformTypeIdentifiers

enum WindowSeatChecks {
    static func run() throws {
        let output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CAPTIONS_WINDOW_PEEK_OUTPUT"] ?? "output/deepseek-window-seat")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let art=WindowSeatArtwork.shared
        precondition(art.available)
        var rows:[[String:Any]]=[]
        let inertiaChecks=checkInertia()
        let pressureChecks=checkPressure()
        func png(_ image:NSImage)->Data {NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!).representation(using:.png,properties:[:])!}
        precondition(png(art.transitions.last!)==png(art.frames[0]),"Sit/loop handoff uses identical pixels")
        precondition(png(art.balance[0])==png(art.frames[0]),"Balance/loop handoff uses identical pixels")
        precondition(png(art.frames[12])==png(art.frames[0]),"Both neutral loop endpoints are identical")
        // Reviewed palm regions, excluding cuffs, thighs and gold skirt bows.
        // Reject a missing intermediate even when endpoint checks pass.
        let palmCenters:[[NSPoint]]=[
            [.init(x:194,y:380),.init(x:215,y:380)], [.init(x:196,y:384),.init(x:218,y:384)],
            [.init(x:196,y:395),.init(x:230,y:395)], [.init(x:182,y:391),.init(x:246,y:391)],
            [.init(x:160,y:400),.init(x:269,y:400)], [.init(x:132,y:404),.init(x:297,y:404)],
            [.init(x:110,y:404),.init(x:319,y:404)],
            [.init(x:109,y:421),.init(x:326,y:421)], [.init(x:95,y:424),.init(x:331,y:425)]
        ]
        var palms:[[NSPoint]]=[]
        for (i,image) in art.transitions.enumerated() {
            let rep=NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            palms.append(palmCenters[i].map {center in
                var xSum=0.0,ySum=0.0,n=0.0
                for y in Int(center.y)-15...Int(center.y)+15 {for x in Int(center.x)-15...Int(center.x)+15 {
                    let c=rep.colorAt(x:x,y:y)!,r=c.redComponent,g=c.greenComponent,b=c.blueComponent
                    if c.alphaComponent>0.8 && r>0.7 && g>0.4 && g<r*0.96 && b<g*1.02 {n+=1;xSum+=Double(x);ySum+=Double(y)}
                }}
                precondition(n>100,"Missing intermediate palm in frame \(i)")
                return NSPoint(x:xSum/n,y:ySum/n)
            })
        }
        var maxPalmStep=0.0
        for i in 1..<palms.count {
            for side in 0..<2 {maxPalmStep=max(maxPalmStep,hypot(palms[i][side].x-palms[i-1][side].x,palms[i][side].y-palms[i-1][side].y))}
            precondition(palms[i][1].x-palms[i][0].x >= palms[i-1][1].x-palms[i-1][0].x-3,"Hands unfold progressively")
        }
        precondition(maxPalmStep<45,"Hands must not jump straight from lap to sides")
        var balancePalms:[[NSPoint]]=[],balanceShoes:[[NSPoint]]=[]
        let palmY=[424,410,403,395,382,382,353,346,343,342]
        for (i,image) in art.balance.enumerated() {
            let rep=NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            func centroid(_ side:Int,_ shoe:Bool)->NSPoint {
                var n=0.0,sx=0.0,sy=0.0
                let rangeX=shoe ? (side==0 ? 0..<214 : 214..<448) : (side==0 ? 0..<150 : 282..<448)
                let rangeY=shoe ? 440..<620 : max(280,palmY[i]-25)..<min(449,palmY[i]+25)
                var shoePixels=Set<Int>()
                for y in rangeY {for x in rangeX {
                    let c=rep.colorAt(x:x,y:y)!,r=c.redComponent,g=c.greenComponent,b=c.blueComponent
                    let included=shoe ? r>0.75 && g>0.75 && b>0.7 : r>0.7 && g>0.4 && g<r*0.96 && b<g*1.02
                    if c.alphaComponent>0.8 && included {
                        if shoe {shoePixels.insert(y*448+x)}
                        else {n+=1;sx+=Double(x);sy+=Double(y)}
                    }
                }}
                if shoe {
                    // Use the white instep oval shared by every Mary Jane shoe.
                    // Navy tail tips can overlap a dark shoe color component.
                    var selected:[Int]=[]
                    while let seed=shoePixels.first {
                        shoePixels.remove(seed);var component=[seed],cursor=0
                        while cursor<component.count {
                            let p=component[cursor];cursor+=1
                            for dy in -1...1 {for dx in -1...1 {
                                let x=p%448+dx,y=p/448+dy
                                guard rangeX.contains(x),rangeY.contains(y) else {continue}
                                let next=y*448+x
                                if shoePixels.remove(next) != nil {component.append(next)}
                            }}
                        }
                        func centerY(_ points:[Int])->Double {
                            points.isEmpty ? 0 : Double(points.reduce(0){$0+$1/448})/Double(points.count)
                        }
                        if component.count>40 && centerY(component)>centerY(selected) {selected=component}
                    }
                    n=Double(selected.count)
                    sx=selected.reduce(0){$0+Double($1%448)};sy=selected.reduce(0){$0+Double($1/448)}
                }
                precondition(n>100,"Complete \(shoe ? "shoe" : "palm") in balance \(i), side \(side)")
                return NSPoint(x:sx/n,y:sy/n)
            }
            let hands=[centroid(0,false),centroid(1,false)]
            balancePalms.append(hands);balanceShoes.append([centroid(0,true),centroid(1,true)])
        }
        var balanceMaxPalmStep=0.0,balanceMaxShoeStep=0.0
        for i in 1..<art.balance.count {
            for side in 0..<2 {
                balanceMaxPalmStep=max(balanceMaxPalmStep,hypot(balancePalms[i][side].x-balancePalms[i-1][side].x,balancePalms[i][side].y-balancePalms[i-1][side].y))
                balanceMaxShoeStep=max(balanceMaxShoeStep,hypot(balanceShoes[i][side].x-balanceShoes[i-1][side].x,balanceShoes[i][side].y-balanceShoes[i-1][side].y))
            }
        }
        precondition(balanceMaxPalmStep<45 && balanceMaxShoeStep<32,"Balance limbs unfold continuously: \(balanceMaxPalmStep), \(balanceMaxShoeStep)")
        precondition(balancePalms.last![1].x-balancePalms.last![0].x>330,"Both arms spread to brace")
        for feet in balanceShoes {
            precondition(feet[1].x-feet[0].x<70 && abs(feet[1].y-feet[0].y)<6,"Feet lift together, staying side by side")
        }
        precondition(balanceShoes[0][0].y-balanceShoes.last![0].y>40 && balanceShoes[0][1].y-balanceShoes.last![1].y>40,"Both closed legs lift upward")
        for i in 1..<balanceShoes.count {
            precondition(balanceShoes[i][0].y-balanceShoes[i-1][0].y<6 && balanceShoes[i][1].y-balanceShoes[i-1][1].y<6,"Both legs lift continuously without dropping between poses")
        }
        // Exercise the production renderer: padding preserves source scale,
        // the upper body rotates intact, and the joined feet stay unrotated.
        let rig=WindowSeatSpriteView(frame:NSRect(x:0,y:0,width:608,height:640))
        rig.image=art.balance.last!
        func renderLean(_ angle:Double,_ focus:Double?=nil)->NSBitmapImageRep {
            let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:608,pixelsHigh:640,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            rig.upperLeanDegrees=angle;rig.focusAmount=focus;rig.draw(rig.bounds)
            NSGraphicsContext.restoreGraphicsState();return rep
        }
        rig.blinkAmount=0
        let loopGIF=CGImageDestinationCreateWithURL(output.appendingPathComponent("continuous-leg-loop.gif") as CFURL,UTType.gif.identifier as CFString,24,nil)!
        CGImageDestinationSetProperties(loopGIF,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for image in art.frames {
            rig.image=image
            let rep=renderLean(0,0)
            CGImageDestinationAddImage(loopGIF,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:WindowSeatArtwork.loopFrameDuration]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(loopGIF))
        rig.image=art.balance.last!
        let upright=renderLean(0)
        var expressionChangedPixels=0
        for focus in [0.0,1.0/3,2.0/3,1.0] {
            let rep=renderLean(0,focus)
            try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("expression-\(focus).png"))
            for y in 0..<640 {for x in 0..<608 {
                var a=[Int](repeating:0,count:4),b=a
                upright.getPixel(&a,atX:x,y:y);rep.getPixel(&b,atX:x,y:y)
                if focus==1 && zip(a,b).contains(where:{abs($0-$1)>8}) {expressionChangedPixels+=1}
            }}
        }
        precondition(expressionChangedPixels>100,"Focused expression must visibly differ from the relaxed expression")
        for angle in [-15.0,-12.0,-5.0,5.0,12.0,15.0] {
            let rep=renderLean(angle)
            try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("lean-\(Int(angle)).png"))
            for y in 480..<610 {for x in 234..<355 {
                // Compare actual opaque shoe/cuff pixels; transparent pixels
                // may legitimately reveal the hair/tail rotating behind them.
                var a=[Int](repeating:0,count:4),b=a
                upright.getPixel(&a,atX:x,y:y);rep.getPixel(&b,atX:x,y:y)
                if a[3]==255 {precondition(zip(a,b).allSatisfy{abs($0-$1)<=2},"Upper-body lean must not move or distort raised feet: \(angle), \(x), \(y)")}
            }}
            for y in 0..<640 {
                precondition(rep.colorAt(x:0,y:y)!.alphaComponent<0.8 && rep.colorAt(x:607,y:y)!.alphaComponent<0.8,"Lean margins keep complete arms and hair visible")
            }
        }
        let contact=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:608,pixelsHigh:700,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for (i,angle) in [0.0,3,8,14].enumerated() {
            rig.image=i==0 ? art.frames[0] : art.balance[Int((min(1,WindowSeatPressure.load(for:angle)/1.1)*9).rounded())]
            rig.gazeOffset=angle/15*6
            let rendered=renderLean(angle,WindowSeatPressure.load(for:angle)/3)
            try rendered.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("pressure-stage-\(i).png"))
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:contact)
            let x=CGFloat(i%2)*304,y=CGFloat(1-i/2)*350
            NSImage(cgImage:rendered.cgImage!,size:rig.bounds.size).draw(in:NSRect(x:x,y:y,width:304,height:320))
            (["放松 · 0°","留意平衡 · 3°","凝神用力 · 8°","临界慌张 · 14°"][i] as NSString).draw(at:NSPoint(x:x+80,y:y+326),withAttributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.labelColor])
            NSGraphicsContext.restoreGraphicsState()
        }
        try contact.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("pressure-stages.png"))
        rig.gazeOffset=0
        // Preview the curious idle sequence with the exact production rig,
        // including the unchanged leg loop and pressure clock's blink timing.
        let idleGIF=CGImageDestinationCreateWithURL(output.appendingPathComponent("continuous-idle-expression.gif") as CFURL,UTType.gif.identifier as CFString,120,nil)!
        CGImageDestinationSetProperties(idleGIF,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        var idleClock=WindowSeatPressure(),previousIdle=WindowSeatIdleExpression(),maxIdleStep=0.0
        var minIdleX=0.0,maxIdleX=0.0,maxIdleY=0.0,maxSmile=0.0,maxSmileStep=0.0
        rig.image=art.frames[0];rig.gazeOffset=0;rig.gazeOffsetY=0;rig.blinkAmount=0
        for i in 0..<120 {
            let t=Double(i)*WindowSeatArtwork.loopFrameDuration,idle=WindowSeatIdleExpression.sample(at:t)
            for _ in 0..<12 {idleClock.step(angle:0,acceleration:0,delta:0.01)}
            minIdleX=min(minIdleX,idle.x);maxIdleX=max(maxIdleX,idle.x);maxIdleY=max(maxIdleY,idle.y)
            maxIdleStep=max(maxIdleStep,hypot(idle.x-previousIdle.x,idle.y-previousIdle.y));previousIdle=idle
            rig.image=art.frames[i%24];rig.gazeOffset=(idle.x*4).rounded()/4;rig.gazeOffsetY=(idle.y*4).rounded()/4
            rig.blinkAmount=(idleClock.blink*16).rounded()/16
            let smile=(idle.smile*16).rounded()/16
            maxSmile=max(maxSmile,smile);maxSmileStep=max(maxSmileStep,abs(smile-rig.smileAmount));rig.smileAmount=smile
            let rendered=renderLean(0,0)
            if i==103 {try rendered.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("happy-smile.png"))}
            let preview=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:644,pixelsHigh:320,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:preview)
            NSColor(calibratedWhite:0.18,alpha:1).setFill();NSRect(x:0,y:0,width:644,height:320).fill()
            NSImage(cgImage:rendered.cgImage!,size:rig.bounds.size).draw(in:NSRect(x:0,y:0,width:304,height:320))
            let face=rendered.cgImage!.cropping(to:CGRect(x:212,y:175,width:170,height:110))!
            NSImage(cgImage:face,size:NSSize(width:170,height:110)).draw(in:NSRect(x:304,y:50,width:340,height:220))
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(idleGIF,preview.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:WindowSeatArtwork.loopFrameDuration]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(idleGIF))
        precondition(minIdleX == -4 && maxIdleX == 4 && maxIdleY == 2 && maxIdleStep<1.2,"Curious idle eyes glance both ways smoothly, without head deformation")
        precondition(maxSmile==1 && maxSmileStep<=0.25,"The happy smile eases in and out, keeping one mouth contour")
        try JSONSerialization.data(withJSONObject:["duration":14.4,"minX":minIdleX,"maxX":maxIdleX,"maxY":maxIdleY,"maxStep":maxIdleStep,"maxSmile":maxSmile,"maxSmileStep":maxSmileStep,"sameLegFrameClock":true],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("idle-expression-validation.json"))
        rig.gazeOffset=0;rig.gazeOffsetY=0;rig.blinkAmount=0;rig.smileAmount=0
        let handoff=CGImageDestinationCreateWithURL(output.appendingPathComponent("continuous-handoff.gif") as CFURL,UTType.gif.identifier as CFString,art.transitions.count+13,nil)!
        CGImageDestinationSetProperties(handoff,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for (i,image) in (art.transitions+Array(art.frames.prefix(13))).enumerated() {
            rig.image=image
            let rendered=renderLean(0,i<8 ? nil : 0)
            CGImageDestinationAddImage(handoff,rendered.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:i==0 ? 0.7 : i<9 ? WindowSeatArtwork.transitionDuration/9 : WindowSeatArtwork.loopFrameDuration]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(handoff))
        if CommandLine.arguments.contains("--seat-render-only") {print("PASS: seat artwork and pressure states");return}
        let area=NSScreen.screens.first!.visibleFrame
        let window=NSWindow(contentRect:NSRect(x:area.midX-260,y:area.minY+40,width:520,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.orderFrontRegardless()
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        // Leaving while happy should close the mouth gradually, including
        // the wait for the legs to reach their neutral folding posture.
        do {
            let target=DesktopWindowTarget.resolve(UInt32(window.windowNumber),side:.left)!
            let panel=NSPanel(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false
            let original=NSRect(x:window.frame.midX-73.5,y:window.frame.maxY+30,width:147,height:226)
            let motion=WindowSeatMotion(panel:panel,original:original,scale:1,target:target)
            let time=motion.startedAt+motion.duration+12.3
            _=motion.tick(at:time)
            precondition(motion.view.smileAmount==1)
            motion.leave(at:time,reason:"happy leave check")
            _=motion.tick(at:time+0.12)
            precondition(motion.view.smileAmount>0 && motion.view.smileAmount<1,"Departure eases a happy mouth toward the neutral pose")
            _=motion.tick(at:time+0.25)
            precondition(motion.view.smileAmount==0)
            panel.orderOut(nil)
        }
        // Cancelling during a relaxed blink must finish opening the eyes,
        // preserving the new relaxed face throughout the loop-to-fold handoff.
        do {
            let target=DesktopWindowTarget.resolve(UInt32(window.windowNumber),side:.left)!
            let panel=NSPanel(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false
            let original=NSRect(x:window.frame.midX-73.5,y:window.frame.maxY+30,width:147,height:226)
            let motion=WindowSeatMotion(panel:panel,original:original,scale:1,target:target)
            let clock=motion.startedAt+motion.duration
            _=motion.tick(at:clock)
            var checked=false
            for i in 1...300 {
                let now=clock+Double(i)/60
                _=motion.tick(at:now)
                if motion.view.blinkAmount>0.85 {
                    let before=motion.view.blinkAmount
                    motion.leave(at:now,reason:"blink cancellation check")
                    _=motion.tick(at:now+0.03)
                    precondition(motion.view.blinkAmount>0 && motion.view.blinkAmount<before)
                    precondition(motion.view.focusAmount==0,"Departure retains the relaxed expression until its authored fold fade")
                    _=motion.tick(at:now+0.13)
                    precondition(motion.view.blinkAmount==0)
                    checked=true;break
                }
            }
            precondition(checked,"Exercise cancellation inside a blink")
            panel.orderOut(nil);panel.close()
        }
        var balanceResponse:[[String:Any]]=[]
        for scale in [0.5,1.0,2.0] {
            let original=NSRect(x:window.frame.midX-73.5*scale,y:window.frame.maxY+30*scale,width:147*scale,height:226*scale)
            let target=DesktopWindowTarget.resolve(UInt32(window.windowNumber),side:.left)!
            precondition(WindowSeatGeometry.fits(character:original,window:target.frame,scale:scale,area:area))
            if scale == 1 {
                let sideFallback=WindowPeekController()
                precondition(sideFallback.start(from:original,scale:scale,requiredTarget:target))
                precondition(sideFallback.route == .walking,"An above-window side fallback must not bypass top-visibility selection")
                sideFallback.stop(immediate:true)
            }
            let controller=WindowPeekController()
            precondition(controller.start(from:original,scale:scale,requiredTarget:target,preferSeat:true))
            precondition(controller.route == .seating)
            let start=ProcessInfo.processInfo.systemUptime
            let cadence=0.08,count=Int((controller.duration+2.88)/cadence)+1
            var entryStages=Set<String>(),jogPositions:[CGFloat]=[],firstSitContact:CGFloat?
            let gif=scale==1 ? CGImageDestinationCreateWithURL(output.appendingPathComponent("continuous-seat.gif") as CFURL,UTType.gif.identifier as CFString,count,nil) : nil
            if let gif {CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)}
            for i in 0..<count {
                controller.tick(at:start+Double(i)*cadence)
                let d=controller.diagnostics
                entryStages.insert(d["seatEntryStage"] as! String)
                if d["seatEntryStage"] as? String == "小跑到窗沿" {jogPositions.append(controller.body.frame.minX)}
                if d["seatEntryStage"] as? String == "收步坐下",firstSitContact == nil {
                    firstSitContact=controller.body.frame.minY+20*controller.body.frame.height/640
                }
                if let gif {
                    let scene=NSRect(x:original.midX-160,y:window.frame.maxY-90,width:320,height:355)
                    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:320,pixelsHigh:355,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
                    NSColor.windowBackgroundColor.setFill();NSRect(origin:.zero,size:scene.size).fill()
                    NSGraphicsContext.current!.cgContext.translateBy(x:-scene.minX,y:-scene.minY)
                    NSColor.separatorColor.setFill();window.frame.fill()
                    let view=controller.body.contentView!,sprite=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                    view.cacheDisplay(in:view.bounds,to:sprite)
                    NSImage(cgImage:sprite.cgImage!,size:view.bounds.size).draw(in:controller.body.frame)
                    NSGraphicsContext.restoreGraphicsState()
                    CGImageDestinationAddImage(gif,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:cadence]] as CFDictionary)
                    if i==count-1 {try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("seated.png"))}
                }
            }
            if let gif {precondition(CGImageDestinationFinalize(gif))}
            precondition(entryStages.isSuperset(of:["起身转向","小跑到窗沿","收步坐下","放下双手伸腿"]))
            precondition((jogPositions.max()!-jogPositions.min()!)>40*scale,"Jog has real travel before sitting")
            precondition(abs(firstSitContact!-window.frame.maxY)<1,"Jog contact pose lands on the window top before sitting")
            precondition(controller.phase == .seatedOnWindow)
            let frame=controller.body.frame,unit=frame.height/640
            precondition(abs(frame.minY+205*unit-window.frame.maxY)<1.1,"Support stays on real top edge")
            precondition(abs((controller.body.contentView as! WindowSeatSpriteView).artworkRect.width-147*scale)<0.01,"Transparent lean margins never enlarge the character")
            let d=controller.diagnostics
            let redraws=d["seatRedraws"] as! Int, refresh=d["seatWindowRefreshes"] as! Int
            let perfStart=ProcessInfo.processInfo.systemUptime
            for i in 0..<1200 {controller.tick(at:start+controller.duration+3+Double(i)/120)}
            let tickTime=ProcessInfo.processInfo.systemUptime-perfStart
            let after=controller.diagnostics
            precondition(controller.body.frame==frame,"Fixed anchor must not slide while feet swing")
            precondition((after["seatRedraws"] as! Int)-redraws <= 175,"Loop plus three brief blinks stays below 17.5 redraws/s, without repainting every 120 Hz tick")
            precondition((after["seatWindowRefreshes"] as! Int)-refresh <= 201,"Quiet follow queries only the selected window, bounded to 20 Hz")
            rows.append(["scale":scale,"fixedAnchor":true,"ticks":1200,"tickSeconds":tickTime,
                         "loopRedraws":(after["seatRedraws"] as! Int)-redraws,"windowRefreshes":(after["seatWindowRefreshes"] as! Int)-refresh])
            // Follow horizontal/vertical movement and direction reversals at
            // every scale; hold the same support offset and fixed core size.
            let testTime=start+controller.duration+14
            let offset=controller.body.frame.origin
            var balanceFrames=Set<Int>()
            var positiveLean=false,negativeLean=false,maxLeanStep=0.0,previousLean=0.0,previousFocus=0.0,maxFocus=0.0,maxFocusStep=0.0
            let balanceGIF=scale==1 ? CGImageDestinationCreateWithURL(output.appendingPathComponent("continuous-balance.gif") as CFURL,UTType.gif.identifier as CFString,245,nil) : nil
            if let balanceGIF {CGImageDestinationSetProperties(balanceGIF,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)}
            var balancePreviewFrame=0
            func checkBalanceGaze() {
                let d=controller.diagnostics
                if d["seatBalanceProgress"] as! Double > 0 {
                    let view=controller.body.contentView as! WindowSeatSpriteView
                    precondition(view.smileAmount==0,"The happy idle smile yields to the focused balance expression")
                    precondition(view.gazeOffsetY==0,"Curious upward glances stay suppressed through balance and its return")
                    let expected=((d["seatGazeOffset"] as! Double)*4).rounded()/4
                    precondition(view.gazeOffset==expected,"Balance gaze takes over without idle offsets")
                }
            }
            func recordBalance() {
                guard let balanceGIF else {return}
                let scene=NSRect(x:target.frame.minX-60,y:target.frame.maxY-110,width:680,height:320)
                let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:680,pixelsHigh:320,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
                NSColor.windowBackgroundColor.setFill();NSRect(origin:.zero,size:scene.size).fill()
                NSGraphicsContext.current!.cgContext.translateBy(x:-scene.minX,y:-scene.minY)
                NSColor(calibratedRed:0.92,green:0.96,blue:1,alpha:1).setFill();window.frame.fill()
                NSColor.separatorColor.setFill();NSRect(x:window.frame.minX,y:window.frame.maxY-24,width:window.frame.width,height:24).fill()
                let view=controller.body.contentView!,sprite=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                view.cacheDisplay(in:view.bounds,to:sprite)
                NSImage(cgImage:sprite.cgImage!,size:view.bounds.size).draw(in:controller.body.frame)
                NSGraphicsContext.restoreGraphicsState()
                // GIF delays are centiseconds: 30/30/40 ms preserves the
                // actual 30 Hz average instead of speeding every frame up.
                let delay=balancePreviewFrame%3==2 ? 0.04 : 0.03
                CGImageDestinationAddImage(balanceGIF,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay]] as CFDictionary)
                balancePreviewFrame+=1
            }
            for i in 0..<140 {
                // Two smooth start/brake/reverse cycles exercise acceleration,
                // including deceleration while the window still moves right.
                let dx=CGFloat(56*(1-cos(Double(i)*2 * .pi/70))),dy=dx*0.3
                window.setFrameOrigin(NSPoint(x:target.frame.minX+dx,y:target.frame.minY+dy))
                RunLoop.main.run(until:Date().addingTimeInterval(0.035))
                controller.tick(at:testTime+Double(i)/30)
                let d=controller.diagnostics
                checkBalanceGaze()
                balanceFrames.insert(d["seatBalanceFrame"] as! Int)
                let lean=d["seatUpperLeanDegrees"] as! Double
                let focus=d["seatFocusAmount"] as! Double
                maxFocus=max(maxFocus,focus);maxFocusStep=max(maxFocusStep,abs(focus-previousFocus));previousFocus=focus
                if scale==1 {balanceResponse.append(["time":Double(i)/30,"x":dx,"velocity":d["seatHorizontalVelocity"]!,"acceleration":d["seatHorizontalAcceleration"]!,"leanDegrees":lean,"focusAmount":focus])}
                maxLeanStep=max(maxLeanStep,abs(lean-previousLean));previousLean=lean
                if i>77 && i<88 {precondition(lean>0.5,"Rightward acceleration leans upper body left: \(d)");positiveLean=true}
                if i>113 && i<122 {precondition(lean < -0.5,"Leftward acceleration leans upper body right: \(d)");negativeLean=true}
                precondition(controller.phase == .seatedOnWindow && !(d["seatReturning"] as! Bool))
                precondition(abs(controller.body.frame.minX-offset.x-dx)<1.1 && abs(controller.body.frame.minY-offset.y-dy)<1.1,"Follow 2D position without changing seat offset: scale \(scale), step \(i), desired \(dx),\(dy), body \(controller.body.frame), offset \(offset), target \(d["targetFrame"]!)")
                precondition(controller.body.frame.size==frame.size,"Balance never enlarges the character")
                recordBalance()
            }
            precondition(balanceFrames.contains(WindowSeatArtwork.balanceFrameCount-1),"Movement reaches the fully braced pose")
            precondition(positiveLean && negativeLean && maxLeanStep<2,"Direction reversal leans smoothly through upright: \(maxLeanStep)")
            precondition(maxFocus>0.3 && maxFocusStep<0.15,"Acceleration focuses the expression with continuous changes: \(maxFocus), \(maxFocusStep)")
            let settleTime=testTime+5
            for i in 0..<210 {controller.tick(at:settleTime+Double(i)/60);checkBalanceGaze();if i%2==0 {recordBalance()}}
            if let balanceGIF {precondition(CGImageDestinationFinalize(balanceGIF))}
            precondition(controller.diagnostics["seatBalanceFrame"] as! Int == 0,"Stop moving, retract limbs, resume the resting loop")
            precondition(controller.diagnostics["seatUpperLeanDegrees"] as! Double == 0,"Stopped window returns upper body upright")
            precondition(controller.diagnostics["seatFocusAmount"] as! Double == 0,"Stopped window relaxes expression")
            // A moderate impulse fades continuously instead of forcing a full
            // movement-gated gesture after the acceleration has disappeared.
            let briefTime=settleTime+3.5
            var prior=0.0,peak=0.0
            for i in 0..<90 {
                if i<12 {window.setFrameOrigin(NSPoint(x:target.frame.minX+CGFloat(i)*2,y:target.frame.minY))}
                RunLoop.main.run(until:Date().addingTimeInterval(0.02))
                controller.tick(at:briefTime+Double(i)/60)
                let value=controller.diagnostics["seatBalanceProgress"] as! Double
                precondition(abs(value-prior)<0.05,"Arm/leg preparation and relaxation stay continuous")
                prior=value;peak=max(peak,value)
            }
            precondition(peak>0.05,"Short acceleration produces a proportional balance response")
            for i in 0..<12 {
                window.setFrameOrigin(NSPoint(x:target.frame.minX+22+CGFloat(i*i)*0.2,y:target.frame.minY))
                RunLoop.main.run(until:Date().addingTimeInterval(0.02))
                controller.tick(at:briefTime+1.5+Double(i)/60)
            }
            let balanceBeforeLoss=controller.diagnostics["seatBalanceProgress"] as! Double
            precondition(balanceBeforeLoss>0,"Loss exercises a loaded posture")
            window.setFrame(NSRect(x:target.frame.minX,y:target.frame.minY,width:target.frame.width+20,height:target.frame.height),display:false)
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
            var finished=0
            controller.onFinish={_ in finished+=1}
            let leaveTime=briefTime+1.75
            controller.tick(at:leaveTime)
            precondition(controller.isRunning && controller.phase != .fallingFromWindow,"An unsettled resize is not a lost support")
            controller.tick(at:leaveTime+0.2)
            precondition(controller.phase == .leavingWindow && controller.isRunning)
            let before=controller.body.frame
            controller.tick(at:leaveTime+0.201)
            precondition(abs(controller.body.frame.minY-before.minY)<1,"Window departure does not teleport the sprite")
            controller.tick(at:leaveTime+0.2+balanceBeforeLoss*WindowSeatArtwork.balanceReturnDuration+0.001)
            let neutral=(controller.body.contentView as! WindowSeatSpriteView).image!
            precondition(png(neutral)==png(art.frames[0]),"Balance-to-fold handoff must not flash a stale loop frame")
            for i in 1...300 {controller.tick(at:leaveTime+Double(i)/20)}
            precondition(!controller.isRunning && finished==1)
            window.setFrame(target.frame,display:false)
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        }
        let fallChecks=try checkFall(window:window,area:area,output:output)
        window.close()
        try WindowSeatSelectionChecks.run()
        try WindowSeatSupportLossChecks.run()
        try JSONSerialization.data(withJSONObject:["passed":true,"inertia":inertiaChecks,"pressure":pressureChecks,"fall":fallChecks,"expressionChangedPixels":expressionChangedPixels,"balanceResponse":balanceResponse,"geometryAndCost":rows,"maxPalmStepPixels":maxPalmStep,"palmCenters":palms.map{$0.map{[$0.x,$0.y]}},"handTransitionSeconds":WindowSeatArtwork.transitionDuration,"balanceMaxPalmStep":balanceMaxPalmStep,"balanceMaxShoeStep":balanceMaxShoeStep,"balancePalms":balancePalms.map{$0.map{[$0.x,$0.y]}},"balanceShoes":balanceShoes.map{$0.map{[$0.x,$0.y]}}],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("seat-validation.json"))
        print("PASS: seat loop endpoints, 50/100/200 percent anchors, articulated loss recovery and 1200-tick costs")
    }
    private static func checkFall(window:NSWindow,area:NSRect,output:URL)throws -> [[String:Any]] {
        let startWindow=window.frame
        var rows:[[String:Any]]=[]
        for direction in [-1.0,1.0] {
            window.setFrame(startWindow,display:false)
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            let target=DesktopWindowTarget.resolve(UInt32(window.windowNumber),side:.left)!
            let original=NSRect(x:target.frame.midX-73.5,y:target.frame.maxY+30,width:147,height:226)
            let controller=WindowPeekController()
            precondition(controller.start(from:original,scale:1,requiredTarget:target,preferSeat:true))
            var returned:NSRect?
            controller.onReturnToEdge={returned=$0}
            let clock=ProcessInfo.processInfo.systemUptime+controller.duration+0.1
            controller.tick(at:clock)
            var fallingAt:Double?,firstY=0.0,lastY=0.0,maxDrop=0.0,queriesAtFall=0,done=false
            let gif=direction>0 ? CGImageDestinationCreateWithURL(output.appendingPathComponent("continuous-fall.gif") as CFURL,UTType.gif.identifier as CFString,180,nil) : nil
            if let gif {CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)}
            for i in 1...360 {
                let t=Double(i)/60,dx=direction*0.5*3200*pow(min(t,0.44),2)
                if fallingAt==nil {window.setFrameOrigin(NSPoint(x:startWindow.minX+dx,y:startWindow.minY))}
                RunLoop.main.run(until:Date().addingTimeInterval(0.019))
                controller.tick(at:clock+t)
                guard controller.isRunning else {done=true;break}
                let d=controller.diagnostics
                if d["seatFalling"] as! Bool {
                    if fallingAt==nil {fallingAt=t;firstY=controller.body.frame.minY;queriesAtFall=d["seatWindowRefreshes"] as! Int}
                    precondition(d["seatWindowRefreshes"] as! Int == queriesAtFall,"Detached fall must stop querying/following its former support")
                    maxDrop=max(maxDrop,firstY-controller.body.frame.minY);lastY=controller.body.frame.minY
                    precondition(controller.phase == .fallingFromWindow)
                }
                if i%2==0,let gif {
                    let scene=NSRect(x:startWindow.midX-100,y:area.minY,width:850,height:650)
                    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:850,pixelsHigh:650,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
                    NSColor.windowBackgroundColor.setFill();NSRect(origin:.zero,size:scene.size).fill()
                    NSGraphicsContext.current!.cgContext.translateBy(x:-scene.minX,y:-scene.minY)
                    NSColor(calibratedRed:0.9,green:0.95,blue:1,alpha:1).setFill();window.frame.fill()
                    NSColor.separatorColor.setFill();NSRect(x:scene.minX,y:area.minY,width:scene.width,height:2).fill()
                    let view=controller.body.contentView!,sprite=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                    view.cacheDisplay(in:view.bounds,to:sprite)
                    NSImage(cgImage:sprite.cgImage!,size:view.bounds.size).draw(in:controller.body.frame)
                    NSGraphicsContext.restoreGraphicsState()
                    CGImageDestinationAddImage(gif,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.0333]] as CFDictionary)
                    if [18,36,54,72,108,150,204,240].contains(i) {try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("fall-\(i).png"))}
                }
            }
            if let gif {precondition(CGImageDestinationFinalize(gif))}
            precondition(fallingAt != nil && maxDrop>150 && done,"Excessive acceleration must visibly fall and finish recovery")
            precondition(returned != nil && returned!.minY>=area.minY-1 && returned!.minY<area.minY+90,"Fall returns the ordinary character at its new floor location: \(String(describing:returned)), area \(area)")
            precondition(abs(returned!.minY-original.minY)>150,"A fall cannot teleport back to its former seat")
            rows.append(["direction":direction,"fallAfter":fallingAt!,"dropPoints":maxDrop,"lastBodyY":lastY,"returnY":returned!.minY,"queriesAfterDetaching":0])
        }
        window.setFrame(startWindow,display:false)
        return rows
    }
    private static func checkPressure()->[[String:Any]] {
        var rows:[[String:Any]]=[]
        for angle in [0.0,3,8,14] {
            var p=WindowSeatPressure()
            for _ in 0..<240 {p.step(angle:angle,acceleration:angle*50,delta:1.0/120)}
            let expected=angle==0 ? 0 : angle<5 ? 1 : angle<12 ? 2 : 3
            precondition(p.tier==expected,"All four pressure tiers have distinct stable states")
            precondition(angle==0 ? p.gaze==0 : p.gaze>0,"Gaze opposes the actual upper-body lean")
            if angle>=12 {precondition(p.legAmplitude==0 && p.legSpeed==0,"Critical feet stop and tuck")}
            rows.append(["angle":angle,"pressure":p.amount,"tier":p.tier,"gaze":p.gaze,"legAmplitude":p.legAmplitude,"legSpeed":p.legSpeed])
        }
        var reversal=WindowSeatPressure()
        for i in 0..<240 {
            reversal.step(angle:i<120 ? 12 : -12,acceleration:i<120 ? 700 : -700,delta:1.0/120)
            precondition(reversal.gaze*reversal.lean>=0,"Eyes oppose body lean even while passing through upright")
        }
        var falling=WindowSeatPressure(),peakStep=0.0,previous=0.0
        for _ in 0..<120 {
            falling.step(angle:15,acceleration:2400,delta:1.0/120)
            peakStep=max(peakStep,abs(falling.amount-previous));previous=falling.amount
        }
        precondition(falling.shouldFall && peakStep<0.21,"Sustained overload reaches critical continuously, then detaches")
        var short=WindowSeatPressure()
        for _ in 0..<6 {short.step(angle:15,acceleration:3000,delta:1.0/120)}
        for _ in 0..<120 {short.step(angle:0,acceleration:0,delta:1.0/120)}
        precondition(!short.shouldFall,"A single short spike cannot trigger a fall")
        falling.step(angle:0,acceleration:0,delta:1.0/120)
        precondition(falling.amount>2.9,"Relaxation must not snap")
        for _ in 0..<480 {falling.step(angle:0,acceleration:0,delta:1.0/120)}
        precondition(falling.amount==0 && falling.lean==0 && falling.gaze==0)
        var blinking=WindowSeatPressure(),blinks=0,wasBlinking=false
        for _ in 0..<1200 {
            blinking.step(angle:0,acceleration:0,delta:1.0/120)
            if blinking.blink>0 && !wasBlinking {blinks+=1}
            wasBlinking=blinking.blink>0
        }
        precondition(blinks==2,"Relaxed eyes blink naturally about every 3.4 seconds")
        rows.append(["sustainedOverloadFalls":true,"spikeFalls":false,"maxPressureStep120Hz":peakStep,"relaxedBlinks10Seconds":blinks])
        return rows
    }
    private static func checkInertia()->[[String:Any]] {
        var rows:[[String:Any]]=[]
        for hz in [20,60,120] {
            let dt=1.0/Double(hz)
            func ramp(_ acceleration:Double)->Double {
                var motion=WindowSeatInertia(),previous=0.0
                for i in 1...(hz*2) {
                    let t=Double(i)*dt,x=0.5*acceleration*t*t
                    motion.sample(displacement:x-previous,interval:dt);previous=x
                }
                return motion.leanDegrees
            }
            let weak=ramp(120),strong=ramp(480),extreme=ramp(1200),left=ramp(-480)
            precondition(weak>0.9 && strong>weak*2 && extreme>strong && extreme<=15,"Larger acceleration produces larger bounded lean at \(hz) Hz")
            precondition(abs(left+strong)<0.01,"Acceleration direction reverses the lean symmetrically")
            var motion=WindowSeatInertia()
            for _ in 0..<(hz*3) {motion.sample(displacement:240*dt,interval:dt)}
            let cruise=motion.leanDegrees
            precondition(abs(cruise)<0.1,"Even fast constant velocity returns upright")
            var brake=0.0
            for _ in 0..<hz {motion.sample(displacement:0,interval:dt);brake=min(brake,motion.leanDegrees)}
            precondition(brake < -0.5,"Stopping rightward travel leans forward with inertia")
            for _ in 0..<hz {motion.sample(displacement:0,interval:dt)}
            precondition(motion.leanDegrees==0,"Resting after braking returns exactly upright")
            motion.sample(displacement:50,interval:1)
            precondition(motion.leanDegrees==0,"Clock suspension discards old velocity")
            rows.append(["sampleHz":hz,"weakAcceleration":120,"strongAcceleration":480,"extremeAcceleration":1200,"weakLeanDegrees":weak,"strongLeanDegrees":strong,"extremeLeanDegrees":extreme,"cruiseLeanDegrees":cruise,"brakeLeanDegrees":brake])
        }
        var motion=WindowSeatInertia(),x=0.0,maxNoise=0.0
        // Selected-window queries switch between 20 and 60 Hz. Rounded 24 pt/s
        // positions must not create a visible lean from cadence or pixel noise.
        for hz in [20,60,20] {
            for i in 0..<(hz*2) {
                let next=x+24/Double(hz)
                motion.sample(displacement:next.rounded()-x.rounded(),interval:1/Double(hz));x=next
                if i>hz {maxNoise=max(maxNoise,abs(motion.leanDegrees))}
            }
        }
        precondition(maxNoise<0.5,"Pixel quantization and query cadence cannot cause visible tilt: \(maxNoise)")
        var vertical=WindowSeatInertia()
        for _ in 0..<120 {vertical.sample(displacement:0,interval:1/60)}
        precondition(vertical.leanDegrees==0,"Vertical movement has no horizontal inertia")
        rows.append(["queryCadenceAndPixelNoiseMaxDegrees":maxNoise,"verticalLeanDegrees":vertical.leanDegrees])
        return rows
    }
}
