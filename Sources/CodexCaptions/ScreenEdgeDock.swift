import AppKit
import ImageIO

/// Bounded process-lifetime cache. Tick and drawing perform no file access.
final class ScreenEdgeArtwork {
    static let shared = ScreenEdgeArtwork()
    static let edgeX: CGFloat = 344
    static let peekEdgeX: CGFloat = 362
    static let peekArtworkShiftX: CGFloat = 56
    static let peekAngle: CGFloat = 20 * .pi / 180
    static let canvasSize = NSSize(width: 384, height: 512)
    static let height: CGFloat = 168
    static let sequence = [0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 5, 5, 6, 6, 7, 7]
    let frames: [CGImage]
    let transitions: [CGImage]
    private init() {
        func load(_ prefix: String) -> [CGImage] {
            (0..<8).compactMap { frame in
                let name = String(format: "\(prefix)-%02d", frame)
                let folder = "DeepSeekThinking/ScreenEdge"
                let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder)
                    ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder)
                guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
        }
        frames = load("frame"); transitions = load("transition")
    }
}

/// Entry and exit use real articulated frames and can reverse mid-transition.
struct ScreenEdgePlayback {
    enum Phase: String { case entering, peeking, exiting }
    private(set) var phase: Phase = .entering
    private(set) var step = 0
    private(set) var loopStep = 0
    private(set) var hovering = false
    private(set) var peekStep = 0
    static let peekSteps = 3
    var peekLean: CGFloat { CGFloat(peekStep) / CGFloat(Self.peekSteps) }
    var isPlaying: Bool { phase != .peeking || hovering || peekStep > 0 }
    var concealment: CGFloat { CGFloat(step) / 7 }
    var transitionFrame: Int? { phase == .peeking ? nil : step }
    var loopFrame: Int { ScreenEdgeArtwork.sequence[loopStep] }
    mutating func enter() { phase = .entering; hovering = false }
    mutating func exit() { phase = .exiting; hovering = false }
    mutating func setHovering(_ value: Bool) {
        hovering = value && phase == .peeking
        if !hovering { loopStep = 0 }
    }
    /// Returns true once the complete seated exit frame has had its own tick.
    mutating func advance() -> Bool {
        switch phase {
        case .entering:
            peekStep = max(0, peekStep - 1)
            if step < 7 { step += 1 } else { phase = .peeking; loopStep = 0 }
        case .peeking:
            if hovering {
                if peekStep < Self.peekSteps { peekStep += 1 }
                else { loopStep = (loopStep + 1) % ScreenEdgeArtwork.sequence.count }
            } else { peekStep = max(0, peekStep - 1) }
        case .exiting:
            peekStep = max(0, peekStep - 1)
            if step > 0 { step -= 1 } else { return true }
        }
        return false
    }
}

/// Shared display borders remain a route to the next display.
struct ScreenEdgeDock: Equatable {
    enum Side: String { case left, right }
    let side: Side
    let screenFrame: NSRect
    static func candidate(for frame: NSRect, on screen: NSRect,
                          screens: [NSRect], scale: CGFloat) -> ScreenEdgeDock? {
        let threshold = 24 * scale
        let candidates: [(Side, CGFloat, CGFloat)] = [
            (.left, abs(frame.minX - screen.minX), screen.minX - 1),
            (.right, abs(frame.maxX - screen.maxX), screen.maxX + 1)
        ]
        let headY = frame.minY + 134 * scale
        guard let edge = candidates.filter({ _, distance, outsideX in
            distance <= threshold && !screens.contains { other in
                other != screen && other.contains(NSPoint(x: outsideX, y: headY))
            }
        }).min(by: { $0.1 < $1.1 }) else { return nil }
        return ScreenEdgeDock(side: edge.0, screenFrame: screen)
    }
    static func hiddenWidth(for width: CGFloat, scale: CGFloat) -> CGFloat {
        (width - ScreenEdgeArtwork.height * 0.75 * scale) / 2
            + ScreenEdgeArtwork.edgeX * ScreenEdgeArtwork.height / ScreenEdgeArtwork.canvasSize.height * scale
    }
    static func peekRevealWidth(scale: CGFloat) -> CGFloat {
        (ScreenEdgeArtwork.edgeX + ScreenEdgeArtwork.peekArtworkShiftX - ScreenEdgeArtwork.peekEdgeX)
            * ScreenEdgeArtwork.height / ScreenEdgeArtwork.canvasSize.height * scale
    }
    func origin(for frame: NSRect, usableArea: NSRect, scale: CGFloat) -> NSPoint {
        let hidden = Self.hiddenWidth(for: frame.width, scale: scale)
        return NSPoint(x: side == .left ? screenFrame.minX - hidden : screenFrame.maxX - frame.width + hidden,
            y: min(max(usableArea.minY, frame.minY), max(usableArea.minY, usableArea.maxY - frame.height)))
    }
    static func artworkRect(in bounds: NSRect, scale: CGFloat) -> NSRect {
        let height = ScreenEdgeArtwork.height * scale
        return NSRect(x: bounds.midX - height * 0.75 / 2, y: bounds.minY + 8 * scale,
            width: height * 0.75, height: height)
    }
    /// The complete image stays INSIDE its window. WindowServer clips only at
    /// the physical screen edge, so dragging cannot carry a floating cut line.
    static func draw(frame: Int, transition: Int? = nil, in bounds: NSRect, side: Side, scale: CGFloat,
                     peekLean: CGFloat = 0) {
        let artwork = ScreenEdgeArtwork.shared
        let frames = transition == nil ? artwork.frames : artwork.transitions
        let index = transition ?? frame
        guard frames.indices.contains(index) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // The front-facing seated endpoint matches the ordinary pose on both sides.
        if side == .right && transition != 0 {
            NSGraphicsContext.current?.cgContext.translateBy(x: bounds.minX + bounds.maxX, y: 0)
            NSGraphicsContext.current?.cgContext.scaleBy(x: -1, y: 1)
        }
        if peekLean > 0, let context = NSGraphicsContext.current?.cgContext {
            // The complete pose leans around the hidden lower body. Its local
            // shift leaves enough room for all hair inside the native window.
            let rect = artworkRect(in: bounds, scale: scale)
            let amount = min(1, peekLean)
            context.translateBy(x: -ScreenEdgeArtwork.peekArtworkShiftX * rect.width / 384 * amount, y: 0)
            let pivot = NSPoint(x: rect.minX + 210 * rect.width / 384,
                y: rect.minY + 60 * rect.height / 512)
            context.translateBy(x: pivot.x, y: pivot.y)
            context.rotate(by: -amount * ScreenEdgeArtwork.peekAngle)
            context.translateBy(x: -pivot.x, y: -pivot.y)
        }
        NSGraphicsContext.current?.cgContext.draw(frames[index], in: artworkRect(in: bounds, scale: scale))
    }
}
