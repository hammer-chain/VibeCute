import AppKit
import CaptionCore
@testable import CodexCaptions

@main struct IdleWorkResumeChecks {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let suite = CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--preferences-suite")! + 1]
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "onboardingVersion")
        defaults.set("complete", forKey: "onboardingStep")
        defaults.set(["claude":"deepseek"], forKey: "characterBindings")
        defaults.set(["claude"], forKey: "trackedHarnesses")
        for key in ["audioEnabled", "autoAvoidanceEnabled", "companionEnabled", "autoHide", "typewriterEnabled"] {
            defaults.set(false, forKey: key)
        }
        defaults.set(true, forKey: "autoWindowPeekEnabled")
        let root = CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--claude-root")! + 1]
        let folder = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("resume.jsonl")
        try Data().write(to: log)
        var serial = 0
        func append(user: Bool, terminal: Bool = false) throws {
            serial += 1
            let message: [String:Any] = user ? ["content":"新任务 \(serial)"]
                : ["stop_reason":terminal ? "end_turn" : "tool_use", "content":[["type":"text", "text":"任务结束 \(serial)"]]]
            let row: [String:Any] = ["type":user ? "user" : "assistant", "sessionId":"idle-resume",
                "cwd":"/fixture", "uuid":"resume-\(serial)", "timestamp":ISO8601DateFormatter().string(from:Date()), "message":message]
            var data = try JSONSerialization.data(withJSONObject: row); data.append(10)
            let file = try FileHandle(forWritingTo: log)
            try file.seekToEnd(); try file.write(contentsOf: data); try file.close()
        }
        // A running session can have no displayable caption (e.g. hidden tools).
        let overlays = ProjectOverlays()
        overlays.update([], font:14, opacity:1, bottom:16, screenIndex:0, movable:true,
                        focusedID:"", thinkingMascots:[.claude], characterBindings:[.claude:.deepseek])
        precondition(overlays.characterDiagnostics.first?["animating"] as? Bool == true)
        precondition(overlays.visibleIDs.isEmpty, "Thinking without output must not fabricate a caption")
        let character = overlays.character(for: .claude)!
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.screens[0]
        let screenIndex = NSScreen.screens.firstIndex(of: screen)!
        func updateDockedWork() {
            overlays.update([], font:14, opacity:1, bottom:16, screenIndex:screenIndex, movable:true,
                            focusedID:"", thinkingMascots:[.claude], characterBindings:[.claude:.deepseek])
        }
        updateDockedWork()
        for side in [ScreenEdgeDock.Side.left, .right] {
            let probe = NSPoint(x:side == .left ? screen.frame.minX-1 : screen.frame.maxX+1,
                                y:screen.visibleFrame.minY+150)
            if NSScreen.screens.contains(where: { $0 !== screen && $0.frame.contains(probe) }) { continue }
            character.panel.beginManualDrag()
            character.panel.setFrameOrigin(NSPoint(x:side == .left ? screen.frame.minX : screen.frame.maxX-character.panel.frame.width,
                                                   y:screen.visibleFrame.minY+70))
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            character.panel.finishManualDragIfReleased(buttonDown:false)
            for _ in 0..<8 { character.subtitle.advanceScreenEdgeFrame() }
            precondition(character.subtitle.screenEdgeDock == side, "dock expected \(side), actual \(String(describing: character.subtitle.screenEdgeDock)), frame \(character.panel.frame)")
            let hiddenFrame = character.panel.frame
            for _ in 0..<3 { updateDockedWork() }
            precondition(character.subtitle.screenEdgeDock == side && character.subtitle.screenEdgePlayback?.phase == .peeking,
                         "New work must preserve manual edge hiding")
            precondition(character.panel.frame == hiddenFrame && overlays.visibleIDs.isEmpty,
                         "New work must not pull the character out or show a bubble")
            character.panel.beginManualDrag()
            character.panel.setFrameOrigin(NSPoint(x:screen.visibleFrame.midX, y:screen.visibleFrame.minY+70))
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            character.panel.finishManualDragIfReleased(buttonDown:false)
            for _ in 0..<8 { character.subtitle.advanceScreenEdgeFrame() }
            updateDockedWork()
            precondition(character.subtitle.screenEdgeDock == nil && character.subtitle.mascotAnimating,
                         "Only manually dragging out restores the working pose")
        }
        overlays.update([], font:14, opacity:1, bottom:16, screenIndex:0, movable:true,
                        focusedID:"", characterBindings:[.claude:.deepseek])
        precondition(overlays.characterDiagnostics.isEmpty, "Auto-hidden character must stop after work ends")
        let model = AppModel()
        let bindings = model.characterBindings
        let tracked = model.trackedHarnesses
        let question = UserQuestionRequest.parse(id:"idle-question", turnID:nil, asynchronous:true,
            questions:[["title":"等待选择", "options":["继续"]]], date:Date())!
        for source in SessionSource.allCases {
            model.trackedHarnesses = [source.preferenceID]
            for choice in [CharacterChoice.deepseek, .orangeHoodie] {
                model.characterBindings = [source.preferenceID:choice.rawValue]
                var session = SessionSnapshot(path:"/fixture", id:"busy", active:true, activity:.distantPast)
                session.source = source
                model.sessions = [session]
                precondition(!model.harnessIdle(for:choice), "All bound tasks block rest, even without recent captions: \(source)")
                session.active = false; session.runningSubagentCount = 1; model.sessions = [session]
                precondition(!model.harnessIdle(for:choice), "Running subagents block rest")
                session.runningSubagentCount = 0; session.pendingQuestions = [question]; model.sessions = [session]
                precondition(!model.harnessIdle(for:choice), "Waiting for an answer is still a task")
                session.pendingQuestions[0].externalApproval = true; model.sessions = [session]
                precondition(!model.harnessIdle(for:choice), "Waiting for approval is still a task")
                session.pendingQuestions = []; session.readable = false; model.sessions = [session]
                precondition(!model.harnessIdle(for:choice), "Unreadable state must not be treated as idle")
                session.readable = true; model.sessions = [session]
                precondition(model.harnessIdle(for:choice), "A completed task permits rest")
                session.active = true; model.sessions = [session]
                let other: CharacterChoice = choice == .deepseek ? .orangeHoodie : .deepseek
                precondition(model.harnessIdle(for:other), "Work only blocks the bound character")
            }
        }
        model.trackedHarnesses = ["codex", "claude"]
        model.characterBindings = ["codex":CharacterChoice.orangeHoodie.rawValue, "claude":CharacterChoice.orangeHoodie.rawValue]
        var background = SessionSnapshot(path:"/fixture/background", id:"background", active:true)
        background.source = .claude
        model.sessions = [SessionSnapshot(path:"/fixture/complete", id:"complete"), background]
        precondition(!model.harnessIdle(for:.orangeHoodie), "Any busy Harness sharing the character blocks idle interaction")
        model.trackedHarnesses = ["codex"]
        model.sessions = [background]
        precondition(model.harnessIdle(for:.orangeHoodie), "Untracked Harnesses must not block another character")
        model.sessions = []
        model.trackedHarnesses = tracked
        model.characterBindings = bindings
        func fish() -> [String:Any]? { model.developerPreviewCharacters.first { ($0["artwork"] as? String) == "deepseek" } }
        func wait(_ label: String, _ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
            precondition(predicate(), label + ": " + model.autoWindowPeekLabel)
        }
        try append(user: true); try append(user: false, terminal: true)
        model.start()
        wait("Enter automatic sleep") { !(fish()?["sleepPhase"] as? String ?? "").isEmpty }
        try append(user: true)
        wait("New task clears sleep and animates without a caption") {
            fish()?["sleepPhase"] as? String == "" && fish()?["animating"] as? Bool == true
        }
        precondition(!model.windowPeekActive)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        precondition(fish()?["sleepPhase"] as? String == "", "Active work must not reenter sleep")
        try append(user: false, terminal: true)
        wait("Completion allows a fresh idle interval") { !(fish()?["sleepPhase"] as? String ?? "").isEmpty }
        model.autoWindowPeekEnabled = false
        // Complete the normal wake before testing the independent window interaction.
        wait("Disabled idle wakes") { fish()?["sleepPhase"] as? String == "" }
        model.showWindowPeek()
        wait("Window rest starts") { model.windowPeekActive }
        try append(user: true)
        wait("New task releases window rest and restores the original character") {
            !model.windowPeekActive && fish()?["animating"] as? Bool == true
        }
        precondition(!model.demoMode)
        model.autoHide = true
        wait("Working character remains visible with auto hide") { fish()?["animating"] as? Bool == true }
        model.bind(.orangeHoodie, to:.claude)
        model.developerPreviewCharacter = .orangeHoodie
        model.previewAction(.crabPet)
        precondition(!model.demoMode && model.developerPreviewStatus.contains("正在工作"), "Crab preview must not bypass a bound task")
        print("PASS: 7 Harnesses x 2 characters block active/subagent/question/approval/unreadable tasks; shared bindings and untracked isolation; crab preview cannot bypass work; automatic sleep interrupted by captionless work; no resleep while active; completion resets idle; window rest releases original character; manual edge hiding preserved; auto-hide retains working animation")
    }
}
