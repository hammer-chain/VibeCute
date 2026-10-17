import AppKit

final class DeepSeekStroll {
    static let shared = DeepSeekStroll()
    let frames: [NSImage]
    let launchFrames: [NSImage]
    var available: Bool { frames.count == 24 && launchFrames.count == 4 && DeepSeekFrontRetreat.shared.available }
    private init() {
        frames = (0..<24).compactMap { index in
            let folder = "DeepSeekThinking/Stroll", name = String(format: "frame-%02d", index)
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder)
                ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder)
            return url.flatMap { NSImage(contentsOf: $0) }
        }
        launchFrames = (0..<4).compactMap { index in
            let name=String(format:"frame-%02d",index),folder="DeepSeekThinking/Stroll/Launch"
            return (Bundle.main.url(forResource:name,withExtension:"png",subdirectory:folder)
                ?? Bundle.module.url(forResource:name,withExtension:"png",subdirectory:folder)).flatMap { NSImage(contentsOf:$0) }
        }
    }
    func draw(_ sample: StrollTimeline.Sample, animation: MascotAnimation, in rect: NSRect,
              fromScootRest: Bool = false,entryImage: NSImage? = nil,entryRect: NSRect? = nil) {
        guard available else { return }
        if let launch=sample.launchFrame, launchFrames.indices.contains(launch) {
            launchFrames[launch].draw(in:rect); return
        }
        if let transition = sample.transitionFrame {
            DeepSeekFrontRetreat.shared.draw(.init(frame:nil,transitionFrame:transition,offset:0,phase:.rising),
                animation:animation,in:rect,fromScootRest:fromScootRest)
            return
        }
        if let frame = sample.frame, frames.indices.contains(frame) {
            // The regenerated v4 sprites already include alternating arm motion.
            frames[frame].draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
        } else if let entryImage, let entryRect {
            entryImage.draw(in:entryRect,from:.zero,operation:.sourceOver,fraction:1)
        } else if fromScootRest {
            DeepSeekFrontRetreat.shared.draw(.init(frame:nil,transitionFrame:3,offset:0,phase:.finished),animation:animation,in:rect)
        } else {
            let original = NSRect(x: rect.midX-rect.width*384/448/2, y: rect.minY,
                                  width: rect.width*384/448, height: rect.height*512/640)
            animation.frames[0].draw(in: original, from: .zero, operation: .sourceOver,
                                     fraction:1)
        }
    }
}
