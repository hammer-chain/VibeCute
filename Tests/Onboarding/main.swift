import AppKit
import CaptionCore
@testable import CodexCaptions

let app = NSApplication.shared
app.setActivationPolicy(.accessory); app.finishLaunching()
let suite = CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--preferences-suite")! + 1]
let defaults = UserDefaults(suiteName: suite)!
if let index = CommandLine.arguments.firstIndex(of: "--restart-stage") {
    let stage = CommandLine.arguments[index + 1]
    let first = CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--first-permission")! + 1]
    let replay = CommandLine.arguments.contains("--replay-check")
    if stage == "begin" {
        defaults.removePersistentDomain(forName: suite)
        if replay {
            defaults.set(1, forKey: "onboardingVersion"); defaults.set("complete", forKey: "onboardingStep")
            defaults.set(true, forKey: "companionEnabled"); defaults.set("codex", forKey: "companionCharacter")
            defaults.set([String](), forKey: "trackedHarnesses")
            for key in ["claudeTrackingMigrated", "doubaoTrackingMigrated"] { defaults.set(true, forKey: key) }
            for key in ["audioEnabled", "autoAvoidanceEnabled", "autoWindowPeekEnabled"] { defaults.set(false, forKey: key) }
        }
    }
    let model = AppModel(); model.start()
    var requested = 0
    let permissionAction: () -> Void = {
        requested += 1
        precondition(OnboardingProgress.permissionReplay(defaults) == replay, "Checkpoint must precede the system request")
        let window = app.windows.first { $0.title == "让大肥鱼认识桌面" && $0.isVisible }!
        window.close() // macOS quit/restart can close this window before process exit.
    }
    let flow = OnboardingController(model: model, screenPermissionAction: permissionAction, audioPermissionAction: permissionAction)
    switch stage {
    case "begin":
        flow.start(replay: replay); flow.move(.permissions); flow.showPermissions()
        if first == "screen" { flow.enableScreen() } else { flow.enableAudio() }
        precondition(requested == 1 && flow.step == .permissions)
        precondition(OnboardingProgress.permissionReplay(defaults) == replay)
    case "resume":
        precondition(flow.step == .permissions)
        flow.start()
        precondition(model.onboardingCharacter?.subtitle.mascotArtwork == "deepseek")
        precondition(app.windows.contains { $0.title == "让大肥鱼认识桌面" && $0.isVisible })
        precondition(requested == 0, "Restoring the permission window must not request authorization automatically")
    case "continue":
        flow.start()
        precondition(flow.step == .permissions && app.windows.contains { $0.title == "让大肥鱼认识桌面" && $0.isVisible })
        if first == "screen" { flow.enableAudio() } else { flow.enableScreen() }
        precondition(requested == 1 && flow.step == .permissions)
        flow.showPermissions(); flow.permissionsContinue()
        precondition(flow.step == .interaction && OnboardingProgress.permissionReplay(defaults) == nil)
    case "finished":
        precondition(flow.step == (replay ? .complete : .interaction))
        flow.start()
        precondition(!app.windows.contains { $0.title == "让大肥鱼认识桌面" && $0.isVisible })
        flow.move(.complete)
        defaults.removePersistentDomain(forName: suite)
    default: preconditionFailure("Unknown restart stage")
    }
    defaults.synchronize()
    print("PASS permission process restart: first=\(first), replay=\(replay), stage=\(stage)")
    exit(0) // Abrupt exit preserves the pending checkpoint; no graceful cleanup advances it.
}
defaults.removePersistentDomain(forName: suite)
defer { defaults.removePersistentDomain(forName: suite) }

