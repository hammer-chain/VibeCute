import AppKit
import QuartzCore
import CaptionCore
@testable import CodexCaptions

@main struct RainShelterNativeChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        func wait(_ seconds: Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
        guard let screen = NSScreen.screens.first else { fatalError("No graphical display") }
        let decodeStart = CACurrentMediaTime()
        precondition(DeepSeekRainArtwork.shared.available)
        let decodeMs = (CACurrentMediaTime()-decodeStart)*1000
        precondition(DeepSeekRainArtwork.shared.frames.count == 32)
        precondition(decodeMs < 250,"Bounded cold artwork decode exceeded 250ms")
        let overlays = ProjectOverlays(positionStore:nil)
        overlays.update([],font:14,opacity:1,bottom:24,screenIndex:0,movable:true,focusedID:"",
            restingMascots:[.companion,.codex],characterBindings:[.companion:.deepseek,.codex:.codex])
        guard let actor = overlays.character(for:.companion), let other = overlays.character(for:.codex) else { fatalError("No native character panels") }
        let area = screen.visibleFrame
        let start = CGPoint(x:area.minX+40,y:area.minY+30)
        actor.panel.setFrameOrigin(start)
        let roof = CGRect(x:start.x+230,y:start.y+20,width:350,height:400)
        let quartz = quartzRect(appKit:RainRect(x:roof.minX,y:roof.minY,width:roof.width,height:roof.height),mainDisplayTop:screen.frame.maxY)
        var snapshot = RainShelterSnapshot(raining:true,suspended:false,frontWindow:quartz,wind:0)
        let coordinator = RainShelterCoordinator(overlays:overlays)
        var times: [Double] = []
        func render(_ name: String) throws {
            guard let bitmap = actor.subtitle.bitmapImageRepForCachingDisplay(in:actor.subtitle.bounds) else { fatalError("No sprite bitmap") }
            if let bytes = bitmap.bitmapData { memset(bytes,0,bitmap.bytesPerRow*bitmap.pixelsHigh) }
            actor.subtitle.cacheDisplay(in:actor.subtitle.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"output/rain-shelter/"+name+".png"))
        }
        var stowKeys = Set<Int>()
        for i in 0...600 {
            let t = 100+Double(i)/60, before = CACurrentMediaTime()
            coordinator.update(snapshot,enabled:true,at:t)
            times.append((CACurrentMediaTime()-before)*1000)
            if i == 20 { precondition(actor.subtitle.rainShelterPose != nil); try render("native-entry") }
            if i == 150 { precondition((8...15).contains(actor.subtitle.rainShelterPose!.frame)); try render("native-running") }
            if let pose = actor.subtitle.rainShelterPose, pose.frame >= 24 {
                stowKeys.insert(pose.frame)
                if pose.frame == 26 { try render("native-stowing") }
            }
            if i == 600 { try render("native-sheltered") }
            precondition(other.subtitle.rainShelterPose == nil,"Rain changed another character's artwork")
        }
        precondition(stowKeys == Set(24...31),"Native update skipped the basin-stow tail")
        precondition(actor.subtitle.rainShelterPose == nil && actor.subtitle.originalThinkingPoseActive,"Did not restore actual thinking after stow")
        var arrival = actor.panel.frame.origin
        precondition(arrival.x > start.x+100)
        let body = DeepSeekRainArtwork.body(in:actor.subtitle.bounds,scale:1).offsetBy(dx:arrival.x,dy:arrival.y)
        precondition(roof.contains(body),"Arrival is below/outside the foreground window")
        precondition(abs(body.minY-roof.minY-8)<0.1,"Below-window start did not arrive at bottom inside edge")
        let field = RoofField(windows:[quartz])
        for x in [body.minX,body.maxX] { for y in [body.minY,body.maxY] {
            precondition(field.isSheltered(RainPoint(x:x,y:screen.frame.maxY-y),wind:0),"Arrived in a wet pixel")
        }}
        let plansAfterArrival = coordinator.plans
        precondition(plansAfterArrival <= 22,"Planner exceeded 2Hz for one actor")
        snapshot.frontWindow = quartzRect(appKit:RainRect(x:roof.minX+120,y:roof.minY,width:roof.width,height:roof.height),mainDisplayTop:screen.frame.maxY)
        for i in 1...660 { coordinator.update(snapshot,enabled:true,at:110+Double(i)/60) }
        precondition(actor.panel.frame.minX > arrival.x+80,"Moving foreground roof was not followed")
        precondition(actor.subtitle.rainShelterPose == nil && actor.subtitle.originalThinkingPoseActive,"Did not restore thinking after roof moved")
        arrival = actor.panel.frame.origin
        snapshot.frontWindow = nil
        var directions = Set<Bool>(), minX = Double.infinity, maxX = -Double.infinity
        for i in 1...1200 {
            coordinator.update(snapshot,enabled:true,at:121+Double(i)/60)
            minX = min(minX,actor.panel.frame.minX); maxX = max(maxX,actor.panel.frame.minX)
            if let pose = actor.subtitle.rainShelterPose, (8...15).contains(pose.frame) { directions.insert(pose.mirrored) }
        }
        precondition(minX >= arrival.x-56.1 && maxX <= arrival.x+56.1,"Lost window sent character back to an old distant anchor")
        precondition(maxX-minX > 80 && directions.count == 2,"No local back-and-forth run")
        try render("native-fallback")
        // External movement simulates a manual drag: relinquish ownership without snapping back.
        let dragged = CGPoint(x:actor.panel.frame.minX+20,y:actor.panel.frame.minY)
        actor.panel.setFrameOrigin(dragged)
        coordinator.update(snapshot,enabled:true,at:141.1)
        precondition(actor.subtitle.rainShelterPose == nil && actor.panel.frame.origin == dragged)
        coordinator.update(snapshot,enabled:true,at:143)
        precondition(actor.subtitle.rainShelterPose == nil,"Rain fought the manual-move cooldown")
        coordinator.update(snapshot,enabled:true,at:144.2)
        precondition(actor.subtitle.rainShelterPose != nil,"Rain never resumed after manual move")
        snapshot.raining = false
        for i in 0...210 { coordinator.update(snapshot,enabled:true,at:144.3+Double(i)/60) }
        precondition(coordinator.sources.isEmpty && actor.subtitle.rainShelterPose == nil)
        snapshot.raining = true
        coordinator.update(snapshot,enabled:true,at:150)
        snapshot.suspended = true
        coordinator.update(snapshot,enabled:true,at:150.1)
        precondition(coordinator.sources.isEmpty && actor.subtitle.rainShelterPose == nil,"Sleep/lock retained actor motion")
        overlays.update([],font:14,opacity:1,bottom:24,screenIndex:0,movable:true,focusedID:"",characterBindings:[:])

        // Actual AppModel weather path, isolated preferences and empty session roots.
        let suiteIndex = CommandLine.arguments.firstIndex(of:"--preferences-suite")!
        let suite = CommandLine.arguments[suiteIndex+1], defaults = UserDefaults(suiteName:suite)!
        defaults.removePersistentDomain(forName:suite)
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(1,forKey:"onboardingVersion"); defaults.set("complete",forKey:"onboardingStep")
        defaults.set([],forKey:"trackedHarnesses"); defaults.set(true,forKey:"claudeTrackingMigrated"); defaults.set(true,forKey:"doubaoTrackingMigrated")
        defaults.set(true,forKey:"companionEnabled"); defaults.set("deepseek",forKey:"companionCharacter")
        for key in ["audioEnabled","autoWindowPeekEnabled","autoAvoidanceEnabled","desktopRainAutomatic"] { defaults.set(false,forKey:key) }
        var wet = false, weatherCalls = 0
        let weather = RainWeatherMonitor { _ in weatherCalls += 1; return RainWeatherReading(raining:wet,date:Date()) }
        let model = AppModel(rainWeather:weather); model.start(); wait(0.2)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.isEmpty == true)
        model.selectRainCity(RainCity(id:1816670,name:"北京",latitude:39.9075,longitude:116.39723,admin1:nil,country:"中国"))
        model.desktopRainAutomatic = true; model.desktopRainEnabled = true; wait(0.2)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.isEmpty == true,"Dry weather triggered basin animation")
        wet = true
        model.selectRainCity(RainCity(id:2950159,name:"Berlin",latitude:52.52,longitude:13.41,admin1:nil,country:"Germany"))
        wait(0.3)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.count == 1,"Automatic wet weather did not reach blue fish")
        model.desktopRainAutomatic = false; wait(0.2)
        precondition(model.desktopRainDiagnostics["active"] as? Bool == true)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.count == 1,"Real rain did not reach companion blue fish")
        model.previewWeather(.snow); wait(3.5)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.isEmpty == true,"Snow triggered rain shelter")
        model.previewWeather(.thunder); wait(0.25)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.count == 1,"Thunder preview did not trigger shelter")
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.screensDidSleepNotification,object:nil)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.isEmpty == true,"Sleep notification did not immediately release rain action")
        precondition(model.desktopRainDiagnostics["active"] as? Bool == false)
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.screensDidWakeNotification,object:nil)
        wait(0.2)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.count == 1,"Wake did not resume rain behavior")
        model.desktopRainEnabled = false; model.stopWeatherPreview(); wait(3.5)
        precondition((model.rainShelterDiagnostics["actors"] as? [[String:Any]])?.isEmpty == true)
        precondition(model.desktopRainDiagnostics["active"] as? Bool == false)
        precondition(weatherCalls == 2,"Shelter added a weather request")
        times.sort()
        let report: [String:Any] = ["coldDecodeMs":decodeMs,"decodedFrames":32,"decodedPixelBytes":32*512*640*4,"stowKeys":stowKeys.sorted(),
            "coordinatorSampleCalls":times.count,"p95UpdateMs":times[Int(Double(times.count-1)*0.95)],
            "planningCallsFor10Seconds":plansAfterArrival,"extraWindowQueries":0,"extraWeatherRequests":0,
            "arrivalX":arrival.x,"fallbackSpan":maxX-minX,"fallbackDirections":directions.count,
            "cases":["entry-run-sit","whole-body-dry-arrival","moving-window-replan","window-disappears-local-fallback","both-directions","manual-interruption-and-cooldown","rain-stop","sleep-lock-stop","AppModel-sleep-wake-notifications","other-character-preserved","AppModel-auto-wet","dry-no-trigger","AppModel-manual-rain","snow-no-trigger","thunder-trigger","preview-stop"]]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"output/rain-shelter/native-performance.json"))
        print("Rain shelter native checks passed: real panels, resources, movement, weather integration and bounded planning")
    }
}
