import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutWardrobeChecks {
 static func main() throws {
    let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
    let base=root.appendingPathComponent("Sources/CodexCaptions/Resources")
    let character=try CutoutCharacter.load(base.appendingPathComponent("CutoutCharacters/deepseek-cutout.json"))
    let rig=character.cutout!,resources=base.appendingPathComponent(character.resourceDirectory)
    let out=root.appendingPathComponent("output/claude-cutout")
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    func require(_ value:Bool,_ message:String)throws {if !value {throw CutoutError.invalid(message)}}
    let art=try CutoutArtwork(rig:rig) {resources.appendingPathComponent($0)},player=art.player
    let clothes=["clothes-original","clothes-claude-code"]
    let hairstyles=rig.variants.filter {$0.category=="hair" && $0.id != "hair-none"}.map(\.id)
    let actions=["thinking-classic","head-sway","arm-probe","right-elbow-probe","sleeve-joints-probe"]
    let sleeveSlots=["right-upper","right-fore","right-cuff","right-hand","left-upper","left-fore","left-cuff","left-hand"]
    let workwear=rig.variants.first {$0.id=="clothes-claude-code"}!
    try require(sleeveSlots.allSatisfy {slot in workwear.attachments.contains {$0.slot==slot}},"Workwear must have two separate upper sleeves, lower sleeves, cuffs and hands")
    try require(Set(workwear.attachments.map(\.file)).count==workwear.attachments.count,"Sleeves reuse a fused bitmap")
    try require(workwear.clothDeformations != nil && workwear.clothDeformations != rig.clothDeformations,"Workwear still inherits the maid cloth region")
    func bitmap(_ w:Int,_ h:Int)->CGContext {CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!}
    func render(_ art:CutoutArtwork,_ width:Int=420,_ height:Int=400)->CGImage {
        let c=bitmap(width,height)
        art.draw(in:c,anchor:CGPoint(x:Double(width)/2,y:20),scale:2)
        return c.makeImage()!
    }
    func save(_ image:CGImage,_ name:String) {
        let d=CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(d,image,nil);precondition(CGImageDestinationFinalize(d))
    }
    player.play("thinking-classic",at:0,transition:0);player.sample(at:1.76)
    let baseline=try CutoutPixels(render(art)).rgba,baselineBytes=art.decodedBytes
    let pose=player.world,local=player.local,started=player.startedAt,clipIndex=player.clipIndex
    var coldSwapSeconds=0.0
    for roundTrip in 0..<6 {
        let before=ProcessInfo.processInfo.systemUptime
        try art.select(["clothes":"clothes-claude-code","headwear":"headwear-claude-code"])
        if roundTrip==0 {coldSwapSeconds=ProcessInfo.processInfo.systemUptime-before}
        try require(player.world==pose && player.local==local && player.startedAt==started && player.clipIndex==clipIndex,"Clothing swap changed the action phase or pose")
        try art.select(rig.defaults)
        try require(art.decodedBytes==baselineBytes,"Decoded cache did not return to the maid baseline")
        try require(try CutoutPixels(render(art)).rgba==baseline,"Returning from workwear altered the original pixels")
    }
    var boundsSamples=0,maxBytes=0,jointSamples=0
    var timings=[Double](),variantBytes=[String:Int]()
    let perf=bitmap(210,210)
    let contact=bitmap(420*3,400*2)
    contact.setFillColor(NSColor(calibratedWhite:0.16,alpha:1).cgColor);contact.fill(CGRect(x:0,y:0,width:1260,height:800))
    for (row,costume) in clothes.enumerated() {
      for (col,hair) in hairstyles.enumerated() {
        try art.select(["clothes":costume,"hair":hair,"headwear":row==0 ? "headwear-original":"headwear-claude-code"])
        maxBytes=max(maxBytes,art.decodedBytes);variantBytes[costume+"/"+hair]=art.decodedBytes
        let reads=art.resourceReads,decodes=art.decodedImages,builds=art.compositeBuilds,clothBuilds=art.clothPatchImagesBuilt
        for action in actions {
          player.play(action,at:0,transition:0)
          for frame in 0...Int(ceil(player.clips[player.clipIndex].duration*60)) {
            let t=Double(frame)/60
            player.sample(at:t)
            let b=art.displayBounds(anchor:CGPoint(x:rig.anchor[0],y:rig.anchor[1]),scale:1/rig.pointsPerPixel)
            try require(rig.sharedMotionBounds.contains(b),"Shared crop clips \(costume)/\(hair)/\(action)")
            if frame%4==0 {
                let before=ProcessInfo.processInfo.systemUptime
                perf.clear(CGRect(x:0,y:0,width:210,height:210))
                player.sample(at:t)
                art.draw(in:perf,anchor:CGPoint(x:105,y:8))
                timings.append(ProcessInfo.processInfo.systemUptime-before)
            }
            boundsSamples+=1
          }
        }
        try require(reads==art.resourceReads && decodes==art.decodedImages && builds==art.compositeBuilds && clothBuilds==art.clothPatchImagesBuilt,"Animation prepared new costume resources")
        player.play("thinking-classic",at:0,transition:0);player.sample(at:1.76)
        contact.saveGState();contact.translateBy(x:Double(col*420),y:Double((1-row)*400))
        art.draw(in:contact,anchor:CGPoint(x:210,y:20),scale:2)
        contact.restoreGState()
      }
    }
    save(contact.makeImage()!,"wardrobe-hairstyles.png")
    // Compare exposed throat pixels with the actual identity layer. A valid
    // neck attachment alone did not catch the first hood covering the neck.
    try art.select(["clothes":"clothes-claude-code","hair":"hair-original","headwear":"headwear-claude-code"])
    // Hide the raised hand for this probe: its pale skin naturally covers the
    // lower left throat, which must not be mistaken for an opaque hood.
    var throatRig=rig
    let hiddenSleeves=Set(sleeveSlots+["handwear-l"])
    for i in throatRig.slots.indices where hiddenSleeves.contains(throatRig.slots[i].id) {throatRig.slots[i].optional=true}
    for i in throatRig.variants.indices {
        throatRig.variants[i].attachments.removeAll {hiddenSleeves.contains($0.slot)}
        throatRig.variants[i].slotOrders=throatRig.variants[i].slotOrders?.filter {!hiddenSleeves.contains($0.key)}
    }
    let throatArt=try CutoutArtwork(rig:throatRig) {resources.appendingPathComponent($0)}
    try throatArt.select(["clothes":"clothes-claude-code","headwear":"headwear-claude-code"])
    let throatPlayer=throatArt.player,neck=throatArt.parts.first {rig.slots[$0.slot].id=="neck"}!
    var exposedNeckSamples=0,exposedLegSamples=0,frontSkirtSamples=0
    throatPlayer.play("thinking-classic",at:0,transition:0)
    for t in [0.0,1.76,2.40] {
        throatPlayer.sample(at:t)
        let full=bitmap(1024,1024),identity=bitmap(1024,1024)
        throatArt.draw(in:full,anchor:CGPoint(x:rig.anchor[0],y:rig.anchor[1]),scale:1/rig.pointsPerPixel)
        identity.interpolationQuality = .medium
        identity.concatenate(throatPlayer.world[neck.bone]);identity.concatenate(neck.orientation)
        identity.draw(neck.image,in:neck.rect)
        let actual=try CutoutPixels(full.makeImage()!).rgba,expected=try CutoutPixels(identity.makeImage()!).rgba
        for p in [CGPoint(x:480,y:495),CGPoint(x:485,y:496),CGPoint(x:490,y:497),CGPoint(x:490,y:503),CGPoint(x:495,y:506),CGPoint(x:499,y:503)] {
            let bind=throatPlayer.bindWorld[neck.bone]
            let q=CGPoint(x:p.x-bind.x,y:p.y-bind.y).applying(throatPlayer.world[neck.bone])
            let offset=((1023-Int(q.y))*1024+Int(q.x))*4
            try require(expected[offset+3]==255 && (0..<4).allSatisfy {abs(Int(actual[offset+$0])-Int(expected[offset+$0]))<=3},"Hood or sleeve hides neck \(p) at \(t): \(Array(actual[offset..<offset+4])) vs \(Array(expected[offset..<offset+4]))")
            exposedNeckSamples+=1
        }
        // The rear flare must not hide the seated knees or legwarmers.
        let leg=throatArt.parts.first {rig.slots[$0.slot].id=="legwear"}!,legCanvas=bitmap(1024,1024)
        legCanvas.interpolationQuality = .medium;legCanvas.concatenate(throatPlayer.world[leg.bone]);legCanvas.draw(leg.image,in:leg.rect)
        let legPixels=try CutoutPixels(legCanvas.makeImage()!).rgba
        for p in [CGPoint(x:410,y:210),CGPoint(x:520,y:210),CGPoint(x:430,y:190),CGPoint(x:532,y:190),CGPoint(x:380,y:133),CGPoint(x:548,y:133)] {
            let offset=((1023-Int(p.y))*1024+Int(p.x))*4
            try require(legPixels[offset+3]==255 && (0..<4).allSatisfy {abs(Int(actual[offset+$0])-Int(legPixels[offset+$0]))<=3},"Skirt or shoes hide a knee or sock patch at \(p), \(t)")
            exposedLegSamples+=1
        }
        // The front skirt must still cover the upper thighs. Checking only
        // visible knees missed the first all-legs-in-front arrangement.
        let front=throatArt.parts.first {rig.slots[$0.slot].id=="skirt-front"}!,frontCanvas=bitmap(1024,1024)
        frontCanvas.interpolationQuality = .medium;frontCanvas.concatenate(throatPlayer.world[front.bone]);frontCanvas.draw(front.image,in:front.rect)
        let frontPixels=try CutoutPixels(frontCanvas.makeImage()!).rgba
        for p in [CGPoint(x:414,y:250),CGPoint(x:522,y:250)] {
            let offset=((1023-Int(p.y))*1024+Int(p.x))*4
            try require(frontPixels[offset+3]==255 && (0..<4).allSatisfy {abs(Int(actual[offset+$0])-Int(frontPixels[offset+$0]))<=3},"Upper thigh covers the front skirt at \(t)")
            frontSkirtSamples+=1
        }
    }
    // Test actual overlapping chin/collar pixels, not just a neck above the
    // garment. This also requires contact: a gap must not vacuously pass.
    let face=throatArt.parts.first {rig.slots[$0.slot].id=="face"}!
    let shirt=throatArt.parts.first {rig.slots[$0.slot].id=="topwear"}!
    var chinOverlapSamples=0
    for (action,t) in [("thinking-classic",0.0),("thinking-classic",1.76),("head-sway",1.1),("head-sway",3.0)] {
        throatPlayer.play(action,at:0,transition:0);throatPlayer.sample(at:t)
        let full=bitmap(1024,1024),faceOnly=bitmap(1024,1024),shirtOnly=bitmap(1024,1024)
        throatArt.draw(in:full,anchor:CGPoint(x:rig.anchor[0],y:rig.anchor[1]),scale:1/rig.pointsPerPixel)
        for (part,canvas) in [(face,faceOnly),(shirt,shirtOnly)] {
            canvas.interpolationQuality = .medium;canvas.concatenate(throatPlayer.world[part.bone])
            canvas.concatenate(part.orientation);canvas.draw(part.image,in:part.rect)
        }
        let actual=try CutoutPixels(full.makeImage()!).rgba
        let facePixels=try CutoutPixels(faceOnly.makeImage()!).rgba
        let shirtPixels=try CutoutPixels(shirtOnly.makeImage()!).rgba
        var overlaps=0
        for y in stride(from:510,through:554,by:2) {for x in stride(from:420,through:550,by:2) {
            let offset=((1023-y)*1024+x)*4
            guard facePixels[offset+3]==255 && shirtPixels[offset+3]==255 else {continue}
            try require((0..<4).allSatisfy {abs(Int(actual[offset+$0])-Int(facePixels[offset+$0]))<=3},"Collar covers chin in \(action) at \(t), \(x),\(y)")
            overlaps+=1
        }}
        try require(overlaps>=40,"Collar is disconnected from the chin in \(action) at \(t)")
        chinOverlapSamples+=overlaps
    }
    // Test sleeve coverage without the torso underneath hiding missing paint.
    try art.select(["clothes":"clothes-claude-code"])
    let arms=art.parts.filter {sleeveSlots.contains(rig.slots[$0.slot].id)}
    let pixels=try arms.map {try CutoutPixels($0.image)}
    func coverage(_ point:CGPoint)->Double {
        var uncovered=1.0
        for (part,px) in zip(arms,pixels) {
            let t=part.orientation.concatenating(player.world[part.bone]).inverted()
            let p=point.applying(t)
            guard part.rect.contains(p) else {continue}
            let x=min(px.width-1,max(0,Int((p.x-part.rect.minX)/part.rect.width*Double(px.width))))
            let y=min(px.height-1,max(0,Int((part.rect.maxY-p.y)/part.rect.height*Double(px.height))))
            uncovered *= 1-Double(px.rgba[(y*px.width+x)*4+3])/255
        }
        return 1-uncovered
    }
    for action in actions {
        player.play(action,at:0,transition:0)
        for frame in 0...240 {
            player.sample(at:Double(frame)/60)
            for joint in ["arm-right","right-elbow","right-wrist","arm-left","left-elbow","left-wrist"] {
                let p=CGPoint.zero.applying(player.world[player.indices[joint]!])
                for offset in [CGPoint.zero,CGPoint(x:4,y:0),CGPoint(x:-4,y:0),CGPoint(x:0,y:4),CGPoint(x:0,y:-4)] {
                    try require(coverage(CGPoint(x:p.x+offset.x,y:p.y+offset.y))>=0.98,"Sleeve/hand hole at \(joint), \(action), \(frame)")
                    jointSamples+=1
                }
            }
        }
    }
    // Reviewable native-rendered export: thinking, then the sleeve diagnostic.
    try art.select(["hair":"hair-original","headwear":"headwear-claude-code"])
    let gif=CGImageDestinationCreateWithURL(out.appendingPathComponent("workwear-motion.gif") as CFURL,UTType.gif.identifier as CFString,86,nil)!
    CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
    for (action,count) in [("thinking-classic",36),("sleeve-joints-probe",50)] {
        player.play(action,at:0,transition:0)
        for frame in 0..<count {
            let t=Double(frame)*0.08;player.sample(at:t)
            let c=bitmap(520,500);c.setFillColor(NSColor(calibratedWhite:0.16,alpha:1).cgColor)
            c.fill(CGRect(x:0,y:0,width:520,height:500))
            art.draw(in:c,anchor:CGPoint(x:260,y:24),scale:2.7,blink:player.automaticBlink(at:t,fallback:0))
            CGImageDestinationAddImage(gif,c.makeImage()!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.08,kCGImagePropertyGIFUnclampedDelayTime:0.08]] as CFDictionary)
        }
    }
    try require(CGImageDestinationFinalize(gif),"Cannot export workwear preview")
    // Reject clothing-local settings with missing owners or malformed regions.
    for mutation in 0..<6 {
        var invalid=rig
        let i=invalid.variants.firstIndex {$0.id=="clothes-claude-code"}!
        if mutation==0 {invalid.variants[i].clothDeformations![0].region[2] = -1}
        else if mutation==1 {invalid.variants[i].clothDeformations![0].slot="missing"}
        else if mutation==2 {invalid.variants[i].category="hair"}
        else if mutation==3 {invalid.variants[i].slotOrders=["missing":6]}
        else if mutation==4 {invalid.variants[i].slotOrders=["neck":129]}
        else {invalid.variants[i].slotOrders=["front hair":6]}
        var rejected=false
        do {_ = try invalid.validated()} catch {rejected=true}
        try require(rejected,"Invalid clothing-local cloth configuration accepted")
    }
    timings.sort();let p95=timings[Int(Double(timings.count-1)*0.95)]
    try require(p95<0.004,"Wardrobe drawing exceeded 4 ms p95")
    try require(maxBytes<=rig.cacheByteLimit,"Workwear exceeded active decoded budget")
    let report:[String:Any]=["costumes":clothes,"hairstyles":hairstyles,"actions":actions,"combinations":clothes.count*hairstyles.count*actions.count,
        "boundsSamples":boundsSamples,"jointCoverageSamples":jointSamples,"exposedNeckSamples":exposedNeckSamples,"exposedLegSamples":exposedLegSamples,"frontSkirtSamples":frontSkirtSamples,"chinOverlapSamples":chinOverlapSamples,"decodedBytes":variantBytes,
        "maxDecodedBytes":maxBytes,"budget":rig.cacheByteLimit,"peakResidentDecodedBytes":art.peakResidentDecodedBytes,
        "drawP95Seconds":p95,"drawSamples":timings.count,"coldSwapSeconds":coldSwapSeconds,"roundTrips":6,"tickReads":0,"tickDecodes":0,"originalPixelsPreserved":true]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
    print("PASS wardrobe",report)
 }
}
