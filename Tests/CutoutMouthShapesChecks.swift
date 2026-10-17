import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutMouthShapesChecks {
    static func main() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out=root.appendingPathComponent(ProcessInfo.processInfo.environment["CAPTIONS_MOUTH_SHAPES_OUTPUT"] ?? ".build/cutout/mouth-validation")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let definition=try CutoutCharacter.load(root.appendingPathComponent("Sources/CodexCaptions/Resources/CutoutCharacters/deepseek-cutout.json"))
        let oldDefinition=definition
        var legacyRig=definition.cutout!
        legacyRig.mouthShapes=nil
        let formal=root.appendingPathComponent("Sources/CodexCaptions/Resources/DeepSeekCutout")
        let start=ProcessInfo.processInfo.systemUptime
        let art=try CutoutArtwork(rig:definition.cutout!) {formal.appendingPathComponent($0)}
        let cold=ProcessInfo.processInfo.systemUptime-start
        let old=try CutoutArtwork(rig:legacyRig) {formal.appendingPathComponent($0)}
        let candidate=try CutoutArtwork(rig:definition.cutout!) {formal.appendingPathComponent($0)}
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        func context(_ w:Int=1024,_ h:Int=1024)->CGContext {
            CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        func check(_ ok:Bool,_ label:String)throws {if !ok {throw CutoutError.invalid(label)}}
        func draw(_ a:CutoutArtwork,amount:Double=0,shape:String?=nil,blink:Double=0)->CGImage {
            let c=context();a.draw(in:c,anchor:CGPoint(x:512,y:0),scale:1/a.rig.pointsPerPixel,blink:blink,mouth:amount,mouthShape:shape)
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
        let r=definition.cutout!.variants.flatMap(\.attachments).first{$0.slot=="mouth"}!.rect
        let shapeIDs=definition.cutout!.mouthShapes!.map(\.id)
        let reads=art.resourceReads,decodes=art.decodedImages,builds=art.compositeBuilds
        var samples=0,zeroCases=0,fullImages=[CGImage](), hashes=Set<Data>()
        for clip in ["thinking","thinking-classic"] {
            for phase in [0.0,0.18,0.58] {
                for a in [art,old] {a.player.play(clip,at:0,transition:0);a.player.sample(at:phase*a.player.clips.first{$0.definition.id==clip}!.definition.duration,gaze:CGPoint(x:0.6,y:-0.3))}
                let base=bytes(draw(art,blink:0.5))
                try check(base==bytes(draw(old,blink:0.5)),"Existing neutral changed")
                let head=art.player.indices["head"]!,bind=art.player.bindWorld[head]
                let mask=context();mask.setFillColor(CGColor(gray:1,alpha:1))
                mask.translateBy(x:512-art.rig.anchor[0],y:-art.rig.anchor[1]);mask.concatenate(art.player.world[head])
                mask.fill(CGRect(x:r[0]-bind.x,y:r[1]-bind.y,width:r[2],height:r[3]).insetBy(dx:-2,dy:-2))
                let allowed=bytes(mask.makeImage()!)
                for id in shapeIDs {
                    try check(base==bytes(draw(art,shape:id,blink:0.5)),"Closed \(id) mouth changed neutral")
                    zeroCases += 1
                    for step in 1...8 {
                        let result=bytes(draw(art,amount:Double(step)/8,shape:id,blink:0.5))
                        for p in 0..<(1024*1024) where allowed[p*4+3]==0 {
                            let k=p*4
                            try check(result[k...k+3].elementsEqual(base[k...k+3]),"\(id) edited pixels outside transformed mouth envelope")
                        }
                        samples += 1
                    }
                }
            }
        }
        art.player.play("idle",at:0,transition:0);art.player.sample(at:0)
        old.player.play("idle",at:0,transition:0);old.player.sample(at:0)
        if oldDefinition.cutout?.mouthShapes?.contains(where:{$0.id=="smile"}) == true {
            save(draw(old,amount:1,shape:"smile"),"baseline-smile.png")
        }
        for amount in [0.0,0.5,1.0] {
            try check(bytes(draw(art,amount:amount))==bytes(draw(old,amount:amount)),"Legacy opening changed")
        }
        let neutral=draw(art);save(neutral,"neutral.png")
        for id in shapeIDs {
            let image=draw(art,amount:1,shape:id);save(image,"mouth-"+id+".png")
            try check(hashes.insert(Data(bytes(image))).inserted,"Mouth contours are identical")
            fullImages.append(image)
        }
        let sheet=context(256*4,256*2)
        for (i,image) in fullImages.enumerated() {
            let crop=image.cropping(to:CGRect(x:330,y:310,width:280,height:220))!
            sheet.draw(crop,in:CGRect(x:(i%4)*256,y:(1-i/4)*256,width:256,height:256))
        }
        save(sheet.makeImage()!,"mouth-contact-sheet.png")
        let inputs=definition.cutoutPlayback!
        for index in 0..<12 {
            let input=inputs.mouthInput(for:index)
            try check(input.openness==inputs.mouthOpenness[index],"Audio opening mapping changed")
            if input.openness>0 {try check(input.shape != nil,"Voiced input has no mouth contour")}
        }
        for index in [nil,-1,12] {
            let input=inputs.mouthInput(for:index);try check(input.openness==0 && input.shape==nil,"Invalid/silent input did not reset")
        }
        for i in 0..<180 {
            let input=inputs.mouthInput(for:i%12)
            art.player.sample(at:Double(i)/30,gaze:CGPoint(x:0.4,y:0.1))
            _=draw(art,amount:input.openness,shape:input.shape,blink:Double(i%16)/15)
        }
        try check(art.resourceReads==reads && art.decodedImages==decodes && art.compositeBuilds==builds,"Changing mouth shapes performs tick I/O or atlas building")
        try check(art.decodedBytes<24*1024*1024 && candidate.decodedBytes<24*1024*1024,"New mouth forms exceed cache budget")
        var invalid=definition.cutout!
        invalid.mouthShapes![0].forms[0]="../outside.png"
        do {_ = try invalid.validated();throw CutoutError.invalid("Unsafe mouth path accepted")} catch CutoutError.invalid(let message) {try check(message != "Unsafe mouth path accepted",message)}
        // Alternate the same input and native-size drawing target to reduce
        // order/warmup bias; this measures the renderer, not whole-app CPU.
        var oldTimes=[Double](),newTimes=[Double](),namedTimes=[Double]()
        let native=context(256,384)
        for i in 0..<240 {
            for a in [old,art] {
                native.clear(CGRect(x:0,y:0,width:256,height:384))
                let t=ProcessInfo.processInfo.systemUptime
                a.draw(in:native,anchor:CGPoint(x:128,y:16),scale:1,blink:Double(i%16)/15,mouth:Double(i%16)/15)
                if i>=20 {
                    let elapsed=ProcessInfo.processInfo.systemUptime-t
                    if a === old {oldTimes.append(elapsed)} else {newTimes.append(elapsed)}
                }
            }
            native.clear(CGRect(x:0,y:0,width:256,height:384))
            let t=ProcessInfo.processInfo.systemUptime
            art.draw(in:native,anchor:CGPoint(x:128,y:16),scale:1,blink:Double(i%16)/15,
                mouth:Double(i%16)/15,mouthShape:shapeIDs[i%shapeIDs.count])
            if i>=20 {namedTimes.append(ProcessInfo.processInfo.systemUptime-t)}
        }
        func p95(_ values:[Double])->Double {values.sorted()[Int(Double(values.count-1)*0.95)]*1000}
        let performance:[String:Any] = ["samplesPerMode":220,"targetPixels":[256,384],
            "baselineP95Milliseconds":p95(oldTimes),"legacyWithAddedShapesP95Milliseconds":p95(newTimes),
            "namedShapesP95Milliseconds":p95(namedTimes),"scope":"Alternating actual renderer on the same inputs; does not replace native whole-app CPU"]
        try JSONSerialization.data(withJSONObject:performance,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("renderer-performance.json"))
        let report:[String:Any]=["passed":true,"shapes":shapeIDs,"openingSamples":samples,"neutralExactCases":zeroCases,
            "outsideMouthEnvelopeChangedPixels":0,"audioInputCases":12,"tickSamples":180,
            "tickReads":art.resourceReads-reads,"tickDecodes":art.decodedImages-decodes,"tickAtlasBuilds":art.compositeBuilds-builds,
            "baselineDecodedBytes":old.decodedBytes,"decodedBytes":art.decodedBytes,"twinCandidateDecodedBytes":candidate.decodedBytes,
            "coldLoadSeconds":cold,"elapsedSeconds":ProcessInfo.processInfo.systemUptime-start,
            "boundary":"Actual renderer, two thinking clips and independent blink/gaze; native application checked separately"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print("PASS mouth shapes: 8 contours, \(samples) scoped renders, \(zeroCases) exact neutral cases, 12 audio inputs and zero tick I/O")
    }
}
