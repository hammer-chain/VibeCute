import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutThinkingSyncChecks {
    static func main() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath),out=root.appendingPathComponent("output/cutout-thinking-sync")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        func require(_ value:Bool,_ message:String)throws {if !value {throw CutoutError.invalid(message)}}
        let base=root.appendingPathComponent("Sources/CodexCaptions/Resources")
        let character=try CutoutCharacter.load(base.appendingPathComponent("CutoutCharacters/deepseek-cutout.json"))
        let rig=character.cutout!,resources=base.appendingPathComponent(character.resourceDirectory)
        let art=try CutoutArtwork(rig:rig){resources.appendingPathComponent($0)},player=art.player
        // Read the actual, unchanged pixel renderer's sequence and tick interval.
        let source=try String(contentsOf:root.appendingPathComponent("Sources/CodexCaptions/MascotAnimation.swift"),encoding:.utf8)
        let regex=try NSRegularExpression(pattern:#"static let sequence = \[([^\]]+)\]"#)
        let match=regex.firstMatch(in:source,range:NSRange(source.startIndex...,in:source))!
        let range=Range(match.range(at:1),in:source)!
        let sequence=source[range].split(separator:",").map{Int($0.trimmingCharacters(in:.whitespaces))!}
        let overlay=try String(contentsOf:root.appendingPathComponent("Sources/CodexCaptions/OverlayPanel.swift"),encoding:.utf8)
        try require(overlay.contains("Timer(timeInterval: 0.16, repeats: true)"),"Pixel cadence changed; recheck the reference")
        let clip=player.clips.first{$0.definition.id=="thinking-classic"}!
        try require(clip.definition.interpolation == .step && clip.definition.referenceFrames==sequence,"Thinking cadence differs from actual pixel sequence")
        try require(clip.definition.frameDurations==Array(repeating:0.16,count:sequence.count) && clip.duration==2.88,"Pixel beat/period mismatch")
        let expectedBlink=[0.0,0,0,0.7,1,0,0,0]
        player.play("thinking-classic",at:0,transition:0)
        let reads=art.resourceReads,decodes=art.decodedImages,bytes=art.decodedBytes
        var samples=0
        for cycle in [0,1,9,99,999] {
            for (index,frame) in sequence.enumerated() {
                let start=Double(cycle)*2.88+Double(index)*0.16
                player.sample(at:start+0.001);let pose=player.world
                for offset in [0.001,0.04,0.08,0.12,0.159999] {
                    let t=start+offset;player.sample(at:t)
                    try require(player.world.indices.filter { $0 != player.indices["hair-return"]! }.allSatisfy { player.world[$0]==pose[$0] },"Head/body moves during pixel hold")
                    try require(clip.referenceFrame(at:t)==frame,"Source frame drift at cycle \(cycle), step \(index)")
                    try require(player.automaticBlink(at:t,fallback:0.4)==expectedBlink[frame],"Blink rhythm mismatch")
                    samples+=1
                }
            }
        }
        // Both sides of every switching boundary, including the loop seam.
        for i in 1...180 {
            let boundary=Double(i)*0.16
            try require(clip.referenceFrame(at:boundary-1e-6)==sequence[(i-1)%18],"Pose advanced early")
            try require(clip.referenceFrame(at:boundary+1e-6)==sequence[i%18],"Pose advanced late")
        }
        try require(reads==art.resourceReads && decodes==art.decodedImages,"Cadence sampling prepared resources")
        // Same native layout and floor as the app, with original frame pixels.
        let atlas=try CutoutPixels.load(base.appendingPathComponent("DeepSeekThinking/thinking-atlas.png"))
        let tiles=(0..<8).map {atlas.cropping(to:CGRect(x:($0%4)*384,y:($0/4)*512,width:384,height:512))!}
        let width=600,height=230
        func bitmap(_ w:Int,_ h:Int)->CGContext {CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!}
        let context=bitmap(width,height)
        // Once upright, the head/body stay fixed while a leaf control bends hair.
        player.sample(at:1.76);let upright=player.world
        for t in stride(from:1.6,through:2.879,by:0.01) {
            player.sample(at:t)
            for name in ["root","torso","head","arm-right","right-elbow","right-wrist"] {
                let i=player.indices[name]!
                try require(player.world[i]==upright[i],"Hair recovery moved \(name)")
            }
        }
        for patch in art.hairPatches.values {
            try require(patch.offset(at:patch.root,amount:1)==0,"Hair root is not pinned")
            try require(abs(patch.offset(at:patch.tip,amount:1)-patch.definition.maxOffset)<1e-9,"Hair tip amplitude missing")
            let quarter=patch.root+(patch.tip-patch.root)*0.25
            try require(abs(patch.offset(at:quarter,amount:1)-patch.definition.maxOffset*0.25)>0.01,"Hair only shears rigidly; nonlinear bend missing")
            if patch.root>patch.levels.first! && patch.root<patch.levels.last! {
                try require(patch.levels.contains(patch.root),"Pinned root must be an exact mesh boundary")
            }
        }
        func sourcePixels(_ t:Double)throws->CutoutPixels {
            player.sample(at:t);let c=bitmap(1024,1024)
            art.draw(in:c,anchor:CGPoint(x:rig.anchor[0],y:rig.anchor[1]),scale:1/rig.pointsPerPixel)
            return try CutoutPixels(c.makeImage()!)
        }
        let hairA=try sourcePixels(1.76),hairB=try sourcePixels(1.92)
        try require(hairA.rgba != hairB.rgba,"Independent hair deformation did not change pixels")
        try art.select(["hair":"hair-none"])
        try require(try sourcePixels(1.76).rgba==sourcePixels(1.92).rgba,"Without hair, recovery still moves the head/body pixels")
        try art.select(rig.defaults)
        let settledReads=art.resourceReads,settledDecodes=art.decodedImages
        func render(_ t:Double)->CGImage {
            context.setFillColor(NSColor(calibratedWhite:0.94,alpha:1).cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
            let frame=sequence[min(17,Int((t.truncatingRemainder(dividingBy:2.88)+1e-9)/0.16))]
            context.draw(tiles[frame],in:CGRect(x:150-63,y:20,width:126,height:168))
            player.sample(at:t)
            art.draw(in:context,anchor:CGPoint(x:450,y:20),blink:player.automaticBlink(at:t,fallback:0))
            context.setStrokeColor(NSColor.gray.cgColor);context.setLineWidth(0.5)
            context.move(to:CGPoint(x:40,y:20));context.addLine(to:CGPoint(x:560,y:20));context.strokePath()
            return context.makeImage()!
        }
        player.play("thinking-classic",at:0,transition:0)
        let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent("thinking-side-by-side.gif") as CFURL,UTType.gif.identifier as CFString,72,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<72 {CGImageDestinationAddImage(gif,render(Double(i)*0.04),[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)}
        try require(CGImageDestinationFinalize(gif),"Cannot export side-by-side native GIF")
        let sheet=bitmap(width*3,height*3)
        for (i,t) in [0.0,0.8,1.12,1.44,1.60,1.76,1.92,2.24,2.88].enumerated() {
            sheet.draw(render(t),in:CGRect(x:(i%3)*width,y:(2-i/3)*height,width:width,height:height))
        }
        let png=CGImageDestinationCreateWithURL(out.appendingPathComponent("contact.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(png,sheet.makeImage()!,nil);try require(CGImageDestinationFinalize(png),"Cannot export contact sheet")
        var hot=[Double]()
        for i in 0..<1032 {
            let t=Double(i)/30,start=ProcessInfo.processInfo.systemUptime
            player.sample(at:t);context.clear(CGRect(x:0,y:0,width:width,height:height))
            art.draw(in:context,anchor:CGPoint(x:300,y:20),blink:player.automaticBlink(at:t,fallback:0))
            if i>=32 {hot.append(ProcessInfo.processInfo.systemUptime-start)}
        }
        let p95=hot.sorted()[Int(Double(hot.count-1)*0.95)]
        try require(p95<0.004,"Cutout thinking sampling/drawing exceeds 4ms")
        try require(settledReads==art.resourceReads && settledDecodes==art.decodedImages && bytes==art.decodedBytes,"Thinking cadence added texture preparation")
        let report:[String:Any]=["samples":samples,"boundaries":180,"cyclesChecked":[0,1,9,99,999],"sequence":sequence,"beatSeconds":0.16,"periodSeconds":clip.duration,"drawP95Seconds":p95,"decodedBytes":bytes,"tickReads":art.resourceReads-settledReads,"tickDecodes":art.decodedImages-settledDecodes,"headFixedAfterSeconds":1.6,"hairNonlinearDeformation":true,"hairlessPixelsUnchanged":true]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print("PASS thinking cadence",report)
    }
}
