import AppKit

/// Decoded on first use only; the 24-frame loop retains its authored 120 ms clock.
final class WindowSeatArtwork {
    static let shared = WindowSeatArtwork()
    static let canvas = NSSize(width:448,height:640)
    static let anchor = NSPoint(x:210,y:205) // authored [210,435], top-left coordinates
    static let unit:CGFloat = 147.0/448
    static let transitionFrameCount = 9
    static let transitionDuration = 1.92
    static let loopFrameDuration = 0.12
    static let balanceFrameCount = 10
    static let balanceRiseDuration = 0.72
    static let balanceReturnDuration = 0.9
    static let balanceHoldDuration = 0.35
    static let leanLimit = 15.0
    static let horizontalPadding:CGFloat = 80 // source pixels; the character keeps its original scale
    let transitions: [NSImage]
    let frames: [NSImage]
    let balance:[NSImage]
    let pressureFaces:[NSImage],blinkFaces:[NSImage],restFaces:[NSImage],irises:[NSImage]
    let happyMouths:[NSImage]
    let eyeBase:NSImage?
    let irisRects:[NSRect]
    let balanceBottoms:[CGFloat],transitionBottoms:[CGFloat]
    var available:Bool { transitions.count == Self.transitionFrameCount && frames.count == 24 && balance.count == Self.balanceFrameCount && pressureFaces.count == 49 && blinkFaces.count == 17 && restFaces.count == 17 && happyMouths.count == 17 && irises.count == 2 && irisRects.count == 2 && eyeBase != nil }
    private init() {
        func load(_ folder:String,_ count:Int)->[NSImage] {
            (0..<count).compactMap { i in
                let name=String(format:"frame-%02d",i), path="DeepSeekThinking/WindowSeat/"+folder
                let url=Bundle.main.url(forResource:name,withExtension:"png",subdirectory:path)
                    ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:path)
                return url.flatMap { NSImage(contentsOf:$0) }
            }
        }
        transitions=load("Transition",Self.transitionFrameCount);frames=load("Loop",24)
        balance=load("Balance",Self.balanceFrameCount)
        happyMouths=load("Happy",17)
        func patch(_ name:String)->NSImage? {
            let path="DeepSeekThinking/WindowSeat/Pressure"
            return (Bundle.main.url(forResource:name,withExtension:"png",subdirectory:path)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:path)).flatMap{NSImage(contentsOf:$0)}
        }
        pressureFaces=(0...48).compactMap{patch(String(format:"pressure-%02d",$0))}
        blinkFaces=(0...16).compactMap{patch(String(format:"blink-%02d",$0))}
        restFaces=(0...16).compactMap{patch(String(format:"rest-%02d",$0))}
        irises=(0...1).compactMap{patch("iris-\($0)")};eyeBase=patch("eye-base")
        let manifestURL=Bundle.main.url(forResource:"manifest",withExtension:"json",subdirectory:"DeepSeekThinking/WindowSeat/Pressure")
            ?? Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"DeepSeekThinking/WindowSeat/Pressure")
        let manifest=manifestURL.flatMap{try? Data(contentsOf:$0)}.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        irisRects=(manifest?["irisRects"] as? [[Double]] ?? []).compactMap { row in
            guard row.count==4 else {return nil}
            return NSRect(x:row[0],y:row[1],width:row[2],height:row[3])
        }
        // Ground contact metadata is measured once, never scanned in tick/draw.
        func bottom(_ image:NSImage)->CGFloat {
            let rep=NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            for y in stride(from:639,through:0,by:-1) {
                for x in 130..<290 where rep.colorAt(x:x,y:y)!.alphaComponent>0.8 {return CGFloat(639-y)}
            }
            return 0
        }
        balanceBottoms=balance.map(bottom);transitionBottoms=transitions.map(bottom)
    }

}

/// Estimate horizontal inertia from the existing window samples. Filtering
/// velocity before differentiating avoids amplifying pixel/timing jitter.
struct WindowSeatInertia {
    private(set) var velocity=0.0
    private(set) var acceleration=0.0
    var leanDegrees:Double {
        let magnitude=max(0,abs(acceleration)-35) // ignore small quantization noise
        let angle=min(WindowSeatArtwork.leanLimit,atan(magnitude/3200)*180 / .pi)
        return acceleration<0 ? -angle : angle
    }
    mutating func sample(displacement:Double,interval:Double) {
        guard interval>0,interval<=0.25,displacement.isFinite else {
            self=Self();return // a suspended clock must not reuse stale velocity
        }
        let previous=velocity
        velocity += (displacement/interval-velocity)*(1-exp(-interval/0.10))
        let measured=(velocity-previous)/interval
        acceleration += (measured-acceleration)*(1-exp(-interval/0.08))
    }
}

