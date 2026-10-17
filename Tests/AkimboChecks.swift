import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AkimboChecks {
    static func run() throws {
        func check(_ value: Bool, _ message: String) { OverlayGeometryChecks.require(value, message) }
        check(AkimboReaction.boundedUtterancePause(.nan) == 2 &&
              AkimboReaction.boundedUtterancePause(-1) == 0 &&
              AkimboReaction.boundedUtterancePause(4) == 3,
              "the persisted pause defaults to two seconds and stays within the slider range")
        var streak = HeadPatStreak()
        check(!streak.record(at: 0) && !streak.record(at: 3) && streak.record(at: 6), "exactly the third accepted gesture triggers")
        check(streak.count == 0 && !streak.record(at: 9), "triples do not overlap")
        streak.reset(); _ = streak.record(at: 0); _ = streak.record(at: 3)
        check(!streak.record(at: 12) && streak.count == 1, "a long pause starts a new streak")
        streak.reset(); _ = streak.record(at: 0); streak.reset()
        check(!streak.record(at: 3) && streak.count == 1, "cancelled interactions clear accumulated pats")
        check(AkimboReaction.frame(at: 0) == 0 && AkimboReaction.frame(at: AkimboReaction.transition-0.02) == 13, "thinking smoothly reaches open-eyed akimbo")
        check(AkimboReaction.frame(at: AkimboReaction.duration-0.02) == 0 && AkimboReaction.frame(at: AkimboReaction.duration) == nil,
            "the reverse transition returns to thinking and completes")
        let cueTime = 9.0
        let timeline = (0..<Int(ceil(AkimboReaction.duration*30))).compactMap {
            AkimboReaction.frame(at: Double($0)/30, winkElapsed: Double($0)/30-cueTime)
        }
        var winkEpisodes = 0, wasWinking = false
        for frame in timeline {
            let winking = AkimboReaction.winkFrames.contains(frame)
            if winking && !wasWinking { winkEpisodes += 1 }
            wasWinking = winking
        }
        let closedSeconds = Double(timeline.filter { AkimboReaction.winkFrames.contains($0) }.count)/30
        check(closedSeconds >= 0.8 && closedSeconds <= 0.9, "the closed wink holds for about 0.84 seconds")
        check(winkEpisodes == 1, "the entire reaction winks exactly once, including return")
        check((0..<360).allSatisfy { AkimboReaction.frame(at: AkimboReaction.transition+Double($0)/30) == 13 },
              "held akimbo stays open-eyed until the caption cue")
        check(AkimboReaction.frame(at: cueTime, winkElapsed: 0.01) == 14 &&
              AkimboReaction.frame(at: cueTime+0.37, winkElapsed: AkimboReaction.winkStep*3+0.01) == 17 &&
              AkimboReaction.frame(at: cueTime+AkimboReaction.winkDuration-0.01, winkElapsed: AkimboReaction.winkDuration-0.01) == 21,
              "complete head-tilt poses progress from upright to wink and upright again")
        check(AkimboSpeech.shape("我") == 5 && AkimboSpeech.shape("你") == 4 && AkimboSpeech.shape("不") == 6 &&
              AkimboSpeech.shape("，") == nil, "Mandarin vowel mouth shapes and punctuation are mapped from the text")
        var maximumMouthChanges = 0
        let speechStart = ProcessInfo.processInfo.systemUptime
        for speed in [5.0, 25.0, 40.0] {
            for utterance in AkimboReaction.utterances.indices {
                let count = AkimboReaction.utterances[utterance].count
                var player = AkimboSpeechPlayer(), previous: Int?, changes: [Double] = [], sawSpeech = false
                for i in 0...Int(ceil((Double(count)/speed+0.6)*60)) {
                    let now = Double(i)/60, revealed = min(count, Int(now*speed))
                    player.observe(utterance: utterance, revealed: revealed, typing: revealed < count)
                    player.advance(at: now)
                    if player.mouth != previous { changes.append(now); previous = player.mouth }
                    if player.mouth != nil { sawSpeech = true }
                    let recent = changes.filter { now-$0 < 1 }.count
                    maximumMouthChanges = max(maximumMouthChanges, recent)
                }
                check(sawSpeech && player.mouth == nil, "speech starts with typing and releases to rest at \(speed) characters/s")
                player.observe(utterance: utterance, revealed: 1, typing: true); player.advance(at: 100)
                player.reset(); check(player.mouth == nil, "interruption immediately resets the text mouth")
            }
        }
        check(maximumMouthChanges <= 8, "text mouths change at most eight times in a sliding second")
        let speechScheduleSeconds = ProcessInfo.processInfo.systemUptime-speechStart
        let artwork = AkimboArtwork.shared
        check(artwork.available && artwork.decodedBytes <= 20*1024*1024, "twenty-two complete poses fit the 20 MiB decoded budget")
        let folder = URL(fileURLWithPath: "output/head-pat-akimbo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func pat(_ view: SubtitleView, at time: Double) {
            let h = view.headPatRegion
            for (i, x) in HeadPatChecks.stroke.enumerated() {
                view.observeHeadPat(at: NSPoint(x: h.minX+x*h.width, y: h.midY),
                    pressed: false, visibleHit: true, now: time+Double(i)*0.02)
            }
        }
        func scene(_ controller: OverlayController) -> CGImage {
            let windows = [controller.panel] + (controller.panel.childWindows ?? []).filter { $0.isVisible }
            let area = windows.reduce(controller.panel.frame) { $0.union($1.frame) }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(area.width*2)), pixelsHigh: Int(ceil(area.height*2)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = area.size
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(srgbRed: 0.13, green: 0.17, blue: 0.23, alpha: 1).setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: area.size)).fill()
            for window in windows {
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                NSImage(cgImage: bitmap.cgImage!, size: view.bounds.size).draw(in: window.frame.offsetBy(dx: -area.minX, dy: -area.minY))
            }
            NSGraphicsContext.restoreGraphicsState(); return rep.cgImage!
        }
        var cases = 0
        var baselineDrawSeconds = 0.0, akimboDrawSeconds = 0.0
        var mouthBaselineSeconds = 0.0, talkingDrawSeconds = 0.0
        var dialogueHeightChanges = 0
        var captionWinkEpisodes = 0
        var sentencePauses: [TimeInterval] = []
        func measureDraw(_ view: NSView) -> Double {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<200 { view.cacheDisplay(in: view.bounds, to: bitmap) }
            return ProcessInfo.processInfo.systemUptime-start
        }
        for scale in [0.5, 1.0, 2.0] {
            let c = OverlayController(), v = c.subtitle
            let configuredPause: Double = scale == 0.5 ? 0 : scale == 2 ? 3 : 2
            v.akimboUtterancePause = configuredPause
            c.update(text: "", context: "", title: "", live: true, mascot: .deepseek,
                font: 18, opacity: 0, bottom: 80, screenIndex: 0, movable: false, visible: true,
                scale: scale, mode: .character)
            OverlayGeometryChecks.settle()
            if scale == 1 { baselineDrawSeconds = measureDraw(v) }
            let anchor = c.panel.frame, start = ProcessInfo.processInfo.systemUptime-12
            pat(v, at: start); check(v.headPatCount == 1 && !v.akimboActive, "first pet remains a normal reaction")
            v.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime+2)
            pat(v, at: start+3); check(v.headPatCount == 2 && !v.akimboActive, "second pet remains a normal reaction")
            v.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime+2)
            let thirdStart = ProcessInfo.processInfo.systemUptime
            pat(v, at: start+6)
            // Slider changes take effect on the next interaction, so the two
            // gaps within this reaction keep the value captured at its start.
            v.akimboUtterancePause = 1
            check(v.headPatCount == 3 && v.akimboActive && v.akimboCount == 1, "third pet starts seated akimbo at every scale")
            check(c.akimboDialogueDiagnostics["visible"] as? Bool == true, "new side dialogue is visible")
            check(c.akimboDialogueDiagnostics["ignoresMouseEvents"] as? Bool == true && !c.panel.isKeyWindow,
                "dialogue never takes focus or pointer input")
            let dialogue = c.panel.childWindows!.first { $0.isVisible && $0.contentView is SubtitleView }!.contentView as! SubtitleView
            let sizing = SubtitleView()
            sizing.mode = .bubble; sizing.layoutScale = dialogue.layoutScale; sizing.fontSize = dialogue.fontSize
            sizing.text = AkimboReaction.utterances[0]
            let titledHeight = sizing.height(for: dialogue.frame.width)
            sizing.showsCaptionHeader = false
            let oneLineHeight = sizing.height(for: dialogue.frame.width)
            check(dialogue.frame.height == oneLineHeight, "first utterance starts at one-line height at every scale")
            check(!dialogue.showsCaptionHeader && dialogue.context.isEmpty &&
                  abs(titledHeight-oneLineHeight-22*dialogue.layoutScale) < 0.01,
                  "reaction bubble removes its title and the reserved header space at every scale")
            check(dialogue.mode == .bubble && dialogue.captionRevealedCharacterCount < dialogue.text.count && dialogue.captionTypewriterRunning && dialogue.text == AkimboReaction.utterances[0],
                "dialogue uses the subtitle UI and starts revealing text (\(dialogue.captionRevealedCharacterCount)/\(dialogue.text.count), running \(dialogue.captionTypewriterRunning))")
            if scale == 1 {
                akimboDrawSeconds = measureDraw(v)
            }
            if scale == 1 {
                let frames = Int(ceil(AkimboReaction.duration*15))
                let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("seated-akimbo-return.gif") as CFURL,
                    UTType.gif.identifier as CFString, frames, nil)!
                CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                var seenUtterances = Set<String>()
                var lastUtterance = 0
                var speakingUtterances = Set<Int>()
                let dialogueSize = dialogue.frame.size
                let thirdLineBoundary = AkimboReaction.utterances[2].prefix { $0 != "\n" }.count
                sizing.text = AkimboReaction.utterances[2]
                let twoLineHeight = sizing.height(for: dialogueSize.width)
                check(twoLineHeight > oneLineHeight, "the explicit comma break adds exactly a second line")
                var previousDialogueHeight = oneLineHeight, expansionCount = 0
                var thirdPageTop: CGFloat?
                var wasCaptionWinking = false
                var completedAt: [Int: TimeInterval] = [:]
                var observedPauses: [TimeInterval] = []
                for i in 0..<frames {
                    while ProcessInfo.processInfo.systemUptime < thirdStart+Double(i)/15 {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.003))
                    }
                    v.advanceHeadPat(at: thirdStart+0.001+Double(i)/15)
                    let utterance = v.akimboUtterance
                    check(dialogue.text == AkimboReaction.utterances[utterance], "exactly one utterance is displayed, without a page counter")
                    let expanded = utterance == 2 && dialogue.captionRevealedCharacterCount >= thirdLineBoundary
                    let cueVisible = utterance == 2 && dialogue.captionRevealedCharacterCount >= AkimboReaction.winkCueCharacterCount
                    check((v.akimboWinkStartedAt != nil) == cueVisible, "wink starts only when the actual typewriter reveals 太")
                    let captionWinking = v.akimboFrame.map { AkimboReaction.winkFrames.contains($0) } ?? false
                    if captionWinking && !wasCaptionWinking { captionWinkEpisodes += 1 }
                    wasCaptionWinking = captionWinking
                    check(!dialogue.showsCaptionHeader && dialogue.context.isEmpty && dialogue.frame.width == dialogueSize.width &&
                          dialogue.frame.height == (expanded ? twoLineHeight : oneLineHeight),
                          "short pages stay one line; third page expands only once its first line is complete")
                    if utterance == 2 {
                        if thirdPageTop == nil { thirdPageTop = dialogue.window!.frame.maxY }
                        check(abs(dialogue.window!.frame.maxY-thirdPageTop!) < 0.01, "expansion keeps the first line and bubble top anchored")
                    }
                    if dialogue.frame.height != previousDialogueHeight { expansionCount += 1; previousDialogueHeight = dialogue.frame.height }
                    seenUtterances.insert(dialogue.text)
                    if v.akimboMouthIndex != nil { speakingUtterances.insert(utterance) }
                    if i == 3 {
                        check(v.akimboMouthIndex != nil, "actual typewriter progress drives the character mouth")
                    }
                    if !dialogue.captionTypewriterRunning, dialogue.captionRevealedCharacterCount == dialogue.text.count {
                        if completedAt[utterance] == nil { completedAt[utterance] = Double(i)/15 }
                    }
                    if let completed = completedAt[utterance], Double(i)/15-completed > 0.29 {
                        check(v.akimboMouthIndex == nil, "mouth returns to rest after each completed caption")
                    }
                    if utterance != lastUtterance {
                        check(utterance == lastUtterance+1, "completed captions advance sequentially without skipping")
                        check(completedAt[lastUtterance] != nil, "previous caption finishes before the next one starts")
                        let pause = Double(i)/15-completedAt[lastUtterance]!
                        check(pause >= 1.9 && pause <= 2.15, "sentences follow after a two-second completion-driven pause")
                        observedPauses.append(pause)
                        check(dialogue.captionRevealedCharacterCount < dialogue.text.count && dialogue.captionTypewriterRunning,
                              "each new utterance restarts the typewriter")
                        lastUtterance = utterance
                    }
                    if i == 3 { check(dialogue.captionRevealedCharacterCount > 0 && dialogue.captionRevealedCharacterCount < dialogue.text.count,
                        "real typewriter clock gradually reveals the dialogue") }
                    let image = scene(c)
                    CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0/15]] as CFDictionary)
                    if [0, 3, 6, 14, 32, 38, 46, 56, 63, 66, 90, 123, 126, 128, 130, 132, 135, 140, 145, 150, 165, 235].contains(i) {
                        let png = CGImageDestinationCreateWithURL(folder.appendingPathComponent("pose-\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
                        CGImageDestinationAddImage(png, image, nil); check(CGImageDestinationFinalize(png), "pose preview saves")
                    }
                }
                check(speakingUtterances.count == 3, "all three real subtitle reveals have talking mouths")
                check(expansionCount == 1, "the whole dialogue resizes once, without per-glyph window layout")
                check(captionWinkEpisodes == 1, "actual typewriter-driven playback winks once after 太, never on entry")
                dialogueHeightChanges = expansionCount
                check(seenUtterances.count == 3, "all three separate utterances were shown")
                check(observedPauses.count == 2, "both sentence gaps follow actual typing completion")
                sentencePauses = observedPauses
                check(CGImageDestinationFinalize(gif), "full entrance, held dialogue and return preview saves")
                check(dialogue.captionRevealedCharacterCount == dialogue.text.count && !dialogue.captionTypewriterRunning, "full dialogue remains readable before the return")
                let bitmap = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                func drawPose(mouth: Int?) -> Double {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    let start = ProcessInfo.processInfo.systemUptime
                    for _ in 0..<200 {
                        NSGraphicsContext.current!.cgContext.clear(v.bounds)
                        artwork.draw(frame: 13, in: v.seatedSpriteRect, mouth: mouth,
                                     animation: MascotAnimation.library[.deepseek])
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    return ProcessInfo.processInfo.systemUptime-start
                }
                mouthBaselineSeconds = drawPose(mouth: nil); talkingDrawSeconds = drawPose(mouth: 2)

            }
            if scale != 1 {
                let completion = ProcessInfo.processInfo.systemUptime
                dialogue.pauseTypewriter()
                v.updateAkimboSpeech(utterance: 0, revealed: AkimboReaction.utterances[0].count, typing: false)
                if configuredPause > 0 {
                    v.advanceHeadPat(at: completion+configuredPause-0.1)
                    check(v.akimboUtterance == 0, "maximum slider pause waits for the configured gap")
                }
                v.advanceHeadPat(at: completion+configuredPause+0.1)
                check(v.akimboUtterance == 1, "slider minimum/maximum affect playback and current interaction keeps its snapshot")
            }
            v.advanceHeadPat(at: thirdStart+AkimboReaction.duration+0.01)
            check(v.akimboWinkStartedAt == nil, "completion clears the pending wink cue")
            check(v.akimboMouthIndex == nil, "mouth state is cleared on completion or cancellation")
            check(!v.akimboActive && c.akimboDialogueDiagnostics["visible"] as? Bool == false, "dialogue disappears when pose returns")
            check(c.panel.frame == anchor && v.originalThinkingPoseActive, "same seated anchor resumes latest thinking")
            v.setMascot(.deepseek, animating: false)
            v.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime+12)
            OverlayGeometryChecks.settle()
            check(!v.seatedMotionAnimating, "extra reaction clock stops")
            let later = start+30
            pat(v, at: later); v.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime+2)
            pat(v, at: later+3); v.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime+2)
            pat(v, at: later+6)
            check(v.akimboActive, "a fresh triple can react after completion")
            check(v.akimboWinkStartedAt == nil, "a fresh reaction waits for its own caption cue")
            v.updateAkimboSpeech(utterance: 0, revealed: AkimboReaction.utterances[0].count, typing: false)
            v.updateAkimboSpeech(utterance: 1, revealed: AkimboReaction.utterances[1].count, typing: false)
            v.updateAkimboSpeech(utterance: 2, revealed: AkimboReaction.winkCueCharacterCount-1, typing: true)
            check(v.akimboWinkStartedAt == nil, "previous pages and the third-page line break cannot trigger a wink")
            v.updateAkimboSpeech(utterance: 2, revealed: AkimboReaction.winkCueCharacterCount, typing: true)
            let firstCueTime = v.akimboWinkStartedAt
            check(firstCueTime != nil, "revealing 太 starts the wink independently of the reaction clock")
            v.updateAkimboSpeech(utterance: 2, revealed: AkimboReaction.utterances[2].count, typing: false)
            check(v.akimboWinkStartedAt == firstCueTime, "later characters never restart the wink")
            v.observeHeadPat(at: .zero, pressed: true, visibleHit: false, now: later+7)
            check(v.akimboWinkStartedAt == nil, "drag cancellation clears the wink cue")
            check(v.akimboMouthIndex == nil, "mouth state is cleared on completion or cancellation")
            check(!v.akimboActive && c.akimboDialogueDiagnostics["visible"] as? Bool == false,
                "button/drag cancels the pose and dialogue together")
            let edgeStart = later+12
            pat(v, at: edgeStart); v.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime+2)
            pat(v, at: edgeStart+3); v.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime+2)
            pat(v, at: edgeStart+6)
            v.enterScreenEdge(.left)
            check(v.akimboMouthIndex == nil, "mouth state is cleared on completion or cancellation")
            check(!v.akimboActive && c.akimboDialogueDiagnostics["visible"] as? Bool == false,
                "entering screen edge cancels pose, dialogue and accumulated pets")
            c.panel.orderOut(nil); cases += 1
        }
        let area = NSRect(x: 0, y: 0, width: 1440, height: 900), size = NSSize(width: 258, height: 135)
        let left = AkimboDialogue.placement(sprite: NSRect(x: 20, y: 70, width: 180, height: 240), area: area, size: size)
        let right = AkimboDialogue.placement(sprite: NSRect(x: 1240, y: 70, width: 180, height: 240), area: area, size: size)
        check(left.1 && !right.1 && area.contains(left.0) && area.contains(right.0), "side dialogue flips at screen edges")
        let timedStart = ProcessInfo.processInfo.systemUptime
        var frameChanges = 0, previous: Int?
        let timelineTicks = Int(ceil(AkimboReaction.duration*30))+1
        for i in 0..<timelineTicks {
            let frame = AkimboReaction.frame(at: Double(i)/30, winkElapsed: Double(i)/30-cueTime)
            if frame != previous { frameChanges += 1; previous = frame }
        }
        let warm = ProcessInfo.processInfo.systemUptime-timedStart
        check(frameChanges < 40, "held pose changes redraw only when a complete frame changes")
        let result: [String: Any] = ["passed": true, "geometryCases": cases, "frames": artwork.frames.count, "winkEpisodes": winkEpisodes, "winkClosedSeconds": closedSeconds, "utterances": AkimboReaction.utterances, "duration": AkimboReaction.duration, "decodedBytes": artwork.decodedBytes,
            "coldLoadSeconds": artwork.loadSeconds, "warmTimelineTicks": timelineTicks, "warmTimelineSeconds": warm, "frameChanges": frameChanges,
            "drawSamples": 200, "baselineDrawSeconds": baselineDrawSeconds, "akimboDrawSeconds": akimboDrawSeconds,
            "speechScheduleSeconds": speechScheduleSeconds, "maxMouthChangesPerSecond": maximumMouthChanges,
            "mouthDrawSamples": 200, "mouthBaselineDrawSeconds": mouthBaselineSeconds, "talkingDrawSeconds": talkingDrawSeconds,
            "dialogueHeightChanges": dialogueHeightChanges, "stagedCaptionHeight": true, "captionHeaderVisible": false,
            "captionWinkEpisodes": captionWinkEpisodes, "winkCueCharacterCount": AkimboReaction.winkCueCharacterCount,
            "sentencePauses": sentencePauses, "requestedSentencePause": AkimboReaction.utterancePause,
            "extraPersistentTimers": 0, "runtimeNetworkRequests": 0, "runtimeModelCalls": 0,
            "boundary": "controlled native AppKit views and gesture dispatch; manual signed-app acceptance separate"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
