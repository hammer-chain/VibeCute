import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main struct CutoutPSDClassicThinkingChecks {
    static func main() {do {try run()} catch {fputs("FAIL: \(error)\n",stderr);exit(1)}}
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out=root.appendingPathComponent("output/cutout/see-through-classic-thinking-v1")
        let previous=root.appendingPathComponent("output/cutout/see-through-hair-thinking-v1")
        func check(_ condition:Bool,_ message:String)throws {if !condition {throw CutoutError.invalid(message)}}
        let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:out.appendingPathComponent("classic-thinking-rig.json")))
        let motions=try JSONDecoder().decode(CutoutMotionLibrary.self,from:Data(contentsOf:out.appendingPathComponent(rig.motions)))
        let oldRig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:previous.appendingPathComponent("hair-thinking-rig.json")))
        let oldMotions=try JSONDecoder().decode(CutoutMotionLibrary.self,from:Data(contentsOf:previous.appendingPathComponent(oldRig.motions)))
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        for before in oldMotions.clips {
            let after=motions.clips.first{$0.id==before.id}!
            try check(try encoder.encode(before)==encoder.encode(after),"An existing action was changed")
        }
        let start=ProcessInfo.processInfo.systemUptime
        let art=try CutoutArtwork(rig:rig){out.appendingPathComponent($0)}
        let cold=ProcessInfo.processInfo.systemUptime-start
        let old=try CutoutArtwork(rig:oldRig){previous.appendingPathComponent($0)}
        let state=CutoutStudioState(artwork:art,candidatePath:out.appendingPathComponent("classic-thinking-rig.json").path)
        state.setPlaying(false);state.setAction("thinking-classic");state.seek(0)
        try check(abs(state.duration-2.88)<1e-10,"Original eighteen 160ms beats lost")
        try check(art.decodedBytes==old.decodedBytes,"Rhythm adds texture memory")
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        func context(_ w:Int=1024,_ h:Int=1024)->CGContext {CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!}
        func render(_ a:CutoutArtwork,_ blink:Double)->CGImage {
            let c=context();a.draw(in:c,anchor:CGPoint(x:512,y:0),scale:1/a.rig.pointsPerPixel,blink:blink)
            return c.makeImage()!
        }
        func bytes(_ image:CGImage)->[UInt8] {let c=context();c.draw(image,in:CGRect(x:0,y:0,width:1024,height:1024));return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:1024*1024*4))}
        let player=art.player,head=player.indices["head"]!,hair=player.indices["hair-back"]!
        let upper=player.indices["arm-right"]!,elbow=player.indices["right-elbow"]!,wrist=player.indices["right-wrist"]!
        let constraint=rig.twoBoneConstraints!.first{$0.id=="right-chin-contact"}!
        let target=CGPoint(x:constraint.targetPoint[0]-player.bindWorld[head].x,y:constraint.targetPoint[1]-player.bindWorld[head].y)
        let hairRoot=CGPoint(x:player.bindWorld[hair].x-player.bindWorld[head].x,y:player.bindWorld[hair].y-player.bindWorld[head].y)
        player.play("thinking-classic",at:0,transition:0);old.player.play("thinking",at:0,transition:0)
        let neutral=bytes(render(art,0));try check(neutral==bytes(render(old,0)),"Classic starts with different artwork")
        for (phase,angle,blink) in [(0.4,0.0,0.0),(0.96,0,0),(1.20,-9,0),(1.48,-7,0.7),(1.65,0,1),(1.80,0,0),(2.40,1,0)] {
            state.seek(phase/2.88)
            let pose=player.world[head],face=state.faceInputs(at:state.clock)
            try check(abs(atan2(pose.b,pose.a)*180/Double.pi-angle)<1e-8,"Original pose hold lost at \(phase)")
            try check(abs(face.blink-blink)<1e-8,"Original half/closed/open rhythm lost at \(phase)")
        }
        state.eyeMode="manual";state.blink=0.3;state.mouthMode="manual";state.mouth=0.4;state.gazeMode="left"
        state.seek(1.65/2.88);let manual=state.faceInputs(at:state.clock)
        try check(manual.blink==0.3 && manual.mouth==0.4 && manual.gaze.x == -1,"Authored blink overrides explicit facial controls")
        state.eyeMode="auto";let closed=state.faceInputs(at:state.clock).blink
        state.setAction("thinking");try check(abs(state.faceInputs(at:state.clock).blink-closed)<1e-8,"Leaving authored blink jumps")
        state.setAction("thinking-classic");state.seek(1.20/2.88)
        let pose=player.world,phase=player.startedAt,index=player.clipIndex
        try art.select(["hair":"hair-none","tail":"tail-none"])
        try check(player.world==pose && player.startedAt==phase && player.clipIndex==index,"Appearance swap resets original rhythm")
        try art.select(rig.defaults)
        var armRig=rig;armRig.clothDeformations=nil;armRig.expressions=nil;armRig.eyeClips=nil
        let ids:Set<String>=["right-upper","right-fore","right-hand"]
        armRig.slots=armRig.slots.filter{ids.contains($0.id)}
        var clothes=armRig.variants.first{$0.category=="clothes" && $0.id==armRig.defaults["clothes"]}!
        clothes.attachments=clothes.attachments.filter{ids.contains($0.slot)}
        armRig.variants=[clothes];armRig.defaults=["clothes":clothes.id]
        let arm=try CutoutArtwork(rig:armRig){out.appendingPathComponent($0)}
        player.play("thinking-classic",at:0,transition:0);arm.player.play("thinking-classic",at:0,transition:0)
        let probes=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("seam-probes.json"))) as! [[String:Any]]
        let reads=art.resourceReads,decodes=art.decodedImages,masks=art.eyeMaskImagesBuilt,patches=art.clothPatchImagesBuilt
        var maxContact=0.0,maxRoot=0.0,minAlpha=255,minHead=0.0,maxHead=0.0,probeSamples=0
        for frame in 0..<260 {
            let time=Double(frame)/30;player.sample(at:time);arm.player.sample(at:time)
            let end=CGPoint.zero.applying(player.world[wrist]),contact=target.applying(player.world[head])
            maxContact=max(maxContact,hypot(end.x-contact.x,end.y-contact.y))
            let rootPoint=CGPoint.zero.applying(player.world[hair]),expectedRoot=hairRoot.applying(player.world[head])
            maxRoot=max(maxRoot,hypot(rootPoint.x-expectedRoot.x,rootPoint.y-expectedRoot.y))
            let angle=atan2(player.world[head].b,player.world[head].a)*180/Double.pi
            minHead=min(minHead,angle);maxHead=max(maxHead,angle)
            for id in ["root","tail"] {let i=player.indices[id]!,b=player.bindWorld[i],w=player.world[i];try check(w.tx==b.x && w.ty==b.y && w.a==1 && w.b==0,"Original rhythm moves fixed support")}
            let pixels=bytes(render(arm,0))
            for probe in probes {
                let p=probe["point"] as! [Double],isElbow=probe["joint"] as! String=="elbow"
                let a=isElbow ? upper:elbow,b=isElbow ? elbow:wrist
                func moved(_ i:Int)->CGPoint {CGPoint(x:p[0]-player.bindWorld[i].x,y:p[1]-player.bindWorld[i].y).applying(player.world[i])}
                let pa=moved(a),pb=moved(b),x=Int((pa.x+pb.x)/2),y=Int((pa.y+pb.y)/2)
                try check(x>=0 && x<1024 && y>=0 && y<1024,"Classic arm joint leaves canvas")
                let alpha=Int(pixels[((1023-y)*1024+x)*4+3]);minAlpha=min(minAlpha,alpha);probeSamples+=1
                try check(alpha>=240,"Classic arm opens a seam")
            }
        }
        try check(maxContact<1e-8 && maxRoot<1e-8,"Classic loses contact or hair registration")
        try check(minHead>=(-9-1e-8) && maxHead<1.1 && minHead < -8.99,"Classic head range missing or excessive")
        for t in [2.88,5.76,8.64] {player.sample(at:t);try check(bytes(render(art,player.automaticBlink(at:t,fallback:0)))==neutral,"Classic loop endpoint jumps")}
        // Export one exact 2.88s cycle at 25Hz, a divisor of the 160ms source beat.
        let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent("classic-thinking.gif") as CFURL,UTType.gif.identifier as CFString,72,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for f in 0..<72 {
            let t=Double(f)*0.04;player.sample(at:t);let image=render(art,player.automaticBlink(at:t,fallback:0))
            if [0,30,37,41].contains(f) {let dest=CGImageDestinationCreateWithURL(out.appendingPathComponent("classic-pose-\(f).png") as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(dest,image,nil);precondition(CGImageDestinationFinalize(dest))}
            let c=context(384,512);c.setFillColor(CGColor(gray:0.8,alpha:1));c.fill(CGRect(x:0,y:0,width:384,height:512));c.translateBy(x:-64,y:0);c.scaleBy(x:0.5,y:0.5);c.draw(image,in:CGRect(x:0,y:0,width:1024,height:1024))
            CGImageDestinationAddImage(gif,c.makeImage()!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        for values in [[CutoutMotionLibrary.ScalarKey(time:0,value:0),.init(time:2.88,value:2)],
                       [.init(time:0.1,value:0),.init(time:2.88,value:0)],
                       [.init(time:0,value:0),.init(time:0,value:1),.init(time:2.88,value:0)],
                       [.init(time:0,value:0),.init(time:2.88,value:1)]] {
            var invalid=motions;let i=invalid.clips.firstIndex{$0.id=="thinking-classic"}!;invalid.clips[i].blink=values
            do {_=try CutoutPlayer(rig:rig,motions:invalid);throw CutoutError.invalid("Invalid blink fixture accepted")} catch let error as CutoutError {try check(!error.description.contains("fixture accepted"),error.description)}
        }
        player.play("thinking-classic",at:0,transition:0)
        let c=context(300,300)
        func draw(_ a:CutoutArtwork,_ f:Int) {let t=24+Double(f)/30;a.player.sample(at:t,gaze:CGPoint(x:sin(t),y:cos(t)*0.4));c.clear(CGRect(x:0,y:0,width:300,height:300));a.draw(in:c,anchor:CGPoint(x:150,y:0),blink:a.player.automaticBlink(at:t,fallback:0),mouth:CutoutArtwork.talkingPreview(at:t))}
        for f in 0..<100 {draw(art,f)}
        let ops=art.drawOperations,solves=player.constraintSolves,tracks=player.sampledTracks,begin=ProcessInfo.processInfo.systemUptime
        var timings=[Double]()
        for f in 0..<1000 {let s=ProcessInfo.processInfo.systemUptime;draw(art,f);timings.append(ProcessInfo.processInfo.systemUptime-s)}
        let elapsed=ProcessInfo.processInfo.systemUptime-begin;timings.sort()
        try check(art.resourceReads==reads && art.decodedImages==decodes && art.eyeMaskImagesBuilt==masks && art.clothPatchImagesBuilt==patches,"Rhythm prepares resources while playing")
        try check(art.drawOperations-ops<=31000 && art.parts.count==30 && rig.bones.count==12,"Rhythm exceeds original work budget")
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any]=["renderer":"actual CutoutPlayer/CutoutArtwork/CutoutStudioState","sourceSequenceVerified":true,"durationSeconds":2.88,"frames":260,"sampleHz":30,"existingActionsPreserved":true,"neutralChangedPixels":0,"loopEndpointChangedPixels":0,"blinkHoldsVerified":true,"manualFaceOverrideVerified":true,"blinkExitContinuous":true,"swapPhasePreserved":true,"invalidBlinkFixturesRejected":4,"maximumContactErrorSourcePixels":maxContact,"maximumHairRootErrorSourcePixels":maxRoot,"minimumArmSeamAlpha":minAlpha,"seamProbeSamples":probeSamples,"minimumHeadAngleDegrees":minHead,"maximumHeadAngleDegrees":maxHead,"decodedBytes":art.decodedBytes,"decodedBytesDelta":art.decodedBytes-old.decodedBytes,"cachedClothForms":patches,"tickReads":0,"tickDecodes":0,"tickMaskBuilds":0,"tickClothPatchBuilds":0,"newTimers":0,"drawOperations1000":art.drawOperations-ops,"constraintSolves1000":player.constraintSolves-solves,"sampledBoneTracks1000":player.sampledTracks-tracks,"coldLoadSeconds":cold,"sampleAndDraw1000Seconds":elapsed,"sampleAndDrawP95Milliseconds":timings[949]*1000,"offlinePeakRSSBytes":usage.ru_maxrss,"productionMigrationComplete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!)
    }
}
