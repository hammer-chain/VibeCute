import AppKit
import AVFoundation
import QuartzCore

private final class RainOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct RainShelterSnapshot {
    var raining: Bool
    var suspended: Bool
    var frontWindow: RainRect?
    var wind: Double
    var windows: [RainRect] = []
}

/// Owns all rain work. Disabled/sleeping/locked means no windows, audio or frame timer.
final class DesktopRainController {
    private var windows: [RainOverlayWindow] = []
    private var views: [RainView] = []
    private let geometry = RainWindowGeometry()
    private var timer: Timer?
    private var lastFrame = 0.0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false
    private var locked = false
    private var requested = false
    private var settings = RainSettings()
    private var soundEnabled = false
    private var volume = 0.15
    private var dropsVolume = 0.45
    private var thunderVolume = 0.35
    private var basinVolume = 0.6
    private var player: AVAudioPlayer?
    private var dropsPlayer: AVAudioPlayer?
    private var thunderPlayers: [AVAudioPlayer] = []
    private var thunderIndex = 0
    private var thunderDeck = WeatherThunderDeck()
    private var thunderPlayer: AVAudioPlayer? { thunderPlayers.indices.contains(thunderIndex) ? thunderPlayers[thunderIndex] : nil }
    private var weatherElapsed = 0.0
    private var lastThunderCycle = -1
    private let stormSeed = UInt64.random(in: .min ... .max)
    private var thunderGain = 0.85
    private(set) var thunderPlays = 0
    private(set) var audioDecodes = 0
    private(set) var frames = 0
    private(set) var stepSeconds = 0.0
    private(set) var soundStatus = "天气音效已关闭"
    var onStatus: ((String) -> Void)?
    var onSuspension: (() -> Void)?
    var footprintProvider: (() -> [RainFootprint])?
    private var footRipples = RainFootRipples()
    var basinProvider: (() -> [RainBasinSurface])?
    var onBasinImpact: ((RainBasinImpact,Double) -> Void)?
    private var basinVoices: [AVAudioPlayer] = []
    private var basinAudioAttempted = false
    private var lastBasinSound = -Double.infinity
    private(set) var basinSoundPlays = 0
    private(set) var basinHits = 0

