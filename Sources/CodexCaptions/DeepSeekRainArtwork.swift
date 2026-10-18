import AppKit
import ImageIO

struct RainShelterPose: Equatable { var frame: Int; var mirrored: Bool }

/// User-approved v5 full-character frames. Decode once, bounded to 24 RGBA images.
final class DeepSeekRainArtwork {
    static let shared = DeepSeekRainArtwork()
    let frames: [NSImage]
    var available: Bool { frames.count == 24 }
    private init() {
        frames = (1...24).compactMap { index in
            let name = String(format:"frame-%02d",index), folder = "DeepSeekThinking/RainShelter"
            guard let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                    ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder),
                  let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                  let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
            else { return nil }
            return NSImage(cgImage:image,size:NSSize(width:384,height:512))
        }
    }
    static func canvas(in bounds: CGRect, scale: Double) -> CGRect {
        // 480px foot line coincides with the normal seated sprite's 8pt baseline.
        let h = 204*scale, w = h*0.75
        return CGRect(x:bounds.midX-w/2,y:8*scale-32*h/512,width:w,height:h)
    }
    static func body(in bounds: CGRect, scale: Double) -> CGRect {
        // Conservative union for both facings, all approved poses, and the basin.
        CGRect(x:bounds.midX-73.5*scale,y:4*scale,width:147*scale,height:188*scale)
    }
    func draw(frame: Int, mirrored: Bool, in bounds: CGRect, scale: Double) {
        guard frames.indices.contains(frame) else { return }
        NSGraphicsContext.saveGraphicsState()
        if mirrored {
            NSGraphicsContext.current?.cgContext.translateBy(x:bounds.midX*2,y:0)
            NSGraphicsContext.current?.cgContext.scaleBy(x:-1,y:1)
        }
        frames[frame].draw(in:Self.canvas(in:bounds,scale:scale))
        NSGraphicsContext.restoreGraphicsState()
    }
}
