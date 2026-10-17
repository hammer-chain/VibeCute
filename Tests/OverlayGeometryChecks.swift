import AppKit

@main
struct OverlayGeometryChecks {
    static func checkCaptionClose() {
        let overlays = ProjectOverlays()
        var closed = Set<String>()
        var movable = false
        func update() {
            let items = ["first", "second"].filter { !closed.contains($0) }.map { id in
                OverlayItem(id: id, text: "普通字幕关闭验收 \(id)", header: "Codex · 进度 · \(id)", title: id,
                    active: true, mascot: .codex, onOpenConversation: { nil },
                    onCaptionClose: { closed.insert(id); update() })
            }
            overlays.update(items, font: 24, opacity: 0.7, bottom: 80, screenIndex: 0,
                movable: movable, focusedID: "first", bubblesFixedToCharacter: true,
                restingMascots: [.codex], characterBindings: [.codex: .codex])
        }
        update(); settle()
        let first = overlays.controller(for: "first")!
        require(first.captionCloseVisible && first.panel.ignoresMouseEvents,
                "ordinary close button is visible even when the caption is click-through")
        require(first.captionCloseButton?.isEnabled == true, "ordinary close button accepts native clicks")
        require(first.captionCloseButton?.window?.isMovable == false, "close control cannot be dragged away from its caption")
        let header = first.subtitle.conversationLinkFrame
        let close = first.captionCloseButton!.window!.frame.offsetBy(dx: -first.panel.frame.minX, dy: -first.panel.frame.minY)
        require(!header.intersects(close), "close control does not overlap the conversation link")
        first.captionCloseButton!.performClick(nil); settle()
        require(closed == ["first"] && overlays.visibleIDs == ["second"], "native close action removes only its own caption")
        require(!first.captionCloseVisible && !first.panel.isVisible, "hidden captions leave no orphan close control")
        require(overlays.characterDiagnostics.count == 1, "closing a caption keeps the role visible")
        let remaining = overlays.controller(for: "second")!
        movable = true; update(); settle()
        require(remaining.captionCloseVisible, "close control survives refresh and movable-mode changes")
        remaining.captionCloseButton!.performClick(nil); settle()
        require(overlays.visibleIDs.isEmpty && overlays.characterDiagnostics.count == 1,
                "closing the final caption keeps an enabled resting character")
        overlays.update([], font: 24, opacity: 0.7, bottom: 80, screenIndex: 0,
            movable: false, focusedID: "", characterBindings: [:])
    }
    static func checkCaptionCloseTracking() {
        let overlays = ProjectOverlays()
        let sources: [CaptionMascot] = [.codex, .deepseek, .workbuddy]
        func checkOffsets(_ stage: String) {
            for source in sources {
                guard let controller = overlays.controller(for: source.rawValue), controller.panel.isVisible else { continue }
                let button = controller.captionCloseButton!
                let box = controller.subtitle.bubbleFrame, scale = controller.subtitle.layoutScale
                let expected = NSRect(x: controller.panel.frame.minX + box.maxX - 30 * scale,
                    y: controller.panel.frame.minY + box.maxY - 30 * scale, width: 24 * scale, height: 24 * scale)
                let actual = button.window!.frame
                require(near(actual.minX, expected.minX) && near(actual.minY, expected.minY),
                    "close tracks \(stage) for \(source.rawValue): delta \(actual.minX - expected.minX), \(actual.minY - expected.minY)")
            }
        }
        for (index, scale) in [1.0, 2.0, 0.7, 1.5, 1.0].enumerated() {
            let active = index == 4 ? Array(sources.prefix(1)) : sources
            let items = active.map { OverlayItem(id: $0.rawValue, text: "正在更新字幕，改变宽度和字号。", header: "Codex · 进度 · 验收",
                title: "验收", active: true, mascot: $0, onCaptionClose: {}) }
            overlays.update(items, font: 24, opacity: 0.7, bottom: 50, screenIndex: 0, movable: true,
                focusedID: "codex", characterScale: scale, bubblesFixedToCharacter: true,
                restingMascots: Set(sources), characterBindings: [.codex: .codex, .deepseek: .codex, .workbuddy: .codex])
            settle(); checkOffsets("scale \(scale)")
            let role = overlays.character(for: .codex)!.panel
            role.setFrameOrigin(NSPoint(x: role.frame.minX + 12, y: role.frame.minY + 7))
            settle(); checkOffsets("nested parent movement")
            for source in active {
                let bubble = overlays.controller(for: source.rawValue)!.panel
                bubble.setFrame(NSRect(x: bubble.frame.minX + 8, y: bubble.frame.minY + 5,
                    width: bubble.frame.width - 40, height: bubble.frame.height + 10), display: false)
            }
            settle(); checkOffsets("native bubble resize without caption update")
        }
        overlays.update([], font: 24, opacity: 0.7, bottom: 50, screenIndex: 0,
            movable: true, focusedID: "", characterBindings: [:])
    }
    static func checkSharedMetrics() {
        let overlays = ProjectOverlays()
        var queries = 0
        var loading = false
        var balance = "账户余额 -"
        var shared = true
        func update() {
            overlays.update([], font: 18, opacity: 0.7, bottom: 140, screenIndex: 0,
                movable: true, focusedID: "", restingMascots: [.codex, .deepseek],
                characterBindings: [.codex: .deepseek, .deepseek: shared ? .deepseek : .codex],
                fallbackMetrics: [
                    .codex: OverlayHoverMetrics(averageSpeed: 52, quotaText: "额度 90%"),
                    .deepseek: OverlayHoverMetrics(averageSpeed: 31, quotaText: balance,
                        refreshing: loading, onHover: { queries += 1 })])
        }
        update(); settle()
        let character = overlays.character(for: .codex)!
        let point = NSEvent.mouseLocation
        character.panel.setFrameOrigin(NSPoint(x: point.x - character.panel.frame.width / 2,
            y: point.y - character.panel.frame.height / 2))
        character.refreshSpeedHover(at: point, leftButtonDown: false)
        require(character.hoverMetricsText == "Codex\n平均 52.0 token/s\n额度 90%\nDSH\n平均 31.0 token/s\n账户余额 -",
                "shared hover lists both harness names and their metrics vertically")
        require(character.hoverMetricsHeight == 164 && character.hoverMetricsWindowVisible,
                "two source rows fit the unified metrics card")
        require(queries == 1, "one DSH query per shared hover entry")
        loading = true; update()
        character.refreshSpeedHover(at: point, leftButtonDown: false)
        require(character.hoverMetricsDiagnostics["spinnerVisible"] as? Bool == true,
                "shared hover retains the loading spinner and balance placeholder")
        loading = false; balance = "账户余额 ¥86.49"; update()
        character.refreshSpeedHover(at: point, leftButtonDown: false)
        require(character.hoverMetricsText.hasSuffix("账户余额 ¥86.49") &&
                character.hoverMetricsDiagnostics["spinnerVisible"] as? Bool == false,
                "balance updates its own block and stops the spinner")
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { update() }
        require(queries == 1, "100 stationary refreshes do not request the balance again")
        print("INFO: 100 shared metric refreshes: \(ProcessInfo.processInfo.systemUptime - start) seconds; one hover query")
        character.refreshSpeedHover(at: point, leftButtonDown: false)
        let area = character.panel.screen!.visibleFrame
        character.panel.setFrameOrigin(NSPoint(x: area.midX - character.panel.frame.width / 2,
            y: area.midY - character.panel.frame.height / 2))
        var inside = NSPoint(x: character.panel.frame.midX, y: character.panel.frame.midY)
        character.refreshSpeedHover(at: inside, leftButtonDown: false)
        require(character.hoverMetricsFrame.minX >= character.panel.frame.maxX,
                "metrics sit beside the role without covering its body")
        let beforeLayouts = character.metricsLayoutCount
        let queryBefore = queries
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { character.refreshSpeedHover(at: inside, leftButtonDown: false) }
        require(character.metricsLayoutCount == beforeLayouts && queries == queryBefore,
                "stationary hover reuses prepared layout and makes no repeated queries")
        print("INFO: 1000 unchanged side-panel events: \(ProcessInfo.processInfo.systemUptime - began) seconds; zero layouts or queries")
        let card = character.hoverMetricsFrame
        character.refreshSpeedHover(at: NSPoint(x: card.midX, y: card.midY), leftButtonDown: false)
        require(character.hoverMetricsWindowVisible && queries == queryBefore,
                "moving from the role to its card keeps one hover session")
        character.panel.setFrameOrigin(NSPoint(x: area.maxX - character.panel.frame.width - 8,
            y: area.minY + 8))
        inside = NSPoint(x: character.panel.frame.midX, y: character.panel.frame.midY)
        character.refreshSpeedHover(at: inside, leftButtonDown: false)
        require(character.hoverMetricsFrame.maxX <= character.panel.frame.minX && area.contains(character.hoverMetricsFrame),
                "right-edge role places its card on the left within the visible screen")
        character.panel.setFrameOrigin(NSPoint(x: area.minX + 8, y: area.maxY - character.panel.frame.height - 8))
        inside = NSPoint(x: character.panel.frame.midX, y: character.panel.frame.midY)
        character.refreshSpeedHover(at: inside, leftButtonDown: false)
        require(character.hoverMetricsFrame.minX >= character.panel.frame.maxX && area.contains(character.hoverMetricsFrame),
                "left/top-edge role keeps the side card inside the visible screen")
        character.panel.setFrameOrigin(NSPoint(x: area.midX - character.panel.frame.width / 2,
            y: area.midY - character.panel.frame.height / 2))
        character.setHoverMetrics(speed: nil, quota: nil, text: "Codex\n平均 52.0 token/s\n额度 90%\nDSH\n平均 31.0 token/s\n账户余额 ¥86.49\nWorkBuddy\n平均 - token/s", rows: [
            HoverMetricsRow(name: "Codex", speed: 52, quota: "本周剩余 90%"),
            HoverMetricsRow(name: "DSH", speed: 31, quota: "账户余额 ¥86.49"),
            HoverMetricsRow(name: "WorkBuddy", speed: nil, quota: nil)])
        character.refreshSpeedHover(at: NSPoint(x: character.panel.frame.midX, y: character.panel.frame.midY), leftButtonDown: false)
        require(character.panel.childWindows?.contains { $0.frame == character.hoverMetricsFrame } == true,
                "shown metrics attach to the role after hiding and re-entering")
        if let view = character.panel.childWindows?.compactMap({ $0.contentView }).first(where: {
            $0.subviews.contains { ($0 as? NSTextField)?.stringValue.hasPrefix("Codex\n") == true }
        }), let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let folder = URL(fileURLWithPath: "output/side-metrics")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("card.png"))
            let union = character.panel.frame.union(character.hoverMetricsFrame).insetBy(dx: -16, dy: -16)
            let image = NSImage(size: union.size)
            image.lockFocus()
            for (window, contents) in [(character.panel as NSWindow, character.panel.contentView!), (view.window!, view)] {
                if let rep = contents.bitmapImageRepForCachingDisplay(in: contents.bounds) {
                    contents.cacheDisplay(in: contents.bounds, to: rep)
                    rep.draw(in: window.frame.offsetBy(dx: -union.minX, dy: -union.minY))
                }
            }
            image.unlockFocus()
            try! NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("beside-role.png"))
        }
        let view = character.subtitle
        let started = ProcessInfo.processInfo.systemUptime
        for round in 0..<3 {
            let head = view.headPatRegion
            for (index, x) in HeadPatChecks.stroke.enumerated() {
                view.observeHeadPat(at: NSPoint(x: head.minX + x * head.width, y: head.midY),
                    pressed: false, visibleHit: true, now: started + Double(round) * 3 + Double(index) * 0.025)
            }
            if round < 2 { view.advanceHeadPat(at: ProcessInfo.processInfo.systemUptime + 2) }
        }
        require(view.akimboActive && !character.hoverMetricsWindowVisible,
                "akimbo captions take the side space without a metrics card covering them")
        view.cancelHeadPat()
        character.refreshSpeedHover(at: NSPoint(x: character.panel.frame.midX, y: character.panel.frame.midY), leftButtonDown: false)
        require(character.hoverMetricsWindowVisible, "metrics resume after the akimbo dialogue ends")
        shared = false; update(); settle()
        let individual = overlays.character(for: .codex)!
        individual.refreshSpeedHover(at: NSPoint(x: individual.panel.frame.midX, y: individual.panel.frame.midY), leftButtonDown: false)
        require(individual.hoverMetricsText == "平均 52.0 token/s\n额度 90%" && individual.hoverMetricsHeight == 102,
                "separate bindings restore the single-harness metric layout")
        overlays.update([], font: 18, opacity: 0.7, bottom: 140, screenIndex: 0,
            movable: true, focusedID: "", characterBindings: [:])
    }
    static func checkCharacterStacking() {
        let pipeline = ProjectOverlays()
        let sources: [CaptionMascot] = [.codex, .deepseek, .claude]
        func refresh() {
            pipeline.update([], font: 18, opacity: 0.7, bottom: 60, screenIndex: 0,
                movable: true, focusedID: "", restingMascots: Set(sources),
                characterBindings: [.codex: .codex, .deepseek: .deepseek, .claude: .pinkBear])
        }
        refresh()
        let panels = sources.map { pipeline.character(for: $0)!.panel }
        panels.forEach { $0.setFrameOrigin(NSPoint(x: 600, y: 400)) }
        func isFront(_ panel: NSWindow) -> Bool {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let numbers = Set(panels.map(\.windowNumber))
            let order = windows.compactMap { $0[kCGWindowNumber as String] as? Int }.filter { numbers.contains($0) }
            return order.first == panel.windowNumber
        }
        func drag(_ panel: SubtitlePanel) {
            panel.beginManualDrag()
            settle()
            require(isFront(panel), "dragging immediately raises the selected character")
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 6, y: panel.frame.minY))
            panel.finishManualDragIfReleased(buttonDown: false)
        }
        drag(panels[2])
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { refresh() }
        settle()
        require(isFront(panels[2]), "100 caption refreshes preserve the last dragged character on top")
        print("INFO: 100 stacking refreshes across 3 characters: \(ProcessInfo.processInfo.systemUptime - start) seconds; no additional timer")
        drag(panels[0]); refresh(); settle()
        require(isFront(panels[0]), "dragging another character changes the persistent front layer")
        panels[1].beginManualDrag(); panels[1].finishManualDragIfReleased(buttonDown: false)
        refresh(); settle()
        require(isFront(panels[0]), "a click without movement does not replace the last dragged character")
        sources.forEach { pipeline.setSourceHidden($0, true) }
    }
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.08)) }
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }
    static func checkScrollScale() {
        let overlays = ProjectOverlays()
        var scale = 1.0, deliveries = 0
        let item = OverlayItem(id: "scroll", text: "滚轮缩放", header: "Codex", title: "滚轮缩放", active: false, mascot: .codex)
        func update() {
            overlays.update([item], font: 24, opacity: 0.7, bottom: 46, screenIndex: 0,
                movable: true, focusedID: "scroll", characterScale: scale)
        }
        overlays.onCharacterScrollScale = { delta in
            deliveries += 1; scale = min(2, max(0.5, scale + delta)); update()
        }
        update(); settle()
        let panel = overlays.character.panel
        let original = panel.frame
        let font = overlays.controller(for: "scroll")!.subtitle.fontSize
        let event = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!
        panel.sendEvent(event); settle()
        require(scale > 1 && panel.frame.height > original.height, "native upward scroll enlarges character")
        require(near(panel.frame.midX, original.midX) && near(panel.frame.minY, original.minY), "scroll scaling preserves bottom-center anchor")
        panel.handleScaleScroll(delta: -1, precise: false, inverted: false, momentum: false); settle()
        require(abs(scale - 1) < 0.001, "downward scroll shrinks character")
        panel.handleScaleScroll(delta: -1, precise: false, inverted: true, momentum: false); settle()
        require(scale > 1, "natural scrolling setting preserves physical wheel direction")
        let before = deliveries
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<120 { panel.handleScaleScroll(delta: 1, precise: false, inverted: false, momentum: false) }
        settle()
        require(deliveries == before + 1 && scale == 2, "120-event burst coalesces into one bounded scale update")
        for _ in 0..<120 { panel.handleScaleScroll(delta: -1, precise: false, inverted: false, momentum: false) }
        settle()
        require(scale == 0.5 && overlays.controller(for: "scroll")!.subtitle.fontSize == font, "minimum scale preserves caption font")
        let settled = deliveries
        panel.handleScaleScroll(delta: 100, precise: true, inverted: false, momentum: true)
        panel.setManualDragging(true)
        panel.handleScaleScroll(delta: 1, precise: false, inverted: false, momentum: false)
        panel.setManualDragging(false); settle()
        require(deliveries == settled, "momentum and dragging do not change scale")
        print("INFO: 240 scroll events and native relayout, including three 80 ms settles: \(ProcessInfo.processInfo.systemUptime - started) s; no polling")
    }
    static func require(_ condition: Bool, _ label: String) {
        guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        print("PASS: \(label)")
    }


    static func checkQuestions() {
        let overlays = ProjectOverlays()
        let request = UserQuestionRequest.parse(id: "fixture", turnID: nil, asynchronous: true,
            questions: [["title": String(repeating: "这是需要内部滚动的长问题描述，中文和 emoji 🐳 仍然完整。\n", count: 12), "options": ["选项一", "选项二"]]], date: Date())!
        var opened = 0, replies = 0
        let item = OverlayItem(id: "question", text: "测试提问", header: "Codex · 提问", title: "验收聊天",
            active: false, mascot: .codex, question: request, onOpenConversation: { opened += 1; return nil }, onQuestionReply: { _, _ in replies += 1 })
        func update(_ item: OverlayItem) {
            overlays.update([item], font: 18, opacity: 0.7, bottom: 46, screenIndex: 0,
                movable: false, focusedID: "question", bubblesFixedToCharacter: true)
            settle()
        }
        let ordinary = OverlayItem(id: "question", text: "继续工作", header: "Codex · 进度", title: "验收聊天", active: false, mascot: .codex)
        update(ordinary)
        let controller = overlays.controller(for: "question")!
        let ordinaryFrame = controller.panel.frame
        let characterFrame = overlays.character.panel.frame
        let ordinaryWindow = controller.panel.windowNumber
        update(item)
        let intermediateHeight = controller.panel.frame.height
        require(intermediateHeight > ordinaryFrame.height && intermediateHeight < controller.layoutHeight,
            "same bubble interpolates from ordinary height rather than jumping")
        require(near(controller.panel.frame.minY, ordinaryFrame.minY) && overlays.character.panel.frame == characterFrame,
            "expansion preserves tail bottom and character geometry")
        update(item) // Repeated subtitle refresh must not restart the animation.
        require(controller.panel.frame.height > intermediateHeight,
            "ordinary refresh does not restart an in-flight expansion")
        RunLoop.main.run(until: Date().addingTimeInterval(0.38))
        require(controller.panel.windowNumber == ordinaryWindow && !controller.isQuestionTransitionRunning,
            "expansion uses the original native panel and releases its timer")
        require(controller.panel.acceptsQuestionInput && controller.panel.canBecomeKey && !controller.panel.ignoresMouseEvents,
            "question accepts clicks and keyboard with fixed/click-through captions")
        require(controller.panel.contentView is QuestionReplyView && controller.panel.frame.height >= 200,
            "character binding preserves the interactive question and readable height")
        let expandedHeight = controller.panel.frame.height
        let expansionFrames = controller.transitionFrameCount
        let expansionWork = controller.transitionWorkSeconds
        let view = controller.panel.contentView!
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
        }
        require(descendants(view, as: NSTextView.self).isEmpty,
            "question has no custom text input")
        let description = descendants(view, as: NSScrollView.self).first { $0.identifier?.rawValue == "request-description" }!
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 15, weight: .medium)))
        require(description.frame.height <= lineHeight * 3 && description.documentView!.frame.height > description.frame.height,
            "long question description occupies at most three lines with internal scrolling")
        description.contentView.scroll(to: NSPoint(x: 0, y: 80)); update(item)
        require(description.contentView.bounds.minY > 0, "caption refresh preserves the inner description scroll position")
        let buttons = descendants(view, as: NSButton.self)
        let choice = buttons.first { $0.title == "选项二" }!
        choice.performClick(nil); update(item)
        require(controller.panel.contentView === view && choice.state == .on,
            "redraw preserves selected answer and native card")
        let own = buttons.first { $0.title == "我要自己回复" }!
        own.performClick(nil)
        require(opened == 1 && replies == 0 && controller.panel.contentView === view,
            "own reply navigates once without answering or dismissing the request")
        let submit = buttons.first { $0.title == "发送回复" }!
        require(own.frame.minY == submit.frame.minY && submit.frame.maxX + 8 <= own.frame.minX,
            "question footer fills one horizontal row without overlap")
        require((view as! QuestionReplyView).controlsOpacity == 1 && view.hitTest(NSPoint(x: own.frame.midX, y: own.frame.midY)) != nil,
            "compact question controls become fully visible and clickable after transition")
        let outer = descendants(view, as: NSScrollView.self).first { $0.identifier?.rawValue != "request-description" }!
        require(near(submit.frame.minY - outer.frame.maxY, 8) && submit.frame.height == 28,
            "small question buttons follow the description/options with the same eight-point gap")
        let output = URL(fileURLWithPath: "output/codex-questions/native-question.png")
        try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: output)
        }
        update(ordinary)
        require(controller.panel.frame.height < expandedHeight && controller.panel.frame.height > ordinaryFrame.height,
            "question dismissal contracts smoothly")
        // Reverse a transition while it is still moving: preserve current size.
        let reversingHeight = controller.panel.frame.height
        update(item)
        require(abs(controller.panel.frame.height - reversingHeight) < 30,
            "new question reverses contraction without a size jump")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        update(ordinary)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        require(near(controller.panel.frame.height, ordinaryFrame.height) && !controller.isQuestionTransitionRunning,
            "contraction restores the original one-line geometry and stops")
        let finishedFrames = controller.transitionFrameCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        require(controller.transitionFrameCount == finishedFrames && expansionFrames <= 60 && expansionWork < 0.08,
            "bounded animation work with no idle frame callbacks")
        let metrics: [String: Any] = ["durationSeconds": 0.42, "expansionFrames": expansionFrames,
            "frameMutationSeconds": expansionWork, "ordinaryHeight": ordinaryFrame.height,
            "expandedHeight": expandedHeight, "intermediateHeight": intermediateHeight, "idleCallbacks": 0,
            "scope": "native window frame/layout mutations; excludes compositor/GPU rendering"]
        try! JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.deletingLastPathComponent().appendingPathComponent("animation-validation.json"))
        require(!controller.panel.acceptsQuestionInput && !controller.panel.canBecomeKey && controller.panel.ignoresMouseEvents,
            "ordinary caption restores click-through after question dismissal")
    }

    static func checkApprovals() {
        let overlays = ProjectOverlays()
        let approval = CodexApproval.parse(threadID: "fixture", row: ["id": 17,
            "method": "item/commandExecution/requestApproval", "params": [
                "threadId": "fixture", "turnId": "turn", "itemId": "item", "startedAtMs": 123,
                "command": "curl https://example.com/测试", "cwd": "/示例项目", "reason": "读取示例网页，需要网络访问。"]])!
        var replies = 0, opened = 0
        let item = OverlayItem(id: "approval", text: approval.question.questions[0].title,
            header: "Codex · 等待审批", title: "验收聊天", active: false, mascot: .codex,
            question: approval.question, onOpenConversation: { opened += 1; return nil }, onQuestionReply: { _, _ in replies += 1 })
        overlays.update([item], font: 28, opacity: 0.7, bottom: 46, screenIndex: 0, movable: false,
            focusedID: "approval", bubblesFixedToCharacter: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.52))
        let panel = overlays.controller(for: "approval")!.panel, root = panel.contentView!
        func buttons(_ view: NSView) -> [NSButton] {
            guard !view.isHidden else { return [] }
            return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let controls = buttons(root)
        require(controls.contains { $0.identifier?.rawValue == "close-request-bubble" && $0.title == "×" },
                "approval keeps its separate request close control")
        let actions = controls.filter { $0.identifier?.rawValue != "close-request-bubble" }
        require(Set(actions.map(\.title)) == Set(["拒绝", "允许一次", "⌄", "我要自己回复"]),
            "approval uses direct deny/allow actions and scope menu without question radio rows")
        require(panel.frame.height < 320 && actions.allSatisfy { $0.frame.height == 28 },
            "approval has compact height and native-sized footer buttons")
        let deny = actions.first { $0.title == "拒绝" }!, allow = actions.first { $0.title == "允许一次" }!
        require(deny.frame.maxX + 8 <= allow.frame.minX && deny.frame.minY == allow.frame.minY,
            "footer actions align without overlap")
        let description = (root as! QuestionReplyView).subviews.compactMap { $0 as? NSScrollView }.first!
        require(near(deny.frame.minY - description.frame.maxY, 8), "approval footer uses the same spacing as request content")
        require(replies == 0, "showing and focusing an approval never submits a decision")
        let own = actions.first { $0.title == "我要自己回复" }!
        let scope = actions.first { $0.title == "⌄" }!
        require(scope.frame.maxX + 8 <= own.frame.minX && own.frame.minY == deny.frame.minY,
            "approval has three balanced footer actions with a scope menu")
        require((root as! QuestionReplyView).controlsOpacity == 1 && root.hitTest(NSPoint(x: own.frame.midX, y: own.frame.midY)) != nil,
            "compact approval controls reach full opacity and accept clicks")
        own.performClick(nil)
        require(opened == 1 && replies == 0, "opening approval in Codex submits no decision")
        let output = URL(fileURLWithPath: "output/codex-questions/native-approval-card.png")
        if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: output)
        }
        let consent = CodexApproval.parse(threadID: "browser", row: ["id": 759,
            "method": "mcpServer/elicitation/request", "params": ["threadId": "browser", "turnId": "turn",
                "serverName": "cua_repl", "mode": "form", "message": "Allow upload to https://arena.ai?",
                "requestedSchema": ["type": "object", "properties": [:]],
                "_meta": ["codex_approval_kind": "mcp_tool_call", "connector_id": "browser-use",
                          "origin": "https://arena.ai", "file_transfer": "upload", "persist": ["session", "always"]]]])!
        let consentItem = OverlayItem(id: consent.key, text: consent.question.questions[0].title,
            header: "Codex · 等待审批", title: "浏览器上传", active: false, mascot: .codex,
            question: consent.question, onQuestionReply: { _, _ in replies += 1 })
        overlays.update([item, consentItem], font: 28, opacity: 0.7, bottom: 46,
            screenIndex: 0, movable: false, focusedID: "approval", bubblesFixedToCharacter: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.52))
        let browserPanel = overlays.controller(for: consent.key)!.panel
        require(overlays.controller(for: "approval")!.panel.contentView === root,
            "existing reply card remains mounted when browser approval appears")
        require(browserPanel.isVisible && browserPanel.acceptsQuestionInput && panel.isVisible
            && !browserPanel.frame.intersects(panel.frame), "browser consent and existing card are both visible without overlap")
        require(Set(buttons(browserPanel.contentView!).map(\.title)).isSuperset(of: ["拒绝", "允许一次", "⌄"])
            && replies == 0, "browser approval exposes native decisions without automatically responding")
        let computerRow = try! JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: "Tests/Fixtures/codex-computer-use-approval.json"))) as! [String: Any]
        let computer = CodexApproval.parse(threadID: "thread-fixture", row: computerRow)!
        var computerAnswer: String?
        let computerItem = OverlayItem(id: computer.key, text: computer.question.questions[0].title,
            header: "Codex · 等待审批", title: "Computer Use 验收", active: false, mascot: .codex,
            question: computer.question, onQuestionReply: { answers, completion in
                computerAnswer = answers[computer.question.questions[0].id]; replies += 1
                completion(.success(()))
            })
        overlays.update([item, computerItem], font: 28, opacity: 0.7, bottom: 46,
            screenIndex: 0, movable: false, focusedID: computer.key, bubblesFixedToCharacter: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.52))
        let computerPanel = overlays.controller(for: computer.key)!.panel
        let computerButtons = buttons(computerPanel.contentView!).filter { $0.identifier?.rawValue != "close-request-bubble" }
        require(computerPanel.acceptsQuestionInput && Set(computerButtons.map(\.title)) ==
            Set(["拒绝", "允许一次", "⌄", "我要自己回复"]) && replies == 0,
            "real Computer Use request shape exposes native approval buttons without submitting")
        if let view = computerPanel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: "output/codex-questions/native-computer-approval-card.png"))
        }
        computerButtons.first { $0.title == "允许一次" }!.performClick(nil)
        require(computerAnswer == "允许本次" && replies == 1,
            "Computer Use allow button selects the approval response rather than a question reply")
    }

    static func checkConversationNavigation() {
        let controller = OverlayController(interactive: true)
        var opened = 0
        var openedTitle = ""
        func update(title: String = "思考字幕", source: String = "Codex", linked: Bool = true, compact: Bool = false, scale: CGFloat = 1, wait: Bool = true, live: Bool = true) {
            controller.update(text: "命令完成 · 0s: python", context: source + "  ·  工具调用  ·  " + title,
                title: title, live: live, mascot: nil, font: 24, opacity: 0.7,
                bottom: 48, screenIndex: 0, movable: false, visible: true,
                scale: scale, mode: .bubble, compactStack: compact,
                onOpenConversation: linked ? { opened += 1; openedTitle = title; return nil } : nil)
            if wait { settle() }
        }
        update()
        let button = controller.conversationButton!
        let linkWindow = button.window!
        require(!controller.panel.ignoresMouseEvents && linkWindow === controller.panel,
            "caption accepts native button input in its own backing window")
        require(button.superview === controller.subtitle && button.frame.width < controller.panel.frame.width / 2,
            "one native subview covers only the title through the arrow")
        require(button.caption.string == "思考字幕  ↗" && !button.mouseDownCanMoveWindow,
            "title and arrow share one native button without initiating a drag")
        func hitSurfaceAlpha() -> CGFloat {
            let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)!
            button.cacheDisplay(in: button.bounds, to: rep)
            return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.alphaComponent
        }
        let restingAlpha = hitSurfaceAlpha()
        require(restingAlpha > 0 && restingAlpha < 0.03,
            "idle title window retains a nonzero hit surface instead of passing clicks through transparent pixels")
        let hoverEvent = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: linkWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        button.mouseEntered(with: hoverEvent)
        require(button.isHovering && hitSurfaceAlpha() > 0.2, "hover immediately highlights the entire title hit area")
        button.mouseExited(with: hoverEvent)
        require(!button.isHovering && hitSurfaceAlpha() < 0.03, "leaving title clears hover highlight while keeping clicks enabled")
        let clickPoint = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let mouseDown = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint, modifierFlags: [], timestamp: 1,
            windowNumber: linkWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: clickPoint, modifierFlags: [], timestamp: 1.01,
            windowNumber: linkWindow.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApplication.shared.postEvent(mouseUp, atStart: true)
        linkWindow.sendEvent(mouseDown)
        require(opened == 1 && button.isFlashing, "title button opens once and immediately brightens the clickable area")
        if let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            button.cacheDisplay(in: button.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "output/codex-questions/native-conversation-title-pressed.png"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        require(!button.isFlashing, "click feedback clears after 180 ms without a repeating timer")
        let offset = NSPoint(x: linkWindow.frame.minX - controller.panel.frame.minX, y: linkWindow.frame.minY - controller.panel.frame.minY)
        controller.panel.setFrameOrigin(controller.panel.frame.origin.offset(dx: 15, dy: 12))
        require(near(linkWindow.frame.minX - controller.panel.frame.minX, offset.x) &&
            near(linkWindow.frame.minY - controller.panel.frame.minY, offset.y), "native child follows bubble movement")
        update(live: false)
        let titleColor = controller.subtitle.conversationLinkCaption.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        require(titleColor.alphaComponent == 1, "waiting conversation link remains fully readable")
        controller.subtitle.display()
        let dragStarted = ProcessInfo.processInfo.systemUptime
        let dragOrigin = controller.panel.frame.origin
        for step in 0..<120 {
            controller.panel.setFrameOrigin(dragOrigin.offset(dx: CGFloat(step % 20), dy: CGFloat(step % 12)))
            require(!controller.subtitle.needsDisplay, "title and body reuse the same bubble pixels during move \(step)")
        }
        print("120 title-bearing native moves: \(ProcessInfo.processInfo.systemUptime - dragStarted) s")
        try! controller.exportPreview(to: URL(fileURLWithPath: "output/codex-questions/native-waiting-title.png"))
        update(title: String(repeating: "很长的对话标题🐳", count: 10), compact: true, scale: 0.8)
        require(controller.conversationButton === button && button.window === linkWindow &&
            button.caption.string.hasSuffix("…  ↗") && button.frame.maxX < controller.subtitle.bounds.maxX,
            "long compact titles truncate while retaining the arrow and native control")
        update(title: "有跳转到deepseek当前会话的完整名字", source: "DSH")
        require(button.caption.string == "有跳转到deep…  ↗", "conversation title is capped at eight graphemes")
        let prefixWidth = (controller.subtitle.headerPrefix as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .kern: 0.5]).width
        require(controller.subtitle.headerPrefix == "DSH  ·  工具调用  ·  " && controller.subtitle.headerPrefixFrame.width >= prefixWidth,
            "DSH source and tool status retain their full measured width")
        try! controller.exportPreview(to: URL(fileURLWithPath: "output/codex-questions/native-dsh-title.png"))
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { update(title: "另一个对话", wait: false) }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        button.performClick(nil)
        require(opened == 2 && openedTitle == "另一个对话" && controller.conversationButton === button,
            "refresh opens the newly tracked conversation without accumulating controls")
        update(linked: false)
        require(button.isHidden && controller.subtitle.conversationLinkFrame.isEmpty,
            "unlinked source removes the arrow and clickable area")
        update()
        try! controller.exportPreview(to: URL(fileURLWithPath: "output/codex-questions/native-conversation-title.png"))
        update(title: "Harness 会话", source: "DSH")
        require(controller.conversationButton === button && button.accessibilityLabel() == "打开 DeepSeek Harness 窗口",
            "Harness reuses the arrow control and describes window-only navigation")
        button.performClick(nil)
        require(opened == 3 && openedTitle == "Harness 会话" && button.isFlashing,
            "Harness name and arrow retain click feedback and the source-specific callback")
        update(title: "文章资源", source: "Claude Code")
        require(controller.conversationButton === button && button.accessibilityLabel() == "跳转到 Claude Code 终端：文章资源",
            "Claude title shares the native arrow control with a terminal-specific hint")
        button.performClick(nil)
        require(opened == 4 && openedTitle == "文章资源" && button.isFlashing,
            "Claude name and arrow invoke the current session callback with click feedback")
        update(title: "OpenCode 会话", source: "OpenCode")
        require(button.accessibilityLabel() == "跳转到 OpenCode 终端：OpenCode 会话",
            "OpenCode title uses its own terminal navigation hint")
        button.performClick(nil)
        require(opened == 5 && openedTitle == "OpenCode 会话" && button.isFlashing,
            "OpenCode title invokes its current callback with click feedback")
        update(title: "WorkBuddy 会话", source: "WorkBuddy")
        require(button.accessibilityLabel() == "打开 WorkBuddy 对话：WorkBuddy 会话",
            "WorkBuddy title uses its own conversation navigation hint")
        button.performClick(nil)
        require(opened == 6 && openedTitle == "WorkBuddy 会话" && button.isFlashing,
            "WorkBuddy title invokes its current callback with click feedback")
        update(title: "豆包工作会话", source: "豆包工作")
        require(button.accessibilityLabel() == "打开豆包工作窗口：豆包工作会话",
            "Doubao title uses its own conversation navigation hint")
        button.performClick(nil)
        require(opened == 7 && openedTitle == "豆包工作会话" && button.isFlashing,
            "Doubao title invokes its current callback with click feedback")
        controller.setAverageSpeed(12.3)
        controller.refreshSpeedHover(at: NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY))
        require(controller.speedIsVisible, "speed is shown when the pointer enters the character window")
        controller.refreshSpeedHover(at: NSPoint(x: -10000, y: -10000))
        require(!controller.speedIsVisible, "speed hides when the pointer leaves")
        controller.setAverageSpeed(nil)
        controller.refreshSpeedHover(at: NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY))
        require(!controller.speedIsVisible, "missing reliable usage never displays a made-up speed")
        controller.setHoverMetrics(speed: nil, quota: "周额度剩余 31%")
        controller.refreshSpeedHover(at: NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY))
        require(controller.speedIsVisible, "quota displays independently while speed awaits a complete turn")
        controller.setHoverMetrics(speed: 12.3, quota: "周额度剩余 31%")
        controller.refreshSpeedHover(at: NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY))
        require(controller.hoverMetricsText == "平均 12.3 token/s\n周额度剩余 31%" && controller.hoverMetricsHeight == 102,
            "native hover label shows speed and quota on separate lines")
        if let label = Mirror(reflecting: controller).children.first(where: { $0.label == "speedLabel" })?.value as? NSTextField,
           let image = label.bitmapImageRepForCachingDisplay(in: label.bounds) {
            label.cacheDisplay(in: label.bounds, to: image)
            try! image.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: "output/codex-questions/native-hover-metrics.png"))
        }
        controller.setHoverMetrics(speed: nil, quota: nil)
        let realPipeline = ProjectOverlays()
        realPipeline.update([OverlayItem(id: "metrics", text: "检查真实角色链路", header: "Codex", title: "指标验收",
            active: true, mascot: .codex, averageSpeed: 12.3, quotaText: "周额度剩余 31%")],
            font: 18, opacity: 0.6, bottom: 60, screenIndex: 0, movable: false, focusedID: "metrics",
            characterBindings: [.codex: .deepseek])
        let realCharacter = realPipeline.character(for: .codex)!
        realCharacter.refreshSpeedHover(at: NSPoint(x: realCharacter.panel.frame.midX, y: realCharacter.panel.frame.midY))
        require(realCharacter.speedIsVisible && realCharacter.hoverMetricsText == "平均 12.3 token/s\n周额度剩余 31%",
            "full source→skin binding→character→hover pipeline preserves both metrics")
        realCharacter.panel.setManualDragging(true)
        require(!realCharacter.speedIsVisible, "drag start immediately hides hover metrics")
        realCharacter.panel.orderFrontRegardless()
        require(!realCharacter.hoverMetricsWindowVisible, "parent window ordering cannot reveal hidden metrics during drag")
        realCharacter.refreshSpeedHover(at: NSPoint(x: realCharacter.panel.frame.midX, y: realCharacter.panel.frame.midY))
        require(!realCharacter.speedIsVisible, "hover refresh cannot reveal metrics during a drag")
        realCharacter.panel.setManualDragging(false)
        realCharacter.refreshSpeedHover(at: NSPoint(x: realCharacter.panel.frame.midX, y: realCharacter.panel.frame.midY))
        require(realCharacter.speedIsVisible, "hover metrics resume after drag completion")
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: realCharacter.panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        realCharacter.handleHoverMouseEvent(down)
        require(!realCharacter.hoverMetricsWindowVisible, "raw mouse-down immediately hides the actual metrics window")
        realCharacter.refreshSpeedHover(at: NSPoint(x: realCharacter.panel.frame.midX, y: realCharacter.panel.frame.midY), leftButtonDown: true)
        require(!realCharacter.hoverMetricsWindowVisible, "pressed left button suppresses hover even without a manual-drag callback")
        realCharacter.refreshSpeedHover(at: NSPoint(x: realCharacter.panel.frame.midX, y: realCharacter.panel.frame.midY), leftButtonDown: false)
        require(realCharacter.hoverMetricsWindowVisible, "released left button allows the actual hover window to return")
        realPipeline.update([OverlayItem(id: "metrics", text: "暂无速度", header: "Codex", title: "指标验收",
            active: true, mascot: .codex, quotaText: "周额度剩余 31%")],
            font: 18, opacity: 0.6, bottom: 60, screenIndex: 0, movable: false, focusedID: "metrics",
            characterBindings: [.codex: .deepseek])
        realCharacter.refreshSpeedHover(at: NSPoint(x: realCharacter.panel.frame.midX, y: realCharacter.panel.frame.midY), leftButtonDown: false)
        require(realCharacter.hoverMetricsText == "平均 - token/s\n周额度剩余 31%" && realCharacter.hoverMetricsHeight == 102,
            "Codex shows a speed placeholder alongside quota when speed is unavailable")
        realCharacter.setHoverMetrics(speed: nil, quota: nil, showSpeedPlaceholder: true)
        realCharacter.refreshSpeedHover(at: NSPoint(x: realCharacter.panel.frame.midX, y: realCharacter.panel.frame.midY), leftButtonDown: false)
        require(realCharacter.hoverMetricsWindowVisible && realCharacter.hoverMetricsText == "平均 - token/s" && realCharacter.hoverMetricsHeight == 86,
            "Codex placeholder remains available even without quota data")
        realPipeline.setSourceHidden(.codex, true)
        var hoverQueries = 0
        realPipeline.update([OverlayItem(id: "dsh-metrics", text: "余额查询", header: "DeepSeek Harness", title: "指标验收",
            active: true, mascot: .deepseek, averageSpeed: 50, quotaText: "账户余额刷新中",
            metricsRefreshing: true, onMetricsHover: { hoverQueries += 1 })],
            font: 18, opacity: 0.6, bottom: 60, screenIndex: 0, movable: false, focusedID: "dsh-metrics")
        let dshCharacter = realPipeline.character(for: .deepseek)!
        dshCharacter.refreshSpeedHover(at: NSPoint(x: -10000, y: -10000), leftButtonDown: false)
        let before = hoverQueries
        let inside = NSPoint(x: dshCharacter.panel.frame.midX, y: dshCharacter.panel.frame.midY)
        dshCharacter.refreshSpeedHover(at: inside, leftButtonDown: false)
        for _ in 0..<100 { dshCharacter.refreshSpeedHover(at: inside, leftButtonDown: false) }
        require(hoverQueries == before + 1, "one query per hover entry; stationary pointer never polls the API")
        require(dshCharacter.hoverMetricsText == "平均 50.0 token/s\n账户余额刷新中"
            && dshCharacter.hoverMetricsDiagnostics["spinnerVisible"] as? Bool == true,
            "Harness metrics reach the actual native label and animated spinner")
        dshCharacter.setHoverMetrics(speed: 50, quota: "账户余额 ¥86.50 · 赠送 ¥0.00", showSpeedPlaceholder: true)
        dshCharacter.refreshSpeedHover(at: inside, leftButtonDown: false)
        require(dshCharacter.hoverMetricsDiagnostics["spinnerVisible"] as? Bool == false,
            "completed balance hides the loading spinner")
        let completedQueries = hoverQueries
        dshCharacter.refreshSpeedHover(at: NSPoint(x: -10000, y: -10000), leftButtonDown: false)
        dshCharacter.refreshSpeedHover(at: inside, leftButtonDown: false)
        require(hoverQueries == completedQueries + 1, "leaving then re-entering permits a fresh query")
        realPipeline.setSourceHidden(.deepseek, true)
        let idlePipeline = ProjectOverlays()
        var idleQueries = 0
        func updateIdle(_ refreshing: Bool, _ quota: String = "账户余额 -") {
            idlePipeline.update([], font: 18, opacity: 0.6, bottom: 60, screenIndex: 0,
                movable: false, focusedID: "", restingMascots: [.deepseek],
                characterBindings: [.deepseek: .codex],
                fallbackMetrics: [.deepseek: OverlayHoverMetrics(averageSpeed: nil, quotaText: quota,
                    refreshing: refreshing, onHover: { idleQueries += 1 })])
        }
        updateIdle(false)
        let idle = idlePipeline.character(for: .deepseek)!
        let idlePoint = NSPoint(x: idle.panel.frame.midX, y: idle.panel.frame.midY)
        idle.refreshSpeedHover(at: idlePoint, leftButtonDown: false)
        require(idle.hoverMetricsText == "平均 - token/s\n账户余额 -" && idle.hoverMetricsHeight == 86,
            "idle character without captions preserves both metric placeholders across character bindings")
        let idleBefore = idleQueries
        for _ in 0..<100 { idle.refreshSpeedHover(at: idlePoint, leftButtonDown: false) }
        require(idleQueries == idleBefore, "idle hover callback remains available without repeated requests")
        updateIdle(true)
        idle.refreshSpeedHover(at: idlePoint, leftButtonDown: false)
        require(idle.hoverMetricsText == "平均 - token/s\n账户余额 -"
            && idle.hoverMetricsDiagnostics["spinnerVisible"] as? Bool == true,
            "idle balance placeholder stays visible while native refresh symbol spins")
        updateIdle(false, "账户余额 - · 查询失败")
        idle.refreshSpeedHover(at: idlePoint, leftButtonDown: false)
        require(idle.hoverMetricsText.hasSuffix("账户余额 - · 查询失败")
            && idle.hoverMetricsDiagnostics["spinnerVisible"] as? Bool == false,
            "failed lookup retains the balance placeholder and stops refreshing")
        idlePipeline.setSourceHidden(.deepseek, true)
        let allPipeline = ProjectOverlays()
        var allQueries = 0
        allPipeline.update([], font: 18, opacity: 0.6, bottom: 60, screenIndex: 0,
            movable: false, focusedID: "", restingMascots: [.codex, .deepseek, .claude],
            characterBindings: [.codex: .codex, .deepseek: .deepseek, .claude: .pinkBear],
            fallbackMetrics: [.deepseek: OverlayHoverMetrics(averageSpeed: 42, quotaText: "账户余额 -",
                onHover: { allQueries += 1 })])
        let all = [CaptionMascot.codex, .deepseek, .claude].map { allPipeline.character(for: $0)! }
        for (index, character) in all.enumerated() {
            character.panel.setFrameOrigin(NSPoint(x: 100 + index * 300, y: 400))
        }
        let target = NSPoint(x: all[0].panel.frame.midX, y: all[0].panel.frame.midY)
        for character in all { character.refreshSpeedHover(at: target, leftButtonDown: false, optionDown: false) }
        require(all[0].hoverMetricsWindowVisible && !all[1].hoverMetricsWindowVisible && !all[2].hoverMetricsWindowVisible,
            "ordinary hover displays only the pointed character")
        let allStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            for character in all { character.refreshSpeedHover(at: target, leftButtonDown: false, optionDown: true) }
        }
        require(all.allSatisfy { $0.hoverMetricsWindowVisible } && allQueries == 1,
            "Option hover displays all characters including idle placeholders and queries balance once")
        print("INFO: 100 Option hover updates across 3 characters: \(ProcessInfo.processInfo.systemUptime - allStart) seconds; one balance callback")
        for character in all { character.refreshSpeedHover(at: target, leftButtonDown: false, optionDown: false) }
        require(!all[1].hoverMetricsWindowVisible && !all[2].hoverMetricsWindowVisible,
            "releasing Option restores individual hover without pointer movement")
        for character in all { character.refreshSpeedHover(at: NSPoint(x: -10000, y: -10000), leftButtonDown: false, optionDown: true) }
        require(all.allSatisfy { !$0.hoverMetricsWindowVisible }, "Option outside all characters hides every metric")
        for source in [CaptionMascot.codex, .deepseek, .claude] { allPipeline.setSourceHidden(source, true) }
        print("INFO: 100 native caption updates excluding deliberate settle time: \(max(0, elapsed)) seconds; no new timers or requests")
        controller.panel.orderOut(nil)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--harness-balance-live-only" {
            let controller = OverlayController()
            controller.update(text: "DeepSeek 指标验收", context: "DeepSeek Harness", title: "指标验收",
                live: true, mascot: .deepseek, font: 18, opacity: 0.6, bottom: 60, screenIndex: 0,
                movable: false, visible: true, scale: 1, mode: .character)
            controller.setHoverMetrics(speed: 50, quota: "账户余额 -", showSpeedPlaceholder: true)
            var result: String?, queries = 0
            controller.onMetricsHover = {
                queries += 1
                controller.setHoverMetrics(speed: 50, quota: "账户余额 -", showSpeedPlaceholder: true, refreshing: true)
                HarnessBalanceQuery.fetch(credentialsURL: URL(fileURLWithPath: CommandLine.arguments[2])) { text in
                    result = text
                    controller.onMetricsHover = nil
                    controller.setHoverMetrics(speed: 50, quota: text, showSpeedPlaceholder: true)
                }
            }
            let point = NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY)
            func saveMetrics(_ name: String) {
                guard let panel = Mirror(reflecting: controller).children.first(where: { $0.label == "speedPanel" })?.value as? NSPanel,
                      let view = panel.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: image)
                try! image.representation(using: .png, properties: [:])!.write(to:
                    URL(fileURLWithPath: "output/codex-questions/dsh-metrics-\(name).png"))
            }
            controller.refreshSpeedHover(at: point, leftButtonDown: false)
            require(queries == 1 && controller.hoverMetricsDiagnostics["spinnerVisible"] as? Bool == true,
                "native hover starts the real account query and displays a spinner")
            saveMetrics("loading")
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = Date().addingTimeInterval(15)
            while result == nil && Date() < deadline { settle() }
            require(result?.hasPrefix("账户余额 ¥") == true, "real Harness account endpoint returns a wallet amount")
            controller.refreshSpeedHover(at: point, leftButtonDown: false)
            require(controller.hoverMetricsText == "平均 50.0 token/s\n" + result!
                && controller.hoverMetricsDiagnostics["spinnerVisible"] as? Bool == false,
                "real balance reaches the native label and stops the spinner")
            saveMetrics("loaded")
            let evidence: [String: Any] = ["queries": queries, "seconds": ProcessInfo.processInfo.systemUptime - started,
                "metrics": controller.hoverMetricsDiagnostics]
            try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to:
                URL(fileURLWithPath: "output/codex-questions/dsh-metrics-live-balance.json"))
            controller.panel.orderOut(nil); return
        }
        if CommandLine.arguments.contains("--head-pat-only") { try! HeadPatChecks.run(); return }
        if CommandLine.arguments.contains("--akimbo-only") { try! AkimboChecks.run(); return }
        if CommandLine.arguments.contains("--screen-edge-only") { try! ScreenEdgeDockChecks.run(); return }
        if CommandLine.arguments.contains("--character-hit-only") { CharacterHitTestingChecks.run(); return }
        if CommandLine.arguments.contains("--dialogue-layer-only") { DialogueLayerChecks.run(); return }
        if CommandLine.arguments.contains("--character-stacking-only") { checkCharacterStacking(); return }
        if CommandLine.arguments.contains("--scroll-scale-only") { checkScrollScale(); return }
        if CommandLine.arguments.contains("--conversation-navigation-only") { checkConversationNavigation(); return }
        if CommandLine.arguments.contains("--questions-only") { checkQuestions(); return }
        if CommandLine.arguments.contains("--approvals-only") { checkApprovals(); return }
        if CommandLine.arguments.contains("--stack-only") {
            checkCompactStack(); checkStackCompaction(); checkFixedBubbles()
            checkIndependentSources(area: NSScreen.screens[0].visibleFrame)
            CharacterPositionChecks.run(); return
        }
        if CommandLine.arguments.contains("--caption-close-tracking-only") { checkCaptionCloseTracking(); return }
        if CommandLine.arguments.contains("--caption-close-only") { checkCaptionClose(); return }
        if CommandLine.arguments.contains("--shared-metrics-only") { checkSharedMetrics(); return }
        if CommandLine.arguments.contains("--character-bindings-only") {
            checkCharacterBindings(); return
        }
        if CommandLine.arguments.contains("--singing-step-performance-only") {
            try! SingingStepArtworkChecks.performance(); return
        }
        if CommandLine.arguments.contains("--drag-reaction-only") {
            let controller = OverlayController()
            controller.update(text: "拖拽反馈受控检查", context: "DeepSeek Harness", title: "拖拽反馈",
                live: false, mascot: .deepseek, font: 18, opacity: 0.6, bottom: 60, screenIndex: 0,
                movable: true, visible: true, scale: 1, mode: .character)
            let view = controller.subtitle
            let original = controller.panel.frame
            precondition(view.beginDragReaction(at: original.origin, time: 1))
            for i in 1...20 {
                view.updateDragReaction(at: original.origin.applying(CGAffineTransform(translationX: CGFloat(i)*8,y:0)),
                    time: 1+Double(i)/60)
            }
            precondition(view.dragReaction.active && abs(view.dragReaction.lean) > 1)
            precondition(CharacterDragArtwork.shared.available, "Installed paddling frames must load")
            precondition(view.dragReaction.frameIndex != nil)
            let center = NSPoint(x:view.seatedSpriteRect.midX,y:view.seatedSpriteRect.minY+view.seatedSpriteRect.height*0.4)
            let hit = center.applying(view.dragReaction.transform(in:view.seatedSpriteRect,scale:view.layoutScale))
            precondition(view.containsVisibleCharacter(at: hit), "Hit testing must follow transformed character")
            precondition(controller.panel.frame == original, "Reaction must not move or resize the native window")
            let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"output/drag-reaction/appkit-drag.png"))
            view.endDragReaction(at: 1.34)
            view.updateDragReaction(at:original.origin,time:2.20)
            precondition(!view.dragReaction.active)
            precondition(view.beginDragReaction(at:original.origin,time:2))
            view.enterScreenEdge(.left)
            view.updateDragReaction(at:original.origin,time:2.02)
            precondition(!view.dragReaction.active, "Screen edge action owns its geometry")
            controller.panel.orderOut(nil)
            print("PASS: actual SubtitleView whole-art transform, transformed hit test, unchanged window frame, release and edge cancellation")
            return
        }
        if CommandLine.arguments.contains("--gaze-only") {
            try! SeatedGazeChecks.run(); return
        }
        if CommandLine.arguments.contains("--withdraw-artwork-only") {
            try! WindowPeekChecks.checkWithdrawalArtwork(); return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--position-fixture" {
            CharacterPositionChecks.fixture(mode: CommandLine.arguments[2], suite: CommandLine.arguments[3])
            return
        }
        if CommandLine.arguments.contains("--avoidance-only") {
            try! BackdropAvoidanceChecks.run(); return
        }
        if CommandLine.arguments.contains("--singing-step-only") {
            try! SingingStepArtworkChecks.run(); try! BackdropAvoidanceChecks.run(); return
        }
        if CommandLine.arguments.contains("--scoot-only") {
            try! SeatedScootChecks.run(); return
        }
        if CommandLine.arguments.contains("--front-retreat-only") {
            try! FrontRetreatChecks.run(); return
        }
        if CommandLine.arguments.contains("--stroll-only") {
            try! StrollArtworkChecks.run(); return
        }
        if CommandLine.arguments.contains("--window-seat-selection-only") {
            try! WindowSeatSelectionChecks.run(); return
        }
        if CommandLine.arguments.contains("--window-seat-loss-only") {
            try! WindowSeatSupportLossChecks.run(); return
        }
        if CommandLine.arguments.contains("--window-seat-only") {
            try! WindowSeatChecks.run(); return
        }
        if CommandLine.arguments.contains("--window-peek-only") {
            try! WindowPeekChecks.run(); try! WindowSwimChecks.run(); return
        }
        try! MouthArtworkChecks.run()
        try! SingingArtworkChecks.run()
        try! SingingStepArtworkChecks.run()
        try! KiraArtworkChecks.run()
        try! SeatedScootChecks.run()
        try! FrontRetreatChecks.run()
        try! StrollArtworkChecks.run()
        try! WindowPeekChecks.run()
        try! WindowSwimChecks.run()
        checkAudioCharacters()
        checkPinkBearBinding()
        checkFixedBubbles()
        let overlays = ProjectOverlays()
        let items = (0..<2).map { index in
            OverlayItem(id: "project-\(index)", text: "正在检查独立项目的字幕。",
                        header: "Codex · 项目 \(index)", title: "项目 \(index)",
                        active: false, mascot: .codex)
        }
        func update(_ scale: Double = 1, _ source: CaptionMascot = .codex) {
            overlays.update(items.map { item in
                OverlayItem(id: item.id, text: item.text, header: item.header,
                            title: item.title, active: false, mascot: source)
            }, font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
               movable: true, focusedID: items[0].id, characterScale: scale)
            settle()
        }
        func frames() -> [NSRect] { items.map { overlays.controller(for: $0.id)!.panel.frame } }
        update()
        require(overlays.character.subtitle.showsMascot, "real character assets loaded")
        let initialStack = frames()
        require(initialStack.allSatisfy { near($0.midX, overlays.character.panel.frame.midX) }
                && near(initialStack[1].width, initialStack[0].width)
                && near(initialStack[1].minY - initialStack[0].maxY, 2),
                "default bubbles align above the character in a compact upward stack")
        require(items.allSatisfy { overlays.controller(for: $0.id)!.panel.parent === overlays.character.panel },
                "bubbles use native parent-window attachment")
        for item in items { overlays.controller(for: item.id)!.subtitle.display() }
        let rapidRole = overlays.character.panel.frame
        let rapidBubbles = frames()
        for step in 0..<60 {
            let delta = NSPoint(x: CGFloat(step % 15), y: CGFloat(step % 10))
            overlays.character.panel.setFrameOrigin(rapidRole.origin.offset(dx: delta.x, dy: delta.y))
            // No run-loop wait or application timer between moves: child windows
            // must already be at the matching position when setFrame returns.
            let currentRole = overlays.character.panel.frame
            require(zip(rapidBubbles, frames()).allSatisfy {
                near($1.minX - $0.minX, currentRole.minX - rapidRole.minX)
                    && near($1.minY - $0.minY, currentRole.minY - rapidRole.minY)
            }, "rapid move \(step + 1) remains synchronized")
        }
        require(items.allSatisfy { !overlays.controller(for: $0.id)!.subtitle.needsDisplay },
                "group dragging reuses bubble pixels without text redraw")
        overlays.character.panel.setFrameOrigin(rapidRole.origin)
        settle(); update()
        let originalCharacter = overlays.character.panel.frame
        let originalBubbles = frames()
        let area = NSScreen.screens[0].visibleFrame
        let bounds = originalBubbles.reduce(originalCharacter) { $0.union($1) }
        let dx = min(40, max(0, area.maxX - bounds.maxX - 2))
        let dy = min(40, max(0, area.maxY - bounds.maxY - 2))
        require(dx > 1 && dy > 1, "layout leaves space for two-axis dragging")
        overlays.character.panel.setFrameOrigin(originalCharacter.origin.offset(dx: dx, dy: dy))
        settle()
        for (before, after) in zip(originalBubbles, frames()) {
            require(near(after.minX - before.minX, dx) && near(after.minY - before.minY, dy),
                    "native character move translates each bubble immediately")
        }
        let moved = frames()
        update()
        require(zip(moved, frames()).allSatisfy { $0 == $1 }, "refresh preserves dragged group position")
        let bubble = overlays.controller(for: items[0].id)!
        bubble.panel.setFrameOrigin(bubble.panel.frame.origin.offset(dx: 12, dy: 8))
        settle(); update()
        let adjusted = frames()
        overlays.character.panel.setFrameOrigin(overlays.character.panel.frame.origin.offset(dx: -10, dy: 6))
        settle(); update()
        require(zip(adjusted, frames()).allSatisfy {
            near($1.minX - $0.minX, -10) && near($1.minY - $0.minY, 6)
        }, "independently adjusted bubble keeps its offset when character moves")
        let center = overlays.character.panel.frame.midX
        let bottom = overlays.character.panel.frame.minY
        let fonts = items.map { overlays.controller(for: $0.id)!.subtitle.fontSize }
        for scale in [0.5, 1.5, 2.0, 1.0] {
            update(scale)
            let character = overlays.character.panel.frame
            require(near(character.height, originalCharacter.height * scale)
                    && near(character.width, originalCharacter.width * scale), "character scales to \(Int(scale * 100)) percent")
            require(near(character.midX, center) && near(character.minY, bottom), "scaling preserves character bottom-center")
            require(items.enumerated().allSatisfy { index, item in
                near(overlays.controller(for: item.id)!.subtitle.fontSize, fonts[index])
            }, "character scaling preserves caption font size")
        }
        let prior = frames()
        let priorRole = overlays.character.panel.frame
        overlays.character.panel.setFrameOrigin(NSPoint(x: area.maxX + 500, y: area.maxY + 500))
        settle()
        let finalRole = overlays.character.panel.frame
        let delta = NSPoint(x: finalRole.minX - priorRole.minX, y: finalRole.minY - priorRole.minY)
        require(zip(prior, frames()).allSatisfy {
            near($1.minX - $0.minX, delta.x) && near($1.minY - $0.minY, delta.y)
        }, "screen-edge constraint moves the group without changing relative offsets")
        require(frames().allSatisfy { area.insetBy(dx: -1, dy: -1).contains($0) }, "bubbles remain visible at screen edge")
        update(1, .deepseek)
        require(overlays.character(for: .codex)!.panel.frame == finalRole
                && !overlays.character(for: .codex)!.panel.isVisible,
                "hidden source keeps its own dragged character position")
        update(1, .codex)
        require(overlays.character.panel.frame == finalRole, "returning source restores its own character position")
        overlays.update([], font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                        movable: false, focusedID: "")
        require(overlays.character.panel.childWindows?.isEmpty ?? true,
                "hidden projects detach their native child windows")
        overlays.update(items, font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                        movable: false, focusedID: items[0].id)
        require(overlays.character.panel.ignoresMouseEvents && items.allSatisfy {
            overlays.controller(for: $0.id)!.panel.ignoresMouseEvents
        }, "disabling dragging restores click-through on character and bubbles")
        overlays.update([], font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                        movable: false, focusedID: "")
        let crowded = ProjectOverlays()
        for count in [1, 3, 6, 16] {
            let many = (0..<count).map { index in
                OverlayItem(id: "crowded-\(index)", text: String(repeating: "检查较长字幕和换行。", count: 4),
                            header: "Codex · 项目 \(index)", title: "项目 \(index)",
                            active: true, mascot: .codex)
            }
            crowded.update(many, font: 42, opacity: 0.68, bottom: 46, screenIndex: 0,
                           movable: true, focusedID: many[0].id, characterScale: 2)
            let stack = crowded.visibleIDs.map { crowded.controller(for: $0)!.panel.frame }
            require(stack.allSatisfy { area.insetBy(dx: -1, dy: -1).contains($0)
                && near($0.midX, crowded.character.panel.frame.midX) }
                && zip(stack, stack.dropFirst()).allSatisfy { $1.minY >= $0.maxY },
                    "\(count) long-message bubbles fit vertically without overlap")
            require(near(crowded.character.panel.frame.height, originalCharacter.height * 2),
                    "vertical fitting preserves configured character size")
        }
        crowded.update([], font: 42, opacity: 0.68, bottom: 46, screenIndex: 0,
                       movable: false, focusedID: "")
        checkCompactStack()
        checkStackCompaction()
        checkIndependentSources(area: area)
        CharacterPositionChecks.run()
    }

    static func checkStackCompaction() {
        let overlays = ProjectOverlays()
        let all = (0..<5).map { index in
            OverlayItem(id: "reflow-\(index)", text: "项目 \(index) 正在工作。",
                        header: "Codex · 项目 \(index)", title: "项目 \(index)", active: true, mascot: .codex)
        }
        var items = all
        func update() {
            overlays.update(items, font: 20, opacity: 0.68, bottom: 46, screenIndex: 0,
                            movable: true, focusedID: items.first!.id)
            settle()
        }
        func frames() -> [NSRect] {
            overlays.visibleIDs.map { overlays.controller(for: $0)!.panel.frame }
        }
        func packed() -> Bool {
            let stack = frames()
            return stack.allSatisfy { near($0.midX, overlays.character.panel.frame.midX) }
                && zip(stack, stack.dropFirst()).allSatisfy {
                    let gap = $1.minY - $0.maxY
                    return gap >= 0 && gap <= 3
                }
        }
        update()
        // Group dragging remains the durable anchor; an older individual
        // bubble offset must not leave a hole when visible membership changes.
        overlays.character.panel.setFrameOrigin(overlays.character.panel.frame.origin.offset(dx: -15, dy: 4))
        settle(); update()
        let role = overlays.character.panel.frame
        let top = overlays.controller(for: all[4].id)!
        top.panel.setFrameOrigin(top.panel.frame.origin.offset(dx: 10, dy: 35))
        settle(); update()
        let oldTop = top.panel.frame
        let colors = Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, overlays.controller(for: $0.id)!.subtitle.themeHue)
        })
        items.removeAll { $0.id == all[1].id || $0.id == all[2].id }
        update()
        require(packed() && top.panel.frame.minY < oldTop.minY,
                "removing multiple middle sessions lowers upper bubbles and closes old placement gaps")
        require(overlays.character.panel.frame == role && items.allSatisfy {
            overlays.controller(for: $0.id)!.subtitle.themeHue == colors[$0.id]
        }, "compaction preserves the dragged character anchor and surviving project colors")
        let compact = frames()
        update()
        require(frames() == compact, "refresh does not restore stale positions after compaction")
        items.removeFirst(); update()
        require(packed() && overlays.controller(for: items[0].id)!.subtitle.tailTarget != nil,
                "bottom removal repacks surviving bubbles and transfers the sole tail")
        items = all; update()
        require(packed() && overlays.character.panel.frame == role,
                "returning sessions rejoin the continuous stack without moving the character")
        overlays.update([], font: 20, opacity: 0.68, bottom: 46, screenIndex: 0,
                        movable: false, focusedID: "")
    }

    static func checkCompactStack() {
        let overlays = ProjectOverlays()
        var items = (0..<3).map { index in
            OverlayItem(id: "compact-\(index)",
                        text: index == 1 ? "正在检查较长的项目字幕，确认换行后依然紧凑、对齐且可以完整阅读。" : "正在思考…",
                        header: "Codex · 项目 \(index)", title: "项目 \(index)", active: true, mascot: .codex)
        }
        func update(_ font: Double = 28) {
            overlays.update(items, font: font, opacity: 0.68, bottom: 46, screenIndex: 0,
                            movable: true, focusedID: items.first!.id)
        }
        for font in [10.0, 28.0, 42.0] {
            update(font)
            let controllers = overlays.visibleIDs.map { overlays.controller(for: $0)! }
            require(controllers.first!.subtitle.tailTarget != nil
                    && controllers.dropFirst().allSatisfy { $0.subtitle.tailTarget == nil },
                    "only the lowest bubble has a character tail at font \(Int(font))")
            require(controllers.allSatisfy { near($0.panel.frame.width, controllers[0].panel.frame.width) },
                    "short and wrapped messages share aligned stack edges")
            let boxes = controllers.map {
                $0.subtitle.bubbleFrame.offsetBy(dx: $0.panel.frame.minX, dy: $0.panel.frame.minY)
            }
            require(zip(boxes, boxes.dropFirst()).allSatisfy {
                let gap = $1.minY - $0.maxY
                return gap >= 0 && gap <= 7
            }, "visible bubble borders remain tightly stacked without overlap")
            require(Set(controllers.map { $0.subtitle.themeHue }).count == items.count,
                    "compact layers keep distinct project colors")
        }
        let originalRole = overlays.character.panel.frame
        items.removeFirst(); update()
        require(overlays.controller(for: items[0].id)!.subtitle.tailTarget != nil
                && overlays.controller(for: items[1].id)!.subtitle.tailTarget == nil,
                "removing the bottom project transfers the sole tail to the new bottom layer")
        items.removeFirst(); update()
        let single = overlays.controller(for: items[0].id)!.subtitle
        require(single.tailTarget != nil && !single.compactStack
                && overlays.character.panel.frame == originalRole,
                "a remaining single project restores the standalone bubble without moving the character")
        overlays.update([], font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                        movable: false, focusedID: "")
    }

    static func checkIndependentSources(area: NSRect) {
        let overlays = ProjectOverlays()
        var items = [
            OverlayItem(id: "codex-a", text: "Codex 项目 A", header: "Codex · A", title: "A", active: true, mascot: .codex),
            OverlayItem(id: "codex-b", text: "Codex 项目 B", header: "Codex · B", title: "B", active: true, mascot: .codex),
            OverlayItem(id: "deepseek-a", text: "DeepSeek 项目 A", header: "DeepSeek · A", title: "A", active: true, mascot: .deepseek),
            OverlayItem(id: "deepseek-b", text: "DeepSeek 项目 B", header: "DeepSeek · B", title: "B", active: true, mascot: .deepseek)
        ]
        func update(_ focused: String = "codex-a") {
            overlays.update(items, font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                            movable: true, focusedID: focused)
            settle()
        }
        func frames(_ source: CaptionMascot) -> [NSRect] {
            items.filter { $0.mascot == source }.map { overlays.controller(for: $0.id)!.panel.frame }
        }
        update()
        let codex = overlays.character(for: .codex)!, deepseek = overlays.character(for: .deepseek)!
        require(overlays.characterDiagnostics.count == 2 && codex.subtitle.mascotAnimating
                && deepseek.subtitle.mascotAnimating, "both source characters animate concurrently")
        require(items.allSatisfy {
            overlays.controller(for: $0.id)!.panel.parent === overlays.character(for: $0.mascot!)!.panel
        }, "each bubble attaches only to its own source character")
        for source in [CaptionMascot.codex, .deepseek] {
            let layers = items.filter { $0.mascot == source }.map { overlays.controller(for: $0.id)!.subtitle }
            require(layers[0].tailTarget != nil && layers[1].tailTarget == nil,
                    "\(source.rawValue) independently keeps one tail on its own bottom layer")
        }
        let codexStart = frames(.codex), deepseekStart = frames(.deepseek)
        require(codexStart.allSatisfy { c in deepseekStart.allSatisfy { !c.intersects($0) } },
                "source columns do not overlap by default")
        let deepseekOrigin = deepseek.panel.frame
        codex.panel.setFrameOrigin(codex.panel.frame.origin.offset(dx: -20, dy: 12))
        settle(); update("deepseek-a")
        require(zip(codexStart, frames(.codex)).allSatisfy {
            near($1.minX - $0.minX, -20) && near($1.minY - $0.minY, 12)
        } && frames(.deepseek) == deepseekStart && deepseek.panel.frame == deepseekOrigin,
                "dragging Codex moves only Codex bubbles and survives focus changes")
        let codexOrigin = codex.panel.frame, codexMoved = frames(.codex)
        deepseek.panel.setFrameOrigin(deepseek.panel.frame.origin.offset(dx: 18, dy: 9))
        settle(); update()
        require(codex.panel.frame == codexOrigin && frames(.codex) == codexMoved
                && zip(deepseekStart, frames(.deepseek)).allSatisfy {
                    near($1.minX - $0.minX, 18) && near($1.minY - $0.minY, 9)
                }, "dragging DeepSeek leaves Codex position untouched")
        let deepseekMoved = frames(.deepseek), deepseekRole = deepseek.panel.frame
        items[0] = OverlayItem(id: "codex-a", text: "Codex 更新较长的字幕，检查另一来源的画面不会改变。",
                               header: "Codex · A", title: "A", active: false, mascot: .codex)
        update()
        require(codex.subtitle.mascotAnimating && deepseek.subtitle.mascotAnimating,
                "a finished focused conversation cannot stop another active conversation's source animation")
        items[1] = OverlayItem(id: "codex-b", text: "Codex 项目 B", header: "Codex · B", title: "B",
                               active: false, mascot: .codex)
        update()
        require(!codex.subtitle.mascotAnimating && deepseek.subtitle.mascotAnimating
                && frames(.deepseek) == deepseekMoved && deepseek.panel.frame == deepseekRole,
                "Codex completion and text updates leave DeepSeek running unchanged")
        let frame = deepseek.subtitle.mascotFrameIndex
        let deadline = Date().addingTimeInterval(2)
        while deepseek.subtitle.mascotFrameIndex == frame && Date() < deadline { settle() }
        require(deepseek.subtitle.mascotFrameIndex != frame && codex.subtitle.mascotFrameIndex == 0,
                "one source stops while the other animation continues advancing")
        items.removeAll { $0.mascot == .codex }
        update("deepseek-a")
        require(!codex.panel.isVisible && deepseek.panel.isVisible
                && deepseek.panel.frame == deepseekRole && frames(.deepseek) == deepseekMoved,
                "hiding one source neither hides nor relocates the other")
        require(frames(.deepseek).allSatisfy { area.contains($0) }, "independent source remains on screen")
        overlays.update([], font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                        movable: false, focusedID: "")
    }

    static func checkFixedBubbles() {
        let overlays = ProjectOverlays()
        let items = [
            OverlayItem(id: "fixed-codex-a", text: "Codex 项目 A", header: "Codex", title: "A", active: false, mascot: .codex),
            OverlayItem(id: "fixed-codex-b", text: "Codex 项目 B", header: "Codex", title: "B", active: false, mascot: .codex),
            OverlayItem(id: "fixed-deepseek", text: "DeepSeek 项目", header: "DeepSeek", title: "C", active: false, mascot: .deepseek)
        ]
        func update(fixed: Bool, movable: Bool = true) {
            overlays.update(items, font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                            movable: movable, focusedID: items[0].id,
                            bubblesFixedToCharacter: fixed, pinkBearBinding: .codex)
            settle()
        }
        func frames() -> [NSRect] { items.map { overlays.controller(for: $0.id)!.panel.frame } }
        update(fixed: false)
        let bubble = overlays.controller(for: items[0].id)!
        bubble.panel.setFrameOrigin(bubble.panel.frame.origin.offset(dx: 14, dy: 6))
        settle()
        let arranged = frames()
        update(fixed: true)
        require(frames() == arranged, "locking preserves the current manually arranged bubble offsets")
        require(items.allSatisfy {
            let panel = overlays.controller(for: $0.id)!.panel
            return panel.ignoresMouseEvents && !panel.isMovableByWindowBackground
        } && [CaptionMascot.codex, .deepseek].allSatisfy {
            let controller = overlays.character(for: $0)!
            // Mouse transparency depends on the live pointer and artwork alpha.
            // Sample an opaque pixel rather than assuming the user's cursor is on it.
            let view = controller.subtitle
            for y in stride(from: 8.0, to: Double(view.bounds.height), by: 8) {
                for x in stride(from: 8.0, to: Double(view.bounds.width), by: 8) {
                    let point = NSPoint(x: x, y: y)
                    if view.containsVisibleCharacter(at: point) {
                        controller.refreshCharacterMouseTransparency(at: point.offset(
                            dx: controller.panel.frame.minX, dy: controller.panel.frame.minY))
                        return !controller.panel.ignoresMouseEvents && controller.panel.isMovableByWindowBackground
                    }
                }
            }
            return false
        }, "fixed mode makes both Harness bubble groups click-through while only characters are draggable")
        for source in [CaptionMascot.codex, .deepseek] {
            let character = overlays.character(for: source)!.panel
            let before = frames()
            character.setFrameOrigin(character.frame.origin.offset(dx: -12, dy: 10))
            require(items.enumerated().allSatisfy { index, item in
                let after = overlays.controller(for: item.id)!.panel.frame
                return item.mascot == source
                    ? near(after.minX - before[index].minX, -12) && near(after.minY - before[index].minY, 10)
                    : after == before[index]
            }, "locked \(source.rawValue) bubbles follow their character immediately and independently")
            let moved = frames()
            update(fixed: true)
            require(frames() == moved, "locked \(source.rawValue) offsets survive refresh")
        }
        update(fixed: true, movable: false)
        require([CaptionMascot.codex, .deepseek].allSatisfy {
            overlays.character(for: $0)!.panel.ignoresMouseEvents
        } && items.allSatisfy { overlays.controller(for: $0.id)!.panel.ignoresMouseEvents },
                "the drag switch still disables character interaction in fixed mode")
        let lockedFrames = frames()
        update(fixed: false)
        require(frames() == lockedFrames && items.allSatisfy {
            let panel = overlays.controller(for: $0.id)!.panel
            return !panel.ignoresMouseEvents && panel.isMovableByWindowBackground
        }, "unlocking restores independent bubble dragging without moving windows")
        bubble.panel.setFrameOrigin(bubble.panel.frame.origin.offset(dx: 8, dy: 4))
        settle(); update(fixed: false)
        require(near(bubble.panel.frame.minX - lockedFrames[0].minX, 8)
                && near(bubble.panel.frame.minY - lockedFrames[0].minY, 4),
                "unlocked bubble adjustments are retained on refresh")
        overlays.update([], font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                        movable: false, focusedID: "")
    }

    static func checkPinkBearBinding() {
        for developerMode in [false, true] {
            require(!CharacterChoice.selectable(developerMode: developerMode).contains(.pinkBear),
                    "retired bear is unavailable in every build and mode")
            require(CharacterChoice.resolved("pinkBear", developerMode: developerMode) == .defaultChoice,
                    "legacy bear bindings resolve to the default character")
        }
    }

    static func checkAudioCharacters() {
        let overlays = ProjectOverlays()
        func update(_ sources: Set<CaptionMascot>) {
            overlays.update([], font: 28, opacity: 0.68, bottom: 46, screenIndex: 0,
                            movable: true, focusedID: "", audioMascots: sources)
        }
        update([.codex, .deepseek])
        require(overlays.visibleIDs.isEmpty && overlays.characterDiagnostics.count == 2,
                "audio-only characters appear without invented caption bubbles")
        let codex = overlays.character(for: .codex)!, deepseek = overlays.character(for: .deepseek)!
        let origin = deepseek.panel.frame
        let codexOrigin = codex.panel.frame
        for index in 0..<24 {
            overlays.setDeepSeekPerformance(index)
            require(deepseek.subtitle.performanceFrameIndex == index && codex.subtitle.performanceFrameIndex == nil,
                    "singing frame \(index) affects only DeepSeek")
            require(deepseek.panel.frame == origin && codex.panel.frame == codexOrigin,
                    "body frames never resize or move source windows")
        }
        overlays.setDeepSeekPerformance(nil)
        overlays.setAudioMouth(2, targets: [.codex, .deepseek])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func pixels(_ view: SubtitleView) -> Data {
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        let beforeBreath = [pixels(codex.subtitle), pixels(deepseek.subtitle)]
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        require(codex.subtitle.seatedMotionAnimating && deepseek.subtitle.seatedMotionAnimating &&
                beforeBreath[0] != pixels(codex.subtitle) && beforeBreath[1] != pixels(deepseek.subtitle) &&
                codex.subtitle.audioMouthIndex == 2 && deepseek.subtitle.audioMouthIndex == 2,
                "both seated bodies move while the same mouth pose is held")
        require(codex.panel.frame == codexOrigin && deepseek.panel.frame == origin,
                "breathing keeps character windows and floor positions fixed")
        overlays.setDeepSeekPerformance(16)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        require(!deepseek.subtitle.seatedMotionAnimating && codex.subtitle.seatedMotionAnimating,
                "standing performance suspends only DeepSeek seated breathing")
        overlays.setDeepSeekPerformance(nil)
        overlays.setAudioMouth(2, targets: [.codex])
        require(codex.subtitle.audioMouthIndex == 2 && deepseek.subtitle.audioMouthIndex == nil,
                "audio mouth target affects only its chosen role")
        overlays.setAudioMouth(nil, targets: [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        require(!codex.subtitle.seatedMotionAnimating && !deepseek.subtitle.seatedMotionAnimating,
                "seated motion timers stop after silence fades back to thinking")
        update([.codex, .deepseek])
        require(!codex.subtitle.seatedMotionAnimating && !deepseek.subtitle.seatedMotionAnimating,
                "layout refresh does not restart faded breathing timers")
        require(codex.subtitle.mascotAnimating && deepseek.subtitle.mascotAnimating,
                "audio-enabled roles keep thinking timers running without active sessions")
        let initialCodexFrame = codex.subtitle.mascotFrameIndex
        let initialDeepSeekFrame = deepseek.subtitle.mascotFrameIndex
        let deadline = Date().addingTimeInterval(2)
        while (codex.subtitle.mascotFrameIndex == initialCodexFrame ||
               deepseek.subtitle.mascotFrameIndex == initialDeepSeekFrame) && Date() < deadline { settle() }
        require(codex.subtitle.audioMouthIndex == nil && deepseek.subtitle.audioMouthIndex == nil &&
                codex.subtitle.mascotFrameIndex != initialCodexFrame &&
                deepseek.subtitle.mascotFrameIndex != initialDeepSeekFrame,
                "silence releases mouth overlays and both thinking animations advance")
        overlays.setAudioMouth(2, targets: [.codex])
        require(codex.subtitle.audioMouthIndex == 2 && deepseek.subtitle.audioMouthIndex == nil,
                "sound resumes its own mouth while the other role keeps thinking")
        update([.deepseek])
        require(!codex.panel.isVisible && deepseek.panel.isVisible && deepseek.panel.frame == origin,
                "changing audio role preserves the other character position")
        update([])
        require(overlays.characterDiagnostics.isEmpty, "audio-only characters hide when audio stops")
    }
}

private extension NSPoint {
    func offset(dx: CGFloat, dy: CGFloat) -> NSPoint { NSPoint(x: x + dx, y: y + dy) }
}

extension OverlayGeometryChecks {
    static func checkCharacterBindings() {
        let overlays = ProjectOverlays()
        let sources: [CaptionMascot] = [.codex, .deepseek, .claude, .doubao, .opencode, .workbuddy]
        let items = sources.map { OverlayItem(id: $0.rawValue, text: "字幕来自 \($0.rawValue)",
            header: $0.rawValue, title: $0.rawValue, active: true, mascot: $0) }
        func update(_ bindings: [CaptionMascot: CharacterChoice], _ content: [OverlayItem]) {
            overlays.update(content, font: 18, opacity: 0.7, bottom: 46, screenIndex: 0,
                movable: true, focusedID: "codex", bubblesFixedToCharacter: true,
                restingMascots: Set(bindings.keys), characterBindings: bindings)
        }
        for first in CharacterChoice.allCases {
            for second in CharacterChoice.allCases {
                let bindings: [CaptionMascot: CharacterChoice] = [.codex: first, .deepseek: second]
                update(bindings, Array(items.prefix(2))); settle()
                let shared = first == second
                require(overlays.characterDiagnostics.count == (shared ? 1 : 2), "same role shares one character")
                for source in bindings.keys {
                    require(overlays.character(for: source)?.subtitle.mascotArtwork == bindings[source]!.rawValue,
                            "each harness resolves its selected artwork")
                    require(overlays.controller(for: source.rawValue)?.panel.parent === overlays.character(for: source)?.panel,
                            "each bubble belongs to its selected character")
                }
                require((overlays.character(for: .codex)?.panel === overlays.character(for: .deepseek)?.panel) == shared,
                        "source routing aliases only shared roles")
                require(overlays.visibleIDs.count == 2, "merging preserves both captions")
                overlays.setAudioMouth(3, targets: [.codex])
                let mouth = first == .pinkBear ? nil : 3
                require(overlays.character(for: .codex)?.subtitle.audioMouthIndex == mouth, "audio reaches selected role")
                require(overlays.character(for: .deepseek)?.subtitle.audioMouthIndex == (shared ? mouth : nil),
                        "shared role receives audio through either harness")
                overlays.setDeepSeekPerformance(0, targets: [.codex])
                require(overlays.character(for: .codex)?.subtitle.performanceFrameIndex == (first == .deepseek ? 0 : nil),
                        "performance routes to the selected whale")
                overlays.setDeepSeekPerformance(nil)
                if shared {
                    let a = overlays.controller(for: "codex")!.panel.frame
                    let b = overlays.controller(for: "deepseek")!.panel.frame
                    require(a.maxY <= b.minY || b.maxY <= a.minY, "shared bubbles stack without overlap")
                    update(bindings, [items[1]])
                    require(overlays.visibleIDs == ["deepseek"], "removing one caption preserves the other")
                    require(overlays.characterDiagnostics.count == 1, "owner remains stable without its own task")
                }
            }
        }
        for choice in CharacterChoice.allCases {
            let mixed: [CaptionMascot: CharacterChoice] = [.codex: .codex, .deepseek: .codex,
                .claude: .pinkBear, .doubao: .pinkBear, .opencode: .codex, .workbuddy: choice]
            update(mixed, items); settle()
            require(overlays.characterDiagnostics.count == Set(mixed.values).count,
                    "six mixed bindings produce one window per distinct role")
            require(overlays.visibleIDs.count == 6, "mixed grouping preserves every source caption")
            for source in sources {
                require(overlays.character(for: source)?.subtitle.mascotArtwork == mixed[source]!.rawValue,
                        "mixed role routing retains selected artwork")
            }
        }
        let same = Dictionary(uniqueKeysWithValues: sources.map { ($0, CharacterChoice.codex) })
        update(same, items); settle()
        require(overlays.characterDiagnostics.count == 1 && overlays.visibleIDs.count == 6,
                "six harnesses share one character with six captions")
        let parent = overlays.character(for: .codex)!.panel
        require(sources.allSatisfy { overlays.controller(for: $0.rawValue)?.panel.parent === parent },
                "all six captions follow the shared character")
        let restacks = overlays.layerRestackCount
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { update(same, items) }
        print("INFO: 100 refreshes, six harnesses/one character: \(ProcessInfo.processInfo.systemUptime - started) seconds")
        require(overlays.layerRestackCount == restacks, "unchanged refreshes do not restack windows")
        update([.codex: .codex, .claude: .deepseek], [items[0], items[2]])
        require(overlays.characterDiagnostics.count == 2, "changing a binding splits the characters")
        update([.claude: .codex], [items[2]])
        require(overlays.characterDiagnostics.count == 1 && overlays.visibleIDs == ["claude"],
                "disabling the former owner keeps the enabled harness visible")
        update([:], [])
        require(overlays.characterDiagnostics.isEmpty && overlays.visibleIDs.isEmpty, "all disabled hides every panel")
    }
}
