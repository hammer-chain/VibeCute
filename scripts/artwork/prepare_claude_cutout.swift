// Offline packing only. Run from the project root:
// swift scripts/artwork/prepare_claude_cutout.swift artwork/cutout/claude-code/source-sheet.png
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let sourceURL=root.appendingPathComponent(CommandLine.arguments.dropFirst().first ?? "artwork/cutout/claude-code/source-sheet.png")
let destination=root.appendingPathComponent("Sources/CodexCaptions/Resources/DeepSeekCutout/outfits/claude-code")
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
let rawSource=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(sourceURL as CFURL,nil)!,0,nil)!
precondition(rawSource.width==1024 && rawSource.height==1536,"Recheck the source registration after regenerating the sheet")
let space=CGColorSpace(name:CGColorSpace.sRGB)!
func context(_ w:Int,_ h:Int)->CGContext {
    CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func cleaned(_ image:CGImage)->CGImage {
let sourceContext=context(image.width,image.height)
sourceContext.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
let pixels=sourceContext.data!.assumingMemoryBound(to:UInt8.self)
for i in 0..<image.width*image.height {
    let a=Int(pixels[i*4+3])
    if a<=8 {for j in 0..<4 {pixels[i*4+j]=0}}
    else if a>=248 {
        for j in 0..<3 {pixels[i*4+j]=UInt8(min(255,Int(pixels[i*4+j])*255/a))}
        pixels[i*4+3]=255
    }
}
return sourceContext.makeImage()!
}
let source=cleaned(rawSource)
func alphaBounds(_ image:CGImage)->CGRect {
    let c=context(image.width,image.height);c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    let p=c.data!.assumingMemoryBound(to:UInt8.self)
    var x0=image.width,y0=image.height,x1 = -1,y1 = -1
    for y in 0..<image.height {for x in 0..<image.width where p[(y*image.width+x)*4+3]>8 {
        x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
    }}
    precondition(x1>=x0 && y1>=y0,"Empty sprite")
    return CGRect(x:x0,y:y0,width:x1-x0+1,height:y1-y0+1)
}
// Bounds are recorded per component, rather than assuming an equal-grid crop.
let regions:[String:CGRect]=[
    "topwear":CGRect(x:0,y:0,width:490,height:470),
    "right-upper":CGRect(x:490,y:0,width:230,height:470),
    "right-fore":CGRect(x:720,y:0,width:304,height:470),
    "right-cuff":CGRect(x:60,y:570,width:300,height:260),
    "left-upper":CGRect(x:390,y:455,width:290,height:405),
    "left-fore":CGRect(x:680,y:470,width:344,height:370),
    "left-cuff":CGRect(x:20,y:920,width:280,height:280),
    "left-hand":CGRect(x:320,y:900,width:310,height:280),
    "legwear":CGRect(x:620,y:840,width:404,height:400),
    "footwear":CGRect(x:20,y:1230,width:440,height:280),
    "headwear":CGRect(x:460,y:1240,width:230,height:240)
]
var sourceBounds=[String:CGRect](),images=[String:CGImage](),attachments=[[String:Any]](),sourceFiles=[String:String]()
for (name,region) in regions {
    let cropped=source.cropping(to:region)!,b=alphaBounds(cropped)
    let bounds=b.offsetBy(dx:region.minX,dy:region.minY)
    sourceBounds[name]=bounds;images[name]=source.cropping(to:bounds)!
    sourceFiles[name]="artwork/cutout/claude-code/source-sheet.png"
}
// Body and head accessory were corrected independently; do not recrop the arm
// sheet when replacing one component. Keep these sources in the workspace.
for (name,file) in [("headwear","headwear-eight-spoke.png")] {
    let path="artwork/cutout/claude-code/"+file
    let raw=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL,nil)!,0,nil)!
    let image=cleaned(raw),bounds=alphaBounds(image)
    sourceBounds[name]=bounds;images[name]=image.cropping(to:bounds)!
    sourceFiles[name]=path
}
// These are three pieces of one compact seated outfit, not a lap strip
// added over a complete dress. Alpha bounds discard the sheet's empty margins.
let compactPath="artwork/cutout/claude-code/compact-outfit-source.png"
let compactRaw=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(root.appendingPathComponent(compactPath) as CFURL,nil)!,0,nil)!
precondition(compactRaw.width==1024 && compactRaw.height==1536)
let compact=cleaned(compactRaw)
for (name,region) in [
    ("topwear",CGRect(x:160,y:95,width:700,height:665)),
    ("skirt-front",CGRect(x:20,y:780,width:984,height:355)),
    ("skirt-back",CGRect(x:60,y:1190,width:904,height:260))
] {
    let local=alphaBounds(compact.cropping(to:region)!)
    let bounds=local.offsetBy(dx:region.minX,dy:region.minY)
    sourceBounds[name]=bounds;images[name]=compact.cropping(to:bounds)!
    sourceFiles[name]=compactPath
}
func loadPieces(_ file:String,_ regions:[(String,CGRect)]) {
    let path="artwork/cutout/claude-code/"+file
    let raw=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL,nil)!,0,nil)!
    let sheet=cleaned(raw)
    for (name,region) in regions {
        let local=alphaBounds(sheet.cropping(to:region)!)
        let bounds=local.offsetBy(dx:region.minX,dy:region.minY)
        sourceBounds[name]=bounds;images[name]=sheet.cropping(to:bounds)!;sourceFiles[name]=path
    }
}
loadPieces("low-neckline-source.png",[("topwear",CGRect(x:190,y:65,width:1000,height:1020))])
loadPieces("puffy-sleeves-source.png",[
    ("right-upper",CGRect(x:150,y:20,width:350,height:480)),
    ("right-fore",CGRect(x:620,y:20,width:340,height:480)),
    ("right-cuff",CGRect(x:1100,y:250,width:340,height:220)),
    ("left-upper",CGRect(x:150,y:520,width:350,height:490)),
    ("left-fore",CGRect(x:620,y:520,width:340,height:490)),
    ("left-cuff",CGRect(x:1100,y:740,width:340,height:220))
])
loadPieces("soft-socks-shoes-source.png",[
    ("legwear",CGRect(x:80,y:70,width:860,height:960)),
    ("footwear",CGRect(x:100,y:1090,width:820,height:400))
])
func save(_ image:CGImage,_ name:String,_ rect:CGRect) {
    let url=destination.appendingPathComponent(name+".png")
    let d=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(d,image,nil);precondition(CGImageDestinationFinalize(d))
    // Keep IDAT unchanged; omit generator/host metadata from shipped resources.
    let bytes=try! Data(contentsOf:url);var result=bytes.prefix(8),offset=8
    while offset<bytes.count {
        let size=bytes[offset..<offset+4].reduce(0) {$0*256+Int($1)}
        let type=String(data:bytes[offset+4..<offset+8],encoding:.ascii)!
        if !["eXIf","tEXt","zTXt","iTXt"].contains(type) {result.append(bytes[offset..<offset+12+size])}
        offset+=12+size
    }
    try! result.write(to:url)
    attachments.append(["slot":name,"file":"outfits/claude-code/"+name+".png",
        "rect":[rect.minX,rect.minY,rect.width,rect.height],
        "source":sourceFiles[name]!,
        "sourceBounds":[sourceBounds[name]!.minX,sourceBounds[name]!.minY,sourceBounds[name]!.width,sourceBounds[name]!.height]])
}
func placed(_ name:String,_ rect:CGRect) {
    let c=context(Int(rect.width),Int(rect.height));c.interpolationQuality = .high
    c.draw(images[name]!,in:CGRect(x:0,y:0,width:rect.width,height:rect.height))
    save(c.makeImage()!,name,rect)
}
// Map the two painted endpoints to the existing bind joints. Width is adjusted
// independently from length, without changing the rig or action keyframes.
func articulated(_ name:String,_ sourceA:CGPoint,_ sourceB:CGPoint,_ targetA:CGPoint,_ targetB:CGPoint,_ widthScale:Double) {
    let image=images[name]!,b=sourceBounds[name]!
    let a=CGPoint(x:sourceA.x-b.minX,y:b.height-(sourceA.y-b.minY))
    let z=CGPoint(x:sourceB.x-b.minX,y:b.height-(sourceB.y-b.minY))
    let length=hypot(z.x-a.x,z.y-a.y),distance=hypot(targetB.x-targetA.x,targetB.y-targetA.y)
    let u=CGPoint(x:(z.x-a.x)/length,y:(z.y-a.y)/length),v=CGPoint(x:(targetB.x-targetA.x)/distance,y:(targetB.y-targetA.y)/distance)
    let along=distance/length
    let aa=along*v.x*u.x+widthScale*v.y*u.y,bb=along*v.y*u.x-widthScale*v.x*u.y
    let cc=along*v.x*u.y-widthScale*v.y*u.x,dd=along*v.y*u.y+widthScale*v.x*u.x
    let t=CGAffineTransform(a:aa,b:bb,c:cc,d:dd,tx:targetA.x-aa*a.x-cc*a.y,ty:targetA.y-bb*a.x-dd*a.y)
    let full=CGRect(x:0,y:0,width:image.width,height:image.height)
    let rect=full.applying(t).insetBy(dx:-2,dy:-2).integral
    let c=context(Int(rect.width),Int(rect.height));c.interpolationQuality = .high
    c.translateBy(x:-rect.minX,y:-rect.minY);c.concatenate(t);c.draw(image,in:full)
    save(c.makeImage()!,name,rect)
}
// The raised rear collar overlaps behind the chin; a short torso meets one
// arched lap hem. The rear crescent stays inside that skirt's silhouette.
// The open V ends inside the existing neck, not below it. Register the
// neckline separately from the belly so lowering the collar does not lengthen
// the whole garment or turn it into a stand-up scarf.
let torso=images["topwear"]!,collarRows=Int(Double(images["topwear"]!.height)*0.43)
let torsoCanvas=context(330,265);torsoCanvas.interpolationQuality = .high
let collar=torso.cropping(to:CGRect(x:0,y:0,width:torso.width,height:collarRows+1))!
// Taper only the hidden upper hood. The lower edge still matches the torso
// exactly, avoiding a horizontal notch at the two registrations' join.
for row in 0..<75 {
    let width=330-90*(Double(row)+0.5)/75
    torsoCanvas.saveGState()
    torsoCanvas.clip(to:CGRect(x:0,y:190+row,width:330,height:1))
    torsoCanvas.draw(collar,in:CGRect(x:(330-width)/2,y:190,width:width,height:75))
    torsoCanvas.restoreGState()
}
torsoCanvas.draw(torso.cropping(to:CGRect(x:0,y:collarRows,width:torso.width,height:torso.height-collarRows))!,in:CGRect(x:0,y:0,width:330,height:190))
save(torsoCanvas.makeImage()!,"topwear",CGRect(x:312,y:300,width:330,height:265))
placed("skirt-back",CGRect(x:257,y:210,width:440,height:65))
placed("skirt-front",CGRect(x:242,y:197,width:470,height:125))
// Keep the sock patches round; hide the extra upper thigh behind the skirt
// instead of squashing the complete knee/sock source into a shorter rectangle.
placed("legwear",CGRect(x:347,y:60,width:236,height:270))
placed("footwear",CGRect(x:365,y:32,width:211,height:80))
placed("headwear",CGRect(x:641,y:738,width:82,height:94))
articulated("right-upper",CGPoint(x:315,y:95),CGPoint(x:315,y:445),CGPoint(x:375,y:477),CGPoint(x:376,y:381),0.38)
articulated("right-fore",CGPoint(x:780,y:95),CGPoint(x:765,y:455),CGPoint(x:376,y:381),CGPoint(x:450,y:454),0.44)
articulated("right-cuff",CGPoint(x:1275,y:315),CGPoint(x:1275,y:405),CGPoint(x:442,y:446),CGPoint(x:458,y:462),0.20)
articulated("left-upper",CGPoint(x:330,y:585),CGPoint(x:330,y:950),CGPoint(x:573,y:476),CGPoint(x:572,y:367),0.36)
articulated("left-fore",CGPoint(x:780,y:590),CGPoint(x:790,y:945),CGPoint(x:572,y:367),CGPoint(x:480,y:322),0.44)
articulated("left-cuff",CGPoint(x:1275,y:805),CGPoint(x:1275,y:895),CGPoint(x:490,y:327),CGPoint(x:471,y:317),0.20)
articulated("left-hand",CGPoint(x:552,y:1009),CGPoint(x:407,y:1082),CGPoint(x:480,y:322),CGPoint(x:420,y:309),0.42)
let manifest:[String:Any]=["source":"artwork/cutout/claude-code/source-sheet.png","sourceSize":[1024,1536],
    "coordinateSystem":"source canvas, y up","attachments":attachments.sorted {($0["slot"] as! String)<($1["slot"] as! String)}]
