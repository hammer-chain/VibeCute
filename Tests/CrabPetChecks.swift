import AppKit
import ImageIO
import UniformTypeIdentifiers
import CaptionCore
@testable import CodexCaptions

@main struct CrabPetChecks {
 static func main() throws {
    let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.finishLaunching()
    let motion=CrabPetMotion(from:CGPoint(x:40,y:20),to:CGPoint(x:370,y:20),startedAt:0,scale:1)
    precondition(motion.sample(at:0).pose?.frame==0)
    precondition(motion.sample(at:motion.duration-0.01).pose?.frame==0)
    precondition(motion.sample(at:motion.duration).finished)
    var last=motion.from
    for i in 0...Int(motion.duration*60) {
        let s=motion.sample(at:Double(i)/60)
        precondition(hypot(s.origin.x-last.x,s.origin.y-last.y)<5)
        if let p=s.pose {precondition((0..<24).contains(p.frame))}
        last=s.origin
    }
    let overlays=ProjectOverlays()
    overlays.update([],font:14,opacity:1,bottom:80,screenIndex:0,movable:true,focusedID:"",
        restingMascots:[.claude],characterBindings:[.claude:.orangeHoodie])
    let character=overlays.character(for:.claude)!
    let scale=Double(character.subtitle.layoutScale)
    let canvas=CrabPetArtwork.canvas(in:character.subtitle.bounds,scale:scale)
    let original=CGRect(x:canvas.minX+128*canvas.width/640,y:canvas.minY,width:384*canvas.width/640,height:512*canvas.height/640)
    let seated=character.subtitle.seatedSpriteRect
    precondition(abs(original.minX-seated.minX)<0.001 && abs(original.minY-seated.minY)<0.001 && abs(original.height-seated.height)<0.001,"Original seated endpoint must register exactly")
    precondition(character.subtitle.crabPetEligible)
    overlays.beginBackdropRelocation(for:.claude)
    let sample=CrabPetSample(origin:character.panel.frame.origin,pose:.init(frame:21,mirrored:false),finished:false)
    overlays.applyCrabPet(sample,for:.claude)
    precondition(character.subtitle.crabPetPose?.frame==21)
    character.subtitle.setAudioMouth(0)
    precondition(character.subtitle.crabPetEligible,"Ambient lip tracking must not suppress petting")
    character.subtitle.enterScreenEdge(.left)
    precondition(!character.subtitle.crabPetEligible)
    character.subtitle.screenEdgeDock=nil
    overlays.clearCrabPet(for:.claude);overlays.endBackdropRelocation(for:.claude)
    precondition(character.subtitle.crabPetPose==nil)
    let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/output/crab-pet")
    let w=600,h=400
    func fixture(crab:Bool)->CGImage {
        let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor.black.cgColor);c.fill(CGRect(x:0,y:0,width:w,height:h))
        c.setFillColor(NSColor(srgbRed:0.82,green:0.48,blue:0.35,alpha:1).cgColor)
        if crab {
            c.fill(CGRect(x:118,y:160,width:124,height:80));c.fill(CGRect(x:100,y:180,width:160,height:20))
            for x in [118,136,218,236] {c.fill(CGRect(x:x,y:140,width:8,height:20))}
            c.setFillColor(NSColor.black.cgColor)
            for x in [136,218] {c.fill(CGRect(x:x,y:200,width:8,height:20))}
        } else {c.fill(CGRect(x:100,y:140,width:160,height:100))}
        return c.makeImage()!
    }
    precondition(CrabIconDetector.detect(fixture(crab:false))==nil,"Orange rectangles are not crabs")
    let found=CrabIconDetector.detect(fixture(crab:true))
    precondition(found != nil,"Reference crab geometry must match")
    let icon=found!.rect
    precondition(CrabIconDetector.detect(fixture(crab:true),allowedRegions:[CGRect(x:0,y:0,width:0.1,height:1)])==nil,"A crab outside visible terminal regions must not match")
    precondition(CrabIconDetector.detect(fixture(crab:true),allowedRegions:[icon.insetBy(dx:-0.01,dy:-0.01)]) != nil,"A visible crab must match without a focused-window filter")
    let windowRect=CGRect(x:0,y:0,width:600,height:400)
    let targetRect=CGRect(x:100,y:160,width:160,height:100)
    let covered=CrabPetVisibility.subtract(CGRect(x:120,y:150,width:80,height:140),from:windowRect)
    precondition(!covered.contains {$0.contains(targetRect)},"A partly occluded crab must be rejected")
    let uncovered=CrabPetVisibility.subtract(CGRect(x:400,y:0,width:100,height:400),from:windowRect)
    precondition(uncovered.contains {$0.contains(targetRect)},"Other windows away from the crab must not block it")
    precondition(CrabPetVisibility.subtract(windowRect,from:windowRect).isEmpty,"A fully covered terminal must not trigger")
    let normalized=CrabPetVisibility.normalized(CGRect(x:100,y:160,width:160,height:100),on:windowRect)
    precondition(abs(normalized.minY-0.35)<0.001,"Visibility coordinates must match top-left capture coordinates")
    var actualScore=0.0
    if let index=CommandLine.arguments.firstIndex(of:"--reference"),CommandLine.arguments.count>index+1 {
        let url=URL(fileURLWithPath:CommandLine.arguments[index+1])
        let im=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
        let m=CrabIconDetector.detect(im);precondition(m != nil,"User supplied reference must match")
        actualScore=m!.score
    }
    let start=ProcessInfo.processInfo.systemUptime
    let art=CrabPetArtwork.shared;precondition(art.available)
    let decodeMS=(ProcessInfo.processInfo.systemUptime-start)*1000
    let frameCount=Int(ceil((motion.duration+0.5)*12))
    let gif=CGImageDestinationCreateWithURL(output.appendingPathComponent("full-transition.gif") as CFURL,UTType.gif.identifier as CFString,frameCount,nil)!
    CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
    for i in 0..<frameCount {
        let sample=motion.sample(at:Double(i)/12)
        let im=NSImage(size:NSSize(width:720,height:320));im.lockFocus()
        NSColor(srgbRed:0.9,green:0.91,blue:0.93,alpha:1).setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:720,height:320)).fill()
        let bounds=CGRect(x:sample.origin.x,y:sample.origin.y,width:220,height:226)
        art.draw(sample.pose ?? .init(frame:0,mirrored:false),in:bounds,scale:1)
        let palm=CrabPetArtwork.palmOffset(in:CGRect(x:0,y:0,width:220,height:226),scale:1,mirrored:false)
        let target=CGPoint(x:motion.to.x+palm.x,y:motion.to.y+palm.y)
        NSColor(srgbRed:0.82,green:0.48,blue:0.35,alpha:1).setFill()
        NSBezierPath(rect:CGRect(x:target.x-28,y:target.y-34,width:56,height:34)).fill()
        NSBezierPath(rect:CGRect(x:target.x-36,y:target.y-24,width:72,height:10)).fill()
        for x in [-28,-20,16,24] {NSBezierPath(rect:CGRect(x:target.x+CGFloat(x),y:target.y-44,width:4,height:12)).fill()}
        NSColor.black.setFill();for x in [-20,16] {NSBezierPath(rect:CGRect(x:target.x+CGFloat(x),y:target.y-20,width:4,height:10)).fill()}
        im.unlockFocus()
        let cg=im.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        CGImageDestinationAddImage(gif,cg,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/12]] as CFDictionary)
        if [0,12,18,58,70,frameCount-1].contains(i) {
            let d=CGImageDestinationCreateWithURL(output.appendingPathComponent("check-\(i).png") as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(d,cg,nil);CGImageDestinationFinalize(d)
        }
    }
    precondition(CGImageDestinationFinalize(gif))
    let report:[String:Any] = ["passed":true,"referenceScore":actualScore,"syntheticScore":found!.score,"decodeMS":decodeMS,"duration":motion.duration,"decodedPixelBytes":24*640*640*4]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("checks.json"))
    print(report)
 }
}
