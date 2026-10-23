import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutPlaybackChecks {
    static func main() throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out = root.appendingPathComponent("output/cutout-playback")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let base = root.appendingPathComponent("Sources/CodexCaptions/Resources")
        let character = try CutoutCharacter.load(base.appendingPathComponent("CutoutCharacters/deepseek-cutout.json"))
        let rig = character.cutout!, resources = base.appendingPathComponent(character.resourceDirectory)
        let motions = try JSONDecoder().decode(CutoutMotionLibrary.self,from:Data(contentsOf:resources.appendingPathComponent(rig.motions)))
        func require(_ condition:Bool,_ message:String) throws { if !condition { throw CutoutError.invalid(message) } }
        func rejects(_ label:String,_ body:() throws -> Void) throws {
            var rejected = false
            do { try body() } catch CutoutError.invalid { rejected = true }
            try require(rejected,"Accepted invalid \(label)")
        }
        let coldStart = ProcessInfo.processInfo.systemUptime
        let art = try CutoutArtwork(rig:rig) { resources.appendingPathComponent($0) }
        let cold = ProcessInfo.processInfo.systemUptime-coldStart
        let player = art.player
        // The new declarations retain every original authored pose and lid time.
        var legacy = motions; legacy.poses = nil; legacy.clips.removeAll { $0.id == "tail-wag-once" }
        for i in legacy.clips.indices {
            legacy.clips[i].frameDurations = nil; legacy.clips[i].startPose = nil; legacy.clips[i].endPose = nil
        }
        let reference = try CutoutPlayer(rig:rig,motions:legacy)
        var originalSamples = 0
        for clip in reference.clips {
            player.play(clip.definition.id,at:0,transition:0); reference.play(clip.definition.id,at:0,transition:0)
            for i in 0...240 {
                let t = Double(i)*clip.duration/120
                player.sample(at:t); reference.sample(at:t)
                try require(player.world == reference.world,"Original body timing changed: \(clip.definition.id)")
                try require(player.automaticBlink(at:t,fallback:0.3) == reference.automaticBlink(at:t,fallback:0.3),"Original lid timing changed")
                originalSamples += 1
            }
        }
        // Retimed one-shot preserves each authored pose, with unequal interval durations.
        player.play("tail-wag-once",at:0,transition:0); reference.play("tail-wag",at:0,transition:0)
        for (t,source) in [(0.0,0.0),(0.15,0.5),(0.3,1.0),(0.55,1.5),(0.8,2.0),(1.15,2.5),(1.5,3.0),(1.75,3.5)] {
            player.sample(at:t); reference.sample(at:source)
            for (a,b) in zip(player.local,reference.local) {
                try require(abs(a.rotation-b.rotation)<1e-9 && abs(a.x-b.x)<1e-9 && abs(a.y-b.y)<1e-9,"Frame durations did not retime the pose")
            }
        }
        player.sample(at:2)
        try require(player.clips[player.clipIndex].definition.id == "idle" && player.startedAt == 2,"Fallback missed its exact boundary")
        player.play("tail-wag-once",at:0,transition:0); _ = player.automaticBlink(at:22.4,fallback:0)
        player.sample(at:22.4)
        try require(player.clips[player.clipIndex].definition.id == "idle" && player.startedAt == 2,"Late tick lost fallback elapsed time")
        player.play("tail-wag-once",at:0,transition:0); player.seek(to:2,at:8)
        _ = player.automaticBlink(at:8,fallback:0); player.sample(at:8)
        try require(player.clips[player.clipIndex].definition.id == "tail-wag-once","Paused endpoint cannot be inspected")
        player.sample(at:8.01)
        try require(player.clips[player.clipIndex].definition.id == "idle","Resume did not leave inspected endpoint")
        var hold = motions; hold.clips[hold.clips.count-1].fallback = nil
        let held = try CutoutPlayer(rig:rig,motions:hold)
        held.play("tail-wag-once",at:0,transition:0);held.sample(at:20)
        try require(held.clips[held.clipIndex].definition.id == "tail-wag-once","Missing fallback must hold final pose")
        var slower = motions
        let classic = slower.clips.firstIndex { $0.id == "thinking-classic" }!
        slower.clips[classic].frameDurations = slower.clips[classic].frameDurations!.map { $0*2 }
        let retimed = try CutoutPlayer(rig:rig,motions:slower)
        retimed.play("thinking-classic",at:0,transition:0); reference.play("thinking-classic",at:0,transition:0)
        for t in stride(from:0.0,through:5.76,by:0.02) {
            retimed.sample(at:t); reference.sample(at:t/2)
            for (a,b) in zip(retimed.local,reference.local) {
                try require(abs(a.rotation-b.rotation)<1e-8 && abs(a.x-b.x)<1e-8 && abs(a.y-b.y)<1e-8,"Retiming broke skeletal interpolation")
            }
            try require(abs(retimed.automaticBlink(at:t,fallback:0)-reference.automaticBlink(at:t/2,fallback:0))<1e-8,"Retiming desynchronized eyelids")
        }
        // Locks and exit edges fail before the frame clock starts.
        for mutation in 0..<7 {
            var invalid = motions
            let last = invalid.clips.count-1
            switch mutation {
            case 0: invalid.clips[0].startPose = "missing"
            case 1: invalid.poses!["seated-neutral"] = ["head":.init(x:0,y:0,rotation:1)]
            case 2: invalid.clips[last].frameDurations = [0]
            case 3: invalid.clips[last].fallback = "missing"
            case 4: invalid.clips[0].fallback = "idle"
            case 5: invalid.clips[0].loop = false; invalid.clips[0].fallback = "tail-wag-once"
            default: invalid.clips[last].tracks[0].keys[0].value.rotation = 1
            }
            try rejects("playback mutation \(mutation)") { _ = try CutoutPlayer(rig:rig,motions:invalid) }
        }
        // All supported appearances and clips use one registered source crop.
        let crop = rig.sharedMotionBounds
        var boundsSamples = 0, maxDecoded = art.decodedBytes
        let fixed = art.motionBounds(anchor:.zero)
        for hair in rig.variants.filter({$0.category == "hair"}) {
            try art.select(["hair":hair.id])
            maxDecoded = max(maxDecoded,art.decodedBytes)
            for clip in player.clips {
                player.play(clip.definition.id,at:0,transition:0)
                for frame in 0...Int(ceil(clip.duration*60)) {
                    player.sample(at:Double(frame)/60,gaze:CGPoint(x:frame%2 == 0 ? -1:1,y:frame%3 == 0 ? -1:1))
                    let actual = art.displayBounds(anchor:CGPoint(x:rig.anchor[0],y:rig.anchor[1]),scale:1/rig.pointsPerPixel)
                    try require(crop.contains(actual),"Shared crop clips \(hair.id)/\(clip.definition.id): \(actual)")
                    try require(art.motionBounds(anchor:.zero) == fixed,"Action/appearance refitted its crop")
                    boundsSamples += 1
                }
            }
        }
        try art.select(rig.defaults)
        let reads = art.resourceReads, decodes = art.decodedImages, builds = art.compositeBuilds, cloth = art.clothPatchImagesBuilt
        try art.select(art.selection)
        try require(reads == art.resourceReads && decodes == art.decodedImages && builds == art.compositeBuilds && cloth == art.clothPatchImagesBuilt,"No-op swap rebuilt resources")
        let stableBytes = art.decodedBytes
        for _ in 0..<8 {
            try art.select(["hair":"hair-none"]); try art.select(rig.defaults)
            try require(art.decodedBytes == stableBytes,"Cache grew across a full appearance round trip")
        }
        try require(art.releasedDecodedBytes>0 && art.peakResidentDecodedBytes<=2*rig.cacheByteLimit,"Old appearance pixels were not released or transaction exceeded two selections")
        // A shared expression/attachment is decoded and charged once; oversized swaps reject before decoding.
        let fixture = out.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        func savePNG(_ image:CGImage,_ url:URL) {
            let d=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(d,image,nil);precondition(CGImageDestinationFinalize(d))
        }
        func bitmap(_ w:Int,_ h:Int)->CGContext {
            CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        for size in [8,64] { let c=bitmap(size,size);c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:0,y:0,width:size,height:size));savePNG(c.makeImage()!,fixture.appendingPathComponent("\(size).png")) }
        let tinyJSON = """
        {"schemaVersion":1,"canvas":[64,64],"anchor":[32,0],"pointsPerPixel":1,"bones":[{"id":"root","position":[0,0]}],"slots":[{"id":"mouth","bone":"root","order":0,"category":"identity","optional":false}],"variants":[{"id":"small","title":"small","category":"identity","attachments":[{"slot":"mouth","file":"8.png","rect":[0,0,8,8]}]},{"id":"large","title":"large","category":"identity","attachments":[{"slot":"mouth","file":"64.png","rect":[0,0,64,64]}]}],"defaults":{"identity":"small"},"motions":"motion.json","expressions":{"mouth":["8.png","8.png"]},"mouthShapes":[{"id":"a","title":"a","forms":["8.png","8.png"]}],"decodedByteLimit":256}
        """
        let tinyRig = try JSONDecoder().decode(CutoutRig.self,from:Data(tinyJSON.utf8))
        let tinyMotions = CutoutMotionLibrary(schemaVersion:1,clips:[.init(id:"idle",title:"idle",duration:1,loop:true,tracks:[])])
        try JSONEncoder().encode(tinyMotions).write(to:fixture.appendingPathComponent("motion.json"))
        let tiny = try CutoutArtwork(rig:tinyRig) { fixture.appendingPathComponent($0) }
        try require(tiny.decodedImages == 1 && tiny.decodedBytes == 256,"Shared neutral image was decoded/charged more than once")
        let before = tiny.parts[0].image, beforeSelection = tiny.selection, beforeDecodes = tiny.decodedImages
        try rejects("over-budget appearance") { try tiny.select(["identity":"large"]) }
        try require(tiny.parts[0].image === before && tiny.selection == beforeSelection && tiny.decodedImages == beforeDecodes && tiny.decodedBytes == 256,"Budget rejection decoded oversized pixels or changed previous frame")
        // Native raster and hot-path measurements, with one immutable export crop.
        let w=Int(crop.width),h=Int(crop.height), renderScale=1/rig.pointsPerPixel
        func draw(_ t:Double)->CGImage {
            player.sample(at:t)
            let c=bitmap(w,h)
            art.draw(in:c,anchor:CGPoint(x:rig.anchor[0]-crop.minX,y:rig.anchor[1]-crop.minY),scale:renderScale,blink:player.automaticBlink(at:t,fallback:0))
            return c.makeImage()!
        }
        player.play("tail-wag-once",at:0,transition:0)
        let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent("tail-once.gif") as CFURL,UTType.gif.identifier as CFString,60,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<60 {
            CGImageDestinationAddImage(gif,draw(Double(i)*0.04),[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
        }
        try require(CGImageDestinationFinalize(gif),"Could not export native preview")
        let sheet=bitmap(w*3,h*2)
        for (i,t) in [0.0,0.3,0.8,1.5,1.99,2.4].enumerated() {
            player.play("tail-wag-once",at:0,transition:0)
            sheet.draw(draw(t),in:CGRect(x:(i%3)*w,y:(1-i/3)*h,width:w,height:h))
        }
        savePNG(sheet.makeImage()!,out.appendingPathComponent("contact.png"))
        let context=bitmap(210,210),tickReads=art.resourceReads,tickDecodes=art.decodedImages,tickBuilds=art.compositeBuilds,tickBytes=art.decodedBytes
        player.play("thinking-classic",at:0,transition:0)
        var hot=[Double]()
        for i in 0..<1032 {
            let t=Double(i)/30,start=ProcessInfo.processInfo.systemUptime
            player.sample(at:t)
            context.clear(CGRect(x:0,y:0,width:210,height:210))
            art.draw(in:context,anchor:CGPoint(x:105,y:8),blink:player.automaticBlink(at:t,fallback:0),mouth:Double(i%4)/3)
            if i>=32 { hot.append(ProcessInfo.processInfo.systemUptime-start) }
        }
        let p95=hot.sorted()[Int(Double(hot.count-1)*0.95)]
        try require(p95<0.004,"Native draw p95 exceeds 4ms")
        try require(tickReads == art.resourceReads && tickDecodes == art.decodedImages && tickBuilds == art.compositeBuilds && tickBytes == art.decodedBytes,"Tick performed resource preparation")
        let report:[String:Any] = ["originalSamples":originalSamples,"boundsSamples":boundsSamples,"coldSeconds":cold,"drawP95Seconds":p95,"activeDecodedBytes":art.decodedBytes,"maxSelectedBytes":maxDecoded,"peakResidentDecodedBytes":art.peakResidentDecodedBytes,"releasedDecodedBytes":art.releasedDecodedBytes,"cacheLimit":rig.cacheByteLimit,"tickReads":art.resourceReads-tickReads,"tickDecodes":art.decodedImages-tickDecodes,"crop":[crop.minX,crop.minY,crop.maxX,crop.maxY],"invalidPlaybackRejected":7]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        print("PASS Cutout playback:",report)
    }
}
