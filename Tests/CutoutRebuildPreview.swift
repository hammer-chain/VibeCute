import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct RebuildPreview {
    static func main() throws {
        let started=Date()
        let out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/cutout/rebuild-v2")
        let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:out.appendingPathComponent("rig.json")))
        let art=try CutoutArtwork(rig:rig) {out.appendingPathComponent($0)}
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        func render()->CGImage {
            let c=CGContext(data:nil,width:384,height:512,bitsPerComponent:8,bytesPerRow:1536,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            art.draw(in:c,anchor:.zero);return c.makeImage()!
        }
        func data(_ im:CGImage)->Data {im.dataProvider!.data! as Data}
        art.player.play("neutral",at:0,transition:0)
        var reports=[[String:Any]]()
        for mode in ["tail-wag","head-sway","bald-head-sway"] {
            let bald=mode=="bald-head-sway",clip=bald ? "head-sway":mode
            try art.select(["hair":bald ? "hair-none":"hair-redrawn","headwear":bald ? "headwear-none":"headwear-redrawn"])
            art.player.play("neutral",at:0,transition:0)
            let baseline=data(render())
            art.player.play(clip,at:0,transition:0)
            let reads=art.resourceReads,decodes=art.decodedImages,builds=art.compositeBuilds
            let dst=CGImageDestinationCreateWithURL(out.appendingPathComponent(mode+".gif") as CFURL,UTType.gif.identifier as CFString,60,nil)!
            CGImageDestinationSetProperties(dst,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            var times=[Double](), changed=0
            for f in 0..<60 {
                let t=Date();art.player.sample(at:Double(f)/30);let im=render();times.append(Date().timeIntervalSince(t)*1000)
                let bytes=data(im)
                // Tail is wholly below this band: moving it cannot change head/hair.
                if clip=="tail-wag" {precondition(bytes.prefix(300*1536)==baseline.prefix(300*1536),"Tail animation changed upper character")}
                if bald {precondition(bytes.suffix(192*1536)==baseline.suffix(192*1536),"Bald head movement changed body or tail")}
                if bytes != baseline {changed+=1}
                if f==15 {
                    let png=CGImageDestinationCreateWithURL(out.appendingPathComponent(mode+"-extreme.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
                    CGImageDestinationAddImage(png,im,nil);precondition(CGImageDestinationFinalize(png))
                }
                CGImageDestinationAddImage(dst,im,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(dst))
            precondition(changed>30)
            precondition(art.resourceReads==reads && art.decodedImages==decodes && art.compositeBuilds==builds)
            times.sort()
            reports.append(["clip":mode,"frames":60,"p95RenderMilliseconds":times[56],"tickReads":0,"tickDecodes":0,"tickCompositeBuilds":0,"decodedBytes":art.decodedBytes])
        }
        try art.select(["hair":"hair-redrawn","headwear":"headwear-redrawn"])
        art.player.play("head-sway",at:0,transition:0)
        var displayTimes=[Double]()
        let displayReads=art.resourceReads,displayDecodes=art.decodedImages
        for f in 0..<240 {
            let t=Date()
            let c=CGContext(data:nil,width:126,height:168,bitsPerComponent:8,bytesPerRow:504,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.scaleBy(x:126.0/384,y:168.0/512)
            art.player.sample(at:Double(f)/30);art.draw(in:c,anchor:.zero)
            displayTimes.append(Date().timeIntervalSince(t)*1000)
        }
        precondition(art.resourceReads==displayReads && art.decodedImages==displayDecodes)
        displayTimes.sort()
        let display:[String:Any] = ["size":[126,168],"frames":240,"p95RenderMilliseconds":displayTimes[227],"decodedBytes":art.decodedBytes,"scope":"Offscreen CoreGraphics, not native app CPU/GPU"]
        try JSONSerialization.data(withJSONObject:["phases":reports,"displayBenchmark":display,"totalSeconds":Date().timeIntervalSince(started),"visualAccepted":false,"nativeValidated":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print("PASS: 180 frames; independent head/tail pixel checks; no tick IO/decode/build. Visual and native acceptance separate.")
    }
}
