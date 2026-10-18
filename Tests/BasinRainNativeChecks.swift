import AppKit
import QuartzCore
import SwiftUI
@testable import CodexCaptions

@main struct BasinRainNativeChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let display = NSScreen.screens.first else { fatalError("Graphical session required") }
        // Empty thunder frame must be transparent until a bolt appears.
        // This catches a cloud overlay without depending on private draw methods.
        let stormView = RainView(frame:NSRect(x:0,y:0,width:320,height:260),region:RainRect(x:0,y:0,width:320,height:260))
        func hasVisibleWeather() -> Bool {
            let image = stormView.bitmapImageRepForCachingDisplay(in:stormView.bounds)!
            stormView.cacheDisplay(in:stormView.bounds,to:image)
            for y in stride(from:0,to:image.pixelsHigh,by:4) {
                for x in stride(from:0,to:image.pixelsWide,by:4) {
                    if (image.colorAt(x:x,y:y)?.alphaComponent ?? 0) > 0 { return true }
                }
            }
            return false
        }
        stormView.step(dt:0,field:RoofField(),enabled:true,settings:RainSettings(style:.thunder),weatherTime:0)
        precondition(!hasVisibleWeather(),"Thunder preview still paints clouds")
        let bolt = WeatherStormTiming.event(at:0).lightningAt
        stormView.step(dt:0,field:RoofField(),enabled:true,settings:RainSettings(style:.thunder),weatherTime:bolt+0.1)
        precondition(hasVisibleWeather(),"Cloud removal also removed lightning")
        let roof = RainBasinSurface(source:"deepseek",points:[RainPoint(x:80,y:170),RainPoint(x:160,y:140),RainPoint(x:240,y:170)],scale:1)!
        let vertical = roof.firstImpact(from:RainPoint(x:160,y:0),to:RainPoint(x:160,y:250))!
        precondition(abs(vertical.point.y-140) < 0.01 && vertical.normal.y < 0)
        precondition(roof.firstImpact(from:RainPoint(x:20,y:0),to:RainPoint(x:20,y:250)) == nil)
        precondition(roof.firstImpact(from:RainPoint(x:160,y:240),to:RainPoint(x:160,y:250)) == nil)
        for dx in [-90.0,90] {
            precondition(roof.firstImpact(from:RainPoint(x:160-dx,y:0),to:RainPoint(x:160+dx,y:250)) != nil)
        }
        // Actual rain solver emits steel contacts, while an upstream window
        // intercepts those same drops. Statistical lower bound has a wide margin.
        var wetHits = 0
        for covered in [false,true] {
            let view = RainView(frame:NSRect(x:0,y:0,width:320,height:300),region:RainRect(x:0,y:0,width:320,height:300))
            let field = RoofField(windows:covered ? [RainRect(x:0,y:50,width:320,height:50)] : [])
            for _ in 0..<300 {
                view.step(dt:1/30,field:field,enabled:true,settings:RainSettings(quantity:3),basins:[roof])
                precondition(view.basinImpacts.count <= 12)
                precondition(view.basinImpacts.allSatisfy { !field.isSheltered($0.hit.point,wind:0) })
            }
            if covered { precondition(view.basinHits == 0,"Rain splashed a covered basin") }
            else { wetHits = view.basinHits; precondition(wetHits > 30,"Exposed steel never received real raindrops") }
        }
        let actor = OverlayController()
        actor.update(text:"",context:"",title:"",live:false,mascot:.deepseek,font:14,opacity:1,bottom:24,
                     screenIndex:0,movable:true,visible:true,mode:.character)
        actor.panel.setFrameOrigin(CGPoint(x:display.visibleFrame.minX+30,y:display.visibleFrame.minY+30))
        var registered = 0
        for frame in 0..<32 {
            for scale in [0.7,1,1.5] {
                for mirrored in [false,true] {
                    let result = DeepSeekRainArtwork.shared.basinSurface(pose:RainShelterPose(frame:frame,mirrored:mirrored),
                        in:actor.subtitle.bounds,origin:CGPoint(x:-600,y:-200),displayTop:900,scale:scale,source:"deepseek")
                    precondition((result != nil) == (4...18).contains(frame))
                    if let result { precondition(result.points.count == 9); registered += 1 }
                }
            }
        }
        actor.subtitle.setRainShelterPose(RainShelterPose(frame:8,mirrored:false))
        let surface = DeepSeekRainArtwork.shared.basinSurface(pose:actor.subtitle.rainShelterPose!,in:actor.subtitle.bounds,
            origin:actor.panel.frame.origin,displayTop:display.frame.maxY,scale:1,source:"deepseek")!
        let now = CACurrentMediaTime()
        for point in surface.points {
            actor.subtitle.receiveBasinRain(RainBasinImpact(source:"deepseek",hit:RainHit(time:0,point:point,normal:RainPoint(x:0,y:-1)),scale:1),at:now)
        }
        actor.subtitle.advanceBasinRain(at:now+0.08)
        precondition(actor.subtitle.basinRainSplash.count == 36)
        try FileManager.default.createDirectory(atPath:"output/basin-rain",withIntermediateDirectories:true)
        let bitmap = actor.subtitle.bitmapImageRepForCachingDisplay(in:actor.subtitle.bounds)!
        if let bytes = bitmap.bitmapData { memset(bytes,0,bitmap.bytesPerRow*bitmap.pixelsHigh) }
        actor.subtitle.cacheDisplay(in:actor.subtitle.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"output/basin-rain/native-splash.png"))
        for _ in 0..<100 { actor.subtitle.receiveBasinRain(RainBasinImpact(source:"deepseek",hit:vertical,scale:1),at:now+0.1) }
        precondition(actor.subtitle.basinRainSplash.count == 64,"Unbounded splash growth")
        actor.subtitle.advanceBasinRain(at:now+0.5)
        precondition(actor.subtitle.basinRainSplash.count == 0)
        actor.subtitle.receiveBasinRain(RainBasinImpact(source:"deepseek",hit:vertical,scale:1),at:now+0.6)
        actor.subtitle.setRainShelterPose(nil)
        precondition(actor.subtitle.basinRainSplash.count == 0,"Thinking retained basin splashes")
        actor.subtitle.setRainShelterPose(RainShelterPose(frame:8,mirrored:false))
        actor.subtitle.receiveBasinRain(RainBasinImpact(source:"deepseek",hit:vertical,scale:1),at:now+0.7)
        actor.subtitle.setMascot(.codex,animating:false)
        precondition(actor.subtitle.basinRainSplash.count == 0,"Character swap retained basin splashes")

        // Real controller and AVAudioPlayer, controlled contact input. Volume 0
        // exercises decoding/playback without producing sound on the test device.
        let controller = DesktopRainController()
        controller.configure(active:true,settings:RainSettings(),sound:true,volume:0,basinVolume:0)
        var delivered = 0
        controller.onBasinImpact = { _,_ in delivered += 1 }
        let impact = RainBasinImpact(source:"deepseek",hit:vertical,scale:1)
        controller.processBasinImpact(impact,at:now)
        precondition(controller.diagnostics["basinSoundPlaying"] as? Bool == true)
        let decodes = controller.audioDecodes
        for i in 1...100 { controller.processBasinImpact(impact,at:now+Double(i)*0.001) }
        precondition(controller.basinSoundPlays == 1,"Per-drop audio bypassed 8Hz throttle")
        precondition(controller.diagnostics["basinVoices"] as? Int == 2)
        precondition(controller.audioDecodes == decodes,"Hits decoded repeated audio")
        RunLoop.main.run(until:Date().addingTimeInterval(0.3)) // Finish the silent one-shot before changing gain.
        controller.configure(active:true,settings:RainSettings(),sound:true,volume:0,basinVolume:0.8)
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        let gains = controller.diagnostics["basinVoiceVolumes"] as! [Double]
        precondition(gains.count == 2 && gains.allSatisfy { abs($0-0.8)<0.01 },"Steel gain still follows rain volume")
        precondition(controller.audioDecodes == decodes,"Steel volume slider recreated the audio pool")
        controller.configure(active:true,settings:RainSettings(),sound:false,volume:0,basinVolume:0)
        precondition(controller.diagnostics["basinSoundPlaying"] as? Bool == false)
        controller.configure(active:true,settings:RainSettings(style:.snow),sound:true,volume:0,basinVolume:0)
        controller.processBasinImpact(impact,at:now+2)
        precondition(controller.basinSoundPlays == 1,"Snow played steel rain sounds")
        controller.stop()
        let before = delivered
        controller.processBasinImpact(impact,at:now+3)
        precondition(delivered == before && controller.diagnostics["basinVoices"] as? Int == 0)
        actor.hide()
        let suiteIndex = CommandLine.arguments.firstIndex(of:"--preferences-suite")!
        let suite = CommandLine.arguments[suiteIndex+1], defaults = UserDefaults(suiteName:suite)!
        defaults.removePersistentDomain(forName:suite)
        defer { defaults.removePersistentDomain(forName:suite) }
        let settingsModel = AppModel()
        precondition(settingsModel.desktopRainBasinVolume == 0.6,"New steel volume default is not louder")
        settingsModel.desktopRainBasinVolume = 0.78
        precondition(abs(defaults.double(forKey:"desktopRainBasinVolume")-0.78)<0.001)
        let reloaded = AppModel()
        precondition(abs(reloaded.desktopRainBasinVolume-0.78)<0.001,"Steel volume did not survive preferences reload")
        // Render this program's real SwiftUI menu, without capturing the desktop.
        settingsModel.taskSoundsEnabled = true; settingsModel.taskSoundVolume = 1.5
        settingsModel.desktopRainSound = true; settingsModel.desktopRainVolume = 0.35
        let menu = NSHostingController(rootView:MenuPanelView(model:settingsModel,onPreferences:{},onOnboarding:{}))
        let menuWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:340,height:720),styleMask:[.borderless],backing:.buffered,defer:false)
        menuWindow.contentViewController = menu; menuWindow.isReleasedWhenClosed = false
        menuWindow.orderFrontRegardless()
        RunLoop.main.run(until:Date().addingTimeInterval(0.25))
        menu.view.layoutSubtreeIfNeeded()
        let menuBitmap = menu.view.bitmapImageRepForCachingDisplay(in:menu.view.bounds)!
        menu.view.cacheDisplay(in:menu.view.bounds,to:menuBitmap)
        try FileManager.default.createDirectory(atPath:"output/basin-volume",withIntermediateDirectories:true)
        try menuBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"output/basin-volume/native-menu.png"))
        menuWindow.orderOut(nil)
        let report: [String:Any] = ["actualSolverWetHits":wetHits,"coveredHits":0,"registeredPoseScaleFacingCases":registered,
            "particleLimit":64,"poolVoices":2,"audioPlaysFor101ContactsIn100ms":controller.basinSoundPlays,
            "decodeCountStableAcross100Contacts":true,"audioTestVolume":0,
            "nativeImage":"controlled impacts on actual native character view; not a desktop screenshot"]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:"output/basin-rain/native-checks.json"))
        print("Basin rain checks passed: real solver wet/covered, registered poses, bounded native splash, steel audio throttle/mute/snow/stop")
    }
}
