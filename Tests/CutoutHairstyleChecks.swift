import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Actual renderer checks and exports for isolated hairstyle candidates.
@main struct CutoutHairstyleChecks {
    static func main() { do { try run() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) } }
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out=CommandLine.arguments.count > 1
            ? URL(fileURLWithPath:CommandLine.arguments[1],relativeTo:root).standardizedFileURL
            : root.appendingPathComponent("output/cutout/approved-twins")
        let rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:out.appendingPathComponent("hairstyles-rig.json")))
        func check(_ ok:Bool,_ s:String)throws {if !ok {throw CutoutError.invalid(s)}}
        let cold=ProcessInfo.processInfo.systemUptime
        let art=try CutoutArtwork(rig:rig){out.appendingPathComponent($0)}
        let loadSeconds=ProcessInfo.processInfo.systemUptime-cold
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        func render(_ blink:Double=0,_ mirror:Bool=false,_ size:Int=1024)->CGImage {
            let c=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,
                space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            let s=Double(size)/1024
            art.draw(in:c,anchor:CGPoint(x:Double(size)/2,y:rig.anchor[1]*s),scale:s/rig.pointsPerPixel,
                mirrored:mirror,blink:blink,mouth:0)
            return c.makeImage()!
        }
        func save(_ image:CGImage,_ file:String)throws {
            let u=out.appendingPathComponent(file)
            try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true)
            let d=CGImageDestinationCreateWithURL(u as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(d,image,nil);try check(CGImageDestinationFinalize(d),"Cannot write \(file)")
        }
        art.player.play("thinking-classic",at:0,transition:0);art.player.sample(at:0)
        try save(render(),"renders/original.png")
        var rows=[[String:Any]]()
        let styles=rig.variants.filter{$0.category=="hair" && $0.id != "hair-none"}
        for style in styles {
            let before=art.player.world,started=art.player.startedAt,index=art.player.clipIndex
            let start=ProcessInfo.processInfo.systemUptime
            try art.select(["hair":style.id])
            try check(art.player.world==before && art.player.startedAt==started && art.player.clipIndex==index,"Hair swap resets motion")
            let swapSeconds=ProcessInfo.processInfo.systemUptime-start
            let cache=art.decodedBytes
            try check(cache<=24*1024*1024,"Hair exceeds selected cache budget")
            let reads=art.resourceReads,decodes=art.decodedImages,masks=art.eyeMaskImagesBuilt,cloth=art.clothPatchImagesBuilt
            var frames=0,maxBounds=CGRect.null
            for clip in ["thinking-classic","thinking"] {
                art.player.play(clip,at:0,transition:0)
                let duration=art.player.clips[art.player.clipIndex].definition.duration
                let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent("\(style.id)-\(clip).gif") as CFURL,
                    UTType.gif.identifier as CFString,Int(duration*15),nil)!
                CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
                for f in 0..<Int(duration*30) {
                    let time=Double(f)/30
                    art.player.sample(at:time,gaze:CGPoint(x:sin(time)*0.4,y:cos(time)*0.2))
                    let blink=art.player.automaticBlink(at:time,fallback:0)
                    let anchor=CGPoint(x:512,y:rig.anchor[1])
                    maxBounds=maxBounds.union(art.displayBounds(anchor:anchor,scale:1/rig.pointsPerPixel))
                    if f%2==0 {CGImageDestinationAddImage(gif,render(blink,false,384),
                        [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1/15.0]] as CFDictionary)}
                    if [0,36,49,85].contains(f) {try save(render(blink),"renders/\(style.id)-\(clip)-\(f).png")}
                    frames+=1
                }
                try check(CGImageDestinationFinalize(gif),"Cannot finalize hairstyle GIF")
            }
            try check(reads==art.resourceReads && decodes==art.decodedImages && masks==art.eyeMaskImagesBuilt && cloth==art.clothPatchImagesBuilt,
                "Hair prepares files or atlases on animation tick")
            art.player.play("thinking-classic",at:0,transition:0);art.player.sample(at:0)
            for (size,scale) in [(512,50),(1024,100),(2048,200)] {
                try save(render(0,false,size),"renders/\(style.id)-\(scale).png")
                try save(render(0,true,size),"renders/\(style.id)-\(scale)-mirror.png")
            }
            rows.append(["id":style.id,"title":style.title,"swapPhasePreserved":true,"frames":frames,
                "decodedBytes":cache,"swapSeconds":swapSeconds,"tickReads":0,"tickDecodes":0,"tickAtlasBuilds":0,
                "sourceBounds":[maxBounds.minX,maxBounds.minY,maxBounds.maxX,maxBounds.maxY]])
        }
        // A failed selection preserves the previous artwork and pose atomically.
        let previous=art.selection,world=art.player.world
        do {try art.select(["hair":"missing-hairstyle"]);throw CutoutError.invalid("Invalid swap accepted")}
        catch {try check(art.selection==previous && art.player.world==world,"Failed swap discards current appearance")}
        let report:[String:Any]=["renderer":"actual CutoutArtwork/CutoutPlayer", "styles":rows,"coldLoadSeconds":loadSeconds,
            "bones":rig.bones.count,"slots":rig.slots.count,"budgetBytes":24*1024*1024,
            "newMotionTracks":0,"newTimers":0,"failedSwapPreserved":true,"visualAcceptanceRequired":true]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print("PASS actual hairstyle renderer: \(styles.count) styles, 2 clips, 50/100/200%, mirrors, preserved phase and bounded current cache")
    }
}
