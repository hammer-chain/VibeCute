import AppKit
import QuartzCore
@testable import CodexCaptions

@main struct DesktopRainChecks {
    static func main() throws {
        _ = NSApplication.shared
        func wait(_ duration: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        let city = RainCity(id: 1816670, name: "北京", latitude: 39.9075, longitude: 116.39723, admin1: "北京市", country: "中国")
        let other = RainCity(id: 2950159, name: "Berlin", latitude: 52.52, longitude: 13.41, admin1: nil, country: "Germany")
        let now = Date()
        func reading(_ code: Int, rain: Double = 0, showers: Double = 0, age: Double = 0) throws -> RainWeatherReading {
            let data = try JSONSerialization.data(withJSONObject: ["current": ["time": now.addingTimeInterval(-age).timeIntervalSince1970,
                "weather_code": Double(code), "rain": rain, "showers": showers]])
            return try RainWeatherClient.decode(data, now: now)
        }
        for code in [51,53,55,56,57,61,63,65,66,67,80,81,82,95,96,97,99] { let value = try reading(code); precondition(value.raining) }
        for code in [0,1,2,3,45,48,71,73,75,77,85,86] { let value = try reading(code); precondition(!value.raining) }
        for code in 0...3 {
            let fair = try reading(code,rain:0.1,showers:0.1)
            precondition(!fair.raining && !fair.thunderstorm,"Fair weather must do nothing even with contradictory amounts")
        }
        for code in [95,96,97,99] { let storm = try reading(code); precondition(storm.thunderstorm) }
        let normalRain = try reading(61); precondition(!normalRain.thunderstorm)
        for (code, expected) in [(61,RainIntensity.light),(63,.moderate),(65,.heavy),(80,.light),(81,.moderate),(82,.heavy),(95,.moderate),(97,.heavy)] {
            let decodedReading = try reading(code)
            precondition(decodedReading.intensity == expected,"Current weather lost rain intensity")
        }
        for (preview,ceiling) in [(DesktopWeatherPreview.drizzle,0.35),(.rain,0.65),(.heavyRain,1.0),(.snow,0.0)] {
            let settings = preview.settings
            precondition(abs(settings.rainOutput(userVolume:0.5)-ceiling*0.5)<0.0001)
            precondition(settings.rainOutput(userVolume:0) == 0 && settings.rainOutput(userVolume:1) == ceiling)
            precondition(settings.rainOutput(userVolume:2) == ceiling && settings.rainOutput(userVolume: .nan) == 0)
            // Mapping must remain linear through the full slider, with no flat
            // upper region caused by clamping instead of scaling.
            precondition(settings.rainOutput(userVolume:0.9) < settings.rainOutput(userVolume:1) || ceiling == 0)
        }
        var intervals = Set<Int>(), gains = Set<Int>(), delays = Set<Int>(), shapes = Set<String>()
        for seed: UInt64 in [0,42,.max] {
            var previousBolt: Double?
            var previousSound: Double?
            for cycle in 0..<200 {
                let event = WeatherStormTiming.event(at:Double(cycle)*WeatherStormTiming.period,seed:seed)
                precondition(event.cycle == cycle)
                precondition(event.lightningAt >= Double(cycle)*WeatherStormTiming.period+1 && event.lightningAt < Double(cycle)*WeatherStormTiming.period+5)
                precondition((0.45...1.5).contains(event.soundAt-event.lightningAt))
                precondition((0.65...1).contains(event.gain))
                precondition(WeatherStormTiming.showsLightning(at:event.lightningAt+0.1,seed:seed))
                precondition(!WeatherStormTiming.showsLightning(at:event.lightningAt-0.01,seed:seed))
                precondition(WeatherStormTiming.soundCycle(at:event.soundAt-0.01,seed:seed) == nil)
                precondition(WeatherStormTiming.soundCycle(at:event.soundAt+0.01,seed:seed) == cycle)
                if let previousBolt { intervals.insert(Int((event.lightningAt-previousBolt)*1000)) }
                if let previousBolt {
                    precondition((20...28).contains(event.lightningAt-previousBolt),"Storm frequency no longer meets the longer interval")
                }
                if let previousSound {
                    precondition((18.95...29.05).contains(event.soundAt-previousSound),"Thunder interval out of bounds")
                }
                previousSound = event.soundAt
                previousBolt = event.lightningAt
                gains.insert(Int(event.gain*1000)); delays.insert(Int((event.soundAt-event.lightningAt)*1000))
                let shape = WeatherLightningShape(seed:seed,cycle:cycle)
                let same = WeatherLightningShape(seed:seed,cycle:cycle)
                precondition(shape.trunk.count == 19 && (3...6).contains(shape.branches.count))
                precondition(shape.branches.allSatisfy { $0.count == 6 })
                precondition(zip(shape.trunk,same.trunk).allSatisfy { $0.x == $1.x && $0.y == $1.y },"Bolt geometry changed between draws")
                shapes.insert(shape.trunk.map { "\($0.x),\($0.y)" }.joined(separator:";"))
            }
        }
        precondition(intervals.count > 100 && gains.count > 100 && delays.count > 100 && shapes.count == 600,
                     "Storm events still repeat identically")
        for (code, amount, age) in [(61,0.0,1801.0),(61,0.0,-301.0),(100,0.0,0.0),(0,-1.0,0.0)] {
            do { _ = try reading(code, rain: amount, age: age); fatalError("Invalid or stale reading accepted") } catch {}
        }
        do { _ = try RainWeatherClient.decode(Data("{}".utf8)); fatalError("Missing weather accepted") } catch {}
        var wet = false
        var calls = 0
        let monitor = RainWeatherMonitor { _ in calls += 1; return RainWeatherReading(raining: wet, date: Date()) }
        var state = false
        monitor.onChange = { state = $0; _ = $1 }
        monitor.configure(city: city); wait()
        precondition(!state && calls == 1)
        for _ in 0..<100 { monitor.refresh(); monitor.refresh(manual: true); monitor.configure(city: city) }
        wait(); precondition(calls == 1, "Repeated UI updates must not refetch weather")
        wet = true; monitor.configure(city: other); wait(); precondition(state && calls == 2)
        monitor.configure(city: nil); wait(); precondition(!state && monitor.diagnostics["polling"] as? Bool == false)
        var delayed: CheckedContinuation<RainWeatherReading, Error>?
        let late = RainWeatherMonitor { _ in try await withCheckedThrowingContinuation { delayed = $0 } }
        var lateWet = false
        late.onChange = { lateWet = $0; _ = $1 }
        late.configure(city: city); wait(); late.configure(city: nil)
        delayed?.resume(returning: RainWeatherReading(raining: true, date: Date())); wait()
        precondition(!lateWet && late.diagnostics["enabled"] as? Bool == false, "Late response re-enabled rain")
        let failed = RainWeatherMonitor { _ in throw RainWeatherError.invalidResponse }
        var failureState = true
        failed.onChange = { failureState = $0; _ = $1 }
        failed.configure(city: city); wait(); precondition(!failureState)
        failed.configure(city: nil)

        let suiteIndex = CommandLine.arguments.firstIndex(of: "--preferences-suite")!
        let suite = CommandLine.arguments[suiteIndex+1], defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "onboardingVersion"); defaults.set("complete", forKey: "onboardingStep")
        defaults.set([], forKey: "trackedHarnesses"); defaults.set(true, forKey: "claudeTrackingMigrated")
        defaults.set(true, forKey: "doubaoTrackingMigrated"); defaults.set(false, forKey: "autoAvoidanceEnabled")
        defaults.set(false, forKey: "audioEnabled"); defaults.set(false, forKey: "autoWindowPeekEnabled")
        defaults.set(0,forKey:"desktopRainBasinVolume") // Independent steel gain must also stay silent.
        var appWet = false, appThunder = false
        let appWeather = RainWeatherMonitor { _ in RainWeatherReading(raining: appWet, date: Date(), thunderstorm:appThunder,intensity:.light) }
        let model = AppModel(rainWeather: appWeather)
        model.start(); wait()
        precondition(model.desktopRainDiagnostics["active"] as? Bool == false)
        model.selectRainCity(city); model.desktopRainEnabled = true; wait()
        precondition(model.desktopRainDiagnostics["active"] as? Bool == false, "Dry city should remain idle")
        appWet = true; model.selectRainCity(other); wait()
        precondition(model.desktopRainDiagnostics["active"] as? Bool == true, "Rain weather must start actual overlay")
        precondition(model.desktopRainDiagnostics["rainSoundCeiling"] as? Double == 0.35,"Automatic light rain did not reach the audio controller")
        precondition(model.desktopRainDiagnostics["windowCount"] as? Int == NSScreen.screens.count)
        precondition(model.desktopRainDiagnostics["mouseTransparent"] as? Bool == true)
        let frameCount = model.desktopRainDiagnostics["frames"] as! Int
        model.desktopRainEnabled = false; wait(0.3)
        precondition(model.desktopRainDiagnostics["windowCount"] as? Int == 0)
        precondition(model.desktopRainDiagnostics["frames"] as! Int == frameCount)
        precondition(model.rainWeatherDiagnostics["polling"] as? Bool == false)
        precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == false)
        precondition(model.desktopRainDiagnostics["dropsPlaying"] as? Bool == false)
        model.desktopRainAutomatic = false; model.desktopRainEnabled = true; wait(0.4)
        precondition(model.desktopRainDiagnostics["active"] as? Bool == true, "Manual mode starts without weather")
        model.desktopRainVolume = 0; model.desktopRainDropsVolume = 0; model.desktopRainThunderVolume = 0; model.desktopRainSound = true; wait()
        precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == true, "Bundled rain audio must load and play")
        precondition(model.desktopRainDiagnostics["dropsPlaying"] as? Bool == true,"Independent drop track must play")
        precondition((model.desktopRainDiagnostics["rainDuration"] as? Double ?? 0) > 120)
        precondition((model.desktopRainDiagnostics["dropsDuration"] as? Double ?? 0) > 120)
        precondition(defaults.double(forKey:"desktopRainDropsVolume") == 0)
        // Exercise independent gains without exposing audible output: change and restore
        // within the same run-loop turn before the player's 200ms fade advances.
        let rainDecodes = model.desktopRainDiagnostics["audioDecodes"] as! Int
        // Switch all manual intensities without audio output or preference rewrite.
        for (quantity,cap) in [(0.4,0.35),(1.0,0.65),(2.8,1.0)] {
            model.desktopRainQuantity = quantity
            precondition(model.desktopRainDiagnostics["rainSoundCeiling"] as? Double == cap)
            precondition(model.desktopRainVolume == 0 && model.desktopRainDropsVolume == 0)
        }
        model.desktopRainQuantity = 1
        model.desktopRainDropsVolume = 0.2
        precondition(model.desktopRainDiagnostics["rainVolume"] as? Double == 0)
        precondition(model.desktopRainDiagnostics["dropsVolume"] as? Double == 0.2)
        precondition(abs((model.desktopRainDiagnostics["dropsTargetVolume"] as! Double)-0.13)<0.0001,"User drops gain bypassed the medium-rain ceiling")
        precondition(model.desktopRainDiagnostics["thunderVolume"] as? Double == 0)
        model.desktopRainDropsVolume = 0
        for _ in 0..<30 { model.desktopRainVolume = 0; model.desktopRainDropsVolume = 0; model.desktopRainThunderVolume = 0 }
        precondition(model.desktopRainDiagnostics["audioDecodes"] as? Int == rainDecodes)
        model.desktopRainAutomatic = true; appThunder = true; model.selectRainCity(city); wait()
        precondition(model.desktopRainDiagnostics["style"] as? String == "thunder", "Actual weather lost its thunderstorm code")
        precondition(model.desktopRainDiagnostics["thunderReady"] as? Bool == true)
        precondition(model.desktopRainDiagnostics["thunderVariants"] as? Int == 4,"All thunder variants must decode and prepare")
        let decoded = model.desktopRainDiagnostics["audioDecodes"] as! Int
        for i in 0..<30 { model.desktopRainSize = 0.7+Double(i)/100 }
        precondition(model.desktopRainDiagnostics["audioDecodes"] as! Int == decoded,"Slider updates repeatedly decoded audio")
        wait(0.65)
        precondition(model.desktopRainDiagnostics["thunderPlays"] as? Int == 0,"Thunder sounded before lightning")
        let due = model.desktopRainDiagnostics["thunderAt"] as! Double
        let elapsed = model.desktopRainDiagnostics["weatherElapsed"] as! Double
        wait(max(0,due-elapsed)+0.2)
        precondition(model.desktopRainDiagnostics["thunderPlaying"] as? Bool == true)
        precondition(model.desktopRainDiagnostics["thunderPlays"] as? Int == 1,"Thunder was multiplied by redraws/displays")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        wait(); precondition(model.desktopRainDiagnostics["windowCount"] as? Int == 0)
        precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == false)
        precondition(model.desktopRainDiagnostics["dropsPlaying"] as? Bool == false)
        precondition(model.desktopRainDiagnostics["thunderPlaying"] as? Bool == false)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        wait(); precondition(model.desktopRainDiagnostics["active"] as? Bool == true)
        model.desktopRainSound = false
        precondition(model.desktopRainDiagnostics["thunderReady"] as? Bool == false)
        let before = model.desktopRainDiagnostics["frames"] as! Int
        model.desktopRainSize = 2; model.desktopRainWind = -30; model.desktopRainQuantity = 3
        wait(0.3)
        precondition(model.desktopRainDiagnostics["frames"] as! Int > before)
        model.desktopRainEnabled = false
        precondition(defaults.bool(forKey: "desktopRainAutomatic") == true)
        precondition(defaults.data(forKey: "desktopRainCity") != nil)

        for preview in DesktopWeatherPreview.allCases {
            model.desktopRainSound = true // zero volume: exercise the actual decoder silently
            model.previewWeather(preview); wait(0.12)
            precondition(model.desktopRainDiagnostics["style"] as? String == preview.settings.style.rawValue)
            precondition(model.desktopRainDiagnostics["rainSoundCeiling"] as? Double == preview.settings.rainSoundCeiling)
            precondition(defaults.double(forKey:"desktopRainVolume") == 0 && defaults.double(forKey:"desktopRainDropsVolume") == 0,"Preview rewrote user rain volumes")
            precondition(model.desktopRainDiagnostics["active"] as? Bool == true)
            precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == (preview != .snow))
            precondition(model.desktopRainDiagnostics["dropsPlaying"] as? Bool == (preview != .snow))
            precondition(model.desktopRainDiagnostics["thunderReady"] as? Bool == (preview == .thunder))
            precondition(!defaults.bool(forKey: "desktopRainEnabled"), "Preview must not change saved rain preference")
        }
        model.stopWeatherPreview(); wait()
        precondition(model.desktopRainDiagnostics["windowCount"] as? Int == 0)
        precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == false)
        precondition(model.desktopRainDiagnostics["dropsPlaying"] as? Bool == false)
        precondition(model.desktopRainDiagnostics["thunderPlaying"] as? Bool == false)
        // Export the real renderer for every weather style; no fabricated UI.
        for preview in DesktopWeatherPreview.allCases {
            let view = RainView(frame: NSRect(x: 0, y: 0, width: 960, height: 600),
                                region: RainRect(x: 0, y: 0, width: 960, height: 600))
            for _ in 0..<216 { view.step(dt: 1/30, field: RoofField(), enabled: true, settings: preview.settings) }
            if preview == .thunder {
                view.step(dt:0,field:RoofField(),enabled:true,settings:preview.settings,
                          weatherTime:WeatherStormTiming.event(at:0).lightningAt+0.025)
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No weather bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: "output/desktop-rain/preview-\(preview.id).png"))
        }

        // Same dimensions/settings at 0/40/160 roofs. Worst case: all roofs below
        // the viewport, so no early shelter rejection. Fixed particle memory caps.
        var performance: [[String: Any]] = []
        for count in [0, 40] {
            let view = RainView(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
                                region: RainRect(x: 0, y: 0, width: 2560, height: 1440))
            let field = RoofField(windows: (0..<count).map { RainRect(x: Double($0 * 25), y: 1600, width: 120, height: 180) })
            let settings = RainSettings(size: 1, speed: 1, wind: 0.5, quantity: 3)
            var times: [Double] = []
            for frame in 0..<450 {
                let start = CACurrentMediaTime()
                view.step(dt: 1 / 30, field: field, enabled: true, settings: settings)
                let ms = (CACurrentMediaTime() - start) * 1000
                if frame >= 150 { times.append(ms) }
                precondition(view.particleCount <= 2200)
            }
            times.sort()
            let p95 = times[Int(Double(times.count-1) * 0.95)]
            precondition(p95 < 100, "Debug simulation severely exceeds frame budget")
            performance.append(["roofs": count, "frames": times.count, "p95StepMs": p95,
                "meanStepMs": times.reduce(0,+) / Double(times.count), "maxParticles": 2200])
        }
        try JSONSerialization.data(withJSONObject: performance, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "output/desktop-rain/simulation-performance.json"))
        print("Desktop rain checks passed: weather classification/freshness/failure/cancellation/rate limit; real AppModel auto/manual/off; bounded simulation")
    }
}