/// One pressure clock drives posture, gaze, expression and leg motion. No new
/// timer or window query is introduced. Release is deliberately slower.
struct WindowSeatPressure {
    private(set) var amount=0.0,lean=0.0,gaze=0.0,legPhase=0.0,blink=0.0
    private(set) var overload=0.0
    private var blinkClock=0.0,blinkElapsed:Double?
    var focus:Double { amount/3 }
    var tier:Int { amount<0.12 ? 0 : amount<1 ? 1 : amount<2 ? 2 : 3 }
    var legAmplitude:Double { 3*max(0,1-amount/2) }
    var legSpeed:Double { max(0,1-amount/2) }
    var legAngle:Double {sin(legPhase)*legAmplitude}
    var shouldFall:Bool {overload>=0.16 && amount>2.4 && abs(lean)>12}
    static func load(for angle:Double)->Double {
        let a=abs(angle)
        if a<0.5 {return 0}
        if a<5 {return a/5}
        if a<12 {return 1+(a-5)/7}
        return min(3,2+(a-12)/3)
    }
    mutating func step(angle:Double,acceleration:Double,delta:Double) {
        let dt=min(0.05,max(0,delta)),target=Self.load(for:angle)
        let change=(angle-lean)*(1-exp(-dt/0.14))
        lean += min(45*dt,max(-45*dt,change))
        if abs(lean)<0.08 && angle==0 {lean=0}
        amount += (target-amount)*(1-exp(-dt/(target>amount ? 0.12 : 0.48)))
        if target==0 && amount<0.015 {amount=0}
        // Positive AppKit rotation moves the head left; positive gaze moves
        // the irises right. Gaze follows rendered lean through reversals.
        gaze=(lean/15)*6 // lean is already smoothed; another lag can look the wrong way at reversal
        legPhase += dt*2 * .pi/2.88*legSpeed
        blinkClock += dt
        if blinkElapsed==nil && amount<0.12 && blinkClock>=3.4 {blinkElapsed=0;blinkClock=0}
        if let elapsed=blinkElapsed {
            let next=elapsed+dt
            blink=max(0,1-abs(next-0.12)/0.12)
            blinkElapsed=next<0.24 ? next : nil
        } else {blink=0}
        if abs(acceleration)>1800 {overload += dt} else {overload=max(0,overload-dt*2)}
    }
}

/// Quiet, curious glances like the window peek. Sample on the existing leg
/// frame clock: pauses between glances matter more than continuous eye motion.
struct WindowSeatIdleExpression {
    var x=0.0,y=0.0,smile=0.0
    static func sample(at time:Double)->Self {
        let t=max(0,time).truncatingRemainder(dividingBy:14.4)
        func pulse(_ start:Double,_ end:Double)->Double {
            guard t>start && t<end else {return 0}
            let u=min(1,min((t-start)/0.72,(end-t)/0.72))
            return u*u*(3-2*u)
        }
        let left=pulse(1.8,4.2),right=pulse(6.6,9.6),smile=pulse(11.4,13.8)
        return Self(x:-4*left+4*right,y:1.5*left+2*right,smile:smile)
    }
}

