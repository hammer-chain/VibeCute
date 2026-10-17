import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutPSDChecks {
    static func main() { do {try run()} catch {fputs("FAIL: \(error)\n",stderr);exit(1)} }
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out=root.appendingPathComponent("output/cutout/see-through-repaired-v1")
        let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:out.appendingPathComponent("psd-rig.json")))
        let loaded=ProcessInfo.processInfo.systemUptime
        let art=try CutoutArtwork(rig:rig) {out.appendingPathComponent($0)}
        let coldSeconds=ProcessInfo.processInfo.systemUptime-loaded
        let size=1024,space=CGColorSpace(name:CGColorSpace.sRGB)!
        func context(_ width:Int=1024,_ height:Int=1024)->CGContext {
            CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        func image(_ path:String)->CGImage {CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(out.appendingPathComponent(path) as CFURL,nil)!,0,nil)!}
        func bytes(_ im:CGImage)->[UInt8] {let c=context();c.draw(im,in:CGRect(x:0,y:0,width:size,height:size));return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:size*size*4))}
        func render()->CGImage {let c=context();art.draw(in:c,anchor:CGPoint(x:rig.anchor[0],y:rig.anchor[1]),scale:1/rig.pointsPerPixel);return c.makeImage()!}
        func save(_ im:CGImage,_ name:String) {let d=CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(d,im,nil);precondition(CGImageDestinationFinalize(d))}
        func check(_ ok:Bool,_ message:String) throws {if !ok {throw CutoutError.invalid(message)}}
        art.player.play("idle",at:0,transition:0)
        let neutral=render(),actual=bytes(neutral),expected=bytes(image("composite.png"))
        var maxDelta=0,changed=0,alphaSupportMismatch=0,alphaMaxDelta=0
        for p in 0..<(size*size) {
            let d=(0..<4).map {abs(Int(actual[p*4+$0])-Int(expected[p*4+$0]))}.max()!
            maxDelta=max(maxDelta,d);if d>0{changed+=1}
            if (actual[p*4+3]>0) != (expected[p*4+3]>0) {alphaSupportMismatch+=1}
            alphaMaxDelta=max(alphaMaxDelta,abs(Int(actual[p*4+3])-Int(expected[p*4+3])))
        }
        try check(alphaSupportMismatch==0,"Repaired PSD silhouette changed in actual renderer")
        // Keep photometric failure visible while continuing mechanical checks.
        // A successful fixture run does not turn this into a fidelity acceptance.
        let photometricPass = maxDelta <= 2
        save(neutral,"runtime-neutral.png")
        try check(art.parts.count==26 && art.decodedBytes<24*1024*1024,"Wrong PSD part count/budget")
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("parts.json"))) as! [String:Any]
        for entry in manifest["parts"] as! [[String:Any]] {
            let name=entry["name"] as! String, box=entry["bbox"] as! [Int]
            let part=art.parts.first { rig.slots[$0.slot].id == name }!
            let pivot=art.player.bindWorld[part.bone], r=part.rect.offsetBy(dx:pivot.x,dy:pivot.y)
            try check(r == CGRect(x:box[0],y:1024-box[3],width:box[2]-box[0],height:box[3]-box[1]),"Component was independently fitted: \(name)")
        }
        let actions=["tail-wag","hair-sway","head-sway","arm-probe"]
        var phases=[[String:Any]](),handContactError=0.0
        for action in actions {
            try art.select(rig.defaults);art.player.play(action,at:0,transition:0)
            let base=bytes(render()),reads=art.resourceReads,decodes=art.decodedImages
            let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent("runtime-\(action).gif") as CFURL,UTType.gif.identifier as CFString,60,nil)!
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            for frame in 0..<60 {
                art.player.sample(at:Double(frame)/15)
                let im=render()
                // Isolated tail/root attachment makes semantic mis-parenting observable.
                if action=="tail-wag" {let b=bytes(im);for p in 0..<(size*500) {try check((0..<4).allSatisfy{b[p*4+$0]==base[p*4+$0]},"Tail motion changes head pixels")}}
                if action=="head-sway" {
                    let point=CGPoint(x:443-486,y:1024-513-(1024-510)).applying(art.player.world[art.player.indices["head"]!])
                    let hand=CGPoint(x:443-375,y:1024-513-(1024-547)).applying(art.player.world[art.player.indices["arm-right"]!])
                    handContactError=max(handContactError,hypot(point.x-hand.x,point.y-hand.y))
                }
                let c=context(384,512);c.setFillColor(CGColor(gray:0.85,alpha:1));c.fill(CGRect(x:0,y:0,width:384,height:512));c.translateBy(x:-64,y:0);c.scaleBy(x:0.5,y:0.5);c.draw(im,in:CGRect(x:0,y:0,width:1024,height:1024))
                CGImageDestinationAddImage(gif,c.makeImage()!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/15]] as CFDictionary)
                if frame==15 || frame==45 {save(im,"runtime-\(action)-\(frame).png")}
            }
            precondition(CGImageDestinationFinalize(gif));try check(art.resourceReads==reads && art.decodedImages==decodes,"Animation loads resources")
            phases.append(["action":action,"frames":60,"tickFileReads":art.resourceReads-reads,"tickDecodes":art.decodedImages-decodes])
        }
        // Replacing appearance must not reset action, startedAt, pose or phase.
        art.player.play("tail-wag",at:10,transition:0);art.player.sample(at:11)
        let time=art.player.startedAt,index=art.player.clipIndex,world=art.player.world
        try art.select(["hair":"hair-none","headwear":"headwear-none"])
        try check(art.player.startedAt==time && art.player.clipIndex==index && art.player.world==world,"Appearance swap reset motion")
        save(render(),"runtime-no-hair.png")
        try art.select(rig.defaults)
        let benchmark=context(300,300),reads=art.resourceReads,decodes=art.decodedImages
        for f in 0..<100 {benchmark.clear(CGRect(x:0,y:0,width:300,height:300));art.player.sample(at:Double(f)/30);art.draw(in:benchmark,anchor:CGPoint(x:150,y:0))}
        let start=ProcessInfo.processInfo.systemUptime,ops=art.drawOperations
        for f in 0..<1000 {benchmark.clear(CGRect(x:0,y:0,width:300,height:300));art.player.sample(at:Double(f)/30);art.draw(in:benchmark,anchor:CGPoint(x:150,y:0))}
        let tickSeconds=ProcessInfo.processInfo.systemUptime-start
        try check(art.resourceReads==reads && art.decodedImages==decodes,"Benchmark tick did IO")
        let report:[String:Any]=["renderer":"actual CutoutArtwork/CutoutPlayer","parts":art.parts.count,"bones":rig.bones.count,"decodedBytes":art.decodedBytes,"coldLoadSeconds":coldSeconds,"neutralChangedPixels":changed,"neutralMaximumChannelDelta":maxDelta,"alphaSupportMismatch":alphaSupportMismatch,"alphaMaximumChannelDelta":alphaMaxDelta,"photometricThreshold":2,"photometricPass":photometricPass,"sourcePlacementPass":true,"alphaComparisonBoundary":"CoreGraphics premultiplied sRGB versus PSD layer compositor; not original-image acceptance","phasePreservedAcrossSwap":true,"phases":phases,"maximumUnconstrainedHandContactErrorSourcePixels":handContactError,"sampleAndDraw1000Seconds":tickSeconds,"drawOperations1000":art.drawOperations-ops,"tickFileReads":art.resourceReads-reads,"tickDecodes":art.decodedImages-decodes,"visualAccepted":false,"productionMigrationComplete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("runtime-checks.json"));print(String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!)
    }
}
