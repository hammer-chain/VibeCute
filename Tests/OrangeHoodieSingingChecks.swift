import AppKit
import ImageIO
import UniformTypeIdentifiers
import CaptionCore
@testable import CodexCaptions

@main
struct OrangeHoodieSingingChecks {
    static func main() throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath:"output/orange-hoodie-singing")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let start = ProcessInfo.processInfo.systemUptime
        let art = OrangeHoodiePerformance.shared
        precondition(art.available && art.frames.count == 16)
        let coldMS = (ProcessInfo.processInfo.systemUptime-start)*1000
        func render(_ pose: OrangeHoodieSingingPose?, mouth: Int? = 2) -> NSBitmapImageRep {
            let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:448,pixelsHigh:640,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:image)
            NSColor.white.setFill(); NSRect(x:0,y:0,width:448,height:640).fill()
            if let pose { art.draw(pose:pose,mouth:mouth,in:NSRect(x:0,y:0,width:448,height:640)) }
            else { MascotAnimation.orangeHoodie.drawSeated(mouth:mouth,in:NSRect(x:32,y:0,width:384,height:512),at:0,motionAmount:0) }
            NSGraphicsContext.restoreGraphicsState(); return image
        }
        func bytes(_ image: NSBitmapImageRep)->Data { Data(bytes:image.bitmapData!,count:image.bytesPerRow*image.pixelsHigh) }
        // At a key pose the body must equal one uninterrupted cached sprite draw.
        // This catches the old antialiased neckline clipping seam.
        for index in 1..<16 {
            let expected = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:448,pixelsHigh:640,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:expected)
            NSColor.white.setFill(); NSRect(x:0,y:0,width:448,height:640).fill()
            let cg = art.frames[index].cgImage(forProposedRect:nil,context:nil,hints:nil)!
            NSGraphicsContext.current!.cgContext.draw(cg,in:CGRect(x:0,y:0,width:448,height:640))
            NSGraphicsContext.restoreGraphicsState()
            precondition(bytes(render(OrangeHoodieSingingPose(first:index,second:index,blend:0),mouth:nil)) == bytes(expected),
                "Key pose must have no internal clipping seam")
        }
        precondition(art.mouths[7] == art.mouths[8])
        precondition(bytes(render(.transition(1))) == bytes(render(.loop(0))), "Rise endpoint equals singing loop entry")
        // At the return endpoint the original seated art and live mouth are restored.
        precondition(bytes(render(.transition(0),mouth:nil)) == bytes(render(nil,mouth:nil)))
        let sheet = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1792,pixelsHigh:2560,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:sheet)
        NSColor.white.setFill(); NSRect(x:0,y:0,width:1792,height:2560).fill()
        for i in 0..<16 {
            art.draw(pose:OrangeHoodieSingingPose(first:i,second:i,blend:0),mouth:2,
                in:NSRect(x:i%4*448,y:(3-i/4)*640,width:448,height:640))
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("registered-poses.png"))
        // Inspect the half-way samples where silhouette crossfades used to ghost.
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:sheet)
        NSColor.white.setFill(); NSRect(x:0,y:0,width:1792,height:2560).fill()
        for i in 0..<16 {
            art.draw(pose:OrangeHoodieSingingPose(first:i,second:i < 7 ? i+1 : (i < 8 ? 8 : 8+(i-7)%8),blend:0.5),mouth:2,
                in:NSRect(x:i%4*448,y:(3-i/4)*640,width:448,height:640))
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("midpoint-poses.png"))
        func blueSaturation(_ index: Int) -> Double {
            let bitmap = render(OrangeHoodieSingingPose(first:index,second:index,blend:0),mouth:nil)
            let p = bitmap.bitmapData!
            var values = [Double]()
            for y in stride(from:0,to:640,by:2) {
                for x in stride(from:0,to:448,by:2) {
                    let i = y*bitmap.bytesPerRow+x*4
                    let r = Double(p[i]), g = Double(p[i+1]), b = Double(p[i+2])
                    if b > r*1.3 && b > g && b-min(r,g)>25 { values.append((b-min(r,g))/b) }
                }
            }
            values.sort(); return values[values.count/2]
        }
        let seatedSaturation = blueSaturation(0)
        let standingSaturation = blueSaturation(8)
        precondition(abs(seatedSaturation-standingSaturation)<0.08,"Standing blue palette drifted from seated")
        print(String(format:"Palette blue median saturation: seated %.3f, standing %.3f",seatedSaturation,standingSaturation))
        // A patch around the eyes/head must match a rigidly translated source,
        // including just before and after the old scale-switch discontinuity.
        for progress in [0.0699,0.073,0.21,0.36,0.50,0.64,0.79,0.93] {
            let pose = OrangeHoodieSingingPose.transition(progress)
            let index = pose.blend < 0.5 ? pose.first : pose.second
            let target = art.mouthCenter(for:pose), source = art.mouths[index]
            let expected = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:448,pixelsHigh:640,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:expected)
            NSColor.white.setFill(); NSRect(x:0,y:0,width:448,height:640).fill()
            let cg = art.frames[index].cgImage(forProposedRect:nil,context:nil,hints:nil)!
            NSGraphicsContext.current!.cgContext.draw(cg,in:CGRect(x:target.x-source.x,y:target.y-source.y,width:448,height:640))
            NSGraphicsContext.restoreGraphicsState()
            let actual = render(pose,mouth:nil)
            var error = 0.0, channels = 0, ink = 0
            for y in Int(640-target.y-110)..<Int(640-target.y-5) {
                for x in Int(target.x-70)..<Int(target.x+70) {
                    let i = y*expected.bytesPerRow+x*4
                    if expected.bitmapData![i] < 220 { ink += 1 }
                    for c in 0..<3 {
                        error += abs(Double(actual.bitmapData![i+c])-Double(expected.bitmapData![i+c])); channels += 1
                    }
                }
            }
            precondition(ink > 500,"Head comparison must contain artwork")
            precondition(error/Double(channels)<3,"Head was scaled or distorted instead of rigidly translated")
        }
        // One deliberate lean, then a monotone rise; no extra anchor reversals.
        let centers = (0...100).map { art.mouthCenter(for:.transition(Double($0)/100)).y }
        for i in 1...24 { precondition(centers[i] <= centers[i-1]+0.001) }
        for i in 25...100 { precondition(centers[i] >= centers[i-1]-0.001) }
        print("PASS: rigid head raster at eight rise samples and a single smooth lean/rise trajectory")
        // End-to-end clock → hoodie pose checks at the detector's supported tempi.
        for bpm in [60.0,100,120,180,240,360] {
            var clock = SingingPerformance(), body = OrangeHoodieSingingPlayback()
            var cycles = 0.0, previous = 0.0
            for step in 0...720 {
                let t = Double(step)/24
                let beat = BeatEstimate(bpm:bpm,confidence:0.9,audioTime:t,
                    lastBeatTime:floor(t/(60/bpm))*(60/bpm))
                _ = clock.sample(scene:SoundScene(kind:.singing,singing:0.9,music:0.8,audioTime:t),level:0.3,at:t,beat:beat)
                let pose = body.sample(phase:clock.phase,cycle:clock.cycleProgress,at:t)
                if t >= 20 {
                    let advance = (clock.cycleProgress-previous+1).truncatingRemainder(dividingBy:1)
                    precondition(advance > 0 && advance < 0.04,"BPM changes cannot reverse or jump the clock")
                    if t > 20 { cycles += advance }
                    precondition(pose == OrangeHoodieSingingPose.loop(clock.cycleProgress))
                }
                previous = clock.cycleProgress
            }
            let expected = SingingTimeline.segmentsPerCycle*SingingTimeline.beatsPerSegment(forBPM:bpm)*60/bpm
            precondition(abs(clock.cycleDuration-expected)<0.001)
            precondition(abs(cycles-10/expected)<0.02,"Hoodie loop frequency must follow the BPM clock")
            let heldDuration = clock.cycleDuration, before = clock.cycleProgress
            for step in 721...768 {
                let t = Double(step)/24
                _ = clock.sample(scene:SoundScene(kind:.music,music:0.8,audioTime:t),level:0.3,at:t,beat:.unknown)
            }
            precondition(abs(clock.cycleDuration-heldDuration)<0.001 && clock.cycleProgress != before,
                "Temporary BPM loss must hold speed and keep moving")
            let changedBPM = bpm == 120 ? 60.0 : 120.0
            previous = clock.cycleProgress
            for step in 769...1008 {
                let t = Double(step)/24
                let beat = BeatEstimate(bpm:changedBPM,confidence:0.9,audioTime:t,
                    lastBeatTime:floor(t/(60/changedBPM))*(60/changedBPM))
                _ = clock.sample(scene:SoundScene(kind:.music,music:0.8,audioTime:t),level:0.3,at:t,beat:beat)
                let advance = (clock.cycleProgress-previous+1).truncatingRemainder(dividingBy:1)
                precondition(advance > 0 && advance < 0.04,"Tempo changes must preserve forward phase continuity")
                previous = clock.cycleProgress
                precondition(body.sample(phase:clock.phase,cycle:clock.cycleProgress,at:t) == .loop(clock.cycleProgress))
            }
            precondition(abs(clock.cycleDuration-240/changedBPM)<0.01,"Tempo must converge after a change")
            for index in 0..<8 {
                let pose = OrangeHoodieSingingPose.loop((Double(index)+0.37)/8)
                precondition(pose.first == 8+index && pose.second == 8+(index+1)%8)
                precondition(abs(pose.blend-0.37)<0.00001,"All sway segments must advance uniformly without accent holds")
            }
            print(String(format:"PASS hoodie BPM %.0f: %.3f seconds/cycle, %.3f cycles/10s, dropout holds speed, tempo change stays continuous",bpm,expected,cycles))
        }
        // Native raster regression for two opposite face rolls, with the source
        // patch's seated roll removed. Rotating about the origin would shift it.
        for (index, dx, dy) in [(9,54.37,2.28),(13,54.93,-2.47)] {
            let expectedAngle = atan2(-dy,dx)+atan2(6.0,71.0)
            precondition(abs(Double(art.mouthRotations[index])-expectedAngle)<0.00001)
            let animation = MascotAnimation.orangeHoodie
            for mouth in [3,10] {
                let expected = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:448,pixelsHigh:640,bitsPerSample:8,
                    samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:expected)
                NSColor.white.setFill(); NSRect(x:0,y:0,width:448,height:640).fill()
                let context = NSGraphicsContext.current!.cgContext
                context.draw(art.frames[index].cgImage(forProposedRect:nil,context:nil,hints:nil)!,in:CGRect(x:0,y:0,width:448,height:640))
                context.translateBy(x:art.mouths[index].x,y:art.mouths[index].y)
                context.rotate(by:expectedAngle)
                let patch = NSRect(x:-animation.mouthRect.width/2,y:-animation.mouthRect.height/2,
                    width:animation.mouthRect.width,height:animation.mouthRect.height)
                NSBezierPath(ovalIn:patch).addClip()
                animation.mouths[mouth].draw(in:patch,from:.zero,operation:.sourceOver,fraction:1)
                NSGraphicsContext.restoreGraphicsState()
                precondition(bytes(render(OrangeHoodieSingingPose(first:index,second:index,blend:0),mouth:mouth)) == bytes(expected),
                    "Mouth raster must rotate with the head around its fixed local anchor")
            }
        }
        print("PASS: mouth roll follows two opposite eye baselines, with fixed pivot and two mouth shapes")
        let count = 240
        let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("singing-preview.gif") as CFURL,UTType.gif.identifier as CFString,count,nil)!
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        var player = SingingPerformance(), playback = OrangeHoodieSingingPlayback()
        var phases = Set<String>(), timings = [Double]()
        var previous: NSPoint?
        var maxMouthStep: CGFloat = 0
        for i in 0..<count {
            let time = Double(i)/24
            let singing = time >= 0.5 && time < 7.5
            let scene = SoundScene(kind:singing ? .singing : .silence,singing:singing ? 0.9 : 0,music:singing ? 0.8 : 0,audioTime:time)
            _ = player.sample(scene:scene,level:singing ? 0.3 : 0,at:time)
            phases.insert(player.phase.rawValue)
            let pose = playback.sample(phase:player.phase,cycle:player.cycleProgress,at:time)
            let now = ProcessInfo.processInfo.systemUptime
            let image = render(pose,mouth:singing ? [2,3,4,5,6,10][Int(time*3)%6] : nil)
            timings.append((ProcessInfo.processInfo.systemUptime-now)*1000)
            let center = pose.map { art.mouthCenter(for:$0) } ?? art.mouths[0]
            if let previous { maxMouthStep = max(maxMouthStep,hypot(center.x-previous.x,center.y-previous.y)) }
            previous = center
            CGImageDestinationAddImage(destination,image.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/24]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        precondition(phases == ["seated","rising","singing","sitting"])
        precondition(maxMouthStep < 16, "Transition face anchor jumped more than 16 source pixels")
        // Interrupted rises return from the current height rather than full standing.
        var interrupted = OrangeHoodieSingingPlayback()
        _ = interrupted.sample(phase:.rising,cycle:0,at:0)
        let before = interrupted.sample(phase:.rising,cycle:0,at:0.4)!
        let after = interrupted.sample(phase:.sitting,cycle:0,at:0.4)!
        precondition(before == after)
        let overlays = ProjectOverlays()
        overlays.update([],font:18,opacity:0.7,bottom:60,screenIndex:0,movable:true,focusedID:"",
            restingMascots:[.codex,.deepseek],characterBindings:[.codex:.orangeHoodie,.deepseek:.deepseek])
        defer { overlays.character(for:.codex)?.panel.orderOut(nil); overlays.character(for:.deepseek)?.panel.orderOut(nil) }
        overlays.setOrangeHoodieSinging(phase:.singing,cycle:0.3,at:10,targets:[.codex])
        let view = overlays.character(for:.codex)!.subtitle
        precondition(view.hoodieSingingPose != nil && !view.seatedGazeActive)
        precondition(overlays.character(for:.deepseek)!.subtitle.hoodieSingingPose == nil)
        view.setAudioMouth(3); view.setMascot(.orangeHoodie,animating:true)
        precondition(view.hoodieSingingPose != nil && view.audioMouthIndex == 3)
        overlays.setOrangeHoodieSinging(phase:.seated,cycle:0,at:11,targets:[])
        precondition(view.hoodieSingingPose == nil && view.seatedGazeActive)
        timings.sort()
        print("PASS: 240 rendered samples, all four acoustic phases, exact seated/rise/loop endpoints, interrupted rise, bound native window and gaze/mouth restoration")
        print(String(format:"Cold load %.2f ms; full 448x640 render median %.2f ms, p95 %.2f ms; maximum face step %.2f source px",coldMS,timings[count/2],timings[Int(Double(count)*0.95)],maxMouthStep))
    }
}
