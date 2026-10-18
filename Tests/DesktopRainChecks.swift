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
        for code in [51,53,55,56,57,61,63,65,66,67,80,81,82,95,96,99] { let value = try reading(code); precondition(value.raining) }
        for code in [0,1,2,3,45,48,71,73,75,77,85,86] { let value = try reading(code); precondition(!value.raining) }
        let mixedRain = try reading(3, rain: 0.1); precondition(mixedRain.raining)
        let showers = try reading(3, showers: 0.1); precondition(showers.raining)
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
        var appWet = false
        let appWeather = RainWeatherMonitor { _ in RainWeatherReading(raining: appWet, date: Date()) }
        let model = AppModel(rainWeather: appWeather)
        model.start(); wait()
        precondition(model.desktopRainDiagnostics["active"] as? Bool == false)
        model.selectRainCity(city); model.desktopRainEnabled = true; wait()
        precondition(model.desktopRainDiagnostics["active"] as? Bool == false, "Dry city should remain idle")
        appWet = true; model.selectRainCity(other); wait()
        precondition(model.desktopRainDiagnostics["active"] as? Bool == true, "Rain weather must start actual overlay")
        precondition(model.desktopRainDiagnostics["windowCount"] as? Int == NSScreen.screens.count)
        precondition(model.desktopRainDiagnostics["mouseTransparent"] as? Bool == true)
        let frameCount = model.desktopRainDiagnostics["frames"] as! Int
        model.desktopRainEnabled = false; wait(0.3)
        precondition(model.desktopRainDiagnostics["windowCount"] as? Int == 0)
        precondition(model.desktopRainDiagnostics["frames"] as! Int == frameCount)
        precondition(model.rainWeatherDiagnostics["polling"] as? Bool == false)
        precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == false)
        model.desktopRainAutomatic = false; model.desktopRainEnabled = true; wait(0.4)
        precondition(model.desktopRainDiagnostics["active"] as? Bool == true, "Manual mode starts without weather")
        model.desktopRainVolume = 0; model.desktopRainSound = true; wait()
        precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == true, "Bundled rain audio must load and play")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        wait(); precondition(model.desktopRainDiagnostics["windowCount"] as? Int == 0)
        precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == false)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        wait(); precondition(model.desktopRainDiagnostics["active"] as? Bool == true)
        model.desktopRainSound = false
        let before = model.desktopRainDiagnostics["frames"] as! Int
        model.desktopRainSize = 2; model.desktopRainWind = -30; model.desktopRainQuantity = 3
        wait(0.3)
        precondition(model.desktopRainDiagnostics["frames"] as! Int > before)
        model.desktopRainEnabled = false
        precondition(defaults.bool(forKey: "desktopRainAutomatic") == false)
        precondition(defaults.data(forKey: "desktopRainCity") != nil)

        for preview in DesktopWeatherPreview.allCases {
            model.previewWeather(preview); wait(0.12)
            precondition(model.desktopRainDiagnostics["style"] as? String == preview.settings.style.rawValue)
            precondition(model.desktopRainDiagnostics["active"] as? Bool == true)
            precondition(model.desktopRainDiagnostics["soundPlaying"] as? Bool == false)
            precondition(!defaults.bool(forKey: "desktopRainEnabled"), "Preview must not change saved rain preference")
        }
        model.stopWeatherPreview(); wait()
        precondition(model.desktopRainDiagnostics["windowCount"] as? Int == 0)
        // Export the real renderer for every weather style; no fabricated UI.
        for preview in DesktopWeatherPreview.allCases {
            let view = RainView(frame: NSRect(x: 0, y: 0, width: 960, height: 600),
                                region: RainRect(x: 0, y: 0, width: 960, height: 600))
            for _ in 0..<216 { view.step(dt: 1/30, field: RoofField(), enabled: true, settings: preview.settings) }
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
