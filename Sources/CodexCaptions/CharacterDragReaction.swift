import AppKit

/// Whole-art response driven by the existing common-mode refresh clock.
/// One fixed state per active drag; no images, timers or history buffers.
struct CharacterDragReaction {
    private(set) var active = false
    private(set) var dragging = false
    private(set) var weight: CGFloat = 0
    private(set) var lean: CGFloat = 0
    private var position = NSPoint.zero
    private var lastTime: TimeInterval = 0
    private var releasedAt: TimeInterval?
    private var startedAt: TimeInterval = 0
    private var releaseFrame = 0
    private(set) var frameIndex: Int?
    static let artTick = 0.12
    static let releaseDuration = 0.84
    // Finish through the already smooth lift poses in reverse: hands move
    // inward before the original chin-rest pose, avoiding the lap-to-chin cut.
    static let landingSequence = [8, 9, 1, 0, 0, 0]

    mutating func begin(at point: NSPoint, time: TimeInterval) {
        active = true; dragging = true; releasedAt = nil
        position = point; lastTime = time; weight = 0.35; lean = 0
        startedAt = time; frameIndex = 0
    }
    mutating func end(at time: TimeInterval) {
        guard active, dragging else { return }
        dragging = false; releasedAt = time; releaseFrame = frameIndex ?? 0
    }
    mutating func reset() { self = Self() }
    @discardableResult
    mutating func update(at point: NSPoint, time: TimeInterval, scale: CGFloat) -> Bool {
        guard active else { return false }
        let oldWeight = weight, oldLean = lean
        let oldFrame = frameIndex
        let rawDT = time-lastTime
        guard rawDT > 0 else { return false }
        let dt = min(rawDT, 0.05)
        let factor = CGFloat(1-exp(-dt/0.075))
        let speed = dragging && rawDT < 0.2 ? (point.x-position.x)/CGFloat(rawDT)/max(scale,0.25) : 0
        let targetLean = dragging ? min(2.5,max(-2.5,-speed*0.004)) : 0
        weight += ((dragging ? 1 : 0)-weight)*factor
        lean += (targetLean-lean)*factor
        position = point; lastTime = time
        if let releasedAt {
            let elapsed = time-releasedAt
            let step = Int(max(0,elapsed)/Self.artTick)
            if elapsed >= Self.releaseDuration { reset() }
            else if releaseFrame < 4 { frameIndex = max(0,releaseFrame-step) }
            else { frameIndex = step == 0 ? releaseFrame : Self.landingSequence[min(step-1,Self.landingSequence.count-1)] }
        } else {
            let step = Int(max(0,time-startedAt)/Self.artTick)
            frameIndex = step < 4 ? step : 4+(step-4)%4
        }
        return oldFrame != frameIndex || abs(weight-oldWeight)>0.0001 || abs(lean-oldLean)>0.0001
    }
    func transform(in rect: NSRect, scale: CGFloat) -> CGAffineTransform {
        guard active else { return .identity }
        let center = NSPoint(x:rect.midX,y:rect.minY+rect.height*0.45)
        let angle = lean * .pi/180
        let sx = 1+0.012*weight, sy = 1-0.016*weight
        let a = cos(angle)*sx, b = sin(angle)*sx
        let c = -sin(angle)*sy, d = cos(angle)*sy
        return CGAffineTransform(a:a,b:b,c:c,d:d,
            tx:center.x-a*center.x-c*center.y,
            ty:center.y+2*scale*weight-b*center.x-d*center.y)
    }
}


/// Twelve complete poses, decoded once and shared across character windows.
final class CharacterDragArtwork {
    static let shared = CharacterDragArtwork()
    let frames: [NSImage]
    let loadSeconds: Double
    var available: Bool { frames.count == 12 }
    var decodedBytes: Int { frames.count*384*512*4 }
    init(directory: URL? = nil) {
        let start = ProcessInfo.processInfo.systemUptime
        var root = directory ?? Bundle.main.resourceURL?.appendingPathComponent("DeepSeekThinking/Drag")
        if directory == nil, root.map({ !FileManager.default.fileExists(atPath:$0.path) }) ?? true {
            root = Bundle.module.resourceURL?.appendingPathComponent("DeepSeekThinking/Drag")
        }
        frames = (0..<12).compactMap { i in
            guard let url = root?.appendingPathComponent(String(format:"drag-%02d.png",i)),
                  let image = NSImage(contentsOf:url),
                  let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil), cg.width == 384, cg.height == 512,
                  let c = CGContext(data:nil,width:384,height:512,bitsPerComponent:8,bytesPerRow:1536,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.draw(cg,in:CGRect(x:0,y:0,width:384,height:512))
            return c.makeImage().map { NSImage(cgImage:$0,size:NSSize(width:384,height:512)) }
        }
        loadSeconds = ProcessInfo.processInfo.systemUptime-start
    }
    func draw(frame: Int, in rect: NSRect) {
        guard frames.indices.contains(frame) else { return }
        frames[frame].draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
    }
}
