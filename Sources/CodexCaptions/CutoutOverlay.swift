import AppKit

/// Per-overlay pose and clock; decoded resources are prepared once on selection.
/// One 30 Hz clock owns body, gaze, blinking and the existing audio mouth input.
final class CutoutOverlayRenderer {
    let artwork: CutoutArtwork
    weak var view: SubtitleView?
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
    private var clockOrigin = ProcessInfo.processInfo.systemUptime
    private var stoppedAt = 0.0
    private(set) var thinking = false
    private var thinkingClip: String
    private var gaze = SeatedGaze()
    private(set) var ticks = 0
    private(set) var blink = 0.0
    private(set) var mouth = 0.0
    private(set) var mouthShape: String?
    private(set) var appearanceError: String?
    var running: Bool { timer != nil }
    var clock: Double { running ? ProcessInfo.processInfo.systemUptime - clockOrigin : stoppedAt }
    var displaySize: CGSize {
        guard let variant=artwork.rig.variants.first(where:{$0.id==artwork.selection["hair"]}),
              let b=variant.displayBounds else {return CGSize(width:126,height:184)}
        let rig=artwork.rig
        let half=max(abs(b[0]-rig.anchor[0]),abs(b[2]-rig.anchor[0]))
        return CGSize(width:max(126,2*half*rig.pointsPerPixel+12),
                      height:max(184,(b[3]-rig.anchor[1])*rig.pointsPerPixel+20))
    }
    var headPatRegion: NSRect {
        guard let view, let index = artwork.player.indices["gaze"] else { return .zero }
        let center = artwork.player.world[index]
        let rect = view.seatedSpriteRect
        let factor = artwork.rig.pointsPerPixel * Double(view.layoutScale)
        return NSRect(x: rect.midX + (center.tx-artwork.rig.anchor[0]-180)*factor,
            y: rect.minY + (center.ty-artwork.rig.anchor[1]-65)*factor,
            width: 360*factor, height: 315*factor)
    }

    init(view: SubtitleView) throws {
        self.view = view
        artwork = try CutoutArtwork.bundled()
        thinkingClip = MascotAnimation.cutoutCharacter.cutoutPlayback!.thinkingClip
        guard artwork.player.clips.contains(where: { $0.definition.id == thinkingClip }) else {
            throw CutoutError.invalid("Registered thinking clip is missing")
        }
        artwork.player.play("idle", at: 0, transition: 0)
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if let window = note.object as? NSWindow, window !== self.view?.window { return }
                self.refreshVisibility()
            })
        }
    }
    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    func setThinking(_ value: Bool) {
        guard value != thinking else { return }
        thinking = value
        artwork.player.play(value ? thinkingClip : "idle", at: clock, blink: blink)
    }
    func setThinkingClip(_ id: String) {
        let playback = MascotAnimation.cutoutCharacter.cutoutPlayback!
        guard ([playback.thinkingClip] + playback.alternativeThinkingClips).contains(id) else { return }
        guard id != thinkingClip else { return }
        thinkingClip = id
        if thinking { artwork.player.play(id, at: clock, blink: blink) }
    }
    func setHair(_ id: String) {
        guard artwork.selection["hair"] != id else { return }
        do {
            // Selection prepares only the new textures; the shared face/cloth
            // caches and the current player phase survive unchanged.
            try artwork.select(["hair": id])
            appearanceError = nil
            view?.needsDisplay = true
        } catch {
            appearanceError = String(describing:error)
        }
    }
    func setAudioMouth(_ index: Int?) {
        let input = MascotAnimation.cutoutCharacter.cutoutPlayback!.mouthInput(for: index)
        mouth = input.openness; mouthShape = input.shape
        artwork.player.sample(at: clock, gaze: gaze.position, mouth: mouth, blink: blink)
    }
    func refreshVisibility() {
        let visible = view?.window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        if visible && !NSApp.isHidden {
            guard timer == nil else { return }
            clockOrigin = ProcessInfo.processInfo.systemUptime - stoppedAt
            let next = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.advance() }
            timer = next; RunLoop.main.add(next, forMode: .common)
        } else {
            stoppedAt = clock; timer?.invalidate(); timer = nil
        }
    }
    private func advance() {
        guard let view, let window = view.window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !NSApp.isHidden else { refreshVisibility(); return }
        ticks += 1
        view.advanceHeadPat()
        let time = clock
        let rect = view.seatedSpriteRect
        let cursor = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let head = artwork.player.indices["head"]!
        let a = artwork.player.world[head]
        let factor = artwork.rig.pointsPerPixel * Double(view.layoutScale)
        let bind = artwork.player.bindWorld[head]
        let center = artwork.player.bindWorld[artwork.player.indices["gaze"]!].applying(
            CGAffineTransform(translationX: -bind.x, y: -bind.y).concatenating(a))
        let eye = CGPoint(x: rect.midX + (center.x - artwork.rig.anchor[0]) * factor,
                          y: rect.minY + (center.y - artwork.rig.anchor[1]) * factor)
        let angle = Double(atan2(a.b, a.a))
        let dx = Double(cursor.x - eye.x), dy = Double(cursor.y - eye.y)
        let target = NSPoint(x: (cos(angle)*dx + sin(angle)*dy)/(190*Double(view.layoutScale)),
                             y: (-sin(angle)*dx + cos(angle)*dy)/(145*Double(view.layoutScale)))
        gaze.update(target: target, dt: 1 / 30)
        blink = artwork.player.automaticBlink(at: time, fallback: CutoutArtwork.blink(at: time))
        let input = MascotAnimation.cutoutCharacter.cutoutPlayback!.mouthInput(for: view.audioMouthIndex)
        mouth = input.openness; mouthShape = input.shape
        artwork.player.sample(at: time, gaze: gaze.position, mouth: mouth, blink: blink)
        view.setNeedsDisplay(view.seatedSpriteRect.insetBy(dx: -20*view.layoutScale, dy: -12*view.layoutScale))
    }
    func draw(in context: CGContext) {
        guard let view else { return }
        let rect = view.seatedSpriteRect
        artwork.draw(in: context, anchor: CGPoint(x: rect.midX, y: rect.minY),
                     scale: Double(view.layoutScale), blink: max(blink, Double(view.headPatReactionSample?.amount ?? 0)),
                     mouth: mouth, mouthShape: mouthShape)
    }
    var diagnostics: [String: Any] {
        ["running":running,"ticks":ticks,"thinking":thinking,"clip":thinkingClip,
         "clock":clock,"blink":blink,"mouth":mouth,"mouthShape":mouthShape ?? "default","resourceReads":artwork.resourceReads,
         "decodedImages":artwork.decodedImages,"decodedBytes":artwork.decodedBytes,
         "draws":artwork.drawCount,"drawOperations":artwork.drawOperations,
         "clothForms":artwork.clothPatchImagesBuilt,"hair":artwork.selection["hair"] ?? "",
         "appearanceError":appearanceError ?? ""]
    }
}