    init() {
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, self.timer != nil else { return }; self.rebuildScreens()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.views.forEach { $0.clear() }; self.footRipples.clear()
            self.geometry.refresh(now: CACurrentMediaTime(), force: true)
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.sleeping = true; self?.reconcile() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.sleeping = false; self?.reconcile() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.sleeping = true; self?.reconcile() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.sleeping = false; self?.reconcile() }
        observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsLocked")) { [weak self] in self?.locked = true; self?.reconcile() }
        observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsUnlocked")) { [weak self] in self?.locked = false; self?.reconcile() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observers.append((center, token))
    }

    deinit { stop(); for (center, token) in observers { center.removeObserver(token) } }

    func configure(active: Bool, settings: RainSettings, sound: Bool, volume: Double, dropsVolume: Double = 0.45, thunderVolume: Double? = nil, basinVolume: Double = 0.6) {
        if self.settings.style != settings.style { weatherElapsed = 0; lastThunderCycle = -1 }
        requested = active; self.settings = settings; soundEnabled = sound
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 0.15
        self.dropsVolume = dropsVolume.isFinite ? min(1,max(0,dropsVolume)) : 0.45
        let thunder = thunderVolume ?? volume
        self.thunderVolume = thunder.isFinite ? min(1,max(0,thunder)) : 0.35
        self.basinVolume = basinVolume.isFinite ? min(1,max(0,basinVolume)) : 0.6
        reconcile()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        dropsPlayer?.stop(); dropsPlayer = nil
        stopThunderAudio()
        stopBasinAudio(release:true)
        weatherElapsed = 0; lastThunderCycle = -1
        footRipples.clear()
        soundStatus = soundEnabled ? "天气音效随雨效暂停" : "天气音效已关闭"
        windows.forEach { $0.close() }; windows.removeAll(); views.removeAll()
    }

    private func reconcile() {
        guard requested, !sleeping, !locked else {
            if sleeping || locked { onSuspension?() }
            stop(); return
        }
        if timer == nil {
            rebuildScreens()
            lastFrame = CACurrentMediaTime()
            let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            clock.tolerance = 0.003
            RunLoop.main.add(clock, forMode: .common)
            timer = clock
        }
        updateAudio()
    }

    private func rebuildScreens() {
        footRipples.clear()
        windows.forEach { $0.close() }; windows.removeAll(); views.removeAll()
        guard let primary = NSScreen.screens.first else { return }
        for screen in NSScreen.screens {
            let f = screen.frame
            let region = quartzRect(appKit: RainRect(x: f.minX, y: f.minY, width: f.width, height: f.height),
                                    mainDisplayTop: primary.frame.maxY)
            let window = RainOverlayWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
            window.title = "VibeCute · 桌面雨"
            window.isReleasedWhenClosed = false; window.isOpaque = false
            window.backgroundColor = .clear; window.hasShadow = false
            window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
            window.isExcludedFromWindowsMenu = true; window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let view = RainView(frame: NSRect(origin: .zero, size: f.size), region: region)
            window.contentView = view; window.setFrame(f, display: true); window.orderFrontRegardless()
            windows.append(window); views.append(view)
        }
        geometry.refresh(now: CACurrentMediaTime(), force: true)
        lastFrame = CACurrentMediaTime()
    }

    private func tick() {
        let now = CACurrentMediaTime(), dt = max(0, min(now - lastFrame, 0.1))
        lastFrame = now
        weatherElapsed += dt
        geometry.refresh(now: now)
        if settings.style == .snow || !geometry.available {
            footRipples.clear()
        } else {
            footRipples.advance(at:now,feet:footprintProvider?() ?? [],field:geometry.field,wind:settings.wind)
        }
        let basins = settings.style == .snow ? [] : Array((basinProvider?() ?? []).prefix(2))
        if !basins.contains(where:{ $0.points.contains(where:{ !geometry.field.isSheltered($0,wind:settings.wind) }) }) {
            stopBasinAudio(release:false)
        }
        for view in views {
            view.step(dt:dt,field:geometry.field,enabled:geometry.available,settings:settings,
                      weatherTime:weatherElapsed,footRipples:footRipples.rings,rippleTime:now,basins:basins.filter { $0.overlaps(view.region) },stormSeed:stormSeed)
            for impact in view.basinImpacts {
                processBasinImpact(impact,at:now)
            }
        }
        if settings.style == .thunder, let cycle = WeatherStormTiming.soundCycle(at: weatherElapsed,seed:stormSeed), cycle > lastThunderCycle {
            lastThunderCycle = cycle
            if soundEnabled, !thunderPlayers.isEmpty {
                thunderPlayers.forEach { $0.stop() }
                thunderIndex = thunderDeck.next()
                let thunderPlayer = thunderPlayers[thunderIndex]
                thunderPlayer.rate = Float.random(in:0.97...1.03)
                thunderPlayer.pan = Float.random(in:-0.12...0.12)
                thunderGain = WeatherStormTiming.event(at:weatherElapsed,seed:stormSeed).gain
                thunderPlayer.volume = Float(thunderVolume * thunderGain)
                thunderPlayer.currentTime = 0
                if thunderPlayer.play() { thunderPlays += 1 }
                else { soundStatus = "雨声播放中 · 雷声播放失败" }
            }
        }
        frames += 1; stepSeconds += CACurrentMediaTime() - now
        onStatus?(geometry.available ? "桌面天气效果正在显示" : "窗口边界不可用 · 雨效已隐藏")
    }

    private func updateAudio() {
        guard soundEnabled, settings.style != .snow else {
            player?.stop(); player = nil; dropsPlayer?.stop(); dropsPlayer = nil; stopThunderAudio()
            stopBasinAudio(release:true)
            soundStatus = soundEnabled ? "下雪不播放音效" : "天气音效已关闭"; return
        }
        // Separate files and reusable decoders: volume changes never recreate a player.
        var failures: [String] = []
        func loop(_ audio: inout AVAudioPlayer?, name: String, gain: Double, label: String) {
            do {
                if audio == nil {
                    let loaded = try loadAudio(name)
                    loaded.numberOfLoops = -1; loaded.volume = 0
                    guard loaded.prepareToPlay() else { failures.append("\(label)无法准备"); return }
                    audio = loaded
                }
                guard audio?.isPlaying == true || audio?.play() == true else {
                    failures.append("\(label)播放失败"); return
                }
                audio?.setVolume(Float(gain), fadeDuration: 0.2)
            } catch { audio = nil; failures.append("\(label)文件不可用") }
        }
        loop(&player,name:"rain-bed-loop",gain:settings.rainOutput(userVolume:volume),label:"远处雨声")
        loop(&dropsPlayer,name:"rain-drops-loop",gain:settings.rainOutput(userVolume:dropsVolume),label:"近处雨滴")
        for voice in basinVoices { voice.setVolume(Float(basinVolume),fadeDuration:0.1) }
        if settings.style == .thunder {
            do {
                if thunderPlayers.isEmpty {
                    thunderPlayers = try WeatherThunderDeck.resources.map { name in
                        let audio = try loadAudio(name)
                        audio.enableRate = true; audio.volume = 0
                        guard audio.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
                        return audio
                    }
                }
                for audio in thunderPlayers { audio.setVolume(Float(thunderVolume*thunderGain), fadeDuration: 0.2) }
            } catch { stopThunderAudio(); failures.append("雷声文件不可用") }
        } else { stopThunderAudio() }
        let mapping = "\(settings.soundIntensity.rawValue) · 档内上限\(Int(settings.rainSoundCeiling*100))%"
        soundStatus = failures.isEmpty
            ? (settings.style == .thunder ? "远雨与滴雨独立播放 · \(mapping) · 闪电后播放雷声" : "远雨与滴雨独立播放 · \(mapping)")
            : failures.joined(separator:" · ")
    }

    private func stopThunderAudio() {
        thunderPlayers.forEach { $0.stop() }; thunderPlayers.removeAll()
        thunderIndex = 0
    }

    private func loadAudio(_ name: String, extension ext: String = "wav") throws -> AVAudioPlayer {
        guard let url = Bundle.main.url(forResource:name,withExtension:ext)
                ?? Bundle.module.url(forResource:name,withExtension:ext) else {
            throw CocoaError(.fileNoSuchFile)
        }
        audioDecodes += 1
        return try AVAudioPlayer(contentsOf:url)
    }

    private func stopBasinAudio(release: Bool) {
        for voice in basinVoices where voice.isPlaying { voice.stop() }
        lastBasinSound = -Double.infinity
        if release { basinVoices.removeAll(); basinAudioAttempted = false }
    }

    private func playBasinAudio(at now: Double) {
        guard soundEnabled, settings.style != .snow, now-lastBasinSound >= 0.125 else { return }
        if !basinAudioAttempted {
            basinAudioAttempted = true
            do {
                basinVoices = try (0..<2).map { _ in
                    let audio = try loadAudio("basin-hit")
                    audio.enableRate = true; audio.volume = Float(basinVolume)
                    guard audio.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
                    return audio
                }
            } catch { soundStatus += " · 钢盆音效不可用"; return }
        }
        guard let voice = basinVoices.first(where:{ !$0.isPlaying }) else { return }
        voice.currentTime = 0; voice.rate = Float.random(in:0.94...1.06)
        if voice.play() { lastBasinSound = now; basinSoundPlays += 1 }
    }

    func processBasinImpact(_ impact: RainBasinImpact, at now: Double) {
        guard timer != nil, !sleeping, !locked, settings.style != .snow else { return }
        basinHits += 1; onBasinImpact?(impact,now); playBasinAudio(at:now)
    }

    var shelterSnapshot: RainShelterSnapshot {
        RainShelterSnapshot(raining: timer != nil && (settings.style == .rain || settings.style == .thunder),
            suspended: sleeping || locked, frontWindow: geometry.available ? geometry.field.windows.first : nil,
            wind: settings.wind, windows: geometry.available ? geometry.field.windows : [])
    }

    var diagnostics: [String: Any] {
        ["active": timer != nil, "windowCount": windows.count, "frames": frames,
         "geometryQueries": geometry.queryCount, "stepSeconds": stepSeconds,
         "footRipples":footRipples.rings.count,"footRipplesEmitted":footRipples.emitted,
         "particles": views.reduce(0) { $0 + $1.particleCount }, "geometryAvailable": geometry.available,
         "style": settings.style.rawValue, "targetFPS": 30,
         "mouseTransparent": windows.allSatisfy(\.ignoresMouseEvents), "sound": soundStatus,
         "soundPlaying": player?.isPlaying == true,
         "dropsPlaying":dropsPlayer?.isPlaying == true,"rainVolume":volume,"dropsVolume":dropsVolume,
         "rainIntensity":settings.soundIntensity.rawValue,"rainSoundCeiling":settings.rainSoundCeiling,
         "rainTargetVolume":settings.rainOutput(userVolume:volume),"dropsTargetVolume":settings.rainOutput(userVolume:dropsVolume),
         "rainPlayerVolume":Double(player?.volume ?? 0),"dropsPlayerVolume":Double(dropsPlayer?.volume ?? 0),
         "rainDuration":player?.duration ?? 0,"dropsDuration":dropsPlayer?.duration ?? 0,
         "thunderVolume":thunderVolume, "thunderPlaying": thunderPlayer?.isPlaying == true,
         "thunderReady": thunderPlayers.count == WeatherThunderDeck.resources.count,
         "thunderVariants":thunderPlayers.count,"thunderVariant":WeatherThunderDeck.resources[thunderIndex],
         "thunderRate":Double(thunderPlayer?.rate ?? 1), "thunderPlays": thunderPlays, "audioDecodes": audioDecodes,
         "weatherElapsed": weatherElapsed,"thunderGain":thunderGain,
         "lightningAt":WeatherStormTiming.event(at:weatherElapsed,seed:stormSeed).lightningAt,
         "thunderAt":WeatherStormTiming.event(at:weatherElapsed,seed:stormSeed).soundAt,
         "basinHits":basinHits,"basinSoundPlays":basinSoundPlays,
         "basinVoices":basinVoices.count,"basinSoundPlaying":basinVoices.contains(where:\.isPlaying),
         "basinVolume":basinVolume,"basinVoiceVolumes":basinVoices.map { Double($0.volume) }]
    }
}
