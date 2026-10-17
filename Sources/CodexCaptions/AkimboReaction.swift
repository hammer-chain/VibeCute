import AppKit
import ImageIO

/// Counts completed, accepted gestures, rather than pointer direction changes.
struct HeadPatStreak {
    private(set) var count = 0
    private var lastTime: TimeInterval?
    static let maximumGap: TimeInterval = 8
    mutating func reset() { count = 0; lastTime = nil }
    mutating func record(at time: TimeInterval) -> Bool {
        guard time.isFinite else { reset(); return false }
        if let lastTime, time < lastTime || time-lastTime > Self.maximumGap { count = 0 }
        lastTime = time; count += 1
        if count == 3 { reset(); return true }
        return false
    }
}

enum AkimboReaction {
    static let step: TimeInterval = 0.15
    static let armTransition = step * 14
    static let winkStep: TimeInterval = 0.12
    static let winkClosedHold: TimeInterval = 0.6
    static let transition = armTransition
    static let winkDuration = winkStep * 8 + winkClosedHold
    static let winkFrames = 17...18
    // Skip the wink poses when returning, so the entire reaction winks once.
    static let returnTransition = step * 14
    static let hold: TimeInterval = 12
    static let duration = transition + hold + winkDuration + returnTransition
    static let utterances = ["难不成你其实很喜欢我", "唉，大大方方直说吧", "都怪我是个可爱的小肥鱼，\n太有魅力了"]
    static let dialogue = utterances.joined(separator: "\n")
    // Includes the first line, explicit newline, and the first “太” glyph.
    static let winkCueCharacterCount = utterances[2].prefix { $0 != "\n" }.count + 2
    static let utterancePause: TimeInterval = 2
    static let utterancePauseRange = 0.0...3.0
    static func boundedUtterancePause(_ value: Double) -> Double {
        value.isFinite ? min(utterancePauseRange.upperBound, max(utterancePauseRange.lowerBound, value)) : utterancePause
    }
    static func frame(at elapsed: TimeInterval, winkElapsed: TimeInterval? = nil) -> Int? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        if elapsed < armTransition { return min(13, Int(elapsed / step)) }
        let returnStart = duration-returnTransition
        if elapsed >= returnStart { return max(0, 13-Int((elapsed-returnStart)/step)) }
        if let winkElapsed, winkElapsed >= 0, winkElapsed < winkDuration {
            if winkElapsed < winkStep*4 { return 14 + Int(winkElapsed/winkStep) }
            if winkElapsed < winkStep*5+winkClosedHold { return 18 }
            return 14 + min(7, Int((winkElapsed-winkClosedHold)/winkStep))
        }
        return 13
    }
}

/// Prepared once for these three fixed utterances, never during animation ticks.
/// Text-based vowel shapes are approximate Mandarin visemes, not audio timing.
enum AkimboSpeech {
    static let targets: [[Int?]] = AkimboReaction.utterances.map { $0.map(shape) }
    static func shape(_ character: Character) -> Int? {
        guard character.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        let latin = String(character).applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? ""
        switch latin.last(where: { "aeiou".contains($0) }) {
        case "a": return 2
        case "e": return 3
        case "i": return 4
        case "o": return 5
        case "u": return 6
        default: return 10
        }
    }
}

/// One current target; obsolete characters are replaced rather than queued.
struct AkimboSpeechPlayer {
    private(set) var mouth: Int?
    private var target: Int?
    private var changedAt = -Double.infinity
    static let minimumHold: TimeInterval = 0.14
    mutating func reset() { mouth = nil; target = nil; changedAt = -.infinity }
    mutating func observe(utterance: Int, revealed: Int, typing: Bool) {
        guard typing, AkimboSpeech.targets.indices.contains(utterance), revealed > 0,
              AkimboSpeech.targets[utterance].indices.contains(revealed-1) else { target = nil; return }
        target = AkimboSpeech.targets[utterance][revealed-1]
    }
    mutating func advance(at now: TimeInterval) {
        guard now.isFinite, now-changedAt >= Self.minimumHold, mouth != target else { return }
        // One small opening bridges onset and release; no endless talking loop.
        if mouth == nil && target != nil { mouth = 10 }
        else if target == nil && mouth != nil && mouth != 10 { mouth = 10 }
        else { mouth = target }
        changedAt = now
    }
}