let manifestURL=root.appendingPathComponent("artwork/cutout/claude-code/registration.json")
try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:manifestURL)
// Persist source-space registration and the runtime registry together, avoiding
// an asset/JSON mismatch after changing a sleeve's width or endpoint.
let characterURL=root.appendingPathComponent("Sources/CodexCaptions/Resources/CutoutCharacters/deepseek-cutout.json")
var registry=try String(contentsOf:characterURL,encoding:.utf8)
for packed in attachments {
    let file=packed["file"] as! String,rect=packed["rect"] as! [CGFloat]
    let pattern="(\"file\"\\s*:\\s*\""+NSRegularExpression.escapedPattern(for:file)+"\"\\s*,\\s*\"rect\"\\s*:\\s*)\\[[^\\]]+\\]"
    let regex=try NSRegularExpression(pattern:pattern)
    let matches=regex.matches(in:registry,range:NSRange(registry.startIndex...,in:registry))
    precondition(matches.count==1,"Expected one registered file: "+file)
    let values=rect.map {String(Int($0))}.joined(separator:",\n              ")
    registry=regex.stringByReplacingMatches(in:registry,range:NSRange(registry.startIndex...,in:registry),withTemplate:"$1[\n              "+values+"\n            ]")
}
registry=registry.replacingOccurrences(of:"Claude Code 橙色花饰",with:"Claude Code 橙色星芒")
try registry.write(to:characterURL,atomically:true,encoding:.utf8)
print("Prepared",attachments.count,"registered clothing/accessory sprites")
