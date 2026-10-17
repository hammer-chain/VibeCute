import AppKit
import ImageIO
import UniformTypeIdentifiers

enum SingingArtworkChecks {
    static func run() throws {
        let performance = DeepSeekPerformance.shared
        precondition(performance.available, "All 16 transition and 8 singing frames must be bundled")
        let mascot = MascotAnimation.library[.deepseek]!
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("output/deepseek-singing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var closed: [CGImage] = [], speaking: [CGImage] = []
        for index in 0..<24 {
            for mouth in [0, 2] {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 448, pixelsHigh: 640,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 448 * 4, bitsPerPixel: 32)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current!.cgContext.clear(NSRect(x: 0, y: 0, width: 448, height: 640))
                performance.draw(frame: index, mouth: mouth, animation: mascot, in: NSRect(x: 0, y: 0, width: 448, height: 640))
                NSGraphicsContext.restoreGraphicsState()
                let data = bitmap.bitmapData!
                let visible = (0..<(448 * 640)).filter { data[$0 * 4 + 3] > 64 }
                let xs = visible.map { $0 % 448 }, ys = visible.map { $0 / 448 }
                precondition(xs.min()! > 1 && xs.max()! < 446 && ys.min()! > 1 && ys.max()! < 638,
                             "Full hair, skirt, shoes and tail need clear canvas margins in frame \(index)")
                precondition(abs(ys.max()! - 620) <= 2 || abs(ys.min()! - 19) <= 2,
                             "Frame \(index) must keep the same floor anchor")
                if mouth == 0 { closed.append(bitmap.cgImage!) } else { speaking.append(bitmap.cgImage!) }
            }
        }
        try contactSheet(closed, path: folder.appendingPathComponent("body-contact-sheet.png"))
        try contactSheet(speaking, path: folder.appendingPathComponent("mouth-registration-check.png"))
        // Mouth anchors track the head's vertical movement. After the single
        // preparatory lean, tolerate only tiny drawing variation, not a dip.
        let anchorURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/CodexCaptions/Resources/DeepSeekThinking/Performance/mouth-anchors.json")
        let anchors = try JSONDecoder().decode([DeepSeekPerformance.MouthAnchor].self, from: Data(contentsOf: anchorURL))
        let heights = SingingTimeline.risingFrames.map { anchors[$0].y }
        let lean = heights.firstIndex(of: heights.min()!)!
        for index in 1..<heights.count {
            let movement = heights[index] - heights[index - 1]
            precondition(index <= lean ? movement <= 4 : movement >= -4,
                         "Stand-up must lean once, then keep rising; wrong pose at playback step \(index)")
        }
        typealias Step = (frame: Int, duration: Double)
        let pause: [Step] = [(0, 0.8)]
        let rising = SingingTimeline.risingFrames.map { Step($0, SingingTimeline.transitionFrameDuration) }
        let singing = (0..<2).flatMap { _ in
            zip(SingingTimeline.singingFrames, SingingTimeline.singingFractions).map { Step($0, $1 * SingingTimeline.defaultCycleDuration) }
        }
        let sequence = pause + rising + singing + Array(rising.reversed()) + pause
        let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("singing-preview.gif") as CFURL,
            UTType.gif.identifier as CFString, sequence.count, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (step, pose) in sequence.enumerated() {
            let index = pose.frame
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 224, pixelsHigh: 320,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 224, height: 320).fill()
            NSImage(cgImage: index >= 16 && step % 3 != 0 ? speaking[index] : closed[index], size: NSSize(width: 448, height: 640))
                .draw(in: NSRect(x: 0, y: 0, width: 224, height: 320))
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(gif, bitmap.cgImage!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: pose.duration]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        print("PASS: 24 complete singing frames, one lean then continuous rise, fixed floor, live mouth registration, exported full-action preview")
    }

    private static func contactSheet(_ frames: [CGImage], path: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 896, pixelsHigh: 2040,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 896, height: 2040).fill()
        for (index, frame) in frames.enumerated() {
            let x = CGFloat(index % 4) * 224, y = CGFloat(5 - index / 4) * 340
            NSImage(cgImage: frame, size: NSSize(width: 448, height: 640))
                .draw(in: NSRect(x: x, y: y + 20, width: 224, height: 320))
            (String(format: "%02d", index) as NSString).draw(at: NSPoint(x: x + 105, y: y + 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray])
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
}
