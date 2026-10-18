import AppKit
#if canImport(CaptionCore)
import CaptionCore
#endif

struct OverlayHoverMetrics {
    let averageSpeed: Double?
    let quotaText: String?
    var refreshing = false
    var onHover: (() -> Void)? = nil
    var persistent = false
}

struct OverlayItem {
    let id: String
    let text: String
    let header: String
    let title: String
    let active: Bool
    let mascot: CaptionMascot?
    let typewriterID: String?
    let typewriterCharactersPerSecond: Double
    let question: UserQuestionRequest?
    let onOpenConversation: (() -> String?)?
    let averageSpeed: Double?
    let quotaText: String?
    let metricsRefreshing: Bool
    let onMetricsHover: (() -> Void)?
    let onQuestionReply: (([String: String], @escaping (Result<Void, Error>) -> Void) -> Void)?
    let onQuestionClose: (() -> Void)?
    let onCaptionClose: (() -> Void)?

    init(id: String, text: String, header: String, title: String, active: Bool,
         mascot: CaptionMascot?, typewriterID: String? = nil, typewriterCharactersPerSecond: Double = 25,
         question: UserQuestionRequest? = nil,
         averageSpeed: Double? = nil,
         quotaText: String? = nil,
         metricsRefreshing: Bool = false, onMetricsHover: (() -> Void)? = nil,
         onOpenConversation: (() -> String?)? = nil,
         onQuestionClose: (() -> Void)? = nil,
         onCaptionClose: (() -> Void)? = nil,
         onQuestionReply: (([String: String], @escaping (Result<Void, Error>) -> Void) -> Void)? = nil) {
        self.id = id; self.text = text; self.header = header; self.title = title
        self.active = active; self.mascot = mascot; self.typewriterID = typewriterID
        self.typewriterCharactersPerSecond = typewriterCharactersPerSecond
        self.onOpenConversation = onOpenConversation
        self.averageSpeed = averageSpeed
        self.quotaText = quotaText
        self.metricsRefreshing = metricsRefreshing; self.onMetricsHover = onMetricsHover
        self.question = question; self.onQuestionReply = onQuestionReply
        self.onQuestionClose = onQuestionClose
        self.onCaptionClose = onCaptionClose
    }
}

/// A source owns its windows, drag constraints and animation independently.
private final class CharacterOverlayGroup {
    private var panels: [String: OverlayController] = [:]
    private var appearances: [String: Int] = [:]
    private(set) var visibleIDs: [String] = []
    var onCaptionScroll: ((Double) -> Void)?
    let character = OverlayController()
    private var movementObserver: NSObjectProtocol?
    private var layingOut = false
    private var movingGroup = false
    private var lastCharacterFrame: NSRect?
    private var screenArea: NSRect?
    private var relativeGroupBounds: NSRect?
    private let measurement = SubtitleView()
    private let source: String
    private let positionStore: CharacterPositionStore?
    private var positionLoaded = false
    private var pendingPositionSave: DispatchWorkItem?
    private var temporarilyHidden = false
    private var relocating = false
    private var screenEdgeDock: ScreenEdgeDock?
    private var draggedScreenFrame: NSRect?
    private var configuredScreenIndex: Int?
    var onDockChanged: (() -> Void)?
    private var canDock: Bool { character.subtitle.mascotArtwork == "deepseek" }

    private var edgeMotionOrigin: NSPoint?
    private var edgeMotionStart: CGFloat = 0
    private var edgeExitDestination: NSPoint?
    private var edgeDragSide: ScreenEdgeDock.Side?
    private var edgeDragOrigin: NSPoint?
    private var edgeDragOffset: CGFloat = 0
    private var edgeActive: Bool { character.subtitle.screenEdgeDock != nil }

    func beginManualDrag() {
        edgeDragSide = character.subtitle.screenEdgeDock
        edgeDragOrigin = character.panel.frame.origin
        edgeDragOffset = edgeDragSide == nil ? 0 : ScreenEdgeDock.hiddenWidth(
            for: character.panel.frame.width, scale: character.subtitle.layoutScale)
            * (character.subtitle.screenEdgePlayback?.concealment ?? 1)
            - ScreenEdgeDock.peekRevealWidth(scale: character.subtitle.layoutScale)
                * (character.subtitle.screenEdgePlayback?.peekLean ?? 0)
    }
    private func moveEdgeFrame() {
        guard !character.panel.isManuallyDragging, let playback = character.subtitle.screenEdgePlayback,
              let origin = edgeMotionOrigin else { return }
        let destination: NSPoint
        let progress: CGFloat
        if playback.phase == .exiting, let exit = edgeExitDestination {
            destination = exit
            progress = edgeMotionStart > 0 ? 1 - playback.concealment / edgeMotionStart : 1
        } else if let dock = screenEdgeDock, let area = screenArea {
            destination = dock.origin(for: character.panel.frame, usableArea: area,
                scale: character.subtitle.layoutScale)
            progress = edgeMotionStart < 1 ? (playback.concealment - edgeMotionStart) / (1 - edgeMotionStart) : 1
        } else { return }
        let amount = min(1, max(0, progress))
        var reveal: CGFloat = 0
        if playback.phase != .exiting, let dock = screenEdgeDock {
            reveal = (dock.side == .left ? 1 : -1)
                * ScreenEdgeDock.peekRevealWidth(scale: character.subtitle.layoutScale) * playback.peekLean
        }
        movingGroup = true
        character.panel.setFrameOrigin(NSPoint(x: origin.x + (destination.x - origin.x) * amount + reveal,
            y: origin.y + (destination.y - origin.y) * amount))
        movingGroup = false
        lastCharacterFrame = character.panel.frame
    }
    private func edgeExited() {
        screenEdgeDock = nil; edgeMotionOrigin = nil; edgeExitDestination = nil
        onDockChanged?()
        savePosition()
    }
    func finishManualDrag(moved: Bool) {
        defer { edgeDragSide = nil; edgeDragOrigin = nil; edgeDragOffset = 0 }
        guard moved, canDock, let screen = character.panel.screen else { return }
        var logicalFrame = character.panel.frame
        if let side = edgeDragSide {
            logicalFrame.origin.x += side == .left ? edgeDragOffset : -edgeDragOffset
        }
        let next = ScreenEdgeDock.candidate(for: logicalFrame, on: screen.frame,
            screens: NSScreen.screens.map(\.frame), scale: character.subtitle.layoutScale)
        draggedScreenFrame = screen.frame; screenArea = screen.visibleFrame
        screenEdgeDock = next
        edgeMotionOrigin = character.panel.frame.origin
        if let next {
            character.subtitle.enterScreenEdge(next.side)
            edgeMotionStart = character.subtitle.screenEdgePlayback?.concealment ?? 0
            edgeExitDestination = nil
        } else if edgeActive {
            character.subtitle.exitScreenEdge()
            edgeMotionStart = character.subtitle.screenEdgePlayback?.concealment ?? 1
            edgeExitDestination = NSPoint(x: min(max(screen.frame.minX, character.panel.frame.minX),
                screen.frame.maxX - character.panel.frame.width), y: character.panel.frame.minY)
        }
        onDockChanged?()
        savePosition()
    }
    private(set) var relocationInterrupted = false
    private var expectedRelocationOrigin: CGPoint?
    var allowedOrigins: CGRect {
        guard !edgeActive else { return .null }
        guard let area = screenArea else { return .null }
        return allowedOrigins(in:area)
    }
    func allowedOrigins(in area: CGRect) -> CGRect {
        guard !edgeActive, let relative = relativeGroupBounds else { return .null }
        let minX = area.minX-relative.minX, maxX = area.maxX-relative.maxX
        let minY = area.minY-relative.minY, maxY = area.maxY-relative.maxY
        guard minX <= maxX, minY <= maxY else { return .null }
        return CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
    }
    func beginRelocation() {
        pendingPositionSave?.cancel(); pendingPositionSave = nil
        relocating = true; relocationInterrupted = false
        expectedRelocationOrigin = character.panel.frame.origin
    }
    func applyRelocation(_ sample: BackdropRelocationSample) {
        guard relocating, !relocationInterrupted else { return }
        movingGroup = true
        character.panel.setFrameOrigin(sample.origin)
        movingGroup = false
        if let screen = character.panel.screen {
            draggedScreenFrame = screen.frame; screenArea = screen.visibleFrame
        }
        expectedRelocationOrigin = character.panel.frame.origin
        lastCharacterFrame = character.panel.frame
        if character.subtitle.mascotArtwork == "blue-fish-orange-hoodie" {
            character.subtitle.setOrangeHoodieScoot(sample.scoot.map {
                OrangeHoodieScoot.Pose(progress:$0.pushPhase,direction:sample.mirrored ? -1 : 1)
            })
        } else {
            // The continuous phase is only for the hoodie transform. Preserve
            // the original sprite renderer's held-frame redraw deduplication.
            character.subtitle.setScootSample(sample.scoot.map {
                SeatedScootTimeline.Sample(frame:$0.frame,offset:$0.offset,phase:$0.phase)
            })
        }
        character.subtitle.strollMirrored = sample.mirrored
        character.subtitle.setStrollSample(sample.stroll)
        character.subtitle.setFrontRetreatSample(sample.frontRetreat)
        if let frame = sample.performanceFrame {
            character.subtitle.performanceMirrored = sample.mirrored
            character.subtitle.setPerformanceFrame(frame)
        }
    }
    func applyRainShelter(_ sample: RainShelterSample) {
        guard relocating, !relocationInterrupted else { return }
        if character.panel.frame.origin != sample.origin {
            movingGroup = true; character.panel.setFrameOrigin(sample.origin); movingGroup = false
        }
        expectedRelocationOrigin = character.panel.frame.origin
        lastCharacterFrame = character.panel.frame
        character.subtitle.setRainShelterPose(sample.frame.map { RainShelterPose(frame:$0,mirrored:sample.mirrored) })
        character.subtitle.setRainShelterThinking(sample.phase == .sheltered)
    }
    func saveRainShelterPosition() { savePosition(allowRelocation:true) }