final class WindowSeatSpriteView:NSView {
    var image:NSImage?
    var stroll:StrollTimeline.Sample?
    var mirrored=false
    var upperLeanDegrees:Double=0
    var focusAmount:Double?
    var gazeOffset=0.0,gazeOffsetY=0.0,blinkAmount=0.0,legSwingDegrees=0.0,bodyRotation=0.0
    var smileAmount=0.0
    var faceOpacity=1.0
    var artworkRect:NSRect {
        let unit=bounds.height/WindowSeatArtwork.canvas.height
        return NSRect(x:WindowSeatArtwork.horizontalPadding*unit,y:0,width:448*unit,height:bounds.height)
    }
    override func draw(_ dirtyRect:NSRect) {
        let rect=artworkRect
        if let stroll {
            NSGraphicsContext.saveGraphicsState()
            if mirrored {NSGraphicsContext.current?.cgContext.translateBy(x:bounds.width,y:0);NSGraphicsContext.current?.cgContext.scaleBy(x:-1,y:1)}
            DeepSeekStroll.shared.draw(stroll,animation:MascotAnimation.library[.deepseek]!,in:rect)
            NSGraphicsContext.restoreGraphicsState()
        } else if let image {
            guard let context=NSGraphicsContext.current?.cgContext else {return}
            let unit=rect.height/640
            context.saveGState()
            defer {context.restoreGState()}
            if bodyRotation != 0 {
                let pivot=NSPoint(x:rect.minX+210*unit,y:226*unit)
                context.translateBy(x:pivot.x,y:pivot.y);context.rotate(by:bodyRotation * .pi/180)
                context.translateBy(x:-pivot.x,y:-pivot.y)
            }
            guard upperLeanDegrees != 0 || legSwingDegrees != 0 else {drawUpperArtwork(image,in:rect);return}
            // Legs remain together and raised, independent of the upper-body
            // counter-lean. The thigh bridge below connects the two joint edges.
            let legs=NSRect(x:rect.minX+143*unit,y:0,width:142*unit,height:200*unit)
            context.saveGState()
            let pivot=NSPoint(x:rect.minX+210*unit,y:226*unit)
            context.translateBy(x:pivot.x,y:pivot.y)
            context.rotate(by:upperLeanDegrees * .pi/180)
            context.translateBy(x:-pivot.x,y:-pivot.y)
            let path=CGMutablePath();path.addRect(rect)
            path.addRect(NSRect(x:legs.minX,y:0,width:legs.width,height:226*unit))
            context.addPath(path);context.clip(using:.evenOdd)
            drawUpperArtwork(image,in:rect);context.restoreGState()
            // The rotating hair/tail stays behind the complete raised legs.
            context.saveGState()
            context.translateBy(x:pivot.x,y:pivot.y);context.rotate(by:legSwingDegrees * .pi/180)
            context.translateBy(x:-pivot.x,y:-pivot.y)
            context.clip(to:legs);image.draw(in:rect);context.restoreGState()
            // The tiny thigh joint follows the rotated pelvis at its top and
            // the raised knees at its bottom. Face, torso, skirt and shoes stay
            // rigid; a two-triangle mapping closes the hip seam at ±15 degrees.
            func point(_ x:CGFloat,_ y:CGFloat)->CGPoint {CGPoint(x:rect.minX+x*unit,y:y*unit)}
            func rotate(_ p:CGPoint,_ angle:Double)->CGPoint {
                let a=angle * .pi/180,dx=p.x-pivot.x,dy=p.y-pivot.y
                return CGPoint(x:pivot.x+dx*cos(a)-dy*sin(a),y:pivot.y+dx*sin(a)+dy*cos(a))
            }
            let source=[point(143,226),point(285,226),point(285,200),point(143,200)]
            let destination=source.enumerated().map{rotate($0.element,$0.offset<2 ? upperLeanDegrees : legSwingDegrees)}
            for indices in [[0,1,2],[0,2,3]] {
                let s=indices.map{source[$0]},d=indices.map{destination[$0]}
                drawJoint(image,in:rect,source:s,destination:d,context:context)
            }
        }
    }
    private func drawJoint(_ image:NSImage,in rect:NSRect,source s:[CGPoint],destination d:[CGPoint],context:CGContext) {
        let ax=s[1].x-s[0].x,ay=s[1].y-s[0].y,bx=s[2].x-s[0].x,by=s[2].y-s[0].y
        let ux=d[1].x-d[0].x,uy=d[1].y-d[0].y,vx=d[2].x-d[0].x,vy=d[2].y-d[0].y,det=ax*by-ay*bx
        let a=(ux*by-vx*ay)/det,b=(uy*by-vy*ay)/det,c=(vx*ax-ux*bx)/det,e=(vy*ax-uy*bx)/det
        let transform=CGAffineTransform(a:a,b:b,c:c,d:e,tx:d[0].x-a*s[0].x-c*s[0].y,ty:d[0].y-b*s[0].x-e*s[0].y)
        context.saveGState()
        let path=CGMutablePath();path.addLines(between:d);path.closeSubpath();context.addPath(path);context.clip()
        context.concatenate(transform);image.draw(in:rect);context.restoreGState()
    }
    private func drawUpperArtwork(_ image:NSImage,in rect:NSRect) {
        image.draw(in:rect)
        guard let focusAmount else {return}
        let unit=rect.height/640
        let face=NSRect(x:rect.minX+132*unit,y:rect.minY+365*unit,width:170*unit,height:91*unit)
        let art=WindowSeatArtwork.shared,pressure=min(3,max(0,focusAmount*3))
        guard art.available,let context=NSGraphicsContext.current?.cgContext else {return}
        if focusAmount==0 && gazeOffset==0 && gazeOffsetY==0 {
            art.restFaces[min(16,Int((blinkAmount*16).rounded()))].draw(in:face,from:.zero,operation:.sourceOver,fraction:faceOpacity)
            drawSmile(in:rect,opacity:faceOpacity)
            return
        }
        context.saveGState()
        if faceOpacity<1 {context.setAlpha(faceOpacity);context.beginTransparencyLayer(auxiliaryInfo:nil)}
        art.eyeBase?.draw(in:face)
        let shrink=1-0.3*max(0,pressure-2)
        for (i,box) in art.irisRects.enumerated() {
            art.irises[i].draw(in:NSRect(x:rect.minX+(box.midX+gazeOffset-box.width/2*shrink)*unit,
                y:rect.minY+(640-box.midY+gazeOffsetY-box.height/2*shrink)*unit,width:box.width*shrink*unit,height:box.height*shrink*unit))
        }
        let foreground=blinkAmount>0 ? art.blinkFaces[min(16,Int((blinkAmount*16).rounded()))]
            : art.pressureFaces[min(48,Int((pressure*16).rounded()))]
        foreground.draw(in:face)
        drawSmile(in:rect)
        if faceOpacity<1 {context.endTransparencyLayer()};context.restoreGState()
    }
    private func drawSmile(in rect:NSRect,opacity:Double=1) {
        guard smileAmount>0 else {return}
        let unit=rect.height/640,index=min(16,Int((smileAmount*16).rounded()))
        WindowSeatArtwork.shared.happyMouths[index].draw(in:NSRect(x:rect.minX+194*unit,y:rect.minY+372*unit,width:28*unit,height:22*unit),from:.zero,operation:.sourceOver,fraction:opacity)
    }
}

