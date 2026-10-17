import AppKit
import ImageIO
import UniformTypeIdentifiers

enum KiraArtworkChecks {
    static func run() throws {
        let art = DeepSeekPerformance.shared, mascot = MascotAnimation.library[.deepseek]!
        precondition(art.kiraAvailable)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/deepseek-kira")
        var images: [Int: CGImage] = [:]
        for index in [16,17,18,20,19,21,22,23] + Array(24..<32) {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 448, pixelsHigh: 640,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 448*4, bitsPerPixel: 32)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current!.cgContext.clear(NSRect(x: 0,y: 0,width: 448,height: 640))
            art.draw(frame: index, mouth: 2, animation: mascot, in: NSRect(x: 0,y: 0,width: 448,height: 640))
            NSGraphicsContext.restoreGraphicsState()
            images[index] = bitmap.cgImage!
            let pixels = bitmap.bitmapData!
            let visible = (0..<(448*640)).filter { pixels[$0*4+3] > 64 }
            let xs=visible.map { $0%448 }, ys=visible.map { $0/448 }
            precondition(xs.min()! > 1 && xs.max()! < 446 && ys.min()! > 1 && ys.max()! < 638, "Kira \(index) clipped")
            precondition(abs(ys.max()!-620) <= 2 || abs(ys.min()!-19) <= 2, "Floor drift \(index)")
        }
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 896,pixelsHigh: 680,bitsPerSample: 8,
            samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:sheet)
        NSColor(calibratedWhite:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:896,height:680).fill()
        for i in 0..<8 {
            let x=CGFloat(i%4)*224, y=CGFloat(1-i/4)*340
            NSImage(cgImage:images[24+i]!,size:NSSize(width:448,height:640)).draw(in:NSRect(x:x,y:y+20,width:224,height:320))
            ("\(i+1)" as NSString).draw(at:NSPoint(x:x+104,y:y+2),withAttributes:[.foregroundColor:NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("contact-sheet.png"))
        let singing = zip(SingingTimeline.singingFrames,SingingTimeline.singingFractions).map { ($0,$1*3) }
        let gesture = Array(zip(KiraTimeline.frames,KiraTimeline.durations))
        let sequence = singing + gesture + singing
        let gif=CGImageDestinationCreateWithURL(folder.appendingPathComponent("singing-to-kira.gif") as CFURL,UTType.gif.identifier as CFString,sequence.count,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for (frame,duration) in sequence {
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:280,pixelsHigh:400,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
            NSColor(calibratedWhite:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:280,height:400).fill()
            NSImage(cgImage:images[frame]!,size:NSSize(width:448,height:640)).draw(in:NSRect(x:0,y:0,width:280,height:400))
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(gif,bitmap.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:duration]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        print("PASS: 8 complete Kira frames, fixed floor, no clipping, exported singing -> Kira -> singing preview")
    }
}