/// One shared, bounded decoded atlas. First use loads twenty-two complete poses;
/// every tick thereafter only selects a prepared image.
final class AkimboArtwork {
    static let shared = AkimboArtwork()
    let frames: [NSImage]
    let loadSeconds: TimeInterval
    let decodedBytes: Int
    private init() {
        let start = ProcessInfo.processInfo.systemUptime
        let folder = "DeepSeekThinking/Akimbo"
        func decode(_ name: String) -> [NSImage] {
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder)
                ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder)
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  atlas.width == 1536, atlas.height == 1024 else { return [] }
            return (0..<8).compactMap { i in
                guard let crop = atlas.cropping(to: CGRect(x: i%4*384, y: i/4*512, width: 384, height: 512)),
                      let context = CGContext(data: nil, width: 384, height: 512, bitsPerComponent: 8,
                        bytesPerRow: 384*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 384, height: 512))
                return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: 384, height: 512)) }
            }
        }
        let original = decode("transition-atlas"), between = decode("inbetween-atlas")
        let wink = decode("wink-tilt-atlas")
        if original.count == 8 && between.count == 8 && wink.count == 8 {
            frames = [original[0], between[0], between[1], between[2], original[1],
                      between[3], between[4], between[5], original[2], between[6], between[7],
                      original[3], original[4], original[5]] + wink
        } else { frames = [] }
        decodedBytes = frames.count * 384*512*4
        loadSeconds = ProcessInfo.processInfo.systemUptime-start
    }
    var available: Bool { frames.count == 22 }
    static func drawingRect(in seated: NSRect) -> NSRect {
        // The new complete poses occupy more of their canvas. A uniform
        // drawing scale and floor offset align their seated feet/head with
        // the current thinking artwork, without replacing any body pixels.
        let factor: CGFloat = 0.94
        return NSRect(x: seated.midX-seated.width*factor/2,
            y: seated.minY+seated.height*11.4/512,
            width: seated.width*factor, height: seated.height*factor)
    }
    // Drawing coordinates in each actual 384×512 pose, top-origin pixels.
    // Wink anchors include the head's inclination; eyes/body are never replaced.
    struct MouthAnchor { let x: CGFloat, y: CGFloat, degrees: CGFloat }
    static let mouthAnchors: [MouthAnchor] = [
        .init(x:167,y:237,degrees:0), .init(x:174,y:237,degrees:0),
        .init(x:181,y:238,degrees:0), .init(x:178,y:238,degrees:0),
        .init(x:179,y:239,degrees:0), .init(x:177,y:238,degrees:0),
        .init(x:176,y:240,degrees:0), .init(x:177,y:239,degrees:0),
        .init(x:175,y:238,degrees:0), .init(x:176,y:240,degrees:0),
        .init(x:177,y:240,degrees:0), .init(x:175,y:238,degrees:0),
        .init(x:177,y:239,degrees:0), .init(x:177,y:238,degrees:0),
        .init(x:177,y:236,degrees:0), .init(x:193,y:232,degrees:6),
        .init(x:197,y:232,degrees:10), .init(x:196,y:231,degrees:12),
        .init(x:193,y:230,degrees:12), .init(x:194,y:231,degrees:10),
        .init(x:178,y:239,degrees:6), .init(x:168,y:238,degrees:0)
    ]
    func draw(frame: Int, in rect: NSRect, mouth: Int? = nil, animation: MascotAnimation? = nil) {
        guard frames.indices.contains(frame) else { return }
        let drawing = Self.drawingRect(in: rect)
        frames[frame].draw(in: drawing, from: .zero, operation: .sourceOver, fraction: 1)
        guard let mouth, let animation, mouth > 0, animation.mouths.indices.contains(mouth) else { return }
        let anchor = Self.mouthAnchors[frame], scale = drawing.height/512
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: drawing.minX+anchor.x*scale, y: drawing.minY+(512-anchor.y+6.5)*scale)
        context.rotate(by: anchor.degrees * .pi / 180)
        let patch = NSRect(x: -15.5*scale, y: -11*scale, width: 31*scale, height: 22*scale)
        NSBezierPath(ovalIn: patch).addClip()
        // Existing thinking-mouth tiles also include the top of a chin finger.
        // Crop that lower strip for this hands-on-waist pose. The crop's mouth
        // center offset is accounted for above; no hand/face frame is copied.
        let source = NSRect(x: 0, y: 5, width: 31, height: 20)
        animation.mouths[mouth].draw(in: patch, from: source, operation: .sourceOver, fraction: 1)
    }
}

