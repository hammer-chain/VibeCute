import AppKit
import ImageIO
import UniformTypeIdentifiers

enum StrollArtworkChecks {
    static func run() throws {
        let art = DeepSeekStroll.shared, mascot = MascotAnimation.library[.deepseek]!
        precondition(art.available, "All rise, turn and walk sprites must be bundled")
        let folder = ProcessInfo.processInfo.environment["CAPTIONS_STROLL_OUTPUT"].map {URL(fileURLWithPath:$0)}
            ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/deepseek-jog")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        precondition(StrollTimeline.sample(at: -1) == nil && StrollTimeline.sample(at: .infinity) == nil)
        precondition(StrollTimeline.sample(at: StrollTimeline.duration) == nil)
        precondition(abs(Double(StrollTimeline.walkFrames.count)*StrollTimeline.walkFrameDuration-0.72) < 0.000001, "Short two-step jog cycle")
        let walkingSteps = StrollTimeline.steps.filter { $0.phase == .walking }
        precondition(walkingSteps.map(\.frame) == Array(repeating:StrollTimeline.walkFrames, count:StrollTimeline.walkCycles).flatMap { $0 }.map { Optional($0) })
        precondition(walkingSteps.allSatisfy { $0.duration == StrollTimeline.walkFrameDuration && $0.transitionFrame == nil },"Jog cadence is shared by every walking frame")
        for index in StrollTimeline.walkFrames.indices {
            precondition(StrollTimeline.walkSample(at:(Double(index)+0.5)*StrollTimeline.walkFrameDuration).frame == StrollTimeline.walkFrames[index])
        }
        precondition(StrollTimeline.walkSample(at:0.72+0.001).frame == 12,"Jog loops back to its contact pose")
        precondition(StrollTimeline.walkSample(at:0).armSwing == -1 && StrollTimeline.walkSample(at:0.36).armSwing == 1,
            "Arms reverse smoothly on each alternating step")
        let endpoint = SubtitleView(frame:NSRect(x:0,y:0,width:147,height:226))
        endpoint.mode = .character
        func pixels() -> Data {
            let rep = endpoint.bitmapImageRepForCachingDisplay(in:endpoint.bounds)!
            endpoint.cacheDisplay(in:endpoint.bounds,to:rep)
            return rep.representation(using:.png,properties:[:])!
        }
        for rest in [false,true] { for mirrored in [false,true] {
            endpoint.setMascot(nil,animating:false); endpoint.setMascot(.deepseek,animating:false)
            endpoint.strollMirrored = mirrored
            if rest {
                endpoint.setScootSample(.init(frame:7,offset:0,phase:"坐稳")); endpoint.setScootSample(nil)
            }
            let before = pixels()
            endpoint.setStrollSample(StrollTimeline.sample(at:0))
            precondition(pixels() == before,"Stroll begins on exact current seated pixels in either direction")
            for launch in 0..<3 {
                endpoint.setStrollSample(.init(frame:nil,phase:.turning,launchFrame:launch))
                let rep=endpoint.bitmapImageRepForCachingDisplay(in:endpoint.bounds)!
                endpoint.cacheDisplay(in:endpoint.bounds,to:rep)
                var faceX=0.0,count=0.0
                for y in Int(Double(rep.pixelsHigh)*50/226)..<Int(Double(rep.pixelsHigh)*120/226) {for x in 0..<rep.pixelsWide {
                    let c=rep.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                    if c.alphaComponent>0.8 && c.redComponent>0.8 && c.greenComponent>0.45 && c.blueComponent>0.35 && c.redComponent>c.greenComponent*1.12 && c.greenComponent>c.blueComponent*1.03 {faceX+=Double(x);count+=1}
                }}
                precondition(count>20)
                precondition(mirrored ? faceX/count < Double(rep.pixelsWide)*0.4 : faceX/count > Double(rep.pixelsWide)*0.6,
                    "Launch faces actual direction of travel in the normal overlay")
            }
            endpoint.setStrollSample(StrollTimeline.sample(at:StrollTimeline.duration-0.001))
            let seated = pixels()
            endpoint.setStrollSample(nil)
            precondition(endpoint.hasScootRestPose && pixels() == seated,"Stroll recovery starts on exact final seat")
            endpoint.setAudioMouth(3)
            precondition(endpoint.hasScootRestPose,"Speech preserves the return transition")
            endpoint.setAudioMouth(nil)
            RunLoop.main.run(until:Date().addingTimeInterval(0.5))
            precondition(!endpoint.hasScootRestPose && endpoint.seatedGazeActive,
                         "Stroll completion restores ordinary thinking")
        } }
        let continuity: [String:Any] = ["passed":true,"thinkingSeatEntryExact":true,"scootSeatEntryExact":true,
            "bothDirections":true,"launchMirroringVerifiedByFacePixels":true,"finalSeatExact":true,"ordinaryThinkingResumed":true,
            "walkFrames":StrollTimeline.walkFrames,"walkFrameDuration":StrollTimeline.walkFrameDuration,"duration":StrollTimeline.duration]
        try JSONSerialization.data(withJSONObject:continuity,options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("stroll-continuity-validation.json"))
        // Inspect baked hands across the supplied full-body cycle. There is no
        // separate arm rig: adding it would duplicate arms on the new artwork.
        var handCenters: [[Double]] = []
        for frame in StrollTimeline.walkFrames {
            let rep=NSBitmapImageRep(cgImage:art.frames[frame].cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            var points=Set<Int>()
            for y in 320..<450 {for x in 140..<440 {
                let c=rep.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if c.alphaComponent>0.8 && c.redComponent>0.75 && c.greenComponent>0.45 && c.blueComponent>0.35 && c.redComponent>c.greenComponent*1.08 && c.greenComponent>c.blueComponent*1.03 {points.insert(y*448+x)}
            }}
            var hands:[[Int]]=[]
            while let seed=points.first {
                var group=[seed],head=0;points.remove(seed)
                while head<group.count {
                    let p=group[head];head+=1
                    for q in [p-1,p+1,p-448,p+448] where points.remove(q) != nil {group.append(q)}
                }
                if group.count>20 {hands.append(group)}
            }
            let palms=hands.sorted { $0.count>$1.count }.prefix(2)
            precondition(palms.count==2,"Both baked palms remain visible in every supplied jog frame")
            handCenters.append(palms.map { Double($0.map { $0%448 }.reduce(0,+))/Double($0.count) }.sorted())
        }
        let near=handCenters.map { $0[0] },far=handCenters.map { $0[1] }
        precondition(near.max()!-near.min()!>15 && far.max()!-far.min()!>3,"Both baked arms move across the twelve-frame jog")
        try JSONSerialization.data(withJSONObject:["passed":true,"bakedArmMotion":true,"duplicateArmRig":false,
            "handCenters":handCenters,"cycleSeconds":0.72],options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("arm-swing-validation.json"))
        var images: [CGImage] = []
        let registrationURL = Bundle.main.url(forResource:"jog-registration",withExtension:"json",subdirectory:"DeepSeekThinking/Stroll")
            ?? Bundle.module.url(forResource:"jog-registration",withExtension:"json",subdirectory:"DeepSeekThinking/Stroll")
            ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/deepseek-motion-v4/jog-registration.json")
        let registration = try JSONSerialization.jsonObject(with:Data(contentsOf:registrationURL)) as! [[String:Any]]
        for (index, image) in art.frames.enumerated() {
            let composed = bitmap(width:448,height:640)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:composed)
            art.draw(.init(frame:index,phase:index >= 12 ? .walking : .turning),animation:mascot,in:NSRect(x:0,y:0,width:448,height:640))
            NSGraphicsContext.restoreGraphicsState()
            let cg = index >= 12 ? composed.cgImage! : image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
            let rep = NSBitmapImageRep(cgImage: cg)
            var minX = 448, maxX = 0, minY = 640, maxY = 0
            for y in 0..<640 { for x in 0..<448 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.4 {
                minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
            } }
            precondition(minX >= 8 && maxX < 440 && minY > 8 && maxY < 632, "Hair, skirt, shoes or tail clipped in frame \(index): \(minX),\(maxX),\(minY),\(maxY)")
            let lift = index >= 12 ? registration[index-12]["footLift"] as! Int : 0
            precondition(abs(maxY-(620-lift)) <= 2, "Contact floor or airborne lift moved")
            if index == 12 || index == 18 { precondition(abs(lift) <= 2,"Both foot contacts share the same floor") }
            if index == 16 || index == 22 { precondition(lift > 8,"Jog flight must be visible at desktop size") }
            images.append(cg)
        }
        let sheet = bitmap(width: 896, height: 1920)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x:0,y:0,width:896,height:1920).fill()
        for (i, image) in images.enumerated() {
            NSImage(cgImage: image, size: NSSize(width:448,height:640))
                .draw(in:NSRect(x:(i%4)*224,y:(5-i/4)*320,width:224,height:320))
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("contact-sheet.png"))
        let walkStart = StrollTimeline.steps.prefix { $0.phase != .walking }.reduce(0) { $0+$1.duration }
        let start=StrollTimeline.steps.prefix { $0.frame != 6 }.reduce(0) { $0+$1.duration }
        let times=(0..<Int(ceil((walkStart+0.72-start)*50))).map {start+Double($0)/50}
        let transitionGIF=CGImageDestinationCreateWithURL(folder.appendingPathComponent("launch-to-jog.gif") as CFURL,
            UTType.gif.identifier as CFString,times.count,nil)!
        CGImageDestinationSetProperties(transitionGIF,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for time in times {
            let frame=bitmap(width:224,height:320)
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:frame)
            NSColor(calibratedWhite:0.96,alpha:1).setFill();NSRect(x:0,y:0,width:224,height:320).fill()
            art.draw(StrollTimeline.sample(at:time)!,animation:mascot,in:NSRect(x:0,y:0,width:224,height:320))
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(transitionGIF,frame.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.02]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(transitionGIF))
        for (name, width, height, cycleOnly) in [
            ("sit-to-stroll.gif",224,320,false), ("stroll-default-size.gif",147,210,false),
            ("walk-loop.gif",224,320,true), ("jog-default-loop.gif",147,210,true)
        ] {
            let times: [Double] = cycleOnly
                ? (0..<36).map { walkStart+Double($0)*0.02 }
                : (0..<Int(ceil(StrollTimeline.duration*25))).map { Double($0)/25 }
            let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                UTType.gif.identifier as CFString,times.count,nil)!
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            for t in times {
                let sample = StrollTimeline.sample(at: cycleOnly ? t : min(t,StrollTimeline.duration-0.001))!
                let image = bitmap(width:width,height:height)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:image)
                NSColor(calibratedWhite:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:width,height:height).fill()
                art.draw(sample,animation:mascot,in:NSRect(x:0,y:0,width:width,height:height),fromScootRest:true)
                NSGraphicsContext.restoreGraphicsState()
                CGImageDestinationAddImage(gif,image.cgImage!,
                    [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:cycleOnly ? 0.02 : 0.04]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(gif))
        }
        let view = SubtitleView(frame:NSRect(x:0,y:0,width:147,height:226))
        view.mode = .character; view.setMascot(.deepseek,animating:true)
        let fixedSize = NSSize(width:view.preferredWidth(available:900),height:view.height(for:147))
        for t in stride(from:0.0,to:StrollTimeline.duration,by:0.1) {
            view.setStrollSample(StrollTimeline.sample(at:t))
            precondition(fixedSize == NSSize(width:view.preferredWidth(available:900),height:view.height(for:147)),
                         "Action must not resize/reflow character window")
        }
        view.setStrollSample(nil)
        precondition(view.strollSample == nil && view.mascotAnimating)
        view.setStrollSample(StrollTimeline.sample(at:4))
        view.setMascot(.deepseek,animating:true,pinkBear:true)
        precondition(view.strollSample == nil && view.mascotArtwork == "pinkBear")
        print("PASS: 24 stroll sprites, 12-frame alternating jog, exact seated endpoints in both directions, tiptoe jog cadence, contact floor and airborne lift, fixed window, full-action GIFs")
    }
    private static func bitmap(width:Int,height:Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    }
}
