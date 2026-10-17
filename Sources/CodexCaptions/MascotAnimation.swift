import AppKit
import CaptionCore

enum CaptionMascot: String, CaseIterable {
    // Legacy type also keys source-owned windows. OpenCode selects existing
    // artwork through CharacterChoice, with its own position and caption lane.
    case codex, deepseek, claude, doubao, opencode, workbuddy, companion
    case deepseekCutout = "deepseek-cutout"
    case orangeHoodie = "blue-fish-orange-hoodie"
    var directory: String {
        if self == .orangeHoodie { return "OrangeHoodieThinking" }
        return self == .deepseek ? "DeepSeekThinking" : "CodexThinking"
    }
}

/// Artwork selection does not change the log source, captions, or saved position.
enum CharacterChoice: String, CaseIterable, Identifiable {
    case codex, deepseek, pinkBear
    case deepseekCutout = "deepseek-cutout"
    case orangeHoodie = "blue-fish-orange-hoodie"
    // Retired: keep the raw value only for reading existing preferences.
    static let includesPinkBear = false
    static let defaultChoice: Self = .deepseek
    static var available: [Self] { selectable(developerMode: false) }
    static func selectable(developerMode: Bool) -> [Self] {
        [.deepseek, .orangeHoodie, .codex, .deepseekCutout].filter { $0.isSelectable(developerMode: developerMode) }
    }
    func isSelectable(developerMode: Bool) -> Bool {
        (self != .pinkBear || Self.includesPinkBear) && (self != .deepseekCutout || (developerMode && BuildProfile.experiments))
    }
    static func resolved(_ rawValue: String?, developerMode: Bool) -> Self {
        guard let rawValue, let choice = Self(rawValue: rawValue), choice.isSelectable(developerMode: developerMode) else {
            return defaultChoice
        }
        return choice
    }
    static var cutoutDefaultHair: String {
        #if VIBECUTE_RELEASE
        return ""
        #else
        return MascotAnimation.cutoutCharacter.cutout!.defaults["hair"]!
        #endif
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "ChatGPT龙娘 （试验版）"
        case .deepseek: return "蓝色大肥鱼"
        case .orangeHoodie: return "蓝色大肥鱼 · Claude Code工服（试验版）"
        case .deepseekCutout:
            #if VIBECUTE_RELEASE
            return "CutOut（未包含）"
            #else
            return MascotAnimation.cutoutCharacter.displayName
            #endif
        case .pinkBear: return "粉色小熊"
        }
    }
    var mascot: CaptionMascot {
        switch self {
        case .deepseek: return .deepseek
        case .orangeHoodie: return .orangeHoodie
        case .deepseekCutout: return .deepseekCutout
        default: return .codex
        }
    }
}

/// Source coordinates are the original 384 × 512 seated sprite, y up.
/// No audio state enters this controller.
struct SeatedGaze {
    private(set) var position = NSPoint.zero
    static let eyeCenter = NSPoint(x: 174, y: 308)

    static func target(cursor: NSPoint, in rect: NSRect, transform: CGAffineTransform = .identity,
                       eyeCenter: NSPoint = Self.eyeCenter) -> NSPoint {
        guard rect.width > 0, rect.height > 0, cursor.x.isFinite, cursor.y.isFinite else { return .zero }
        let local = cursor.applying(transform.inverted())
        let x = ((local.x - rect.minX) * 384 / rect.width - eyeCenter.x) / 190
        let y = ((local.y - rect.minY) * 512 / rect.height - eyeCenter.y) / 145
        let radius = hypot(x, y), deadZone: CGFloat = 0.035
        guard radius > deadZone else { return .zero }
        let amount = (min(1, radius) - deadZone) / (1 - deadZone)
        return NSPoint(x: x / radius * amount, y: y / radius * amount)
    }

    mutating func update(target: NSPoint, dt: TimeInterval, returning: Bool = false) {
        guard dt.isFinite, dt >= 0, target.x.isFinite, target.y.isFinite else { return }
        let radius = max(1, hypot(target.x, target.y))
        let k = CGFloat(1 - exp(-dt / (returning ? 0.18 : 0.095)))
        position.x += (target.x / radius - position.x) * k
        position.y += (target.y / radius - position.y) * k
    }
}

