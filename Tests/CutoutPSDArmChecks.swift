import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutPSDArmChecks {
    static func main() { do {try run()} catch {fputs("FAIL: \(error)\n",stderr);exit(1)} }
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let source=root.appendingPathComponent("output/cutout/see-through-repaired-v1")
        let out=root.appendingPathComponent("output/cutout/see-through-arm-v1")
        func load(_ directory:URL,_ filename:String)throws->CutoutArtwork {
            let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:directory.appendingPathComponent(filename)))
            return try CutoutArtwork(rig:rig){directory.appendingPathComponent($0)}
        }
        let baseline=try load(source,"psd-rig.json")
        let begin=ProcessInfo.processInfo.systemUptime
        let art=try load(out,"arm-rig.json"),cold=ProcessInfo.processInfo.systemUptime-begin
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        func context(_ w:Int=1024,_ h:Int=1024)->CGContext {
            CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        func render(_ artwork:CutoutArtwork)->CGImage {
            let c=context();artwork.draw(in:c,anchor:CGPoint(x:512,y:0),scale:1/artwork.rig.pointsPerPixel);return c.makeImage()!
        }
        func bytes(_ im:CGImage)->[UInt8] {
            let c=context();c.draw(im,in:CGRect(x:0,y:0,width:1024,height:1024))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:1024*1024*4))
        }
        func save(_ im:CGImage,_ name:String) {
            let d=CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(d,im,nil);precondition(CGImageDestinationFinalize(d))
        }
        func check(_ ok:Bool,_ message:String)throws {if !ok {throw CutoutError.invalid(message)}}
        baseline.player.play("idle",at:0,transition:0);art.player.play("idle",at:0,transition:0)
        let before=bytes(render(baseline)),neutral=render(art),after=bytes(neutral)
        let ruffleNames:Set<String>=["shoulder-ruffle-r","shoulder-ruffle-l"]
        let ruffles=art.rig.slots.filter{ruffleNames.contains($0.id)}
        let armOrder=art.rig.slots.filter{["right-upper","right-fore","right-hand","handwear-l"].contains($0.id)}.map(\.order).max()!
        let hairOrder=art.rig.slots.first{$0.id=="front hair"}!.order
        try check(ruffles.count==2 && ruffles.allSatisfy{$0.bone=="root" && $0.category=="clothes" && $0.order>armOrder && $0.order<hairOrder},"Shoulder clothing overlays must cover arms below front hair")
        // Restoring their old torso order must reproduce the previous image
        // exactly. The new order may change only the shoulder pixel footprints.
        var sameOrderRig=art.rig
        var ordered=sameOrderRig.slots.filter{!ruffleNames.contains($0.id)}.sorted{$0.order<$1.order}
        let torsoIndex=ordered.firstIndex{$0.id=="topwear"}!+1
        ordered.insert(contentsOf:ruffles.sorted{$0.order<$1.order},at:torsoIndex)
        for i in ordered.indices {ordered[i].order=i};sameOrderRig.slots=ordered
        let sameOrder=try CutoutArtwork(rig:sameOrderRig){out.appendingPathComponent($0)}
        sameOrder.player.play("idle",at:0,transition:0)
        try check(bytes(render(sameOrder))==before,"Shoulder decomposition changes pixels even in the original order")
        let maskSource=CGImageSourceCreateWithURL(out.appendingPathComponent("shoulder-overlay-mask.png") as CFURL,nil)!
        let mask=bytes(CGImageSourceCreateImageAtIndex(maskSource,0,nil)!)
        var changes=0,maxDelta=0
        for p in 0..<(1024*1024) {
            let d=(0..<4).map{abs(Int(before[p*4+$0])-Int(after[p*4+$0]))}.max()!
            if d>0 {changes+=1;try check(mask[p*4]>0,"Overlay changed a pixel outside the two shoulder ruffles")};maxDelta=max(maxDelta,d)
        }
        save(neutral,"neutral.png")
        save(render(baseline),"neutral-previous.png")
        var ruffleRig=art.rig;ruffleRig.slots=ruffles
        var ruffleClothes=ruffleRig.variants.first{$0.id=="clothes-original"}!
        ruffleClothes.attachments=ruffleClothes.attachments.filter{ruffleNames.contains($0.slot)}
        ruffleRig.variants=[ruffleClothes];ruffleRig.defaults=["clothes":ruffleClothes.id]
        let ruffleArtwork=try CutoutArtwork(rig:ruffleRig){out.appendingPathComponent($0)}
        save(render(ruffleArtwork),"shoulder-ruffles-only.png")
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("parts.json"))) as! [String:Any]
        try check(art.parts.count==(manifest["parts"] as! [[String:Any]]).count && art.rig.bones.count==11,"Arm parts/joints missing")
        try check(art.decodedBytes<24*1024*1024,"Arm fixture exceeds texture budget")
        let wrist=art.player.indices["right-wrist"]!,head=art.player.indices["head"]!
        let upper=art.player.indices["arm-right"]!,elbow=art.player.indices["right-elbow"]!
        func armOnly(_ fill:Bool)throws->CutoutArtwork {
            var rig=art.rig
            let names:Set<String>=["right-upper","right-fore","right-hand","elbow-underlap","wrist-underlap"]
            rig.slots=rig.slots.filter{names.contains($0.id) && (fill || !$0.id.contains("underlap"))}
            let selected=Set(rig.slots.map(\.id))
            var clothes=rig.variants.first{$0.id=="clothes-original"}!
            clothes.attachments=clothes.attachments.filter{selected.contains($0.slot)}
            rig.variants=[clothes];rig.defaults=["clothes":clothes.id]
            return try CutoutArtwork(rig:rig){out.appendingPathComponent($0)}
        }
        let isolated=try armOnly(true),unfilled=try armOnly(false)
        let probes=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("seam-probes.json"))) as! [[String:Any]]
        try check(probes.count>20,"Insufficient original-pixel joint seam probes")
        var seamSamples=0,unfilledHoles=0,filledHoles=0
        var seamRows=[String:[String:Int]]()
        let bindWrist=art.player.bindWorld[wrist],bindHead=art.player.bindWorld[head]
        let target=CGPoint(x:bindWrist.x-bindHead.x,y:bindWrist.y-bindHead.y)
        let localTip=CGPoint(x:443-bindWrist.x,y:1024-513-bindWrist.y)
        let headTip=CGPoint(x:443-bindHead.x,y:1024-513-bindHead.y)
        var maximumWristError=0.0,maximumTipError=0.0,maxLengthError=0.0
        var phases=[[String:Any]]()
        for action in ["head-sway","right-elbow-probe"] {
            art.player.play(action,at:0,transition:0)
            isolated.player.play(action,at:0,transition:0);unfilled.player.play(action,at:0,transition:0)
            let reads=art.resourceReads,decodes=art.decodedImages
            let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent(action+".gif") as CFURL,UTType.gif.identifier as CFString,120,nil)!
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            for frame in 0..<120 {
                art.player.sample(at:Double(frame)/30)
                isolated.player.sample(at:Double(frame)/30);unfilled.player.sample(at:Double(frame)/30)
                let filledPixels=bytes(render(isolated)),unfilledPixels=bytes(render(unfilled))
                func alpha(_ pixels:[UInt8],_ point:CGPoint)->UInt8 {
                    let x=min(1023,max(0,Int(point.x))),y=min(1023,max(0,Int(point.y)))
                    // CGImage row storage is top down; rig coordinates are y up.
                    return pixels[((1023-y)*1024+x)*4+3]
                }
                for probe in probes {
                    let joint=probe["joint"] as! String,p=probe["point"] as! [Double]
                    let a=joint=="elbow" ? upper:elbow,b=joint=="elbow" ? elbow:wrist
                    let source=CGPoint(x:p[0],y:p[1])
                    func moved(_ bone:Int)->CGPoint {
                        CGPoint(x:source.x-art.player.bindWorld[bone].x,y:source.y-art.player.bindWorld[bone].y).applying(art.player.world[bone])
                    }
                    let left=moved(a),right=moved(b),midpoint=CGPoint(x:(left.x+right.x)/2,y:(left.y+right.y)/2)
                    if frame==0 {try check(alpha(unfilledPixels,midpoint)>240,"Joint probe is outside original opaque coverage")}
                    seamSamples+=1
                    let beforeAlpha=Int(alpha(unfilledPixels,midpoint)),afterAlpha=Int(alpha(filledPixels,midpoint))
                    if beforeAlpha<240 {unfilledHoles+=1}
                    if afterAlpha<240 {filledHoles+=1}
                    let key=action+":"+joint
                    var row=seamRows[key] ?? ["samples":0,"unfilledBelow240":0,"filledBelow240":0,"unfilledZeroAlpha":0,"filledZeroAlpha":0,"filledBelow128":0,"minimumFilledAlpha":255]
                    row["samples",default:0]+=1
                    if beforeAlpha<240 {row["unfilledBelow240",default:0]+=1};if afterAlpha<240 {row["filledBelow240",default:0]+=1}
                    if beforeAlpha==0 {row["unfilledZeroAlpha",default:0]+=1};if afterAlpha==0 {row["filledZeroAlpha",default:0]+=1}
                    if afterAlpha<128 {row["filledBelow128",default:0]+=1}
                    row["minimumFilledAlpha"]=min(row["minimumFilledAlpha"]!,afterAlpha);seamRows[key]=row
                }
                if action=="head-sway" {
                    let a=CGPoint.zero.applying(art.player.world[wrist]),b=target.applying(art.player.world[head])
                    maximumWristError=max(maximumWristError,hypot(a.x-b.x,a.y-b.y))
                    let c=localTip.applying(art.player.world[wrist]),d=headTip.applying(art.player.world[head])
                    maximumTipError=max(maximumTipError,hypot(c.x-d.x,c.y-d.y))
                }
                for pair in [(upper,elbow),(elbow,wrist)] {
                    let a=CGPoint.zero.applying(art.player.world[pair.0]),b=CGPoint.zero.applying(art.player.world[pair.1])
                    let ba=art.player.bindWorld[pair.0],bb=art.player.bindWorld[pair.1]
                    maxLengthError=max(maxLengthError,abs(hypot(a.x-b.x,a.y-b.y)-hypot(ba.x-bb.x,ba.y-bb.y)))
                }
                let im=render(art),preview=context(384,512)
                preview.setFillColor(CGColor(gray:0.8,alpha:1));preview.fill(CGRect(x:0,y:0,width:384,height:512))
                preview.translateBy(x:-64,y:0);preview.scaleBy(x:0.5,y:0.5)
                preview.draw(im,in:CGRect(x:0,y:0,width:1024,height:1024))
                CGImageDestinationAddImage(gif,preview.makeImage()!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
                if frame==0 || frame==30 || frame==90 {save(im,action+"-\(frame).png");save(render(isolated),action+"-arm-\(frame).png")}
            }
            precondition(CGImageDestinationFinalize(gif))
            try check(art.resourceReads==reads && art.decodedImages==decodes,"Arm animation performs tick I/O")
            phases.append(["action":action,"frames":120,"tickFileReads":0,"tickDecodes":0])
        }
        try check(maximumWristError<1e-8 && maximumTipError<1e-8 && maxLengthError<1e-8,"IK contact or limb length failed")
        try check(filledHoles==0,"Articulated native joint has \(filledHoles) low-alpha seam samples")
        // Transition acquisition/release and interruption use the actual player.
        art.player.play("head-sway",at:10,transition:0);art.player.sample(at:11)
        let pose=art.player.world,time=art.player.startedAt,index=art.player.clipIndex
        try art.select(["hair":"hair-none","headwear":"headwear-none"])
        try check(pose==art.player.world && time==art.player.startedAt && index==art.player.clipIndex,"Skin selection resets constrained motion")
        save(render(art),"contact-no-hair.png");try art.select(art.rig.defaults)
        art.player.play("idle",at:11,transition:0.3);art.player.sample(at:11)
        try check(zip(pose,art.player.world).allSatisfy { a,b in abs(a.tx-b.tx)<1e-8 && abs(a.ty-b.ty)<1e-8 && abs(a.a-b.a)<1e-8 },"Contact release jumps")
        art.player.sample(at:11.15);let interrupted=art.player.world
        art.player.play("head-sway",at:11.15,transition:0.25);art.player.sample(at:11.15)
        try check(zip(interrupted,art.player.world).allSatisfy { a,b in abs(a.tx-b.tx)<1e-8 && abs(a.ty-b.ty)<1e-8 && abs(a.a-b.a)<1e-8 },"Interrupted acquisition jumps")
        let bench=context(300,300),reads=art.resourceReads,decodes=art.decodedImages
        for f in 0..<100 {bench.clear(CGRect(x:0,y:0,width:300,height:300));art.player.sample(at:20+Double(f)/30);art.draw(in:bench,anchor:CGPoint(x:150,y:0))}
        let start=ProcessInfo.processInfo.systemUptime,ops=art.drawOperations,solves=art.player.constraintSolves
        var timings=[Double]()
        for f in 0..<1000 {
            let t=ProcessInfo.processInfo.systemUptime
            bench.clear(CGRect(x:0,y:0,width:300,height:300));art.player.sample(at:24+Double(f)/30);art.draw(in:bench,anchor:CGPoint(x:150,y:0))
            timings.append(ProcessInfo.processInfo.systemUptime-t)
        }
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        try check(art.resourceReads==reads && art.decodedImages==decodes,"Arm benchmark does I/O")
        timings.sort()
        let report:[String:Any]=["renderer":"actual CutoutArtwork/CutoutPlayer","neutralVersusUnsplitChangedPixels":changes,"neutralVersusUnsplitMaximumChannelDelta":maxDelta,
            "sameOrderDecompositionChangedPixels":0,"neutralChangeOutsideShoulderRuffles":0,"shoulderOcclusionChangeIntentional":true,"shoulderOverlaysAboveArms":true,
            "parts":art.parts.count,"bones":art.rig.bones.count,"coldLoadSeconds":cold,"decodedBytes":art.decodedBytes,
            "maximumWristContactErrorSourcePixels":maximumWristError,"maximumFingerContactErrorSourcePixels":maximumTipError,"maximumLimbLengthErrorSourcePixels":maxLengthError,
            "headMotionDegrees":6,"elbowProbeDegrees":12,"phasePreservedAcrossSwap":true,"releaseAndInterruptedAcquisitionContinuous":true,"phases":phases,
            "seamProbeCount":probes.count,"seamProbeSamples":seamSamples,"unfilledSeamLowAlphaSamples":unfilledHoles,"filledSeamLowAlphaSamples":filledHoles,
            "jointCoveragePassed":filledHoles==0,"seamProbeAlphaThreshold":240,
            "seamRows":seamRows,
            "sampleAndDraw1000Seconds":elapsed,"sampleAndDrawP95Milliseconds":timings[949]*1000,"drawOperations1000":art.drawOperations-ops,"constraintSolves1000":art.player.constraintSolves-solves,
            "tickFileReads":0,"tickDecodes":0,"nativeAccepted":false,"visualAccepted":false,"originalReferenceFidelityAccepted":false,"productionMigrationComplete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!)
    }
}
