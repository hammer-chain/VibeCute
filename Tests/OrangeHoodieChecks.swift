import AppKit

@main
struct OrangeHoodieChecks {
    static func main() throws {
        precondition(CharacterChoice.selectable(developerMode: false).contains(.orangeHoodie))
        precondition(CharacterChoice.resolved("blue-fish-orange-hoodie", developerMode: false) == .orangeHoodie)
        precondition(CharacterChoice.orangeHoodie.mascot == .orangeHoodie)
        precondition(CharacterChoice.defaultChoice == .deepseek)
        let start = ProcessInfo.processInfo.systemUptime
        let artwork = MascotAnimation.orangeHoodie
        let loadMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        precondition(artwork === MascotAnimation.orangeHoodie)
        precondition(artwork.frames.count == 8 && artwork.thinkingFrames.count == 8)
        precondition(artwork.mouths.count == 12 && artwork.supportsSeatedGaze)
        let directions = [NSPoint.zero, NSPoint(x:-1,y:0), NSPoint(x:1,y:0), NSPoint(x:0,y:1),
                          NSPoint(x:0,y:-1), NSPoint(x:-0.707,y:0.707), NSPoint(x:0.707,y:0.707),
                          NSPoint(x:-0.707,y:-0.707), NSPoint(x:0.707,y:-0.707)]
        func render(frame: Int = 0, mouth: Int? = nil, gaze: NSPoint? = nil, thinking: Bool = false) -> NSBitmapImageRep {
            let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:384,pixelsHigh:512,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
                bytesPerRow:384*4,bitsPerPixel:32)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:image)
            NSGraphicsContext.current!.cgContext.clear(CGRect(x:0,y:0,width:384,height:512))
            artwork.drawSeated(frame:frame,mouth:mouth,in:NSRect(x:0,y:0,width:384,height:512),
                               at:0,motionAmount:0,gaze:gaze,thinking:thinking)
            NSGraphicsContext.restoreGraphicsState()
            return image
        }
        func pixels(_ image: NSBitmapImageRep) -> Data { Data(bytes:image.bitmapData!,count:image.bytesPerRow*image.pixelsHigh) }
        let base = pixels(render())
        var unique = Set<Data>()
        let drawStart = ProcessInfo.processInfo.systemUptime
        for gaze in directions { for mouth in 0..<12 {
            let output = pixels(render(mouth:mouth,gaze:gaze))
            unique.insert(output)
            // Moving face layers cannot change hair, clothing, hands or silhouette.
            for y in 0..<512 { for x in 0..<384 where !(110..<240).contains(x) || !(175..<249).contains(y) {
                let offset = (y*384+x)*4
                precondition(output[offset..<offset+4] == base[offset..<offset+4], "Face animation escaped its region at \(x),\(y)")
            } }
        } }
        precondition(unique.count == 108, "Every mouth and gaze combination must remain independently visible")
        for frame in [3,4] {
            precondition(pixels(render(frame:frame,mouth:2,gaze:directions[1])) == pixels(render(frame:frame,mouth:2,gaze:directions[2])), "Blink cannot expose moving pupils")
        }
        for frame in 0..<8 {
            let left = pixels(render(frame:frame,gaze:directions[1],thinking:true))
            let right = pixels(render(frame:frame,gaze:directions[2],thinking:true))
            precondition((left == right) == (frame == 4), "Closed eyes mask gaze; all other thinking poses follow")
        }
        let elapsedMS = (ProcessInfo.processInfo.systemUptime-drawStart)*1000
        let path = CommandLine.arguments.dropFirst().first ?? "/tmp/orange-hoodie-face-check.png"
        let sheet = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:960,pixelsHigh:480,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:sheet)
        NSColor.white.setFill(); NSRect(x:0,y:0,width:960,height:480).fill()
        for i in 0..<24 {
            let frame = i < 12 ? 0 : (i-12)%8
            let mouth: Int? = i < 12 ? i : nil
            let gaze = directions[i%3]
            NSGraphicsContext.saveGraphicsState()
            let box = NSRect(x:(i%6)*160,y:(3-i/6)*120,width:160,height:120)
            box.clip()
            artwork.drawSeated(frame:frame,mouth:mouth,in:NSRect(x:box.minX-100,y:box.minY-247,width:384,height:512),
                at:0,motionAmount:0,gaze:gaze,thinking:mouth == nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
        let small = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:252,pixelsHigh:336,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:small)
        var timings = [Double]()
        for i in 0..<310 {
            let begin = ProcessInfo.processInfo.systemUptime
            NSGraphicsContext.current!.cgContext.clear(CGRect(x:0,y:0,width:252,height:336))
            artwork.drawSeated(frame:i%8,mouth:i%12,in:NSRect(x:0,y:0,width:252,height:336),
                at:Double(i)/30,gaze:directions[i%9])
            if i >= 10 { timings.append((ProcessInfo.processInfo.systemUptime-begin)*1000) }
        }
        NSGraphicsContext.restoreGraphicsState()
        timings.sort()
        print(String(format:"Warm 2x-scale drawing, 300 frames: median %.3f ms, p95 %.3f ms",timings[150],timings[285]))
        print("PASS: registration, 108 independent eye/mouth combinations, unchanged body pixels, blink masking, all thinking poses")
        print(String(format:"Cold load %.2f ms; pixel audit %.2f ms (includes full pixel assertions)",loadMS,elapsedMS))
    }
}
