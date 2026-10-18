import AppKit
#if canImport(CaptionCore)
import CaptionCore
#endif

class SubtitlePanel: NSPanel {
    var acceptsQuestionInput = false
    override var canBecomeKey: Bool { acceptsQuestionInput }
    override var canBecomeMain: Bool { false }
    var tracksCharacterDrag = false
    private(set) var isManuallyDragging = false
    var onManualDragStateChanged: (() -> Void)?
    var onManualDragStarted: (() -> Void)?
    var onManualDragEnded: ((Bool) -> Void)?
    var onScrollFont: ((Double) -> Void)?
    private var pendingFontDelta = 0.0
    private var fontDeliveryQueued = false
    var onScrollScale: ((Double) -> Void)?
    private var manualDragOrigin: NSPoint?
    private var pendingScaleDelta = 0.0
    private var scaleDeliveryQueued = false
    var characterHitTest: ((NSPoint) -> Bool)?
    func handleScaleScroll(delta: Double, precise: Bool, inverted: Bool, momentum: Bool) {
        guard tracksCharacterDrag, onScrollScale != nil, !isManuallyDragging,
              !momentum, delta.isFinite, delta != 0 else { return }
        let amount = delta * (inverted ? -1 : 1) * (precise ? 0.001 : 0.05)
        pendingScaleDelta = min(1.5, max(-1.5, pendingScaleDelta + min(0.15, max(-0.15, amount))))
        guard !scaleDeliveryQueued else { return }
        scaleDeliveryQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let amount = self.pendingScaleDelta
            self.pendingScaleDelta = 0; self.scaleDeliveryQueued = false
            if amount != 0 { self.onScrollScale?(amount) }
        }
    }
    func handleFontScroll(delta: Double, precise: Bool, inverted: Bool, momentum: Bool) {
        guard onScrollFont != nil, !momentum, delta.isFinite, delta != 0 else { return }
        let direction = inverted ? -1.0 : 1.0
        pendingFontDelta += direction * (precise ? delta * 0.05 : (delta > 0 ? 1 : -1))
        pendingFontDelta = min(8, max(-8, pendingFontDelta))
        guard !fontDeliveryQueued else { return }
        fontDeliveryQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fontDeliveryQueued = false
            let amount = self.pendingFontDelta >= 0 ? floor(self.pendingFontDelta + 1e-9) : ceil(self.pendingFontDelta - 1e-9)
            self.pendingFontDelta -= amount
            if amount != 0 { self.onScrollFont?(amount) }
        }
    }
    func setManualDragging(_ dragging: Bool) {
        isManuallyDragging = dragging
        onManualDragStateChanged?()
    }
    func beginManualDrag() {
        manualDragOrigin = frame.origin
        setManualDragging(true)
        onManualDragStarted?()
    }
    func finishManualDragIfReleased(buttonDown: Bool? = nil) {
        guard let origin = manualDragOrigin,
              !(buttonDown ?? (NSEvent.pressedMouseButtons & 1 != 0)) else { return }
        manualDragOrigin = nil
        setManualDragging(false)
        onManualDragEnded?(frame.origin != origin)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, onScrollFont != nil {
            handleFontScroll(delta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
                inverted: event.isDirectionInvertedFromDevice, momentum: event.momentumPhase != [])
            return
        }
        if tracksCharacterDrag, event.type == .scrollWheel, onScrollScale != nil {
            handleScaleScroll(delta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
                inverted: event.isDirectionInvertedFromDevice, momentum: event.momentumPhase != [])
            return
        }
        guard tracksCharacterDrag, event.type == .leftMouseDown,
              isMovableByWindowBackground, !ignoresMouseEvents else {
            super.sendEvent(event); return
        }
        guard characterHitTest?(event.locationInWindow) ?? true else { return }
        beginManualDrag()
        // WindowServer owns this drag. performDrag returns immediately and
        // can consume mouse-up; the existing UI refresh detects release.
        performDrag(with:event)
    }
}

enum OverlayMode { case combined, bubble, character }

