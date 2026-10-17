import AppKit
import SwiftUI
import CaptionCore
@testable import CodexCaptions

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = CommandLine.arguments
let suite = args[args.firstIndex(of: "--preferences-suite")! + 1]
let defaults = UserDefaults(suiteName: suite)!
defaults.set(1, forKey: "onboardingVersion")
defaults.set("complete", forKey: "onboardingStep")
defaults.set([], forKey: "trackedHarnesses")
for key in ["claudeTrackingMigrated", "doubaoTrackingMigrated"] { defaults.set(true, forKey: key) }
for key in ["companionEnabled", "audioEnabled", "autoAvoidanceEnabled", "autoWindowPeekEnabled"] { defaults.set(false, forKey: key) }
defer { defaults.removePersistentDomain(forName: suite) }
// Retired artwork must disappear even with preferences from an older full build.
defaults.set(["codex": "pinkBear"], forKey: "characterBindings")
defaults.set("pinkBear", forKey: "companionCharacter")
defaults.set("pinkBear", forKey: "developerPreviewCharacter")
defaults.set("codex", forKey: "pinkBearBinding")
for developerMode in [false, true] {
    precondition(!CharacterChoice.selectable(developerMode: developerMode).contains(.pinkBear))
    precondition(CharacterChoice.resolved("pinkBear", developerMode: developerMode) == .defaultChoice)
}
let delegate = AppDelegate()
app.delegate = delegate
app.finishLaunching()
func settle() {
    let deadline = Date().addingTimeInterval(0.4)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}
