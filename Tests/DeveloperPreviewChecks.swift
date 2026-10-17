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
        print("PASS: four preview characters, all hoodie actions, unsupported-action guard, stop/cancel and unchanged real bindings; native developer panel rendered")
    }
}
