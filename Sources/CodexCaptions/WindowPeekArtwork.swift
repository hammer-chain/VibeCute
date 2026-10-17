import AppKit

final class WindowPeekArtwork {
    static let shared = WindowPeekArtwork()
    let frames: [NSImage]
    let swimFrames: [NSImage]
    let withdrawFrames: [NSImage]
    let withdrawalPoseY: [CGFloat]
    let withdrawalDistance: CGFloat
    var available: Bool { frames.count == 8 && withdrawFrames.count == 8 }
    var swimmingAvailable: Bool { swimFrames.count == 8 }
    static let edgeX: CGFloat = 352
    static let lowerBodyExtension: CGFloat = 832 - 640
    static let canvasHeight: CGFloat = 832
    static let gripY: CGFloat = 537
    // The complete peek is 740 px from crown to shoe; the standing grip
    // pose is 543 px. Extra source canvas must not enlarge the character.
    static let fullBodyScale: CGFloat = 543.0 / 740.0
    static func fullBodyRect(in base: NSRect) -> NSRect {
        let unit = base.width / 448
        return NSRect(x:base.minX+edgeX*unit*(1-fullBodyScale),
                      y:base.minY+gripY*unit*(1-fullBodyScale),
                      width:base.width*fullBodyScale,
                      height:canvasHeight*unit*fullBodyScale)
    }
    private init() {
        frames = (0..<8).compactMap { i in
            let name = String(format:"frame-%02d",i), folder = "DeepSeekThinking/Peek"
            let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder)
            return url.flatMap { NSImage(contentsOf:$0) }
        }
        swimFrames = (0..<8).compactMap { i in
            let name = String(format:"frame-%02d",i), folder = "DeepSeekThinking/Swim"
            let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder)
            return url.flatMap { NSImage(contentsOf:$0) }
        }
        withdrawFrames = (0..<8).compactMap { i in
            let name = String(format:"frame-%02d",i), folder = "DeepSeekThinking/Peek/Withdraw"
            let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder)
            return url.flatMap { NSImage(contentsOf:$0) }
        }
        // Once the palm releases, register the free poses to the last held
        // crown height. Their source canvases otherwise jump upward by 44 px.
        let tops: [CGFloat] = withdrawFrames.map { frame in
            guard let image=frame.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return 0 }
            let rep=NSBitmapImageRep(cgImage:image),alpha=rep.bitmapFormat.contains(.alphaFirst) ? 0 : rep.samplesPerPixel-1
            for y in 0..<image.height {for x in 0..<min(image.width,Int(Self.edgeX)) {
                if rep.bitmapData![y*rep.bytesPerRow+x*rep.samplesPerPixel+alpha]>200 {return CGFloat(y)}
            }}
            return 0
        }
        withdrawalPoseY=tops.enumerated().map { index,top in index>3 ? top-tops[3] : 0 }
        // The final pose must pass fully behind the border at the same size.
        // Derive travel from its alpha extent rather than a smaller old pose.
        if let image=withdrawFrames.last?.cgImage(forProposedRect:nil,context:nil,hints:nil) {
            let rep=NSBitmapImageRep(cgImage:image),alpha=rep.bitmapFormat.contains(.alphaFirst) ? 0 : rep.samplesPerPixel-1
            var left=image.width
            for y in 0..<image.height {for x in 0..<left {
                if rep.bitmapData![y*rep.bytesPerRow+x*rep.samplesPerPixel+alpha]>0 {left=x;break}
            }}
            withdrawalDistance=max(0,Self.edgeX-CGFloat(left))+8
        } else { withdrawalDistance=Self.edgeX }
    }
    static let withdrawalDuration = 1.35
    static func withdrawalFrame(at progress:Double) -> Int {
        min(7,max(0,Int((progress-0.08)/0.92*8)))
    }
}

