import AppKit
import SwiftUI
import CaptionCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var menuLocalClickMonitor: Any?
    private var menuGlobalClickMonitor: Any?
    private var detachedSettingsWindow: NSWindow?
    private var settingsDetached = false
    private var developerWindow: NSWindow?
    private var onboarding: OnboardingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !VIBECUTE_RELEASE
        if CommandLine.arguments.contains("--cutout-compare"),
           CommandLine.arguments.contains("--cutout-rhythm-smoke-out") || CommandLine.arguments.contains("--cutout-drag-smoke-out") {
            NSApp.setActivationPolicy(.regular)
            CutoutComparisonController.shared.show()
            return
        }
        if CommandLine.arguments.contains("--cutout-studio") {
            NSApp.setActivationPolicy(.regular)
            CutoutStudioController.shared.show()
            return
        }
        #endif
        NSApp.setActivationPolicy(.accessory)
        model = AppModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "VibeCute")
            button.target = self; button.action = #selector(togglePopover)
            button.toolTip = "VibeCute · Codex / DeepSeek Harness"
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        let menuController = NSHostingController(rootView: MenuPanelView(model: model,
            onHeightChange: { [weak self] height in
                guard let self, abs(self.popover.contentSize.height - height) > 0.5 else { return }
                self.popover.contentSize = NSSize(width: 340, height: height)
            },
            onPreferences: { [weak self] in self?.detachSettingsFromMenu() },
            onOnboarding: { [weak self] in self?.replayOnboarding() }))
        menuController.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        popover.contentViewController = menuController
        model.onStatus = { [weak self] enabled in
            self?.statusItem.button?.appearsDisabled = !enabled
        }
        model.start()
        onboarding = OnboardingController(model: model)
        onboarding?.start()
        #if !VIBECUTE_RELEASE
        if CommandLine.arguments.contains("--cutout-compare") {
            DispatchQueue.main.async { CutoutComparisonController.shared.show() }
        }
        if CommandLine.arguments.contains("--cutout-workbench") {
            DispatchQueue.main.async { CutoutStudioController.shared.show() }
        }
        #endif
        if !BuildProfile.isRelease && CommandLine.arguments.contains("--developer-mode") {
            DispatchQueue.main.async { [weak self] in self?.showDeveloperMode() }
        } else if CommandLine.arguments.contains("--settings-window") {
            DispatchQueue.main.async { [weak self] in self?.detachSettingsFromMenu() }
        } else if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { [weak self] in self?.togglePopover() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        #if !VIBECUTE_RELEASE
        if CommandLine.arguments.contains("--cutout-studio") {
            CutoutStudioController.shared.show()
            return true
        }
        #endif
        if settingsDetached, let window = detachedSettingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else if !popover.isShown {
            showPopover()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {
        !BuildProfile.isRelease && CommandLine.arguments.contains("--cutout-studio")
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func settingsView(isDetached: Bool) -> SettingsView {
        SettingsView(model: model, isDetached: isDetached,
                     onDetach: { [weak self] in self?.detachSettingsFromMenu() },
                     onReturnToMenu: { [weak self] in self?.returnSettingsToMenu() },
                     onDeveloperMode: { [weak self] in self?.showDeveloperMode() },
                     onOnboarding: { [weak self] in self?.replayOnboarding() })
    }

    private func showDeveloperMode() {
        #if !VIBECUTE_RELEASE
        popover.performClose(nil)
        if let window = developerWindow {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            return
        }
        let height = min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 80)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "VibeCute · 开发者模式"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentViewController = NSHostingController(rootView: DeveloperSettingsView(model: model))
        window.setContentSize(NSSize(width:500,height:height))
        developerWindow = window; window.center()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        #endif
    }

    private func replayOnboarding() {
        guard let onboarding else { return }
        popover.performClose(nil); onboarding.start(replay: true)
    }

    private func detachSettingsFromMenu() {
        popover.close()
        if let window = detachedSettingsWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            return
        }
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let size = NSSize(width: min(900, visible.width - 60), height: min(690, visible.height - 80))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "VibeCute · 偏好设置"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(srgbRed: 0.09, green: 0.15, blue: 0.18, alpha: 1)
        window.contentMinSize = NSSize(width: 760, height: 540)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentViewController = NSHostingController(rootView: settingsView(isDetached: true))
        window.setContentSize(size)
        detachedSettingsWindow = window; settingsDetached = true
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    private func returnSettingsToMenu() {
        guard settingsDetached else { return }
        let window = detachedSettingsWindow
        detachedSettingsWindow = nil
        settingsDetached = false
        window?.delegate = nil
        window?.close()
        showPopover()
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        if let controller = popover.contentViewController as? NSHostingController<MenuPanelView> {
            controller.rootView.maximumHeight = max(100, (button.window?.screen?.visibleFrame.height ?? 800) - 40)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        monitorMenuOutsideClicks()
    }

    private func monitorMenuOutsideClicks() {
        stopMonitoringMenuClicks()
        guard popover.isShown else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Same-app character panels do not deactivate the app, so .transient alone
        // misses them. Return the event unchanged so the outside target still receives it.
        menuLocalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.dismissMenuIfOutside(event)
            return event
        }
        menuGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.dismissMenuIfOutside(event)
        }
    }

    private func dismissMenuIfOutside(_ event: NSEvent) {
        guard popover.isShown, let menuWindow = popover.contentViewController?.view.window else { return }
        // Preserve controls and their child popups, even when they extend beyond the menu.
        var target = event.window
        while let window = target {
            if window === menuWindow { return }
            target = window.parent
        }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if menuWindow.frame.contains(point) { return }
        if let button = statusItem.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) {
            return // The status-item action already toggles the menu.
        }
        popover.performClose(nil)
    }

    private func stopMonitoringMenuClicks() {
        if let monitor = menuLocalClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = menuGlobalClickMonitor { NSEvent.removeMonitor(monitor) }
        menuLocalClickMonitor = nil; menuGlobalClickMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) { stopMonitoringMenuClicks() }

    func applicationWillTerminate(_ notification: Notification) { stopMonitoringMenuClicks() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === developerWindow {
            developerWindow = nil; model.stopPreview(); model.stopWeatherPreview(); return
        }
        guard window === detachedSettingsWindow else { return }
        detachedSettingsWindow = nil
        settingsDetached = false
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
