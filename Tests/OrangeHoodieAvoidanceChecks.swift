import AppKit
import ImageIO
import UniformTypeIdentifiers
import CaptionCore
@testable import CodexCaptions

@main struct OrangeHoodieAvoidanceChecks {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath:"output/orange-hoodie-avoidance")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let animation = MascotAnimation.orangeHoodie
        let cg = animation.frames[0].cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let silhouette = BackdropSilhouette(image:cg)
        func scene(texturedUntil x: Int) throws -> BackdropScene {
            let c = CGContext(data:nil,width:800,height:600,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x:0,y:0,width:800,height:600))
            for stripe in stride(from:0,to:x,by:8) {
                c.setFillColor(NSColor.black.cgColor); c.fill(CGRect(x:stripe,y:0,width:4,height:600))
            }
            return try BackdropScene.analyze(c.makeImage()!,frame:CGRect(x:0,y:0,width:800,height:600),at:0)
        }
        let from = CGPoint(x:200,y:200), sprite = CGRect(x:200,y:200,width:126,height:168)
        let area = CGRect(x:0,y:100,width:650,height:300)
        let nearby = try scene(texturedUntil:280)
        let started = ProcessInfo.processInfo.systemUptime
        let plan = BackdropAvoidancePlanner.plan(scene:nearby,silhouette:silhouette,sprite:sprite,
            panelOrigin:from,allowedOrigins:area,scale:1,destinationBounds:silhouette.worldBounds(in:sprite).insetBy(dx:-8,dy:-8),maxDistance:120)!
        let planningMS = (ProcessInfo.processInfo.systemUptime-started)*1000
        precondition(plan.movement == .scoot && plan.distance <= 120 && nearby.isBlank(plan.destinationBody))
        let far = try scene(texturedUntil:500)
        precondition(BackdropAvoidancePlanner.plan(scene:far,silhouette:silhouette,sprite:sprite,
            panelOrigin:from,allowedOrigins:area,scale:1,maxDistance:120) == nil,"No short blank means wait, never use another character's far action")
        var timings = [Double](), maxStep: CGFloat = 0
        for direction in [-1.0,1.0] {
            let relocation = BackdropRelocation()
            let target = CGPoint(x:from.x+64*direction,y:from.y)
            relocation.start(BackdropAvoidancePlan(from:from,to:target,movement:.scoot,destinationBody:.zero),scale:1,at:0)
            let count = Int(ceil(relocation.duration*24))
            let dest = CGImageDestinationCreateWithURL(output.appendingPathComponent(direction < 0 ? "left.gif" : "right.gif") as CFURL,UTType.gif.identifier as CFString,count+1,nil)!
            CGImageDestinationSetProperties(dest,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            var previous: CGPoint?, lastOrigin = from
            for i in 0...count {
                let sample = relocation.sample(at:Double(i)/24)
                let origin = sample?.origin ?? target
                let pose = OrangeHoodieScoot.Pose(progress:sample?.scoot?.pushPhase ?? 1,direction:CGFloat(direction))
                let point = CGPoint(x:192,y:400).applying(pose.transform)
                if let previous { maxStep = max(maxStep,hypot(point.x-previous.x,point.y-previous.y)) }
                previous = point
                precondition(direction*(origin.x-lastOrigin.x) >= -0.001,"Short relocation cannot reverse")
                precondition(origin.y == from.y && abs(origin.x-from.x) <= 64.001)
                lastOrigin = origin
                let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640,pixelsHigh:540,bitsPerSample:8,
                    samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                let begin = ProcessInfo.processInfo.systemUptime
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:image)
                NSColor.white.setFill(); NSRect(x:0,y:0,width:640,height:540).fill()
                OrangeHoodieScoot.draw(pose,frame:0,in:NSRect(x:128+(origin.x-from.x)*2,y:8,width:384,height:512))
                NSGraphicsContext.restoreGraphicsState()
                timings.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
                CGImageDestinationAddImage(dest,image.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/24]] as CFDictionary)
                if direction > 0 && i == 24 { try image.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("moving.png")) }
            }
            precondition(CGImageDestinationFinalize(dest))
            precondition(lastOrigin == target)
            // Scene changes settle at the current position and return to a neutral pose.
            relocation.start(BackdropAvoidancePlan(from:from,to:target,movement:.scoot,destinationBody:.zero),scale:1,at:0)
            let midwaySample = relocation.sample(at:0.9)!
            let midway = midwaySample.origin
            relocation.settle(at:midway,now:0.9)
            precondition(relocation.sample(at:1)!.origin == midway)
            precondition(relocation.sample(at:0.9)!.scoot?.pushPhase == midwaySample.scoot?.pushPhase)
            precondition(relocation.sample(at:1.4) == nil)
        }
        precondition(maxStep < 3,"Procedural pose must be continuous at cycle boundaries")
        for p in [0.0,1] {
            let t = OrangeHoodieScoot.Pose(progress:p,direction:1).transform
            precondition(abs(t.a-1)+abs(t.b)+abs(t.c)+abs(t.d-1)+abs(t.tx)+abs(t.ty)<1e-8,"Action endpoints must exactly restore the same artwork")
        }
        let overlays = ProjectOverlays()
        overlays.update([],font:18,opacity:0.7,bottom:60,screenIndex:0,movable:true,focusedID:"",
            restingMascots:[.codex,.deepseek],characterBindings:[.codex:.orangeHoodie,.deepseek:.deepseek])
        let hoodie = overlays.character(for:.codex)!, original = overlays.character(for:.deepseek)!
        defer { hoodie.panel.orderOut(nil); original.panel.orderOut(nil) }
        let originalOrigin = original.panel.frame.origin
        overlays.beginBackdropRelocation(for:.codex)
        let here = hoodie.panel.frame.origin, there = CGPoint(x:here.x+20,y:here.y)
        overlays.applyBackdropRelocation(BackdropRelocationSample(origin:there,
            scoot:.init(frame:3,offset:0.5,phase:"短程挪动",pushPhase:0.4),stroll:nil,mirrored:true,phase:"短程"),for:.codex)
        precondition(hoodie.panel.frame.origin == there && original.panel.frame.origin == originalOrigin)
        precondition(hoodie.subtitle.hoodieScootPose?.direction == -1 && hoodie.subtitle.scootSample == nil)
        precondition(hoodie.subtitle.performanceFrameIndex == nil && !hoodie.subtitle.seatedGazeActive)
        overlays.endBackdropRelocation(for:.codex)
        precondition(hoodie.subtitle.hoodieScootPose == nil && hoodie.subtitle.seatedGazeActive && !hoodie.subtitle.hasScootRestPose)
        overlays.beginBackdropRelocation(for:.deepseek)
        var legacy = BackdropRelocationSample(origin:originalOrigin,
            scoot:.init(frame:2,offset:0,phase:"准备",pushPhase:0.1),stroll:nil,mirrored:false,phase:"短程")
        overlays.applyBackdropRelocation(legacy,for:.deepseek)
        let held = original.subtitle.scootSample
        legacy = BackdropRelocationSample(origin:originalOrigin,
            scoot:.init(frame:2,offset:0,phase:"准备",pushPhase:0.2),stroll:nil,mirrored:false,phase:"短程")
        overlays.applyBackdropRelocation(legacy,for:.deepseek)
        precondition(original.subtitle.scootSample == held && held?.pushPhase == 0,
            "Continuous hoodie motion must not invalidate the original character's held-frame deduplication")
        overlays.endBackdropRelocation(for:.deepseek)
        original.panel.orderOut(nil)
        precondition(overlays.eligibleBackdropSources(allowHoodie:true) == [.codex],
            "An invisible original actor cannot block a visible hoodie actor")
        precondition(overlays.eligibleBackdropSources(allowHoodie:false).isEmpty)
        let shared = ProjectOverlays()
        shared.update([],font:18,opacity:0.7,bottom:60,screenIndex:0,movable:true,focusedID:"",
            restingMascots:[.codex,.deepseek],characterBindings:[.codex:.orangeHoodie,.deepseek:.orangeHoodie])
        precondition(shared.character(for:.codex) === shared.character(for:.deepseek))
        precondition(shared.eligibleBackdropSources(allowHoodie:true) == [.codex],
            "Two harness bindings of one character must only scan one native window")
        shared.character(for:.codex)?.panel.orderOut(nil)
        timings.sort()
        print("PASS: short-only planner, nearby blank, far target rejected, left/right monotone motion, settle, neutral endpoints, source-bound native window, gaze restoration")
        print(String(format:"Planner %.2f ms; %d rendered samples, median %.2f ms, p95 %.2f ms; max head step %.2f source px",planningMS,timings.count,timings[timings.count/2],timings[Int(Double(timings.count)*0.95)],maxStep))
    }
}
