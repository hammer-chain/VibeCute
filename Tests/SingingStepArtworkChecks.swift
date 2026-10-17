import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum SingingStepArtworkChecks {
    static func performance() throws {
        let clock = ProcessInfo.processInfo
        let start = clock.systemUptime
        let art = DeepSeekPerformance.shared, mascot = MascotAnimation.library[.deepseek]!
        precondition(art.singingStepAvailable)
        let initialized = clock.systemUptime
        // Default 147×210 point character on a 2× display; actual production draw.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:294,pixelsHigh:420,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:294*4,bitsPerPixel:32)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x:2,y:2)
        func cycle(_ rounds:Int) {
            for _ in 0..<rounds { for frame in 32..<40 { for mouth in 0..<12 {
                context.clear(CGRect(x:0,y:0,width:147,height:210))
                art.draw(frame:frame,mouth:mouth,animation:mascot,in:CGRect(x:0,y:0,width:147,height:210))
            } } }
        }
        let cold = clock.systemUptime; cycle(1)
        let firstCycle = clock.systemUptime-cold
        var batches:[Double] = []
        for _ in 0..<5 {
            let began = clock.systemUptime; cycle(10)
            batches.append((clock.systemUptime-began)*1000/960)
        }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        let result:[String:Any] = ["metadataAndImageInitMs":(initialized-start)*1000,
            "first96DrawsMs":firstCycle*1000,"steadyMsPerDraw":batches,
            "medianSteadyMsPerDraw":batches.sorted()[2],"steadyDrawCount":4800,
            "peakResidentBytes":usage.ru_maxrss,"renderPixels":[294,420],
            "runtimeFrameBudgetMs":1000.0/60,"scope":"Production character drawing only; not whole-app startup or audio processing"]
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
    }

    static func run() throws {
        let art = DeepSeekPerformance.shared, mascot = MascotAnimation.library[.deepseek]!
        precondition(art.available && art.kiraAvailable && art.singingStepAvailable)
        let folder = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CAPTIONS_SINGING_STEP_OUTPUT"]
            ?? FileManager.default.currentDirectoryPath+"/output/deepseek-singing-step")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var images: [CGImage] = []
        for index in 32..<40 {
            var rendered: [NSBitmapImageRep] = []
            for mouth in 0..<MascotAnimation.mouthCount {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:448,pixelsHigh:640,bitsPerSample:8,
                    samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:448*4,bitsPerPixel:32)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
                NSGraphicsContext.current!.cgContext.clear(CGRect(x:0,y:0,width:448,height:640))
                art.draw(frame:index,mouth:mouth,animation:mascot,in:CGRect(x:0,y:0,width:448,height:640))
                NSGraphicsContext.restoreGraphicsState()
                let data = bitmap.bitmapData!
                let visible = (0..<(448*640)).filter { data[$0*4+3] > 64 }
                let xs = visible.map { $0%448 }, ys = visible.map { $0/448 }
                precondition(xs.min()! > 1 && xs.max()! < 446 && ys.min()! > 1 && ys.max()! < 638,"Whole body stays in frame")
                precondition(abs(ys.max()!-620) <= 2 || abs(ys.min()!-19) <= 2,"Standing foot baseline is fixed")
                rendered.append(bitmap)
            }
            let closed = Data(bytes:rendered[0].bitmapData!,count:448*640*4)
            // Independent evidence comes from the mouth ink on the neutral body,
            // not the overlay's metadata. The old common x=204 fails this check.
            let body = NSBitmapImageRep(cgImage:art.frames[index].cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            var lips: [NSPoint] = []
            for y in 280..<290 { for x in 176..<230 {
                let c = body.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if c.alphaComponent > 240/255 && c.redComponent > 180/255 &&
                    c.greenComponent > 70/255 && c.greenComponent < 190/255 &&
                    c.blueComponent < 175/255 && c.redComponent-c.greenComponent > 35/255 {
                    lips.append(NSPoint(x:x,y:y))
                }
            } }
            precondition(lips.count >= 4)
            let center = NSPoint(x:(lips.map(\.x).min()!+lips.map(\.x).max()!+1)/2,
                                 y:(lips.map(\.y).min()!+lips.map(\.y).max()!+1)/2)
            for mouth in 1..<MascotAnimation.mouthCount {
                let open = Data(bytes:rendered[mouth].bitmapData!,count:448*640*4)
                precondition(closed != open,"Every live mouth renders on every step frame")
                var changed: [NSPoint] = []
                for pixel in 0..<(448*640) {
                    let start = pixel*4
                    if (0..<4).contains(where:{ closed[start+$0] != open[start+$0] }) {
                        // cacheDisplay bitmap rows are y down at this resolution.
                        changed.append(NSPoint(x:pixel%448,y:pixel/448))
                    }
                }
                precondition(!changed.isEmpty)
                let patchCenter = NSPoint(x:(changed.map(\.x).min()!+changed.map(\.x).max()!+1)/2,
                                          y:(changed.map(\.y).min()!+changed.map(\.y).max()!+1)/2)
                precondition(abs(patchCenter.x-center.x) <= 1.5 && abs(patchCenter.y-center.y) <= 1.5,
                             "Mouth \(mouth), step \(index-32) drifts from its face")
            }
            images.append(rendered[2].cgImage!)
            try rendered[2].representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(String(format:"mouth-check-%02d.png",index-32)))
        }
        for left in [false,true] {
            let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent(left ? "singing-step-left.gif" : "singing-step-right.gif") as CFURL,
                UTType.gif.identifier as CFString,32,nil)!
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            for i in 0..<32 {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:360,pixelsHigh:230,bitsPerSample:8,
                    samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
                NSColor(calibratedWhite:0.96,alpha:1).setFill(); CGRect(x:0,y:0,width:360,height:230).fill()
                let x = left ? 180-Double(i)*4 : 25+Double(i)*4
                if left {
                    NSGraphicsContext.current!.cgContext.translateBy(x:2*x+147,y:0)
                    NSGraphicsContext.current!.cgContext.scaleBy(x:-1,y:1)
                }
                NSImage(cgImage:images[i%8],size:NSSize(width:448,height:640)).draw(in:CGRect(x:x,y:8,width:147,height:210))
                NSGraphicsContext.restoreGraphicsState()
                CGImageDestinationAddImage(gif,bitmap.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(gif))
        }
        print("PASS: eight full step poses, fixed floor, all 12 mouths, face-relative mouth registration, left/right continuous previews")
    }
}
