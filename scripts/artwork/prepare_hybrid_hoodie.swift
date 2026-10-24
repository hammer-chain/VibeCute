import AppKit
import ImageIO

// Register generated UNDERPAINTINGS only. The visible body remains original pixels.
let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
func prepare(_ source:String, _ output:String, transform:CGAffineTransform, clip:CGRect) throws {
    let url=root.appendingPathComponent("artwork/hybrid-hoodie/\(source).png")
    let image=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
    let ctx=CGContext(data:nil,width:384,height:512,bitsPerComponent:8,bytesPerRow:384*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    // All registration coordinates below are source top-left pixels.
    ctx.translateBy(x:0,y:512);ctx.scaleBy(x:1,y:-1)
    ctx.clip(to:clip)
    ctx.concatenate(transform)
    ctx.translateBy(x:0,y:CGFloat(image.height));ctx.scaleBy(x:1,y:-1)
    ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    let target=root.appendingPathComponent("Sources/CodexCaptions/Resources/OrangeHoodieThinking/Hybrid/\(output).png")
    let dst=CGImageDestinationCreateWithURL(target as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(dst,ctx.makeImage()!,nil);precondition(CGImageDestinationFinalize(dst))
}
try prepare("body-underpainting-source","body-underpainting",transform:CGAffineTransform(a:0.33,b:0,c:0,d:0.33,tx:2,ty:57),clip:CGRect(x:99,y:233,width:164,height:96))
try prepare("chin-underpainting-source","face-underpainting",transform:CGAffineTransform(a:140.0/496,b:0,c:0,d:137.0/450,tx:106-294*140.0/496,ty:118-456*137.0/450),clip:CGRect(x:106,y:118,width:140,height:139))
