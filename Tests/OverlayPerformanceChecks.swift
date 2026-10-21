import AppKit
import CaptionCore

private func require(_ value: Bool, _ message: String = "", line: Int = #line) {
    if !value {
        try? FileHandle.standardError.write(contentsOf: Data("FAIL line=\(line): \(message)\n".utf8))
        exit(1)
    }

}

private func controlScreenFrame(_ button: NSButton) -> NSRect {
    button.window!.convertToScreen(button.convert(button.bounds, to: nil))
}
private func controlCenter(_ button: NSButton) -> NSPoint {
    let frame = controlScreenFrame(button)
    return NSPoint(x: frame.midX, y: frame.midY)
}

@main
struct OverlayPerformanceChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if ProcessInfo.processInfo.environment["CONTROL_CONTENT_SYNC_ONLY"] == "1" { checkControlContentSync(); return }
        if ProcessInfo.processInfo.environment["CONTROL_DRAG_ONLY"] == "1" { checkControlDrag(); return }
        if ProcessInfo.processInfo.environment["CONVERSATION_CONTROLS_ONLY"] == "1" { checkConversationControls(); return }
        if ProcessInfo.processInfo.environment["BALANCE_ALERT_ONLY"] == "1" { checkBalanceAlert(); return }
        if ProcessInfo.processInfo.environment["MULTI_HARNESS_CLOSE_ONLY"] == "1" { checkConcurrentHarnessClose(); return }
        if ProcessInfo.processInfo.environment["CAPTION_CLOSE_ONLY"] == "1" { checkCaptionCloseLifecycle(); return }
        if let path = ProcessInfo.processInfo.environment["DSH_READ_CHECK"] {
            let record = SessionRecord(url: URL(fileURLWithPath: path), source: .deepseek)
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<128 { _ = try! record.poll() }
            require(record.snapshot.readable && !record.snapshot.id.isEmpty, "Real compressed DSH transcript is readable")
            require(!record.isSubagent && record.parentSessionID == nil, "Seeded main session remains visible")
            require(record.snapshot.caption != nil || record.snapshot.answer != nil, "Main session text is retained")
            print("PASS: real DSH compressed seeded-main read; caption retained; ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
            return
        }
        if ProcessInfo.processInfo.environment["DSH_APPROVAL_ONLY"] == "1" { checkDSHApproval(); return }
        if ProcessInfo.processInfo.environment["WORKING_DOTS_ONLY"] == "1" { checkWorkingDots(); return }
        if ProcessInfo.processInfo.environment["TASK_APPEARANCE_ONLY"] == "1" { checkTaskAppearance(); return }
        let controller = OverlayController()
        var text = "正在检查性能，保留中文、emoji👨‍👩‍👧‍👦和字幕换行。"
        func update(font: Double = 24, opacity: Double = 0.7, live: Bool = false,
                    anchor: NSPoint? = nil, scale: CGFloat = 1, typewriter: String? = nil) {
            controller.update(text: text, context: "Codex · 性能验收", title: "验收",
                live: live, mascot: nil, font: font, opacity: opacity, bottom: 80, screenIndex: 0,
                movable: false, visible: true, anchor: anchor, scale: scale, mode: .bubble,
                typewriterID: typewriter)
        }
        update()
        controller.subtitle.display()
        let initial = controller.panel.frame
        #if PERFORMANCE_COUNTERS
        let measures = controller.subtitle.textMeasurementCount
        let frames = controller.frameApplicationCount
        #endif
        for round in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<1000 { update() }
            print("PERF: unchanged 1000 overlay updates round=\(round+1) ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
        }
        require(controller.panel.frame == initial)
        #if PERFORMANCE_COUNTERS
        try? FileHandle.standardError.write(contentsOf: Data("COUNTERS measures=\(controller.subtitle.textMeasurementCount-measures) frames=\(controller.frameApplicationCount-frames) dirty=\(controller.subtitle.needsDisplay)\n".utf8))
        require(controller.subtitle.textMeasurementCount == measures, "Unchanged updates must reuse text measurements")
        require(controller.frameApplicationCount == frames, "Unchanged geometry must not apply native frames")
        require(!controller.subtitle.needsDisplay, "Unchanged updates must not invalidate rendering")
        print("PERF: unchanged updates=5000 newMeasurements=0 frameApplications=0 redrawInvalidations=0")
        #endif
        update(opacity: 0.5)
        require(controller.subtitle.backdrop == 0.5 && controller.subtitle.needsDisplay)
        controller.subtitle.needsDisplay = false
        update(opacity: 0.5, live: true)
        require(controller.subtitle.isLive && controller.subtitle.needsDisplay)
        text = "全新字幕\n" + String(repeating: "变化内容👨‍👩‍👧‍👦", count: 20)
        update(font: 30, scale: 1.2)
        require(controller.subtitle.text == text && controller.subtitle.needsDisplay)
        let view = controller.subtitle
        let fresh = SubtitleView()
        fresh.text = text; fresh.fontSize = view.fontSize; fresh.layoutScale = view.layoutScale; fresh.mode = .bubble
        require(view.preferredWidth(available: 900) == fresh.preferredWidth(available: 900))
        require(view.height(for: 420) == fresh.height(for: 420))
        view.captionLayoutText = "第一行"; fresh.captionLayoutText = "第一行"
        require(view.height(for: 420) == fresh.height(for: 420), "Staged captions invalidate measurement input")
        view.captionLayoutText = nil
        update(anchor: NSPoint(x: initial.midX + 30, y: initial.minY + 20))
        require(controller.panel.frame != initial)
        text = "逐字显示中文👨‍👩‍👧‍👦"; update(typewriter: "typing")
        let end = Date().addingTimeInterval(0.2)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        require(view.captionRevealedCharacterCount > 0 && view.captionTypewriterRunning)
        view.pauseTypewriter(); update(typewriter: "typing")
        require(view.captionTypewriterRunning, "Unchanged caption must resume paused typing")
        view.pauseTypewriter()
        text = "性能优化验收：中文与 emoji👨‍👩‍👧‍👦保持完整。"
        update()
        let output = URL(fileURLWithPath: "output/performance-audit")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try! controller.exportPreview(to: output.appendingPathComponent("overlay-preview.png"))
        controller.panel.orderOut(nil)
        checkSharedRoles()
        checkQuestion()
        print("PASS: overlay reuse, content/style/font/scale/staged-text invalidation, geometry and typewriter resume")
    }

    static func checkCaptionCloseLifecycle() {
        let overlays = ProjectOverlays()
        let request = UserQuestionRequest.parse(id: "close-lifecycle", turnID: nil, asynchronous: true,
            questions: [["title": "切换中的提问", "options": ["继续", "停止"]]], date: Date())!
        var closed = 0
        func item(_ id: String, question: Bool = false) -> OverlayItem {
            OverlayItem(id: id, text: String(repeating: "切换中的字幕。", count: 20),
                header: "OpenCode · 回答", title: "检查", active: false, mascot: .opencode,
                question: question ? request : nil, onOpenConversation: { nil },
                onCaptionClose: { closed += 1 }, onQuestionReply: { _, _ in })
        }
        func update(_ items: [OverlayItem]) {
            overlays.update(items, font: 18, opacity: 0.7, bottom: 50, screenIndex: 0,
                movable: false, focusedID: "a", bubblesFixedToCharacter: true,
                restingMascots: [.opencode], characterBindings: [.opencode: .codex])
        }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.45)) }
        update([item("a", question: true), item("b")]); drain()
        update([item("a"), item("b")])
        let removed = overlays.controller(for: "a")!
        let retained = overlays.controller(for: "b")!
        let wasTransitioning = removed.isQuestionTransitionRunning
        drain()
        for controller in [removed, retained] {
            guard let button = controller.captionCloseButton, let window = button.window else { fatalError("Missing close control") }
            let center = controlCenter(button)
            let hit = NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0)
            require(hit == window.windowNumber, "Close control must be above sibling bubble windows: hit=\(hit), button=\(window.windowNumber)")
            require(button.acceptsFirstMouse(for: nil), "Close control must accept the first click while another app is active")
            // A neighboring caption's body may cover this button geometrically.
            let overlap = NSPanel(contentRect: controlScreenFrame(button).insetBy(dx: -40, dy: -30), styleMask: [.borderless], backing: .buffered, defer: false)
            overlap.level = controller.panel.level
            overlap.ignoresMouseEvents = true
            overlap.backgroundColor = NSColor.white.withAlphaComponent(0.5)
            overlap.orderFrontRegardless(); drain()
            require(NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0) == window.windowNumber,
                "A noninteractive overlay must not intercept the close button")
            overlap.orderOut(nil)
        }
        // Hide while both resize animation and queued native layout are pending.
        removed.panel.setFrameOrigin(NSPoint(x: removed.panel.frame.minX + 4, y: removed.panel.frame.minY))
        update([item("b")]); drain()
        require(!removed.panel.isVisible, "Removed caption remains hidden")
        require(!removed.captionCloseVisible, "Removed caption must not leave a close window")
        require(!removed.isQuestionTransitionRunning, "Hidden captions stop resize timers")
        require(removed.panel.childWindows?.allSatisfy { !$0.isVisible } ?? true, "All caption controls hide together")
        require(retained.panel.isVisible && retained.captionCloseVisible, "Other caption remains usable")
        update([item("a"), item("b")]); drain()
        require(removed.panel.isVisible && removed.captionCloseVisible, "Reused caption restores close control")
        removed.captionCloseButton?.performClick(nil)
        require(closed == 1, "Restored close control still calls its action")
        update([]); drain()
        require(!removed.captionCloseVisible && !retained.captionCloseVisible, "Empty stack has no close controls")
        print("PASS: close-control lifecycle; transition exercised=\(wasTransitioning); removal, queued layout, reuse, sibling and empty stack")
    }

    static func checkConcurrentHarnessClose() {
        let sources: [SessionSource] = [.codex, .deepseek, .claude, .doubao, .opencode, .workbuddy]
        var totalHitChecks = 0, totalClosed = 0, idleCacheMisses = 0
        for shared in [true, false] {
            let overlays = ProjectOverlays()
            var states: [String: ProjectCaptionState] = [:]
            var snapshots: [String: SessionSnapshot] = [:]
            let choices: [CharacterChoice] = [.codex, .deepseek, .pinkBear]
            let bindings = Dictionary(uniqueKeysWithValues: sources.enumerated().map {
                (CaptionMascot(rawValue: $0.element.preferenceID)!, shared ? CharacterChoice.codex : choices[$0.offset % choices.count])
            })
            for source in sources {
                for index in 0..<2 {
                    let id = source.preferenceID + "-\(index)"
                    var session = SessionSnapshot(path: "/fixture/\(id)", id: id, active: true)
                    session.source = source
                    session.caption = Caption(text: String(repeating: "并发会话 \(id) 的字幕内容。", count: 5), kind: .progress, date: Date())
                    let state = ProjectCaptionState(session: session)
                    state.receive(session, answers: true, tools: true, font: 18)
                    states[id] = state; snapshots[id] = session
                }
            }
            func update() {
                let items = states.keys.sorted().compactMap { id -> OverlayItem? in
                    let state = states[id]!
                    guard !state.isDismissed else { return nil }
                    return OverlayItem(id: id, text: state.text, header: state.header, title: id, active: true,
                        mascot: CaptionMascot(rawValue: state.session.source.preferenceID),
                        onCaptionClose: { state.dismissCaption() })
                }
                overlays.update(items, font: 18, opacity: 0.6, bottom: 30, screenIndex: 0,
                    movable: false, focusedID: "codex-0", bubblesFixedToCharacter: true,
                    characterBindings: bindings)
            }
            func drain(_ seconds: Double = 0.08) {
                NSApp.updateWindows()
                RunLoop.main.run(until: Date().addingTimeInterval(seconds))
                for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
                NSApp.updateWindows()
            }
            var minButtonWidth = CGFloat.greatestFiniteMagnitude
            func checkHits() {
                for id in overlays.visibleIDs {
                    let controller = overlays.controller(for: id)!
                    guard let button = controller.captionCloseButton, let window = button.window else { fatalError("Missing close \(id)") }
                    require(controller.captionCloseVisible, "Concurrent close visible: \(id)")
                    let center = controlCenter(button)
                    let hit = NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0)
                    if hit != window.windowNumber {
                        print("HIT_FAILURE",id,"point",center,"expected",window.windowNumber,"hit",hit)
                        if let intercepted = NSApp.windows.first(where: { $0.windowNumber == hit }) {
                            print("INTERCEPTOR",intercepted.frame,intercepted.isVisible,"parent",intercepted.parent?.windowNumber ?? -1)
                        }
                        for otherID in overlays.visibleIDs {
                            let other = overlays.controller(for: otherID)!
                            print("CLOSE_FRAME",otherID,other.panel.frame,other.captionCloseButton?.window?.windowNumber ?? -1,other.captionCloseButton?.window?.frame ?? .zero)
                        }
                    }
                    require(hit == window.windowNumber,
                        "Concurrent harness close intercepted: \(id), shared=\(shared)")
                    require(window.screen?.frame.contains(center) == true, "Close remains on screen: \(id)")
                    minButtonWidth = min(minButtonWidth, button.frame.width)
                    totalHitChecks += 1
                }
            }
            update(); drain(0.5)
            require(overlays.visibleIDs.count == 12, "All six harnesses / twelve conversations shown")
            checkHits()
            let start = ProcessInfo.processInfo.systemUptime
            var timings: [Double] = []
            for round in 0..<60 {
                for id in snapshots.keys.sorted() {
                    var session = snapshots[id]!
                    let caption = session.caption!
                    session.caption = Caption(text: caption.text + "继续\(round)。", kind: .progress, date: Date())
                    snapshots[id] = session
                    states[id]!.receive(session, answers: true, tools: true, font: 18)
                }
                let began = ProcessInfo.processInfo.systemUptime
                update()
                timings.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
                if round % 10 == 0 { drain(); checkHits() }
            }
            // Let real page timers advance while all sources stay active.
            drain(4)
            for state in states.values { state.tick() }
            update(); drain(); checkHits()
            let cover = NSPanel(contentRect: NSScreen.screens[0].visibleFrame,
                styleMask: [.borderless], backing: .buffered, defer: false)
            cover.level = .statusBar; cover.isOpaque = false; cover.ignoresMouseEvents = true
            cover.backgroundColor = NSColor.white.withAlphaComponent(0.15)
            cover.orderFrontRegardless(); drain(); checkHits()
            cover.orderOut(nil)
            update(); drain(); update()
            let controllers = states.keys.sorted().map { overlays.controller(for: $0)! }
            #if PERFORMANCE_COUNTERS
            let counters = controllers.map { ($0.subtitle.textMeasurementCount, $0.frameApplicationCount) }
            #endif
            let idleStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 { update() }
            let idleMS = (ProcessInfo.processInfo.systemUptime - idleStart) * 1000
            #if PERFORMANCE_COUNTERS
            for (index, controller) in controllers.enumerated() {
                let measures = controller.subtitle.textMeasurementCount - counters[index].0
                let frames = controller.frameApplicationCount - counters[index].1
                if measures != 0 || frames != 0 {
                    idleCacheMisses += 1
                    print("PERF_MISS shared=\(shared) index=\(index) measures=\(measures) frames=\(frames)")
                }
            }
            #endif
            for id in states.keys.sorted() {
                let controller = overlays.controller(for: id)!
                controller.captionCloseButton!.performClick(nil)
                require(states[id]!.isDismissed, "Close dispatches to the correct harness conversation")
                totalClosed += 1
                update(); drain()
                require(!controller.panel.isVisible && !controller.captionCloseVisible, "Closed harness leaves no ghost control")
                checkHits()
            }
            require(overlays.visibleIDs.isEmpty, "All concurrent conversations close independently")
            // A closed streaming message must stay closed as other sources refresh.
            for (id, session) in snapshots { states[id]!.receive(session, answers: true, tools: true, font: 18) }
            update(); drain()
            require(overlays.visibleIDs.isEmpty, "Concurrent refresh must not revive dismissed messages")
            timings.sort()
            print(String(format: "PASS: concurrent harnesses=6 chats=12 shared=%@; update median=%.3fms p95=%.3fms idle100=%.3fms minCloseWidth=%.1fpx elapsed=%.2fs",
                String(shared), timings[timings.count/2], timings[Int(Double(timings.count-1)*0.95)], idleMS, minButtonWidth,
                ProcessInfo.processInfo.systemUptime-start))
        }
        require(idleCacheMisses == 0, "Concurrent idle cache misses=\(idleCacheMisses)")
        print("PASS: multi-harness close hitChecks=\(totalHitChecks) closed=\(totalClosed); streaming, pagination, overlap, idle cache and no ghost/revival")
    }

    static func checkBalanceAlert() {
        let overlays = ProjectOverlays()
        var hoverQueries = 0
        let away = NSPoint(x: -100_000, y: -100_000)
        func update(_ warning: Bool, shared: Bool) {
            let bindings: [CaptionMascot: CharacterChoice] = shared ? [.codex: .codex, .deepseek: .codex] : [.deepseek: .codex]
            overlays.update([], font: 18, opacity: 0.6, bottom: 40, screenIndex: 0, movable: false, focusedID: "",
                restingMascots: Set(bindings.keys), characterBindings: bindings,
                fallbackMetrics: [.deepseek: OverlayHoverMetrics(averageSpeed: 42,
                    quotaText: warning ? "⚠️ 普通余额偏低 · 账户余额 ¥0.50 · 赠送 ¥100.00" : "账户余额 ¥2.00",
                    onHover: { hoverQueries += 1 }, persistent: warning)])
        }
        for shared in [false, true] {
            update(false, shared: shared)
            let character = overlays.character(for: .deepseek)!
            character.refreshSpeedHover(at: away, leftButtonDown: false)
            require(!character.hoverMetricsWindowVisible, "Before a hover query, no balance warning is shown")
            let beforeHover = hoverQueries
            let inside = NSPoint(x: character.panel.frame.midX, y: character.panel.frame.midY)
            character.refreshSpeedHover(at: inside, leftButtonDown: false)
            require(hoverQueries == beforeHover + 1, "Only entering a real hover requests balance")
            character.refreshSpeedHover(at: inside, leftButtonDown: false)
            require(hoverQueries == beforeHover + 1, "Remaining hovered must not repeat balance requests")
            update(true, shared: shared)
            character.refreshSpeedHover(at: away, leftButtonDown: false)
            let afterQuery = hoverQueries
            require(character.hoverMetricsWindowVisible, "Low paid balance proactively displays speed window without hovering")
            require(character.hoverMetricsText.contains("⚠️") && character.hoverMetricsText.contains("0.50"), "Warning and paid balance remain visible with bonus")
            let layouts = character.metricsLayoutCount
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<500 {
                character.refreshSpeedHover(at: away, leftButtonDown: false)
            }
            require(character.metricsLayoutCount == layouts, "Persistent balance window reuses geometry")
            require(hoverQueries == afterQuery, "Proactive visibility must not cause balance API queries")
            print("PERF: balance warning shared=\(shared) idle500 ms=\((ProcessInfo.processInfo.systemUptime-started)*1000), newLayouts=0, extraQueries=0")
            update(false, shared: shared)
            character.refreshSpeedHover(at: away, leftButtonDown: false)
            require(!character.hoverMetricsWindowVisible, "Recovery or threshold change restores hover-only display")
            update(true, shared: shared)
            character.refreshSpeedHover(at: away, leftButtonDown: false)
            require(character.hoverMetricsWindowVisible, "Warning can reappear")
            character.hide()
            require(!character.hoverMetricsWindowVisible, "Disabling or hiding character clears persistent window")
        }
        print("PASS: balance warning proactive visibility, shared roles, recovery, no recursive queries, cached layout and hide")
    }

    static func checkConversationControls() {
        var opened: [String] = [], closed: [String] = []
        let controllers = (0..<3).map { _ in OverlayController(interactive: true) }
        func drain() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            for w in NSApp.windows where w.isVisible { w.displayIfNeeded() }
        }
        func update(_ index: Int, close: Bool = true) {
            let id = "会话\(index)"
            controllers[index].update(text: "正文 \(id)", context: "Codex · 回答 · " + id, title: id,
                live: true, mascot: nil, font: 18, opacity: 0.6, bottom: 40, screenIndex: 0,
                movable: false, visible: true, anchor: NSPoint(x: 700, y: 180 + index * 110),
                mode: .bubble, onOpenConversation: { opened.append(id); return nil },
                onCaptionClose: close ? { closed.append(id) } : nil)
        }
        for i in controllers.indices { update(i, close: i != 2) }
        drain()
        for (index, controller) in controllers.enumerated() {
            let link = controller.conversationButton!
            let buttons: [NSButton] = [link] + (controller.captionCloseButton.map { [$0 as NSButton] } ?? [])
            let cover = NSPanel(contentRect: controller.panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.level = controller.panel.level; cover.isOpaque = false; cover.ignoresMouseEvents = true
            cover.backgroundColor = NSColor.white.withAlphaComponent(0.15)
            cover.orderFrontRegardless(); drain()
            for button in buttons {
                let w = button.window!
                let point = controlCenter(button)
                require(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == w.windowNumber,
                    "Conversation and close controls receive clicks through noninteractive overlays")
                require(button.acceptsFirstMouse(for: nil), "Both controls accept first clicks")
            }
            cover.orderOut(nil)
            let oldFrame = controlScreenFrame(link)
            controller.panel.setFrameOrigin(NSPoint(x: controller.panel.frame.minX + 21, y: controller.panel.frame.minY + 13))
            drain()
            require(abs(controlScreenFrame(link).minX - oldFrame.minX - 21) < 1 && abs(controlScreenFrame(link).minY - oldFrame.minY - 13) < 1,
                "Conversation hit area follows native bubble movement, including without a close control")
            let closeFrame = controller.captionCloseButton.map { controlScreenFrame($0) }
            require(closeFrame?.intersects(controlScreenFrame(link)) != true, "Close control must not cover conversation link")
            link.performClick(nil)
            require(opened.last == "会话\(index)" && opened.count == index + 1, "Jump dispatches to the correct conversation")
            controller.captionCloseButton?.performClick(nil)
            require(closed.count == min(index+1, 2), "Close dispatch remains usable alongside jump")
            controller.hide(); drain()
            require(link.window?.isVisible == false && !controller.captionCloseVisible, "Both controls hide with their caption")
        }
        print("PASS: Codex conversation/close native hit, first click, overlap, correct callbacks, independent motion, link-only motion and hide")
    }

    static func checkControlDrag() {
        let controller = OverlayController(interactive: true)
        var opened = 0, closed = 0
        controller.update(text: "连续拖动同步检查", context: "Codex · 回答 · 拖动检查", title: "拖动检查",
            live: false, mascot: nil, font: 18, opacity: 0.6, bottom: 50, screenIndex: 0, movable: true,
            visible: true, anchor: NSPoint(x: 700, y: 300), mode: .bubble,
            onOpenConversation: { opened += 1; return nil }, onCaptionClose: { closed += 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let close = controller.captionCloseButton!.window!
        let link = controller.conversationButton!.window!
        let buttons: [NSButton] = [controller.captionCloseButton!, controller.conversationButton!]
        let offsets = buttons.map { NSPoint(x: controlScreenFrame($0).minX-controller.panel.frame.minX, y: controlScreenFrame($0).minY-controller.panel.frame.minY) }
        func check(_ round: Int) {
            for (i, button) in buttons.enumerated() {
                let control = controlScreenFrame(button)
                let dx = control.minX-controller.panel.frame.minX-offsets[i].x
                let dy = control.minY-controller.panel.frame.minY-offsets[i].y
                require(abs(dx) < 1 && abs(dy) < 1, "Control lags during native drag before main-loop delivery; round=\(round), control=\(i), delta=\(dx),\(dy)")
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let original = controller.panel.frame.origin
        for round in 1...200 {
            controller.panel.setFrameOrigin(NSPoint(x: original.x + CGFloat(round%40), y: original.y + CGFloat(round%25)))
            check(round)
        }
        let parent = NSPanel(contentRect: NSRect(x: 600,y: 100,width: 100,height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        parent.level = controller.panel.level
        parent.orderFrontRegardless()
        controller.attach(to: parent)
        let parentOrigin = parent.frame.origin
        for round in 1...200 {
            parent.setFrameOrigin(NSPoint(x: parentOrigin.x + CGFloat(round%35), y: parentOrigin.y + CGFloat(round%20)))
            check(round+200)
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
        require(buttons.allSatisfy { $0.window === controller.panel && $0.superview === controller.subtitle }, "Control views share the bubble backing during nested character drag")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        for button in [controller.captionCloseButton! as NSButton, controller.conversationButton! as NSButton] {
            button.window!.displayIfNeeded()
            let point = controlCenter(button)
            require(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == button.window!.windowNumber, "Controls remain clickable after continuous drag")
            button.performClick(nil)
        }
        require(opened == 1 && closed == 1, "Both drag-following controls dispatch correctly")
        controller.hide(); parent.orderOut(nil)
        require(!close.isVisible && !link.isVisible, "No controls left after hiding dragged bubble")
        print("PASS: 400 consecutive native moves without event-loop delivery, direct/nested drag, zero control drift; elapsed=\(elapsed)ms; jump/close hit and hide")
    }

    static func checkControlContentSync() {
        let controller = OverlayController(interactive: true)
        var opened = 0, closed = 0
        func update(_ round: Int) {
            controller.update(text: String(repeating: "气泡变高换页。", count: round % 3 + 1),
                context: "Codex · 回答 · 同步检查", title: "同步检查", live: false, mascot: nil,
                font: 18 + Double(round % 3), opacity: 0.6, bottom: 50, screenIndex: 0,
                movable: true, visible: true, anchor: NSPoint(x: 650,y: 250), scale: 1,
                mode: .bubble, onOpenConversation: { opened += 1; return nil }, onCaptionClose: { closed += 1 })
        }
        func screenFrame(_ button: NSButton) -> NSRect {
            button.window!.convertToScreen(button.convert(button.bounds, to: nil))
        }
        func check(_ round: Int) {
            let scale = controller.subtitle.layoutScale, box = controller.subtitle.bubbleFrame
            let rect = NSRect(x:box.maxX-30*scale,y:box.maxY-30*scale,width:24*scale,height:24*scale)
            let expected = controller.panel.convertToScreen(controller.subtitle.convert(rect,to:nil))
            let actual = screenFrame(controller.captionCloseButton!)
            require(abs(expected.minX-actual.minX)<1 && abs(expected.minY-actual.minY)<1,
                "Close must remain anchored to bubble corner during resize without main-loop delivery: round=\(round), actual=\(actual), expected=\(expected)")
        }
        update(0)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        let origin = controller.panel.frame
        for round in 1...200 {
            controller.panel.setFrame(NSRect(x: origin.minX+CGFloat(round%30),y:origin.minY+CGFloat(round%20),
                width:origin.width+CGFloat(round%40),height:origin.height+CGFloat(round%50)), display:false)
            check(round)
        }
        for round in 0..<100 { update(round); check(round+200) }
        controller.captionCloseButton!.performClick(nil)
        controller.conversationButton!.performClick(nil)
        require(closed == 1 && opened == 1, "Close and jump both dispatch after mixed movement and reflow")
        require(controller.captionCloseButton!.window === controller.panel && controller.conversationButton!.window === controller.panel,
            "Control pixels and caption must share one native window")
        controller.panel.displayIfNeeded()
        for button in [controller.captionCloseButton! as NSButton,controller.conversationButton! as NSButton] {
            let rect = screenFrame(button), point = NSPoint(x:rect.midX,y:rect.midY)
            require(NSWindow.windowNumber(at:point,belowWindowWithWindowNumber:0)==controller.panel.windowNumber, "Visible control hits its caption window")
            let local = controller.subtitle.convert(controller.panel.convertPoint(fromScreen:point),from:nil)
            require(controller.subtitle.hitTest(local) === button, "Native view hit test reaches the correct button")
        }
        controller.hide()
        require(!controller.captionCloseVisible && controller.conversationButton!.isHidden,"Both controls hide with caption")
        print("PASS: 200 uninterrupted native moves/resizes + 100 content/font/page reflows, exact corner anchoring, shared backing, both hits/actions and hide")
    }

    static func checkSharedRoles() {
        let overlays = ProjectOverlays()
        let sources: [CaptionMascot] = [.codex, .deepseek, .claude, .doubao, .opencode, .workbuddy]
        let items = sources.map { OverlayItem(id: $0.rawValue, text: "共享角色字幕 \($0.rawValue)",
            header: "Codex · 性能检查", title: $0.rawValue, active: false, mascot: $0) }
        let bindings = Dictionary(uniqueKeysWithValues: sources.map { ($0, CharacterChoice.codex) })
        func update() {
            overlays.update(items, font: 18, opacity: 0.7, bottom: 50, screenIndex: 0,
                movable: false, focusedID: "codex", bubblesFixedToCharacter: true,
                restingMascots: Set(sources), characterBindings: bindings)
        }
        update()
        let controllers = sources.map { overlays.controller(for: $0.rawValue)! }
        let original = controllers.map { $0.panel.frame }
        #if PERFORMANCE_COUNTERS
        let counts = controllers.map { ($0.subtitle.textMeasurementCount, $0.frameApplicationCount) }
        #endif
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { update() }
        print("PERF: six sources/one character 100 refreshes ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
        require(controllers.map { $0.panel.frame } == original)
        #if PERFORMANCE_COUNTERS
        for (i, c) in controllers.enumerated() {
            require(c.subtitle.textMeasurementCount == counts[i].0, "Shared bubbles reuse measurements")
            require(c.frameApplicationCount == counts[i].1, "Shared bubbles reuse native geometry")
        }
        #endif
        require(overlays.visibleIDs.count == 6 && overlays.characterDiagnostics.count == 1)
        let character = overlays.character(for: .codex)!
        let before = character.panel.frame
        character.panel.setFrameOrigin(NSPoint(x: before.minX+12, y: before.minY+7))
        update()
        require(controllers.allSatisfy { $0.panel.parent === character.panel }, "Native parent movement retains attachment")
        overlays.update([], font: 18, opacity: 0.7, bottom: 50, screenIndex: 0,
            movable: false, focusedID: "", characterBindings: [:])
    }

    static func checkDSHApproval() {
        let parser = HarnessEventParser()
        let data = try! JSONSerialization.data(withJSONObject: ["type": "approval/asked", "time": Date().timeIntervalSince1970 * 1000,
            "data": ["id": "native-approval", "toolName": "bash", "reason": "此操作需要写入工作区外的目录，请在 DSH 中确认。"]])
        guard case let .question(request) = parser.parse(data).first! else { fatalError("Missing approval") }
        let controller = OverlayController()
        controller.update(text: "权限申请", context: "DSH · 等待审批", title: "DSH 权限预览", live: false,
            mascot: nil, font: 18, opacity: 0.8, bottom: 80, screenIndex: 0, movable: false, visible: true,
            mode: .bubble, question: request, onOpenConversation: { nil }, onQuestionClose: {}, onQuestionReply: { _, _ in
                fatalError("External approval must never submit through Codex")
            })
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        require(controller.subtitle.statusNeedsInput && !controller.subtitle.showsWorkingDots)
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
        }
        let view = controller.panel.contentView!
        let visible = buttons(view).filter { !$0.isHidden }
        require(visible.contains { $0.title == "去 DSH 处理" && $0.isEnabled })
        require(visible.contains { $0.title == "拒绝" && $0.isEnabled })
        require(visible.contains { $0.title == "允许一次" && $0.isEnabled })
        require(!visible.contains { $0.title == "发送回复" })
        let directory = URL(fileURLWithPath: "output/dsh-approval", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.display()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("native.png"))
        controller.hide()
        if let path = ProcessInfo.processInfo.environment["DSH_APPROVAL_LOG"] {
            let tail = ZstdLogTail(url: URL(fileURLWithPath: path))
            let replay = HarnessEventParser()
            var snapshot = SessionSnapshot(path: "replay")
            var asked = 0, decided = 0, observed = 0
            for _ in 0..<128 {
                for line in try! tail.read() {
                    for event in replay.parse(line) {
                        if case .question = event { asked += 1 }
                        if case .questionResolved = event { decided += 1 }
                        snapshot.apply(event)
                        observed = max(observed, snapshot.pendingQuestions.count)
                    }
                }
            }
            require(asked > 0 && decided > 0 && observed > 0, "Real historical approvals are detected")
            require(snapshot.pendingQuestions.isEmpty, "Processed historical approvals do not linger")
            print("PASS: real DSH approval replay asked=\(asked) decided=\(decided) pending=0")
        }
        print("PASS: native DSH approval card, waiting appearance, external handling only")
    }

    static func checkWorkingDots() {
        let controller = OverlayController()
        func show(_ text: String = "正在整理任务", live: Bool = true, typing: String? = nil) {
            controller.update(text: text, context: "Codex · 工作中", title: "验收", live: live,
                mascot: nil, font: 24, opacity: 0.8, bottom: 80, screenIndex: 0,
                movable: false, visible: true, mode: .bubble, typewriterID: typing)
        }
        show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        require(controller.subtitle.showsWorkingDots)
        require(controller.subtitle.workingDotsRunning || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let frame = controller.panel.frame
        let first = controller.subtitle.workingDotCount
        let measurements = controller.subtitle.textMeasurementCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            require(first != controller.subtitle.workingDotCount, "Working dots advance")
        }
        require(controller.panel.frame == frame, "Dots never resize the panel")
        require(controller.subtitle.textMeasurementCount == measurements, "Dots reuse text layout")
        let directory = URL(fileURLWithPath: "output/working-dots", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = controller.subtitle
        view.display()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("native.png"))
        show("新字幕正在逐字显示", typing: "new-caption")
        require(!view.showsWorkingDots && !view.workingDotsRunning, "Typing suppresses dots")
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        require(view.showsWorkingDots, "Dots resume after typing finishes")
        show(live: false)
        require(!view.showsWorkingDots && !view.workingDotsRunning, "Finished tasks stop dots")
        show()
        controller.hide()
        require(!view.showsWorkingDots && !view.workingDotsRunning, "Hidden captions stop dots")
        print("PASS: native working dots cycle, stable geometry/layout cache, typing/finish/hide lifecycle")
    }

    static func checkTaskAppearance() {
        let controller = OverlayController()
        let request = UserQuestionRequest.parse(id: "appearance", turnID: nil, asynchronous: true,
            questions: [["title": "请选择下一步", "options": ["继续", "暂停"]]], date: Date())!
        func show(completed: Bool = false, question: Bool = false) {
            controller.update(text: completed ? "任务已完成" : "请选择下一步", context: "Codex · 视觉验收", title: "状态预览",
                live: false, mascot: nil, font: 18, opacity: 0.8, bottom: 80, screenIndex: 0,
                movable: false, visible: true, mode: .bubble, question: question ? request : nil,
                completed: completed, onQuestionReply: { _, _ in })
        }
        let directory = URL(fileURLWithPath: "output/caption-status", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture(_ name: String) {
            let view = controller.panel.contentView!
            view.display()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        }
        show(); capture("normal")
        show(completed: true); capture("completed")
        require(controller.subtitle.statusCompleted && !controller.subtitle.statusNeedsInput)
        show(question: true)
        require(!controller.subtitle.statusCompleted && controller.subtitle.statusNeedsInput)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)); capture("waiting-a")
        RunLoop.main.run(until: Date().addingTimeInterval(1.4)); capture("waiting-b")
        show(completed: true)
        require(!controller.subtitle.statusNeedsInput && controller.subtitle.statusCompleted, "Completion clears waiting appearance")
        controller.hide()
        require(!controller.subtitle.statusNeedsInput && !controller.subtitle.statusCompleted, "Hiding clears appearance")
        print("PASS: native task appearance transitions and rendered normal/completed/waiting captures")
    }

    static func checkQuestion() {
        let controller = OverlayController()
        let request = UserQuestionRequest.parse(id: "performance-fixture", turnID: nil, asynchronous: true,
            questions: [["title": "保留提问中的选择", "options": ["选项一", "选项二"]]], date: Date())!
        func update(opacity: Double = 0.7, hue: CGFloat = 0.57) {
            controller.update(text: "保留提问中的选择", context: "Codex · 等待回复", title: "验收",
                live: false, mascot: nil, font: 18, opacity: opacity, bottom: 80, screenIndex: 0,
                movable: false, visible: true, hue: hue, mode: .bubble, question: request, onQuestionReply: { _, _ in })
        }
        update()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let view = controller.panel.contentView as! QuestionReplyView
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
        }
        let choice = buttons(view).first { $0.title.contains("选项一") }!
        choice.performClick(nil)
        for _ in 0..<100 { update() }
        require(controller.panel.contentView === view && choice.state == .on, "Request controls and choice survive polling")
        #if PERFORMANCE_COUNTERS
        let draws = view.drawCount
        #endif
        update(hue: 0.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #if PERFORMANCE_COUNTERS
        require(view.drawCount > draws, "Interactive surface actually draws after hue changes")
        #endif
        require(controller.subtitle.themeHue == 0.2 && choice.state == .on)
        controller.panel.orderOut(nil)
        print("PASS: retained native question controls, selection and style invalidation")
    }
}
