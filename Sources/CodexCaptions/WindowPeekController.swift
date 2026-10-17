import AppKit
import CoreGraphics

/// Only our sprite windows move. The target is read from WindowServer metadata.
final class WindowPeekController {
    enum Phase: String {
        case floating = "浮起转身", swimming = "游向窗口下角", corner = "抵达窗口下角"
        case rising = "起身", approaching = "小跑到窗口旁", turning = "转向窗口"
        case entering = "侧步收身藏到窗口后面", hidden = "藏在窗口后面"
        case peeking = "扒着窗口探头", withdrawing = "缩回窗口后面"
        case parked = "停在窗口后"
        case runningToSeat = "小跑到窗口上沿", sittingAtSeat = "收步坐到窗口上沿"
        case perching = "放下双手伸腿", seatedOnWindow = "坐在窗口上沿", leavingWindow = "收腿回到原位", fallingFromWindow = "失去平衡下落"
        case startled = "愣了一下", lookingLeft = "向左看看", lookingRight = "向右看看"
        case covering = "松手捂住脸", returning = "捂脸小跑回屏幕边缘", settling = "若无其事坐好"
    }
    enum Route: String { case walking, swimming, seating }
    private var seatMotion:WindowSeatMotion?
    private var seatPreviewSelectionSeconds=0.0
    private var seatPreviewActivatedTarget=false
    private var spaceObserver:NSObjectProtocol?
    private(set) var route: Route = .walking
    static let jogSpeed: CGFloat = 150
    static let swimSpeed: CGFloat = 50
    private(set) var movementSpeed: CGFloat = jogSpeed
    let body = SubtitlePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let peek = SubtitlePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let bodyView = WindowPeekSpriteView(), peekView = WindowPeekSpriteView()
    private(set) var fixture: NSWindow?
    private(set) var isRunning = false
    private(set) var phase: Phase = .rising
    private(set) var target: DesktopWindowTarget?
    private(set) var status = "小跑藏到窗口后面，再扒边探头"
    var onFinish: ((String)->Void)?
    var onReturnToEdge: ((NSRect)->Void)?
    private struct Recovery {
        let startedAt: Double, from: NSRect, to: NSRect, travel: Double
        let mirrored: Bool, frozenTail: Double, reason: String
    }
    private var recovery: Recovery?
    var isRecovering: Bool { recovery != nil }
    private(set) var recoveryDestination: NSRect?
    private var returnOrigins: CGRect = .null
    static let returnSpeed: CGFloat = 105
    static let reactionDuration = 1.65
    static let coverPreparationDuration = 0.56
    private static let recoverySitStart = StrollTimeline.steps.prefix { $0.phase != .sitting }.reduce(0) { $0+$1.duration }-0.18
    private static var settleDuration: Double { StrollTimeline.duration-recoverySitStart }
    var recoveryDuration: Double { recovery.map { Self.reactionDuration+Self.coverPreparationDuration+$0.travel+0.42+Self.settleDuration } ?? 0 }
    private var startFrame = NSRect.zero
    private var scale: CGFloat = 1
    private var startedAt = 0.0, lastRefresh = 0.0, lastTick = 0.0
    private var travelDuration = 1.0, enterDuration = 1.0
    private var holdDuration = 4.8
    private var withdrawalFrame = 2
    private var concealmentAnchorCore: NSRect?
    private var concealmentAnchorTarget: DesktopWindowTarget?
    private var steps: [(Phase,Double)] = []
    var duration: Double { seatMotion?.duration ?? steps.reduce(0) { $0+$1.1 } }
    var elapsed: Double { max(0,ProcessInfo.processInfo.systemUptime-startedAt) }

