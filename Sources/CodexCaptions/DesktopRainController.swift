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
    private var volume = 0.35
    private var player: AVAudioPlayer?
    private var thunderPlayer: AVAudioPlayer?
    private var weatherElapsed = 0.0
    private var lastThunderCycle = -1
    private(set) var thunderPlays = 0
    private(set) var audioDecodes = 0
    private(set) var frames = 0
    private(set) var stepSeconds = 0.0
    private(set) var soundStatus = "天气音效已关闭"
    var onStatus: ((String) -> Void)?
    var onSuspension: (() -> Void)?

    init() {
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, self.timer != nil else { return }; self.rebuildScreens()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.views.forEach { $0.clear() }
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

    func configure(active: Bool, settings: RainSettings, sound: Bool, volume: Double) {
        if self.settings.style != settings.style { weatherElapsed = 0; lastThunderCycle = -1 }
        requested = active; self.settings = settings; soundEnabled = sound
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 0.35
        reconcile()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        thunderPlayer?.stop(); thunderPlayer = nil
        weatherElapsed = 0; lastThunderCycle = -1
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
        for view in views { view.step(dt: dt, field: geometry.field, enabled: geometry.available, settings: settings, weatherTime: weatherElapsed) }
        if settings.style == .thunder, let cycle = WeatherStormTiming.soundCycle(at: weatherElapsed), cycle > lastThunderCycle {
            lastThunderCycle = cycle
            if soundEnabled, let thunderPlayer {
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
            player?.stop(); player = nil; thunderPlayer?.stop(); thunderPlayer = nil
            soundStatus = soundEnabled ? "下雪不播放音效" : "天气音效已关闭"; return
        }
        do {
            if player == nil {
                let audio = try loadAudio("rain")
                audio.numberOfLoops = -1; audio.volume = 0
                guard audio.prepareToPlay() else { soundStatus = "雨声无法播放"; return }
                player = audio
            }
            if player?.isPlaying != true, player?.play() != true { soundStatus = "雨声播放失败"; return }
            player?.setVolume(Float(volume), fadeDuration: 0.2)
            soundStatus = "正在播放本地雨声"
            if settings.style == .thunder {
                do {
                    if thunderPlayer == nil {
                        let audio = try loadAudio("thunder")
                        guard audio.prepareToPlay() else { soundStatus = "雨声播放中 · 雷声无法播放"; return }
                        thunderPlayer = audio
                    }
                    thunderPlayer?.setVolume(Float(volume*0.85), fadeDuration: 0.2)
                    soundStatus = "雨声播放中 · 闪电后播放雷声"
                } catch {
                    thunderPlayer = nil; soundStatus = "雨声播放中 · 雷声文件无法解码"
                }
            } else { thunderPlayer?.stop(); thunderPlayer = nil }
        } catch { player = nil; soundStatus = "雨声文件无法解码" }
    }

    private func loadAudio(_ name: String) throws -> AVAudioPlayer {
        guard let url = Bundle.main.url(forResource:name,withExtension:"wav")
                ?? Bundle.module.url(forResource:name,withExtension:"wav") else {
            throw CocoaError(.fileNoSuchFile)
        }
        audioDecodes += 1
        return try AVAudioPlayer(contentsOf:url)
    }

    var shelterSnapshot: RainShelterSnapshot {
        RainShelterSnapshot(raining: timer != nil && (settings.style == .rain || settings.style == .thunder),
            suspended: sleeping || locked, frontWindow: geometry.available ? geometry.field.windows.first : nil,
            wind: settings.wind)
    }

    var diagnostics: [String: Any] {
        ["active": timer != nil, "windowCount": windows.count, "frames": frames,
         "geometryQueries": geometry.queryCount, "stepSeconds": stepSeconds,
         "particles": views.reduce(0) { $0 + $1.particleCount }, "geometryAvailable": geometry.available,
         "style": settings.style.rawValue, "targetFPS": 30,
         "mouseTransparent": windows.allSatisfy(\.ignoresMouseEvents), "sound": soundStatus,
         "soundPlaying": player?.isPlaying == true, "thunderPlaying": thunderPlayer?.isPlaying == true,
         "thunderReady": thunderPlayer != nil, "thunderPlays": thunderPlays, "audioDecodes": audioDecodes,
         "weatherElapsed": weatherElapsed]
    }
}