/// One on-demand child window per reacting character. It never replaces a
/// session caption, takes focus, or intercepts input. Its typewriter uses
/// the same bounded timer as a normal subtitle and stops on completion/hide.
final class AkimboDialogue {
    let panel: NSPanel
    let view = SubtitleView()
    var onMouthProgress: ((Int, Int, Bool) -> Void)?
    private var lastAnchor: NSRect?
    private var showing = false
    private var currentUtterance: Int?
    private let measurement = SubtitleView()
    private var layoutArea = NSRect.zero
    private var singleLineSize = NSSize.zero
    private var fullHeight: CGFloat = 0
    private var expansionAfter: Int?
    private var expanded = false
    init(parent: NSWindow) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = parent.level; panel.collectionBehavior = parent.collectionBehavior
        view.mode = .bubble; view.context = ""; view.showsCaptionHeader = false; view.backdrop = 0.7
        panel.contentView = view; panel.setAccessibilityLabel(AkimboReaction.dialogue)
        view.onCaptionProgress = { [weak self] revealed, typing in
            guard let self, let utterance = self.currentUtterance else { return }
            if !self.expanded, let boundary = self.expansionAfter, revealed >= boundary {
                self.expanded = true
                self.layoutDialogue()
            }
            self.onMouthProgress?(utterance, revealed, typing)
        }
    }
    func hide() { view.pauseTypewriter(); panel.orderOut(nil); lastAnchor = nil; showing = false; currentUtterance = nil }
    static func placement(sprite: NSRect, area: NSRect, size: NSSize) -> (NSRect, Bool) {
        let right = area.maxX-sprite.maxX >= size.width+8 || sprite.minX-area.minX < size.width+8
        let x = right ? sprite.maxX+8 : sprite.minX-size.width-8
        return (NSRect(x: min(max(area.minX, x), area.maxX-size.width),
            y: min(max(area.minY, sprite.minY+sprite.height*0.69-size.height/2), area.maxY-size.height),
            width: size.width, height: size.height), right)
    }
    func show(parent: NSWindow, sprite: NSRect, scale: CGFloat, utterance: Int) {
        guard let area = parent.screen?.visibleFrame else { return }
        let anchor = NSRect(x: sprite.minX+parent.frame.minX, y: sprite.minY+parent.frame.minY,
            width: sprite.width, height: sprite.height)
        guard lastAnchor != anchor || !showing || currentUtterance != utterance else { return }
        lastAnchor = anchor
        view.layoutScale = min(1.15, max(0.85, scale))
        view.fontSize = 18*view.layoutScale
        let text = AkimboReaction.utterances[utterance]
        let firstLine = String(text.prefix { $0 != "\n" })
        let newUtterance = !showing || currentUtterance != utterance
        // Prepare both bounded sizes once per page/anchor change, before the
        // synchronous initial typewriter callback can request expansion.
        layoutArea = area
        measurement.mode = .bubble; measurement.context = view.context
        measurement.showsCaptionHeader = view.showsCaptionHeader
        measurement.layoutScale = view.layoutScale; measurement.fontSize = view.fontSize
        let width = min(area.width, 320*view.layoutScale)
        measurement.text = firstLine
        singleLineSize = NSSize(width: width, height: measurement.height(for: width))
        measurement.text = text
        fullHeight = measurement.height(for: width)
        expansionAfter = text.contains("\n") ? firstLine.count : nil
        if newUtterance { expanded = false }
        view.captionLayoutText = expanded ? text : firstLine
        if newUtterance {
            currentUtterance = utterance
            panel.setAccessibilityLabel(AkimboReaction.utterances[utterance])
            let speed = UserDefaults.standard.object(forKey: "typewriterCharactersPerSecond") as? Double ?? 25
            view.setCaption(AkimboReaction.utterances[utterance], typewriterID: UUID().uuidString, charactersPerSecond: speed)
        }
        layoutDialogue()
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        if !panel.isVisible { panel.order(.above, relativeTo: parent.windowNumber) }
        showing = true
    }
    private func layoutDialogue() {
        guard let anchor = lastAnchor, let utterance = currentUtterance else { return }
        let (initial, right) = Self.placement(sprite: anchor, area: layoutArea, size: singleLineSize)
        var frame = initial
        if expanded {
            view.captionLayoutText = AkimboReaction.utterances[utterance]
            frame.size.height = fullHeight
            // Grow downward so the already typed first line stays in place.
            frame.origin.y = max(layoutArea.minY, initial.maxY-fullHeight)
        }
        view.sideTailTarget = NSPoint(x: right ? -12 : frame.width+12, y: initial.midY-frame.minY)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: frame.size)
        }
        view.needsDisplay = true
    }
}
