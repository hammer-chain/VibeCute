import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main struct CutoutPSDBodyThinkingChecks {
    static func main() {do {try run()} catch {fputs("FAIL: \(error)\n",stderr);exit(1)}}
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let arguments=Array(CommandLine.arguments.dropFirst())
        let stage=arguments.count==4 ? arguments[0]:"see-through-body-thinking-v1"
        let rigFile=arguments.count==4 ? arguments[1]:"body-thinking-rig.json"
        let baselineStage=arguments.count==4 ? arguments[2]:"see-through-thinking-v1"
        let baselineFile=arguments.count==4 ? arguments[3]:"thinking-rig.json"
        let out=root.appendingPathComponent("output/cutout/\(stage)")
        let previous=root.appendingPathComponent("output/cutout/\(baselineStage)")
        func check(_ condition:Bool,_ message:String)throws {if !condition {throw CutoutError.invalid(message)}}
        func load(_ dir:URL,_ file:String)throws->CutoutArtwork {
            let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:dir.appendingPathComponent(file)))
            return try CutoutArtwork(rig:rig){dir.appendingPathComponent($0)}
        }
        let started=ProcessInfo.processInfo.systemUptime
        let art=try load(out,rigFile),cold=ProcessInfo.processInfo.systemUptime-started
        let old=try load(previous,baselineFile)
        let state=CutoutStudioState(artwork:art,candidatePath:out.appendingPathComponent(rigFile).path)
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
        old.player.play("thinking",at:0,transition:0);art.player.play("thinking",at:0,transition:0)
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
        let torso=player.indices["torso"]!
        let hair=player.indices["hair-back"]!
        let hairMotion=art.player.clips.first{$0.definition.id=="thinking"}!.definition.tracks.contains{$0.bone=="hair-back"}
        let hairRoot=CGPoint(x:player.bindWorld[hair].x-player.bindWorld[head].x,y:player.bindWorld[hair].y-player.bindWorld[head].y)
        // This distal point is inside the unchanged source hair silhouette.
        let hairTipSource=CGPoint(x:229,y:263)
        let hairPart=art.parts.first{art.rig.slots[$0.slot].id=="back hair"}!
        let sourceHair=context(hairPart.image.width,hairPart.image.height)
        sourceHair.draw(hairPart.image,in:CGRect(x:0,y:0,width:hairPart.image.width,height:hairPart.image.height))
        let hairSourceRect=hairPart.rect.offsetBy(dx:player.bindWorld[hair].x,dy:player.bindWorld[hair].y)
        let hx=Int(hairTipSource.x-hairSourceRect.minX),hy=hairPart.image.height-1-Int(hairTipSource.y-hairSourceRect.minY)
        try check(hx>=0 && hx<hairPart.image.width && hy>=0 && hy<hairPart.image.height,"Hair tip probe is outside the registered source rectangle")
        try check(sourceHair.data!.assumingMemoryBound(to:UInt8.self)[(hy*hairPart.image.width+hx)*4+3]>=250,"Hair tip probe is outside the source silhouette")
        let hairTip=CGPoint(x:hairTipSource.x-player.bindWorld[hair].x,y:hairTipSource.y-player.bindWorld[hair].y)
        var maxHairRootError=0.0,maxHairAngle=0.0,maxHairTipDisplacement=0.0,maxHairStep=0.0,lastHairAngle=0.0
        let moving=descendants([torso]),rest=player.world
        for (id,i) in player.indices where id != "torso" {
            try check(player.bindWorld[i]==old.player.bindWorld[old.player.indices[id]!],"Body binding changes original neutral registration")
        }
        var lowerRig=art.rig
        lowerRig.clothDeformations=nil
        lowerRig.slots=lowerRig.slots.filter{["legwear","footwear"].contains($0.id)}
        var lowerClothes=lowerRig.variants.first{$0.category=="clothes" && $0.id==lowerRig.defaults["clothes"]}!
        lowerClothes.attachments=lowerClothes.attachments.filter{["legwear","footwear"].contains($0.slot)}
        lowerRig.variants=[lowerClothes];lowerRig.defaults=["clothes":lowerClothes.id];lowerRig.expressions=nil;lowerRig.eyeClips=nil
        let lower=try CutoutArtwork(rig:lowerRig){out.appendingPathComponent($0)}
        lower.player.play("thinking",at:0,transition:0)
        let lowerNeutral=bytes(render(lower))
        // Find opaque native overlap where moving skirt covers fixed thighs.
        func slotsArtwork(_ ids:Set<String>)throws->CutoutArtwork {
            var rig=art.rig;rig.slots=rig.slots.filter{ids.contains($0.id)}
            rig.clothDeformations=rig.clothDeformations?.filter{ids.contains($0.slot)}
            var clothes=rig.variants.first{$0.category=="clothes" && $0.id==rig.defaults["clothes"]}!
            clothes.attachments=clothes.attachments.filter{ids.contains($0.slot)}
            rig.variants=[clothes];rig.defaults=["clothes":clothes.id];rig.expressions=nil;rig.eyeClips=nil
            return try CutoutArtwork(rig:rig){out.appendingPathComponent($0)}
        }
        let skirt=try slotsArtwork(["topwear"]),legs=try slotsArtwork(["legwear"])
        skirt.player.play("thinking",at:0,transition:0)
        let skirtPixels=bytes(render(skirt)),legPixels=bytes(render(legs))
        var supportProbes=[CGPoint]()
        for y in stride(from:235,through:270,by:3) {for x in stride(from:350,through:583,by:3) {
            let offset=((1023-y)*1024+x)*4+3
            if skirtPixels[offset]>=250 && legPixels[offset]>=250 {supportProbes.append(CGPoint(x:x,y:y))}
        }}
        try check(supportProbes.count>20,"Missing opaque native skirt/thigh overlap")
        let deformation=art.rig.clothDeformations!.first!
        let region=CGRect(x:deformation.region[0],y:deformation.region[1],width:deformation.region[2],height:deformation.region[3])
        var clothInterior=[CGPoint]()
        // Source silhouette pixels legitimately move and interpolate. Probe
        // Every fully opaque source interior pixel, ten pixels from alpha edges.
        // This also leaves room for the 50% native raster's sampling footprint.
        // Existing semitransparent source paint is not a mesh-coverage probe.
        for y in 400...511 {for x in 395...555 {
            if skirtPixels[((1023-y)*1024+x)*4+3] != 255 {continue}
            var interior=true
            for dy in -10...10 {for dx in -10...10 {
                if skirtPixels[((1023-y-dy)*1024+x+dx)*4+3]<254 {interior=false;break}
            };if !interior {break}}
            if interior {clothInterior.append(CGPoint(x:x,y:y))}
        }}
        try check(clothInterior.count>100,"Missing opaque chest fabric probes")
        var minClothAlpha=255,clothSamples=0,protectedClothChanges=0,activeClothChanges=0
        var scaleClothSamples=0,minScaleClothAlpha=255
        let support=try slotsArtwork(["topwear","legwear"])
        support.player.play("thinking",at:0,transition:0)
        var minSupportAlpha=255,supportSamples=0,maxTorsoStep=0.0,lastTorsoAngle=0.0
        var maxTorso=0.0,minTorso=0.0

        var armRig=art.rig
        armRig.clothDeformations=nil
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
        let patchBuilds=art.clothPatchImagesBuilt
        func envelope(_ pose:[CGAffineTransform],_ c:CGContext) {
            c.setFillColor(CGColor(gray:1,alpha:1))
            for part in art.parts where moving.contains(part.bone) {
                c.saveGState();c.concatenate(pose[part.bone]);c.fill(part.rect.insetBy(dx:-2,dy:-2));c.restoreGState()
            }
            c.fill(region.insetBy(dx:-8,dy:-8))
        }
        for frame in 0..<240 {
            let t=Double(frame)/30
            art.player.sample(at:t);arm.player.sample(at:t);lower.player.sample(at:t);support.player.sample(at:t)
            skirt.player.sample(at:t)
            let clothPixels=bytes(render(skirt))
            for p in clothInterior {
                let alpha=Int(clothPixels[((1023-Int(p.y))*1024+Int(p.x))*4+3])
                minClothAlpha=min(minClothAlpha,alpha);clothSamples+=1
                if alpha<254 {save(render(skirt),"failed-cloth.png")}
                try check(alpha>=254,"Shoulder cloth mesh has an internal seam at frame \(frame), source \(p), alpha \(alpha)")
            }
            if frame % 6 == 0 {
                for scale in [0.25,0.5,1.0] {
                    let c=context();skirt.draw(in:c,anchor:CGPoint(x:512*scale,y:0),scale:scale/skirt.rig.pointsPerPixel)
                    let pixels=bytes(c.makeImage()!)
                    for p in clothInterior {
                        let offset=((1023-Int(p.y*scale))*1024+Int(p.x*scale))*4+3
                        let alpha=Int(pixels[offset]);minScaleClothAlpha=min(minScaleClothAlpha,alpha);scaleClothSamples+=1
                        try check(alpha>=254,"Cloth has a filtered triangle seam at native source scale \(scale), frame \(frame), source \(p), alpha \(alpha)")
                    }
                }
            }
            if [0,48,90,177,210].contains(frame) {
                for y in 0..<1024 {for x in 0..<1024 {
                    let offset=((1023-y)*1024+x)*4
                    if (0..<4).contains(where:{clothPixels[offset+$0] != skirtPixels[offset+$0]}) {
                        if region.contains(CGPoint(x:x,y:y)) {activeClothChanges+=1}
                        else {protectedClothChanges+=1}
                    }
                }}
            }
            let torsoAngle=atan2(player.world[torso].b,player.world[torso].a)*180 / Double.pi
            maxTorso=max(maxTorso,torsoAngle);minTorso=min(minTorso,torsoAngle)
            maxTorsoStep=max(maxTorsoStep,abs(torsoAngle-lastTorsoAngle));lastTorsoAngle=torsoAngle
            let supportPixels=bytes(render(support))
            for p in supportProbes {
                let alpha=Int(supportPixels[((1023-Int(p.y))*1024+Int(p.x))*4+3])
                minSupportAlpha=min(minSupportAlpha,alpha);supportSamples+=1
                try check(alpha>=240,"Body lean opens a skirt/thigh seam")
            }
            if frame % 30 == 0 {try check(bytes(render(lower))==lowerNeutral,"Body lean moves legs or feet")}

            for bone in player.world.indices where !moving.contains(bone) {try check(player.world[bone]==rest[bone],"Fixed body bone moved")}
            let angle=atan2(player.world[head].b,player.world[head].a)*180 / Double.pi
            let hairAngle=atan2(player.world[hair].b,player.world[hair].a)*180 / Double.pi-angle
            let rootPoint=CGPoint.zero.applying(player.world[hair]),expectedRoot=hairRoot.applying(player.world[head])
            maxHairRootError=max(maxHairRootError,hypot(rootPoint.x-expectedRoot.x,rootPoint.y-expectedRoot.y))
            maxHairAngle=max(maxHairAngle,abs(hairAngle))
            maxHairStep=max(maxHairStep,abs(hairAngle-lastHairAngle));lastHairAngle=hairAngle
            let hairTipWorld=hairTip.applying(player.world[hair])
            let rigidTip=CGPoint(x:hairTip.x+hairRoot.x,y:hairTip.y+hairRoot.y).applying(player.world[head])
            maxHairTipDisplacement=max(maxHairTipDisplacement,hypot(hairTipWorld.x-rigidTip.x,hairTipWorld.y-rigidTip.y))
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
        try check(protectedClothChanges==0 && activeClothChanges>100,"Cloth must deform locally while preserving waist/skirt; outside \(protectedClothChanges), inside \(activeClothChanges)")
        try check(maxWrist<1e-8 && maxFinger<1e-8 && maxLength<1e-8,"Thinking loses contact or changes limb length")
        try check(abs(maxTorso-1.4)<1e-8 && abs(minTorso+1)<1e-8,"Body does not participate in thinking")
        try check(maxTorsoStep<0.08,"Body lean moves too far between samples")
        try check(maxStep<0.34,"Thinking moves too far between 30 Hz samples")
        try check(maxHairRootError<1e-8,"Back hair separates from its scalp pivot")
        if hairMotion {
            try check(maxHairAngle>0.34 && maxHairAngle<=0.35+1e-8,"Hair sway exceeds its small authored range or is missing")
            try check(maxHairTipDisplacement>4 && maxHairTipDisplacement<4.5 && maxHairStep<0.07,"Hair tip motion is missing, excessive or discontinuous")
        }
        try check(art.resourceReads==reads && art.decodedImages==decodes && art.eyeMaskImagesBuilt==masks && art.clothPatchImagesBuilt==patchBuilds,"Thinking loop prepares resources per tick")
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
        player.play("thinking",at:0,transition:0);old.player.play("thinking",at:0,transition:0)
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
        try check(art.resourceReads==benchReads && art.decodedImages==benchDecodes && art.eyeMaskImagesBuilt==masks && art.clothPatchImagesBuilt==patchBuilds,"Thinking benchmark prepares resources per tick")
        try check(art.decodedBytes-old.decodedBytes<=4*1024*1024 && art.parts.count==30 && art.rig.bones.count==12,"Cloth atlas exceeds its local cache budget")
        try check(art.drawOperations-ops<=31_000,"Cloth exceeds its one-patch draw budget")
        if hairMotion {try check(art.decodedBytes==old.decodedBytes,"Hair sway adds texture memory")}
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any]=["renderer":"actual CutoutArtwork/CutoutPlayer/CutoutStudioState","neutralChangedPixels":0,
            "loopEndpointChangedPixels":0,"outsideMovingPartsChangedPixels":outsideChanges,"frames":240,"framesPerSecond":30,
            "maximumWristContactErrorSourcePixels":maxWrist,"maximumFingerContactErrorSourcePixels":maxFinger,"maximumLimbLengthErrorSourcePixels":maxLength,
            "maximumHeadStepDegrees":maxStep,"seamProbeCount":probes.count,"seamProbeSamples":seamSamples,"minimumSeamAlpha":minAlpha,
            "seamProbeAlphaThreshold":240,"fixedSeatedSupportPreserved":true,"legsAndFeetPixelsPreserved":true,"skirtSupportProbeCount":supportProbes.count,"skirtSupportProbeSamples":supportSamples,"minimumSkirtSupportAlpha":minSupportAlpha,"maximumTorsoStepDegrees":maxTorsoStep,"maximumTorsoRotationDegrees":maxTorso,"minimumTorsoRotationDegrees":minTorso,"controlsIndependent":true,"phasePreservedAcrossSwap":true,
            "releaseAndInterruptedAcquisitionContinuous":true,"coldLoadSeconds":cold,"decodedBytes":art.decodedBytes,"decodedBytesDelta":art.decodedBytes-old.decodedBytes,
            "parts":art.parts.count,"bones":art.rig.bones.count,"drawOperations1000":art.drawOperations-ops,"constraintSolves1000":player.constraintSolves-solves,
            "clothInteriorProbeCount":clothInterior.count,"clothInteriorProbeSamples":clothSamples,"minimumClothInteriorAlpha":minClothAlpha,"protectedClothChangedPixels":protectedClothChanges,"activeClothChangedPixels":activeClothChanges,"cachedClothPatchBuilds":patchBuilds,
            "nativeScaleClothProbeSamples":scaleClothSamples,"minimumNativeScaleClothAlpha":minScaleClothAlpha,"clothAlphaThreshold":254,
            "sampleAndDraw1000Seconds":elapsed,"sampleAndDrawP95Milliseconds":timings[949]*1000,"baselineSampleAndDraw1000Seconds":baseline,
            "hairTipMotionVerified":hairMotion,"maximumHairRootErrorSourcePixels":maxHairRootError,"maximumRelativeHairAngleDegrees":maxHairAngle,"maximumHairTipDisplacementSourcePixels":maxHairTipDisplacement,"maximumHairStepDegrees":maxHairStep,
            "benchmarkComparison":"Same face art, gaze/eye/mouth inputs, timestamps, 300x300 CGContext; \(stage) versus \(baselineStage), sequential single-run timing",
            "offlinePeakRSSBytes":usage.ru_maxrss,"tickReads":0,"tickDecodes":0,"tickMaskBuilds":0,
            "newSourceTextures":0,"cachedClothForms":29,"tickClothPatchBuilds":0,"newTimers":0,"originalEightFrameThinkingReplaced":false,"productionMigrationComplete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!)
    }
}