/// A native title control lives in a small child window so the rest of a fixed
/// caption can continue passing clicks through to the application underneath.
final class ConversationLinkButton: NSButton {
    weak var renderer: SubtitleView?
    var caption = NSAttributedString(string: "")
    var captionFrame = NSRect.zero
    private(set) var isFlashing = false
    private(set) var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?
    private var flashGeneration = 0
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        // WindowServer passes fully transparent window pixels through. Keep
        // an imperceptible hit surface even when the visible highlight is off.
        NSColor.white.withAlphaComponent(0.01).setFill()
        bounds.fill()
        if isHovering || isFlashing || cell?.isHighlighted == true {
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        // Glyphs belong to the bubble backing store. This child window only
        // receives clicks and paints transient feedback, so dragging cannot
        // composite title text separately from the rest of the header.
    }
    func flash() {
        flashGeneration &+= 1
        let generation = flashGeneration
        isFlashing = true; needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.isFlashing = false; self.needsDisplay = true
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class SubtitleView: NSView {
    var onControlLayout: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { onControlLayout?() }
    }

    var text = "字幕已就绪，等待 Codex 的下一条进度…" { didSet { if oldValue != text { needsDisplay = true } } }
    private var typewriterID: String?
    private var typewriterCharacters: [Character] = []
    private var revealedCharacterCount = 0
    private var typewriterTimer: Timer?
    private var typewriterInterval: TimeInterval = 1 / 15
    private var lastTypewriterTokenSpeed: Double?
    private var lastTypewriterFallbackSpeed: Double?
    var captionCharactersPerSecond: Double { 1 / typewriterInterval }
    private var displayedText: String {
        guard typewriterID != nil else { return text }
        return String(typewriterCharacters.prefix(revealedCharacterCount))
    }
    var captionRevealedCharacterCount: Int { typewriterID == nil ? text.count : revealedCharacterCount }
    var captionTypewriterRunning: Bool { typewriterTimer != nil }
    var onCaptionProgress: ((Int, Bool) -> Void)?
    // A staged caption can reserve only its current line until it expands.
    var captionLayoutText: String? { didSet { if oldValue != captionLayoutText { needsDisplay = true } } }
    var context = "Codex · 等待更新" { didSet { if oldValue != context { needsDisplay = true } } }
    var captionFooterHeight: CGFloat = 0 { didSet { if oldValue != captionFooterHeight { needsDisplay = true } } }
    var showsCaptionHeader = true { didSet { if oldValue != showsCaptionHeader { needsDisplay = true } } }
    var conversationTitle = "" { didSet { if oldValue != conversationTitle { needsDisplay = true } } }
    var showsCaptionClose = false { didSet { if oldValue != showsCaptionClose { needsDisplay = true } } }
    var conversationSourceName = "Codex" { didSet { if oldValue != conversationSourceName { needsDisplay = true } } }
    private(set) var conversationLinkFrame = NSRect.zero
    private(set) var conversationLinkTextFrame = NSRect.zero
    private(set) var conversationLinkCaption = NSAttributedString(string: "")
    private(set) var headerPrefix = ""
    private(set) var headerPrefixFrame = NSRect.zero
    private var headerLayoutKey = ""
    var fontSize: CGFloat = 28 { didSet { if oldValue != fontSize { needsDisplay = true } } }
    var backdrop: CGFloat = 0.68 { didSet { if oldValue != backdrop { needsDisplay = true } } }
    var isLive = false { didSet { if oldValue != isLive { needsDisplay = true } } }
    private let mascots = MascotAnimation.library
    var layoutScale: CGFloat = 1 { didSet { if oldValue != layoutScale { needsDisplay = true } } }
    var themeHue: CGFloat = 0.57 { didSet { if oldValue != themeHue { needsDisplay = true } } }
    var mode: OverlayMode = .combined { didSet { if oldValue != mode { needsDisplay = true } } }
    var onCharacterDrawn: (() -> Void)?
    // A single reusable RGBA pixel samples the same drawing as the visible
    // character, including animated poses, scaling, gaze and screen docking.
    private lazy var hitContext = CGContext(data: nil, width: 1, height: 1,
        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    private(set) var characterHitSamples = 0
    func containsVisibleCharacter(at point: NSPoint, screenEdgeIdle: Bool = false, peekLean: CGFloat = 0) -> Bool {
        guard mode == .character, showsMascot, bounds.contains(point), let context = hitContext else { return false }
        characterHitSamples += 1
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.saveGState()
        context.translateBy(x: -floor(point.x), y: -floor(point.y))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if screenEdgeIdle, let side = screenEdgeDock {
            ScreenEdgeDock.draw(frame: 0, in: bounds, side: side, scale: layoutScale, peekLean: peekLean)
        } else { drawCharacter(includeEffects: false) }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        return (context.data?.assumingMemoryBound(to: UInt8.self)[3] ?? 0) > 0
    }
    var tailTarget: NSPoint?
    var sideTailTarget: NSPoint? { didSet { if oldValue != sideTailTarget { needsDisplay = true } } }
    var compactStack = false { didSet { if oldValue != compactStack { needsDisplay = true } } }
    private var mascotKind: CaptionMascot?
    private var usesPinkBear = false
    #if !VIBECUTE_RELEASE
    private(set) var cutoutRenderer: CutoutOverlayRenderer?
    #endif
    private var mascot: MascotAnimation? {
        guard let mascotKind else { return nil }
        if mascotKind == .orangeHoodie { return MascotAnimation.orangeHoodie }
        return usesPinkBear ? MascotAnimation.pinkBear : mascots[mascotKind]
    }
    var mascotArtwork: String { usesPinkBear ? "pinkBear" : mascotSource }
    private var playbackSequence: [Int] {
        screenEdgeDock != nil ? ScreenEdgeArtwork.sequence : mascot?.playbackSequence ?? MascotAnimation.sequence
    }
    private var animationTimer: Timer?
    private var requestedMascotAnimating = false
    private var rainShelterThinking = false
    private var seatedMotionTimer: Timer?
    private var gazeTimer: Timer?
    private var gazeClock: TimeInterval = 0
    private var gaze = SeatedGaze()
    private var headPatGesture = HeadPatGesture()
    private var headPatStartedAt: TimeInterval?
    private var headPatStreak = HeadPatStreak()
    private var akimboStartedAt: TimeInterval?
    private(set) var akimboWinkStartedAt: TimeInterval?
    private(set) var akimboFrame: Int?
    private(set) var akimboCount = 0
    private(set) var akimboUtterance = 0
    var akimboUtterancePause = AkimboReaction.utterancePause
    private var activeAkimboUtterancePause = AkimboReaction.utterancePause
    private var akimboNextUtteranceAt: TimeInterval?
    private var akimboSpeech = AkimboSpeechPlayer()
    var akimboMouthIndex: Int? { akimboSpeech.mouth }
    func updateAkimboSpeech(utterance: Int, revealed: Int, typing: Bool) {
        guard let start = akimboStartedAt else { return }
        akimboSpeech.observe(utterance: utterance, revealed: revealed, typing: typing)
        if utterance == 2, revealed >= AkimboReaction.winkCueCharacterCount, akimboWinkStartedAt == nil {
            // Fast captions can reach the cue while the hands still move.
            // Finish that transition before playing all eight wink poses.
            akimboWinkStartedAt = max(ProcessInfo.processInfo.systemUptime,
                                      start+AkimboReaction.armTransition)
        }
        if utterance == akimboUtterance, utterance < 2, !typing,
           revealed == AkimboReaction.utterances[utterance].count, akimboNextUtteranceAt == nil {
            akimboNextUtteranceAt = ProcessInfo.processInfo.systemUptime+activeAkimboUtterancePause
        }
    }
    var onAkimboChanged: (() -> Void)?
    var akimboActive: Bool { akimboStartedAt != nil }
    private var headPatPointerFrame: NSRect?
    private(set) var headPatCount = 0
    private(set) var headPatPointerSamples = 0
    private(set) var headPatInsideSamples = 0
    private var headPatLastPoint = NSPoint.zero
    var headPatActive: Bool { headPatStartedAt != nil || akimboActive }
    var headPatReactionSample: HeadPatReaction.Sample? {
        headPatStartedAt.flatMap { HeadPatReaction.sample(elapsed: ProcessInfo.processInfo.systemUptime-$0) }
    }
    var headPatEligible: Bool {
        mode == .character && showsMascot && screenEdgeDock == nil &&
        !dragReaction.active && sleepSample == nil && !performanceActive && strollSample == nil && rainShelterPose == nil && scootSample == nil &&
        frontRetreatSample == nil && !hasScootRestPose
    }
    var headPatRegion: NSRect {
    #if !VIBECUTE_RELEASE
        if let renderer = cutoutRenderer { return renderer.headPatRegion }
    #endif
        let rect = seatedCharacterRect
        // Include the actual forehead/hair, rather than a narrow strip that
        // excluded normal hand-drawn arcs across the crown and hairline.
        return NSRect(x: rect.minX + rect.width*0.14, y: rect.minY + rect.height*0.56,
            width: rect.width*0.72, height: rect.height*0.40)
    }
    var headPatDiagnostics: [String: Any] {
        let head = headPatRegion
        return ["active": headPatActive, "count": headPatCount, "eligible": headPatEligible,
                "streak": headPatStreak.count, "akimboActive": akimboActive,
                "akimboCount": akimboCount, "akimboFrame": akimboFrame ?? -1,
                "pointerSamples": headPatPointerSamples,
                "insideSamples": headPatInsideSamples, "lastX": headPatLastPoint.x, "lastY": headPatLastPoint.y,
                "headX": head.minX, "headY": head.minY, "headWidth": head.width, "headHeight": head.height]
    }
    func cancelHeadPat() {
        headPatGesture.reset(); headPatPointerFrame = nil
        headPatStreak.reset(); akimboSpeech.reset(); akimboWinkStartedAt = nil; akimboNextUtteranceAt = nil
        if akimboActive { akimboStartedAt = nil; akimboFrame = nil; onAkimboChanged?() }
        if headPatStartedAt != nil || seatedMotionTimer != nil {
            headPatStartedAt = nil; refreshSeatedMotion(); needsDisplay = true
        }
    }
    /// Called only by the existing native pointer monitors, never by redraws.
    func observeHeadPat(at point: NSPoint, pressed: Bool, visibleHit: Bool,
                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        headPatPointerSamples += 1
        guard headPatEligible, window?.isVisible == true, !pressed else { cancelHeadPat(); return }
        // Window moves, scale changes and display changes invalidate a stroke.
        let frame = window!.frame
        if headPatPointerFrame != frame { headPatGesture.reset(); headPatPointerFrame = frame }
        guard !headPatActive else { return }
        let head = headPatRegion
        let normalized = NSPoint(x: (point.x-head.minX)/head.width, y: (point.y-head.minY)/head.height)
        if normalized.x.isFinite && normalized.y.isFinite { headPatLastPoint = normalized }
        let inHead = visibleHit && head.contains(point)
        if inHead { headPatInsideSamples += 1 }
        if !inHead && !head.insetBy(dx: -head.width*0.12, dy: -head.height*0.12).contains(point) {
            headPatGesture.reset(); return
        }
        if headPatGesture.update(inHead ? normalized : nil, at: now) {
            headPatCount += 1
            if mascotKind == .deepseek, !usesPinkBear, headPatStreak.record(at: now), AkimboArtwork.shared.available {
                akimboStartedAt = ProcessInfo.processInfo.systemUptime
                akimboWinkStartedAt = nil
                akimboNextUtteranceAt = nil
                activeAkimboUtterancePause = AkimboReaction.boundedUtterancePause(akimboUtterancePause)
                akimboSpeech.reset()
                akimboFrame = 0; akimboUtterance = 0; akimboCount += 1
                onAkimboChanged?()
            } else { headPatStartedAt = ProcessInfo.processInfo.systemUptime }
            refreshSeatedMotion(); needsDisplay = true
        }
    }
    func playOnboardingReaction() {
        guard headPatEligible, !headPatActive else { return }
        headPatStartedAt = ProcessInfo.processInfo.systemUptime
        refreshSeatedMotion(); needsDisplay = true
    }
    func advanceHeadPat(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let start = akimboStartedAt {
            guard headPatEligible, window?.isVisible == true else { cancelHeadPat(); return }
            let previousMouth = akimboSpeech.mouth
            akimboSpeech.advance(at: now)
            if previousMouth != akimboSpeech.mouth { needsDisplay = true }
            let frame = AkimboReaction.frame(at: now-start, winkElapsed: akimboWinkStartedAt.map { now-$0 })
            if frame != nil, let next = akimboNextUtteranceAt, now >= next {
                akimboNextUtteranceAt = nil
                akimboUtterance += 1; onAkimboChanged?()
            }
            if frame != akimboFrame { akimboFrame = frame; needsDisplay = true }
            if frame == nil {
                akimboStartedAt = nil; akimboWinkStartedAt = nil; akimboNextUtteranceAt = nil
                akimboSpeech.reset(); onAkimboChanged?(); refreshSeatedMotion()
                refreshGazeTracking(); needsDisplay = true
            }
            return
        }
        guard let start = headPatStartedAt else { return }
        guard headPatEligible, window?.isVisible == true else { cancelHeadPat(); return }
        if now - start >= HeadPatReaction.duration { headPatStartedAt = nil; refreshSeatedMotion() }
        needsDisplay = true
    }
    var seatedGazePosition: NSPoint { gaze.position }
    var seatedGazeActive: Bool {
        !headPatActive && showsMascot && mascot?.supportsSeatedGaze == true && mode != .bubble && screenEdgeDock == nil &&
        !dragReaction.active && sleepSample == nil && !performanceActive && strollSample == nil && rainShelterPose == nil && scootSample == nil &&
        frontRetreatSample == nil && !hasScootRestPose
    }
    var originalThinkingPoseActive: Bool {
        !headPatActive && screenEdgeDock == nil && mascotAnimating && audioMouthIndex == nil && mascot?.thinkingFrames.count == 8 &&
        !dragReaction.active && sleepSample == nil && !performanceActive && strollSample == nil && rainShelterPose == nil && scootSample == nil &&
        frontRetreatSample == nil && !hasScootRestPose
    }
    private var seatedCharacterRect: NSRect {
        let height = characterHeight, width = height * 0.75
        return NSRect(x: bounds.midX - width / 2, y: 8 * layoutScale, width: width, height: height)
    }

    private func refreshGazeTracking() {
        guard !dragReaction.active, sleepSample == nil, rainShelterPose == nil, mascot?.supportsSeatedGaze == true, mode != .bubble, screenEdgeDock == nil else {
            gazeTimer?.invalidate(); gazeTimer = nil; gaze = SeatedGaze(); return
        }
        guard gazeTimer == nil else { return }
        gazeClock = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let dt = now - self.gazeClock; self.gazeClock = now
            guard let window = self.window, window.isVisible else { return }
            let following = self.seatedGazeActive
            let cursor = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let transform = self.mascot!.seatedTransform(in: self.seatedCharacterRect, at: now,
                amount: self.seatedMotionAmount(at: now))
            let target = following ? SeatedGaze.target(cursor: cursor, in: self.seatedCharacterRect,
                transform: transform, eyeCenter: self.originalThinkingPoseActive
                    ? self.mascot!.thinkingEyeCenter(frame: self.mascotFrameIndex) : SeatedGaze.eyeCenter) : .zero
            let before = self.gaze.position
            self.gaze.update(target: target, dt: min(dt, 0.1), returning: !following)
            if self.seatedGazeActive && hypot(before.x - self.gaze.position.x, before.y - self.gaze.position.y) > 0.0001 {
                self.needsDisplay = true
            }
        }
        gazeTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private var motionStartedAt: TimeInterval = 0
    private var motionStartAmount: CGFloat = 0
    private var motionTargetAmount: CGFloat = 0
    private var sequenceIndex = 0
    private(set) var screenEdgePlayback: ScreenEdgePlayback?
    var onScreenEdgeFrame: (() -> Void)?
    var onScreenEdgeExited: (() -> Void)?
    var screenEdgeDock: ScreenEdgeDock.Side? {
        didSet {
            guard oldValue != screenEdgeDock else { return }
            cancelHeadPat()
            screenEdgePlayback = screenEdgeDock == nil ? nil : ScreenEdgePlayback()
            refreshGazeTracking(); refreshSeatedMotion(); needsDisplay = true
        }
    }
    func enterScreenEdge(_ side: ScreenEdgeDock.Side) {
        screenEdgeDock = side
        screenEdgePlayback?.enter()
        needsDisplay = true
    }
    func exitScreenEdge() {
        screenEdgePlayback?.exit()
        needsDisplay = true
    }
    func setScreenEdgeHovered(_ hovering: Bool) {
        guard var playback = screenEdgePlayback else { return }
        let before = playback.hovering
        playback.setHovering(hovering)
        screenEdgePlayback = playback
        if before != playback.hovering { needsDisplay = true }
    }
    func advanceScreenEdgeFrame() {
        guard var playback = screenEdgePlayback, playback.isPlaying else { return }
        let previous = playback
        let finished = playback.advance()
        screenEdgePlayback = playback
        if previous.step != playback.step || previous.phase != playback.phase || previous.peekStep != playback.peekStep {
            onScreenEdgeFrame?()
        }
        if finished {
            screenEdgeDock = nil
            onScreenEdgeExited?()
        }
        if finished || previous.transitionFrame != playback.transitionFrame || previous.loopFrame != playback.loopFrame
            || previous.peekStep != playback.peekStep {
            needsDisplay = true
        }
    }
    private(set) var dragReaction = CharacterDragReaction()
    @discardableResult
    func beginDragReaction(at point: NSPoint, time: TimeInterval) -> Bool {
        guard mascotKind == .deepseek, !usesPinkBear, mode == .character, screenEdgeDock == nil else { return false }
        cancelHeadPat()
        _ = CharacterDragArtwork.shared
        dragReaction.begin(at: point, time: time)
        refreshSeatedMotion()
        needsDisplay = true
        return true
    }
    func endDragReaction(at time: TimeInterval) { dragReaction.end(at: time) }
    func updateDragReaction(at point: NSPoint, time: TimeInterval) {
        if screenEdgeDock != nil || mascotKind != .deepseek || usesPinkBear || window?.isVisible != true {
            if dragReaction.active { dragReaction.reset(); needsDisplay = true }
            return
        }
        let wasActive = dragReaction.active
        if dragReaction.update(at: point, time: time, scale: layoutScale) { needsDisplay = true }
        if wasActive && !dragReaction.active {
            sequenceIndex = 0
            refreshSeatedMotion()
        }
    }
    private(set) var sleepSample: DeepSeekSleepTimeline.Sample?
    func setSleepSample(_ sample: DeepSeekSleepTimeline.Sample?) {
        guard mascotKind == .deepseek, !usesPinkBear, sleepSample != sample else { return }
        let toggled = (sleepSample == nil) != (sample == nil)
        if sample != nil { cancelHeadPat(); cancelSeatedRecovery() }
        sleepSample = sample
        if toggled { refreshGazeTracking(); refreshSeatedMotion() }
        needsDisplay = true
    }
    private(set) var audioMouthIndex: Int?
    private(set) var performanceFrameIndex: Int?
    private var hoodieSingingPlayback = OrangeHoodieSingingPlayback()
    private(set) var hoodieSingingPose: OrangeHoodieSingingPose?
    private var performanceActive: Bool { performanceFrameIndex != nil || hoodieSingingPose != nil || hoodieScootPose != nil }
    private(set) var hoodieScootPose: OrangeHoodieScoot.Pose?
    private var hoodieScootFrame = 0
    func setOrangeHoodieScoot(_ pose: OrangeHoodieScoot.Pose?) {
        guard mascotKind == .orangeHoodie, pose != hoodieScootPose else { return }
        if pose != nil && hoodieScootPose == nil {
            hoodieScootFrame = audioMouthIndex == nil && ![3,4].contains(mascotFrameIndex) ? mascotFrameIndex : 0
            cancelHeadPat()
        }
        if pose == nil, let index = playbackSequence.firstIndex(of:hoodieScootFrame) { sequenceIndex = index }
        hoodieScootPose = pose
        refreshSeatedMotion(); needsDisplay = true
    }
    func setOrangeHoodieSinging(phase: SingingPerformance.Phase, cycle: Double, at now: TimeInterval) {
        guard mascotKind == .orangeHoodie else { return }
        let next = OrangeHoodiePerformance.shared.available
            ? hoodieSingingPlayback.sample(phase:phase,cycle:cycle,at:now) : nil
        guard next != hoodieSingingPose else { return }
        let toggled = (next == nil) != (hoodieSingingPose == nil)
        hoodieSingingPose = next
        if next != nil { cancelHeadPat() }
        if toggled { refreshGazeTracking(); refreshSeatedMotion() }
        needsDisplay = true
    }
    var performanceMirrored = false { didSet { if oldValue != performanceMirrored { needsDisplay = true } } }
    private(set) var hasScootRestPose = false
    private var seatedRecoveryTimer: Timer?
    private var seatedRecoveryProgress: CGFloat = 0
    private func cancelSeatedRecovery() {
        seatedRecoveryTimer?.invalidate(); seatedRecoveryTimer = nil
        hasScootRestPose = false; seatedRecoveryProgress = 0
    }
    private func recoverThinkingSeat() {
        cancelSeatedRecovery()
        hasScootRestPose = true
        sequenceIndex = 0
        let startedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = CGFloat(min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / 0.32))
            self.seatedRecoveryProgress = p * p * (3 - 2 * p)
            if p >= 1 { self.cancelSeatedRecovery() }
            self.needsDisplay = true
        }
        seatedRecoveryTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private(set) var scootSample: SeatedScootTimeline.Sample?
    private(set) var frontRetreatSample: FrontRetreatTimeline.Sample?
    private var frontRetreatEntryImage: NSImage?
    private var frontRetreatFromScootRest = false
    func setFrontRetreatSample(_ sample: FrontRetreatTimeline.Sample?) {
        guard !usesPinkBear, frontRetreatSample != sample else { return }
        if sample != nil { cancelHeadPat() }
        if sample != nil && frontRetreatSample == nil {
            frontRetreatFromScootRest = hasScootRestPose
            if let bitmap = bitmapImageRepForCachingDisplay(in:bounds) {
                cacheDisplay(in:bounds,to:bitmap)
                bitmap.size = bounds.size
                let image = NSImage(size:bounds.size); image.addRepresentation(bitmap)
                frontRetreatEntryImage = image
            }
        }
        if sample == nil && frontRetreatSample != nil { recoverThinkingSeat(); frontRetreatEntryImage = nil }
        if sample != nil { cancelSeatedRecovery() }
        frontRetreatSample = sample
        refreshSeatedMotion()
        needsDisplay = true
    }
    func setScootSample(_ sample: SeatedScootTimeline.Sample?) {
        guard !usesPinkBear, mascotKind == .deepseek, scootSample != sample else { return }
        if sample != nil { cancelHeadPat() }
        if sample == nil && scootSample != nil { recoverThinkingSeat() }
        if sample != nil { cancelSeatedRecovery() }
        scootSample = sample
        refreshSeatedMotion()
        needsDisplay = true
    }
    private(set) var rainShelterPose: RainShelterPose?
    func setRainShelterThinking(_ enabled: Bool) {
        guard rainShelterThinking != enabled else { return }
        rainShelterThinking = enabled
        refreshMascotAnimation(); refreshGazeTracking(); needsDisplay = true
    }
    func setRainShelterPose(_ pose: RainShelterPose?) {
        guard mascotKind == .deepseek, !usesPinkBear, rainShelterPose != pose else { return }
        if pose != nil { cancelHeadPat(); cancelSeatedRecovery() }
        else if rainShelterPose != nil {
            // The last stow image already matches thinking frame zero. A second
            // scoot-rest recovery would briefly replace it with another pose.
            cancelSeatedRecovery(); sequenceIndex = 0
        }
        rainShelterPose = pose
        refreshSeatedMotion(); refreshGazeTracking(); needsDisplay = true
    }

    var strollMirrored = false
    private(set) var strollSample: StrollTimeline.Sample?
    private var strollEntryImage: NSImage?
    private var strollFromScootRest = false
    func setStrollSample(_ sample: StrollTimeline.Sample?) {
        guard !usesPinkBear, strollSample != sample else { return }
        if sample != nil { cancelHeadPat() }
        if sample != nil && strollSample == nil {
            strollFromScootRest = hasScootRestPose
            if let bitmap = bitmapImageRepForCachingDisplay(in:bounds) {
                cacheDisplay(in:bounds,to:bitmap); bitmap.size = bounds.size
                let image = NSImage(size:bounds.size); image.addRepresentation(bitmap)
                strollEntryImage = image
            }
        }
        if sample == nil && strollSample != nil { recoverThinkingSeat(); strollEntryImage = nil }
        if sample != nil { cancelSeatedRecovery() }
        strollSample = sample
        refreshSeatedMotion()
        needsDisplay = true
    }
    func setPerformanceFrame(_ index: Int?) {
        if usesPinkBear { return }
        guard performanceFrameIndex != index else { return }
        if index != nil { cancelHeadPat() }
        if index != nil { cancelSeatedRecovery() }
        performanceFrameIndex = index
        refreshSeatedMotion()
        if screenEdgeDock == nil { needsDisplay = true }
    }
    func setAudioMouth(_ index: Int?) {
        if usesPinkBear { return }
        guard audioMouthIndex != index else { return }
        audioMouthIndex = index
    #if !VIBECUTE_RELEASE
        cutoutRenderer?.setAudioMouth(index)
    #endif
        refreshSeatedMotion()
        if screenEdgeDock == nil { needsDisplay = true }
    }
    #if VIBECUTE_RELEASE
    var showsMascot: Bool { mascotFrameCount == 8 }
    #else
    var showsMascot: Bool { cutoutRenderer != nil || mascotFrameCount == 8 }
    #endif
    var mascotSource: String { mascotKind?.rawValue ?? "" }
    var mascotFrameCount: Int { mascot?.frames.count ?? 0 }
    #if VIBECUTE_RELEASE
    var mascotAnimating: Bool { animationTimer != nil }
    #else
    var mascotAnimating: Bool { cutoutRenderer?.thinking ?? (animationTimer != nil) }
    #endif
    var seatedMotionAnimating: Bool { seatedMotionTimer != nil }
    var mascotFrameIndex: Int { playbackSequence[sequenceIndex % playbackSequence.count] }
    private var characterHeight: CGFloat { showsMascot ? 168 * layoutScale : 0 }
    private var performanceHeadroom: CGFloat {
        if mascotKind == .orangeHoodie { return 42 * layoutScale }
        return !usesPinkBear && mascotKind == .deepseek &&
            (DeepSeekPerformance.shared.available || DeepSeekStroll.shared.available) ? 42 * layoutScale : 0
    }
    private var bubbleBottom: CGFloat {
        if showsMascot && mode != .bubble { return characterHeight + performanceHeadroom + 24 * layoutScale }
        return (mode == .bubble && tailTarget != nil ? 24 : compactStack ? 2 : 8) * layoutScale
    }
    private var bubbleTop: CGFloat { (compactStack ? 2 : 8) * layoutScale }
    var bubbleFrame: NSRect {
        NSRect(x: 9 * layoutScale, y: bubbleBottom, width: bounds.width - 18 * layoutScale,
               height: bounds.height - bubbleBottom - bubbleTop)
    }
    override var mouseDownCanMoveWindow: Bool { true }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4 * layoutScale
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }

