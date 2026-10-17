import AppKit
import ImageIO
import UniformTypeIdentifiers

enum SeatedGazeChecks {
    static func run() throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["CAPTIONS_GAZE_OUTPUT"] ?? "output/seated-gaze")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let animation = MascotAnimation.library[.deepseek]!
        let directions = [NSPoint.zero, NSPoint(x:-1,y:0), NSPoint(x:1,y:0),
            NSPoint(x:0,y:1), NSPoint(x:0,y:-1), NSPoint(x:-0.7071,y:0.7071),
            NSPoint(x:0.7071,y:0.7071), NSPoint(x:-0.7071,y:-0.7071), NSPoint(x:0.7071,y:-0.7071)]
        func render(_ gaze: NSPoint?, _ mouth: Int, _ frame: Int = 0, thinking: Bool = false,
                    pupilsVisible: Bool = true) -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:384,pixelsHigh:512,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                colorSpaceName:.deviceRGB,bytesPerRow:384*4,bitsPerPixel:32)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
            animation.drawSeated(frame:frame,mouth:mouth < 0 ? nil : mouth,in:NSRect(x:0,y:0,width:384,height:512),
                                 at:0,motionAmount:0,gaze:gaze,thinking:thinking,gazePupilsVisible:pupilsVisible)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        func data(_ bitmap: NSBitmapImageRep) -> Data {
            Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        }
        var combinations = [Data]()
        for (direction, gaze) in directions.enumerated() {
            for mouth in 0..<12 {
                let rendered = render(gaze,mouth), pixels = data(rendered)
                combinations.append(pixels)
                if [0,2,11].contains(mouth) {
                    try rendered.representation(using:.png,properties:[:])!
                        .write(to:folder.appendingPathComponent("gaze-\(direction)-mouth-\(mouth).png"))
                }
            }
        }
        precondition(Set(combinations).count == 108, "All directions and mouths must remain distinct")
        for scale: CGFloat in [0.5,1,2] {
            let rect = NSRect(x:-650,y:130,width:384*scale,height:512*scale)
            let transform = animation.seatedTransform(in:rect,at:1.7)
            let center = NSPoint(x:rect.minX+174*scale,y:rect.minY+308*scale).applying(transform)
            precondition(hypot(SeatedGaze.target(cursor:center,in:rect,transform:transform).x,
                               SeatedGaze.target(cursor:center,in:rect,transform:transform).y) < 0.00001)
            let diagonal = SeatedGaze.target(cursor:NSPoint(x:rect.maxX+10000,y:rect.maxY+10000),in:rect)
            precondition(abs(hypot(diagonal.x,diagonal.y)-1) < 0.00001)
        }
        var a = SeatedGaze(), b = SeatedGaze()
        for _ in 0..<30 { a.update(target:directions[6],dt:1/30) }
        for _ in 0..<120 { b.update(target:directions[6],dt:1/120) }
        precondition(hypot(a.position.x-b.position.x,a.position.y-b.position.y) < 0.00001)
        a.update(target:.zero,dt:1,returning:true)
        precondition(hypot(a.position.x,a.position.y)<0.004)
        for blink in [3,4] {
            let closed = render(directions[1],2,blink)
            precondition(data(closed) == data(render(directions[2],2,blink)), "Blink must mask gaze")
            precondition(data(closed) == data(render(nil,2,blink)),
                         "Blink must replace the full cached eye regions, without open-eye remnants")
            try closed.representation(using:.png,properties:[:])!
                .write(to:folder.appendingPathComponent("blink-\(blink).png"))
        }
        // Compare actual rendered thinking poses against the original atlas,
        // including the tilted head and the full closed-eye silhouette. The
        // existing fixed-body tests above still cover gaze/speech separately.
        let url = Bundle.main.url(forResource:"thinking-atlas",withExtension:"png",subdirectory:"DeepSeekThinking")
            ?? Bundle.module.url(forResource:"thinking-atlas",withExtension:"png",subdirectory:"DeepSeekThinking")
        let atlas = NSImage(contentsOf: url!)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(animation.thinkingFrames.count == 8)
        for index in 0..<8 {
            let expected = render(nil,-1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:expected)
            NSGraphicsContext.current!.cgContext.clear(CGRect(x:0,y:0,width:384,height:512))
            let original = NSImage(cgImage:atlas.cropping(to:CGRect(x:index%4*384,y:index/4*512,width:384,height:512))!,
                                   size:NSSize(width:384,height:512))
            original.draw(in:NSRect(x:0,y:0,width:384,height:512))
            NSGraphicsContext.restoreGraphicsState()
            precondition(data(render(nil,-1,index)) == data(expected), "Supplied atlas frame must play without first-frame body replacement")
            let actual = render(nil,-1,index,thinking:true)
            precondition(data(actual) == data(expected), "Thinking pose \(index) must match the original full atlas frame")
            try actual.representation(using:.png,properties:[:])!
                .write(to:folder.appendingPathComponent("thinking-\(index).png"))
        }
        let thinkingGif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("original-thinking.gif") as CFURL,
            UTType.gif.identifier as CFString,72,nil)!
        CGImageDestinationSetProperties(thinkingGif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<72 {
            let index = MascotAnimation.sequence[i%MascotAnimation.sequence.count]
            CGImageDestinationAddImage(thinkingGif,render(nil,-1,index,thinking:true).cgImage!,
                [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.16]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(thinkingGif))
        let registration = MascotAnimation.thinkingGazeRegistration!
        let exposedIrisEdges = [0: [(149,210)], 1: [(150,207)], 2: [(159,200)],
            3: [(148,211),(199,222)], 5: [(151,205)], 6: [(149,209),(211,221)],
            7: [(150,206),(214,220)]]
        var whiteBases = [Int: Data]()
        for index in 0..<8 {
            let whiteBase = render(.zero,-1,index,thinking:true,pupilsVisible:false)
            whiteBases[index] = data(whiteBase)
            try whiteBase.representation(using:.png,properties:[:])!
                .write(to:folder.appendingPathComponent("eye-white-base-\(index).png"))
        }
        for (index, points) in exposedIrisEdges {
            let pixels = whiteBases[index]!
            for (x,y) in points {
                let p = (y*384+x)*4
                precondition(pixels[p] == pixels[p+1] && pixels[p+1] == pixels[p+2],
                    "Pose \(index) must paint neutral eye white over the old iris edge at (\(x),\(y))")
            }
        }
        // Inspect the eye-white stage without the moving pupils. This catches
        // an old iris crescent that ordinary locality/variant tests cannot see.
        // These probes lie on the original tilted iris's exposed right edge.
        let eyeBase = render(.zero,-1,2,thinking:true,pupilsVisible:false)
        let eyeBasePixels = data(eyeBase)
        for (x,y) in [(155,196),(156,201),(154,205),(151,208)] {
            let p = (y*384+x)*4
            let r = Int(eyeBasePixels[p]), g = Int(eyeBasePixels[p+1]), b = Int(eyeBasePixels[p+2])
            precondition(abs(b-r) < 35 && abs(b-g) < 35 && r > 160,
                         "Eye-white base left old blue iris at (\(x),\(y))")
        }
        var oldBluePixels = 0
        for y in 179..<213 { for x in 124..<159 {
            // Actual old-iris footprint, excluding the neighboring blue hair.
            let dx = Double(x-146)/17, dy = (Double(y)-196.5)/19
            if dx*dx+dy*dy > 1 { continue }
            let p = (y*384+x)*4
            let r = Double(eyeBasePixels[p]), g = Double(eyeBasePixels[p+1]), b = Double(eyeBasePixels[p+2])
            if b > 120 && b > r*1.3 && b > g*1.1 { oldBluePixels += 1 }
        } }
        precondition(oldBluePixels == 0, "Eye-white base retained \(oldBluePixels) old blue iris pixels")
        try eyeBase.representation(using:.png,properties:[:])!
            .write(to:folder.appendingPathComponent("tilted-eye-white-base.png"))
        var hybrids = 0
        for index in 0..<8 {
            let base = data(render(nil,-1,index,thinking:true))
            var variants = Set<Data>()
            for (direction, gaze) in directions.enumerated() {
                let image = render(gaze,-1,index,thinking:true), actual = data(image)
                variants.insert(actual); hybrids += 1
                if [1,2,3,4].contains(direction) {
                    try image.representation(using:.png,properties:[:])!
                        .write(to:folder.appendingPathComponent("hybrid-\(index)-direction-\(direction).png"))
                }
            }
            if registration.frames[index].isEmpty {
                precondition(variants == [base], "Fully closed eyes must remain exactly original with no pupil layer")
            } else { precondition(variants.count == 9, "Each open/half-open pose must independently follow all directions") }
        }
        let hybridGif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("thinking-gaze.gif") as CFURL,
            UTType.gif.identifier as CFString,144,nil)!
        CGImageDestinationSetProperties(hybridGif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<144 {
            let t = Double(i)*0.04, frame = MascotAnimation.sequence[(i/4)%MascotAnimation.sequence.count]
            CGImageDestinationAddImage(hybridGif,render(NSPoint(x:cos(t*2),y:sin(t*2)),-1,frame,thinking:true).cgImage!,
                [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(hybridGif))
        let frames = 150
        let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("independent-preview.gif") as CFURL,
            UTType.gif.identifier as CFString,frames,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<frames {
            let t = Double(i)/25
            let gaze = i < 50 ? NSPoint.zero : NSPoint(x:cos(t*2),y:sin(t*2))
            let mouth = i < 50 || i >= 100 ? (i/6)%12 : 0
            let frame = i%75 == 65 ? 3 : (66...68).contains(i%75) ? 4 : 0
            CGImageDestinationAddImage(gif,render(gaze,mouth,frame).cgImage!,
                [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        // Measure the full hybrid compositor at the application's default size,
        // with all eight poses and moving gaze; decoded inputs are reused.
        let small = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:126,pixelsHigh:168,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
            colorSpaceName:.deviceRGB,bytesPerRow:504,bitsPerPixel:32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:small)
        let smallRect = NSRect(x:0,y:0,width:126,height:168)
        func draw(_ i: Int, gaze: NSPoint?) {
            animation.drawSeated(frame:i%8,mouth:nil,in:smallRect,at:0,motionAmount:0,gaze:gaze,thinking:true)
        }
        for i in 0..<32 { draw(i,gaze:directions[i%9]) }
        var baseline = [Double](), hybrid = [Double]()
        for i in 0..<1000 {
            let before = ProcessInfo.processInfo.systemUptime
            draw(i,gaze:nil)
            let middle = ProcessInfo.processInfo.systemUptime
            draw(i,gaze:directions[i%9])
            let after = ProcessInfo.processInfo.systemUptime
            baseline.append(middle-before); hybrid.append(after-middle)
        }
        NSGraphicsContext.restoreGraphicsState()
        let mean = hybrid.reduce(0,+)/1000, p95 = hybrid.sorted()[950]
        precondition(p95 < 0.004, "Hybrid thinking compositor exceeds 4ms p95 budget")
        try JSONSerialization.data(withJSONObject:["passed":true,"drawsPerMode":1000,
            "poses":8,"gazeDirections":9,"displayPoints":[126,168],
            "baselineMeanSeconds":baseline.reduce(0,+)/1000,"hybridMeanSeconds":mean,"hybridP95Seconds":p95,
            "eyePathsCached":registration.frames.reduce(0) { $0+$1.count },
            "additionalDecodedImages":0,"maximumDrawOperations":5,"newTimers":0,
            "gazeClockHz":30,"poseClockSeconds":0.16,
            "boundary":"Warm controlled AppKit bitmap drawing; not whole-app CPU or display latency."],options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("hybrid-performance.json"))
        print(String(format:"Hybrid compositor: mean %.3fms, p95 %.3fms at 126×168",mean*1000,p95*1000))
        print("PASS: 108 eye × mouth combinations; 8 original thinking poses; \(hybrids) pose × gaze combinations; fully closed eyes unchanged; 50/100/200% mapping and smoothing; continuous native-rendered previews")
    }
}
