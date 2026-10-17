import AppKit
import SwiftUI
import CaptionCore
@testable import CodexCaptions

@main struct DeveloperPreviewChecks {
    static func main() throws {
        _ = NSApplication.shared
        let index = CommandLine.arguments.firstIndex(of:"--preferences-suite")!
        let suite = CommandLine.arguments[index+1]
        let defaults = UserDefaults(suiteName:suite)!
        defaults.removePersistentDomain(forName:suite)
        defaults.set(true,forKey:"developerModeEnabled")
        defaults.set(1,forKey:"onboardingVersion"); defaults.set("complete",forKey:"onboardingStep")
        let bindings = ["codex":"blue-fish-orange-hoodie","deepseek":"blue-fish-orange-hoodie"]
        defaults.set(bindings,forKey:"characterBindings")
        defaults.set(["codex","deepseek"],forKey:"trackedHarnesses")
        defaults.set(false,forKey:"typewriterEnabled"); defaults.set(false,forKey:"autoHide"); defaults.set(false,forKey:"companionEnabled")
        defaults.set(false,forKey:"audioEnabled"); defaults.set(false,forKey:"autoWindowPeekEnabled")
        let model = AppModel()
        for character in [CharacterChoice.orangeHoodie,.deepseek,.codex] {
            model.developerPreviewCharacter = character
            model.previewAction(.thinking)
            let expected = character.rawValue
            precondition(model.developerPreviewArtwork == expected,"Preview picker must route to the selected artwork")
            model.stopPreview()
            precondition(model.developerPreviewArtwork == nil)
        }
        model.developerPreviewCharacter = .orangeHoodie
        for action in [DeveloperPreviewAction.thinking,.mouth,.singing,.shortAvoidance] {
            precondition(action.supports(.orangeHoodie))
            model.previewAction(action)
            precondition(model.developerPreviewArtwork == "blue-fish-orange-hoodie","New action must never borrow the original outfit")
        }
        let before = model.developerPreviewArtwork
        model.previewAction(.stroll)
        precondition(model.developerPreviewArtwork == before && model.developerPreviewStatus.contains("尚未"))
        model.stopPreview()
        precondition(defaults.dictionary(forKey:"characterBindings") as? [String:String] == bindings,"Preview cannot alter real character bindings")
        model.characterBindings = ["claude":"codex", "deepseek":"deepseek"]
        model.trackedHarnesses = ["claude", "deepseek"]
        let claudeRootIndex = CommandLine.arguments.firstIndex(of: "--claude-root")!
        let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[claudeRootIndex + 1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let log = fixtureDirectory.appendingPathComponent("claude-preview.jsonl")
        var serial = 0
        func append(_ type: String, _ message: [String: Any]) throws {
            serial += 1
            let row: [String: Any] = ["type":type, "sessionId":"preview-fixture", "cwd":"/fixture",
                "uuid":"fixture-\(serial)", "timestamp":ISO8601DateFormatter().string(from:Date()), "message":message]
            var data = try JSONSerialization.data(withJSONObject: row); data.append(10)
            if !FileManager.default.fileExists(atPath: log.path) { try Data().write(to: log) }
            let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); try handle.write(contentsOf:data); try handle.close()
        }
        func waitForCaption(_ text: String) {
            let deadline = Date().addingTimeInterval(10)
            while !model.developerPreviewCaptions.contains(where: { ($0["text"] as? String) == text }) && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            precondition(model.developerPreviewCaptions.contains { ($0["text"] as? String) == text }, "Other character caption failed to update: \(text)")
        }
        try append("user", ["content":"fixture request"])
        try append("assistant", ["stop_reason":"tool_use", "content":[["type":"text", "text":"工服角色字幕保留"]]])
        model.start()
        waitForCaption("工服角色字幕保留")
        let captionBefore = model.developerPreviewCaptions.first { ($0["text"] as? String) == "工服角色字幕保留" }!
        model.developerPreviewCharacter = .deepseek
        let otherBefore = model.developerPreviewCharacters.first { ($0["artwork"] as? String) == "codex" }!
        for action in [DeveloperPreviewAction.thinking, .mouth, .singing, .sleep, .sleepContinuous] {
            model.previewAction(action)
            let other = model.developerPreviewCharacters.first { ($0["artwork"] as? String) == "codex" }
            precondition(other != nil, "Claude workwear must remain visible during every fish preview")
            precondition(other?["id"] as? String == otherBefore["id"] as? String, "Keep the existing character lane")
            precondition(model.developerPreviewCharacters.filter { ($0["artwork"] as? String) == "deepseek" }.count == 1, "Reuse the existing fish without duplication")
        }
        waitForCaption("工服角色字幕保留")
        let captionDuring = model.developerPreviewCaptions.first { ($0["text"] as? String) == "工服角色字幕保留" }!
        precondition(captionBefore["windowNumber"] as? Int == captionDuring["windowNumber"] as? Int, "Preview must not remount another character's caption")
        try append("assistant", ["stop_reason":"tool_use", "content":[["type":"text", "text":"预览期间字幕继续更新"]]])
        waitForCaption("预览期间字幕继续更新")
        RunLoop.main.run(until: Date().addingTimeInterval(DeepSeekSleepTimeline.duration + 1))
        precondition(model.demoMode, "Continuous sleep must outlast the complete wake-up timeline")
        let sleeper = model.developerPreviewCharacters.first { ($0["artwork"] as? String) == "deepseek" }!
        precondition(sleeper["sleepPhase"] as? String == "趴着睡觉")
        precondition(model.developerPreviewCharacters.contains { ($0["artwork"] as? String) == "codex" })
        for elapsed in [3.2, 7.04, 100.0, 86400.0] {
            let sample = DeepSeekSleepTimeline.sample(at: elapsed, continuous: true)!
            precondition(sample.phase == "趴着睡觉" && !sample.waking)
        }
        precondition(DeepSeekSleepTimeline.sample(at: DeepSeekSleepTimeline.duration) == nil)
        model.stopPreview()
        precondition(model.developerPreviewCharacters.allSatisfy { ($0["sleepPhase"] as? String) == "" })
        precondition(model.developerPreviewCharacters.contains { ($0["artwork"] as? String) == "codex" })
        waitForCaption("预览期间字幕继续更新")
        model.developerPreviewCharacter = .deepseekCutout
        model.previewAction(.thinking)
        precondition(model.developerPreviewCharacters.count == 3, "An unbound preview adds a temporary lane without removing existing characters")
        model.stopPreview()
        let output = URL(fileURLWithPath:"output/developer-previews")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let controller = NSHostingController(rootView:DeveloperSettingsView(model:model).environment(\.colorScheme,.light))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:820),styleMask:[.titled],backing:.buffered,defer:false)
        window.appearance = NSAppearance(named:.aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width:520,height:820))
        window.orderFrontRegardless()
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = controller.view.bitmapImageRepForCachingDisplay(in:controller.view.bounds)!
        controller.view.cacheDisplay(in:controller.view.bounds,to:bitmap)
        let flat = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:flat)
        let rect = NSRect(x:0,y:0,width:flat.pixelsWide,height:flat.pixelsHigh)
        NSColor.white.setFill(); rect.fill()
        NSGraphicsContext.current!.cgContext.setBlendMode(.normal)
        NSGraphicsContext.current!.cgContext.draw(bitmap.cgImage!,in:rect)
        NSGraphicsContext.restoreGraphicsState()
        try flat.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("developer-panel.png"))
        window.orderOut(nil)
        model.stopPreview()
        print("PASS: multiple live characters survive action previews; continuous sleep outlasts wake timeline and stops cleanly;  four preview characters, all hoodie actions, unsupported-action guard, stop/cancel and unchanged real bindings; native developer panel rendered")
    }
}