final class WindowPeekSpriteView: NSView {
    var stroll = StrollTimeline.sample(at:0)!
    var peekFrame: Int?
    var concealment: Double?
    var swimFrame: Int?
    var swimBlend: Double = 1
    var swimOpacity: Double = 1
    var swimAngle: CGFloat = 0
    var braceAmount: Double?
    var braceMirrored: Bool?
    var headTurn: Double = 0
    var tailAngle: Double = 0
    var tailReveal: Double = 1
    var concealedBody = false
    var whistleTime: Double?
    var entryFrame: Int?
    var entryOffsetX: CGFloat = 0
    var coverFrame: Int?
    var coverPrepFrame: Int?
    var mirrored = false
    var layoutScale: CGFloat = 1
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if mirrored {
            NSGraphicsContext.current?.cgContext.translateBy(x:bounds.width,y:0)
            NSGraphicsContext.current?.cgContext.scaleBy(x:-1,y:1)
        }
        if let frame = swimFrame, WindowPeekArtwork.shared.swimFrames.indices.contains(frame) {
            let blend = min(1,max(0,swimBlend))
            if blend < 1 {
                let width = 147*layoutScale
                let standing = NSRect(x:bounds.midX-width/2,y:(bounds.height-226*layoutScale)/2+8*layoutScale,
                    width:width,height:width*640/448)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha((1-blend)*swimOpacity)
                DeepSeekStroll.shared.draw(stroll,animation:MascotAnimation.library[.deepseek]!,in:standing)
                NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.current?.cgContext.translateBy(x:bounds.midX,y:bounds.midY)
            NSGraphicsContext.current?.cgContext.rotate(by:swimAngle)
            let width = 224*layoutScale, height = width*448/640
            WindowPeekArtwork.shared.swimFrames[frame].draw(in:NSRect(x:-width/2,y:-height/2,width:width,height:height),
                from:.zero,operation:.sourceOver,fraction:blend*swimOpacity)
            return
        }
        let rect = NSRect(x:0,y:8*layoutScale,width:bounds.width,height:bounds.width*640/448)
        if let frame=entryFrame, WindowHideArtwork.shared.entryFrames.indices.contains(frame) {
            if frame == WindowHideArtwork.finalEntryFrame {
                WindowHideArtwork.shared.draw(in:rect.offsetBy(dx:entryOffsetX,dy:0),headTurn:0,tailAngle:tailAngle,tailReveal:tailReveal,concealedBody:concealedBody);return
            }
            WindowHideArtwork.shared.entryFrames[frame].draw(in:rect.offsetBy(dx:entryOffsetX,dy:0));return
        }
        if let frame=coverPrepFrame, WindowHideArtwork.shared.coverPrepFrames.indices.contains(frame) {
            WindowHideArtwork.shared.coverPrepFrames[frame].draw(in:rect);return
        }
        if let frame=coverFrame, WindowHideArtwork.shared.coverFrames.indices.contains(frame) {
            WindowHideArtwork.shared.coverFrames[frame].draw(in:rect);return
        }
        if let braceAmount {
            NSGraphicsContext.saveGraphicsState()
            if let braceMirrored, braceMirrored != mirrored {
                NSGraphicsContext.current?.cgContext.translateBy(x:bounds.width,y:0)
                NSGraphicsContext.current?.cgContext.scaleBy(x:-1,y:1)
            }
            WindowHideArtwork.shared.draw(in:rect,headTurn:headTurn,tailAngle:tailAngle,opacity:braceAmount,tailReveal:tailReveal,concealedBody:concealedBody)
            NSGraphicsContext.restoreGraphicsState()
            if braceAmount < 1 {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(1-braceAmount)
                drawStroll(in:rect)
                NSGraphicsContext.restoreGraphicsState()
            }
            return
        }
        if let progress = concealment {
            let rect=WindowPeekArtwork.fullBodyRect(in:rect)
            let time = min(1,max(0,progress)), unit = rect.width/448
            guard time < 1 else { return }
            let frame = WindowPeekArtwork.withdrawalFrame(at:time)
            func smooth(_ value:Double) -> Double { let t=min(1,max(0,value));return t*t*(3-2*t) }
            // Frame 4 releases the palm. Keep one continuous retreat through
            // both steps; two separately eased translations caused a full stop.
            let retreat=smooth((time-0.54)/0.40)
            let offset=CGFloat(retreat)*WindowPeekArtwork.shared.withdrawalDistance*unit
            let bob = (WindowPeekArtwork.shared.withdrawalPoseY[frame]
                - CGFloat(pow(sin(retreat*2*Double.pi),2))*8)*unit
            NSGraphicsContext.saveGraphicsState()
            // Preserve the canonical peek, then let the actual edge hide each
            // successive articulated pose. No opacity fade is used.
            let clipWidth = rect.minX+(WindowPeekArtwork.edgeX+(frame <= 3 ? 8 : 0))*unit
            NSRect(x:0,y:0,width:clipWidth,height:bounds.height).clip()
            WindowPeekArtwork.shared.withdrawFrames[frame].draw(in:rect.offsetBy(dx:offset,dy:bob))
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if let frame = peekFrame, WindowPeekArtwork.shared.frames.indices.contains(frame) {
            let full=WindowPeekArtwork.fullBodyRect(in:rect)
            NSRect(x:0,y:0,width:full.minX+(WindowPeekArtwork.edgeX+8)*full.width/448,height:bounds.height).clip()
            WindowPeekArtwork.shared.frames[frame].draw(in:full)
        } else {
            drawStroll(in:rect)
        }
    }
    private func drawStroll(in rect:NSRect) {
        DeepSeekStroll.shared.draw(stroll,animation:MascotAnimation.library[.deepseek]!,in:rect)
        if let time = whistleTime { WindowHideArtwork.shared.drawWhistle(stroll,in:rect,time:time) }
    }
}

/// A complete layered pose: only the WindowServer wall occludes the body.
final class WindowHideArtwork {
    static let shared = WindowHideArtwork()
    static let wallX: CGFloat = 148
    static let tailPivot = NSPoint(x:185,y:208)
    static let finalEntryFrame = 9
    static let coverFrameDuration = 0.075
    let body: NSImage?, tail: NSImage?, heads: [NSImage]
    let entryFrames:[NSImage], coverFrames:[NSImage], coverPrepFrames:[NSImage]
    var available: Bool { body != nil && tail != nil && heads.count == 3 && entryFrames.count == 12 && coverFrames.count == 8 && coverPrepFrames.count == 4 }
    private init() {
        func image(_ name:String) -> NSImage? {
            let folder = "DeepSeekThinking/Hide"
            let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder)
            return url.flatMap { NSImage(contentsOf:$0) }
        }
        body = image("body"); tail = image("tail"); heads = (0..<3).compactMap { image("head-\($0)") }
        entryFrames=(0..<12).compactMap { image(String(format:"Entry/frame-%02d",$0)) }
        coverFrames=(0..<8).compactMap { image(String(format:"Cover/frame-%02d",$0)) }
        coverPrepFrames=(0..<4).compactMap { image(String(format:"CoverPrep/frame-%02d",$0)) }
    }
    static func tailAngle(at time:Double) -> Double { sin(time*2*Double.pi/3.6)*4*Double.pi/180 }
    static func tailReveal(at parkedTime:Double) -> Double {
        let t=min(1,max(0,(parkedTime-0.2)/0.9))
        return t*t*(3-2*t)
    }
    func draw(in rect:NSRect,headTurn:Double,tailAngle:Double,opacity:Double = 1,tailReveal:Double = 1,concealedBody:Bool = false) {
        guard available else { return }
        let unit = rect.width/448, turn = min(2,max(0,headTurn)), lower = Int(turn), upper = min(2,lower+1)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext.current!.cgContext
        context.setAlpha(opacity)
        let reveal=min(1,max(0,tailReveal))
        // Keep the root fixed behind the window: the tip arcs overhead before settling down.
        context.translateBy(x:rect.minX+Self.tailPivot.x*unit,y:rect.minY+Self.tailPivot.y*unit)
        context.rotate(by:-(1-reveal)*Double.pi+tailAngle*reveal)
        tail!.draw(in:rect.offsetBy(dx:-rect.minX-Self.tailPivot.x*unit,dy:-rect.minY-Self.tailPivot.y*unit))
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if concealedBody {
            NSRect(x:rect.minX+Self.wallX*unit,y:rect.minY,width:rect.width-Self.wallX*unit,height:rect.height).clip()
        }
        body!.draw(in:rect,from:.zero,operation:.sourceOver,fraction:opacity)
        // Only the head turns; hands, body and feet retain identical pixels.
        if lower == upper || turn == Double(lower) {
            heads[lower].draw(in:rect,from:.zero,operation:.sourceOver,fraction:opacity)
        } else {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:448,pixelsHigh:640,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
            let frame = NSRect(x:0,y:0,width:448,height:640), blend = turn-Double(lower)
            heads[lower].draw(in:frame,from:.zero,operation:.copy,fraction:1-blend)
            heads[upper].draw(in:frame,from:.zero,operation:.plusLighter,fraction:blend)
            NSGraphicsContext.restoreGraphicsState()
            NSImage(cgImage:bitmap.cgImage!,size:frame.size).draw(in:rect,from:.zero,operation:.sourceOver,fraction:opacity)
        }
    }
    func drawWhistle(_ sample:StrollTimeline.Sample,in rect:NSRect,time:Double) {
        guard let frame = sample.frame, (12..<20).contains(frame) else { return }
        let bounce: [CGFloat] = [0,-3,-8,-3,8.31,-3,-8,-3]
        let unit = rect.width/448, mouth = NSPoint(x:366,y:640-259-bounce[frame-12])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x:rect.minX,y:rect.minY)
        NSGraphicsContext.current?.cgContext.scaleBy(x:unit,y:unit)
        // A small skin patch replaces the smile with pursed lips, following the face bounce.
        NSColor(calibratedRed:1,green:0.875,blue:0.785,alpha:1).setFill()
        NSBezierPath(ovalIn:NSRect(x:mouth.x-7,y:mouth.y-5,width:14,height:10)).fill()
        NSColor(calibratedRed:0.67,green:0.28,blue:0.25,alpha:1).setStroke()
        let lips = NSBezierPath(ovalIn:NSRect(x:mouth.x-2,y:mouth.y-3,width:5,height:7))
        lips.lineWidth = 1.5; lips.stroke()
        for i in 0..<2 {
            let p = (time/1.2+Double(i)/2).truncatingRemainder(dividingBy:1)
            let x = mouth.x+12+CGFloat(p)*25, y = mouth.y+18+CGFloat(p)*35
            NSColor(calibratedRed:0.23,green:0.5,blue:0.72,alpha:sin(p*Double.pi)).setFill()
            NSBezierPath(ovalIn:NSRect(x:x,y:y,width:8,height:5)).fill()
            NSRect(x:x+6,y:y+2,width:2,height:14).fill()
            let flag = NSBezierPath(); flag.move(to:NSPoint(x:x+7,y:y+16))
            flag.line(to:NSPoint(x:x+14,y:y+12)); flag.line(to:NSPoint(x:x+14,y:y+9));
            flag.line(to:NSPoint(x:x+7,y:y+13)); flag.close(); flag.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
