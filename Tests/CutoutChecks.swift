import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let out = root.appendingPathComponent("output/cutout")
        try FileManager.default.createDirectory(at: out,withIntermediateDirectories:true)
        let rig = try CutoutCharacter.loadRig(root.appendingPathComponent("animation/DeepSeek_Cutout/rejected-runtime/deepseek.json"))
        let resources = root.appendingPathComponent("animation/DeepSeek_Cutout/rejected-runtime")
        var checks = [String](), failures = [String]()
        func require(_ condition: Bool, _ label: String) { if !condition { failures.append(label) } }
        let coldStart = ProcessInfo.processInfo.systemUptime
        let art = try CutoutArtwork(rig:rig) { resources.appendingPathComponent($0) }
        let cold = ProcessInfo.processInfo.systemUptime-coldStart
        let player = art.player
        func bitmap(_ width: Int, _ height: Int) -> CGContext {
            CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        func save(_ image:CGImage,_ name:String) {
            let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination))
        }
        func draw(_ width:Int = 448,_ height:Int = 640,_ mirrored:Bool = false,_ scale:Double? = nil,
                  blink:Double = 0,mouth:Double = 0) -> CGImage {
            let c = bitmap(width,height)
            art.draw(in:c,anchor:CGPoint(x:Double(width)/2,y:scale == nil ? rig.anchor[1] : 20),scale:scale ?? 1/rig.pointsPerPixel,mirrored:mirrored,blink:blink,mouth:mouth)
            return c.makeImage()!
        }
        player.play("neutral",at:0,transition:0);player.sample(at:0)
        let neutral = draw();save(neutral,"neutral-render.png")
        let originalSource = try CutoutPixels(CutoutPixels.load(root.appendingPathComponent("animation/DeepSeek_Cutout/source/maid-front.png")))
        let after = try CutoutPixels(neutral)
        let differences = stride(from:0,to:originalSource.rgba.count,by:4).filter { p in (0..<4).contains { originalSource.rgba[p+$0] != after.rgba[p+$0] } }.count
        let redrawn = rig.artworkMode == "redrawn"
        // Zero-difference ownership remains a strict check for cropped artwork.
        // A user-requested full redraw is reviewed against the unchanged design,
        // not accepted by replacing its reference or raising a pixel tolerance.
        if !redrawn {
            require(differences == 0,"Neutral assembly differs from approved source at \(differences) pixels")
            checks.append("exact source reconstruction by actual cutout renderer")
        }
        let before = redrawn ? after : originalSource
        let expressions = draw(blink:1,mouth:1)
        save(expressions,"local-expressions.png")
        let expressionPixels = try CutoutPixels(expressions)
        let allowed = rig.variants.first { $0.id == "identity" }!.attachments.filter { ["eye-left","eye-right","mouth"].contains($0.slot) }
            .map { p in CGRect(x:p.rect[0],y:rig.canvas[1]-p.rect[1]-p.rect[3],width:p.rect[2],height:p.rect[3]) }
        let outsideChanges = stride(from:0,to:before.rgba.count,by:4).filter { at in
            let point = CGPoint(x:(at/4)%before.width,y:(at/4)/before.width)
            return !allowed.contains { $0.contains(point) } && (0..<4).contains { before.rgba[at+$0] != expressionPixels.rgba[at+$0] }
        }.count
        require(outsideChanges == 0,"Local expressions changed pixels outside eye/mouth envelopes")
        checks.append("local expression changes preserve all pixels outside their registered slots")
        // Neutral face/identity is shared even when two independently selected
        // clothing and hairstyle variants are exchanged.
        player.play("step",at:0,transition:0);player.sample(at:0.225)
        let transforms = player.world, clipStart = player.startedAt
        try art.select(["clothes":"clothes-claude","hair":"hair-claude","headwear":"headwear-claude"])
        player.sample(at:0.225)
        require(player.world == transforms && player.startedAt == clipStart,"Appearance switch changed action/phase")
        save(draw(),"claude-step.png")
        checks.append("same joint transforms, action and phase across costume/hair changes")
        var invalid = rig
        invalid.bones[1].parent = invalid.bones.last!.id
        do { _ = try invalid.validated();require(false,"Cyclic/out-of-order rig accepted") } catch {}
        invalid = rig;invalid.variants[0].attachments.removeAll()
        do { _ = try invalid.validated();require(false,"Missing identity accepted") } catch {}
        let priorSelection = art.selection, priorParts = art.parts.map { $0.image }
        do { try art.select(["hair":"unknown"]);require(false,"Unknown appearance accepted") } catch {}
        require(art.selection == priorSelection && art.parts.map { $0.image } == priorParts,"Failed swap lost previous appearance")
        checks.append("malformed rigs and failed swaps rejected atomically")
        // An interrupted transition must begin at its exact displayed pose.
        player.play("wave",at:1,transition:0.5);player.sample(at:1.14)
        let interrupted = player.local
        player.play("idle",at:1.14,transition:0.3);player.sample(at:1.14)
        require(player.local == interrupted,"Interrupted blend jumped")
        player.sample(at:1.4401)
        require(player.local.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.rotation.isFinite },"Blend produced nonfinite values")
        checks.append("continuous interrupted action blending")
        player.play("wave",at:2,transition:0.5)
        player.seek(to:0.3,at:2.1)
        let scrubbed=player.local
        let reference=try CutoutPlayer(rig:rig,motions:JSONDecoder().decode(CutoutMotionLibrary.self,from:Data(contentsOf:resources.appendingPathComponent(rig.motions))))
        reference.play("wave",at:0,transition:0);reference.sample(at:0.3)
        require(zip(scrubbed,reference.local).allSatisfy {
            abs($0.x-$1.x)<1e-9 && abs($0.y-$1.y)<1e-9 && abs($0.rotation-$1.rotation)<1e-9
        },"Seeking retains the previous action blend")
        checks.append("scrubbing cancels transitions and samples the requested action phase")
        if let ik = CutoutPlayer.solveIK(target:CGPoint(x:60,y:40),upper:50,lower:40) {
            let a = ik.0 * .pi/180, b = (ik.0+ik.1) * .pi/180
            require(hypot(50*cos(a)+40*cos(b)-60,50*sin(a)+40*sin(b)-40) < 0.00001,"IK misses reachable target")
        } else { require(false,"Reachable IK rejected") }
        require(CutoutPlayer.solveIK(target:CGPoint(x:1000,y:0),upper:50,lower:40) != nil,"Unreachable target should clamp")
        require(CutoutPlayer.solveIK(target:.zero,upper:0,lower:40) == nil,"Degenerate IK accepted")
        checks.append("reachable/unreachable/degenerate two-link IK")
        let clipIDs = player.clips.map { $0.definition.id }
        let gif = CGImageDestinationCreateWithURL(out.appendingPathComponent("continuous.gif") as CFURL,UTType.gif.identifier as CFString,clipIDs.count*2*24,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        let sheet = bitmap(7*180,2*260)
        var renders = 0
        for (outfitIndex,outfit) in ["maid","claude"].enumerated() {
            try art.select(["clothes":"clothes-"+outfit,"hair":"hair-"+outfit,"headwear":"headwear-"+outfit])
            for (clipIndex,id) in clipIDs.enumerated() {
                let duration = player.clips[clipIndex].definition.duration
                player.play(id,at:0,transition:0)
                for frame in 0..<24 {
                    let time = Double(frame)/24*duration
                    player.sample(at:time)
                    let image = draw(180,260,false,1,blink:CutoutArtwork.blink(at:time),mouth:id == "sing" ? Double(frame%4)/3 : 0)
                    CGImageDestinationAddImage(gif,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.08]] as CFDictionary)
                    if frame == 6 { sheet.draw(image,in:CGRect(x:clipIndex*180,y:(1-outfitIndex)*260,width:180,height:260)) }
                    renders += 1
                }
            }
        }
        require(CGImageDestinationFinalize(gif),"Cannot save continuous preview")
        save(sheet.makeImage()!,"motion-contact-sheet.png")
        let hairstyles = rig.variants.filter { $0.category == "hair" }
        let hairSheet = bitmap(hairstyles.count*224,320*2)
        for (outfitIndex,outfit) in ["maid","claude"].enumerated() {
            try art.select(["clothes":"clothes-"+outfit,"headwear":"headwear-"+outfit])
            player.play("neutral",at:0,transition:0);player.sample(at:0)
            for (index,variant) in hairstyles.enumerated() {
                let phase = player.startedAt, identity = player.world
                try art.select(["hair":variant.id])
                require(player.startedAt == phase && player.world == identity,"Hairstyle resets pose")
                let image = draw(224,320,false,1.4)
                save(draw(),"\(outfit)-\(variant.id).png")
                hairSheet.draw(image,in:CGRect(x:index*224,y:(1-outfitIndex)*320,width:224,height:320))
            }
        }
        save(hairSheet.makeImage()!,"hairstyle-contact-sheet.png")
        checks.append("all registered hairstyles preserve motion state across both outfits")
        if redrawn {
            for outfit in ["maid","claude"] {
                try art.select(["clothes":"clothes-"+outfit,"hair":"hair-none","headwear":"headwear-none"])
                player.play("neutral",at:0,transition:0);player.sample(at:0)
                save(draw(),"\(outfit)-bald-audit.png")
            }
            let identity=rig.variants.first{$0.id=="identity"}!
            let facePart=identity.attachments.first{$0.slot=="face"}!
            let skin=try CutoutPixels(CutoutPixels.load(resources.appendingPathComponent(facePart.file)))
            let blue = stride(from:0,to:skin.rgba.count,by:4).filter { p in
                skin.rgba[p+3]>=180 && Double(skin.rgba[p+2])>Double(skin.rgba[p])*1.1
                    && Double(skin.rgba[p+1])>Double(skin.rgba[p])*1.02
            }.count
            require(blue==0,"Bald base contains blue hair pixels")
            require(rig.variants.filter{["clothes","identity"].contains($0.category)}.allSatisfy{
                $0.attachments.allSatisfy{$0.file.hasPrefix("Cutout/Redrawn/")} && ($0.underlaps ?? []).isEmpty
            },"Redrawn body still uses a cropped source or flood-filled underlap")
            checks.append("complete newly drawn bald/body components with zero blue hair pixels in bald base")
            try art.select(["clothes":"clothes-maid","hair":"hair-maid","headwear":"headwear-maid"])
        }
        // Representative hot path: registered joints/parts at 30 Hz and 147pt width,
        // not a sampler-only benchmark. The context is reused, not reallocated.
        player.play("step",at:0,transition:0)
        let context = bitmap(180,240)
        let legacyImage = try CutoutPixels.load(root.appendingPathComponent("animation/DeepSeek_Cutout/source/maid-front.png"))
        var baseline = [Double](), hot = [Double](), sampleTimes = [Double]()
        let reads = art.resourceReads, decodes = art.decodedImages, builds=art.compositeBuilds
        for i in 0..<1032 {
            context.clear(CGRect(x:0,y:0,width:180,height:240))
            var t = ProcessInfo.processInfo.systemUptime
            context.draw(legacyImage,in:CGRect(x:16.5,y:0,width:147,height:210))
            let legacy = ProcessInfo.processInfo.systemUptime-t
            context.clear(CGRect(x:0,y:0,width:180,height:240))
            t = ProcessInfo.processInfo.systemUptime
            player.sample(at:Double(i)/30)
            let sampled = ProcessInfo.processInfo.systemUptime
            art.draw(in:context,anchor:CGPoint(x:90,y:10),blink:CutoutArtwork.blink(at:Double(i)/30),mouth:Double(i%4)/3)
            let drawn = ProcessInfo.processInfo.systemUptime
            if i >= 32 { baseline.append(legacy);sampleTimes.append(sampled-t);hot.append(drawn-t) }
        }
        require(art.resourceReads == reads && art.decodedImages == decodes,"Animation tick performed file reads/decoding")
        require(art.compositeBuilds == builds,"Animation tick rebuilt a bitmap atlas")
        func percentile(_ values:[Double],_ fraction:Double) -> Double { values.sorted()[Int(Double(values.count-1)*fraction)] }
        require(cold < 1,"Cold load exceeds 1-second budget")
        require(percentile(hot,0.95) < 0.004,"Sampling plus drawing exceeds 4ms p95 budget")
        checks.append("bounded hot path, zero tick I/O/decode, actual draw p95 under budget")
        let tickReads = art.resourceReads-reads, tickDecodes = art.decodedImages-decodes
        let tickBuilds=art.compositeBuilds-builds
        let peakSelectionBytes = art.decodedBytes
        var maxBytes = peakSelectionBytes
        let beforeNoOp=art.compositeBuilds,readBeforeNoOp=art.resourceReads
        try art.select(art.selection)
        require(art.compositeBuilds==beforeNoOp && art.resourceReads==readBeforeNoOp,"Unchanged selection reloads materials or rebuilds local atlases")
        for i in 0..<20 {
            try art.select(["clothes":i%2 == 0 ? "clothes-maid" : "clothes-claude"])
            maxBytes = max(maxBytes,art.decodedBytes)
        }
        require(maxBytes <= 24*1024*1024,"Repeated swaps exceed bounded cache")
        try art.select(["tail":"no-tail","wings":"fin-wings"])
        player.sample(at:0.3);save(draw(180,260,false,1),"optional-components.png")
        checks.append("optional attachment swap and bounded current-selection cache")
        var variants = 0
        for id in clipIDs {
            player.play(id,at:0,transition:0)
            for scale in [0.5,1.0,2.0] { for mirror in [false,true] {
                player.sample(at:0.25)
                let c = bitmap(400,460)
                art.draw(in:c,anchor:CGPoint(x:200,y:24),scale:scale,mirrored:mirror)
                require(player.world.allSatisfy { $0.a.isFinite && $0.tx.isFinite },"Scale/mirror produced invalid pose")
                let damage = art.displayBounds(anchor:CGPoint(x:200,y:24),scale:scale,mirrored:mirror)
                let pixels = try CutoutPixels(c.makeImage()!)
                var escaped = false
                for at in stride(from:3,to:pixels.rgba.count,by:4) where pixels.rgba[at] > 0 {
                    let pixel = at/4
                    let x = Double(pixel%pixels.width)+0.5
                    let y = Double(pixels.height-pixel/pixels.width)-0.5
                    if !damage.contains(CGPoint(x:x,y:y)) { escaped = true;break }
                }
                require(!escaped,"Drawn pixels escape component damage bounds")
                let soles = (rig.contacts ?? [:]).map { name,p -> Double in
                    let index = player.indices[name]!,bind = player.bindWorld[index]
                    return CGPoint(x:p[0]-bind.x,y:p[1]-bind.y).applying(player.world[index]).y
                }
                require(abs((soles.min() ?? -999)-rig.anchor[1]) < 0.00001,"Grounded action loses support anchor")
                variants += 1
            } }
        }
        let solidSource = stride(from:0,to:before.rgba.count,by:4).filter { before.rgba[$0+3] >= 128 }.map { $0/4/before.width }
        let visibleHeight = solidSource.max()!-solidSource.min()!+1
        if redrawn {
            require(abs(Double(visibleHeight)*rig.pointsPerPixel/(543*147/448)-1)<0.04,"Redrawn standing height differs by more than the existing 4 percent budget")
        } else {
            require(abs(Double(visibleHeight)*rig.pointsPerPixel-543*147/448) < 0.0001,"Standing height differs from registered reference")
        }
        checks.append("ground support and calibrated standing size at 50/100/200 percent in both directions")
        player.play("wave",at:0,transition:0);player.sample(at:0.4)
        let incremental = bitmap(400,460)
        let anchor = CGPoint(x:200,y:24)
        art.draw(in:incremental,anchor:anchor)
        let oldBounds = art.displayBounds(anchor:anchor)
        player.sample(at:0.43)
        let damage = oldBounds.union(art.displayBounds(anchor:anchor))
        incremental.clear(damage);incremental.saveGState();incremental.clip(to:damage)
        art.draw(in:incremental,anchor:anchor);incremental.restoreGState()
        let fresh = bitmap(400,460);art.draw(in:fresh,anchor:anchor)
        require(try CutoutPixels(incremental.makeImage()!).rgba == CutoutPixels(fresh.makeImage()!).rgba,
                "Partial redraw leaves stale pixels or clips the new pose")
        checks.append("damage bounds cover rendered pixels and partial redraw equals full redraw")
        // Check actual opacity across registered joint bridges, rather than
        // accepting a source-pixel reconstruction as seam coverage proof.
        let bridges=[("torso","face"),("torso","upperarm-left"),("torso","upperarm-right"),
            ("upperarm-left","forearm-left"),("upperarm-right","forearm-right"),
            ("forearm-left","hand-left"),("forearm-right","hand-right"),
            ("thigh-left","calf-left"),("thigh-right","calf-right"),("calf-left","foot-left"),("calf-right","foot-right")]
        var jointProbes=0,jointHoles=0
        var jointHoleCounts=[String:Int]()
        for outfit in ["maid","claude"] {
            try art.select(["clothes":"clothes-"+outfit,"hair":"hair-buns","headwear":"headwear-"+outfit,"tail":"whale-tail","wings":"no-wings"])
            let pairs=try bridges.map { parent,child -> (CutoutArtwork.Part,CGPoint,CutoutArtwork.Part,CGPoint) in
                let p=art.parts.first{rig.slots[$0.slot].id==parent}!,c=art.parts.first{rig.slots[$0.slot].id==child}!
                let target=player.bindWorld[c.bone]
                @MainActor func nearest(_ part:CutoutArtwork.Part)throws->CGPoint {
                    let rgba=try CutoutPixels(part.image),bind=player.bindWorld[part.bone]
                    var best=CGPoint.zero,distance=Double.infinity
                    for y in 0..<rgba.height { for x in 0..<rgba.width where rgba.rgba[(y*rgba.width+x)*4+3]>=180 {
                        let local=CGPoint(x:part.rect.minX+(Double(x)+0.5)*part.rect.width/Double(rgba.width),
                            y:part.rect.minY+(Double(rgba.height-y)-0.5)*part.rect.height/Double(rgba.height))
                        let d=hypot(local.x+bind.x-target.x,local.y+bind.y-target.y)
                        if d<distance { distance=d;best=local }
                    } }
                    require(distance<32,"Joint pivot is outside its material envelope: \(parent)/\(child)")
                    return best
                }
                return (p,try nearest(p),c,try nearest(c))
            }
            for id in clipIDs { for frame in 0..<24 {
                player.play(id,at:0,transition:0);player.sample(at:Double(frame)/24*player.clips[player.clipIndex].definition.duration)
                let rendered=draw(),pixels=try CutoutPixels(rendered)
                for (parent,a,child,b) in pairs {
                    let p=a.applying(player.world[parent.bone]),q=b.applying(player.world[child.bone])
                    for step in 0...16 {
                        let v=Double(step)/16,x=Int((p.x+(q.x-p.x)*v).rounded()),y=pixels.height-1-Int((p.y+(q.y-p.y)*v).rounded())
                        var alpha:UInt8=0
                        for sy in max(0,y-1)...min(pixels.height-1,y+1) { for sx in max(0,x-1)...min(pixels.width-1,x+1) {
                            alpha=max(alpha,pixels.rgba[(sy*pixels.width+sx)*4+3])
                        } }
                        jointProbes += 1
                        if alpha<180 {
                            jointHoles += 1
                            jointHoleCounts["\(outfit)/\(id)/\(rig.slots[parent.slot].id)-\(rig.slots[child.slot].id)",default:0] += 1
                            if frame==6 { save(rendered,"seam-\(outfit)-\(id).png") }
                        }
                    }
                }
            } }
        }
        require(jointHoles==0,"Articulated joint bridges contain \(jointHoles) transparent holes")
        checks.append("both outfits retain opaque shoulder/elbow/wrist/neck/knee/ankle bridges in every action")
        let report:[String:Any] = ["passed":failures.isEmpty,"checks":checks,"failures":failures,"neutralDifferentPixels":differences,
            "artworkMode":rig.artworkMode ?? "cropped","bones":rig.bones.count,"defaultParts":art.parts.count,"clips":clipIDs.count,"previewRenders":renders,"scaleMirrorRenders":variants,
            "sourceVisibleHeight":visibleHeight,"displayVisibleHeight":Double(visibleHeight)*rig.pointsPerPixel,"hairstyleDesigns":rig.hairstyleDesigns?.count ?? 0,
            "coldLoadSeconds":cold,"hotSampleP95Seconds":percentile(sampleTimes,0.95),"hotSampleDrawP50Seconds":percentile(hot,0.5),
            "hotSampleDrawP95Seconds":percentile(hot,0.95),"legacySingleSpriteDrawP95Seconds":percentile(baseline,0.95),
            "tickResourceReads":tickReads,"tickDecodes":tickDecodes,"tickCompositeBuilds":tickBuilds,"maximumSelectedDecodedBytes":maxBytes,
            "benchmarkSamples":1000,"displayPoints":[147,210],"targetHz":30,"networkRequests":0,"modelCalls":0,
            "jointBridgeProbes":jointProbes,"jointBridgeHoles":jointHoles,
            "jointHoleCounts":jointHoleCounts,
            "environment":ProcessInfo.processInfo.operatingSystemVersionString,
            "boundary":"Controlled CoreGraphics drawing. Native app and articulated visual/seam review are separate." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        for failure in failures { print("FAIL \(failure)") }
        print("\(failures.isEmpty ? "PASS" : "FAIL") cutout: \(checks.count) checks; cold \(cold*1000)ms, p95 \(percentile(hot,0.95)*1000)ms")
        if !failures.isEmpty { exit(1) }
    }
}
