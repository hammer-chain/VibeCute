import AppKit

enum CharacterPositionChecks {
    static let items = [
        OverlayItem(id: "saved-codex-a", text: "正在检查位置。", header: "Codex · A", title: "A", active: false, mascot: .codex),
        OverlayItem(id: "saved-codex-b", text: "正在检查堆叠。", header: "Codex · B", title: "B", active: false, mascot: .codex),
        OverlayItem(id: "saved-deepseek-a", text: "正在检查位置。", header: "DeepSeek · A", title: "A", active: false, mascot: .deepseek),
        OverlayItem(id: "saved-deepseek-b", text: "正在检查堆叠。", header: "DeepSeek · B", title: "B", active: false, mascot: .deepseek)
    ]

    static func fixture(mode: String, suite: String) {
        let store = CharacterPositionStore(defaults: UserDefaults(suiteName: suite)!)
        let overlays = ProjectOverlays(positionStore: store)
        func update(_ scale: Double = 1) {
            overlays.update(items, font: 20, opacity: 0.68, bottom: 46, screenIndex: 0,
                            movable: true, focusedID: items[0].id, characterScale: scale)
            OverlayGeometryChecks.settle()
        }
        func anchors() -> [String: [Double]] {
            Dictionary(uniqueKeysWithValues: [CaptionMascot.codex, .deepseek].map {
                let frame = overlays.character(for: $0)!.panel.frame
                return ($0.rawValue, [Double(frame.midX), Double(frame.minY)])
            })
        }
        update()
        if mode == "write" {
            for (source, dx, dy) in [(CaptionMascot.codex, -30.0, 15.0), (.deepseek, 20.0, 27.0)] {
                let panel = overlays.character(for: source)!.panel
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            update()
            // Quit immediately after one more move, before the debounce fires.
            let panel = overlays.character(for: .codex)!.panel
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX - 7, y: panel.frame.minY + 3))
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        }
        var result = anchors()
        if mode == "read" {
            update(); update()
            OverlayGeometryChecks.require(anchors() == result, "restored anchors survive periodic refresh")
            update(1.5)
            let resized = anchors()
            OverlayGeometryChecks.require(result.allSatisfy { key, value in
                zip(value, resized[key]!).allSatisfy { abs($0 - $1) < 1 }
            }, "restored bottom-center anchors survive character scaling within native window rounding")
        }
        // A source becoming hidden must not erase its remembered location.
        overlays.update([], font: 20, opacity: 0.68, bottom: 46, screenIndex: 0,
                        movable: true, focusedID: "")
        overlays.flushPositions()
        result["hidden"] = [1]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("POSITION_JSON:" + String(data: data, encoding: .utf8)!)
    }

    static func run() {
        let suite = "app.vibecute.position-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
        func child(_ mode: String) -> [String: [Double]] {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--position-fixture", mode, suite]
            process.standardOutput = pipe
            try! process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            OverlayGeometryChecks.require(process.terminationStatus == 0, "\(mode) position fixture exits successfully")
            let output = String(data: data, encoding: .utf8)!
            let row = output.split(separator: "\n").first { $0.hasPrefix("POSITION_JSON:") }!
            return try! JSONSerialization.jsonObject(with: Data(row.dropFirst("POSITION_JSON:".count).utf8)) as! [String: [Double]]
        }
        let written = child("write"), restored = child("read")
        OverlayGeometryChecks.require(written == restored,
            "a fresh native process restores both source positions, including the final move before quit")
        OverlayGeometryChecks.require(restored["codex"] != restored["deepseek"],
            "Codex and DeepSeek retain separate saved positions")

        let store = CharacterPositionStore(defaults: defaults)
        let area = NSScreen.screens[0].visibleFrame
        store.save(anchor: NSPoint(x: area.minX - 9000, y: area.maxY + 9000), source: "codex", in: area)
        let overlays = ProjectOverlays(positionStore: store)
        overlays.update(items.filter { $0.mascot == .codex }, font: 20, opacity: 0.68, bottom: 46,
                        screenIndex: 0, movable: true, focusedID: items[0].id)
        let role = overlays.character.panel.frame
        let rows = overlays.visibleIDs.map { overlays.controller(for: $0)!.panel.frame }
        OverlayGeometryChecks.require(area.contains(role) && rows.allSatisfy { area.contains($0) }
            && zip(rows, rows.dropFirst()).allSatisfy { $1.minY - $0.maxY >= 0 && $1.minY - $0.maxY <= 3 },
            "an off-screen saved anchor restores the whole continuous stack inside the current display")
        overlays.update([], font: 20, opacity: 0.68, bottom: 46, screenIndex: 0, movable: false, focusedID: "")

        let translated = area.offsetBy(dx: -1000, dy: 300)
        let saved = store.anchor(for: "codex", in: area)!
        let moved = store.anchor(for: "codex", in: translated)!
        OverlayGeometryChecks.require(moved.x == saved.x - 1000 && moved.y == saved.y + 300,
            "display origin changes preserve saved screen-relative coordinates")
        defaults.set(["codex": ["x": "invalid", "y": 40]], forKey: "characterPositions")
        OverlayGeometryChecks.require(store.anchor(for: "codex", in: area) == nil,
            "malformed saved coordinates fall back to the default anchor")
        CharacterPositionStore.saveScreen(0, defaults: defaults)
        defaults.set(999, forKey: "screenIndex")
        OverlayGeometryChecks.require(CharacterPositionStore.selectedScreen(defaults: defaults, screens: NSScreen.screens) == 0,
            "saved display identity takes priority over a reordered display index")
        defaults.set("missing-display", forKey: "selectedDisplayID")
        OverlayGeometryChecks.require(CharacterPositionStore.selectedScreen(defaults: defaults, screens: NSScreen.screens)
            == NSScreen.screens.count - 1, "missing displays fall back to an available display")
    }
}
