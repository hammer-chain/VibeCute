import AppKit
import CoreImage
import CaptionCore

/// A fixed-size pose, sampled by the existing audio clock. No resource work on ticks.
struct OrangeHoodieSingingPose: Equatable {
    let first: Int
    let second: Int
    let blend: CGFloat
    static func transition(_ progress: Double) -> Self {
        let position = min(7, max(0, progress * 7))
        let first = Int(position)
        return Self(first:first,second:min(7,first+1),blend:CGFloat(position-Double(first)))
    }
    static func loop(_ phase: Double) -> Self {
        // BPM controls cycle duration; this character's sway needs equal timing
        // rather than the original character's accent/hold choreography.
        let position = (phase-floor(phase))*8
        let first = Int(position)
        return Self(first:8+first,second:8+(first+1)%8,blend:CGFloat(position-Double(first)))
    }
}

struct OrangeHoodieSingingPlayback {
    private var phase = SingingPerformance.Phase.seated
    private var phaseStart: TimeInterval = 0
    private var height: Double = 0
    private var sittingHeight: Double = 1
    mutating func sample(phase next: SingingPerformance.Phase, cycle: Double, at now: TimeInterval) -> OrangeHoodieSingingPose? {
        guard now.isFinite, cycle.isFinite else { return nil }
        if next != phase {
            if next == .sitting { sittingHeight = height }
            phase = next; phaseStart = now
        }
        let elapsed = max(0,now-phaseStart)
        switch phase {
        case .seated: height = 0; return nil
        case .rising:
            height = min(1,elapsed/SingingPerformance.transitionDuration)
            return .transition(height)
        case .singing: height = 1; return .loop(cycle)
        case .sitting:
            height = max(0,sittingHeight-elapsed/SingingPerformance.transitionDuration)
            return .transition(height)
        }
    }
}

