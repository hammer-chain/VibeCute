import AppKit

enum DialogueLayerChecks {
    static func run() {
        let overlays = ProjectOverlays()
        var items = [
            OverlayItem(id: "layer-codex", text: "上层角色的字幕", header: "Codex", title: "上层对话", active: false,
                mascot: .codex, averageSpeed: 20, quotaText: "额度 -", onOpenConversation: { nil }),
            OverlayItem(id: "layer-deepseek", text: "下层角色的字幕", header: "DeepSeek Harness", title: "下层对话", active: false,
                mascot: .deepseek, averageSpeed: 30, quotaText: "账户余额 -", onOpenConversation: { nil })
        ]
        func refresh() {
            overlays.update(items, font: 18, opacity: 0.7, bottom: 60, screenIndex: 0,
                movable: true, focusedID: "layer-codex", characterBindings: [.codex: .codex, .deepseek: .deepseek])
        }
        refresh()
        let codex = overlays.character(for: .codex)!, deepseek = overlays.character(for: .deepseek)!
        let codexBubble = overlays.controller(for: "layer-codex")!, deepseekBubble = overlays.controller(for: "layer-deepseek")!
        func drag(_ controller: OverlayController) {
            controller.panel.beginManualDrag()
            controller.panel.setFrameOrigin(NSPoint(x: 600, y: 220))
            controller.panel.finishManualDragIfReleased(buttonDown: false)
            OverlayGeometryChecks.settle()
        }
        deepseek.panel.setFrameOrigin(NSPoint(x: 600, y: 220))
        drag(codex)
        func windowNumbers(_ root: NSWindow) -> [Int] {
            (root.isVisible ? [root.windowNumber] : []) + (root.childWindows ?? []).flatMap(windowNumbers)
        }
        func sourceIsFront(_ foreground: OverlayController, _ background: OverlayController) -> Bool {
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let numbers = rows.compactMap { $0[kCGWindowNumber as String] as? Int }
            let front = windowNumbers(foreground.panel).compactMap { numbers.firstIndex(of: $0) }
            let back = windowNumbers(background.panel).compactMap { numbers.firstIndex(of: $0) }
            return !front.isEmpty && !back.isEmpty && front.max()! < back.min()!
        }
        func check(_ ok: Bool, _ label: String) { OverlayGeometryChecks.require(ok, label) }
        check(codexBubble.panel.frame.intersects(deepseekBubble.panel.frame), "two actual dialogue windows overlap")
        check(sourceIsFront(codex, deepseek), "dragging a character raises its complete dialogue and title-control group")
        var stable = true
        for index in 0..<20 {
            let bubble = index.isMultiple(of: 2) ? deepseekBubble : codexBubble
            let frame = bubble.panel.frame
            bubble.update(text: "流式更新 \(index)", context: index.isMultiple(of: 2) ? "DeepSeek Harness" : "Codex",
                title: "更新后的标题 \(index)", live: false, mascot: nil, font: 18, opacity: 0.7,
                bottom: 60, screenIndex: 0, movable: false, visible: true,
                anchor: NSPoint(x: frame.midX, y: frame.minY), mode: .bubble,
                resetManualOffset: true, onOpenConversation: { nil })
            stable = stable && sourceIsFront(codex, deepseek)
        }
        check(stable, "alternating independent dialogue and title updates never change either group's priority")
        let before = overlays.layerRestackCount
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { refresh() }
        OverlayGeometryChecks.settle()
        check(sourceIsFront(codex, deepseek), "100 complete caption refreshes preserve all overlapping group layers")
        check(overlays.layerRestackCount == before, "100 normal refreshes perform zero layer restacks")
        print("INFO: 100 two-character dialogue refreshes: \(ProcessInfo.processInfo.systemUptime - start)s, including one 80 ms settle; zero restacks, no additional timer")
        deepseek.refreshSpeedHover(at: NSPoint(x: deepseek.panel.frame.midX, y: deepseek.panel.frame.midY), leftButtonDown: false)
        OverlayGeometryChecks.settle()
        check(sourceIsFront(codex, deepseek), "showing lower-character metrics does not promote its dialogue group")
        items.append(OverlayItem(id: "layer-extra", text: "下层新增字幕", header: "DeepSeek Harness", title: "新增对话",
            active: false, mascot: .deepseek, onOpenConversation: { nil }))
        refresh(); OverlayGeometryChecks.settle()
        check(sourceIsFront(codex, deepseek), "a new lower-group dialogue enters below the last dragged group")
        deepseek.panel.setFrameOrigin(NSPoint(x: 610, y: 220)); drag(deepseek)
        check(sourceIsFront(deepseek, codex), "dragging the other character changes priority for all of its dialogues together")
        refresh(); OverlayGeometryChecks.settle()
        check(sourceIsFront(deepseek, codex), "the new complete-group priority survives another update")
        overlays.setSourceHidden(.codex, true); overlays.setSourceHidden(.deepseek, true)
    }
}