/// Translate the authored support anchor with its window. The same animation
/// clock raises/retracts the limbs, and unwinds them before a support-loss return.
final class WindowSeatMotion {
    let panel:NSWindow
    let view=WindowSeatSpriteView()
    let original:NSRect,initial:NSRect
    private(set) var destination:NSRect,landing:NSRect,restRig:NSRect
    private(set) var target:DesktopWindowTarget
    let startedAt:Double
    private(set) var leavingAt:Double?
    private(set) var reason=""
    private(set) var artworkFrame = -1
    private(set) var refreshCount=0, redrawCount=0
    private(set) var lastRefresh:Double
    private var leaveProgress = 1.0
    private var leaveEntryTime = 0.0
    private var lastKey = ""
    private var leaveLoopFrame=0
    private var lastTick:Double
    private var lastOrder:Double
    private var lastMovement = -Double.infinity
    private var loopEpoch:Double?
    private var preparationAt:Double?
    private var preparationFrames:[Int]=[]
    private var leaveBalanceProgress=0.0
    private(set) var balanceProgress=0.0
    private(set) var balanceFrame=0
    private(set) var upperLeanDegrees=0.0
    private var wantedLeanDegrees=0.0
    private var inertia=WindowSeatInertia()
    private var pressure=WindowSeatPressure()
    private(set) var returnFrame:NSRect
    enum FallCause:String {case acceleration,supportLost,spaceChanged}
    private struct Fall {
        let startedAt:Double,from:NSRect,to:NSRect,duration:Double,rotation:Double,progress:Double
        let ground:CGFloat
        let cause:FallCause,poses:[(image:NSImage,frame:Int)],poseDuration:Double,leg:Double
    }
    private var fall:Fall?
    private var pendingSpaceChange=false
    private var sizeChangeSince:Double?
    private var lastSizeChangeAt=0.0
    private var lastSizeChangeFrame=NSRect.zero
    var isFalling:Bool {fall != nil}
    private(set) var focusAmount=0.0
    private var leaveFocusAmount=0.0
    private var leaveBlinkAmount=0.0
    private var leaveSmileAmount=0.0
    private var leaveLeanDegrees=0.0
    private var lastBalanceDrawAt = -Double.infinity
    private var drawnBalanceFrame = -1
    private(set) var moveCount=0
    private(set) var querySeconds=0.0
    private(set) var maxQuerySeconds=0.0
    static let restingQueryInterval=0.05
    static let movingQueryInterval=1.0/60
    let travelDuration:Double
    static let riseDuration=StrollTimeline.steps.prefix{$0.phase != .walking}.reduce(0){$0+$1.duration}
    static let walkEnd=riseDuration+Double(StrollTimeline.walkFrames.count)*StrollTimeline.walkFrameDuration*Double(StrollTimeline.walkCycles)
    static let sitDuration=StrollTimeline.duration-walkEnd
    var entryDuration:Double {Self.riseDuration+travelDuration+Self.sitDuration}
    var duration:Double { entryDuration+WindowSeatArtwork.transitionDuration }
    private(set) var entryStage="起身"
    var stationary:Bool { leavingAt == nil && artworkFrame >= WindowSeatArtwork.transitionFrameCount }
    init(panel:NSWindow,original:NSRect,scale:CGFloat,target:DesktopWindowTarget) {
        self.panel=panel; self.original=original; self.returnFrame=original; self.target=target
        destination=WindowSeatGeometry.destination(character:original,window:target.frame,scale:scale)
        let u=WindowSeatArtwork.unit*scale
        initial=NSRect(x:original.midX-224*u,y:original.minY+8*scale,
                       width:448*u,height:640*u)
        // Confirmed jog contact baseline is source y620, i.e. 20 px above
        // the bottom of its 640 px canvas. Airborne frames retain their lift.
        landing=NSRect(x:destination.minX,y:target.frame.maxY-20*u,width:448*u,height:640*u)
        restRig=NSRect(x:destination.minX,y:destination.minY+112*u,width:448*u,height:640*u)
        let distance=hypot(landing.minX-initial.minX,landing.minY-initial.minY)
        let cycle=Double(StrollTimeline.walkFrames.count)*StrollTimeline.walkFrameDuration
        travelDuration=Double(max(2,Int(ceil(distance/(105*scale*cycle)))))*cycle
        startedAt=ProcessInfo.processInfo.systemUptime;lastRefresh=startedAt;lastTick=startedAt;lastOrder=startedAt
        panel.contentView=view;panel.level = .normal
        panel.setFrame(padded(initial),display:false);panel.order(.above,relativeTo:Int(target.id))
    }
    func leave(at now:Double,reason:String) {
        guard leavingAt == nil,fall == nil else { return }
        leavingAt=now;self.reason=reason
        panel.level = .statusBar // Keep the return visible after its supporting window disappears.
        leaveProgress=min(1,max(0,(now-startedAt-entryDuration)/WindowSeatArtwork.transitionDuration))
        leaveEntryTime=min(entryDuration,max(0,now-startedAt))
        leaveLoopFrame=max(0,artworkFrame-WindowSeatArtwork.transitionFrameCount)
        leaveBalanceProgress=balanceProgress
        leaveLeanDegrees=upperLeanDegrees
        leaveFocusAmount=focusAmount;leaveBlinkAmount=view.blinkAmount
        leaveSmileAmount=view.smileAmount
        if balanceProgress>0 {leaveLoopFrame=0}
        preparationAt=nil
    }
    func spaceDidChange() {
        guard fall==nil,leavingAt==nil else {return}
        // Start on the next animation tick, so a paused Space transition does
        // not consume the visible falling animation before the new desktop appears.
        pendingSpaceChange=true
    }
    private func loseSupport(at now:Double,cause:FallCause) {
        if now-startedAt<entryDuration {
            leave(at:now,reason:"入座前窗口支撑已消失 · 回到原位")
        } else {
            beginFall(at:now,cause:cause)
        }
    }
    /// Returns false after a continuous return, or recovery at the fall landing.
    func tick(at now:Double)->Bool {
        let art=WindowSeatArtwork.shared,t=max(0,now-startedAt)
        let delta=max(0,now-lastTick);lastTick=now
        if fall != nil {return tickFall(at:now)}
        if pendingSpaceChange {
            pendingSpaceChange=false
            if leavingAt==nil {loseSupport(at:now,cause:.spaceChanged)}
            if fall != nil {return tickFall(at:now)}
        }
        let followInterval=t>=duration ? (now-lastMovement<WindowSeatArtwork.balanceHoldDuration ? Self.movingQueryInterval : Self.restingQueryInterval) : 0.5
        if leavingAt == nil && now-lastRefresh+0.001 >= followInterval {
            let queryDelta=max(1.0/120,now-lastRefresh)
            refreshCount+=1;lastRefresh=now
            let queryStart=ProcessInfo.processInfo.systemUptime
            let resolved=DesktopWindowTarget.resolveSeatSupport(target.id,side:target.side)
            let cost=ProcessInfo.processInfo.systemUptime-queryStart
            querySeconds+=cost;maxQuerySeconds=max(maxQuerySeconds,cost)
            guard let current=resolved,current.ownerPID == target.ownerPID else {
                loseSupport(at:now,cause:.supportLost)
                return fall != nil ? tickFall(at:now) : tick(at:now)
            }
            guard abs(current.frame.width-target.frame.width)<0.5,abs(current.frame.height-target.frame.height)<0.5,
                  !DesktopWindowTarget.isFullScreen(current.frame) else {
                // WindowServer reports intermediate transformed bounds during
                // the Dock's minimize animation. Wait for those bounds to
                // settle or disappear before classifying a genuine resize.
                if !DesktopWindowTarget.isFullScreen(current.frame) {
                    if sizeChangeSince==nil {sizeChangeSince=now}
                    if current.frame != lastSizeChangeFrame {lastSizeChangeAt=now;lastSizeChangeFrame=current.frame}
                    if now-sizeChangeSince!<0.8 && now-lastSizeChangeAt<0.15 {return true}
                }
                leave(at:now,reason:"窗口已缩放或全屏 · 回到原位")
                return tick(at:now)
            }
            sizeChangeSince=nil
            if t>=duration {
                // Sample even unchanged positions: stopping has acceleration,
                // while sustained constant velocity should return upright.
                inertia.sample(displacement:Double(current.frame.minX-target.frame.minX),interval:queryDelta)
                // Positive AppKit rotation moves the head left, against a
                // positive horizontal acceleration. Braking reverses the lean.
                wantedLeanDegrees=inertia.leanDegrees
            }
            if current.frame.origin != target.frame.origin {
                guard t>=duration else {
                    leave(at:now,reason:"入座期间窗口已移动 · 回到原位")
                    return tick(at:now)
                }
                let dx=current.frame.minX-target.frame.minX,dy=current.frame.minY-target.frame.minY
                destination=destination.offsetBy(dx:dx,dy:dy)
                landing=landing.offsetBy(dx:dx,dy:dy);restRig=restRig.offsetBy(dx:dx,dy:dy)
                let startingDrag=now-lastMovement>=WindowSeatArtwork.balanceHoldDuration
                target=current;lastMovement=now;moveCount+=1
                if startingDrag {
                    // Clicking the title bar can bring the support in front.
                    // Restore the character above it on the first move.
                    panel.order(.above,relativeTo:Int(target.id));lastOrder=now
                }
            }
        }
        if leavingAt==nil && now-lastOrder>=0.5 {
            panel.order(.above,relativeTo:Int(target.id));lastOrder=now
        }
        let progress:Double
        if let leavingAt {
            let elapsed=now-leavingAt
            let balanceTime=leaveBalanceProgress*WindowSeatArtwork.balanceReturnDuration
            if elapsed<balanceTime {
                balanceProgress=max(0,leaveBalanceProgress-elapsed/WindowSeatArtwork.balanceReturnDuration)
                upperLeanDegrees=leaveLeanDegrees*(balanceProgress/leaveBalanceProgress)
                focusAmount=leaveFocusAmount*(balanceProgress/leaveBalanceProgress)
                entryStage="收回四肢坐稳"
                showBalance(art);return true
            }
            balanceProgress=0;balanceFrame=0;upperLeanDegrees=0;focusAmount=0
            let seatedElapsed=elapsed-balanceTime
            // Finish the leg cycle to its neutral pose before folding legs.
            let neutralTime=Double((24-leaveLoopFrame)%24)*WindowSeatArtwork.loopFrameDuration
            if seatedElapsed < neutralTime && leaveProgress == 1 {
                let index=(leaveLoopFrame+Int(seatedElapsed/WindowSeatArtwork.loopFrameDuration))%24
                show(art.frames[index],key:"loop-\(index)",frame:index+WindowSeatArtwork.transitionFrameCount,rect:destination,focus:0)
                return true
            }
            let unwind=max(0,seatedElapsed-(leaveProgress == 1 ? neutralTime : 0))
            progress=max(0,leaveProgress-unwind/WindowSeatArtwork.transitionDuration)
            let folding=leaveProgress*WindowSeatArtwork.transitionDuration
            if unwind >= folding {
                let reverseTime=leaveEntryTime-(unwind-folding)
                if reverseTime <= 0 {return false}
                showEntry(at:reverseTime,reversing:true,clock:unwind)
                return true
            }
        } else {
            if t < entryDuration {showEntry(at:t);return true}
            if t>=duration {
                pressure.step(angle:wantedLeanDegrees,acceleration:inertia.acceleration,delta:delta)
                upperLeanDegrees=pressure.lean;focusAmount=pressure.focus
                if pressure.shouldFall {beginFall(at:now);return tickFall(at:now)}
                let wanted=min(1,pressure.amount/1.1)
                if wanted>0.1 && balanceProgress==0 && preparationAt==nil {
                    let index=max(0,artworkFrame-WindowSeatArtwork.transitionFrameCount)%24
                    let remainder=index%12,direction=remainder<=6 ? -1 : 1,count=min(remainder,12-remainder)
                    preparationFrames=(0...count).map{(index+direction*$0+24)%24};preparationAt=now
                }
                if let preparationAt {
                    let step=Int(max(0,now-preparationAt)/0.04)
                    if step<preparationFrames.count {
                        let index=preparationFrames[step]
                        entryStage="摆腿收稳"
                        show(art.frames[index],key:"loop-\(index)",frame:index+WindowSeatArtwork.transitionFrameCount,rect:destination,lean:upperLeanDegrees,focus:focusAmount)
                        return true
                    }
                    self.preparationAt=nil;loopEpoch=now
                }
                let previous=balanceProgress
                let rate=delta/(wanted>balanceProgress ? WindowSeatArtwork.balanceRiseDuration : WindowSeatArtwork.balanceReturnDuration)
                balanceProgress += min(rate,max(-rate,wanted-balanceProgress))
                if wanted==0 && balanceProgress<0.01 {balanceProgress=0}
                if balanceProgress>0 {
                    entryStage=wanted>previous ? "展开四肢保持平衡" : "收回四肢坐稳"
                    showBalance(art);return true
                }
                balanceFrame=0
                if previous>0 {loopEpoch=now}
            }
            progress=min(1,max(0,(t-entryDuration)/WindowSeatArtwork.transitionDuration))
        }
        entryStage=leavingAt==nil ? "放下双手伸腿" : "抬手收腿"
        if progress == 0 {
            show(art.transitions[0],key:"rest",frame:-1,rect:destination)
        } else if progress < 1 {
            let index=min(art.transitions.count-1,Int(progress*Double(art.transitions.count)))
            show(art.transitions[index],key:"transition-\(index)",frame:index,rect:destination,focus:index==8 ? 0 : nil,opacity:max(0,(progress-8.0/9)*9))
        } else {
            if leavingAt != nil {
                // Balance paused the old loop clock. After retracting, begin
                // folding from its neutral endpoint, never one stale loop pose.
                show(art.frames[0],key:"loop-0",frame:WindowSeatArtwork.transitionFrameCount,rect:destination,focus:0)
                return true
            }
            let loopTime=max(0,now-(loopEpoch ?? startedAt+duration)),index=Int(loopTime/WindowSeatArtwork.loopFrameDuration)%24
            show(art.frames[index],key:"loop-\(index)",frame:index+WindowSeatArtwork.transitionFrameCount,rect:destination,lean:upperLeanDegrees,focus:focusAmount)
        }
        return true
    }
    private func showBalance(_ art:WindowSeatArtwork) {
        balanceFrame=min(art.balance.count-1,Int((balanceProgress*Double(art.balance.count-1)).rounded()))
        // Quantize subpixel motion and cap angle-only repaints to 60 Hz.
        // Pose endpoints still render immediately, including return-to-neutral.
        guard balanceFrame != drawnBalanceFrame || lastTick-lastBalanceDrawAt+0.001>=1.0/60 else {return}
        let angle=(upperLeanDegrees*4).rounded()/4
        let focus=(focusAmount*48).rounded()/48
        show(art.balance[balanceFrame],key:"balance-\(balanceFrame)-lean-\(angle)-focus-\(focus)",frame:WindowSeatArtwork.transitionFrameCount,rect:destination,lean:angle,focus:focus,leg:leavingAt == nil ? pressure.legAngle*balanceProgress : 0)
        drawnBalanceFrame=balanceFrame;lastBalanceDrawAt=lastTick
    }
    private func showEntry(at t:Double,reversing:Bool=false,clock:Double=0) {
        let sample:StrollTimeline.Sample,rect:NSRect
        func mix(_ a:NSRect,_ b:NSRect,_ p:Double)->NSRect {
            let q=min(1,max(0,p)),s=q*q*(3-2*q)
            return NSRect(x:a.minX+(b.minX-a.minX)*s,y:a.minY+(b.minY-a.minY)*s,width:a.width,height:a.height)
        }
        if t < Self.riseDuration {
            sample=StrollTimeline.sample(at:t)!;rect=initial;entryStage="起身转向"
        } else if t < Self.riseDuration+travelDuration {
            sample=StrollTimeline.walkSample(at:reversing ? clock : t-Self.riseDuration)
            rect=mix(initial,landing,(t-Self.riseDuration)/travelDuration);entryStage="小跑到窗沿"
        } else {
            let local=t-Self.riseDuration-travelDuration
            sample=StrollTimeline.sample(at:min(StrollTimeline.duration-0.0001,Self.walkEnd+local))!
            rect=mix(landing,restRig,local/(Self.sitDuration-0.5));entryStage="收步坐下"
        }
        let mirror=sample.isSideFacing && ((landing.minX < initial.minX) != reversing)
        let key="jog-\(sample.frame ?? -1)-\(sample.transitionFrame ?? -1)-\(sample.launchFrame ?? -1)-\(mirror)"
        let panelRect=padded(rect)
        if panel.frame != panelRect {panel.setFrame(panelRect,display:false)}
        artworkFrame = -1
        guard key != lastKey else {return}
        lastKey=key;view.image=nil;view.stroll=sample;view.mirrored=mirror;view.upperLeanDegrees=0;view.focusAmount=nil;view.needsDisplay=true;redrawCount+=1
    }
    private func padded(_ rect:NSRect)->NSRect {rect.insetBy(dx:-WindowSeatArtwork.horizontalPadding*rect.height/640,dy:0)}
    private func show(_ image:NSImage,key:String,frame:Int,rect:NSRect,lean:Double=0,focus:Double?=nil,leg:Double=0,rotation:Double=0,opacity:Double=1) {
        let relaxation=leavingAt != nil || isFalling ? min(1,focusAmount/max(0.001,pressure.focus)) : 1
        let idleTime=floor(max(0,lastTick-(loopEpoch ?? startedAt+duration))/WindowSeatArtwork.loopFrameDuration)*WindowSeatArtwork.loopFrameDuration
        let idle=WindowSeatIdleExpression.sample(at:idleTime)
        // Fade curiosity out before visible counter-lean; the balance gaze
        // remains dominant. Departure also eases back to the neutral face.
        let leavingFade=leavingAt.map{max(0,1-(lastTick-$0)/0.24)} ?? 1
        let idleWeight=(isFalling || balanceProgress>0) ? 0 : max(0,1-abs(lean)/0.5)*max(0,1-(focus ?? 0)*30)*leavingFade
        let gaze=((pressure.gaze*relaxation+idle.x*idleWeight)*4).rounded()/4
        let gazeY=(idle.y*idleWeight*4).rounded()/4
        let blink=leavingAt.map{max(0,leaveBlinkAmount*(1-(lastTick-$0)/0.12))} ?? (pressure.blink*16).rounded()/16
        let smileValue=leavingAt==nil ? idle.smile*idleWeight : leaveSmileAmount*leavingFade
        let smile=(smileValue*16).rounded()/16
        let swing=(leg*4).rounded()/4
        let key=key+"-face-\(focus ?? -1)-gaze-\(focus == nil ? 0 : gaze),\(focus == nil ? 0 : gazeY)-blink-\(focus == nil ? 0 : blink)-smile-\(focus == nil ? 0 : smile)-leg-\(swing)-rotation-\(rotation)-opacity-\(opacity)"
        let panelRect=padded(rect)
        if panel.frame != panelRect {panel.setFrame(panelRect,display:false)}
        artworkFrame=frame
        guard key != lastKey else { return }
        lastKey=key;view.stroll=nil;view.image=image;view.upperLeanDegrees=lean;view.focusAmount=focus
        view.gazeOffset=gaze;view.gazeOffsetY=gazeY;view.blinkAmount=isFalling ? 0 : blink
        view.smileAmount=isFalling ? 0 : smile
        view.legSwingDegrees=swing;view.bodyRotation=rotation;view.faceOpacity=opacity;view.needsDisplay=true;redrawCount+=1
    }
    private func beginFall(at now:Double,cause:FallCause = .acceleration) {
        let art=WindowSeatArtwork.shared,u=destination.width/448
        // Detach from the visible pose, including the hand-lowering transition.
        let from=NSRect(x:panel.frame.minX+WindowSeatArtwork.horizontalPadding*u,y:panel.frame.minY,
                        width:448*u,height:640*u)
        let screen=NSScreen.screens.max { a,b in
            a.frame.intersection(from).width*a.frame.intersection(from).height < b.frame.intersection(from).width*b.frame.intersection(from).height
        }
        let area=screen?.visibleFrame ?? target.frame
        let ground=area.minY+(art.transitionBottoms[0]-112)*u+8*u/WindowSeatArtwork.unit
        let floorY=ground-art.balanceBottoms[9]*u
        let distance=max(0,from.minY-floorY)
        let duration=max(0.24,sqrt(2*distance/1100))
        // Retain horizontal momentum, with enough screen margin for the hands.
        let x=min(area.maxX-destination.width-20,max(area.minX+20,from.minX+CGFloat(inertia.velocity*duration*0.35)))
        let to=NSRect(x:x,y:floorY,width:destination.width,height:destination.height)
        var poses:[(image:NSImage,frame:Int)]=[]
        if balanceProgress==0 {
            if artworkFrame>=art.transitions.count {
                let index=(artworkFrame-art.transitions.count)%24,remainder=index%12
                let direction=remainder<=6 ? -1 : 1,count=min(remainder,12-remainder)
                poses=(0...count).map{let i=(index+direction*$0+24)%24;return (art.frames[i],i+art.transitions.count)}
            } else {
                poses=(max(0,artworkFrame)..<art.transitions.count).map{(art.transitions[$0],$0)}
            }
        }
        let poseDuration=min(Double(max(0,poses.count-1))*0.04,duration*0.35)
        destination=from
        fall=Fall(startedAt:now,from:from,to:to,duration:duration,rotation:view.upperLeanDegrees,progress:balanceProgress,
                  ground:ground,cause:cause,poses:poses,poseDuration:poseDuration,leg:view.legSwingDegrees)
        preparationAt=nil
        let trigger=cause == .acceleration ? "失去平衡" : cause == .spaceChanged ? "已切换虚拟桌面" : "窗口上沿已消失"
        reason=trigger+" · 落到屏幕底部重新坐稳"
        panel.level = .statusBar;panel.orderFrontRegardless()
    }
    private func tickFall(at now:Double)->Bool {
        guard let fall else {return true}
        let art=WindowSeatArtwork.shared,t=max(0,now-fall.startedAt),u=destination.width/448
        if t<fall.duration {
            entryStage="失去平衡下落"
            if t==0 {return true} // The detach frame is exactly the already visible pose.
            let p=t/fall.duration,s=p*p*(3-2*p)
            destination=NSRect(x:fall.from.minX+(fall.to.minX-fall.from.minX)*(2*p-p*p),
                y:fall.from.minY+(fall.to.minY-fall.from.minY)*p*p,width:fall.from.width,height:fall.from.height)
            let balanceTime=max(0,t-fall.poseDuration)
            balanceProgress=fall.progress+(1-fall.progress)*min(1,balanceTime/min(0.3,fall.duration-fall.poseDuration))
            balanceFrame=min(9,Int((balanceProgress*9).rounded()))
            upperLeanDegrees=0;focusAmount=min(1,focusAmount+(1-focusAmount)*min(1,t/0.1))
            if t<fall.poseDuration {
                let index=min(fall.poses.count-1,Int(t/fall.poseDuration*Double(fall.poses.count-1))),pose=fall.poses[index]
                show(pose.image,key:"fall-neutral-\(index)",frame:pose.frame,rect:destination,
                     lean:fall.rotation*(1-s),focus:focusAmount,leg:fall.leg*max(0,1-t/0.12))
                return true
            }
            show(art.balance[balanceFrame],key:"fall-\(balanceFrame)",frame:9,rect:destination,lean:fall.rotation*(1-s),focus:focusAmount,leg:fall.leg*max(0,1-t/0.12),rotation:(fall.rotation<0 ? -1 : 1)*6*sin(.pi*p))
            return true
        }
        let landed=t-fall.duration
        entryStage="落地收手坐稳"
        upperLeanDegrees=0
        if landed<WindowSeatArtwork.balanceReturnDuration {
            balanceProgress=max(0,1-landed/WindowSeatArtwork.balanceReturnDuration)
            balanceFrame=min(9,Int((balanceProgress*9).rounded()))
            focusAmount=balanceProgress
            destination=fall.to;destination.origin.y=fall.ground-art.balanceBottoms[balanceFrame]*u
            show(art.balance[balanceFrame],key:"land-\(balanceFrame)",frame:9,rect:destination,focus:focusAmount)
            return true
        }
        balanceProgress=0;balanceFrame=0;focusAmount=0
        let fold=landed-WindowSeatArtwork.balanceReturnDuration
        let index=max(0,8-Int(fold/WindowSeatArtwork.transitionDuration*9))
        destination=fall.to;destination.origin.y=fall.ground-art.transitionBottoms[index]*u
        show(art.transitions[index],key:"land-fold-\(index)",frame:index,rect:destination,focus:index==8 ? 0 : nil,opacity:max(0,1-fold*9/WindowSeatArtwork.transitionDuration))
        // Transition zero is the exact approved Scoot rest, registered into the
        // original overlay's seat rect. Recovery hands over at this location.
        let scale=u/WindowSeatArtwork.unit
        returnFrame=NSRect(x:destination.midX-original.width/2,y:destination.minY+112*u-8*scale,width:original.width,height:original.height)
        return fold<WindowSeatArtwork.transitionDuration+0.16
    }
    var diagnostics:[String:Any] {
        ["seatArtworkFrame":artworkFrame,"seatAnchor":[destination.minX+WindowSeatArtwork.anchor.x*destination.width/448,
            destination.minY+WindowSeatArtwork.anchor.y*destination.width/448],
         "seatWindowRefreshes":refreshCount,"seatRedraws":redrawCount,"seatReturning":leavingAt != nil,
         "seatEntryStage":entryStage,"seatJogFrame":view.stroll?.frame ?? -1,
         "seatBalanceProgress":balanceProgress,"seatBalanceFrame":balanceFrame,"seatMoveCount":moveCount,
         "seatUpperLeanDegrees":upperLeanDegrees,"seatRenderedLeanDegrees":view.upperLeanDegrees,
         "seatHorizontalVelocity":inertia.velocity,"seatHorizontalAcceleration":inertia.acceleration,
         "seatPressure":pressure.amount,"seatPressureTier":pressure.tier,"seatGazeOffset":pressure.gaze,
         "seatLegAmplitude":pressure.legAmplitude,"seatLegSpeed":pressure.legSpeed,"seatBlink":pressure.blink,
         "seatOverloadSeconds":pressure.overload,"seatFalling":isFalling,"seatFallElapsed":fall.map{max(0,lastTick-$0.startedAt)} ?? 0,
         "seatFallCause":fall?.cause.rawValue ?? "",
         "seatFocusAmount":focusAmount,"seatRenderedFocusAmount":view.focusAmount ?? 0,
         "seatIdleSmile":view.smileAmount,
         "seatQuerySeconds":querySeconds,"seatMaxQuerySeconds":maxQuerySeconds,
         "seatLastTick":lastTick,"seatLastRefresh":lastRefresh,"seatLastMovement":lastMovement.isFinite ? lastMovement : 0]
    }
}