/// Cached, floor-anchored sprites. Each pose uses one continuous transform.
final class OrangeHoodiePerformance {
    static let shared = OrangeHoodiePerformance()
    struct Registration: Decodable {
        struct Frame: Decodable { let mouth: [CGFloat]; let sole: CGFloat; let eyes: [[CGFloat]] }
        let scale: CGFloat
        let frames: [Frame]
    }
    private(set) var frames: [NSImage] = []
    private(set) var mouths: [NSPoint] = []
    private(set) var mouthRotations: [CGFloat] = []
    private var pixels: [CGImage] = []
    private var warpSources: [CIImage] = []
    private let warpContext = CIContext(options:[.cacheIntermediates:false])
    // Inverse sampling is continuous at the neckline; unlike clipped layers it
    // has no separately antialiased edges. Head/face pixels only translate.
    private let warp = CIWarpKernel(source:"""
        kernel vec2 riseWarp(float floorY, float neckY, float delta) {
            vec2 p = destCoord();
            float length = neckY-floorY;
            float t = clamp((p.y-floorY)/length,0.0,1.0);
            float ease = t*t*(3.0-2.0*t);
            return vec2(p.x,p.y-delta*ease);
        }
        """)
    private var lastWarp: (index:Int, delta:CGFloat, image:CGImage)?
    var available: Bool { frames.count == 16 && mouths.count == 16 && mouthRotations.count == 16 }
    static let canvas = NSSize(width:448,height:640)
    static let floor: CGFloat = 17
    private init() {
        let folder = "OrangeHoodieThinking/Performance"
        func resource(_ name: String, _ ext: String) -> URL? {
            Bundle.main.url(forResource:name,withExtension:ext,subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:ext,subdirectory:folder)
        }
        guard let url = resource("singing-atlas","png"), let image = NSImage(contentsOf:url),
              let atlas = image.cgImage(forProposedRect:nil,context:nil,hints:nil),
              atlas.width == 1024, atlas.height == 1536,
              let config = resource("registration","json"), let data = try? Data(contentsOf:config),
              let registration = try? JSONDecoder().decode(Registration.self,from:data),
              registration.frames.count == 16, registration.scale > 0,
              registration.frames.allSatisfy({ $0.mouth.count == 2 && $0.sole > $0.mouth[1] && $0.eyes.count == 2 && $0.eyes.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } && $0.eyes[1][0] > $0.eyes[0][0] }) else { return }
        let animation = MascotAnimation.orangeHoodie
        guard let seated = animation.frames.first else { return }
        func roll(_ eyes: [[CGFloat]]) -> CGFloat {
            // Source coordinates point down; AppKit drawing coordinates point up.
            atan2(eyes[0][1]-eyes[1][1],eyes[1][0]-eyes[0][0])
        }
        let referenceRoll = roll(registration.frames[0].eyes)
        for index in 0..<16 {
            guard let context = CGContext(data:nil,width:448,height:640,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let mouth: NSPoint
            if index == 0 {
                guard let cg = seated.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return }
                context.draw(cg,in:CGRect(x:32,y:0,width:384,height:512))
                mouth = NSPoint(x:32+animation.mouthRect.midX,y:animation.mouthRect.midY)
            } else {
                guard let tile = atlas.cropping(to:CGRect(x:index%4*256+3,y:index/4*384,width:253,height:384)) else { return }
                let frame = registration.frames[index], scale = registration.scale
                let x = 32+animation.mouthRect.midX-frame.mouth[0]*scale
                let y = Self.floor-(384-frame.sole)*scale
                context.draw(tile,in:CGRect(x:x+3*scale,y:y,width:253*scale,height:384*scale))
                mouth = NSPoint(x:32+animation.mouthRect.midX,y:Self.floor+(frame.sole-frame.mouth[1])*scale)
            }
            if index > 0, let data = context.data {
                // Match the seated palette once at load time, never on animation ticks.
                // Seated/standing blue medians: saturation .686/.820, value .667/.769.
                let bytes = data.assumingMemoryBound(to:UInt8.self)
                for offset in stride(from:0,to:context.bytesPerRow*640,by:4) {
                    let r = CGFloat(bytes[offset]), g = CGFloat(bytes[offset+1]), b = CGFloat(bytes[offset+2])
                    let maximum = max(r,g,b)
                    guard maximum > 0 else { continue }
                    let blue = min(1,max(0,(b-max(r,g))/maximum*6))
                    let brightness = 1-blue*(1-0.867)
                    for channel in 0..<3 {
                        let value = (maximum+(CGFloat(bytes[offset+channel])-maximum)*0.836)*brightness
                        bytes[offset+channel] = UInt8(min(255,max(0,value.rounded())))
                    }
                }
            }
            guard let cg = context.makeImage() else { return }
            frames.append(NSImage(cgImage:cg,size:Self.canvas)); mouths.append(mouth); pixels.append(cg)
            mouthRotations.append(index == 0 ? 0 : roll(registration.frames[index].eyes)-referenceRoll)
        }
        // The rise and the singing loop share their endpoint exactly.
        if available {
            frames[7] = frames[8]; mouths[7] = mouths[8]; pixels[7] = pixels[8]; mouthRotations[7] = mouthRotations[8]
            warpSources = pixels.map { CIImage(cgImage:$0) }
        }
    }
    func mouthCenter(for pose: OrangeHoodieSingingPose) -> NSPoint {
        let a = mouths[pose.first], b = mouths[pose.second], t = pose.blend
        if pose.first < 8 && pose.second < 8 {
            let progress = min(1,(CGFloat(pose.first)+t)/7)
            func ease(_ t: CGFloat) -> CGFloat { let t = min(1,max(0,t)); return t*t*(3-2*t) }
            let low = mouths[0].y-30
            let y = progress < 0.24
                ? mouths[0].y+(low-mouths[0].y)*ease(progress/0.24)
                : low+(mouths[7].y-low)*ease((progress-0.24)/0.76)
            // Explicit single-frame poses are used for asset inspection.
            if pose.first != pose.second { return NSPoint(x:a.x,y:y) }
        }
        return NSPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
    }
    func draw(pose: OrangeHoodieSingingPose, mouth: Int?, in rect: NSRect) {
        guard available, frames.indices.contains(pose.first), frames.indices.contains(pose.second) else { return }
        if pose.first == 0 && pose.blend == 0 {
            MascotAnimation.orangeHoodie.drawSeated(frame:0,mouth:mouth,
                in:NSRect(x:rect.minX+rect.width*32/448,y:rect.minY,width:rect.width*384/448,height:rect.height*512/640),
                at:0,motionAmount:0)
            return
        }
        let target = mouthCenter(for:pose)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x:rect.minX,y:rect.minY)
        context.scaleBy(x:rect.width/448,y:rect.height/640)
        let canvas = NSRect(origin:.zero,size:Self.canvas)
        func body(_ index: Int) {
            let source = mouths[index]
            context.saveGState()
            context.setAlpha(1); context.setBlendMode(.normal)
            let delta = target.y-source.y
            if abs(delta) < 0.0001 {
                context.draw(pixels[index],in:canvas)
            } else if let warp {
                let image: CGImage?
                if let cached = lastWarp, cached.index == index, cached.delta == delta { image = cached.image }
                else {
                    let extent = CGRect(x:0,y:0,width:448,height:640)
                    let warped = warp.apply(extent:extent,roiCallback:{ _,rect in rect.insetBy(dx:0,dy:abs(delta)+2) },
                        image:warpSources[index],arguments:[Self.floor,target.y-28,delta])
                    image = warped.flatMap { warpContext.createCGImage($0,from:extent) }
                    if let image { lastWarp = (index,delta,image) }
                }
                if let image { context.draw(image,in:canvas) }
            }
            // The whole face and the mouth share the same rigid translation.
            context.translateBy(x:target.x-source.x,y:delta)
            let animation = MascotAnimation.orangeHoodie
            if let mouth, mouth > 0, animation.mouths.indices.contains(mouth) {
                // Attach the patch in face-local coordinates before applying the
                // body transform, so its size and position follow the face exactly.
                context.translateBy(x:source.x,y:source.y)
                context.rotate(by:mouthRotations[index])
                let patch = NSRect(x:-animation.mouthRect.width/2,y:-animation.mouthRect.height/2,
                    width:animation.mouthRect.width,height:animation.mouthRect.height)
                NSBezierPath(ovalIn:patch).addClip()
                animation.mouths[mouth].draw(in:patch,from:.zero,operation:.sourceOver,fraction:1)
            }
            context.restoreGState()
        }
        // Independent drawings have different silhouettes. Crossfading them creates
        // duplicate eyes, hair and limbs even after mouth registration. Interpolate
        // the anchor continuously, but display only the nearest complete drawing.
        body(pose.blend < 0.5 ? pose.first : pose.second)
    }
}