    func endRelocation() {
        relocating = false; expectedRelocationOrigin = nil
        lastCharacterFrame = character.panel.frame
        character.subtitle.setOrangeHoodieScoot(nil)
        character.subtitle.setScootSample(nil)
        character.subtitle.strollMirrored = false
        character.subtitle.performanceMirrored = false
        character.subtitle.setStrollSample(nil)
        character.subtitle.setFrontRetreatSample(nil)
        savePosition()
    }
    private var scootOrigin: NSPoint?
    private var scootDistance: CGFloat = 0
    private var frontRetreatOrigin: NSPoint?
    private var frontRetreatDistance: CGFloat = 0
    private var restoredFrontRetreatAnchor: NSPoint?
    var frontRetreatPhase: String {
        guard let sample = character.subtitle.frontRetreatSample else { return "" }
        if frontRetreatDistance < 0 {
            if sample.phase == .outward { return FrontRetreatTimeline.Phase.returning.rawValue }
            if sample.phase == .returning { return FrontRetreatTimeline.Phase.outward.rawValue }
        }
        return sample.phase.rawValue
    }

    func setFrontRetreat(_ sample: FrontRetreatTimeline.Sample?) {
        if let sample {
            guard character.panel.isVisible else { return }
            if frontRetreatOrigin == nil {
                pendingPositionSave?.cancel(); pendingPositionSave = nil
                frontRetreatOrigin = character.panel.frame.origin
                let bounds = relativeGroupBounds?.offsetBy(dx:character.panel.frame.minX,dy:character.panel.frame.minY)
                    ?? character.panel.frame
                let right = max(0,(screenArea?.maxX ?? bounds.maxX)-bounds.maxX)
                let left = max(0,bounds.minX-(screenArea?.minX ?? bounds.minX))
                frontRetreatDistance = right >= 168*character.subtitle.layoutScale || right >= left
                    ? min(168*character.subtitle.layoutScale,right) : -min(168*character.subtitle.layoutScale,left)
            }
            movingGroup = true
            character.panel.setFrameOrigin(NSPoint(x:frontRetreatOrigin!.x+CGFloat(sample.offset)*frontRetreatDistance,
                                                  y:frontRetreatOrigin!.y))
            movingGroup = false
            lastCharacterFrame = character.panel.frame
            character.subtitle.setFrontRetreatSample(sample)
        } else {
            if let origin = frontRetreatOrigin {
                movingGroup = true
                character.panel.setFrameOrigin(origin)
                movingGroup = false
                lastCharacterFrame = character.panel.frame
                // Refresh controller offsets once after a programmatic restore, including click-through mode.
                restoredFrontRetreatAnchor = NSPoint(x:character.panel.frame.midX,y:character.panel.frame.minY)
            }
            frontRetreatOrigin = nil
            character.subtitle.setFrontRetreatSample(nil)
        }
    }

    func setScoot(_ sample: SeatedScootTimeline.Sample?) {
        if let sample {
            guard character.panel.isVisible else { return }
            if scootOrigin == nil {
                pendingPositionSave?.cancel(); pendingPositionSave = nil
                scootOrigin = character.panel.frame.origin
                let bounds = relativeGroupBounds?.offsetBy(dx: character.panel.frame.minX, dy: character.panel.frame.minY)
                    ?? character.panel.frame
                let free = max(0, (screenArea?.maxX ?? bounds.maxX)-bounds.maxX)
                scootDistance = min(96*character.subtitle.layoutScale, free)
                if scootDistance < 24*character.subtitle.layoutScale {
                    let leftFree = max(0, bounds.minX-(screenArea?.minX ?? bounds.minX))
                    scootDistance = -min(96*character.subtitle.layoutScale, leftFree)
                }
            }
            movingGroup = true
            character.panel.setFrameOrigin(NSPoint(x: scootOrigin!.x + CGFloat(sample.offset/3)*scootDistance, y: scootOrigin!.y))
            movingGroup = false
            lastCharacterFrame = character.panel.frame
            let phase: String
            if scootDistance < 0 && sample.phase == "坐着向右挪动" { phase = "坐着向左挪动" }
            else if scootDistance < 0 && sample.phase == "坐着向左挪动" { phase = "坐着向右挪动" }
            else { phase = sample.phase }
            character.subtitle.setScootSample(SeatedScootTimeline.Sample(frame:sample.frame,offset:sample.offset,
                phase:phase))
        } else {
            if let origin = scootOrigin {
                movingGroup = true
                character.panel.setFrameOrigin(origin)
                movingGroup = false
                lastCharacterFrame = character.panel.frame
            }
            scootOrigin = nil
            character.subtitle.setScootSample(nil)
        }
    }

    func setTemporarilyHidden(_ hidden: Bool) {
        temporarilyHidden = hidden
        if hidden {
            character.subtitle.cancelHeadPat()
            character.hide()
            panels.values.forEach { $0.hide() }
        }
    }