    func drawOutlined(_ text: NSAttributedString, in rect: NSRect) {
        let pixelsPerPoint = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let radius = 1 / pixelsPerPoint
        let outline = NSMutableAttributedString(attributedString: text)
        outline.addAttribute(.foregroundColor, value: NSColor.black,
                             range: NSRange(location: 0, length: outline.length))
        // Expand the filled glyph silhouette, then cover the interior. Stroking
        // font contours directly leaves seams where Chinese strokes overlap.
        for step in 0..<8 {
            let angle = CGFloat(step) * .pi / 4
            outline.draw(with: rect.offsetBy(dx: cos(angle) * radius, dy: sin(angle) * radius),
                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private var headerAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 10 * layoutScale, weight: .semibold),
            .foregroundColor: isLive ? NSColor(calibratedHue: themeHue, saturation: 0.3, brightness: 1, alpha: 1) : NSColor.white.withAlphaComponent(0.65),
            .kern: 0.5 * layoutScale, .paragraphStyle: paragraph]
    }

    func prepareConversationHeader() {
        let key = "\(context)|\(conversationTitle)|\(showsCaptionHeader)|\(showsCaptionClose)|\(bounds)|\(layoutScale)|\(compactStack)|\(mode)|\(isLive)|\(themeHue)"
        guard key != headerLayoutKey else { return }
        headerLayoutKey = key
        conversationLinkFrame = .zero
        conversationLinkTextFrame = .zero
        guard showsCaptionHeader, mode != .character, !conversationTitle.isEmpty, context.hasSuffix(conversationTitle) else { return }
        let attributes = headerAttributes
        headerPrefix = String(context.dropLast(conversationTitle.count))
        let box = bubbleFrame
        let available = max(0, box.width - (showsCaptionClose ? 66 : 36) * layoutScale)
        let suffix = "  ↗"
        let suffixWidth = ceil((suffix as NSString).size(withAttributes: attributes).width)
        let prefixWidth = min(ceil((headerPrefix as NSString).size(withAttributes: attributes).width), max(0, available - suffixWidth))
        let titleWidth = max(0, available - prefixWidth - suffixWidth)
        // Bound visible title length by graphemes, then fit only that bounded
        // candidate into the space left by the full source/status prefix.
        let characters = Array(conversationTitle.prefix(9))
        var label = String(characters.prefix(8)) + (characters.count > 8 ? "…" : "")
        if (label as NSString).size(withAttributes: attributes).width > titleWidth {
            var low = 0, high = characters.count
            high = min(high, 8)
            while low < high {
                let mid = (low + high + 1) / 2
                let candidate = String(characters.prefix(mid)) + "…"
                if (candidate as NSString).size(withAttributes: attributes).width <= titleWidth { low = mid }
                else { high = mid - 1 }
            }
            label = ("…" as NSString).size(withAttributes: attributes).width <= titleWidth
                ? String(characters.prefix(low)) + "…" : ""
        }
        var linkAttributes = attributes
        linkAttributes[.foregroundColor] = NSColor(calibratedHue: themeHue, saturation: 0.3, brightness: 1, alpha: 1)
        conversationLinkCaption = NSAttributedString(string: label + suffix, attributes: linkAttributes)
        let linkWidth = min(available - prefixWidth, ceil(conversationLinkCaption.size().width))
        let x = box.midX - (prefixWidth + linkWidth) / 2
        let y = box.maxY - (compactStack ? 22 : 28) * layoutScale
        headerPrefixFrame = NSRect(x: x, y: y, width: prefixWidth, height: 15 * layoutScale)
        conversationLinkTextFrame = NSRect(x: x + prefixWidth, y: y, width: linkWidth, height: 15 * layoutScale)
        // The header's glyph ink sits above its line-fragment midpoint. Keep
        // the baseline fixed and centre the padded hit surface around the ink.
        conversationLinkFrame = conversationLinkTextFrame.insetBy(dx: -3 * layoutScale, dy: -1.5 * layoutScale)
            .offsetBy(dx: 0, dy: 1.25 * layoutScale)
    }

    // Two single-entry caches bound retained text and reuse layout across the
    // 250 ms UI refresh and animation draws. Keys contain every metric input;
    // staged captions use their reserved layout text, not the revealed prefix.
    private struct TextMeasureKey: Equatable {
        var text: String
        var fontSize: CGFloat
        var scale: CGFloat
        var width: CGFloat
    }
    private var wrappedMeasurement: (TextMeasureKey, NSSize)?
    private var naturalMeasurement: (TextMeasureKey, CGFloat)?
    private(set) var textMeasurementCount = 0

