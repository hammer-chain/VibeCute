import AppKit

/// One complete, explicitly requested preview. All sampling is constant-time;
/// callers reuse the existing UI refresh clock, quantized to the 160 ms art tick.
enum DeepSeekSleepTimeline {
    static let tick = 0.16
    static let wakeSequence = [0, 1, 2, 3, 4, 8, 9, 10, 9, 10, 11, 5, 6, 7]
    static let tickCount = 44 + wakeSequence.count*2 + 4
    static let duration = Double(tickCount)*tick
    struct Sample: Equatable {
        let phase: String
        let waking: Bool
        let frame: Int
        let sleepTick: Int?
    }
    static func sample(at elapsed: TimeInterval, continuous: Bool = false) -> Sample? {
        if continuous, elapsed.isFinite, elapsed >= 3.2 {
            return sample(at: 3.2 + (elapsed - 3.2).truncatingRemainder(dividingBy: 3.84))
        }
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        let step = Int((elapsed / tick).rounded(.down))
        if step < 4 { return Sample(phase: "坐姿思考", waking: false, frame: 0, sleepTick: nil) }
        if step < 20 { return Sample(phase: "慢慢趴下", waking: false, frame: (step-4)/2, sleepTick: nil) }
        if step < 44 { return Sample(phase: "趴着睡觉", waking: false, frame: 7, sleepTick: step-20) }
        if step < tickCount-4 {
            let frame = wakeSequence[(step-44)/2]
            return Sample(phase: frame >= 8 ? "揉揉眼睛" : "醒来坐好", waking: true, frame: frame, sleepTick: nil)
        }
        return Sample(phase: "恢复坐姿", waking: true, frame: 7, sleepTick: nil)
    }
}

final class DeepSeekSleepArtwork {
    static let shared = DeepSeekSleepArtwork()
    let entry: [NSImage]
    let wake: [NSImage]
    let loadSeconds: Double
    let decodedBytes: Int
    var available: Bool { entry.count == 8 && wake.count == 12 }
    private static let letters: [NSAttributedString] = zip(["z", "z", "Z"], [25.0, 32.0, 40.0]).map { text, size in
        NSAttributedString(string: text, attributes: [
            .font: NSFont.roundedSleepFont(size),
            .foregroundColor: NSColor(calibratedRed: 0.35, green: 0.67, blue: 1, alpha: 1),
            .strokeColor: NSColor.white.withAlphaComponent(0.95), .strokeWidth: -3])
    }
    init(directory: URL? = nil) {
        let start = ProcessInfo.processInfo.systemUptime
        func load(_ prefix: String, count: Int = 8) -> [NSImage] {
            (0..<count).compactMap { i in
                let name = String(format: "\(prefix)-%02d", i)
                let url = directory?.appendingPathComponent(name+".png")
                    ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "DeepSeekThinking/Sleep")
                    ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "DeepSeekThinking/Sleep")
                guard let url, let image = NSImage(contentsOf: url),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      cg.width == 384, cg.height == 512,
                      let c = CGContext(data: nil, width: 384, height: 512, bitsPerComponent: 8,
                        bytesPerRow: 384*4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                // Eagerly decode once, never during animation sampling/drawing.
                c.draw(cg, in: CGRect(x: 0, y: 0, width: 384, height: 512))
                return c.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: 384, height: 512)) }
            }
        }
        entry = load("entry"); wake = load("wake") + load("rub", count: 4)
        decodedBytes = (entry.count+wake.count)*384*512*4
        loadSeconds = ProcessInfo.processInfo.systemUptime-start
    }
    func image(for sample: DeepSeekSleepTimeline.Sample) -> NSImage? {
        let frames = sample.waking ? wake : entry
        return frames.indices.contains(sample.frame) ? frames[sample.frame] : nil
    }
    func draw(_ sample: DeepSeekSleepTimeline.Sample, in rect: NSRect) {
        // Whole-pose registration around the common floor, not facial/body
        // compositing. The generated wake sheet became smaller as it sat up.
        let wakeScale: [CGFloat] = [1, 1.015, 1.035, 1.055, 1.075, 1.095, 475.0/427.0, 1, 1.075, 1.075, 1.075, 1.075]
        let scale = sample.waking ? wakeScale[sample.frame] : 1
        let floor = rect.minY + rect.height * 18/512
        let registered = NSRect(x: rect.midX-rect.width*scale/2,
            y: floor+(rect.minY-floor)*scale, width: rect.width*scale, height: rect.height*scale)
        image(for: sample)?.draw(in: registered, from: .zero, operation: .sourceOver, fraction: 1)
        guard let tick = sample.sleepTick, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width/384, y: rect.height/512)
        // Three staggered glyphs grow along the path above the head. Text is
        // cached; sleep time is quantized, and waking never draws this layer.
        for i in 0..<3 {
            let p = Double((tick + i*4)%18)/18
            let alpha = min(1, p*6) * min(1, (1-p)*4)
            context.saveGState(); context.setAlpha(alpha)
            Self.letters[i].draw(at: NSPoint(x: 170+Double(i)*24+p*24, y: 235+Double(i)*28+p*60))
            context.restoreGState()
        }
    }
}
private extension NSFont {
    static func roundedSleepFont(_ size: Double) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        return font.fontDescriptor.withDesign(.rounded).map { NSFont(descriptor: $0, size: size)! } ?? font
    }
}