    private func bubbleSize(_ item: OverlayItem, font: Double, scale: CGFloat,
                            availableWidth: CGFloat, hasTail: Bool, compactStack: Bool,
                            fixedWidth: CGFloat?) -> NSSize {
        if item.question != nil {
            return NSSize(width: min(420, max(280, availableWidth)), height: min(320, (screenArea?.height ?? 800) - 48))
        }
        measurement.mode = .bubble
        measurement.text = item.text
        measurement.layoutScale = scale
        measurement.fontSize = CGFloat(font) * scale
        measurement.tailTarget = hasTail ? .zero : nil
        measurement.compactStack = compactStack
        let width = fixedWidth ?? measurement.preferredWidth(available: availableWidth)
        return NSSize(width: width, height: measurement.height(for: width))
    }

    init(source: String, positionStore: CharacterPositionStore?) {
        self.source = source
        self.positionStore = positionStore
        character.subtitle.onScreenEdgeFrame = { [weak self] in self?.moveEdgeFrame() }
        character.subtitle.onScreenEdgeExited = { [weak self] in self?.edgeExited() }
        movementObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: character.panel, queue: nil
        ) { [weak self] _ in self?.characterMoved() }
    }

    deinit {
        pendingPositionSave?.cancel()
        if let movementObserver { NotificationCenter.default.removeObserver(movementObserver) }
    }

    private func characterMoved() {
        if relocating, !layingOut, !movingGroup, let expected = expectedRelocationOrigin,
           hypot(character.panel.frame.minX-expected.x,character.panel.frame.minY-expected.y) > 2 {
            relocationInterrupted = true
        }
        guard scootOrigin == nil, frontRetreatOrigin == nil, !layingOut, !movingGroup, character.panel.isVisible,
              let previous = lastCharacterFrame, let area = screenArea,
              let relativeBounds = relativeGroupBounds else { return }
        var delta = NSPoint(x: character.panel.frame.minX - previous.minX,
                            y: character.panel.frame.minY - previous.minY)
        if canDock && character.panel.isManuallyDragging {
            // Bubbles must not stop the character reaching the edge. Native
            // child windows follow the drag, then hide when docking completes.
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? character.panel.screen
            let dragArea = screen?.visibleFrame ?? area
            let horizontalArea = screen?.frame ?? area
            if let screen { draggedScreenFrame = screen.frame; screenArea = dragArea }
            let frame = character.panel.frame
            if let side = edgeDragSide, let origin = edgeDragOrigin,
               character.subtitle.screenEdgePlayback?.phase != .exiting {
                let inward = side == .left ? frame.minX - origin.x : origin.x - frame.minX
                if inward > 0.5 {
                    // Restore articulated anatomy while the button is still held.
                    // The physical screen plane remains fixed throughout the drag.
                    screenEdgeDock = nil
                    character.subtitle.exitScreenEdge()
                }
            }
            let leftBleed = edgeDragSide == .left ? edgeDragOffset : 0
            let rightBleed = edgeDragSide == .right ? edgeDragOffset : 0
            movingGroup = true
            character.panel.setFrameOrigin(NSPoint(
                x: min(max(horizontalArea.minX - leftBleed, frame.minX), horizontalArea.maxX - frame.width + rightBleed),
                y: min(max(dragArea.minY, frame.minY), dragArea.maxY - frame.height)))
            lastCharacterFrame = character.panel.frame
            movingGroup = false
            return
        }
        let bounds = relativeBounds.offsetBy(dx: previous.minX, dy: previous.minY)
        // Keep the group on screen as one object rather than clipping each
        // bubble independently and changing its relative position.
        if bounds.width <= area.width {
            delta.x = min(max(delta.x, area.minX - bounds.minX), area.maxX - bounds.maxX)
        }
        if bounds.height <= area.height {
            delta.y = min(max(delta.y, area.minY - bounds.minY), area.maxY - bounds.maxY)
        }
        movingGroup = true
        defer { movingGroup = false }
        let constrained = NSPoint(x: previous.minX + delta.x, y: previous.minY + delta.y)
        if character.panel.frame.origin != constrained {
            character.panel.setFrameOrigin(constrained)
        }
        // Attached bubbles already moved with the character in AppKit. Their
        // backing stores and relative tail targets remain valid during motion.
        lastCharacterFrame = character.panel.frame
        if positionStore != nil {
            pendingPositionSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.savePosition() }
            pendingPositionSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func savePosition(allowRelocation: Bool = false) {
        pendingPositionSave?.cancel(); pendingPositionSave = nil
        guard !character.panel.isManuallyDragging, (!relocating || allowRelocation), scootOrigin == nil, frontRetreatOrigin == nil, positionLoaded, let area = screenArea else { return }
        positionStore?.save(anchor: NSPoint(x: character.panel.frame.midX, y: character.panel.frame.minY),
                            source: source, in: area)
    }

    func finishWindowRecovery(at frame:NSRect) {
        movingGroup = true
        character.panel.setFrameOrigin(frame.origin)
        movingGroup = false
        restoredFrontRetreatAnchor = NSPoint(x:frame.midX,y:frame.minY)
        lastCharacterFrame = character.panel.frame
        character.subtitle.setStrollSample(StrollTimeline.sample(at:StrollTimeline.duration-0.001))
        character.subtitle.setStrollSample(nil)
        savePosition()
    }

    func controller(for id: String) -> OverlayController? { panels[id] }

    func update(_ items: [OverlayItem], font: Double, opacity: Double, bottom: Double,
                screenIndex: Int, movable: Bool, focusedID: String, characterScale: Double = 1,
                centerX: CGFloat? = nil, laneWidth: CGFloat? = nil, hues: [String: CGFloat] = [:],
                audioMascot: CaptionMascot? = nil, pinkBear: Bool = false,
                bubblesFixedToCharacter: Bool = false, restingMascot: CaptionMascot? = nil,
                fallbackMetrics: OverlayHoverMetrics? = nil, cutoutHair: String? = nil,
                sharedMetrics: [(String, OverlayHoverMetrics)] = []) {
        guard !temporarilyHidden else { return }
        layingOut = true
        defer {
            layingOut = false
            if edgeActive, character.panel.isVisible {
                moveEdgeFrame()
                panels.values.forEach { $0.hide() }
                character.refreshSpeedHover()
            }
            if character.panel.isVisible { restoredFrontRetreatAnchor = nil }
            lastCharacterFrame = character.panel.frame
            let captionFrames = visibleIDs.compactMap { id -> NSRect? in
                guard let panel = panels[id]?.panel, panel.isVisible else { return nil }
                return panel.frame
            }
            character.hoverCaptionTopOffset = captionFrames.map(\.maxY).max().map { $0 - character.panel.frame.maxY }
            if character.hoverMetricsWindowVisible { character.refreshSpeedHover() }
            let bounds = visibleIDs.compactMap { panels[$0]?.panel.frame }
                .reduce(character.panel.frame) { $0.union($1) }
            relativeGroupBounds = bounds.offsetBy(dx: -character.panel.frame.minX,
                                                 dy: -character.panel.frame.minY)
            savePosition()
        }
        let itemIDs = Set(items.map(\.id))
        for (id, controller) in panels where !itemIDs.contains(id) {
            controller.attach(to: nil)
            controller.hide()
        }
        guard (!items.isEmpty || audioMascot != nil || restingMascot != nil), !NSScreen.screens.isEmpty else {
            visibleIDs = []
            character.hide()
            return
        }
        if let configuredScreenIndex, configuredScreenIndex != screenIndex {
            draggedScreenFrame = nil; screenEdgeDock = nil; character.subtitle.screenEdgeDock = nil
        }
        configuredScreenIndex = screenIndex
        let screenIndex = draggedScreenFrame.flatMap { frame in NSScreen.screens.firstIndex { $0.frame == frame } }
            ?? min(max(0, screenIndex), NSScreen.screens.count - 1)
        let screen = NSScreen.screens[screenIndex]
        if let dock = screenEdgeDock, dock.screenFrame != screen.frame { screenEdgeDock = nil; character.subtitle.screenEdgeDock = nil }
        let area = screen.visibleFrame
        let centerX = centerX ?? area.midX
        screenArea = area
        for item in items.sorted(by: { $0.id < $1.id }) where appearances[item.id] == nil {
            appearances[item.id] = appearances.count
        }
        let sorted = items.sorted { appearances[$0.id]! < appearances[$1.id]! }
        let membershipChanged = visibleIDs != sorted.map(\.id)
        visibleIDs = sorted.map(\.id)
        let compactStack = sorted.count > 1
        let gap: CGFloat = compactStack ? 2 : 16
        let bottomMargin: CGFloat = min(max(0, CGFloat(bottom)), area.height / 4)
        let primary = items.first { $0.id == focusedID } ?? sorted.first
            ?? OverlayItem(id: "audio-\(source)", text: "", header: "", title: "", active: false, mascot: audioMascot ?? restingMascot)
        if primary.mascot != .deepseek || pinkBear {
            screenEdgeDock = nil; character.subtitle.screenEdgeDock = nil
        }
        let savedAnchor: NSPoint?
        if !positionLoaded && primary.mascot != nil {
            positionLoaded = true
            savedAnchor = positionStore?.anchor(for: source, in: area)
        } else { savedAnchor = nil }
        func updateCharacter(restoredAnchor: NSPoint? = nil) {
            let transientAnchor = restoredAnchor ?? restoredFrontRetreatAnchor ?? ((edgeActive || character.panel.isManuallyDragging || relocating || scootOrigin != nil || frontRetreatOrigin != nil)
                ? NSPoint(x:character.panel.frame.midX,y:character.panel.frame.minY) : nil)
            character.update(text: primary.text, context: primary.header, title: primary.title,
                live: items.contains(where: \.active) || (audioMascot != nil && !pinkBear), mascot: primary.mascot, font: font, opacity: opacity,
                bottom: Double(bottomMargin), screenIndex: screenIndex, movable: movable, visible: primary.mascot != nil,
                anchor: NSPoint(x: centerX, y: area.minY + bottomMargin),
                scale: min(2, max(0.5, characterScale)), mode: .character, restoredAnchor: transientAnchor,
                pinkBear: pinkBear,cutoutHair:cutoutHair,allowOutsideScreen:relocating)
        }
        updateCharacter()
        let metrics = sorted.isEmpty
            ? fallbackMetrics ?? OverlayHoverMetrics(averageSpeed: nil, quotaText: source == "deepseek" ? "账户余额 -" : nil)
            : OverlayHoverMetrics(averageSpeed: primary.averageSpeed, quotaText: primary.quotaText,
                                  refreshing: primary.metricsRefreshing, onHover: primary.onMetricsHover)
        if sharedMetrics.count > 1 {
            let rows = sharedMetrics.map { HoverMetricsRow(name: $0.0, speed: $0.1.averageSpeed, quota: $0.1.quotaText) }
            let text = rows.map(\.compactLine).joined(separator: "\n")
            character.onMetricsHover = { sharedMetrics.forEach { $0.1.onHover?() } }
            character.setHoverMetrics(speed: nil, quota: nil,
                refreshing: sharedMetrics.contains { $0.1.refreshing }, text: text,
                rows: rows, forceVisible: sharedMetrics.contains { $0.1.persistent })
        } else {
            character.onMetricsHover = metrics.onHover
            character.setHoverMetrics(speed: metrics.averageSpeed, quota: metrics.quotaText,
                                      showSpeedPlaceholder: source != "companion" && CaptionMascot(rawValue: source) != nil,
                                      refreshing: metrics.refreshing, forceVisible: fallbackMetrics?.persistent ?? false, name: ["codex": "Codex", "deepseek": "DSH", "workbuddy": "WorkBuddy", "claude": "Claude", "doubao": "豆包", "opencode": "OpenCode"][source] ?? source)
        }
        if edgeActive { return }
        if sorted.isEmpty {
            if let savedAnchor {
                let halfWidth = character.panel.frame.width / 2
                updateCharacter(restoredAnchor: NSPoint(
                    x: min(max(area.minX + halfWidth, savedAnchor.x), area.maxX - halfWidth),
                    y: min(max(area.minY, savedAnchor.y), area.maxY - character.panel.frame.height)))
            }
            return
        }
        // Keep the default bubble near the seated head. The character window
        // also reserves transparent headroom for standing/singing animations.
        let seatedHead = character.subtitle.seatedSpriteRect.maxY
        let bubbleOffset = primary.mascot == nil ? 0 : seatedHead + 4 * character.subtitle.layoutScale
        let baseBottom = area.minY + bottomMargin + bubbleOffset
        let columnWidth = max(40, min(420, (laneWidth ?? area.width) - 32))
        let availableWidth = columnWidth / 0.82
        // Stack actual bubble heights rather than allocating equal screen-wide
        // grid cells. Fit to the configured anchor so dragging never reflows it.
        let availableHeight = max(40, area.maxY - baseBottom - gap)
        var scale: CGFloat = 1
        func stackHeight(at scale: CGFloat) -> CGFloat {
            sorted.enumerated().reduce(CGFloat.zero) {
                $0 + bubbleSize($1.element, font: font, scale: scale,
                                availableWidth: availableWidth, hasTail: $1.offset == 0 && primary.mascot != nil,
                                compactStack: compactStack,
                                fixedWidth: compactStack ? columnWidth * scale : nil).height
            } + gap * scale * CGFloat(max(0, sorted.count - 1))
        }
        for _ in 0..<8 {
            let height = stackHeight(at: scale)
            if height <= availableHeight { break }
            scale = max(0.05, scale * availableHeight / height * 0.98)
        }
        if let savedAnchor {
            let bubbleWidth = compactStack ? columnWidth * scale
                : bubbleSize(sorted[0], font: font, scale: scale, availableWidth: availableWidth,
                             hasTail: true, compactStack: false, fixedWidth: nil).width
            let halfWidth = max(character.panel.frame.width, bubbleWidth) / 2
            let groupHeight = max(character.panel.frame.height, bubbleOffset + stackHeight(at: scale))
            let highestBottom = max(area.minY, area.maxY - groupHeight)
            // Restore the whole group within the current screen; don't clamp
            // individual rows separately and split a saved compact stack.
            updateCharacter(restoredAnchor: NSPoint(
                x: min(max(area.minX + halfWidth, savedAnchor.x), area.maxX - halfWidth),
                y: min(max(area.minY, savedAnchor.y), highestBottom)))
        }
        let head = primary.mascot == nil ? nil
            : NSPoint(x: character.panel.frame.midX, y: character.panel.frame.minY + seatedHead)
        let offset = primary.mascot == nil ? NSPoint.zero
            : NSPoint(x: character.panel.frame.midX - centerX,
                      y: character.panel.frame.minY - (area.minY + bottomMargin))
        var nextBottom = baseBottom + offset.y
        for (index, item) in sorted.enumerated() {
            let controller = panels[item.id] ?? OverlayController(interactive: true)
            panels[item.id] = controller
            controller.panel.onScrollFont = item.question == nil ? onCaptionScroll : nil
            if primary.mascot == nil { controller.attach(to: nil) }
            let anchor = NSPoint(x: centerX + offset.x, y: nextBottom)
            let hue = hues[item.id] ?? (0.57 + CGFloat(appearances[item.id]!) * 0.381966011).truncatingRemainder(dividingBy: 1)
            controller.update(text: item.text, context: item.header, title: item.title, live: item.active,
                mascot: nil, font: font, opacity: opacity, bottom: bottom, screenIndex: screenIndex,
                movable: movable && !(bubblesFixedToCharacter && primary.mascot != nil),
                visible: true, anchor: anchor, availableWidth: availableWidth,
                scale: scale, hue: hue,
                mode: .bubble, tailTarget: index == 0 ? head : nil,
                compactStack: compactStack, fixedWidth: compactStack ? columnWidth * scale : nil,
                resetManualOffset: membershipChanged, typewriterID: item.typewriterID,
                typewriterCharactersPerSecond: item.typewriterCharactersPerSecond,
                tokenSpeed: item.averageSpeed,
                question: item.question, onOpenConversation: item.onOpenConversation,
                onQuestionClose: item.onQuestionClose, onCaptionClose: item.onCaptionClose, onQuestionReply: item.onQuestionReply,allowOutsideScreen:relocating)
            controller.attach(to: primary.mascot == nil ? nil : character.panel)
            nextBottom += controller.layoutHeight + gap * scale
        }
        // Keep recent manually placed panels without an unbounded cache of native windows.
        if panels.count > 64 {
            for id in panels.keys.filter({ !itemIDs.contains($0) }).sorted()
                .prefix(panels.count - 64) { panels.removeValue(forKey: id) }
        }
    }

    var diagnostics: [[String: Any]] {
        visibleIDs.compactMap { id in
            guard let c = panels[id] else { return nil }
            return ["id": id, "title": c.subtitle.context, "text": c.subtitle.text,
                    "typewriterCharactersPerSecond": c.subtitle.captionCharactersPerSecond,
                "active": c.subtitle.isLive, "x": c.panel.frame.minX, "y": c.panel.frame.minY,
                "width": c.panel.frame.width, "height": c.panel.frame.height,
                "hue": c.subtitle.themeHue, "mascotSource": c.subtitle.mascotSource,
                "hasTail": c.subtitle.tailTarget != nil, "compactStack": c.subtitle.compactStack,
                "mascotAnimating": c.subtitle.mascotAnimating,
                "ignoresMouseEvents": c.panel.ignoresMouseEvents,
                "acceptsQuestionInput": c.panel.acceptsQuestionInput,
                "captionCloseVisible": c.captionCloseVisible,
                "windowNumber": c.panel.windowNumber,
                "keyWindow": c.panel.isKeyWindow,
                "questionTransitionRunning": c.isQuestionTransitionRunning]
        }
    }

    var visibleControllers: [OverlayController] {
        var controllers = visibleIDs.compactMap { panels[$0] }
        if character.panel.isVisible { controllers.append(character) }
        return controllers
    }

    func bringToFront() {
        if character.panel.isVisible { character.panel.orderFrontRegardless() }
        for id in visibleIDs {
            if let panel = panels[id]?.panel, panel.isVisible { panel.orderFrontRegardless() }
        }
    }
}