    private func textSize(for width: CGFloat) -> NSSize {
        let key = TextMeasureKey(text: captionLayoutText ?? text, fontSize: fontSize,
                                 scale: layoutScale, width: max(1, width - 66 * layoutScale))
        if let cached = wrappedMeasurement, cached.0 == key { return cached.1 }
        let size = NSAttributedString(string: key.text, attributes: textAttributes)
            .boundingRect(with: NSSize(width: key.width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        textMeasurementCount += 1
        wrappedMeasurement = (key, size)
        return size
    }

    func setCaption(_ value: String, typewriterID: String?, charactersPerSecond: Double, tokensPerSecond: Double? = nil) {
        let tokens = TypewriterSpeedMapping.boundedTokens(tokensPerSecond)
        let fallback = 15.0
        if tokens != lastTypewriterTokenSpeed || fallback != lastTypewriterFallbackSpeed {
            lastTypewriterTokenSpeed = tokens; lastTypewriterFallbackSpeed = fallback
            let interval = 1 / TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: tokens, fallback: fallback)
            if interval != typewriterInterval { typewriterInterval = interval; pauseTypewriter() }
        }
        if typewriterID == nil, self.typewriterID == nil, text == value { return }
        let previousText = text
        let previousID = self.typewriterID
        text = value
        guard let typewriterID else {
            self.typewriterID = nil
            typewriterCharacters = []
            revealedCharacterCount = value.count
            typewriterTimer?.invalidate(); typewriterTimer = nil
            onCaptionProgress?(revealedCharacterCount, false)
            needsDisplay = true
            return
        }

        if previousID != typewriterID || !value.hasPrefix(previousText) {
            typewriterCharacters = Array(value)
            revealedCharacterCount = 0
        } else if value != previousText {
            typewriterCharacters = Array(value)
            revealedCharacterCount = min(revealedCharacterCount, previousText.count)
        }
        self.typewriterID = typewriterID
        startTypewriterIfNeeded()
        onCaptionProgress?(revealedCharacterCount, typewriterTimer != nil)
        if previousText != value || previousID != typewriterID { needsDisplay = true }
    }

    func pauseTypewriter() {
        typewriterTimer?.invalidate(); typewriterTimer = nil
        onCaptionProgress?(revealedCharacterCount, false)
    }

    private func startTypewriterIfNeeded() {
        guard typewriterTimer == nil, revealedCharacterCount < typewriterCharacters.count else { return }
        let timer = Timer(timeInterval: typewriterInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.revealedCharacterCount < self.typewriterCharacters.count else {
                self.pauseTypewriter()
                return
            }
            self.revealedCharacterCount += 1
            self.needsDisplay = true
            if self.revealedCharacterCount == self.typewriterCharacters.count { self.pauseTypewriter() }
            else { self.onCaptionProgress?(self.revealedCharacterCount, true) }
        }
        typewriterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func preferredWidth(available: CGFloat) -> CGFloat {
    #if !VIBECUTE_RELEASE
        if mode == .character,let renderer=cutoutRenderer {return renderer.displaySize.width*layoutScale}
    #endif
        if mode == .character {
            if mascotKind == .deepseek && !usesPinkBear { return 204 * layoutScale }
            return (performanceHeadroom > 0 ? 147 : 126) * layoutScale
        }
        let key = TextMeasureKey(text: text, fontSize: fontSize, scale: layoutScale, width: 0)
        let natural: CGFloat
        if let cached = naturalMeasurement, cached.0 == key {
            natural = cached.1
        } else {
            natural = (text as NSString).size(withAttributes: textAttributes).width + 66 * layoutScale
            textMeasurementCount += 1
            naturalMeasurement = (key, natural)
        }
        let maximum = min(520 * layoutScale, available * 0.82)
        return min(maximum, max(min(340 * layoutScale, maximum), ceil(natural)))
    }

    /// One outline includes the tail, avoiding a seam inside the speech bubble.
    private func speechBubble(_ box: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let r: CGFloat = (compactStack ? 8 : 18) * layoutScale, k: CGFloat = 0.55228475
        let x = box.minX, y = box.minY, right = box.maxX, top = box.maxY
        path.move(to: NSPoint(x: x + r, y: y))
        if sideTailTarget == nil && (showsMascot || tailTarget != nil) {
            let target = tailTarget ?? NSPoint(x: box.midX, y: y - 30 * layoutScale)
            let baseX = min(max(box.minX + 28 * layoutScale, target.x), box.maxX - 28 * layoutScale)
            let dx = target.x - baseX, dy = target.y - y
            let distance = max(1, hypot(dx, dy))
            path.line(to: NSPoint(x: baseX - 9 * layoutScale, y: y))
            path.line(to: NSPoint(x: baseX + 14 * layoutScale * dx / distance,
                                 y: y - max(8, 16 * abs(dy) / distance) * layoutScale))
            path.line(to: NSPoint(x: baseX + 9 * layoutScale, y: y))
        }
        path.line(to: NSPoint(x: right - r, y: y))
        path.curve(to: NSPoint(x: right, y: y + r),
                   controlPoint1: NSPoint(x: right - r + r * k, y: y),
                   controlPoint2: NSPoint(x: right, y: y + r - r * k))
        if let target = sideTailTarget, target.x > box.midX {
            let base = min(max(y+r+10*layoutScale, target.y), top-r-10*layoutScale)
            path.line(to: NSPoint(x: right, y: base-8*layoutScale))
            path.line(to: NSPoint(x: right+9*layoutScale, y: base))
            path.line(to: NSPoint(x: right, y: base+8*layoutScale))
        }
        path.line(to: NSPoint(x: right, y: top - r))
        path.curve(to: NSPoint(x: right - r, y: top),
                   controlPoint1: NSPoint(x: right, y: top - r + r * k),
                   controlPoint2: NSPoint(x: right - r + r * k, y: top))
        path.line(to: NSPoint(x: x + r, y: top))
        path.curve(to: NSPoint(x: x, y: top - r),
                   controlPoint1: NSPoint(x: x + r - r * k, y: top),
                   controlPoint2: NSPoint(x: x, y: top - r + r * k))
        if let target = sideTailTarget, target.x < box.midX {
            let base = min(max(y+r+10*layoutScale, target.y), top-r-10*layoutScale)
            path.line(to: NSPoint(x: x, y: base+8*layoutScale))
            path.line(to: NSPoint(x: x-9*layoutScale, y: base))
            path.line(to: NSPoint(x: x, y: base-8*layoutScale))
        }
        path.line(to: NSPoint(x: x, y: y + r))
        path.curve(to: NSPoint(x: x + r, y: y),
                   controlPoint1: NSPoint(x: x, y: y + r - r * k),
                   controlPoint2: NSPoint(x: x + r - r * k, y: y))
        path.close()
        return path
    }

    func setMascot(_ kind: CaptionMascot?, animating: Bool, pinkBear: Bool = false) {
        requestedMascotAnimating = animating
        if kind != mascotKind || pinkBear != usesPinkBear || mode != .character { cancelHeadPat() }
        if kind != mascotKind || pinkBear != usesPinkBear { sequenceIndex = 0; cancelSeatedRecovery() }
        if kind != mascotKind || pinkBear != usesPinkBear {
            sleepSample = nil; hoodieSingingPose = nil; hoodieScootPose = nil; hoodieSingingPlayback = OrangeHoodieSingingPlayback()
        }
        mascotKind = kind
        usesPinkBear = pinkBear && kind != nil
        #if !VIBECUTE_RELEASE
        if kind == .deepseekCutout && !usesPinkBear && mode != .bubble {
            if cutoutRenderer == nil {
                do { cutoutRenderer = try CutoutOverlayRenderer(view: self) }
                catch { assertionFailure("Cannot load cutout character: \(error)") }
            }
            animationTimer?.invalidate(); animationTimer = nil
            gazeTimer?.invalidate(); gazeTimer = nil
            seatedMotionTimer?.invalidate(); seatedMotionTimer = nil
            cutoutRenderer?.setThinking(animating)
            cutoutRenderer?.refreshVisibility()
            needsDisplay = true
            return
        }
        cutoutRenderer = nil
        #endif
        if usesPinkBear || kind != .deepseek { rainShelterThinking = false; rainShelterPose = nil; strollSample = nil; strollEntryImage = nil; scootSample = nil; frontRetreatSample = nil; frontRetreatEntryImage = nil }
        if usesPinkBear { audioMouthIndex = nil; performanceFrameIndex = nil }
        if kind == .orangeHoodie { performanceFrameIndex = nil; dragReaction.reset() }
        refreshGazeTracking()
        refreshSeatedMotion()
        refreshMascotAnimation()
    }

    private func refreshMascotAnimation() {
        if showsMascot && (requestedMascotAnimating || rainShelterThinking || screenEdgeDock != nil) {
            guard animationTimer == nil else { return }
            let timer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.screenEdgeDock != nil { self.advanceScreenEdgeFrame(); return }
                self.sequenceIndex = (self.sequenceIndex + 1) % self.playbackSequence.count
                if (!self.dragReaction.active && self.sleepSample == nil && !self.headPatActive && self.audioMouthIndex == nil && !self.performanceActive && self.strollSample == nil && self.rainShelterPose == nil && self.scootSample == nil && self.frontRetreatSample == nil) { self.needsDisplay = true }
            }
            animationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            animationTimer?.invalidate(); animationTimer = nil
            sequenceIndex = 0
        }
    }

    private func seatedMotionAmount(at now: TimeInterval) -> CGFloat {
        let progress = CGFloat(min(1, max(0, (now - motionStartedAt) / 0.25)))
        let eased = progress * progress * (3 - 2 * progress)
        return motionStartAmount + (motionTargetAmount - motionStartAmount) * eased
    }

    private func refreshSeatedMotion() {
    #if !VIBECUTE_RELEASE
        guard cutoutRenderer == nil else { return }
    #endif
        let now = ProcessInfo.processInfo.systemUptime
        guard !dragReaction.active, sleepSample == nil, showsMascot, screenEdgeDock == nil else {
            seatedMotionTimer?.invalidate(); seatedMotionTimer = nil
            motionStartAmount = 0; motionTargetAmount = 0
            return
        }
        let target: CGFloat = audioMouthIndex != nil && !dragReaction.active && sleepSample == nil && !performanceActive && strollSample == nil && rainShelterPose == nil && scootSample == nil && frontRetreatSample == nil ? 1 : 0
        if target != motionTargetAmount {
            motionStartAmount = seatedMotionAmount(at: now)
            motionStartedAt = now; motionTargetAmount = target
        }
        guard seatedMotionTimer == nil, target > 0 || seatedMotionAmount(at: now) > 0 || headPatActive else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.advanceHeadPat()
            if !self.akimboActive { self.needsDisplay = true }
            if !self.headPatActive && self.motionTargetAmount == 0 && ProcessInfo.processInfo.systemUptime - self.motionStartedAt >= 0.25 {
                self.seatedMotionTimer?.invalidate(); self.seatedMotionTimer = nil
            }
        }
        seatedMotionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { animationTimer?.invalidate(); seatedMotionTimer?.invalidate(); gazeTimer?.invalidate(); seatedRecoveryTimer?.invalidate(); typewriterTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if mode == .character {
            drawCharacter()
            onCharacterDrawn?()
            return
        }
        let box = bubbleFrame
        drawBubbleSurface(in: box)

        if mode != .bubble { drawCharacter() }

        let width = box.width - 48 * layoutScale
        let attributed = NSAttributedString(string: displayedText, attributes: textAttributes)
        drawOutlined(attributed, in: NSRect(x: box.minX + 24 * layoutScale, y: box.minY + (compactStack ? 12 : 18) * layoutScale + captionFooterHeight,
                                           width: width, height: ceil(textSize(for: bounds.width).height)))
        guard showsCaptionHeader else { return }
        if !conversationLinkFrame.isEmpty {
            drawOutlined(NSAttributedString(string: headerPrefix, attributes: headerAttributes), in: headerPrefixFrame)
            drawOutlined(conversationLinkCaption, in: conversationLinkTextFrame)
            return
        }
        let headerParagraph = NSMutableParagraphStyle()
        headerParagraph.alignment = .center
        headerParagraph.lineBreakMode = .byTruncatingTail
        let header: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10 * layoutScale, weight: .semibold),
            .foregroundColor: isLive ? NSColor(calibratedHue: themeHue, saturation: 0.3, brightness: 1, alpha: 1) : NSColor.white.withAlphaComponent(0.65),
            .kern: 0.5 * layoutScale, .paragraphStyle: headerParagraph
        ]
        drawOutlined(NSAttributedString(string: context, attributes: header),
                     in: NSRect(x: box.minX + 18 * layoutScale, y: box.maxY - (compactStack ? 22 : 28) * layoutScale,
                                width: box.width - (showsCaptionClose ? 66 : 36) * layoutScale, height: 15 * layoutScale))
    }

    /// Shared by the interactive question: identical outline, tail and palette.
    func drawBubbleSurface(in box: NSRect, opaque: Bool = false) {
        let path = speechBubble(box)
        NSColor(calibratedHue: themeHue, saturation: 0.64, brightness: 0.25, alpha: opaque ? 1 : backdrop).setFill()
        path.fill()
        NSColor(calibratedHue: themeHue, saturation: 0.42, brightness: 0.95, alpha: 0.5).setStroke()
        path.lineWidth = 0.8 * layoutScale; path.stroke()

    }

    func height(for width: CGFloat) -> CGFloat {
    #if !VIBECUTE_RELEASE
        if mode == .character,let renderer=cutoutRenderer {return renderer.displaySize.height*layoutScale}
    #endif
        if mode == .character { return characterHeight + performanceHeadroom + 16 * layoutScale }
        return bubbleBottom + ceil(textSize(for: width).height)
            + ((compactStack ? 24 : 36) + (showsCaptionHeader ? 22 : 0)) * layoutScale + bubbleTop + captionFooterHeight
    }

    var backdropSprite: (CGImage, NSRect)? {
        guard let mascot else { return nil }
        if let pose = hoodieSingingPose, OrangeHoodiePerformance.shared.available,
           let image = OrangeHoodiePerformance.shared.frames[pose.blend < 0.5 ? pose.first : pose.second]
            .cgImage(forProposedRect:nil,context:nil,hints:nil) {
            let h = characterHeight
            return (image,NSRect(x:bounds.midX-h*0.875/2,y:8*layoutScale,width:h*0.875,height:h*1.25))
        }
        if let sample = sleepSample,
           let image = DeepSeekSleepArtwork.shared.image(for: sample)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (image, seatedSpriteRect)
        }
        if !usesPinkBear, mascotKind == .deepseek, let index = performanceFrameIndex,
           DeepSeekPerformance.shared.frames.indices.contains(index),
           let image = DeepSeekPerformance.shared.frames[index].cgImage(forProposedRect:nil,context:nil,hints:nil) {
            let h = characterHeight
            return (image,NSRect(x:bounds.midX-h*0.875/2,y:8*layoutScale,width:h*0.875,height:h*1.25))
        }
        if hasScootRestPose, let rest = backdropRestSprite { return rest }
        guard let image = mascot.frames.first?.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        return (image,seatedSpriteRect)
    }

    var backdropRestSprite: (CGImage, NSRect)? {
        guard !usesPinkBear, mascotKind == .deepseek,
              let image = DeepSeekScoot.shared.frames.last?.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        let rect = seatedSpriteRect
        return (image,NSRect(x:rect.midX-rect.width*448/384/2,y:rect.minY,width:rect.width*448/384,height:rect.height))
    }

    var seatedSpriteRect: NSRect {
        let height = characterHeight
        return NSRect(x:bounds.midX-height*0.75/2,y:8*layoutScale,width:height*0.75,height:height)
    }

    private func drawCharacter(includeEffects: Bool = true) {
        guard showsMascot else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.concatenate(dragReaction.transform(in: seatedSpriteRect, scale: layoutScale))
        if dragReaction.active, let frame = dragReaction.frameIndex, CharacterDragArtwork.shared.available {
            CharacterDragArtwork.shared.draw(frame:frame,in:seatedSpriteRect)
            return
        }
        if let pose = rainShelterPose {
            DeepSeekRainArtwork.shared.draw(frame:pose.frame,mirrored:pose.mirrored,in:bounds,scale:layoutScale)
            return
        }
        if let sample = sleepSample {
            DeepSeekSleepArtwork.shared.draw(sample, in: seatedSpriteRect)
            return
        }
        if let frame = akimboFrame {
            AkimboArtwork.shared.draw(frame: frame, in: seatedSpriteRect, mouth: akimboSpeech.mouth, animation: mascot)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let pat = headPatReactionSample
        if let pat {
            NSGraphicsContext.saveGraphicsState()
            let rect = seatedSpriteRect
            NSGraphicsContext.current?.cgContext.concatenate(HeadPatReaction.transform(pat,
                anchor: NSPoint(x: rect.midX, y: rect.minY), scale: layoutScale))
        }
        defer {
            if let pat {
                NSGraphicsContext.restoreGraphicsState()
                if includeEffects { HeadPatReaction.drawHearts(pat, head: headPatRegion, bounds: bounds, scale: layoutScale) }
            }
        }
    #if !VIBECUTE_RELEASE
        if let cutoutRenderer { cutoutRenderer.draw(in: NSGraphicsContext.current!.cgContext); return }
    #endif
        guard let mascot else { return }
        if let screenEdgeDock {
            ScreenEdgeDock.draw(frame: screenEdgePlayback?.loopFrame ?? 0,
                transition: screenEdgePlayback?.transitionFrame, in: bounds, side: screenEdgeDock, scale: layoutScale,
                peekLean: screenEdgePlayback?.peekLean ?? 0)
            return
        }
        let height = characterHeight, width = height * 0.75
        let rect = NSRect(x: bounds.midX - width / 2, y: 8 * layoutScale, width: width, height: height)
        if mascotKind == .orangeHoodie, let pose = hoodieScootPose {
            OrangeHoodieScoot.draw(pose,frame:hoodieScootFrame,in:rect)
            return
        }
        if mascotKind == .deepseek, let sample = frontRetreatSample, DeepSeekFrontRetreat.shared.available {
            DeepSeekFrontRetreat.shared.draw(sample,animation:mascot,
                in:NSRect(x:bounds.midX-height*0.875/2,y:rect.minY,width:height*0.875,height:height*1.25),
                fromScootRest:frontRetreatFromScootRest,entryImage:frontRetreatEntryImage,entryRect:bounds)
            return
        }
        if mascotKind == .deepseek, let sample = scootSample, DeepSeekScoot.shared.available {
            DeepSeekScoot.shared.draw(sample, animation: mascot, in: rect)
            return
        }
        if mascotKind == .deepseek, let sample = strollSample, DeepSeekStroll.shared.available {
            NSGraphicsContext.saveGraphicsState()
            if strollMirrored && sample.isSideFacing {
                NSGraphicsContext.current?.cgContext.translateBy(x:bounds.midX*2,y:0)
                NSGraphicsContext.current?.cgContext.scaleBy(x:-1,y:1)
            }
            DeepSeekStroll.shared.draw(sample, animation: mascot,
                in: NSRect(x: bounds.midX-height*0.875/2, y: rect.minY,
                           width:height*0.875,height:height*1.25),
                fromScootRest:strollFromScootRest,entryImage:strollEntryImage,entryRect:bounds)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if mascotKind == .orangeHoodie, let pose = hoodieSingingPose, OrangeHoodiePerformance.shared.available {
            OrangeHoodiePerformance.shared.draw(pose:pose,mouth:audioMouthIndex,
                in:NSRect(x:bounds.midX-height*0.875/2,y:rect.minY,width:height*0.875,height:height*1.25))
            return
        }
        if mascotKind == .deepseek, let index = performanceFrameIndex, DeepSeekPerformance.shared.available {
            NSGraphicsContext.saveGraphicsState()
            if performanceMirrored && index >= DeepSeekPerformance.singingStepStart {
                NSGraphicsContext.current?.cgContext.translateBy(x:bounds.midX*2,y:0)
                NSGraphicsContext.current?.cgContext.scaleBy(x:-1,y:1)
            }
            DeepSeekPerformance.shared.draw(frame: index, mouth: audioMouthIndex, animation: mascot,
                in: NSRect(x: bounds.midX - height * 0.875 / 2, y: rect.minY,
                           width: height * 0.875, height: height * 1.25))
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if mascotKind == .deepseek && hasScootRestPose {
            // Keep the exact landing pose on the first frame, then return to the
            // ordinary thinking loop at the same scale and floor anchor.
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            context.setAlpha(1 - seatedRecoveryProgress)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            DeepSeekScoot.shared.drawRest(animation:mascot,mouth:audioMouthIndex,in:rect,at:now,
                motionAmount:seatedMotionAmount(at:now))
            context.endTransparencyLayer(); context.restoreGState()
            if seatedRecoveryProgress > 0 {
                context.saveGState(); context.setAlpha(seatedRecoveryProgress)
                context.setBlendMode(.plusLighter)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                mascot.drawSeated(frame: mascotFrameIndex, mouth: audioMouthIndex, in: rect,
                    at: now, motionAmount: seatedMotionAmount(at: now), thinking: mascotAnimating)
                context.endTransparencyLayer(); context.restoreGState()
            }
            return
        }
        mascot.drawSeated(frame: pat?.frame ?? (seatedGazeActive || audioMouthIndex == nil ? mascotFrameIndex : 0),
            mouth: audioMouthIndex, in: rect, at: now, motionAmount: seatedMotionAmount(at: now),
            gaze: pat == nil && seatedGazeActive ? gaze.position : nil, thinking: pat != nil || mascotAnimating)
    }
}

struct HoverMetricsRow: Equatable {
    let name: String
    let speed: Double?
    let quota: String?
    var compactQuota: String {
        guard let quota, !quota.isEmpty else { return "额度 —" }
        return quota.replacingOccurrences(of: "剩余 ", with: "")
            .replacingOccurrences(of: "剩余", with: "")
            .replacingOccurrences(of: "账户余额", with: "余额")
            .replacingOccurrences(of: " · ", with: " / ")
            .replacingOccurrences(of: "\n", with: " / ")
    }
    var compactSpeed: String {
        guard let speed, speed.isFinite, speed >= 0 else { return "- tok/s" }
        return String(format: "%.1f tok/s", speed)
    }
    var compactLine: String { "\(name) · \(compactQuota) · \(compactSpeed)" }
}

/// Prepared only when metric data changes; one cached line per Harness.
private final class HoverMetricsCard: NSTextField {
    override var isFlipped: Bool { false }
    private var rows: [NSAttributedString] = []
    private var preparedWidth: CGFloat = 260
    var cardSize: NSSize { NSSize(width: preparedWidth, height: 16 + CGFloat(rows.count) * 28) }
    private let blue = NSColor(calibratedRed: 0.53, green: 0.8, blue: 1, alpha: 1)
    private let secondary = NSColor(calibratedRed: 0.66, green: 0.75, blue: 0.81, alpha: 1)

    func prepare(_ values: [HoverMetricsRow]) {
        rows = values.map { value in
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let text = NSMutableAttributedString(string: value.compactLine,
                attributes: [.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                             .foregroundColor: secondary])
            text.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: (value.name as NSString).length))
            text.addAttribute(.foregroundColor, value: blue,
                range: NSRange(location: text.length - (value.compactSpeed as NSString).length, length: (value.compactSpeed as NSString).length))
            return text
        }
        preparedWidth = max(260, (rows.map { $0.size().width }.max() ?? 0).rounded(.up) + 28)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        NSGradient(starting: NSColor(calibratedRed: 0.065, green: 0.11, blue: 0.14, alpha: 0.96),
                   ending: NSColor(calibratedRed: 0.09, green: 0.15, blue: 0.18, alpha: 0.96))?.draw(in: path, angle: -60)
        blue.withAlphaComponent(0.28).setStroke(); path.lineWidth = 1; path.stroke()
        var top = bounds.height - 8
        for row in rows {
            row.draw(at: NSPoint(x: 14, y: top - 22))
            top -= 28
        }
    }
}