private final class SeatedGazeArtwork {
    private var pupils: [NSImage] = []
    // A neutral, opaque field cannot reintroduce the source eye outline or
    // leave the old iris visible when a pose has a larger eye opening.
    private let whiteGradient = NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.76, green: 0.76, blue: 0.76, alpha: 1), 0),
        (NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), 0.35),
        (NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), 1))!
    private lazy var apertures = [aperture(false), aperture(true)]
    var available: Bool { pupils.count == 2 }

    init(reference: NSImage?) {
        func load(_ name: String) -> CGImage? {
            let folder = "DeepSeekThinking/Gaze"
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder)
                ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder)
            return url.flatMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        }
        let sourceRect = CGRect(x: 32, y: 112, width: 384, height: 512)
        guard let reference = reference?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        for name in ["pupil-left-mask", "pupil-right-mask"] {
            guard let mask = load(name)?.cropping(to: sourceRect),
                  let context = CGContext(data: nil, width: 384, height: 512, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            let rect = CGRect(x: 0, y: 0, width: 384, height: 512)
            context.draw(reference, in: rect)
            context.setBlendMode(.destinationIn)
            context.draw(mask, in: rect)
            if let image = context.makeImage() {
                // Recover the original lossless blue iris, using only the supplied alpha.
                pupils.append(NSImage(cgImage: image, size: rect.size))
            }
        }
    }

    private func aperture(_ right: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: 512 - y) }
        if !right {
            path.move(to: p(119, 199))
            path.curve(to: p(138, 184.9), controlPoint1: p(120, 190), controlPoint2: p(128, 184.9))
            path.curve(to: p(154, 199), controlPoint1: p(147, 184.9), controlPoint2: p(153.5, 190.1))
            path.curve(to: p(139, 217.7), controlPoint1: p(154.5, 210.2), controlPoint2: p(149.2, 217.7))
            path.curve(to: p(119, 199), controlPoint1: p(128, 217.7), controlPoint2: p(121.8, 212.7))
        } else {
            path.move(to: p(194, 209))
            path.curve(to: p(205.8, 192), controlPoint1: p(194, 201), controlPoint2: p(197.8, 194.5))
            path.curve(to: p(233, 204), controlPoint1: p(217, 190.4), controlPoint2: p(226.5, 195.4))
            path.curve(to: p(223, 222.1), controlPoint1: p(236, 211.9), controlPoint2: p(230, 218.8))
            path.curve(to: p(196.5, 219.3), controlPoint1: p(214, 226.7), controlPoint2: p(201, 226.3))
            path.curve(to: p(194, 209), controlPoint1: p(195, 216), controlPoint2: p(194, 212))
        }
        path.close(); return path
    }

    func draw(gaze: NSPoint, in rect: NSRect) {
        guard available else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 384, y: rect.height / 512)
        let source = NSRect(x: 0, y: 0, width: 384, height: 512)
        let radius = max(1, hypot(gaze.x, gaze.y))
        for i in 0..<2 {
            NSGraphicsContext.saveGraphicsState()
            apertures[i].addClip()
            drawWhites(in: apertures[i])
            pupils[i].draw(in: source.offsetBy(dx: gaze.x / radius * 4.4, dy: gaze.y / radius * 3.2),
                           from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func drawWhites(in aperture: NSBezierPath) {
        // The caller clips once; clipping the gradient to the same path again
        // would compound edge antialiasing and expose the old iris underneath.
        whiteGradient.draw(in: aperture.bounds, angle: -90)
    }

    func drawPupil(_ index: Int, offset: NSPoint) {
        pupils[index].draw(in: NSRect(x: offset.x, y: offset.y, width: 384, height: 512),
                           from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// Finite per-pose eye paths prepared once from the character registration. Runtime
/// retains the complete pose and replaces only its actual visible eye openings.
private final class ThinkingGazeArtwork {
    struct Eye {
        let registration: ThinkingGazeRegistration.Eye
        let aperture: NSBezierPath
    }
    let definition: ThinkingGazeRegistration
    private let pupils: SeatedGazeArtwork
    private let frames: [[Eye]]

    init?(definition: ThinkingGazeRegistration, poses: [NSImage], pupils: SeatedGazeArtwork) {
        guard definition.drawable, poses.count == definition.frames.count, pupils.available else { return nil }
        self.definition = definition; self.pupils = pupils
        frames = definition.frames.map { eyes in eyes.map { registration in
            let path = NSBezierPath(), points = registration.aperture
            func p(_ row: [Double], _ i: Int) -> NSPoint { NSPoint(x: row[i], y: 512-row[i+1]) }
            path.move(to: p(points[0],0))
            for row in points.dropFirst() {
                path.curve(to:p(row,4),controlPoint1:p(row,0),controlPoint2:p(row,2))
            }
            path.close()
            return Eye(registration: registration, aperture: path)
        } }
    }

    func draw(frame: Int, gaze: NSPoint, in rect: NSRect, pupilsVisible: Bool = true) {
        guard frames.indices.contains(frame) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width/384, y: rect.height/512)
        let radius = max(1, hypot(gaze.x,gaze.y))
        for (side, eye) in frames[frame].enumerated() {
            NSGraphicsContext.saveGraphicsState()
            eye.aperture.addClip()
            pupils.drawWhites(in: eye.aperture)
            let e = eye.registration, angle = e.rotationDegrees * .pi/180
            context.translateBy(x: e.irisCenter[0], y: 512-e.irisCenter[1])
            context.rotate(by: -angle)
            context.scaleBy(x: e.irisScale[0], y: e.irisScale[1])
            let reference = definition.referenceCenters[side]
            context.translateBy(x: -reference[0], y: -(512-reference[1]))
            let local = NSPoint(x: (cos(angle)*gaze.x-sin(angle)*gaze.y)/radius,
                                y: (sin(angle)*gaze.x+cos(angle)*gaze.y)/radius)
            if pupilsVisible {
                pupils.drawPupil(side, offset: NSPoint(x:local.x*definition.maximumOffset[0],y:local.y*definition.maximumOffset[1]))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Artwork is selectable independently of the session source and its position.
enum PinkBearBinding: String, CaseIterable, Identifiable {
    case disabled, codex, deepseek
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: return "不绑定 · 使用原有角色"
        case .codex: return "Codex"
        case .deepseek: return "DeepSeek Harness"
        }
    }
    var source: CaptionMascot? { CaptionMascot(rawValue: rawValue) }
}

/// Each image-tool atlas is decoded and cropped only once.
final class MascotAnimation {
    #if !VIBECUTE_RELEASE
    static let cutoutCharacter: CutoutCharacter = {
        do { return try CutoutCharacter.bundled() }
        catch { preconditionFailure("Invalid cutout runtime configuration: \(error)") }
    }()
    #endif
    static let thinkingGazeRegistration: ThinkingGazeRegistration? = {
        let url = Bundle.main.url(forResource: "thinking-gaze", withExtension: "json", subdirectory: "DeepSeekThinking")
            ?? Bundle.module.url(forResource: "thinking-gaze", withExtension: "json", subdirectory: "DeepSeekThinking")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThinkingGazeRegistration.self, from: data)
    }()
    static let orangeHoodie = MascotAnimation(character: .orangeHoodie)
    static let pinkBear = MascotAnimation(character: .codex, pinkBear: true)
    let isPinkBear: Bool
    var playbackSequence: [Int] { isPinkBear
        ? [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 3, 3, 4, 5, 5, 5, 6, 6, 7, 7, 7, 7]
        : Self.sequence }
    static let mouthCount = 12
    static let library: [CaptionMascot: MascotAnimation] = [
        .codex: MascotAnimation(character: .codex), .deepseek: MascotAnimation(character: .deepseek)
    ]
    let frames: [NSImage]
    private(set) var thinkingFrames: [NSImage] = []
    let mouths: [NSImage]
    let mouthRect: NSRect
    var supportsSeatedGaze: Bool { (character == .deepseek || character == .orangeHoodie) && !isPinkBear }
    private lazy var gazeRegistration: ThinkingGazeRegistration? = {
        if character == .deepseek { return Self.thinkingGazeRegistration }
        let url = Bundle.main.url(forResource: "thinking-gaze", withExtension: "json", subdirectory: character.directory)
            ?? Bundle.module.url(forResource: "thinking-gaze", withExtension: "json", subdirectory: character.directory)
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThinkingGazeRegistration.self, from: data)
    }()
    private lazy var gazeArtwork = supportsSeatedGaze
        ? SeatedGazeArtwork(reference: frames.first) : nil
    private lazy var thinkingGazeArtwork: ThinkingGazeArtwork? = {
        guard supportsSeatedGaze,
              let registration = gazeRegistration,
              let pupils = gazeArtwork else { return nil }
        return ThinkingGazeArtwork(definition: registration, poses: thinkingFrames, pupils: pupils)
    }()
    private let character: CaptionMascot
    // Hold the open-eyed pose, then blink briefly rather than blinking every second.
    static let sequence = [0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 4, 5, 6, 6, 7, 7, 7, 7]

    func thinkingEyeCenter(frame: Int) -> NSPoint {
        guard let gaze = gazeRegistration,
              gaze.frames.indices.contains(frame), gaze.frames[frame].count == 2 else { return SeatedGaze.eyeCenter }
        let eyes = gaze.frames[frame]
        return NSPoint(x: (eyes[0].irisCenter[0]+eyes[1].irisCenter[0])/2,
                       y: 512-(eyes[0].irisCenter[1]+eyes[1].irisCenter[1])/2)
    }

    init(character: CaptionMascot, pinkBear: Bool = false) {
        self.character = character
        isPinkBear = pinkBear
        let directory = pinkBear ? "PinkBearThinking" : character.directory
        // Image-tool mouth tiles are composited onto the original seated sprite,
        // preserving the body artwork, wings and whale tail before motion.
        // Imagegen returned 1254-square atlases. The crop anchors below refer
        // to those original pixels; body tiles are never used by the renderer.
        let mouthSource = character == .codex ? CGRect(x: 133, y: 184, width: 26, height: 24)
            : CGRect(x: 135, y: 173, width: 30, height: 26)
        let targetTop = character == .codex ? CGPoint(x: 156, y: 232) : CGPoint(x: 157, y: 222)
        let mouthSize = NSSize(width: character == .codex ? 29 : 31, height: 25)
        mouthRect = NSRect(x: targetTop.x, y: 512 - targetTop.y - 25,
                           width: mouthSize.width, height: mouthSize.height)
        // Shared face-only crops never include clothing or the headband.
        let lipDirectory = character == .orangeHoodie ? "DeepSeekThinking" : directory
        let lipURL = Bundle.main.url(forResource: "speaking-v2-atlas", withExtension: "png", subdirectory: lipDirectory)
            ?? Bundle.module.url(forResource: "speaking-v2-atlas", withExtension: "png", subdirectory: lipDirectory)
        if let lipURL, let source = NSImage(contentsOf: lipURL),
           let atlas = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
           atlas.width == 1254, atlas.height == 1254 {
            mouths = (0..<Self.mouthCount).compactMap { index in
                guard let crop = atlas.cropping(to: mouthSource.offsetBy(dx: (CGFloat(index % 4) * 313.5).rounded(),
                    dy: CGFloat(index / 4) * 418)) else { return nil }
                return NSImage(cgImage: crop, size: mouthSize)
            }
        } else { mouths = [] }
        let url = Bundle.main.url(forResource: "thinking-atlas", withExtension: "png",
                                  subdirectory: directory)
            ?? Bundle.module.url(forResource: "thinking-atlas", withExtension: "png",
                                 subdirectory: directory)
        guard let url, let source = NSImage(contentsOf: url),
              let atlas = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              atlas.width % 4 == 0, atlas.height % 2 == 0 else {
            frames = []; return
        }
        let width = atlas.width / 4, height = atlas.height / 2
        let candidates = (0..<8).compactMap { index -> NSImage? in
            guard let frame = atlas.cropping(to: CGRect(x: (index % 4) * width,
                y: (index / 4) * height, width: width, height: height)) else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: width, height: height))
        }
        frames = candidates
        if supportsSeatedGaze {
            thinkingFrames = candidates
            _ = thinkingGazeArtwork
        }
    }

    /// A slow breath and a smaller weight shift, anchored at the seated floor.
    /// One transform keeps the artwork and its mouth aligned.
    func seatedTransform(in rect: NSRect, at time: TimeInterval, amount: CGFloat = 1) -> CGAffineTransform {
        let period = character == .codex ? 3.8 : 4.3
        let phase = character == .codex ? 0.0 : 1.3
        let breath = CGFloat(sin(time * 2 * .pi / period + phase)) * amount
        let sway = CGFloat(sin(time * 2 * .pi / (period * 2.1) + phase + 0.7)) * amount
        let sx = 1 + 0.0045 * breath, sy = 1 + 0.0200 * breath
        let shear = 0.0080 * sway
        return CGAffineTransform(a: sx, b: 0, c: shear, d: sy,
            tx: rect.midX * (1 - sx) - rect.minY * shear, ty: rect.minY * (1 - sy))
    }

    func drawSeated(frame: Int = 0, mouth: Int?, in rect: NSRect,
                    at time: TimeInterval, motionAmount: CGFloat = 1, gaze: NSPoint? = nil,
                    thinking: Bool = false, gazePupilsVisible: Bool = true) {
        guard frames.indices.contains(frame) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.concatenate(seatedTransform(in: rect, at: time, amount: motionAmount))
        if thinking, mouth == nil, thinkingFrames.indices.contains(frame) {
            thinkingFrames[frame].draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            if let gaze { thinkingGazeArtwork?.draw(frame: frame, gaze: gaze, in: rect, pupilsVisible: gazePupilsVisible) }
            return
        }
        if let gaze, frame != 3, frame != 4, let artwork = gazeArtwork, artwork.available {
            // A single confirmed body; only the eye layers blink or look around.
            frames[0].draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            artwork.draw(gaze: gaze, in: rect)
        } else {
            // A blink replaces the complete cached eye regions. Clipping it
            // to the open-eye aperture leaves the old iris/lash around its edge.
            frames[frame].draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        if let mouth { drawMouth(mouth, in: rect) }
    }

    func drawMouth(_ index: Int, in characterRect: NSRect, anchor: NSRect? = nil) {
        guard index > 0, mouths.indices.contains(index) else { return }
        let anchor = anchor ?? mouthRect
        let scale = characterRect.height / 512
        let rect = NSRect(x: characterRect.minX + anchor.minX * scale,
                          y: characterRect.minY + anchor.minY * scale,
                          width: anchor.width * scale, height: anchor.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        mouths[index].draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}
