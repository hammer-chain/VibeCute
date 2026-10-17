import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main struct CutoutPSDThinkingChecks {
    static func main() {do {try run()} catch {fputs("FAIL: \(error)\n",stderr);exit(1)}}
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out=root.appendingPathComponent("output/cutout/see-through-thinking-v1")
        let previous=root.appendingPathComponent("output/cutout/see-through-face-v1")
        func check(_ condition:Bool,_ message:String)throws {if !condition {throw CutoutError.invalid(message)}}
        func load(_ dir:URL,_ file:String)throws->CutoutArtwork {
            let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:dir.appendingPathComponent(file)))
            return try CutoutArtwork(rig:rig){dir.appendingPathComponent($0)}
        }
        let started=ProcessInfo.processInfo.systemUptime
        let art=try load(out,"thinking-rig.json"),cold=ProcessInfo.processInfo.systemUptime-started
        let old=try load(previous,"face-rig.json")
        let state=CutoutStudioState(artwork:art,candidatePath:out.appendingPathComponent("thinking-rig.json").path)
        try check(state.action=="thinking","Workbench does not start with thinking")
        state.eyeMode="manual";state.blink=0.5;state.mouthMode="talk";state.gazeMode="left"
        state.setAction("idle");state.setAction("thinking")
        try check(state.eyeMode=="manual" && state.blink==0.5 && state.mouthMode=="talk" && state.gazeMode=="left","Action selection resets eye/mouth controls")
        state.setPlaying(false);let paused=state.clock;state.setPlaying(true)
        try check(abs(state.clock-paused)<0.05,"Pause/resume resets shared clock")
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        func context(_ w:Int=1024,_ h:Int=1024)->CGContext {
            CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        func render(_ a:CutoutArtwork,_ blink:Double=0,_ mouth:Double=0)->CGImage {
            let c=context();a.draw(in:c,anchor:CGPoint(x:512,y:0),scale:1/a.rig.pointsPerPixel,blink:blink,mouth:mouth)
            return c.makeImage()!
        }
        func bytes(_ image:CGImage)->[UInt8] {
            let c=context();c.draw(image,in:CGRect(x:0,y:0,width:1024,height:1024))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:1024*1024*4))
        }
        func save(_ image:CGImage,_ name:String) {
            let dest=CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(dest,image,nil);precondition(CGImageDestinationFinalize(dest))
        }
        old.player.play("idle",at:0,transition:0);art.player.play("thinking",at:0,transition:0)
        let neutral=render(art),neutralBytes=bytes(neutral)
        try check(neutralBytes==bytes(render(old)),"Thinking start changes the previous neutral")
        save(neutral,"neutral.png")
        let player=art.player,head=player.indices["head"]!,wrist=player.indices["right-wrist"]!
        let upper=player.indices["arm-right"]!,elbow=player.indices["right-elbow"]!
        let constraint=art.rig.twoBoneConstraints!.first{$0.id=="right-chin-contact"}!
        let target=CGPoint(x:constraint.targetPoint[0]-player.bindWorld[head].x,y:constraint.targetPoint[1]-player.bindWorld[head].y)
        let finger=CGPoint(x:443-player.bindWorld[wrist].x,y:1024-513-player.bindWorld[wrist].y)
        let headFinger=CGPoint(x:443-player.bindWorld[head].x,y:1024-513-player.bindWorld[head].y)
        func descendants(_ ids:Set<Int>)->Set<Int> {
            var result=ids
            for i in player.parents.indices {if let p=player.parents[i],result.contains(p) {result.insert(i)}}
            return result
        }
        let moving=descendants([head,upper]),rest=player.world
        var armRig=art.rig
        let armSlots:Set<String>=["right-upper","right-fore","right-hand"]
        armRig.slots=armRig.slots.filter{armSlots.contains($0.id)}
        var clothes=armRig.variants.first{$0.category=="clothes" && $0.id==armRig.defaults["clothes"]}!
        clothes.attachments=clothes.attachments.filter{armSlots.contains($0.slot)}
        armRig.variants=[clothes];armRig.defaults=["clothes":clothes.id];armRig.expressions=nil;armRig.eyeClips=nil
        let arm=try CutoutArtwork(rig:armRig){out.appendingPathComponent($0)}
        arm.player.play("thinking",at:0,transition:0)
        let probes=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("seam-probes.json"))) as! [[String:Any]]
        let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent("thinking.gif") as CFURL,UTType.gif.identifier as CFString,240,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        var maxWrist=0.0,maxFinger=0.0,maxLength=0.0,maxStep=0.0,minAlpha=255,seamSamples=0,outsideChanges=0
        var lastAngle=0.0
        let reads=art.resourceReads,decodes=art.decodedImages,masks=art.eyeMaskImagesBuilt
        func envelope(_ pose:[CGAffineTransform],_ c:CGContext) {
            c.setFillColor(CGColor(gray:1,alpha:1))
            for part in art.parts where moving.contains(part.bone) {
                c.saveGState();c.concatenate(pose[part.bone]);c.fill(part.rect.insetBy(dx:-2,dy:-2));c.restoreGState()
            }
        }
        for frame in 0..<240 {
            let t=Double(frame)/30
            art.player.sample(at:t);arm.player.sample(at:t)
            for bone in player.world.indices where !moving.contains(bone) {try check(player.world[bone]==rest[bone],"Fixed body bone moved")}
            let angle=atan2(player.world[head].b,player.world[head].a)*180 / Double.pi
            try check(angle>=(-4.5-1e-9) && angle<=6+1e-9,"Head exceeds validated range")
            maxStep=max(maxStep,abs(angle-lastAngle));lastAngle=angle
            let end=CGPoint.zero.applying(player.world[wrist]),contact=target.applying(player.world[head])
            maxWrist=max(maxWrist,hypot(end.x-contact.x,end.y-contact.y))
            let tip=finger.applying(player.world[wrist]),expected=headFinger.applying(player.world[head])
            maxFinger=max(maxFinger,hypot(tip.x-expected.x,tip.y-expected.y))
            for (a,b) in [(upper,elbow),(elbow,wrist)] {
                let pa=CGPoint.zero.applying(player.world[a]),pb=CGPoint.zero.applying(player.world[b]),ba=player.bindWorld[a],bb=player.bindWorld[b]
                maxLength=max(maxLength,abs(hypot(pa.x-pb.x,pa.y-pb.y)-hypot(ba.x-bb.x,ba.y-bb.y)))
            }
            let pixels=bytes(render(arm))
            for probe in probes {
                let p=probe["point"] as! [Double],isElbow=probe["joint"] as! String == "elbow"
                let a=isElbow ? upper:elbow,b=isElbow ? elbow:wrist
                func moved(_ bone:Int)->CGPoint {CGPoint(x:p[0]-player.bindWorld[bone].x,y:p[1]-player.bindWorld[bone].y).applying(player.world[bone])}
                let pa=moved(a),pb=moved(b),x=Int((pa.x+pb.x)/2),y=Int((pa.y+pb.y)/2)
                try check(x>=0 && x<1024 && y>=0 && y<1024,"Joint leaves canvas")
                let alpha=Int(pixels[((1023-y)*1024+x)*4+3]);minAlpha=min(minAlpha,alpha);seamSamples+=1
                try check(alpha>=240,"Thinking arm has a low-alpha joint seam")
            }
            let blink=CutoutArtwork.blink(at:t),image=render(art,blink)
            if [0,48,90,177,210].contains(frame) {
                save(image,"pose-\(frame).png")
                let changed=bytes(image),c=context();envelope(rest,c);envelope(player.world,c);let mask=bytes(c.makeImage()!)
                for p in 0..<(1024*1024) where mask[p*4+3]==0 {
                    if (0..<4).contains(where:{neutralBytes[p*4+$0] != changed[p*4+$0]}) {outsideChanges+=1}
                }
            }
            let preview=context(384,512);preview.setFillColor(CGColor(gray:0.8,alpha:1));preview.fill(CGRect(x:0,y:0,width:384,height:512))
            preview.translateBy(x:-64,y:0);preview.scaleBy(x:0.5,y:0.5);preview.draw(image,in:CGRect(x:0,y:0,width:1024,height:1024))
            CGImageDestinationAddImage(gif,preview.makeImage()!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        try check(outsideChanges==0,"Thinking changes pixels outside moving-part envelopes")
        try check(maxWrist<1e-8 && maxFinger<1e-8 && maxLength<1e-8,"Thinking loses contact or changes limb length")
        try check(maxStep<0.34,"Thinking moves too far between 30 Hz samples")
        try check(art.resourceReads==reads && art.decodedImages==decodes && art.eyeMaskImagesBuilt==masks,"Thinking loop prepares resources per tick")
        art.player.sample(at:8)
        try check(bytes(render(art))==neutralBytes,"Thinking loop end differs from neutral")
        art.player.sample(at:1.6);let pose=player.world,phase=player.startedAt,index=player.clipIndex
        try art.select(["hair":"hair-none","tail":"tail-none"])
        try check(player.world==pose && player.startedAt==phase && player.clipIndex==index && art.eyeMaskImagesBuilt==masks,"Component swap resets thinking")
        try art.select(art.rig.defaults)
        func equalPose(_ a:[CGAffineTransform],_ b:[CGAffineTransform])->Bool {
            zip(a,b).allSatisfy{a,b in zip([a.a,a.b,a.c,a.d,a.tx,a.ty],[b.a,b.b,b.c,b.d,b.tx,b.ty]).allSatisfy{abs($0-$1)<1e-8}}
        }
        player.play("idle",at:1.6,transition:0.25);player.sample(at:1.6)
        try check(equalPose(pose,player.world),"Leaving thinking jumps")
        player.sample(at:1.725);let halfway=player.world
        player.play("thinking",at:1.725,transition:0.25);player.sample(at:1.725)
        try check(equalPose(halfway,player.world),"Interrupted thinking acquisition jumps")
        player.play("thinking",at:0,transition:0);old.player.play("head-sway",at:0,transition:0)
        let c=context(300,300)
        func draw(_ artwork:CutoutArtwork,_ f:Int) {
            let t=24+Double(f)/30;artwork.player.sample(at:t,gaze:CGPoint(x:sin(t),y:cos(t)*0.4))
            c.clear(CGRect(x:0,y:0,width:300,height:300));artwork.draw(in:c,anchor:CGPoint(x:150,y:0),blink:CutoutArtwork.blink(at:t),mouth:CutoutArtwork.talkingPreview(at:t))
        }
        for f in 0..<100 {draw(art,f);draw(old,f)}
        let benchReads=art.resourceReads,benchDecodes=art.decodedImages
        let ops=art.drawOperations,solves=player.constraintSolves,begin=ProcessInfo.processInfo.systemUptime
        var timings=[Double]()
        for f in 0..<1000 {let start=ProcessInfo.processInfo.systemUptime;draw(art,f);timings.append(ProcessInfo.processInfo.systemUptime-start)}
        let elapsed=ProcessInfo.processInfo.systemUptime-begin,oldStart=ProcessInfo.processInfo.systemUptime
        for f in 0..<1000 {draw(old,f)}
        let baseline=ProcessInfo.processInfo.systemUptime-oldStart;timings.sort()
        try check(art.resourceReads==benchReads && art.decodedImages==benchDecodes && art.eyeMaskImagesBuilt==masks,"Thinking benchmark prepares resources per tick")
        try check(art.decodedBytes==old.decodedBytes && art.parts.count==30 && art.rig.bones.count==11,"Thinking increases textures or parts")
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any]=["renderer":"actual CutoutArtwork/CutoutPlayer/CutoutStudioState","neutralChangedPixels":0,
            "loopEndpointChangedPixels":0,"outsideMovingPartsChangedPixels":outsideChanges,"frames":240,"framesPerSecond":30,
            "maximumWristContactErrorSourcePixels":maxWrist,"maximumFingerContactErrorSourcePixels":maxFinger,"maximumLimbLengthErrorSourcePixels":maxLength,
            "maximumHeadStepDegrees":maxStep,"seamProbeCount":probes.count,"seamProbeSamples":seamSamples,"minimumSeamAlpha":minAlpha,
            "seamProbeAlphaThreshold":240,"fixedBodyBonesPreserved":true,"controlsIndependent":true,"phasePreservedAcrossSwap":true,
            "releaseAndInterruptedAcquisitionContinuous":true,"coldLoadSeconds":cold,"decodedBytes":art.decodedBytes,"decodedBytesDelta":0,
            "parts":art.parts.count,"bones":art.rig.bones.count,"drawOperations1000":art.drawOperations-ops,"constraintSolves1000":player.constraintSolves-solves,
            "sampleAndDraw1000Seconds":elapsed,"sampleAndDrawP95Milliseconds":timings[949]*1000,"baselineSampleAndDraw1000Seconds":baseline,
            "benchmarkComparison":"Same current face art, gaze/eye/mouth inputs, timestamps, 300x300 CGContext; head-sway versus thinking, sequential single-run timing",
            "offlinePeakRSSBytes":usage.ru_maxrss,"tickReads":0,"tickDecodes":0,"tickMaskBuilds":0,
            "newTextures":0,"newTimers":0,"originalEightFrameThinkingReplaced":false,"productionMigrationComplete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!)
    }
}