settle()
if delegate.model == nil { delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
precondition(delegate.model.characterChoice(for: .codex) == .defaultChoice)
precondition(delegate.model.companionChoice == .defaultChoice)
precondition(delegate.model.developerPreviewCharacter == .defaultChoice)
precondition(delegate.model.pinkBearBinding == .disabled)
print("PASS retired pink bear: hidden in both modes and legacy bindings use default character")
if BuildProfile.isRelease {
    let model = delegate.model!
    precondition(TempoEngine.available == [.beatnet] && LipMatchingEngine.available == [.mfcc])
    precondition(model.audioTempoEngine == .beatnet && model.audioLipEngine == .mfcc)
    model.audioTempoEngine = .btrack; model.audioLipEngine = .acoustic
    precondition(model.audioTempoEngine == .beatnet && model.audioLipEngine == .mfcc)
    model.developerModeEnabled = true
    model.speechKeywordEnabled = true; model.songRecognitionEnabled = true
    model.vocalSeparationEnabled = true
    precondition(!model.developerModeEnabled && !model.speechKeywordEnabled && !model.songRecognitionEnabled && !model.vocalSeparationEnabled)
    precondition(!model.availableCharacters.contains(.deepseekCutout))
    precondition(CharacterChoice.resolved("deepseek-cutout", developerMode: true) == .defaultChoice)
    model.showKiraDemo(); model.showSpeechDemo()
    precondition(!model.demoMode, "Removed demos cannot start in production")
    precondition(!DeepSeekPerformance.shared.kiraAvailable)
    precondition(DeepSeekPerformance.shared.available && DeepSeekPerformance.shared.singingStepAvailable)
    precondition(DeepSeekPerformance.shared.frames.count == DeepSeekPerformance.singingStepStart + 8)
    let analyzer = LiveLipAnalyzer()
    analyzer.tempoEngine = .aubio
    precondition(analyzer.tempoEngine == .beatnet)
    print("PASS release capabilities: old preferences, setters, hidden roles, Kira demos, MFCC, BeatNet and singing-step frames")
} else {
    let model = delegate.model!
    precondition(TempoEngine.available.count == 4 && LipMatchingEngine.available.count == 2)
    model.developerModeEnabled = true
    precondition(model.availableCharacters.contains(.deepseekCutout))
    precondition(DeepSeekPerformance.shared.kiraAvailable && DeepSeekPerformance.shared.singingStepAvailable)
    precondition(DeepSeekPerformance.shared.frames.count == 40)
    model.developerModeEnabled = false
    print("PASS development capabilities: four tempo engines, both lip engines, hidden CutOut selection, Kira and singing-step artwork retained")
}

delegate.detachSettingsFromMenu(); settle()
let window = delegate.detachedSettingsWindow!
precondition(window.titlebarAppearsTransparent && window.titlebarSeparatorStyle == .none)
precondition(window.styleMask.contains(.resizable))
precondition(window.contentView!.bounds.width >= 760 && window.contentView!.bounds.height >= 540)
delegate.detachSettingsFromMenu()
precondition(delegate.detachedSettingsWindow === window, "Opening settings must reuse the existing window")
delegate.model.fontSize = 18; settle()
precondition(defaults.double(forKey: "fontSize") == 18)
delegate.model.bind(.orangeHoodie, to: .codex)
precondition(delegate.model.characterChoice(for: .codex) == .orangeHoodie)
precondition(CharacterChoice.orangeHoodie.title == "蓝色大肥鱼 · Claude Code工服（试验版）")
precondition(CharacterChoice.codex.title == "ChatGPT龙娘 （试验版）")
let menuBindings = HarnessSettingsBindings(model: delegate.model!)
let preferencesBindings = HarnessSettingsBindings(model: delegate.model!)
menuBindings.tracking(.codex).wrappedValue = true
precondition(preferencesBindings.tracking(.codex).wrappedValue)
menuBindings.character(.codex).wrappedValue = .orangeHoodie
precondition(preferencesBindings.character(.codex).wrappedValue == .orangeHoodie)
preferencesBindings.character(.codex).wrappedValue = .deepseek
precondition(menuBindings.character(.codex).wrappedValue == .deepseek)
preferencesBindings.tracking(.codex).wrappedValue = false
precondition(!menuBindings.tracking(.codex).wrappedValue)
precondition(!(defaults.stringArray(forKey: "trackedHarnesses") ?? []).contains("codex"))
menuBindings.character(.codex).wrappedValue = .orangeHoodie
print("PASS shared settings: menu to preferences and preferences to menu tracking/character bindings, persisted state")
func capture(_ view: NSView, _ name: String) {
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "output/native-settings/" + name + ".png"))
}
capture(window.contentView!, "native-check-preferences")
func preview(in view: NSView) -> NSImageView? {
    if view.identifier?.rawValue == "settings-subtitle-preview" { return view as? NSImageView }
    return view.subviews.lazy.compactMap { preview(in: $0) }.first
}
for font in [14.0, 42.0] {
    delegate.model.fontSize = font
    settle()
    let snapshot = preview(in: window.contentView!)!.image!
    for scale in [0.5, 1.0, 1.76, 2.0] {
        delegate.model.characterScale = scale
        settle()
        let image = preview(in: window.contentView!)!
        precondition(image.bounds.height <= 220.5 && image.bounds.width > 0)
        precondition(image.image === snapshot, "Character size must not regenerate subtitle-only preview")
    }
}
capture(window.contentView!, "subtitle-only-check")
delegate.model.fontSize = 18
window.close(); settle()
precondition(delegate.detachedSettingsWindow == nil)
delegate.showPopover(); settle()
precondition(delegate.popover.isShown, "Native status popover must actually open")
precondition(delegate.popover.contentViewController!.view.bounds.width == 340)
let menuController = delegate.popover.contentViewController as! NSHostingController<MenuPanelView>
menuController.rootView.maximumHeight = 1000
settle()
let compactHeight = menuController.view.bounds.height
print("Measured compact height: \(compactHeight)")
precondition(compactHeight > 400 && compactHeight < 700, "Menu should fit natural content, without the old 720pt blank area")
delegate.model.companionEnabled = true
settle()
let expandedHeight = menuController.view.bounds.height
precondition(expandedHeight > compactHeight + 10, "Extra picker must expand the actual popover")
delegate.model.companionEnabled = false
settle()
precondition(abs(menuController.view.bounds.height - compactHeight) < 1, "Collapsing picker must shrink the popover")
capture(menuController.view, "adaptive-menu")
menuController.rootView.maximumHeight = 300
settle()
precondition(abs(menuController.view.bounds.height - 300) < 1, "Small screen must cap the menu")
func scrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.compactMap { scrollView(in: $0) }.first
}
let scroll = scrollView(in: menuController.view)!
precondition(scroll.documentView!.bounds.height > scroll.contentView.bounds.height)
scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
scroll.reflectScrolledClipView(scroll.contentView)
precondition(scroll.contentView.bounds.origin.y > 0, "Overflow must actually scroll")
capture(menuController.view, "adaptive-menu-small-screen")
menuController.rootView.maximumHeight = 1000
settle()
print("PASS adaptive menu: compact=\(compactHeight), expanded=\(expandedHeight), small-screen cap=300; overflow scroll verified")
menuBindings.tracking(.codex).wrappedValue = true; settle()
capture(delegate.popover.contentViewController!.view, "menu")
menuBindings.tracking(.codex).wrappedValue = false; settle()
delegate.detachSettingsFromMenu(); settle()
print("Menu transition: shown=\(delegate.popover.isShown), window=\(delegate.detachedSettingsWindow != nil)")
precondition(!delegate.popover.isShown)
precondition(delegate.detachedSettingsWindow != nil && delegate.detachedSettingsWindow !== window)
precondition(delegate.model.fontSize == 18)
precondition(defaults.dictionary(forKey: "characterBindings")?["codex"] as? String == CharacterChoice.orangeHoodie.rawValue)
delegate.detachedSettingsWindow?.close()
// A mouse-down starts a native drag even when released without movement.
// Reproduce a sleeping independent blue character beside the hoodie character.
let model = delegate.model!
model.companionEnabled = true
model.bindCompanion(.deepseek)
model.setTracking(.codex, enabled: true)
model.bind(.orangeHoodie, to: .codex)
model.showSleepDemo()
model.demoMode = false
model.enabled = true
settle()
let storedOverlays = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("overlays") == true }!.value
let overlays = (storedOverlays as? ProjectOverlays)
    ?? (Mirror(reflecting: storedOverlays).children.first!.value as! ProjectOverlays)