let model = AppModel()
precondition(model.companionEnabled && model.companionChoice == .deepseek)
precondition(model.trackedHarnesses.isEmpty)
precondition(!model.audioEnabled && !model.autoAvoidanceEnabled && !model.speechKeywordEnabled && !model.autoWindowPeekEnabled)
precondition(OnboardingProgress.step(defaults) == .greeting)
model.start()
let flow = OnboardingController(model: model)
flow.start()
precondition(model.onboardingActive && model.onboardingCharacter?.panel.isVisible == true)
let bubble = app.windows.first { $0.title == "蓝色大肥鱼 · 第一次见面" }!
precondition(!bubble.styleMask.contains(.titled))
let caption = bubble.contentView as! SubtitleView
precondition(caption.mode == .bubble && !caption.showsCaptionHeader && caption.captionFooterHeight > 0)
precondition(caption.frame.width >= 300 && caption.frame.height < 500)
precondition(caption.subviews.allSatisfy { caption.bounds.contains($0.frame) })
flow.move(.permissions)
flow.showPermissions(); flow.permissionsContinue()
precondition(flow.step == .interaction && flow.interactionText.contains("没关系"))
// Feed native NSEvent values through the installed overlay callback. This checks
// the real visible-character hit test and one-shot timing without OS input synthesis.
let storedOverlays = Mirror(reflecting: model).children.first { $0.label?.contains("overlays") == true }!.value
let overlays = (storedOverlays as? ProjectOverlays)
    ?? (Mirror(reflecting: storedOverlays).children.first!.value as! ProjectOverlays)
let character = model.onboardingCharacter!
let region = character.subtitle.headPatRegion
let local = NSPoint(x: region.midX, y: region.midY)
let screenPoint = character.panel.convertPoint(toScreen: character.subtitle.convert(local, to: nil))
precondition(character.subtitle.containsVisibleCharacter(at: local))
func event(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: screenPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
}
overlays.onOnboardingPointer?(event(.leftMouseDown), screenPoint)
overlays.onOnboardingPointer?(event(.leftMouseUp), screenPoint)
RunLoop.main.run(until: Date().addingTimeInterval(0.75))
precondition(flow.step == .feedback && character.subtitle.headPatActive)
flow.move(.interaction)
overlays.onOnboardingPointer?(event(.mouseMoved), screenPoint)
overlays.onOnboardingPointer?(event(.mouseMoved), NSPoint(x: -10000, y: -10000))
RunLoop.main.run(until: Date().addingTimeInterval(0.9))
precondition(flow.step == .interaction)
overlays.onOnboardingPointer?(event(.mouseMoved), screenPoint)
RunLoop.main.run(until: Date().addingTimeInterval(0.9))
precondition(flow.step == .feedback)
flow.move(.interaction); model.onOnboardingDragEnded?()
RunLoop.main.run(until: Date().addingTimeInterval(0.75))
precondition(flow.step == .feedback)
print("PASS native-event click, hover cancellation/completion and drag-release progression")
flow.move(.connection)
flow.showConnection(); flow.cancelConnection()
precondition(model.trackedHarnesses.isEmpty && model.companionEnabled)
precondition(flow.connectionMessage.contains("没关系"))
flow.move(.farewell); flow.move(.complete)
precondition(!model.onboardingActive && model.onOnboardingLayout == nil && model.onOnboardingDragEnded == nil)
precondition(OnboardingProgress.step(defaults) == .complete)
let restored = AppModel()
precondition(OnboardingController(model: restored).step == .complete)
precondition(restored.trackedHarnesses.isEmpty && restored.companionEnabled)
flow.start(replay: true); flow.move(.interaction)
precondition(OnboardingProgress.step(defaults) == .complete)
flow.move(.complete)
print("PASS fresh install, standalone whale, permission skip, connection cancellation, completion, restart and replay cleanup")

// Simulate an interrupted install and resume without overwriting user choices.
defaults.set("interaction", forKey: "onboardingStep")
let interrupted = AppModel()
precondition(OnboardingController(model: interrupted).step == .interaction)
precondition(interrupted.trackedHarnesses.isEmpty)