/// Each source keeps a stable anchor, including while another source hides.
final class ProjectOverlays {
    var onCharacterDragStarted: ((String) -> Void)?
    var onCharacterDragEnded: ((String, Bool) -> Void)?
    var onCaptionScroll: ((Double) -> Void)?
    var onCharacterScrollScale: ((Double) -> Void)?
    var onCharacterDockChanged: (() -> Void)?
    private var groups: [String: CharacterOverlayGroup] = [:]
    private var dragReactionGroups = Set<String>()
    private var lastDraggedCharacter: String?
    private var draggingCharacter: String?
    private var layerWindowNumbers: Set<Int> = []
    private(set) var layerRestackCount = 0
    private var appearances: [String: Int] = [:]
    private var groupForItem: [String: String] = [:]
    private var groupForSource: [CaptionMascot: String] = [:]
    private var focusedID = ""
    private let fallbackCharacter = OverlayController()
    private let positionStore: CharacterPositionStore?
    private var terminationObserver: NSObjectProtocol?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var headPatTrace: FileHandle?
    private var lastHeadPatTraceAt: TimeInterval = 0
    private var headPatTraceRows = 0
    private(set) var visibleIDs: [String] = []

    init(positionStore: CharacterPositionStore? = nil) {
        self.positionStore = positionStore
        // Optional, bounded manual acceptance log: gesture state only, without
        // captions, session contents, screen pixels, or another polling clock.
        if let index = CommandLine.arguments.firstIndex(of: "--head-pat-diagnostics"),
           index+1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index+1]
            if FileManager.default.createFile(atPath: path, contents: nil) {
                headPatTrace = FileHandle(forWritingAtPath: path)
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flushPositions() }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.observeCharacterPointer(event)
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.observeCharacterPointer(event); return event
        }
    }

    deinit {
        try? headPatTrace?.close()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
    }

    func refreshCharacterMouseTransparency(at point: NSPoint? = nil, recognizeHeadPat: Bool = false) {
        for group in groups.values { group.character.refreshCharacterMouseTransparency(at: point, recognizeHeadPat: recognizeHeadPat) }
    }
    var onboardingActive = false {
        didSet { groups.values.forEach { $0.character.onboardingDialogueVisible = onboardingActive } }
    }
    var onOnboardingPointer: ((NSEvent, NSPoint) -> Void)?
    private func observeCharacterPointer(_ event: NSEvent) {
        // NSEvent retains the event's position/time even when the current
        // pointer has already moved farther while the main thread was busy.
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        let pressed = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
            || event.type == .leftMouseDragged || event.type == .rightMouseDragged || event.type == .otherMouseDragged
            || NSEvent.pressedMouseButtons != 0
        for group in groups.values {
            group.character.refreshCharacterMouseTransparency(at: point, leftButtonDown: pressed,
                recognizeHeadPat: true, pointerTime: event.timestamp)
        }
        onOnboardingPointer?(event, point)
        if let trace = headPatTrace, event.timestamp-lastHeadPatTraceAt >= 0.05 {
            lastHeadPatTraceAt = event.timestamp
            let characters: [[String: Any]] = groups.values.map { group in
                ["artwork": group.character.subtitle.mascotArtwork,
                 "visible": group.character.panel.isVisible,
                 "headPat": group.character.subtitle.headPatDiagnostics]
            }
            if var data = try? JSONSerialization.data(withJSONObject:
                ["processID": ProcessInfo.processInfo.processIdentifier, "time": event.timestamp,
                 "pressed": pressed, "characters": characters]) {
                data.append(10); try? trace.write(contentsOf: data)
            }
            headPatTraceRows += 1
            if headPatTraceRows >= 1800 { try? trace.close(); headPatTrace = nil }
        }
    }

    private func restoreLayerOrder(force: Bool = false) {
        let visible = Set(groups.values.flatMap { $0.visibleControllers.filter { $0.panel.isVisible }.map { $0.panel.windowNumber } })
        guard force || visible != layerWindowNumbers else { return }
        layerWindowNumbers = visible
        var keys = groups.keys.sorted()
        if let foreground = draggingCharacter ?? lastDraggedCharacter,
           let index = keys.firstIndex(of: foreground) {
            keys.append(keys.remove(at: index))
        }
        for key in keys { groups[key]?.bringToFront() }
        layerRestackCount += 1
    }

    func flushPositions() {
        groups.values.forEach { $0.savePosition() }
        positionStore?.flush()
    }

    var character: OverlayController {
        if let key = groupForItem[focusedID], let group = groups[key] { return group.character }
        if let visible = groups.keys.sorted().compactMap({ groups[$0] }).first(where: { $0.character.panel.isVisible }) {
            return visible.character
        }
        return groups["codex"]?.character ?? groups["deepseek"]?.character ?? groups["claude"]?.character ?? groups["doubao"]?.character ?? groups["opencode"]?.character ?? groups["workbuddy"]?.character ?? fallbackCharacter
    }

    private var resolvedBindings: [CaptionMascot: CharacterChoice] = [.codex: .codex, .deepseek: .deepseek]
    /// Window/relocation controller follows the harness wearing the whale artwork.
    /// Prefer its original lane when several harnesses use the same character.
    var deepSeekSource: CaptionMascot {
        resolvedBindings[.deepseek] == .deepseek ? .deepseek
            : CaptionMascot.allCases.first { resolvedBindings[$0] == .deepseek } ?? .deepseek
    }
    private var deepSeekGroup: CharacterOverlayGroup? {
        guard resolvedBindings[deepSeekSource] == .deepseek else { return nil }
        return groups[groupKey(for: deepSeekSource)]
    }

    private func groupKey(for source: CaptionMascot) -> String { groupForSource[source] ?? source.rawValue }

    func character(for source: CaptionMascot) -> OverlayController? { groups[groupKey(for: source)]?.character }
    func updateDragReactions(at time: TimeInterval) {
        guard !dragReactionGroups.isEmpty else { return }
        var finished: [String] = []
        for key in dragReactionGroups {
            guard let group = groups[key] else { finished.append(key); continue }
            let c = group.character
            if c.panel.isManuallyDragging { c.panel.finishManualDragIfReleased() }
            c.subtitle.updateDragReaction(at: c.panel.frame.origin, time: time)
            if !c.subtitle.dragReaction.active { finished.append(key) }
        }
        for key in finished { dragReactionGroups.remove(key) }
    }
    func finishReleasedCharacterDrags() {
        for group in groups.values where group.character.panel.isManuallyDragging {
            group.character.panel.finishManualDragIfReleased()
        }
    }
    func controller(for id: String) -> OverlayController? {
        groupForItem[id].flatMap { groups[$0]?.controller(for: id) }
    }

    func update(_ items: [OverlayItem], font: Double, opacity: Double, bottom: Double,
                screenIndex: Int, movable: Bool, focusedID: String, characterScale: Double = 1,
                akimboUtterancePause: Double = AkimboReaction.utterancePause,
                bubblesFixedToCharacter: Bool = false,
                audioMascots: Set<CaptionMascot> = [], pinkBearBinding: PinkBearBinding = .disabled,
                restingMascots: Set<CaptionMascot> = [],
                characterBindings: [CaptionMascot: CharacterChoice]? = nil,
                fallbackMetrics: [CaptionMascot: OverlayHoverMetrics] = [:],
                cutoutHair: [CaptionMascot: String] = [:]) {
        // AppKit may swallow mouse-up during a WindowServer drag. Reuse the
        // existing subtitle refresh and only check panels with an active drag.
        finishReleasedCharacterDrags()
        self.focusedID = focusedID
        resolvedBindings = characterBindings ?? [
            .codex: pinkBearBinding == .codex ? .pinkBear : .codex,
            .deepseek: pinkBearBinding == .deepseek ? .pinkBear : .deepseek]
        // Resolve six harness bindings plus one independent companion. The owner
        // is stable even when only another harness currently has content.
        var owners: [CharacterChoice: CaptionMascot] = [:]
        for source in CaptionMascot.allCases {
            if source == .companion { continue }
            guard let choice = resolvedBindings[source] else { continue }
            if owners[choice] == nil || (choice == .deepseek && source == .deepseek) {
                owners[choice] = source
            }
        }
        groupForSource = Dictionary(uniqueKeysWithValues: resolvedBindings.map { source, choice in
            (source, source == .companion ? source.rawValue : owners[choice]!.rawValue)
        })
        let grouped = Dictionary(grouping: items) { $0.mascot.map { groupKey(for: $0) } ?? "waiting" }
        groupForItem = Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, $0.mascot.map { groupKey(for: $0) } ?? "waiting")
        })
        let audioGroups = Set(audioMascots.map { groupKey(for: $0) })
        let restingGroups = Set(restingMascots.map { groupKey(for: $0) })
        for item in items.sorted(by: { $0.id < $1.id }) where appearances[item.id] == nil {
            appearances[item.id] = appearances.count
        }
        let hues = appearances.mapValues { (0.57 + CGFloat($0) * 0.381966011).truncatingRemainder(dividingBy: 1) }
        let screens = NSScreen.screens
        let area = screens.isEmpty ? NSRect.zero
            : screens[min(max(0, screenIndex), screens.count - 1)].visibleFrame
        let displayedSources = Set(grouped.keys).union(audioGroups).union(restingGroups)
            .filter { CaptionMascot(rawValue: $0) != nil }
        let sourceOrder = CaptionMascot.allCases.map(\.rawValue).filter { displayedSources.contains($0) }
        let separation = min(460, area.width / CGFloat(max(2, sourceOrder.count)))
        var orderedSources = Set(groups.keys).union(grouped.keys).union(audioGroups).union(restingGroups).sorted()
        // New windows enter in the stable source order. Existing windows retain
        // their layer while text, size and animation update.
        if let foreground = draggingCharacter ?? lastDraggedCharacter,
           let index = orderedSources.firstIndex(of: foreground) {
            orderedSources.append(orderedSources.remove(at: index))
        }
        for key in orderedSources {
            let group = groups[key] ?? CharacterOverlayGroup(source: key,
                positionStore: key == "waiting" ? nil : positionStore)
            groups[key] = group
            group.onCaptionScroll = { [weak self] delta in self?.onCaptionScroll?(delta) }
            group.character.onboardingDialogueVisible = onboardingActive
            group.character.subtitle.akimboUtterancePause = AkimboReaction.boundedUtterancePause(akimboUtterancePause)
            group.onDockChanged = { [weak self] in self?.onCharacterDockChanged?() }
            group.character.isPointerOverAnyCharacter = { [weak self] point in
                self?.groups.contains { key, group in
                    CaptionMascot(rawValue: key) != nil && group.character.panel.isVisible
                        && !group.character.panel.isManuallyDragging && group.character.panel.frame.contains(point)
                } ?? false
            }
            group.character.panel.onScrollScale = { [weak self] delta in self?.onCharacterScrollScale?(delta) }
            group.character.panel.onManualDragStarted = { [weak self, weak group] in
                self?.draggingCharacter = key
                if let group, group.character.subtitle.beginDragReaction(at: group.character.panel.frame.origin,
                    time: ProcessInfo.processInfo.systemUptime) {
                    self?.dragReactionGroups.insert(key)
                }
                group?.beginManualDrag()
                group?.bringToFront()
                self?.onCharacterDragStarted?(key)
            }
            group.character.panel.onManualDragEnded = { [weak self, weak group] moved in
                self?.draggingCharacter = nil
                group?.character.subtitle.endDragReaction(at: ProcessInfo.processInfo.systemUptime)
                if moved { self?.lastDraggedCharacter = key }
                group?.finishManualDrag(moved: moved)
                group?.savePosition()
                self?.onCharacterDragEnded?(key,moved)
                self?.restoreLayerOrder(force: true)
            }
            let centerX: CGFloat
            if sourceOrder.count > 1, let index = sourceOrder.firstIndex(of: key) {
                centerX = area.midX + (CGFloat(index) - CGFloat(sourceOrder.count - 1) / 2) * separation
            } else {
                // Preserve the original single-source Codex/DSH position.
                centerX = key == "codex" ? area.midX - separation / 2
                    : key == "deepseek" ? area.midX + separation / 2 : area.midX
            }
            let source = CaptionMascot(rawValue: key)
            let choice = source.flatMap { resolvedBindings[$0] }
            // Each bubble keeps its source-specific content and callbacks in the shared stack.
            let renderedItems = (grouped[key] ?? []).map { item in
                OverlayItem(id: item.id, text: item.text, header: item.header, title: item.title,
                            active: item.active, mascot: choice?.mascot, typewriterID: item.typewriterID,
                    typewriterCharactersPerSecond: item.typewriterCharactersPerSecond,
                    question: item.question, averageSpeed: item.averageSpeed, quotaText: item.quotaText,
                    metricsRefreshing: item.metricsRefreshing, onMetricsHover: item.onMetricsHover,
                    onOpenConversation: item.onOpenConversation,
                    onQuestionClose: item.onQuestionClose, onCaptionClose: item.onCaptionClose, onQuestionReply: item.onQuestionReply)
            }
            let members = CaptionMascot.allCases.filter { groupForSource[$0] == key }
            let metricsRows: [(String, OverlayHoverMetrics)] = members.count > 1 ? members.map { member in
                let item = items.first { $0.mascot == member && $0.id == focusedID }
                    ?? items.first { $0.mascot == member }
                let metrics = item.map { OverlayHoverMetrics(averageSpeed: $0.averageSpeed, quotaText: $0.quotaText,
                    refreshing: $0.metricsRefreshing, onHover: $0.onMetricsHover, persistent: fallbackMetrics[member]?.persistent ?? false) }
                    ?? fallbackMetrics[member] ?? OverlayHoverMetrics(averageSpeed: nil, quotaText: nil)
                let name: String
                switch member {
                case .codex: name = "Codex"
                case .deepseek: name = "DSH"
                case .claude: name = "Claude Code"
                case .doubao: name = "豆包"
                case .opencode: name = "OpenCode"
                case .workbuddy: name = "WorkBuddy"
                case .deepseekCutout, .orangeHoodie: name = "DeepSeek"
                case .companion: name = "独立角色"
                case .preview: name = "动作预览"
                }
                return (name, metrics)
            } : []
            group.update(renderedItems, font: font, opacity: opacity, bottom: bottom,
                         screenIndex: screenIndex, movable: movable, focusedID: focusedID,
                         characterScale: characterScale, centerX: centerX,
                         laneWidth: key == "waiting" ? area.width : separation, hues: hues,
                         audioMascot: audioGroups.contains(key) ? choice?.mascot : nil,
                         pinkBear: choice == .pinkBear,
                         bubblesFixedToCharacter: bubblesFixedToCharacter,
                         restingMascot: restingGroups.contains(key) ? choice?.mascot : nil,
                         fallbackMetrics: source.flatMap { fallbackMetrics[$0] },
                         cutoutHair:choice == .deepseekCutout ? source.flatMap { cutoutHair[$0] }
                            ?? CharacterChoice.cutoutDefaultHair : nil,
                         sharedMetrics: metricsRows)

        }
        visibleIDs = groups.keys.sorted().flatMap { groups[$0]?.visibleIDs ?? [] }
        restoreLayerOrder()
    }

    /// Mouth changes never reflow or redraw the caption windows.
    func setAudioMouth(_ index: Int?, targets: Set<CaptionMascot>) {
        for (key, group) in groups {
            group.character.subtitle.setAudioMouth(targets.contains(where: { groupKey(for: $0) == key }) ? index : nil)
        }
    }

    func setDeepSeekPerformance(_ index: Int?, targets: Set<CaptionMascot>? = nil) {
        let targets = targets ?? [deepSeekSource]
        for (key, group) in groups {
            let selected = targets.contains { groupKey(for: $0) == key && resolvedBindings[$0] == .deepseek }
            group.character.subtitle.setPerformanceFrame(selected ? index : nil)
        }
    }

    func setOrangeHoodieSinging(phase: SingingPerformance.Phase, cycle: Double, at now: TimeInterval,
                                targets: Set<CaptionMascot>) {
        for (key, group) in groups {
            let selected = targets.contains { groupKey(for:$0) == key && resolvedBindings[$0] == .orangeHoodie }
            group.character.subtitle.setOrangeHoodieSinging(phase:selected ? phase : .seated,cycle:cycle,at:now)
        }
    }

    func eligibleBackdropSources(allowHoodie: Bool) -> [CaptionMascot] {
        let originals = CaptionMascot.allCases.filter { resolvedBindings[$0] == .deepseek }
        let hoodies = CaptionMascot.allCases.filter { resolvedBindings[$0] == .orangeHoodie && allowHoodie }
        var seen = Set<ObjectIdentifier>()
        return (originals+hoodies).filter { source in
            guard let character = character(for:source), character.panel.isVisible,
                  !character.panel.isManuallyDragging, character.subtitle.screenEdgeDock == nil,
                  !character.subtitle.headPatActive else { return false }
            return seen.insert(ObjectIdentifier(character)).inserted
        }
    }

    func allowedBackdropOrigins(for source: CaptionMascot, in area: CGRect) -> CGRect {
        groups[groupKey(for:source)]?.allowedOrigins(in:area) ?? .null
    }
    var rainShelterActors: [(source: CaptionMascot, character: OverlayController)] {
        var seen = Set<String>()
        return CaptionMascot.allCases.compactMap { source in
            let key = groupKey(for:source)
            guard resolvedBindings[source] == .deepseek, !seen.contains(key),
                  let group = groups[key], group.character.panel.isVisible else { return nil }
            seen.insert(key); return (source,group.character)
        }
    }
    func rainShelterAllowedOrigins(for source: CaptionMascot, in area: CGRect) -> CGRect {
        groups[groupKey(for:source)]?.allowedOrigins(in:area) ?? .null
    }
    func applyRainShelter(_ sample: RainShelterSample, for source: CaptionMascot) {
        groups[groupKey(for:source)]?.applyRainShelter(sample)
    }
    func saveRainShelterPosition(for source: CaptionMascot) { groups[groupKey(for:source)]?.saveRainShelterPosition() }
    func clearRainShelter(for source: CaptionMascot) {
        groups[groupKey(for:source)]?.character.subtitle.setRainShelterPose(nil)
        groups[groupKey(for:source)]?.character.subtitle.setRainShelterThinking(false)
    }

    func backdropRelocationInterrupted(for source: CaptionMascot) -> Bool {
        groups[groupKey(for:source)]?.relocationInterrupted ?? true
    }
    func beginBackdropRelocation(for source: CaptionMascot) { groups[groupKey(for:source)]?.beginRelocation() }
    func applyBackdropRelocation(_ sample: BackdropRelocationSample, for source: CaptionMascot) {
        groups[groupKey(for:source)]?.applyRelocation(sample)
    }
    func endBackdropRelocation(for source: CaptionMascot) { groups[groupKey(for:source)]?.endRelocation() }

    var deepSeekAllowedOrigins: CGRect { deepSeekGroup?.allowedOrigins ?? .null }
    func deepSeekAllowedOrigins(in area: CGRect) -> CGRect { deepSeekGroup?.allowedOrigins(in:area) ?? .null }
    var deepSeekRelocationInterrupted: Bool { deepSeekGroup?.relocationInterrupted ?? false }
    func beginDeepSeekRelocation() { deepSeekGroup?.beginRelocation() }
    func applyDeepSeekRelocation(_ sample: BackdropRelocationSample) { deepSeekGroup?.applyRelocation(sample) }
    func endDeepSeekRelocation() { deepSeekGroup?.endRelocation() }

    func setDeepSeekSleep(_ sample: DeepSeekSleepTimeline.Sample?) {
        deepSeekGroup?.character.subtitle.setSleepSample(sample)
    }

    var deepSeekScootPhase: String? { deepSeekGroup?.character.subtitle.scootSample?.phase }

    func setDeepSeekScoot(_ sample: SeatedScootTimeline.Sample?) {
        deepSeekGroup?.setScoot(sample)
    }

    func setDeepSeekStroll(_ sample: StrollTimeline.Sample?) {
        deepSeekGroup?.character.subtitle.setStrollSample(sample)
    }

    var deepSeekFrontRetreatPhase: String { deepSeekGroup?.frontRetreatPhase ?? "" }
    func setDeepSeekFrontRetreat(_ sample: FrontRetreatTimeline.Sample?) {
        deepSeekGroup?.setFrontRetreat(sample)
    }

    func setSourceHidden(_ source: CaptionMascot, _ hidden: Bool) {
        groups[groupKey(for: source)]?.setTemporarilyHidden(hidden)
    }

    func finishDeepSeekWindowRecovery(at frame:NSRect, source: CaptionMascot? = nil) {
        groups[groupKey(for: source ?? deepSeekSource)]?.finishWindowRecovery(at:frame)
    }

    var diagnostics: [[String: Any]] {
        groups.keys.sorted().flatMap { key in
            (groups[key]?.diagnostics ?? []).map { row in
                var row = row; row["characterID"] = key; return row
            }
        }
    }

    var characterDiagnostics: [[String: Any]] {
        groups.keys.sorted().compactMap { key in
            guard let group = groups[key], group.character.panel.isVisible else { return nil }
            let c = group.character, frame = c.panel.frame
            return ["id": key, "sources": groupForSource.filter { $0.value == key }.keys.map(\.rawValue).sorted(),
                    "source": c.subtitle.mascotSource,
                    "hoverMetrics": c.hoverMetricsDiagnostics,
                    "artwork": c.subtitle.mascotArtwork,
                    "headPat": c.subtitle.headPatDiagnostics,
                    "akimboDialogue": c.akimboDialogueDiagnostics,
                    "screenEdgeDock": c.subtitle.screenEdgeDock?.rawValue ?? "",
                    "screenEdgePhase": c.subtitle.screenEdgePlayback?.phase.rawValue ?? "",
                    "screenEdgeTransitionFrame": c.subtitle.screenEdgePlayback?.transitionFrame ?? -1,
                    "screenEdgeConcealment": c.subtitle.screenEdgePlayback?.concealment ?? 0,
                    "screenEdgeHovered": c.subtitle.screenEdgePlayback?.hovering ?? false,
                    "screenEdgeLoopFrame": c.subtitle.screenEdgePlayback?.loopFrame ?? -1,
                    "screenEdgePeekLean": c.subtitle.screenEdgePlayback?.peekLean ?? 0,
                    "animating": c.subtitle.mascotAnimating, "frameIndex": c.subtitle.mascotFrameIndex,
                    "frameCount": c.subtitle.mascotFrameCount,
                    "mouthIndex": c.subtitle.audioMouthIndex ?? -1,
                    "gazeActive": c.subtitle.seatedGazeActive,
                    "originalThinkingPoseActive": c.subtitle.originalThinkingPoseActive,
                    "gazeX": c.subtitle.seatedGazePosition.x,
                    "gazeY": c.subtitle.seatedGazePosition.y,
                    "performanceFrame": c.subtitle.performanceFrameIndex ?? -1,
                    "performanceMirrored": c.subtitle.performanceMirrored,
                    "dragReactionActive": c.subtitle.dragReaction.active,
                    "dragReactionWeight": c.subtitle.dragReaction.weight,
                    "dragArtFrame": c.subtitle.dragReaction.frameIndex ?? -1,
                    "dragReactionLean": c.subtitle.dragReaction.lean,
                    "manualDragging": c.panel.isManuallyDragging,
                    "sleepPhase": c.subtitle.sleepSample?.phase ?? "",
                    "sleepFrame": c.subtitle.sleepSample?.frame ?? -1,
                    "sleepZVisible": c.subtitle.sleepSample?.sleepTick != nil,
                    "scootFrame": c.subtitle.scootSample?.frame ?? -1,
                    "scootPhase": c.subtitle.scootSample?.phase ?? "",
                    "rainShelterFrame": c.subtitle.rainShelterPose?.frame ?? -1,
                    "rainShelterMirrored": c.subtitle.rainShelterPose?.mirrored ?? false,
                    "strollFrame": c.subtitle.strollSample?.frame ?? -1,
                    "strollPhase": c.subtitle.strollSample?.phase.rawValue ?? "",
                    "frontRetreatFrame": c.subtitle.frontRetreatSample?.frame ?? -1,
                    "frontRetreatTransitionFrame": c.subtitle.frontRetreatSample?.transitionFrame ?? -1,
                    "frontRetreatPhase": group.frontRetreatPhase,
                    "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                    "ignoresMouseEvents": c.panel.ignoresMouseEvents]
        }
    }

    var akimboDialogueDiagnostics: [[String: Any]] {
        groups.keys.sorted().compactMap { key in
            guard let c = groups[key]?.character, c.panel.isVisible else { return nil }
            var row = c.akimboDialogueDiagnostics; row["id"] = key; return row
        }
    }

    /// Composite only our own views, never screenshots of the user's desktop.
    func exportPreview(to url: URL, background: NSColor? = nil) throws {
        let controllers = groups.keys.sorted().flatMap { groups[$0]?.visibleControllers ?? [] }
        guard let first = controllers.first else { return }
        let area = controllers.dropFirst().reduce(first.panel.frame) { $0.union($1.panel.frame) }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(area.width * 2)),
            pixelsHigh: Int(ceil(area.height * 2)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = area.size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.clear(NSRect(origin: .zero, size: area.size))
        if let background {
            background.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: area.size)).fill()
        }
        for c in controllers {
            guard let rep = c.subtitle.bitmapImageRepForCachingDisplay(in: c.subtitle.bounds) else { continue }
            c.subtitle.cacheDisplay(in: c.subtitle.bounds, to: rep)
            let image = NSImage(size: c.subtitle.bounds.size); image.addRepresentation(rep)
            image.draw(in: c.panel.frame.offsetBy(dx: -area.minX, dy: -area.minY))
            if !c.subtitle.conversationLinkFrame.isEmpty {
                NSGraphicsContext.saveGraphicsState()
                context.cgContext.translateBy(x: c.panel.frame.minX - area.minX, y: c.panel.frame.minY - area.minY)
                c.subtitle.drawOutlined(c.subtitle.conversationLinkCaption, in: c.subtitle.conversationLinkTextFrame)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: url) }
    }
}