    init() {
        for (panel,view) in [(body,bodyView),(peek,peekView)] {
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle]
            panel.contentView = view
            panel.setAccessibilityLabel("DeepSeek 窗口探头")
        }
        spaceObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            self?.seatMotion?.spaceDidChange()
        }
    }
    deinit {
        if let spaceObserver {NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)}
        body.orderOut(nil); peek.orderOut(nil); fixture?.close()
    }

    @discardableResult
    func start(from original: NSRect, scale: CGFloat, targetID: CGWindowID? = nil,
               forceFixture: Bool = false, speed: CGFloat? = nil, hold: Double = 4.8,
               requiredTarget: DesktopWindowTarget? = nil, allowedReturnOrigins: CGRect = .null,
               preferSeat:Bool = false,previewSeat:Bool = false) -> Bool {
        stop(reason:"",immediate:true)
        guard DeepSeekStroll.shared.available, let screen = NSScreen.screens.first else {
            status = "探头素材尚未就绪"; return false
        }
        body.setAccessibilityLabel("DeepSeek 窗口探头")
        self.scale = scale; returnOrigins = allowedReturnOrigins; recoveryDestination = nil
        concealmentAnchorCore = nil; concealmentAnchorTarget = nil
        bodyView.braceAmount = nil; bodyView.headTurn = 0; bodyView.whistleTime = nil
        bodyView.entryFrame=nil;bodyView.coverFrame=nil;bodyView.coverPrepFrame=nil;bodyView.entryOffsetX=0
        peekView.braceAmount = nil; peekView.concealment = nil
        holdDuration = max(2,hold); withdrawalFrame = 2
        bodyView.layoutScale = scale; peekView.layoutScale = scale
        let size = NSSize(width:147*scale,height:226*scale)
        startFrame = NSRect(x:original.midX-size.width/2,y:original.minY,width:size.width,height:size.height)
        var seatOriginal=original
        var activateSeatTarget=false
        seatPreviewSelectionSeconds=0;seatPreviewActivatedTarget=false
        if previewSeat {
            let began=ProcessInfo.processInfo.systemUptime
            let selection=DesktopWindowTarget.chooseSeatPreview(near:original,scale:scale,onlyWindow:targetID)
            seatPreviewSelectionSeconds=ProcessInfo.processInfo.systemUptime-began
            guard let selection else {
                status="没有找到上沿空间足够的普通窗口，请将一个窗口下移后重试"
                return false
            }
            target=selection.target;seatOriginal=selection.original;activateSeatTarget=selection.needsActivation
        } else if let requiredTarget {
            target = DesktopWindowTarget.resolve(requiredTarget.id,side:requiredTarget.side)
            guard let target, target.ownerPID == requiredTarget.ownerPID,
                  target.frame == requiredTarget.frame, !DesktopWindowTarget.isFullScreen(target.frame) else {
                status = "等待合适的非全屏窗口"; return false
            }
        } else {
            target = targetID.flatMap { DesktopWindowTarget.resolve($0,side:original.midX < (DesktopWindowTarget.resolve($0,side:.left)?.frame.midX ?? original.midX) ? .left : .right) }
                ?? (forceFixture ? nil : DesktopWindowTarget.choose(near:startFrame,scale:scale))
        }
        if target == nil {
            let area = screen.visibleFrame
            let height = max(420,270*scale)
            let frame=NSRect(x:area.midX-260,y:area.midY-height/2,width:520,height:height)
            let window = NSWindow(contentRect:frame,styleMask:[.titled,.closable,.resizable,.miniaturizable],
                                  backing:.buffered,defer:false)
            window.title = "DeepSeek 探头练习窗"
            window.isReleasedWhenClosed = false; window.level = .normal
            window.minSize = NSSize(width:340,height:300)
            let practiceView=PeekPracticeView()
            window.contentView = practiceView
            window.orderFrontRegardless()
            fixture = window
            target = DesktopWindowTarget(id:CGWindowID(window.windowNumber),
                ownerPID:ProcessInfo.processInfo.processIdentifier,owner:"探头练习窗",frame:window.frame,
                side:startFrame.midX < window.frame.midX ? .left : .right)
        }
        guard var target else { status = "请打开一个有可见侧边的普通窗口"; fixture?.close(); fixture = nil; return false }
        if preferSeat || previewSeat,
           let area=NSScreen.screens.first(where:{$0.frame.contains(NSPoint(x:seatOriginal.midX,y:seatOriginal.midY))})?.visibleFrame,
           WindowSeatGeometry.fits(character:seatOriginal,window:target.frame,scale:scale,area:area) {
            guard WindowSeatArtwork.shared.available else { status="窗沿坐姿素材尚未就绪"; return false }
            if activateSeatTarget {
                guard let application=NSRunningApplication(processIdentifier:target.ownerPID) else {
                    status="目标应用已退出，请重新预览";return false
                }
                let activated:Bool
                if #available(macOS 14.0,*) {
                    NSApp.yieldActivation(to:application)
                    activated=application.activate(from:.current,options:[.activateAllWindows])
                } else {
                    activated=application.activate(options:[.activateAllWindows])
                }
                guard activated else {
                    status="无法显示目标窗口，请切换到 \(target.owner) 后重试";return false
                }
                seatPreviewActivatedTarget=true
            }
            route = .seating
            body.setAccessibilityLabel("DeepSeek 窗沿坐姿")
            startedAt=ProcessInfo.processInfo.systemUptime;isRunning=true
            seatMotion=WindowSeatMotion(panel:body,original:seatOriginal,scale:scale,target:target)
            // Manual previews remain visible above the floating control panel.
            // Automatic seats keep their ordinary target-window stacking.
            if previewSeat { body.level = .statusBar }
            peek.orderOut(nil);phase = .perching;status=phase.rawValue+" · "+target.owner
            tick(at:startedAt);return true
        }
        if previewSeat {status="目标窗口已变化，请重新预览";self.target=nil;return false}
        // The seat route does not use any side-peek/hide sprites. Keep their
        // lazy loading on the legacy route instead of paying for both sets.
        guard WindowPeekArtwork.shared.available, WindowHideArtwork.shared.available else {
            status="探头素材尚未就绪";fixture?.close();fixture=nil;self.target=nil;return false
        }
        route = DesktopWindowTarget.isBelow(original,window:target.frame) ? .swimming : .walking
        if route == .swimming {
            guard WindowPeekArtwork.shared.swimmingAvailable else {
                status = "游泳素材尚未就绪"; fixture?.close(); fixture = nil; self.target = nil; return false
            }
            target = target.withSide(DesktopWindowTarget.nearestLowerCorner(original,window:target.frame))
            self.target = target
        }
        let approach = approachOrigin(for:target)
        let distance: CGFloat
        if route == .swimming {
            var previous = swimCenter(for:target,progress:0), length:CGFloat = 0
            for i in 1...32 {
                let next = swimCenter(for:target,progress:Double(i)/32)
                length += hypot(next.x-previous.x,next.y-previous.y); previous = next
            }
            distance = length
        } else { distance = hypot(approach.x-startFrame.minX,approach.y-startFrame.minY) }
        movementSpeed = max(20,speed ?? (route == .swimming ? Self.swimSpeed : Self.jogSpeed))
        let velocity = movementSpeed*scale
        travelDuration = max(0.7,Double(distance/velocity))
        enterDuration = max(1.5,Double(abs(hiddenOrigin(for:target).x-approach.x)/velocity))
        let rise = StrollTimeline.steps.prefix { $0.phase != .walking }.reduce(0) { $0+$1.duration }
        steps = route == .swimming
            ? [(.floating,0.65),(.swimming,travelDuration),(.corner,0.3),(.hidden,0.2),(.peeking,holdDuration),(.withdrawing,WindowPeekArtwork.withdrawalDuration)]
            : [(.rising,rise),(.approaching,travelDuration),(.turning,0.4),(.entering,enterDuration),
               (.hidden,0.25),(.peeking,holdDuration),(.withdrawing,WindowPeekArtwork.withdrawalDuration)]
        startedAt = ProcessInfo.processInfo.systemUptime; lastRefresh = startedAt; lastTick = startedAt; isRunning = true
        body.setFrame(startFrame,display:false)
        peek.setFrame(NSRect(origin:.zero,size:NSSize(width:size.width,
            height:size.height+WindowPeekArtwork.lowerBodyExtension*size.width/448)),display:false)
        body.level = .statusBar; body.orderFrontRegardless(); peek.orderOut(nil)
        status = (route == .swimming ? "浮起转身 · " : "起身 · ") + target.owner
        tick(at:startedAt)
        return true
    }

    func stop(reason: String = "已回到原位", immediate:Bool = false) {
        if let seatMotion, !immediate {
            seatMotion.leave(at:ProcessInfo.processInfo.systemUptime,reason:reason)
            return
        }
        seatMotion=nil;body.contentView=bodyView
        let running = isRunning
        isRunning = false; recovery = nil; body.orderOut(nil); peek.orderOut(nil)
        fixture?.close(); fixture = nil; target = nil
        if !reason.isEmpty { status = reason }
        if running { onFinish?(reason) }
    }

    private func approachOrigin(for target: DesktopWindowTarget) -> NSPoint {
        NSPoint(x:target.side == .left ? target.edgeX-150*scale : target.edgeX+3*scale,
                y:gripY(for:target)-8*scale-(WindowPeekArtwork.gripY-WindowPeekArtwork.lowerBodyExtension)*(147*scale/448))
    }
    private func hiddenOrigin(for target: DesktopWindowTarget) -> NSPoint {
        let unit = 147*scale/448
        return NSPoint(x:target.edgeX-(target.side == .left ? WindowHideArtwork.wallX : 448-WindowHideArtwork.wallX)*unit,
                       y:approachOrigin(for:target).y)
    }
    /// Tail and loose hair may protrude. Face, palms, torso and feet stay physically covered.
    var coveredBodyRect: NSRect {
        let unit = body.frame.width/448, x:CGFloat = bodyView.mirrored ? 12 : Self.gripCoreX
        return NSRect(x:body.frame.minX+x*unit,y:body.frame.minY+8*scale+20*unit,width:(436-Self.gripCoreX)*unit,height:580*unit)
    }
    private static let gripCoreX:CGFloat = 152
    private var canReactToLoss: Bool { [.hidden,.peeking,.withdrawing,.parked].contains(phase) }
    private func beginRecovery(at now:Double,reason:String) {
        guard recovery == nil else { return }
        let from = body.frame
        let screen = NSScreen.screens.max { $0.visibleFrame.intersection(from).areaForRecovery < $1.visibleFrame.intersection(from).areaForRecovery }
            ?? NSScreen.screens.first!
        let area = screen.visibleFrame
        let allowed = returnOrigins.isNull ? NSRect(x:area.minX+8*scale,y:area.minY+8*scale,
            width:max(0,area.width-from.width-16*scale),height:max(0,area.height-from.height-16*scale)) : returnOrigins
        let left = abs(from.minX-allowed.minX) <= abs(allowed.maxX-from.minX)
        let to = NSRect(x:left ? allowed.minX : allowed.maxX,
            y:min(allowed.maxY,max(allowed.minY,startFrame.minY)),width:from.width,height:from.height)
        let distance = hypot(to.minX-from.minX,to.minY-from.minY)
        recovery = Recovery(startedAt:now,from:from,to:to,travel:max(0.8,Double(distance/(Self.returnSpeed*scale))),
            mirrored:bodyView.mirrored,frozenTail:bodyView.tailAngle,reason:reason)
        recoveryDestination = to
        peek.orderOut(nil); body.level = .statusBar; body.orderFrontRegardless()
        tickRecovery(at:now)
    }
    private func tickRecovery(at now:Double) {
        guard let recovery else { return }
        let t = max(0,now-recovery.startedAt), walkStart = Self.reactionDuration+Self.coverPreparationDuration
        var origin = recovery.from.origin
        bodyView.swimFrame = nil; bodyView.peekFrame = nil; bodyView.concealment = nil
        bodyView.whistleTime = nil; bodyView.mirrored = recovery.mirrored
        bodyView.entryFrame=nil;bodyView.coverFrame=nil;bodyView.coverPrepFrame=nil;bodyView.entryOffsetX=0
        bodyView.braceAmount = 1; bodyView.braceMirrored = nil; bodyView.tailAngle = recovery.frozenTail
        bodyView.tailReveal = 1; bodyView.concealedBody = false
        func smooth(_ p:Double) -> Double { let p = min(1,max(0,p)); return p*p*(3-2*p) }
        if t < 0.65 {
            phase = .startled; bodyView.headTurn = 0
        } else if t < 1.15 {
            phase = .lookingLeft
            bodyView.headTurn = (recovery.mirrored ? 2 : 1)*smooth((t-0.65)/0.22)
        } else if t < Self.reactionDuration {
            phase = .lookingRight
            bodyView.headTurn = recovery.mirrored ? 2-smooth((t-1.15)/0.28) : 1+smooth((t-1.15)/0.28)
        } else if t < walkStart {
            phase = .covering;bodyView.braceAmount=nil
            let frame=min(3,Int((t-Self.reactionDuration)/0.14))
            bodyView.coverPrepFrame=frame
            // Turn through the front-facing covered pose; never mirror the
            // bracing body directly into a travelling body.
            bodyView.mirrored = frame < 2 ? !recovery.mirrored : recovery.to.minX < recovery.from.minX
        } else if t < walkStart+recovery.travel {
            phase = .returning
            bodyView.mirrored = recovery.to.minX < recovery.from.minX
            bodyView.braceAmount = nil
            let time = max(0,t-walkStart), p = min(1,time/recovery.travel)
            // Short acceleration/deceleration ramps keep speed continuous at each end.
            let ramp = 0.1
            let distance:Double
            if p < ramp { distance = p*p/(2*ramp*(1-ramp)) }
            else if p > 1-ramp { distance = 1-(1-p)*(1-p)/(2*ramp*(1-ramp)) }
            else { distance = (p-ramp/2)/(1-ramp) }
            origin = mix(recovery.from.origin,recovery.to.origin,distance)
            bodyView.stroll = jog(time)
            bodyView.coverFrame = Int(time/WindowHideArtwork.coverFrameDuration)%8
        } else if t < recoveryDuration {
            phase = .settling; origin = recovery.to.origin
            bodyView.braceAmount = nil
            bodyView.mirrored = recovery.to.minX < recovery.from.minX
            let settle=t-walkStart-recovery.travel
            if settle < 0.42 {
                bodyView.coverPrepFrame=[2,1,0][min(2,Int(settle/0.14))]
            } else {
                bodyView.stroll = StrollTimeline.sample(at:Self.recoverySitStart+settle-0.42)!
            }
        } else {
            body.setFrame(recovery.to,display:false)
            onReturnToEdge?(recovery.to)
            stop(reason:recovery.reason+" · 已捂着脸跑回屏幕边缘")
            return
        }
        body.setFrame(NSRect(origin:origin,size:recovery.from.size),display:false)
        bodyView.needsDisplay = true
        status = phase.rawValue+" · "+recovery.reason
    }
    private func peekOrigin(for target: DesktopWindowTarget) -> NSPoint {
        let unit = 147*scale/448
        return NSPoint(x:target.edgeX-(target.side == .left ? WindowPeekArtwork.edgeX : 448-WindowPeekArtwork.edgeX)*unit,
                       y:gripY(for:target)-8*scale-WindowPeekArtwork.gripY*unit)
    }
    private func gripY(for target:DesktopWindowTarget) -> CGFloat {
        route == .swimming ? target.frame.minY+DesktopWindowTarget.cornerGripOffset*scale : target.gripY
    }
    private func swimControls(for target:DesktopWindowTarget) -> [NSPoint] {
        let start = NSPoint(x:startFrame.midX,y:startFrame.midY)
        let outward:CGFloat = target.side == .left ? -1 : 1
        let end = NSPoint(x:target.edgeX+outward*98*scale,y:target.frame.minY+12*scale)
        return [start,NSPoint(x:start.x,y:start.y+(end.y-start.y)*0.5),
                NSPoint(x:end.x+outward*110*scale,y:max(start.y+(end.y-start.y)*0.7,end.y-20*scale)),end]
    }
    private func swimCenter(for target:DesktopWindowTarget,progress:Double) -> NSPoint {
        let c = swimControls(for:target), t = CGFloat(progress), u = 1-t
        return NSPoint(x:u*u*u*c[0].x+3*u*u*t*c[1].x+3*u*t*t*c[2].x+t*t*t*c[3].x,
                       y:u*u*u*c[0].y+3*u*u*t*c[1].y+3*u*t*t*c[2].y+t*t*t*c[3].y)
    }
    private func setSwimPose(for target:DesktopWindowTarget,progress:Double,time:Double) {
        let before = swimCenter(for:target,progress:max(0,progress-0.01))
        let after = swimCenter(for:target,progress:min(1,progress+0.01))
        bodyView.mirrored = after.x < before.x
        bodyView.swimAngle = atan2(after.y-before.y,abs(after.x-before.x))
        bodyView.swimFrame = Int(time/0.14)%8
        bodyView.swimBlend = 1; bodyView.swimOpacity = 1
    }
    private func mix(_ from: NSPoint,_ to: NSPoint,_ amount: Double) -> NSPoint {
        NSPoint(x:from.x+(to.x-from.x)*amount,y:from.y+(to.y-from.y)*amount)
    }
    private func jog(_ time: Double) -> StrollTimeline.Sample {
        StrollTimeline.walkSample(at:time)
    }
    func tick(at now: Double = ProcessInfo.processInfo.systemUptime) {
        guard isRunning else { return }
        if let seatMotion {
            if !seatMotion.tick(at:now) {
                let reason=seatMotion.reason
                onReturnToEdge?(seatMotion.returnFrame)
                stop(reason:reason,immediate:true);return
            }
            target=seatMotion.target
            phase=seatMotion.isFalling ? .fallingFromWindow : seatMotion.leavingAt != nil ? .leavingWindow : seatMotion.stationary ? .seatedOnWindow
                : seatMotion.entryStage == "起身转向" ? .rising : seatMotion.entryStage == "小跑到窗沿" ? .runningToSeat
                : seatMotion.entryStage == "收步坐下" ? .sittingAtSeat : .perching
            status=(seatMotion.balanceProgress>0 && seatMotion.leavingAt==nil ? seatMotion.entryStage : phase.rawValue)+" · "+seatMotion.target.owner
            return
        }
        if recovery != nil { tickRecovery(at:now); return }
        guard let previous = target else { return }
        let trackingDelta = min(0.1,max(0,now-lastTick)), previousPhase = phase
        lastTick = now
        let refreshedTarget = now-lastRefresh >= 0.08
        if refreshedTarget {
            guard let refreshed = DesktopWindowTarget.resolve(previous.id,side:previous.side) else {
                if canReactToLoss { beginRecovery(at:now,reason:"窗口已关闭或最小化") }
                else { stop(reason:"目标窗口已关闭或最小化 · 已回到原位") }
                return
            }
            if canReactToLoss {
                let core = concealmentAnchorCore ?? coveredBodyRect
                let anchor = concealmentAnchorTarget ?? previous
                let cover = core.intersection(refreshed.frame).areaForRecovery
                let shifted = hypot(refreshed.frame.minX-anchor.frame.minX,refreshed.frame.minY-anchor.frame.minY)
                // Dock minimization can briefly report an expanding/moving wall.
                // Detect that departure before copying its transient frame to the character.
                if cover < core.areaForRecovery*0.94 || shifted > 48*scale
                    || abs(refreshed.edgeX-anchor.edgeX) > 64*scale {
                    beginRecovery(at:now,reason:"窗口被挪走了"); return
                }
            }
            target = refreshed; lastRefresh = now
            if DesktopWindowTarget.isFullScreen(refreshed.frame) {
                stop(reason:"目标窗口已全屏 · 已回到原位"); return
            }
            if refreshed.frame.height < 238*scale || refreshed.frame.width < 155*scale {
                stop(reason:"目标窗口太小 · 已回到原位"); return
            }
        }
        guard let target else { return }
        let t = now-startedAt
        if phase == .parked && t >= duration && target.frame == previous.frame
            && body.frame.origin == hiddenOrigin(for:target) {
            bodyView.tailAngle = WindowHideArtwork.tailAngle(at:t)
            bodyView.tailReveal = WindowHideArtwork.tailReveal(at:t-duration)
            bodyView.needsDisplay = true
            if refreshedTarget { keepParkedOrder(for:target) }
            return
        }
        var start = 0.0
        var local = 0.0, length = 0.0
        if t >= duration {
            phase = .parked; local = t-duration; length = 1
        } else {
            for step in steps {
                if t < start+step.1 { phase = step.0; local = max(0,t-start); length = step.1; break }
                start += step.1
            }
        }
        let p = min(1,local/length), approach = approachOrigin(for:target), hidden = hiddenOrigin(for:target)
        let towardsWindow = target.side == .right
        let travellingLeft = approach.x < startFrame.minX
        if phase != .peeking && phase != .withdrawing && phase != .parked { peek.orderOut(nil) }
        bodyView.peekFrame = nil
        bodyView.concealment = nil
        bodyView.swimFrame = nil
        bodyView.braceAmount = nil; bodyView.braceMirrored = nil; bodyView.headTurn = 0; bodyView.whistleTime = nil
        bodyView.entryFrame=nil;bodyView.coverFrame=nil;bodyView.coverPrepFrame=nil;bodyView.entryOffsetX=0
        bodyView.tailAngle = WindowHideArtwork.tailAngle(at:t)
        bodyView.tailReveal = 1; bodyView.concealedBody = false
        bodyView.mirrored = towardsWindow
        var origin = startFrame.origin
        var bodySize = startFrame.size
        switch phase {
        case .floating:
            bodySize = NSSize(width:252*scale,height:252*scale)
            origin = NSPoint(x:startFrame.midX-bodySize.width/2,y:startFrame.midY-bodySize.height/2)
            bodyView.stroll = StrollTimeline.sample(at:0)!
            bodyView.swimFrame = 0; bodyView.swimBlend = p; bodyView.swimOpacity = 1
            bodyView.swimAngle = .pi/2*CGFloat(p); bodyView.mirrored = false
            body.level = .normal
        case .swimming,.corner:
            bodySize = NSSize(width:252*scale,height:252*scale)
            let progress = phase == .corner ? 1 : p
            let center = swimCenter(for:target,progress:progress)
            origin = NSPoint(x:center.x-bodySize.width/2,y:center.y-bodySize.height/2)
            setSwimPose(for:target,progress:progress,time:local)
            if phase == .corner { bodyView.swimOpacity = 1-p }
            body.level = .normal
        case .rising:
            bodyView.stroll = StrollTimeline.sample(at:min(local,steps[0].1-0.001))!
            bodyView.mirrored = travellingLeft && bodyView.stroll.isSideFacing
            body.level = .statusBar
        case .approaching:
            let ramp=0.12, distance:Double
            if p < ramp { distance=p*p/(2*ramp*(1-ramp)) }
            else if p > 1-ramp { distance=1-(1-p)*(1-p)/(2*ramp*(1-ramp)) }
            else { distance=(p-ramp/2)/(1-ramp) }
            origin = mix(startFrame.origin,approach,distance)
            bodyView.stroll = jog(local); bodyView.mirrored = travellingLeft
            body.level = .statusBar
        case .turning:
            origin = approach
            bodyView.entryFrame = local < 0.12 ? 0 : 1
            // Change stacking while the whole sprite is still outside the wall.
            body.level = .normal
        case .entering:
            // Three planted steps with pauses during weight transfer. Pose and
            // physical displacement share this clock, rather than sliding a run.
            func smooth(_ t:Double)->Double { let t=min(1,max(0,t));return t*t*(3-2*t) }
            let distance=0.35*smooth((p-0.08)/0.22)+0.4*smooth((p-0.38)/0.24)+0.25*smooth((p-0.68)/0.20)
            origin = mix(approach,hidden,distance)
            bodyView.entryFrame = min(WindowHideArtwork.finalEntryFrame,1+Int(p*9))
            if bodyView.entryFrame == WindowHideArtwork.finalEntryFrame {
                bodyView.tailReveal = 0; bodyView.concealedBody = true
            }
            body.level = .normal
        case .hidden:
            origin = hidden; bodyView.stroll = jog(0); bodyView.braceAmount = 1
            bodyView.tailReveal = 0; bodyView.concealedBody = true
            body.level = .normal
        case .peeking,.withdrawing,.parked:
            origin = hidden; body.level = .normal
            bodyView.stroll = jog(0); bodyView.braceAmount = 1
            bodyView.tailReveal = phase == .parked ? WindowHideArtwork.tailReveal(at:local) : 0
            bodyView.concealedBody = true
            let frame: Int
            if phase == .parked || phase == .withdrawing { frame = withdrawalFrame }
            else if local >= length-0.35 { frame = 2 }
            else if local < 0.55 { frame = min(2,Int(local/0.18)) }
            else {
                let sequence = [2,2,2,4,4,5,2,2,3,2,2,2]
                frame = sequence[Int((local-0.55)/0.2)%sequence.count]
            }
            if phase == .peeking { withdrawalFrame = frame }
            peekView.peekFrame = frame; peekView.mirrored = target.side == .right
            peekView.concealment = phase == .parked ? 1 : phase == .withdrawing ? p : nil
            peek.setFrameOrigin(peekOrigin(for:target)); peekView.needsDisplay = true
            peek.level = .normal
            if phase == .parked { peek.orderOut(nil) } else { peek.order(.above,relativeTo:Int(target.id)) }
        case .startled,.lookingLeft,.lookingRight,.covering,.returning,.settling,.runningToSeat,.sittingAtSeat,.perching,.seatedOnWindow,.leavingWindow,.fallingFromWindow:
            break // Recovery owns these phases before target resolution.
        }
        if phase == .parked && previousPhase == .parked {
            let old = body.frame.origin, distance = hypot(origin.x-old.x,origin.y-old.y)
            let step = Self.jogSpeed*scale*trackingDelta
            if distance > step && distance > 0 { origin = mix(old,origin,Double(step/distance)) }
        }
        body.setFrame(NSRect(origin:origin,size:bodySize),display:false); bodyView.needsDisplay = true
        if canReactToLoss && concealmentAnchorCore == nil {
            concealmentAnchorCore = coveredBodyRect; concealmentAnchorTarget = target
        }
        if body.level == .normal { body.order(.below,relativeTo:Int(target.id)) }
        else { body.orderFrontRegardless() }
        status = phase.rawValue+" · "+target.owner
    }
    private func keepParkedOrder(for target:DesktopWindowTarget) {
        let ids = DesktopWindowTarget.windows().compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
        guard let wall = ids.firstIndex(of:Int(target.id)) else { return }
        if let back = ids.firstIndex(of:body.windowNumber), back < wall {
            body.order(.below,relativeTo:Int(target.id))
        }
        if peek.isVisible && (ids.firstIndex(of:peek.windowNumber).map({ $0 > wall }) ?? true) {
            peek.order(.above,relativeTo:Int(target.id))
        }
    }
    var diagnostics: [String:Any] {
        var row: [String:Any] = ["active":isRunning,"phase":phase.rawValue,"status":status,"duration":duration,
            "practiceWindow":fixture?.windowNumber ?? 0,"seatPreviewSelectionSeconds":seatPreviewSelectionSeconds,
            "seatPreviewActivatedTarget":seatPreviewActivatedTarget,
            "elapsed":elapsed,"bodyWindow":body.windowNumber,"peekWindow":peek.windowNumber,
            "bodyFrame":[body.frame.minX,body.frame.minY,body.frame.width,body.frame.height],
            "peekFrame":[peek.frame.minX,peek.frame.minY,peek.frame.width,peek.frame.height],
            "bodyLevel":body.level.rawValue,"peekLevel":peek.level.rawValue,
            "peekVisible":peek.isVisible,"peekArtworkFrame":peekView.peekFrame ?? -1,
            "withdrawArtworkFrame":peekView.concealment.map { WindowPeekArtwork.withdrawalFrame(at:$0) } ?? -1,
            "concealment":peekView.concealment ?? 0,"stationary":phase == .parked || phase == .seatedOnWindow,
            "bracing":bodyView.braceAmount ?? 0,"headTurn":bodyView.headTurn,"tailAngle":bodyView.tailAngle,
            "tailReveal":bodyView.tailReveal,
            "whistling":bodyView.whistleTime != nil,"recovering":isRecovering,"recoveryDuration":recoveryDuration,
            "entryArtworkFrame":bodyView.entryFrame ?? -1,"launchArtworkFrame":bodyView.stroll.launchFrame ?? -1,
            "entryOffsetX":bodyView.entryOffsetX,
            "coverArtworkFrame":bodyView.coverFrame ?? -1,"coverPreparationFrame":bodyView.coverPrepFrame ?? -1,
            "coveringFace":bodyView.coverFrame != nil,
            "coveredBodyRect":[coveredBodyRect.minX,coveredBodyRect.minY,coveredBodyRect.width,coveredBodyRect.height],
            "route":route.rawValue,"movementSpeed":movementSpeed,
            "bodyArtworkFrame":bodyView.stroll.frame ?? -1,"bodyArmSwing":bodyView.stroll.armSwing ?? 0,
            "swimFrame":bodyView.swimFrame ?? -1,"swimAngle":bodyView.swimAngle,
            "swimMirrored":bodyView.mirrored]
        if let seatMotion { row.merge(seatMotion.diagnostics) { _,new in new } }
        if let recovery {
            row["recoveryFrom"] = [recovery.from.minX,recovery.from.minY,recovery.from.width,recovery.from.height]
            row["recoveryElapsed"] = max(0,ProcessInfo.processInfo.systemUptime-recovery.startedAt)
            row["recoveryDestination"] = [recovery.to.minX,recovery.to.minY,recovery.to.width,recovery.to.height]
        }
        if let target {
            if bodyView.entryFrame == WindowHideArtwork.finalEntryFrame {
                let local=WindowHideArtwork.wallX*(body.frame.width/448)+bodyView.entryOffsetX
                row["entryGripScreenX"]=body.frame.minX+(bodyView.mirrored ? body.frame.width-local : local)
            }
            row["targetWindow"] = target.id; row["targetOwner"] = target.owner; row["side"] = target.side.rawValue
            row["targetPID"] = target.ownerPID
            row["targetFrame"] = [target.frame.minX,target.frame.minY,target.frame.width,target.frame.height]
            row["gripScreen"] = [target.edgeX,gripY(for:target)]
            row["lowerCorner"] = [target.edgeX,target.frame.minY]
            let windows = DesktopWindowTarget.windows()
            let ids = windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
            row["windowOrder"] = ids
            if let server = windows.first(where:{ ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == body.windowNumber }),
               let frame = DesktopWindowTarget.frame(from:server) {
                row["bodyServerFrame"] = [frame.minX,frame.minY,frame.width,frame.height]
                row["bodyServerLevel"] = server[kCGWindowLayer as String] ?? -1
            }
        }
        return row
    }

    /// Renders only our own fixture content and sprite views, with native positions.
    /// WindowServer ordering is independently checked by the integration checks.
    func renderFixtureScene(in area: NSRect) -> CGImage? {
        guard let fixture else { return nil }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(area.width)),pixelsHigh:Int(ceil(area.height)),
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedWhite:0.97,alpha:1).setFill(); NSRect(origin:.zero,size:area.size).fill()
        NSGraphicsContext.current!.cgContext.translateBy(x:-area.minX,y:-area.minY)
        func drawSprite(_ panel: NSWindow,_ view: NSView) {
            guard panel.isVisible, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:rep)
            NSImage(cgImage:rep.cgImage!,size:view.bounds.size).draw(in:panel.frame)
        }
        if body.level == .normal && route != .seating { drawSprite(body,body.contentView ?? bodyView) }
        if fixture.isVisible && !fixture.isMiniaturized {
        let rect = fixture.frame
        NSColor(calibratedRed:0.92,green:0.96,blue:1,alpha:1).setFill()
        NSBezierPath(roundedRect:rect,xRadius:8,yRadius:8).fill()
        if let view = fixture.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:rep)
            NSImage(cgImage:rep.cgImage!,size:view.bounds.size)
                .draw(in:NSRect(origin:rect.origin,size:view.bounds.size))
        }
        let title = NSRect(x:rect.minX,y:rect.maxY-22,width:rect.width,height:22)
        NSColor(calibratedWhite:0.84,alpha:1).setFill(); title.fill()
        (fixture.title as NSString).draw(at:NSPoint(x:title.minX+80,y:title.minY+4),
            withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.darkGray])
        NSColor(calibratedWhite:0.65,alpha:1).setStroke()
        NSBezierPath(roundedRect:rect,xRadius:8,yRadius:8).stroke()
        }
        if body.level != .normal || route == .seating { drawSprite(body,body.contentView ?? bodyView) }
        drawSprite(peek,peekView)
        return bitmap.cgImage
    }
}

private final class PeekPracticeView: NSView {
    var seated=false
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.92,green:0.96,blue:1,alpha:1).setFill(); bounds.fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let heading: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:27,weight:.semibold),
            .foregroundColor:NSColor(calibratedRed:0.16,green:0.32,blue:0.55,alpha:1),.paragraphStyle:paragraph]
        ((seated ? "小鲸鱼坐在窗口上沿" : "小鲸鱼在窗口后面") as NSString).draw(in:NSRect(x:20,y:bounds.midY+15,width:bounds.width-40,height:42),withAttributes:heading)
        ((seated ? "缓拖看晃脚，急拉看平衡；过猛会掉下来。" : "拖动或缩放窗口，看看她从哪里探头。") as NSString).draw(in:NSRect(x:20,y:bounds.midY-30,width:bounds.width-40,height:28),
            withAttributes:[.font:NSFont.systemFont(ofSize:15),
                .foregroundColor:NSColor(calibratedRed:0.32,green:0.42,blue:0.55,alpha:1),.paragraphStyle:paragraph])
    }
}

private extension CGRect {
    var areaForRecovery: CGFloat { isNull ? 0 : max(0,width)*max(0,height) }
}