// Actual connection creates one whale and preserves the native frame origin.
let originalOrigin = model.onboardingCharacter!.panel.frame.origin
flow.start(replay: true); flow.move(.connection); flow.connect(.codex)
precondition(model.tracks(.codex) && !model.companionEnabled)
precondition(model.characterChoice(for: .codex) == .deepseek)
precondition(model.onboardingCharacter?.panel.frame.origin == originalOrigin)
precondition(model.onboardingCharacter?.panel.isVisible == true)
flow.move(.complete)
print("PASS interrupted progress, explicit connection, one visible whale and position transfer")
let pending = OnboardingController(model: model)
pending.start(); pending.move(.connection); pending.connect(.codex)
let pendingRestored = OnboardingController(model: model)
precondition(pendingRestored.step == .connection && !pendingRestored.connectionMessage.isEmpty)
pending.move(.complete)
print("PASS connection result survives interruption without connecting again")

defaults.removePersistentDomain(forName: suite)
defaults.set(["codex"], forKey: "trackedHarnesses")
defaults.set(["codex": "codex"], forKey: "characterBindings")
defaults.set(true, forKey: "claudeTrackingMigrated"); defaults.set(true, forKey: "doubaoTrackingMigrated")
let upgraded = AppModel()
precondition(OnboardingProgress.step(defaults) == .complete)
precondition(upgraded.trackedHarnesses == ["codex"] && upgraded.characterChoice(for: .codex) == .codex)
print("PASS upgrade preserves existing Harness and character preferences")

// Layout acceptance: lower-first, both side fallbacks and caption ceiling.
let area = NSRect(x: 0, y: 0, width: 1000, height: 800)
let size = NSSize(width: 260, height: 44)
let high = NSRect(x: 400, y: 250, width: 147, height: 226)
let below = OverlayController.hoverMetricsPlacement(character: high, size: size, area: area, captionTop: 600)
precondition(below.maxY < high.minY && abs(below.midX - high.midX) < 1)
let low = NSRect(x: 400, y: 20, width: 147, height: 226)
let side = OverlayController.hoverMetricsPlacement(character: low, size: size, area: area, captionTop: 125)
precondition(side.minX > low.maxX && side.maxY <= 125 && area.contains(side))
let edge = NSRect(x: 825, y: 20, width: 147, height: 226)
let left = OverlayController.hoverMetricsPlacement(character: edge, size: size, area: area, captionTop: 150)
precondition(left.maxX < edge.minX && left.maxY <= 150 && area.contains(left))
let moved = OverlayController.hoverMetricsPlacement(character: low.offsetBy(dx: -1300, dy: 0), size: size,
    area: area.offsetBy(dx: -1300, dy: 0), captionTop: 125)
precondition(abs(moved.minX - (side.minX - 1300)) < 1)
print("PASS metrics lower-first placement, left/right fallback, caption ceiling and negative-origin display")

let native = model.onboardingCharacter!
native.subtitle.cancelHeadPat()
let nativeArea = native.panel.screen!.visibleFrame
native.setHoverMetrics(speed: 12.3, quota: "账户余额 ¥10.00")
native.panel.setFrameOrigin(NSPoint(x: nativeArea.minX + 350, y: nativeArea.minY + 250))
native.hoverCaptionTopOffset = nil
func showNativeMetrics() {
    native.refreshSpeedHover(at: NSPoint(x: native.panel.frame.midX, y: native.panel.frame.midY), leftButtonDown: false, optionDown: false)
}
showNativeMetrics()
precondition(native.hoverMetricsWindowVisible && native.hoverMetricsFrame.maxY < native.panel.frame.minY)
native.panel.setFrameOrigin(NSPoint(x: nativeArea.minX + 350, y: nativeArea.minY + 20))
native.hoverCaptionTopOffset = -100
showNativeMetrics()
precondition(native.hoverMetricsFrame.minX > native.panel.frame.maxX)
let firstTop = native.hoverMetricsFrame.maxY
native.hoverCaptionTopOffset = -150
showNativeMetrics()
precondition(native.hoverMetricsFrame.maxY <= native.panel.frame.maxY - 150)
precondition(native.hoverMetricsFrame.maxY < firstTop)
let cached = native.hoverMetricsDiagnostics["layoutCount"] as! Int
showNativeMetrics()
precondition(native.hoverMetricsDiagnostics["layoutCount"] as! Int == cached)
native.panel.orderOut(nil)
print("PASS actual metrics window placement, moving-caption ceiling and unchanged-layout cache reuse")

