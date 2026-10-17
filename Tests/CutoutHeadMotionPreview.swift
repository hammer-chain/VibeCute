import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct HeadMotionPreview {
    static func main() {
        do {try run()} catch {fputs("FAIL: \(error)\n",stderr);exit(1)}
    }
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out=root.appendingPathComponent("output/cutout/head-proof")
        let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:out.appendingPathComponent("head-rig.json")))
        let art=try CutoutArtwork(rig:rig) {out.appendingPathComponent($0)}
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        func bitmap()->CGContext {CGContext(data:nil,width:384,height:512,bitsPerComponent:8,bytesPerRow:384*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!}
        func render()->CGImage {
            let c=bitmap();art.draw(in:c,anchor:.zero,scale:1/rig.pointsPerPixel);return c.makeImage()!
        }
        func bytes(_ image:CGImage)->[UInt8] {
            let c=bitmap();c.draw(image,in:CGRect(x:0,y:0,width:384,height:512))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:384*512*4))
        }
        let originalURL=root.appendingPathComponent("docs/animation-reference/deepseek-seated.png")
        let original=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(originalURL as CFURL,nil)!,0,nil)!
        art.player.play("neutral",at:0,transition:0)
        let reference=bytes(original),actual=bytes(render())
        var differences=0
        for p in 0..<(384*512) {if (0..<4).contains(where:{reference[p*4+$0] != actual[p*4+$0]}) {differences+=1}}
        guard differences==0 else {throw CutoutError.invalid("Actual renderer neutral has \(differences) changed pixels")}
        let tailImage=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(out.appendingPathComponent("tail.png") as CFURL,nil)!,0,nil)!
        let tailBytes=bytes(tailImage)
        var tailProbes=[Int]()
        for y in 6..<506 {for x in 6..<378 {
            let p=y*384+x
            if (-5...5).allSatisfy({dy in (-5...5).allSatisfy({dx in tailBytes[((y+dy)*384+x+dx)*4+3]>240})}) {tailProbes.append(p)}
        }}
        guard tailProbes.count>500 else {throw CutoutError.invalid("Insufficient independent tail probes")}
        let completeTail=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(out.appendingPathComponent("tail-complete.png") as CFURL,nil)!,0,nil)!
        let tailBone=art.player.indices["tail"]!
        var erasedTailSamples=0
        var maximumHandContactError=0.0
        var tailChanges=0,headChangesDuringTail=0
        var phases=[[String:Any]]()
        for mode in 0..<8 {
            let bob=mode>=6,workwear=(mode>=3 && mode<6) || mode==7,bald=mode<6 && mode%3==1,tailOnly=mode<6 && mode%3==2
            try art.select(["clothes":workwear ? "clothes-claude-workwear":"clothes-original"])
            try art.select(["hair":bob ? "hair-bob":(bald ? "hair-none":"hair-original"),"headwear":bald ? "headwear-none":"headwear-original"])
            art.player.play(tailOnly ? "tail-wag":"head-sway",at:0,transition:0)
            guard rig.slots.first(where:{$0.id=="tail"})?.bone == "tail", rig.bones.first(where:{$0.id=="tail"})?.parent == "root" else {throw CutoutError.invalid("Tail bound to moving head")}
            let reads=art.resourceReads,decodes=art.decodedImages,builds=art.compositeBuilds,operations=art.drawOperations
            let name=(workwear ? "claude-":"")+(bob ? "bob-motion":(tailOnly ? "tail-motion":(bald ? "bald-motion":"original-hair-motion")))
            let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent(name+".gif") as CFURL,UTType.gif.identifier as CFString,60,nil)!
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            let start=Date()
            for frame in 0..<60 {
                art.player.sample(at:Double(frame)/30)
                if !tailOnly {
                    let target=CGPoint(x:-24,y:-24).applying(art.player.world[art.player.indices["head"]!])
                    let hand=CGPoint.zero.applying(art.player.world[art.player.indices["arm-hand"]!])
                    maximumHandContactError=max(maximumHandContactError,hypot(hand.x-target.x,hand.y-target.y))
                }
                let im=render(),c=bitmap()
                let sampled=bytes(im)
                if tailOnly {
                    let tailContext=bitmap()
                    let bind=art.player.bindWorld[tailBone]
                    tailContext.concatenate(CGAffineTransform(translationX:-bind.x,y:-bind.y).concatenating(art.player.world[tailBone]))
                    tailContext.draw(completeTail,in:CGRect(x:0,y:0,width:384,height:512))
                    let isolated=bytes(tailContext.makeImage()!)
                    if frame != 0 && frame != 30 {
                        for p in 0..<(384*512) where Int(sampled[p*4+3])+1 < Int(isolated[p*4+3]) {erasedTailSamples+=1}
                    }
                    for p in 0..<(384*235) where (0..<4).contains(where:{sampled[p*4+$0] != reference[p*4+$0]}) {headChangesDuringTail+=1}
                }
                for p in tailProbes where bald && (0..<4).contains(where:{sampled[p*4+$0] != reference[p*4+$0]}) {tailChanges+=1}
                c.setFillColor(CGColor(gray:0.85,alpha:1));c.fill(CGRect(x:0,y:0,width:384,height:512))
                c.draw(im,in:CGRect(x:0,y:0,width:384,height:512))
                let opaque=c.makeImage()!
                CGImageDestinationAddImage(gif,opaque,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
                if frame==15 || frame==45 {
                    let png=CGImageDestinationCreateWithURL(out.appendingPathComponent("\(name)-\(frame).png") as CFURL,UTType.png.identifier as CFString,1,nil)!
                    CGImageDestinationAddImage(png,opaque,nil);precondition(CGImageDestinationFinalize(png))
                }
            }
            precondition(CGImageDestinationFinalize(gif))
            guard art.resourceReads==reads && art.decodedImages==decodes && art.compositeBuilds==builds else {
                throw CutoutError.invalid("Animation tick performed resource IO or decoding")
            }
            phases.append(["variant":name,"frames":60,"drawOperations":art.drawOperations-operations,"tickCompositeBuilds":art.compositeBuilds-builds,"decodedBytes":art.decodedBytes,"tickFileReads":art.resourceReads-reads,"tickDecodes":art.decodedImages-decodes,"previewExportSeconds":Date().timeIntervalSince(start)])
        }
        guard maximumHandContactError<1e-8 else {throw CutoutError.invalid("Hand contact drifted: \(maximumHandContactError)")}
        guard erasedTailSamples==0 else {throw CutoutError.invalid("Composite erased moving tail coverage: \(erasedTailSamples)")}
        guard headChangesDuringTail==0 else {throw CutoutError.invalid("Tail motion changed head pixels: \(headChangesDuringTail)")}
        guard tailChanges==0 else {throw CutoutError.invalid("Head motion changed tail pixels: \(tailChanges)")}
        let report:[String:Any]=["maximumHandContactError":maximumHandContactError,"erasedTailSamples":erasedTailSamples,"headChangesDuringTail":headChangesDuringTail,"tailProbeScope":"Hair hidden to remove changing occlusion; full eroded tail mask during head motion", "tailProbePixels":tailProbes.count,"tailChangedSamples":tailChanges,"neutralDifferentPixels":differences,"renderer":"actual CutoutArtwork and CutoutPlayer","phases":phases,"visualAcceptance":false,"visualFindings":["Missing rear-hair hidden surfaces expose gaps against the body","Side-hair roots expose seams when independently rotated","Hand contact is constrained; arm seam and occlusion art remain pending"],"scope":"Controlled head/hair diagnostic only; not native app or complete motion migration"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("motion-checks.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