final class OverlayController {
    private var akimboDialogue: AkimboDialogue?
    var akimboDialogueDiagnostics: [String: Any] {
        let frame = akimboDialogue?.panel.frame ?? .zero
        return ["visible": akimboDialogue?.panel.isVisible ?? false,
                "revealedCharacters": akimboDialogue?.view.captionRevealedCharacterCount ?? 0,
                "typewriterRunning": akimboDialogue?.view.captionTypewriterRunning ?? false,
                "mouthIndex": subtitle.akimboMouthIndex ?? -1,
                "text": akimboDialogue?.view.text ?? "", "x": frame.minX, "y": frame.minY,
                "width": frame.width, "height": frame.height,
                "ignoresMouseEvents": akimboDialogue?.panel.ignoresMouseEvents ?? true]
    }
    var onboardingDialogueVisible = false {
        didSet { if oldValue != onboardingDialogueVisible { refreshAkimboDialogue() } }
    }
    private func refreshAkimboDialogue() {
        if subtitle.akimboActive { hideHoverMetrics() }
        guard !onboardingDialogueVisible, subtitle.akimboActive, panel.isVisible else { akimboDialogue?.hide(); refreshSpeedHover(); return }
        if akimboDialogue == nil {
            let dialogue = AkimboDialogue(parent: panel)
            dialogue.onMouthProgress = { [weak subtitle = subtitle] utterance, revealed, typing in
                subtitle?.updateAkimboSpeech(utterance: utterance, revealed: revealed, typing: typing)
            }
            akimboDialogue = dialogue
        }
        akimboDialogue?.show(parent: panel, sprite: subtitle.seatedSpriteRect, scale: subtitle.layoutScale, utterance: subtitle.akimboUtterance)
    }
    let panel: SubtitlePanel
    let subtitle = SubtitleView()
    private var questionView: QuestionReplyView?
    private var showingQuestion = false
    private var presented = false
    private(set) var captionCloseButton: BubbleReplyButton?
    private var onCaptionClose: (() -> Void)?
    var captionCloseVisible: Bool { panel.isVisible && captionCloseButton?.isHidden == false && captionCloseButton?.window === panel }
    private(set) var conversationButton: ConversationLinkButton?
    private var onOpenConversation: (() -> String?)?
    private var speedPanel: NSPanel?
    private var speedLabel: HoverMetricsCard?
    private var metricsSpinner: NSProgressIndicator?
    private var metricsRefreshing = false
    private var metricsHovering = false
    var onMetricsHover: (() -> Void)?
    var isPointerOverAnyCharacter: ((NSPoint) -> Bool)?
    // One resting screen anchor per controller, refreshed on pose/scale changes.
    // Native frame alignment can round the requested reveal displacement.
    private var edgeHoverAnchor: (side: ScreenEdgeDock.Side, scale: CGFloat, width: CGFloat, x: CGFloat)?
    func refreshCharacterMouseTransparency(at pointer: NSPoint? = nil, leftButtonDown: Bool? = nil,
                                          recognizeHeadPat: Bool = false,
                                          pointerTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard panel.tracksCharacterDrag else { return }
        if akimboDialogue != nil { refreshAkimboDialogue() }
        let point = pointer ?? NSEvent.mouseLocation
        let hit = panel.isVisible && panel.frame.contains(point)
            && subtitle.containsVisibleCharacter(at: subtitle.convert(panel.convertPoint(fromScreen: point), from: nil))
        if recognizeHeadPat {
            subtitle.observeHeadPat(at: subtitle.convert(panel.convertPoint(fromScreen: point), from: nil),
                pressed: panel.isManuallyDragging || (leftButtonDown ?? (NSEvent.pressedMouseButtons != 0)),
                visibleHit: hit, now: pointerTime)
        }
        if let side = subtitle.screenEdgeDock {
            let pressed = leftButtonDown ?? (NSEvent.pressedMouseButtons & 1 != 0)
            // Keep both endpoint silhouettes active while peeking so a pointer
            // can follow the revealed face without flickering between frames.
            let local = subtitle.convert(panel.convertPoint(fromScreen: point), from: nil)
            let direction: CGFloat = side == .left ? 1 : -1
            let reveal = direction * ScreenEdgeDock.peekRevealWidth(scale: subtitle.layoutScale)
            let lean = subtitle.screenEdgePlayback?.peekLean ?? 0
            if subtitle.screenEdgePlayback?.phase != .peeking { edgeHoverAnchor = nil }
            if lean == 0 || edgeHoverAnchor?.side != side || edgeHoverAnchor?.scale != subtitle.layoutScale
                || edgeHoverAnchor?.width != panel.frame.width {
                edgeHoverAnchor = (side, subtitle.layoutScale, panel.frame.width, panel.frame.minX - reveal * lean)
            }
            let restingPoint = NSPoint(x: local.x + panel.frame.minX - (edgeHoverAnchor?.x ?? panel.frame.minX), y: local.y)
            let peekPoint = NSPoint(x: local.x - reveal * (1 - lean), y: local.y)
            let canFollowPeek = subtitle.screenEdgePlayback?.hovering == true
                || (subtitle.screenEdgePlayback?.peekStep ?? 0) > 0
            let hovering = panel.isVisible && subtitle.screenEdgePlayback?.phase == .peeking
                && !panel.isManuallyDragging && !pressed && panel.frame.contains(point)
                && (subtitle.containsVisibleCharacter(at: restingPoint, screenEdgeIdle: true)
                    || (canFollowPeek && (hit || subtitle.containsVisibleCharacter(at: peekPoint, screenEdgeIdle: true, peekLean: 1))))
            subtitle.setScreenEdgeHovered(hovering)
        } else { edgeHoverAnchor = nil }
        let ignores = !panel.isMovableByWindowBackground || (!panel.isManuallyDragging && !hit)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }
    private var globalHoverMonitor: Any?
    private var localHoverMonitor: Any?
    private var speedValue: Double?
    private var hoverQuota: String?
    private var speedPlaceholder = false
    private var forceMetricsVisible = false
    private var speedText = ""
    private var customMetricsText: String?
    private var metricsRows: [HoverMetricsRow] = []
    var hoverCaptionTopOffset: CGFloat?
    private var metricsCaptionTopOffset: CGFloat?
    private var metricsScreen = NSRect.zero
    private(set) var metricsLayoutCount = 0
    private var speedAnchor = NSRect.zero
    private(set) var speedIsVisible = false
    var hoverMetricsText: String { speedLabel?.stringValue ?? "" }
    var hoverMetricsHeight: CGFloat { speedPanel?.frame.height ?? 0 }
    var hoverMetricsFrame: NSRect { speedPanel?.frame ?? .zero }
    var hoverMetricsWindowVisible: Bool { speedPanel?.isVisible ?? false }
    var hoverMetricsDiagnostics: [String: Any] {
        ["text": speedText, "visible": speedIsVisible, "refreshing": metricsRefreshing,
         "spinnerVisible": metricsSpinner?.isHidden == false && hoverMetricsWindowVisible,
         "globalMonitor": globalHoverMonitor != nil, "localMonitor": localHoverMonitor != nil,
         "manualDragging": panel.isManuallyDragging, "leftButtonDown": NSEvent.pressedMouseButtons & 1 != 0,
         "windowVisible": hoverMetricsWindowVisible,
         "pointerInside": panel.frame.contains(NSEvent.mouseLocation),
         "x": hoverMetricsFrame.minX, "y": hoverMetricsFrame.minY,
         "width": hoverMetricsFrame.width, "height": hoverMetricsFrame.height,
         "layoutCount": metricsLayoutCount]
    }