let scrollPanel = SubtitlePanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
var fontChanges: [Double] = []
scrollPanel.onScrollFont = { fontChanges.append($0) }
scrollPanel.handleFontScroll(delta: 3, precise: false, inverted: false, momentum: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(fontChanges == [1])
scrollPanel.handleFontScroll(delta: 3, precise: false, inverted: true, momentum: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(fontChanges == [1, -1])
for _ in 0..<10 { scrollPanel.handleFontScroll(delta: 2, precise: true, inverted: false, momentum: false) }
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(fontChanges == [1, -1, 1])
scrollPanel.handleFontScroll(delta: 20, precise: true, inverted: false, momentum: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(fontChanges.count == 3)
print("PASS caption wheel direction, precise scroll batching and momentum exclusion")

// Replay reuses a current source and switches its artwork without enabling readers.
for choice in [CharacterChoice.codex, .orangeHoodie] {
    model.companionEnabled = false
    model.bind(choice, to: .codex)
    let tracked = model.trackedHarnesses
    let replay = OnboardingController(model: model)
    replay.start(replay: true)
    precondition(model.characterChoice(for: .codex) == .deepseek && !model.companionEnabled)
    precondition(model.trackedHarnesses == tracked)
    precondition(model.onboardingCharacter?.panel.isVisible == true && model.onboardingCharacter?.subtitle.mascotArtwork == "deepseek")
    precondition(app.windows.contains { $0.title == "蓝色大肥鱼 · 第一次见面" && $0.isVisible })
    replay.move(.complete)
    model.companionEnabled = true; model.companionCharacter = choice
    let companionReplay = OnboardingController(model: model)
    companionReplay.start(replay: true)
    precondition(model.companionChoice == .deepseek && model.trackedHarnesses == tracked)
    precondition(model.onboardingCharacter?.panel.isVisible == true && model.onboardingCharacter?.subtitle.mascotArtwork == "deepseek")
    companionReplay.move(.complete)
}
model.companionEnabled = false
for source in SessionSource.allCases { model.setTracking(source, enabled: false) }
let emptyReplay = OnboardingController(model: model); emptyReplay.start(replay: true)
precondition(model.companionEnabled && model.companionChoice == .deepseek && model.trackedHarnesses.isEmpty)
emptyReplay.move(.complete)
print("PASS replay switches dragon/hoodie Harness and companion roles to blue whale; empty configuration creates only a companion")

emptyReplay.start(replay: true); emptyReplay.move(.permissions); emptyReplay.showPermissions()
model.companionCharacter = .orangeHoodie
emptyReplay.start(replay: true)
precondition(emptyReplay.step == .greeting && model.companionChoice == .deepseek)
precondition(OnboardingProgress.permissionReplay(defaults) == nil)
precondition(!app.windows.contains { $0.title == "让大肥鱼认识桌面" && $0.isVisible })
precondition(app.windows.filter { $0.title == "蓝色大肥鱼 · 第一次见面" && $0.isVisible }.count == 1)
emptyReplay.move(.complete)
print("PASS replay restarts an unfinished permission flow with exactly one greeting bubble")

// Header discovery must not confuse an existing directory or arbitrary JSON with a readable session.
let discoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("vibecute-discovery-"+UUID().uuidString)
try! FileManager.default.createDirectory(at: discoveryRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: discoveryRoot) }
let codexRoot = discoveryRoot.appendingPathComponent("codex")
let claudeRoot = discoveryRoot.appendingPathComponent("claude")
let deepseekRoot = discoveryRoot.appendingPathComponent("deepseek")
for url in [codexRoot,claudeRoot,deepseekRoot] { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
let roots: [SessionSource: URL] = [.codex:codexRoot,.claude:claudeRoot,.deepseek:deepseekRoot]
precondition(OnboardingHarnessDiscovery.discover(roots: roots).available.isEmpty)
func writeHeader(_ object: [String: Any], at url: URL) {
    var data = try! JSONSerialization.data(withJSONObject: object); data.append(10); try! data.write(to: url)
}
writeHeader(["type":"session_meta","payload":["id":""]], at:codexRoot.appendingPathComponent("rollout-invalid.jsonl"))
writeHeader(["type":"other","sessionId":"not-a-session","cwd":"/fixture"], at:claudeRoot.appendingPathComponent("bad.jsonl"))
precondition(OnboardingHarnessDiscovery.discover(roots: roots).available.isEmpty)
writeHeader(["type":"user","sessionId":"claude-fixture","cwd":"/fixture"], at:claudeRoot.appendingPathComponent("valid.jsonl"))
precondition(OnboardingHarnessDiscovery.discover(roots: roots).available == [.claude])
writeHeader(["type":"session_meta","payload":["id":"codex-fixture","cwd":"/fixture"]], at:codexRoot.appendingPathComponent("rollout-valid.jsonl"))
writeHeader(["type":"session","version":4,"delegationDepth":0,"id":"deepseek-fixture","cwd":"/fixture"], at:deepseekRoot.appendingPathComponent("session.v4.jsonl"))
precondition(OnboardingHarnessDiscovery.discover(roots: roots).available == [.codex,.claude,.deepseek])
let compressor = Process(); compressor.executableURL = URL(fileURLWithPath:"/opt/homebrew/bin/zstd")
compressor.arguments = ["-q","-f",deepseekRoot.appendingPathComponent("session.v4.jsonl").path,"-o",deepseekRoot.appendingPathComponent("session.v4.jsonl.zstd").path]
try! compressor.run(); compressor.waitUntilExit(); precondition(compressor.terminationStatus == 0)
try! FileManager.default.removeItem(at:deepseekRoot.appendingPathComponent("session.v4.jsonl"))
precondition(OnboardingHarnessDiscovery.discover(roots:[.deepseek:deepseekRoot]).available == [.deepseek])
let bulk = discoveryRoot.appendingPathComponent("bulk"); try! FileManager.default.createDirectory(at:bulk,withIntermediateDirectories:true)
for index in 0..<100 { try! Data().write(to:bulk.appendingPathComponent("unrelated-\(index).txt")) }
var limits = OnboardingHarnessDiscovery.Limits(); limits.entries = 8
let bounded = OnboardingHarnessDiscovery.discover(roots:[.codex:bulk],limits:limits)
precondition(bounded.entries == 8 && bounded.files == 0 && bounded.limited)
precondition(OnboardingHarnessDiscovery.discover(roots:roots,cancelled:{true}).entries == 0)
// The UI receives the asynchronous result without enabling any new source.
model.claudePath = claudeRoot.path; model.harnessPath = discoveryRoot.appendingPathComponent("missing").path
let discoveryFlow = OnboardingController(model:model)
discoveryFlow.start(replay:true); discoveryFlow.move(.connection)
let beforeTracking = model.trackedHarnesses
let started = ProcessInfo.processInfo.systemUptime
discoveryFlow.showConnection()
while discoveryFlow.checkingConnections && ProcessInfo.processInfo.systemUptime-started < 5 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
precondition(!discoveryFlow.checkingConnections && discoveryFlow.availableConnectionSources == [.claude])
precondition(model.trackedHarnesses == beforeTracking)
discoveryFlow.refreshConnections(); discoveryFlow.cancelConnection()
RunLoop.main.run(until:Date().addingTimeInterval(0.1))
precondition(!discoveryFlow.checkingConnections && model.trackedHarnesses == beforeTracking)
discoveryFlow.move(.complete)
print("PASS onboarding discovery: absent/invalid hidden, valid and compressed headers, entry budget, cancellation, asynchronous Claude-only list without enabling tracking")
