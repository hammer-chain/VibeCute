import AppKit
import ImageIO

final class CrabPetArtwork {
    static let shared = CrabPetArtwork()
    let frames:[NSImage]
    var available:Bool {frames.count==24}
    private init() {
        frames=(0..<24).compactMap {index in
            let name=String(format:"frame-%02d",index),folder="OrangeHoodieThinking/CrabPet"
            guard let url=Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder),
                let src=CGImageSourceCreateWithURL(url as CFURL,nil),
                let im=CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {return nil}
            return NSImage(cgImage:im,size:NSSize(width:640,height:640))
        }
    }
    static func canvas(in bounds:CGRect,scale:Double)->CGRect {
        CGRect(x:bounds.midX-105*scale,y:bounds.minY+8*scale,width:210*scale,height:210*scale)
    }
    // Registered contact point in the transparent sprite, in top-left source pixels.
    static let palm=CGPoint(x:480,y:493)
    static func palmOffset(in bounds:CGRect,scale:Double,mirrored:Bool)->CGPoint {
        let rect=canvas(in:bounds,scale:scale)
        return CGPoint(x:rect.minX+(mirrored ? 640-palm.x:palm.x)*rect.width/640,
                       y:rect.maxY-palm.y*rect.height/640)
    }
    func draw(_ pose:CrabPetPose,in bounds:CGRect,scale:Double) {
        guard frames.indices.contains(pose.frame) else {return}
        NSGraphicsContext.saveGraphicsState();defer {NSGraphicsContext.restoreGraphicsState()}
        if pose.mirrored && pose.frame >= 3 {
            NSGraphicsContext.current?.cgContext.translateBy(x:bounds.midX*2,y:0)
            NSGraphicsContext.current?.cgContext.scaleBy(x:-1,y:1)
        }
        frames[pose.frame].draw(in:Self.canvas(in:bounds,scale:scale))
    }
}
