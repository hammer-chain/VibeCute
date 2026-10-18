import AppKit
import ImageIO

struct RainShelterPose: Equatable { var frame: Int; var mirrored: Bool }

/// Approved full-character poses with offline calibration and a basin-stow tail.
/// Decode once, bounded to 32 RGBA images (40 MiB), never filter pixels per tick.
final class DeepSeekRainArtwork {
    static let shared = DeepSeekRainArtwork()
    let frames: [NSImage]
    var available: Bool { frames.count == 32 }
    private init() {
        frames = (1...32).compactMap { index in
            let name = String(format:"frame-%02d",index), folder = "DeepSeekThinking/RainShelter"
            guard let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                    ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder),
                  let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                  let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
            else { return nil }
            return NSImage(cgImage:image,size:NSSize(width:512,height:640))
        }
    }
    static func canvas(in bounds: CGRect, scale: Double) -> CGRect {
        // 608px foot line; padding keeps enlarged hair and basin inside the panel.
        let h = 255*scale, w = 204*scale
        return CGRect(x:bounds.midX-w/2,y:8*scale-32*h/640,width:w,height:h)
    }
    static func body(in bounds: CGRect, scale: Double) -> CGRect {
        // Conservative union for both facings, all approved poses, and the basin.
        CGRect(x:bounds.midX-102*scale,y:2*scale,width:204*scale,height:212*scale)
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
