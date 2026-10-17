import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutPSDFaceChecks {
    static func main() {do {try run()} catch {fputs("FAIL: \(error)\n",stderr);exit(1)}}
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let source=root.appendingPathComponent("output/cutout/see-through-arm-v1")
        let out=root.appendingPathComponent("output/cutout/see-through-face-v1")
        func check(_ value:Bool,_ message:String)throws {if !value {throw CutoutError.invalid(message)}}
        func load(_ directory:URL,_ file:String)throws->CutoutArtwork {
            let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:directory.appendingPathComponent(file)))
            return try CutoutArtwork(rig:rig){directory.appendingPathComponent($0)}
        }
        let start=ProcessInfo.processInfo.systemUptime
        let art=try load(out,"face-rig.json"),cold=ProcessInfo.processInfo.systemUptime-start
        var oldRig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:source.appendingPathComponent("arm-rig.json")))
        oldRig.gazeRange=art.rig.gazeRange
        let old=try CutoutArtwork(rig:oldRig){source.appendingPathComponent($0)},space=CGColorSpace(name:CGColorSpace.sRGB)!
        func context(_ w:Int=1024,_ h:Int=1024)->CGContext {
            CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        func render(_ a:CutoutArtwork,_ blink:Double=0,_ mouth:Double=0)->CGImage {
            let c=context();a.draw(in:c,anchor:CGPoint(x:512,y:0),scale:1/a.rig.pointsPerPixel,blink:blink,mouth:mouth)
            return c.makeImage()!
        }
        func bytes(_ im:CGImage)->[UInt8] {
            let c=context();c.draw(im,in:CGRect(x:0,y:0,width:1024,height:1024))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:1024*1024*4))
        }
        func save(_ im:CGImage,_ name:String) {
            let dest=CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(dest,im,nil);precondition(CGImageDestinationFinalize(dest))
        }
        old.player.play("idle",at:0,transition:0);art.player.play("idle",at:0,transition:0)
        let neutral=render(art),base=bytes(neutral)
        try check(base==bytes(render(old)),"Adding face controls changes the original neutral")
        save(neutral,"neutral.png")
        let features:Set<String>=["eyewhite-r","eyewhite-l","irides-r","irides-l","eyelash-r","eyelash-l","mouth"]
        let attachments=art.rig.variants.flatMap(\.attachments).filter{features.contains($0.slot)}
        func allowed()->[UInt8] {
            let c=context();c.setFillColor(CGColor(gray:1,alpha:1))
            for a in attachments {
                // All feature envelopes move with the head, not with the iris.
                let head=art.player.indices["head"]!,p=art.player.bindWorld[head]
                let r=a.rect,rect=CGRect(x:r[0]-p.x,y:r[1]-p.y,width:r[2],height:r[3]).insetBy(dx:-2,dy:-2)
                c.saveGState();c.concatenate(art.player.world[head]);c.fill(rect);c.restoreGState()
            }
            return bytes(c.makeImage()!)
        }
        func outsideChanges(_ a:[UInt8],_ b:[UInt8],_ mask:[UInt8])->Int {
            var count=0
            for p in 0..<(1024*1024) where mask[p*4+3]==0 {
                let k=p*4;if a[k] != b[k] || a[k+1] != b[k+1] || a[k+2] != b[k+2] || a[k+3] != b[k+3] {count+=1}
            }
            return count
        }
        // The complete blink/mouth cross-product catches channel interference.
        let mask=allowed();var combinations=0
        for b in 0...15 {for m in 0...15 {
            let pixels=bytes(render(art,Double(b)/15,Double(m)/15))
            try check(outsideChanges(base,pixels,mask)==0,"Face form modifies protected body/face pixels")
            combinations+=1
        }}
        // Removing the iris must be visually irrelevant when fully closed,
        // including a moving head and extreme gaze directions.
        var noIrisRig=art.rig
        let iris:Set<String>=["irides-r","irides-l"]
        noIrisRig.slots.removeAll{iris.contains($0.id)};noIrisRig.eyeClips=[]
        for i in noIrisRig.variants.indices {noIrisRig.variants[i].attachments.removeAll{iris.contains($0.slot)}}
        let noIris=try CutoutArtwork(rig:noIrisRig){out.appendingPathComponent($0)}
        var closedCases=0,posedCases=0
        for phase in [0.0,1.0,3.0] {
            for gaze in [CGPoint(x:-1,y:0),CGPoint(x:1,y:0),CGPoint(x:0,y:1),CGPoint(x:0,y:-1),.zero] {
                art.player.play("head-sway",at:0,transition:0);art.player.sample(at:phase,gaze:gaze)
                noIris.player.play("head-sway",at:0,transition:0);noIris.player.sample(at:phase,gaze:gaze)
                try check(bytes(render(art,1,1))==bytes(render(noIris,1,1)),"Closed lids still show an iris")
                closedCases+=1
                let posedNeutral=bytes(render(art)),posedMask=allowed()
                for b in [0.0,0.5,1.0] {for m in [0.0,0.5,1.0] {
                    try check(outsideChanges(posedNeutral,bytes(render(art,b,m)),posedMask)==0,"Posed face changes leave local envelopes")
                    posedCases+=1
                }}
            }
        }
        art.player.play("idle",at:0,transition:0)
        for (name,b,m,gaze) in [("half",0.5,0.5,CGPoint.zero),("closed",1.0,0.0,.zero),
                                ("open-mouth",0.0,1.0,.zero),("look-left",0.0,0.0,CGPoint(x:-1,y:0)),
                                ("look-right",0.0,0.0,CGPoint(x:1,y:0))] {
            art.player.sample(at:0,gaze:gaze);save(render(art,b,m),name+".png")
        }
        let reads=art.resourceReads,decodes=art.decodedImages,masks=art.eyeMaskImagesBuilt
        let started=art.player.startedAt,clip=art.player.clipIndex
        try art.select(["hair":"hair-none","tail":"tail-none"])
        try check(art.eyeMaskImagesBuilt==masks && art.player.startedAt==started && art.player.clipIndex==clip,"Appearance selection rebuilds eyes or restarts body")
        try art.select(art.rig.defaults)
        try check(art.eyeMaskImagesBuilt==masks,"Restoring unrelated components rebuilds face masks")
        var invalid=art.rig;invalid.eyeClips![0].closing = .nan
        do {_ = try invalid.validated();throw CutoutError.invalid("Nonfinite eye registration was accepted")} catch CutoutError.invalid(let message) {
            try check(message != "Nonfinite eye registration was accepted","Nonfinite eye registration was accepted")
        }
        invalid=art.rig;invalid.expressions!["mouth"]!.append("expressions/mouth/frame-15.png")
        do {_ = try invalid.validated();throw CutoutError.invalid("Oversized expression atlas was accepted")} catch CutoutError.invalid(let message) {
            try check(message != "Oversized expression atlas was accepted","Oversized expression atlas was accepted")
        }
        let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent("face-motion.gif") as CFURL,UTType.gif.identifier as CFString,156,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        art.player.play("head-sway",at:0,transition:0)
        let tickReads=art.resourceReads,tickDecodes=art.decodedImages
        for f in 0..<156 {
            let t=Double(f)/30,gaze=CGPoint(x:sin(t*2*Double.pi/5.2),y:0.45*sin(t*2*Double.pi/7.1))
            art.player.sample(at:t,gaze:gaze)
            let im=render(art,CutoutArtwork.blink(at:t),CutoutArtwork.talkingPreview(at:t)),c=context(384,512)
            c.setFillColor(CGColor(gray:0.8,alpha:1));c.fill(CGRect(x:0,y:0,width:384,height:512))
            c.translateBy(x:-64,y:0);c.scaleBy(x:0.5,y:0.5);c.draw(im,in:CGRect(x:0,y:0,width:1024,height:1024))
            CGImageDestinationAddImage(gif,c.makeImage()!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
            if [30,90,105].contains(f) {save(im,"combined-\(f).png")}
        }
        precondition(CGImageDestinationFinalize(gif))
        try check(art.resourceReads==tickReads && art.decodedImages==tickDecodes && art.eyeMaskImagesBuilt==masks,"Face animation prepares images/masks per tick")
        let c=context(300,300)
        old.player.play("head-sway",at:0,transition:0)
        func draw(_ artwork:CutoutArtwork,_ f:Int,_ face:Bool) {
            let t=20+Double(f)/30;artwork.player.sample(at:t,gaze:CGPoint(x:sin(t),y:cos(t)*0.4))
            c.clear(CGRect(x:0,y:0,width:300,height:300))
            artwork.draw(in:c,anchor:CGPoint(x:150,y:0),blink:face ? CutoutArtwork.blink(at:t):0,mouth:face ? CutoutArtwork.talkingPreview(at:t):0)
        }
        for f in 0..<100 {draw(art,f,true);draw(old,f,false)}
        let operations=art.drawOperations,begin=ProcessInfo.processInfo.systemUptime
        var timings=[Double]()
        for f in 0..<1000 {let t=ProcessInfo.processInfo.systemUptime;draw(art,f,true);timings.append(ProcessInfo.processInfo.systemUptime-t)}
        let elapsed=ProcessInfo.processInfo.systemUptime-begin;timings.sort()
        let baselineBegin=ProcessInfo.processInfo.systemUptime
        for f in 0..<1000 {draw(old,f,false)}
        let baselineElapsed=ProcessInfo.processInfo.systemUptime-baselineBegin
        try check(art.resourceReads==tickReads && art.decodedImages==tickDecodes && art.decodedBytes<24*1024*1024,"Face budget or tick I/O failed")
        try check(CutoutArtwork.blink(at:3.5)==1 && CutoutArtwork.blink(at:3.4)==0 && CutoutArtwork.talkingPreview(at:4)==0,"Face scheduling endpoints failed")
        let report:[String:Any]=["neutralChangedPixels":0,"blinkMouthCombinations":combinations,"posedCombinations":posedCases,"closedNoIrisCases":closedCases,
            "localEnvelopeOutsideChangedPixels":0,"parts":art.parts.count,"atlasFiles":art.rig.expressions!.values.reduce(0){$0+$1.count},"eyeMaskImagesBuilt":masks,
            "coldLoadSeconds":cold,"decodedBytes":art.decodedBytes,"baselineDecodedBytes":old.decodedBytes,"baselineSampleAndDraw1000Seconds":baselineElapsed,
            "faceSampleAndDraw1000Seconds":elapsed,"faceSampleAndDrawP95Milliseconds":timings[949]*1000,"drawOperations1000":art.drawOperations-operations,
            "continuousFrames":156,"framesPerSecond":30,"tickReads":0,"tickDecodes":0,"tickMaskBuilds":0,"swapKeepsFaceMasksAndActionPhase":true,
            "initialReads":reads,"initialDecodes":decodes,"input":"Current seated PSD shoulder candidate; blink/gaze/local opening with actual CutoutArtwork",
            "benchmarkComparison":"Same body clip, timestamps, gaze range and trajectory, 300x300 CGContext; local features off/on, sequential single-run timing",
            "invalidFeatureRegistrationsRejected":true,
            "realAudioLipSyncCovered":false,"productionMigrationComplete":false,"originalReferenceFidelityAccepted":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!)
    }
}