let sleeper = overlays.character(for: .companion)!
precondition(sleeper.subtitle.sleepSample != nil, "Controlled sleep must be active before clicking")
overlays.onCharacterDragStarted?(CaptionMascot.codex.rawValue)
precondition(sleeper.subtitle.sleepSample != nil, "Clicking another character must preserve the sleeping character")
overlays.onCharacterDragEnded?(CaptionMascot.codex.rawValue, false)
settle()
precondition(sleeper.subtitle.sleepSample != nil, "Unmoved release must also preserve the other character's sleep")
sleeper.panel.beginManualDrag()
precondition(sleeper.subtitle.sleepSample == nil, "Clicking the sleeping character itself must still interrupt it")
sleeper.panel.finishManualDragIfReleased(buttonDown: false)
model.stopPreview()
print("PASS character isolation: other-source registered down/release callbacks preserve sleep; own native panel down interrupts")
print("PASS native settings: singleton window, transparent titlebar, model persistence, existing role bindings/names, close/reopen, actual 340pt status popover")

// Exercise the actual callback shared by menu and preferences, including an active flow.
model.companionEnabled = true; model.companionCharacter = .codex
let originalTracked = model.trackedHarnesses
delegate.replayOnboarding()
precondition(delegate.onboarding!.step == .greeting && model.companionChoice == .deepseek)
precondition(model.onboardingCharacter?.panel.isVisible == true)
delegate.onboarding!.move(.permissions); delegate.onboarding!.showPermissions()
model.companionCharacter = .orangeHoodie
delegate.replayOnboarding()
precondition(delegate.onboarding!.step == .greeting && model.companionChoice == .deepseek)
precondition(model.trackedHarnesses == originalTracked)
precondition(OnboardingProgress.permissionReplay(defaults) == nil)
precondition(!app.windows.contains { $0.title == "让大肥鱼认识桌面" && $0.isVisible })
precondition(app.windows.filter { $0.title == "蓝色大肥鱼 · 第一次见面" && $0.isVisible }.count == 1)
delegate.onboarding!.move(.complete)
print("PASS actual onboarding entry: switch role and restart unfinished permissions without duplicate windows")