    func setAverageSpeed(_ speed: Double?) {
        setHoverMetrics(speed: speed, quota: nil)
    }

    func setHoverMetrics(speed: Double?, quota: String?, showSpeedPlaceholder: Bool = false, refreshing: Bool = false, text: String? = nil, rows: [HoverMetricsRow]? = nil, forceVisible: Bool = false, name: String = "测速与余额") {
        let valid = speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let preparedRows = (rows ?? [HoverMetricsRow(name: name, speed: valid, quota: quota)]).map {
            HoverMetricsRow(name: $0.name, speed: $0.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, quota: $0.quota)
        }
        let forceChanged = forceMetricsVisible != forceVisible
        forceMetricsVisible = forceVisible
        guard forceChanged || metricsRows != preparedRows || speedValue != valid || hoverQuota != quota || speedPlaceholder != showSpeedPlaceholder || metricsRefreshing != refreshing || customMetricsText != text else {
            // Reuse the existing UI refresh for stationary pointers and window
            // movement; no additional timer or monitoring process is created.
            refreshSpeedHover(); return
        }
        metricsRows = preparedRows
        speedLabel?.prepare(metricsRows)
        customMetricsText = text
        speedValue = valid
        hoverQuota = quota
        speedPlaceholder = showSpeedPlaceholder
        metricsRefreshing = refreshing
        speedText = text ?? (valid != nil || quota != nil || showSpeedPlaceholder
            ? preparedRows.map(\.compactLine).joined(separator: "\n") : "")
        if speedText.isEmpty {
            if let globalHoverMonitor { NSEvent.removeMonitor(globalHoverMonitor) }
            if let localHoverMonitor { NSEvent.removeMonitor(localHoverMonitor) }
            globalHoverMonitor = nil; localHoverMonitor = nil
            hideHoverMetrics()
            return
        }
        if globalHoverMonitor == nil {
            panel.acceptsMouseMovedEvents = true
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
            globalHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
                self?.handleHoverMouseEvent(event)
            }
            localHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                self?.handleHoverMouseEvent(event); return event
            }
        }
        refreshSpeedHover()
    }

    private func hideHoverMetrics() {
        metricsHovering = false
        if speedIsVisible { metricsSpinner?.stopAnimation(nil) }
        if let speedPanel {
            if speedPanel.isVisible { speedPanel.orderOut(nil) }
        }
        speedIsVisible = false
    }

    func handleHoverMouseEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseDragged {
            hideHoverMetrics()
        } else { refreshSpeedHover(optionDown: event.modifierFlags.contains(.option)) }
    }

    func refreshSpeedHover(at point: NSPoint? = nil, leftButtonDown: Bool? = nil, optionDown: Bool? = nil) {
        guard !speedText.isEmpty else { return }
        let pressed = leftButtonDown ?? (NSEvent.pressedMouseButtons & 1 != 0)
        let pointer = point ?? NSEvent.mouseLocation
        let allCharacters = (optionDown ?? NSEvent.modifierFlags.contains(.option))
            && (isPointerOverAnyCharacter?(pointer) ?? false)
        let hovering = panel.isVisible && subtitle.screenEdgeDock == nil && !subtitle.akimboActive && !panel.isManuallyDragging && !pressed
            && (panel.frame.contains(pointer) || (speedIsVisible && panel.frame.union(hoverMetricsFrame).contains(pointer)) || allCharacters)
        let forced = forceMetricsVisible && panel.isVisible && !panel.isManuallyDragging && !pressed
        guard hovering || forced else { hideHoverMetrics(); return }
        let enteredHover = hovering && !metricsHovering
        metricsHovering = hovering
        if enteredHover { onMetricsHover?() }
        let area = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        if speedIsVisible, speedAnchor == panel.frame, metricsScreen == area,
           metricsCaptionTopOffset == hoverCaptionTopOffset,
           speedLabel?.stringValue == speedText, metricsSpinner?.isHidden == !metricsRefreshing { return }
        speedAnchor = panel.frame; metricsScreen = area; metricsCaptionTopOffset = hoverCaptionTopOffset
        metricsLayoutCount += 1
        if speedPanel == nil {
            let child = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            child.isOpaque = false; child.backgroundColor = .clear; child.hasShadow = false
            child.ignoresMouseEvents = true; child.level = panel.level
            child.hidesOnDeactivate = false; child.isReleasedWhenClosed = false
            child.collectionBehavior = panel.collectionBehavior
            let label = HoverMetricsCard(labelWithString: "")
            label.maximumNumberOfLines = 0; label.cell?.wraps = true; label.cell?.isScrollable = false
            label.font = .systemFont(ofSize: 12); label.textColor = .white
            label.alignment = .center; label.backgroundColor = .clear
            label.drawsBackground = false
            label.prepare(metricsRows)
            let container = NSView(frame: .zero)
            container.addSubview(label)
            let spinner = NSProgressIndicator(frame: .zero)
            spinner.style = .spinning; spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.setAccessibilityLabel("账户余额刷新中")
            container.addSubview(spinner); metricsSpinner = spinner
            child.contentView = container; panel.addChildWindow(child, ordered: .above)
            speedPanel = child; speedLabel = label
        }
        let text = speedText
        speedLabel?.stringValue = text
        var size = speedLabel?.cardSize ?? NSSize(width: 260, height: 44)
        if metricsRefreshing { size.width += 24 }
        let frame = Self.hoverMetricsPlacement(character: panel.frame, size: size, area: area,
            captionTop: hoverCaptionTopOffset.map { panel.frame.maxY + $0 })
        speedPanel?.setFrame(frame, display: true)
        speedLabel?.frame = NSRect(origin: .zero, size: size)
        metricsSpinner?.frame = NSRect(x: size.width - 32, y: 12, width: 14, height: 14)
        metricsSpinner?.isHidden = !metricsRefreshing
        if metricsRefreshing { metricsSpinner?.startAnimation(nil) }
        else { metricsSpinner?.stopAnimation(nil) }
        speedPanel?.setAccessibilityLabel(text)
        if let speedPanel, speedPanel.parent !== panel { panel.addChildWindow(speedPanel, ordered: .above) }
        if let speedPanel, !speedPanel.isVisible { speedPanel.order(.above, relativeTo: panel.windowNumber) }
        speedIsVisible = true
    }
    /// Prefer the space below the character; side placement stays beneath the
    /// caption's top edge. Geometry work runs only when the existing hover cache expires.
    static func hoverMetricsPlacement(character: NSRect, size: NSSize, area: NSRect, captionTop: CGFloat?) -> NSRect {
        let margin: CGFloat = 8, gap: CGFloat = 12
        let usable = area.insetBy(dx: margin, dy: margin)
        let width = min(size.width, usable.width), height = min(size.height, usable.height)
        let xBelow = min(max(usable.minX, character.midX - width / 2), usable.maxX - width)
        let yBelow = character.minY - gap - height
        if yBelow >= usable.minY {
            return NSRect(x: xBelow, y: yBelow, width: width, height: height)
        }
        let right = character.maxX + gap
        let left = character.minX - gap - width
        let x = right + width <= usable.maxX ? right : left
        let ceiling = min(usable.maxY, captionTop ?? character.maxY)
        let top = min(character.midY + height / 2, ceiling)
        return NSRect(x: min(max(usable.minX, x), usable.maxX - width),
            y: max(usable.minY, top - height), width: width, height: height)
    }
    private var transitionTimer: Timer?
    private var transitionStart: TimeInterval = 0
    private let transitionDuration: TimeInterval = 0.42
    private var transitionVelocity = NSRect.zero
    private var currentVelocity = NSRect.zero
    private var currentAcceleration = NSRect.zero
    private var transitionAcceleration = NSRect.zero
    private var transitionControlsFrom: CGFloat = 0
    private var transitionFrom = NSRect.zero
    private var targetFrame = NSRect.zero
    private var screenTailTarget: NSPoint?
    private(set) var transitionFrameCount = 0
    private(set) var transitionWorkSeconds: TimeInterval = 0
    var isQuestionTransitionRunning: Bool { transitionTimer != nil }
    var layoutHeight: CGFloat { targetFrame.height }
    private var lastPlacement = ""
    private var lastOrigin: NSPoint?
    private var wasMovable = false
    private var manualOffset = NSPoint.zero
    private var trackedOrigin: NSPoint {
        NSPoint(x: panel.frame.minX - (panel.parent?.frame.minX ?? 0),
                y: panel.frame.minY - (panel.parent?.frame.minY ?? 0))
    }

    init(interactive: Bool = false) {
        panel = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 130),
                              styleMask: interactive ? [.borderless] : [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.level = .statusBar
        // Match the asset/compositor contract. Display-list replay otherwise
        // converts every full source image to the screen profile, including
        // the original pose's two clipped eye-white draws.
        panel.colorSpace = .sRGB
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.contentView = subtitle
        subtitle.setAccessibilityRole(.staticText)
        panel.setAccessibilityLabel("VibeCute")
        panel.onManualDragStateChanged = { [weak self] in
            self?.refreshSpeedHover(); self?.refreshCharacterMouseTransparency()
        }
        panel.characterHitTest = { [weak self] point in
            guard let self else { return false }
            return self.subtitle.containsVisibleCharacter(at: self.subtitle.convert(point, from: nil))
        }
        subtitle.onControlLayout = { [weak self] in
            self?.updateConversationControl()
            self?.updateCaptionCloseControl()
        }
        subtitle.onCharacterDrawn = { [weak self] in self?.refreshCharacterMouseTransparency() }
        subtitle.onAkimboChanged = { [weak self] in self?.refreshAkimboDialogue() }
    }

    deinit {
        hide()
        panel.parent?.removeChildWindow(panel)
        for child in panel.childWindows ?? [] {
            child.orderOut(nil)
            panel.removeChildWindow(child)
        }
        transitionTimer?.invalidate()
        if let globalHoverMonitor { NSEvent.removeMonitor(globalHoverMonitor) }
        if let localHoverMonitor { NSEvent.removeMonitor(localHoverMonitor) }
    }

    private(set) var frameApplicationCount = 0
    private var appliedFrame: (requested: NSRect, actual: NSRect)?
    private func applyFrame(_ frame: NSRect) {
        // AppKit can round a requested fractional frame. Reuse it only while
        // both the request and the actual native geometry remain unchanged.
        let reused = appliedFrame.map { $0.requested == frame && $0.actual == panel.frame } ?? false
        if panel.frame != frame && !reused {
            panel.setFrame(frame, display: false)
            frameApplicationCount += 1
            subtitle.needsDisplay = true
            questionView?.needsDisplay = true
        }
        appliedFrame = (frame, panel.frame)
        let contentFrame = NSRect(origin: .zero, size: panel.frame.size)
        if subtitle.frame != contentFrame { subtitle.frame = contentFrame; subtitle.needsDisplay = true }
        lastOrigin = trackedOrigin
        let tail = screenTailTarget.map {
            NSPoint(x: $0.x - panel.frame.minX, y: $0.y - panel.frame.minY)
        }
        if subtitle.tailTarget != tail { subtitle.tailTarget = tail; subtitle.needsDisplay = true }
        // The interactive card draws through a detached renderer, whose native
        // needsDisplay flag is not reliable while it is outside the view tree.
        // Retain card invalidation so style/tail changes keep their old behavior.
        questionView?.needsDisplay = true
        // Controls appear once there is room to read and use them. No control
        // reconstruction is needed for a height-only transition.
        if transitionTimer == nil { questionView?.controlsOpacity = 1 }
        // Layout remains fixed at the target text width while the window reveals it.
        updateConversationControl()
        updateCaptionCloseControl()
    }

    private func updateCaptionCloseControl() {
        guard presented, panel.isVisible, !showingQuestion, subtitle.mode == .bubble, onCaptionClose != nil else {
            captionCloseButton?.isHidden = true; return
        }
        if captionCloseButton == nil {
            let button = BubbleReplyButton(title: "×", target: self, action: #selector(closeCaption))
            button.isBordered = false; button.font = .systemFont(ofSize: 18)
            button.identifier = NSUserInterfaceItemIdentifier("close-caption-bubble")
            button.setAccessibilityLabel("关闭字幕气泡")
            button.toolTip = "关闭这条字幕；后续新消息仍会显示"
            button.autoresizingMask = [.minXMargin, .minYMargin]
            subtitle.addSubview(button)
            captionCloseButton = button
        }
        let scale = subtitle.layoutScale, box = subtitle.bubbleFrame
        let rect = NSRect(x: box.maxX - 30 * scale, y: box.maxY - 30 * scale, width: 24 * scale, height: 24 * scale)
        if captionCloseButton?.frame != rect { captionCloseButton?.frame = rect }
        if captionCloseButton?.accentHue != subtitle.themeHue {
            captionCloseButton?.accentHue = subtitle.themeHue
            captionCloseButton?.needsDisplay = true
        }
        captionCloseButton?.isHidden = false
    }

    @objc private func closeCaption() { onCaptionClose?() }

    private func updateConversationControl() {
        subtitle.prepareConversationHeader()
        guard presented, panel.isVisible, !showingQuestion, onOpenConversation != nil, !subtitle.conversationLinkFrame.isEmpty else {
            conversationButton?.isHidden = true
            return
        }
        if conversationButton == nil {
            let button = ConversationLinkButton(title: "", target: self, action: #selector(openConversation))
            button.isBordered = false; button.renderer = subtitle
            button.autoresizingMask = [.minYMargin]
            subtitle.addSubview(button)
            conversationButton = button
        }
        guard let conversationButton else { return }
        let rect = subtitle.conversationLinkFrame
        if conversationButton.frame != rect { conversationButton.frame = rect }
        conversationButton.caption = subtitle.conversationLinkCaption
        let textFrame = subtitle.conversationLinkTextFrame
        conversationButton.captionFrame = NSRect(x: textFrame.minX - rect.minX,
            y: conversationButton.isFlipped ? rect.maxY - textFrame.maxY : textFrame.minY - rect.minY,
            width: textFrame.width, height: textFrame.height)
        let hint: String
        switch subtitle.conversationSourceName {
        case "DeepSeek Harness": hint = "打开 DeepSeek Harness 窗口"
        case "Claude Code": hint = "跳转到 Claude Code 终端：" + subtitle.conversationTitle
        case "OpenCode": hint = "跳转到 OpenCode 终端：" + subtitle.conversationTitle
        case "WorkBuddy": hint = "打开 WorkBuddy 对话：" + subtitle.conversationTitle
        case "豆包工作": hint = "打开豆包工作窗口：" + subtitle.conversationTitle
        default: hint = "打开 Codex 对话：" + subtitle.conversationTitle
        }
        conversationButton.setAccessibilityLabel(hint)
        conversationButton.toolTip = hint
        conversationButton.needsDisplay = true
        conversationButton.isHidden = false
    }

    @objc private func openConversation() {
        conversationButton?.flash()
        if let error = onOpenConversation?() { conversationButton?.toolTip = error; NSSound.beep() }
    }

    private func advanceTransition() {
        guard presented else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let progress = min(1, (started - transitionStart) / transitionDuration)
        let p2 = progress * progress, p3 = p2 * progress, p4 = p3 * progress, p5 = p4 * progress
        // Quintic endpoints have zero velocity and acceleration. On reversal,
        // preserve both derivatives instead of restarting from a standstill.
        let eased = 10 * p3 - 15 * p4 + 6 * p5
        let velocityBasis = progress - 6 * p3 + 8 * p4 - 3 * p5
        let accelerationBasis = (p2 - 3 * p3 + 3 * p4 - p5) / 2
        let q1 = 30 * p2 - 60 * p3 + 30 * p4
        let q2 = 60 * progress - 180 * p2 + 120 * p3
        let r1 = 1 - 18 * p2 + 32 * p3 - 15 * p4
        let r2 = -36 * progress + 96 * p2 - 60 * p3
        let a1 = progress - 4.5 * p2 + 6 * p3 - 2.5 * p4
        let a2 = 1 - 9 * progress + 18 * p2 - 10 * p3
        let duration = transitionDuration
        func mix(_ from: CGFloat, _ to: CGFloat, _ velocity: CGFloat, _ acceleration: CGFloat) -> CGFloat {
            from + (to - from) * eased + velocity * duration * velocityBasis + acceleration * duration * duration * accelerationBasis
        }
        func speed(_ from: CGFloat, _ to: CGFloat, _ velocity: CGFloat, _ acceleration: CGFloat) -> CGFloat {
            (to - from) * q1 / duration + velocity * r1 + acceleration * duration * a1
        }
        func acceleration(_ from: CGFloat, _ to: CGFloat, _ velocity: CGFloat, _ initial: CGFloat) -> CGFloat {
            (to - from) * q2 / (duration * duration) + velocity * r2 / duration + initial * a2
        }
        let from = transitionFrom, to = targetFrame, v = transitionVelocity, a = transitionAcceleration
        let frame = NSRect(x: mix(from.minX, to.minX, v.origin.x, a.origin.x), y: mix(from.minY, to.minY, v.origin.y, a.origin.y),
            width: mix(from.width, to.width, v.size.width, a.size.width), height: mix(from.height, to.height, v.size.height, a.size.height))
        currentVelocity = NSRect(x: speed(from.minX, to.minX, v.origin.x, a.origin.x), y: speed(from.minY, to.minY, v.origin.y, a.origin.y),
            width: speed(from.width, to.width, v.size.width, a.size.width), height: speed(from.height, to.height, v.size.height, a.size.height))
        currentAcceleration = NSRect(x: acceleration(from.minX, to.minX, v.origin.x, a.origin.x), y: acceleration(from.minY, to.minY, v.origin.y, a.origin.y),
            width: acceleration(from.width, to.width, v.size.width, a.size.width), height: acceleration(from.height, to.height, v.size.height, a.size.height))
        applyFrame(frame)
        let fade = min(1, max(0, (progress - 0.2) / 0.65))
        let alpha = fade * fade * (3 - 2 * fade)
        questionView?.controlsOpacity = transitionControlsFrom + (1 - transitionControlsFrom) * alpha
        transitionFrameCount += 1
        transitionWorkSeconds += ProcessInfo.processInfo.systemUptime - started
        if progress >= 1 {
            transitionTimer?.invalidate(); transitionTimer = nil
            currentVelocity = .zero; currentAcceleration = .zero; questionView?.controlsOpacity = 1
        }
    }

    func update(text: String, context: String, title: String, live: Bool, mascot: CaptionMascot?, font: Double, opacity: Double,
                bottom: Double, screenIndex: Int, movable: Bool, visible: Bool,
                anchor: NSPoint? = nil, availableWidth: CGFloat? = nil, maximumHeight: CGFloat? = nil,
                scale: CGFloat = 1, hue: CGFloat = 0.57, mode: OverlayMode = .combined,
                tailTarget: NSPoint? = nil, compactStack: Bool = false, fixedWidth: CGFloat? = nil,
                resetManualOffset: Bool = false, restoredAnchor: NSPoint? = nil, pinkBear: Bool = false,
                typewriterID: String? = nil, typewriterCharactersPerSecond: Double = 25, tokenSpeed: Double? = nil,
                question: UserQuestionRequest? = nil,
                onOpenConversation: (() -> String?)? = nil,
                onQuestionClose: (() -> Void)? = nil,
                onCaptionClose: (() -> Void)? = nil,
                onQuestionReply: (([String: String], @escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
                cutoutHair: String? = nil, allowOutsideScreen: Bool = false) {
        guard visible, !NSScreen.screens.isEmpty else { hide(); return }
        presented = true
        let screens = NSScreen.screens
        let screen = screens[min(max(0, screenIndex), screens.count - 1)]
        let area = screen.visibleFrame
        let questionChanged = showingQuestion != (question != nil)
        showingQuestion = question != nil
        self.onOpenConversation = onOpenConversation
        self.onCaptionClose = onCaptionClose
        subtitle.showsCaptionClose = question == nil && mode == .bubble && onCaptionClose != nil
        subtitle.conversationTitle = question == nil && onOpenConversation != nil ? title : ""
        panel.acceptsQuestionInput = question != nil
        if let question, let onQuestionReply {
            let view = questionView ?? QuestionReplyView(); questionView = view
            view.bubbleRenderer = subtitle
            view.configure(question, title: title, onOpenConversation: onOpenConversation,
                           onClose: onQuestionClose, onSubmit: onQuestionReply)
            if panel.contentView !== view {
                panel.contentView = view
                panel.initialFirstResponder = view
                panel.makeFirstResponder(view)
            }
            subtitle.pauseTypewriter()
        } else {
            if panel.contentView !== subtitle { panel.contentView = subtitle }
            questionView = nil
        }
        subtitle.setCaption(text, typewriterID: typewriterID,
                            charactersPerSecond: typewriterCharactersPerSecond, tokensPerSecond: tokenSpeed)
        subtitle.context = context; subtitle.isLive = live
        subtitle.conversationSourceName = context.hasPrefix("DeepSeek Harness") || context.hasPrefix("DSH  ·") ? "DeepSeek Harness"
            : context.hasPrefix("Claude Code") ? "Claude Code" : context.hasPrefix("OpenCode") ? "OpenCode"
            : context.hasPrefix("WorkBuddy") ? "WorkBuddy" : context.hasPrefix("豆包工作") ? "豆包工作" : "Codex"
        subtitle.mode = mode
        panel.tracksCharacterDrag = mode == .character
        if mode == .character { panel.acceptsMouseMovedEvents = true }
        if (subtitle.tailTarget != nil) != (tailTarget != nil) {
            subtitle.tailTarget = tailTarget
            subtitle.needsDisplay = true
        }
        subtitle.compactStack = compactStack
        subtitle.setMascot(mascot, animating: live, pinkBear: pinkBear)
    #if !VIBECUTE_RELEASE
        if let cutoutHair { subtitle.cutoutRenderer?.setHair(cutoutHair) }
    #endif
        subtitle.layoutScale = scale; subtitle.themeHue = hue
        subtitle.fontSize = font * scale; subtitle.backdrop = opacity
        var width = question == nil ? fixedWidth ?? subtitle.preferredWidth(available: availableWidth ?? area.size.width)
            : min(420, max(280, availableWidth ?? area.size.width - 32))
        if let maximumHeight, question == nil {
            for _ in 0..<3 where subtitle.height(for: width) > maximumHeight {
                let ratio = maximumHeight / subtitle.height(for: width) * 0.98
                subtitle.layoutScale *= ratio; subtitle.fontSize *= ratio
                width = subtitle.preferredWidth(available: availableWidth ?? area.size.width)
            }
        }
        let panelLabel = title.isEmpty ? "VibeCute" : "VibeCute · \(title)"
        let captionLabel = title.isEmpty ? text : title + "。" + text
        if panel.accessibilityLabel() != panelLabel { panel.setAccessibilityLabel(panelLabel) }
        if subtitle.accessibilityLabel() != captionLabel { subtitle.setAccessibilityLabel(captionLabel) }
        let height = question == nil ? subtitle.height(for: width)
            : min(questionView?.prepare(width: width) ?? 320, area.size.height - 48)
        let interactiveSizeChanged = question != nil && abs(targetFrame.height - height) > 0.5
        let placement = "\(screenIndex)-\(bottom)-\(area)"
        var origin = NSPoint(x: (anchor?.x ?? area.midX) - width / 2, y: anchor?.y ?? area.origin.y + bottom)
        if let restoredAnchor {
            manualOffset = NSPoint(x: restoredAnchor.x - width / 2 - origin.x,
                                   y: restoredAnchor.y - origin.y)
        } else if resetManualOffset || placement != lastPlacement {
            // A changed stack is packed from its character anchor again; old
            // individual offsets must not preserve holes left by hidden rows.
            manualOffset = .zero
        } else if wasMovable, let lastOrigin {
            manualOffset.x += trackedOrigin.x - lastOrigin.x
            manualOffset.y += trackedOrigin.y - lastOrigin.y
        }
        // A manual offset belongs to the relative anchor, so group moves and
        // message/character size changes preserve the user's placement.
        origin.x += manualOffset.x; origin.y += manualOffset.y
        if !allowOutsideScreen && !(mode == .character && (subtitle.screenEdgeDock != nil || panel.isManuallyDragging)) {
            origin.x = min(max(area.origin.x, origin.x), area.maxX - width)
        }
        if !allowOutsideScreen { origin.y = min(max(area.origin.y, origin.y), area.maxY - height) }
        lastPlacement = placement
        wasMovable = movable
        let ignoresMouse = question == nil && !movable && panel.onScrollFont == nil
            && !(mode == .bubble && (onCaptionClose != nil || onOpenConversation != nil))
        if panel.ignoresMouseEvents != ignoresMouse { panel.ignoresMouseEvents = ignoresMouse }
        if panel.isMovableByWindowBackground != movable { panel.isMovableByWindowBackground = movable }
        screenTailTarget = tailTarget
        targetFrame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        if (questionChanged || interactiveSizeChanged) && (panel.isVisible || question != nil) && mode == .bubble
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let wasTransitioning = transitionTimer != nil
            transitionTimer?.invalidate()
            transitionVelocity = wasTransitioning ? currentVelocity : .zero
            transitionAcceleration = wasTransitioning ? currentAcceleration : .zero
            transitionControlsFrom = questionChanged ? 0 : questionView?.controlsOpacity ?? 0
            if !panel.isVisible {
                applyFrame(NSRect(origin: origin, size: NSSize(width: width, height: min(height, subtitle.height(for: width)))))
            }
            transitionFrom = panel.frame; transitionStart = ProcessInfo.processInfo.systemUptime
            transitionFrameCount = 0; transitionWorkSeconds = 0
            let timer = Timer(timeInterval: 1 / Double(min(120, max(60, screen.maximumFramesPerSecond))), repeats: true) { [weak self] _ in self?.advanceTransition() }
            transitionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            applyFrame(transitionFrom)
            questionView?.controlsOpacity = transitionControlsFrom
        } else if transitionTimer == nil {
            applyFrame(targetFrame)
        } else {
            updateConversationControl(); updateCaptionCloseControl()
        }
        // Updating text or layout must not promote an already visible group.
        if !panel.isVisible {
            if let parent = panel.parent { panel.order(.above, relativeTo: parent.windowNumber) }
            else { panel.orderFrontRegardless() }
            updateConversationControl()
            updateCaptionCloseControl()
        }
        refreshCharacterMouseTransparency()
    #if !VIBECUTE_RELEASE
        subtitle.cutoutRenderer?.refreshVisibility()
    #endif
        if akimboDialogue != nil { refreshAkimboDialogue() }
    }

    /// Hide the complete caption hierarchy and cancel work that could reorder a
    /// detached control window after its bubble has disappeared.
    func hide() {
        presented = false
        transitionTimer?.invalidate(); transitionTimer = nil
        currentVelocity = .zero; currentAcceleration = .zero
        onCaptionClose = nil; onOpenConversation = nil
        forceMetricsVisible = false
        subtitle.showsCaptionClose = false
        subtitle.pauseTypewriter()
        subtitle.setMascot(nil, animating: false)
        hideHoverMetrics()
        akimboDialogue?.hide()
        conversationButton?.isHidden = true
        captionCloseButton?.isHidden = true
        panel.orderOut(nil)
    }

    func attach(to parent: NSWindow?) {
        guard panel.parent !== parent else { return }
        panel.parent?.removeChildWindow(panel)
        parent?.addChildWindow(panel, ordered: .above)
        // Parent motion is not an independent bubble drag. Keep manual offsets
        // in parent coordinates so native attachment needs no per-frame work.
        lastOrigin = trackedOrigin
    }

    /// Renders our own view only; does not capture any other app or screen content.
    func exportPreview(to url: URL) throws {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try data.write(to: url) }
    }
}
