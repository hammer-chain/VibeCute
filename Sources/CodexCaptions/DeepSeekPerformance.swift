import AppKit
import CaptionCore

/// Image-tool artwork is normalized once into a common floor-anchored canvas.
/// The body and its moving mouth anchor always come from the same frame.
final class DeepSeekPerformance {
    static let shared = DeepSeekPerformance()
    struct MouthAnchor: Decodable { let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat }
    private(set) var frames: [NSImage] = []
    private var anchors: [MouthAnchor] = []
    var available: Bool { frames.count >= 24 && anchors.count >= 24 }
    var kiraAvailable: Bool { BuildProfile.experiments && frames.count >= 32 }
    static let singingStepStart = BuildProfile.isRelease ? 24 : 32
    var singingStepAvailable: Bool { frames.count == Self.singingStepStart + 8 && anchors.count == Self.singingStepStart + 8 }
    private init() {
        let folder = "DeepSeekThinking/Performance"
        let url = Bundle.main.url(forResource: "mouth-anchors", withExtension: "json", subdirectory: folder)
            ?? Bundle.module.url(forResource: "mouth-anchors", withExtension: "json", subdirectory: folder)
        guard let url, let data = try? Data(contentsOf: url),
              let anchors = try? JSONDecoder().decode([MouthAnchor].self, from: data) else { return }
        self.anchors = anchors
        frames = (0..<24).compactMap { index in
            let name = String(format: "frame-%02d", index)
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder)
                ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder)
            return url.flatMap { NSImage(contentsOf: $0) }
        }
        #if !VIBECUTE_RELEASE
        if frames.count == 24 {
            let kira = (0..<8).compactMap { index -> NSImage? in
                let name = String(format: "frame-%02d", index)
                let folder = "DeepSeekThinking/Kira"
                let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder)
                    ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder)
                return url.flatMap { NSImage(contentsOf: $0) }
            }
            if kira.count == 8 { frames.append(contentsOf: kira) }
        }
        #endif
        let stepFolder = "DeepSeekThinking/SingingStep"
        let stepURL = Bundle.main.url(forResource:"mouth-anchors",withExtension:"json",subdirectory:stepFolder)
            ?? Bundle.module.url(forResource:"mouth-anchors",withExtension:"json",subdirectory:stepFolder)
        if frames.count == Self.singingStepStart, let stepURL, let data = try? Data(contentsOf:stepURL),
           let stepAnchors = try? JSONDecoder().decode([MouthAnchor].self,from:data), stepAnchors.count == 8 {
            let steps = (0..<8).compactMap { index -> NSImage? in
                let name = String(format:"frame-%02d",index)
                let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:stepFolder)
                    ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:stepFolder)
                return url.flatMap { NSImage(contentsOf:$0) }
            }
            if steps.count == 8 {
                frames.append(contentsOf:steps)
                #if !VIBECUTE_RELEASE
                self.anchors.append(contentsOf:Array(repeating:anchors[16],count:8)) // Kira owns its expression.
                #endif
                self.anchors.append(contentsOf:stepAnchors)
            }
        }
    }
    func draw(frame index: Int, mouth: Int?, animation: MascotAnimation, in rect: NSRect) {
        guard available, frames.indices.contains(index) else { return }
        if index == 0 {
            let original = NSRect(x: rect.midX - rect.width * 384 / 448 / 2, y: rect.minY,
                                  width: rect.width * 384 / 448, height: rect.height * 512 / 640)
            animation.frames[0].draw(in: original, from: .zero, operation: .sourceOver, fraction: 1)
            if let mouth { animation.drawMouth(mouth, in: original) }
            return
        }
        frames[index].draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        // The one-shot pose includes its own expression, including the wink.
        // Do not paint the live mouth over the hand, mic or smiling expression.
        guard index < 24 || index >= Self.singingStepStart else { return }
        guard let mouth, animation.mouths.indices.contains(mouth), mouth > 0 else { return }
        let anchor = anchors[index], scale = rect.height / 640
        let patch = NSRect(x: rect.minX + anchor.x * scale, y: rect.minY + anchor.y * scale,
                           width: anchor.width * scale, height: anchor.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: patch).addClip()
        animation.mouths[mouth].draw(in: patch, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}
