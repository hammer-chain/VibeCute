import AppKit
import ImageIO
import UniformTypeIdentifiers

@main enum LaughterRenderChecks {
    static func main() throws {
        let folder = URL(fileURLWithPath: "output/laughter-priority")
        let data = try Data(contentsOf: folder.appendingPathComponent("model-mouth-trace.json"))
        let all = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let first = all.first { $0["priority"] as! Bool }!["time"] as! Double
        let rows = all.filter { let time = $0["time"] as! Double; return time >= max(0, first - 0.3) && time < first + 5.7 }
        let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("before-after.gif") as CFURL,
            UTType.gif.identifier as CFString, rows.count, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, row) in rows.enumerated() {
            let old = MouthShape(rawValue: row["before"] as! Int)!, new = MouthShape(rawValue: row["after"] as! Int)!
            let image = render(old: old, new: new)
            CGImageDestinationAddImage(gif, image.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.02]] as CFDictionary)
            if [15, 18, 22, 29, 65, 105].contains(index) {
                try image.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(String(format: "preview-%03d.png", index)))
            }
        }
        precondition(CGImageDestinationFinalize(gif))
        print("PASS: continuous native atlas preview of real-laughter trace, \(rows.count) frames, both original characters")
    }

    private static func render(old: MouthShape, new: MouthShape) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 460,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 960, height: 460).fill()
        for (column, character) in [CaptionMascot.codex, .codex, .deepseek, .deepseek].enumerated() {
            let animation = MascotAnimation.library[character]!
            let pose = column % 2 == 0 ? old : new
            let rect = NSRect(x: Double(column) * 240 + 15, y: 15, width: 210, height: 280)
            animation.drawSeated(mouth: pose.rawValue, in: rect, at: 0, motionAmount: 0)
            let crop = NSRect(x: animation.mouthRect.midX - 27, y: animation.mouthRect.midY - 21, width: 54, height: 42)
            let full = NSImage(size: NSSize(width: 384, height: 512))
            full.lockFocus()
            animation.drawSeated(mouth: pose.rawValue, in: NSRect(x: 0, y: 0, width: 384, height: 512), at: 0, motionAmount: 0)
            full.unlockFocus()
            full.draw(in: NSRect(x: Double(column) * 240 + 66, y: 300, width: 108, height: 84), from: crop,
                      operation: .sourceOver, fraction: 1)
            let title = (column % 2 == 0 ? "Before" : "After") + " · " + pose.title
            (title as NSString).draw(at: NSPoint(x: Double(column) * 240 + 24, y: 412),
                withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                 .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)])
        }
        return bitmap
    }

}
