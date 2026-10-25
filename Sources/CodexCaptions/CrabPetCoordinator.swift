import AppKit

/// One actor and one bounded capture in flight. Idle discovery <= once/30 s;
/// during the brief interaction revalidate <= once/s, using the existing app clock.
final class CrabPetCoordinator {
    private let overlays:ProjectOverlays
    private let capture=BackdropCapture()
    private var busy=false,generation=0
    private var idleSince:Double?
    private var lastOrigin:CGPoint?
    private var lastScan = -Double.infinity
    private var cooldownUntil=0.0
    private var lastSlot = -Double.infinity
    private var source:CaptionMascot?
    private var motion:CrabPetMotion?
    private var target:CGRect?
    private var ownerWindowID:CGWindowID?
    private(set) var lastDetected:CGRect?
    private(set) var scans=0
    private(set) var matches=0
    private(set) var status="等待工服角色空闲"
    var running:Bool {motion != nil}
    init(overlays:ProjectOverlays) {self.overlays=overlays}
    func preparePreview() { stop();cooldownUntil=0;lastScan = -Double.infinity }
    func stop() {
        generation += 1
        if let source { overlays.clearCrabPet(for:source);overlays.endBackdropRelocation(for:source) }
        source=nil;motion=nil;target=nil;ownerWindowID=nil;idleSince=nil;lastOrigin=nil
        cooldownUntil=ProcessInfo.processInfo.systemUptime+30
    }
    func update(enabled:Bool,idle:Bool,preview:Bool = false,at now:Double) {
        guard enabled && idle else {if running || idleSince != nil {stop()};return}
        guard let pair=CaptionMascot.allCases.compactMap({s -> (CaptionMascot,OverlayController)? in
            guard let c=overlays.character(for:s),c.panel.isVisible,c.subtitle.mascotArtwork=="blue-fish-orange-hoodie" else {return nil};return (s,c)
        }).first else {if running {stop()};return}
        let (actor,character)=pair
        guard !character.panel.isManuallyDragging,!character.subtitle.dragReaction.active,
            character.subtitle.screenEdgeDock==nil,!character.subtitle.headPatActive,
            character.subtitle.crabPetEligible,let screen=character.panel.screen else {if running {stop()};idleSince=nil;return}
        if let motion {
            guard source==actor,!overlays.backdropRelocationInterrupted(for:actor) else {stop();return}
            let slot=floor(now*30)
            if slot>lastSlot {
                lastSlot=slot
                let sample=motion.sample(at:now)
                overlays.applyCrabPet(sample,for:actor)
                if sample.finished {stop();cooldownUntil=now+120;status="摸完螃蟹，坐回休息";return}
            }
        } else {
            if lastOrigin.map({hypot($0.x-character.panel.frame.minX,$0.y-character.panel.frame.minY)>1}) ?? true {
                lastOrigin=character.panel.frame.origin;idleSince=now
            }
            guard now-(idleSince ?? now)>=(preview ? 0:20),now>=cooldownUntil else {return}
        }
        guard !busy,now-lastScan >= (running ? 1:30),CGPreflightScreenCaptureAccess(),
              let displayID=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {return}
        let windows=CrabPetVisibility.windows(on:screen.frame).filter {ownerWindowID == nil || $0.id==ownerWindowID}
        guard !windows.isEmpty else {
            lastScan=now
            if running {stop()}
            status="等待可见的终端螃蟹图标";return
        }
        let regions=windows.flatMap(\.visibleRects).map {CrabPetVisibility.normalized($0,on:screen.frame)}
        busy=true;lastScan=now;scans+=1
        let token=generation,frame=screen.frame,visibleFrame=screen.visibleFrame
        Task { [weak self] in
            guard let self else {return}
            var result:CrabIconDetector.Match?
            do {
                let image=try await self.capture.capture(displayID:displayID,maximumDimension:1280)
                result=await Task.detached(priority:.utility) {CrabIconDetector.detect(image,allowedRegions:regions)}.value
            } catch {result=nil}
            let detection=result
            await MainActor.run {
                self.busy=false
                guard token==self.generation else {return}
                guard let result=detection else {if self.running {self.stop()};self.status="未找到可确认的螃蟹图标";return}
                let r=result.rect
                let rect=CGRect(x:frame.minX+r.minX*frame.width,y:frame.maxY-r.maxY*frame.height,width:r.width*frame.width,height:r.height*frame.height)
                guard let window=CrabPetVisibility.windows(on:frame).first(where:{$0.contains(rect) && (self.ownerWindowID == nil || self.ownerWindowID==$0.id)}) else {
                    if self.running {self.stop()}
                    self.status="图标已被遮挡或窗口已隐藏";return
                }
                self.lastDetected=rect
                if let old=self.target {
                    if hypot(old.midX-rect.midX,old.midY-rect.midY)>12 || abs(old.width-rect.width)>8 {self.stop()}
                    return
                }
                guard character.panel.isVisible,!character.panel.isManuallyDragging,
                      character.subtitle.screenEdgeDock==nil,CrabPetArtwork.shared.available else {return}
                let scale=Double(character.subtitle.layoutScale),from=character.panel.frame.origin
                let mirror=rect.midX<character.panel.frame.midX
                let palm=CrabPetArtwork.palmOffset(in:character.subtitle.bounds,scale:scale,mirrored:mirror)
                let to=CGPoint(x:rect.midX-palm.x,y:rect.maxY-palm.y)
                let body=CrabPetArtwork.canvas(in:character.subtitle.bounds,scale:scale).offsetBy(dx:to.x,dy:to.y)
                let inkBounds=CGRect(x:body.minX,y:body.minY,width:body.width,height:body.height-44*scale)
                guard visibleFrame.contains(inkBounds) else {self.status="图标附近没有足够活动空间";return}
                self.source=actor;self.target=rect;self.ownerWindowID=window.id;self.matches+=1
                self.motion=CrabPetMotion(from:from,to:to,startedAt:ProcessInfo.processInfo.systemUptime,scale:scale)
                self.overlays.beginBackdropRelocation(for:actor);self.status="过去摸摸螃蟹"
            }
        }
    }
    var diagnostics:[String:Any] {["detectedRect":lastDetected.map {[$0.minX,$0.minY,$0.width,$0.height]} ?? [],"requiresFocus":false,"screenPermission":CGPreflightScreenCaptureAccess(),"running":running,"scans":scans,"matches":matches,"status":status,"maxCaptureDimension":1280,"idleScanInterval":30,"activeScanInterval":1]}
}
