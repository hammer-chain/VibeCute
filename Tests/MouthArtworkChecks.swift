import AppKit
import ImageIO
import UniformTypeIdentifiers

enum MouthArtworkChecks {
    static func run() throws {
        for character in [CaptionMascot.codex, .deepseek] {
            let animation = MascotAnimation.library[character]!
            precondition(animation.mouths.count == 12)
            let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("output/\(character.rawValue)-lipsync-v2")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var rendered = [CGImage](), data = [Data]()
            for index in 0..<12 {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 384, pixelsHigh: 512,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 384 * 4, bitsPerPixel: 32)!
                let rect = NSRect(x: 0, y: 0, width: 384, height: 512)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current!.cgContext.clear(rect)
                animation.frames[0].draw(in: rect)
                animation.drawMouth(index, in: rect)
                NSGraphicsContext.restoreGraphicsState()
                data.append(Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
                rendered.append(bitmap.cgImage!)
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: folder.appendingPathComponent("mouth-\(index).png"))
            }
            precondition(Set(data).count == 12, "All generated mouth shapes must differ")
            for frame in data.dropFirst() {
                for pixel in 0..<(384 * 512) where frame[pixel * 4..<(pixel + 1) * 4] != data[0][pixel * 4..<(pixel + 1) * 4] {
                    let x = CGFloat(pixel % 384), y = CGFloat(pixel / 384)
                    let rect = animation.mouthRect.insetBy(dx: -1, dy: -1)
                    precondition(rect.contains(NSPoint(x: x, y: y)) || rect.contains(NSPoint(x: x, y: 511 - y)),
                                 "Mouth animation must never change body, wings or tail")
                }
            }
            let sequence = [0, 0, 10, 2, 2, 2, 2, 3, 1, 4, 9, 7, 6, 5, 11, 11, 8, 0, 0]
            let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("mouth-preview.gif") as CFURL,
                UTType.gif.identifier as CFString, sequence.count, nil)!
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for index in sequence {
                CGImageDestinationAddImage(gif, rendered[index],
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.18]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(gif))
            try exportContactSheet(rendered, folder: folder)
        }
        print("PASS: twelve distinct mouths per character; original body/tail pixels preserved; v2 preview assets exported")
        try exportBreathingPreview()
    }

    private static func exportBreathingPreview() throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("output/seated-breathing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = 172
        let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("preview.gif") as CFURL,
            UTType.gif.identifier as CFString, count, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<count {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 384,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 640, height: 384).fill()
            for (column, character) in [CaptionMascot.codex, .deepseek].enumerated() {
                let animation = MascotAnimation.library[character]!
                let rect = NSRect(x: CGFloat(column) * 320 + 34, y: 20, width: 252, height: 336)
                let transform = animation.seatedTransform(in: rect, at: Double(index) / 20)
                let floor = CGPoint(x: rect.midX, y: rect.minY)
                precondition(hypot(floor.applying(transform).x - floor.x,
                                   floor.applying(transform).y - floor.y) < 0.0001)
                animation.drawSeated(mouth: 2, in: rect, at: Double(index) / 20)
            }
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(gif, bitmap.cgImage!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
            if index == 0 {
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("preview.png"))
            }
        }
        precondition(CGImageDestinationFinalize(gif))
        print("PASS: seated breathing preview exported with fixed floor anchors and held mouths")
    }

    private static func exportContactSheet(_ images: [CGImage], folder: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 660,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 800, height: 660).fill()
        let labels = ["自然停顿", "双唇闭合", "大张口", "中等张口", "横向展开", "中圆口", "小撮口", "唇齿接触", "舌尖抬起 · 备用", "窄开露齿", "轻微张口", "大圆口"]
        for index in images.indices {
            let x = CGFloat(index % 4) * 200, y = CGFloat(2 - index / 4) * 220
            if let crop = images[index].cropping(to: CGRect(x: 107, y: 167, width: 140, height: 136)) {
                NSImage(cgImage: crop, size: NSSize(width: 140, height: 136))
                    .draw(in: NSRect(x: x + 12, y: y + 36, width: 176, height: 171))
            }
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            ("\(index + 1)  \(labels[index])" as NSString).draw(in: NSRect(x: x, y: y + 8, width: 200, height: 22),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray,
                                 .paragraphStyle: paragraph])
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("mouth-contact-sheet.png"))
    }
}
