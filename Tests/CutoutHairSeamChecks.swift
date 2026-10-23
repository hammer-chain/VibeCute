import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct CutoutHairSeamChecks {
    static func main() throws {
        let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/Sources/CodexCaptions/Resources")
        let out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/output/cutout-thinking-sync/seams")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let character=try CutoutCharacter.load(base.appendingPathComponent("CutoutCharacters/deepseek-cutout.json")),original=character.cutout!
        let resources=base.appendingPathComponent(character.resourceDirectory)
        let width=800,height=740,scale=4.0
        var rows=[[String:Any]](),failures=[String](),saved=false
        func opaqueInterior(_ pixels:CutoutPixels,_ radius:Int)->[Int] {
            let stride=width+1
            var integral=[Int](repeating:0,count:(width+1)*(height+1))
            for y in 0..<height {
                var row=0
                for x in 0..<width {row += pixels.rgba[(y*width+x)*4+3]<254 ? 1:0;integral[(y+1)*stride+x+1]=integral[y*stride+x+1]+row}
            }
            var result=[Int]()
            for y in radius..<(height-radius) {for x in radius..<(width-radius) {
                let x0=x-radius,x1=x+radius+1,y0=y-radius,y1=y+radius+1
                if integral[y1*stride+x1]-integral[y0*stride+x1]-integral[y1*stride+x0]+integral[y0*stride+x0]==0 {result.append((y*width+x)*4+3)}
            }}
            return result
        }
        for style in original.variants.filter({$0.category=="hair" && !$0.attachments.isEmpty}) {
            for attachment in style.attachments {
                try autoreleasepool {
                    // Render one real hair layer at 200% on a Retina display.
                    // An eroded opaque source region must stay opaque under any
                    // displacement allowed by its registered deformation.
                    var rig=original
                    rig.slots=rig.slots.filter{$0.id==attachment.slot}
                    var variant=style;variant.attachments=[attachment]
                    rig.variants=[variant];rig.defaults=["hair":style.id]
                    rig.expressions=nil;rig.mouthShapes=nil;rig.composites=nil;rig.eyeClips=nil;rig.clothDeformations=nil
                    rig.hairDeformations=rig.hairDeformations?.filter{$0.slot==attachment.slot}
                    rig.hairstyleDesigns=nil
                    let art=try CutoutArtwork(rig:rig){resources.appendingPathComponent($0)}
                    let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    art.player.play("thinking-classic",at:0,transition:0)
                    func render(_ t:Double)throws->CutoutPixels {
                        context.clear(CGRect(x:0,y:0,width:width,height:height));art.player.sample(at:t)
                        art.draw(in:context,anchor:CGPoint(x:400,y:20),scale:scale)
                        return try CutoutPixels(context.makeImage()!)
                    }
                    let baseline=try render(2.88)
                    var excludedPixels=0
                    if let polygon=attachment.maskOut,let part=art.parts.first {
                        let image=try CutoutPixels(part.image),path=CGMutablePath()
                        path.move(to:CGPoint(x:polygon[0][0],y:polygon[0][1]))
                        for p in polygon.dropFirst() {path.addLine(to:CGPoint(x:p[0],y:p[1]))};path.closeSubpath()
                        let rect=attachment.rect
                        for y in 0..<image.height {for x in 0..<image.width {
                            let point=CGPoint(x:rect[0]+(Double(x)+0.5)/Double(image.width)*rect[2],y:rect[1]+rect[3]-(Double(y)+0.5)/Double(image.height)*rect[3])
                            if path.contains(point) {
                                if image.rgba[(y*image.width+x)*4+3] != 0 {throw CutoutError.invalid("Rear hair exclusion left painted pixels")}
                                excludedPixels+=1
                            }
                        }}
                        if excludedPixels<1000 {throw CutoutError.invalid("Rear hair exclusion was not exercised")}
                    }
                    let radius=Int(ceil((rig.hairDeformations?.first?.maxOffset ?? 0)*rig.pointsPerPixel*scale))+3
                    let stride=width+1
                    var integral=[Int](repeating:0,count:(width+1)*(height+1))
                    for y in 0..<height {
                        var row=0
                        for x in 0..<width {
                            row += baseline.rgba[(y*width+x)*4+3]<254 ? 1:0
                            integral[(y+1)*stride+x+1]=integral[y*stride+x+1]+row
                        }
                    }
                    var protected=[Int]()
                    for y in radius..<(height-radius) {for x in radius..<(width-radius) {
                        let x0=x-radius,x1=x+radius+1,y0=y-radius,y1=y+radius+1
                        let count=integral[y1*stride+x1]-integral[y0*stride+x1]-integral[y1*stride+x0]+integral[y0*stride+x0]
                        if count==0 {protected.append((y*width+x)*4+3)}
                    }}
                    var holes=0,minimum=255,badFrames=0
                    for frame in 0...24 {
                        let pixels=try render(1.60+Double(frame)*0.04)
                        var frameHoles=0
                        for i in protected {minimum=min(minimum,Int(pixels.rgba[i]));if pixels.rgba[i]<253 {frameHoles+=1}}
                        if frameHoles>0 {
                            holes+=frameHoles;badFrames+=1
                            if !saved {
                                let image=try pixels.image(),d=CGImageDestinationCreateWithURL(out.appendingPathComponent("first-failure.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
                                CGImageDestinationAddImage(d,image,nil);precondition(CGImageDestinationFinalize(d));saved=true
                            }
                        }
                    }
                    let label=style.id+"/"+attachment.slot
                    rows.append(["layer":label,"protectedPixels":protected.count,"holes":holes,"badFrames":badFrames,"minimumAlpha":minimum,"excludedPixels":excludedPixels])
                    if holes>0 {failures.append(label)}
                }
            }
        }
        for style in original.variants.filter({$0.category=="hair" && !$0.attachments.isEmpty}) {
            let art=try CutoutArtwork(rig:original){resources.appendingPathComponent($0)};try art.select(["hair":style.id])
            let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            art.player.play("thinking-classic",at:0,transition:0)
            func draw(_ t:Double)throws->CutoutPixels {
                c.clear(CGRect(x:0,y:0,width:width,height:height));art.player.sample(at:t)
                art.draw(in:c,anchor:CGPoint(x:400,y:20),scale:4)
                return try CutoutPixels(c.makeImage()!)
            }
            let baseline=try draw(2.88),protected=opaqueInterior(baseline,12)
            var holes=0,minimum=255
            for frame in 0...24 {
                let pixels=try draw(1.6+Double(frame)*0.04)
                for i in protected {minimum=min(minimum,Int(pixels.rgba[i]));if pixels.rgba[i]<253 {holes+=1}}
            }
            rows.append(["layer":style.id+"/complete-character","protectedPixels":protected.count,"holes":holes,"minimumAlpha":minimum])
            if holes>0 {failures.append(style.id+"/complete-character")}
        }
        let report:[String:Any]=["layers":rows,"framesPerLayer":25,"displayScale":4,"failures":failures]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"))
        // Native head/neck contact sheet includes the same compositing order.
        let w=620,h=400,styles=original.variants.filter{$0.category=="hair" && !$0.attachments.isEmpty}
        let sheet=CGContext(data:nil,width:w*styles.count,height:h*2,bitsPerComponent:8,bytesPerRow:w*styles.count*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (column,style) in styles.enumerated() {
            let art=try CutoutArtwork(rig:original){resources.appendingPathComponent($0)};try art.select(["hair":style.id])
            art.player.play("thinking-classic",at:0,transition:0)
            for (row,t) in [1.65,1.92].enumerated() {
                let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.setFillColor(NSColor(calibratedWhite:0.15,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:w,height:h))
                art.player.sample(at:t);art.draw(in:c,anchor:CGPoint(x:original.anchor[0]-200,y:original.anchor[1]-470),scale:1/original.pointsPerPixel,blink:art.player.automaticBlink(at:t,fallback:0))
                sheet.draw(c.makeImage()!,in:CGRect(x:column*w,y:(1-row)*h,width:w,height:h))
            }
        }
        let png=CGImageDestinationCreateWithURL(out.appendingPathComponent("hairstyles-neck.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(png,sheet.makeImage()!,nil);precondition(CGImageDestinationFinalize(png))
        let full=CGContext(data:nil,width:width*styles.count,height:height,bitsPerComponent:8,bytesPerRow:width*styles.count*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (column,style) in styles.enumerated() {
            let art=try CutoutArtwork(rig:original){resources.appendingPathComponent($0)};try art.select(["hair":style.id])
            art.player.play("thinking-classic",at:0,transition:0);art.player.sample(at:1.76)
            full.saveGState();full.translateBy(x:Double(column*width),y:0)
            art.draw(in:full,anchor:CGPoint(x:400,y:20),scale:4);full.restoreGState()
        }
        let fullPNG=CGImageDestinationCreateWithURL(out.appendingPathComponent("hairstyles-full.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(fullPNG,full.makeImage()!,nil);precondition(CGImageDestinationFinalize(fullPNG))
        print(failures.isEmpty ? "PASS hair-layer opacity coverage and rear exclusions":"FAIL hair opacity coverage",failures,"layers",rows.count)
        if !failures.isEmpty {exit(1)}
    }
}
