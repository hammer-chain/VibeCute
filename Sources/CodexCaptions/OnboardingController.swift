import AppKit
import SwiftUI
import CaptionCore
import CoreGraphics

final class OnboardingController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var step: OnboardingProgress.Step
    @Published var connectionMessage = ""
    @Published private(set) var availableConnectionSources: [SessionSource] = []
    @Published private(set) var checkingConnections = false
    @Published private(set) var connectionCheckLimited = false
    private var connectionCheckGeneration = 0
    private var connectionOperation: BlockOperation?
    private let connectionQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility; return queue
    }()
    let model: AppModel
    private let defaults: UserDefaults
    private var replay = false
    private let screenPermissionAction: (() -> Void)?
    private let audioPermissionAction: (() -> Void)?
    private var bubble: SubtitlePanel?
    private let captionView = SubtitleView()
    private var buttons: [BubbleReplyButton] = []
    private var actions: [() -> Void] = []
    private var settings: NSWindow?
    private var hover: DispatchWorkItem?
    private var mouseDown: NSPoint?
    private var observer: NSObjectProtocol?
    private var lastFrame = NSRect.zero

    init(model: AppModel, screenPermissionAction: (() -> Void)? = nil, audioPermissionAction: (() -> Void)? = nil) {
        self.screenPermissionAction = screenPermissionAction; self.audioPermissionAction = audioPermissionAction
        self.model = model; defaults = model.onboardingPreferences
        if let resumeReplay = OnboardingProgress.permissionReplay(defaults) {
            step = .permissions; replay = resumeReplay
        } else { step = OnboardingProgress.step(defaults) }
        connectionMessage = defaults.string(forKey: "onboardingConnectionMessage") ?? ""
        super.init()
    }
    var active: Bool { step != .complete }
    func start(replay: Bool = false) {
        guard replay || active else { return }
        if bubble != nil {
            guard replay else { return }
            finish()
        }
        if replay {
            self.replay = true; step = .greeting; connectionMessage = ""
            OnboardingProgress.clearPermissionResume(defaults)
        }
        model.onboardingActive = true
        model.prepareOnboardingCharacter()
        model.onOnboardingLayout = { [weak self] in self?.positionBubble() }
        model.onOnboardingDragEnded = { [weak self] in self?.completeInteractionAfterRelease() }
        model.observeOnboardingPointer { [weak self] event, point in self?.pointer(event, at: point) }
        let panel = SubtitlePanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.acceptsQuestionInput = true
        panel.title = "蓝色大肥鱼 · 第一次见面"
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        captionView.setAccessibilityRole(.group); captionView.setAccessibilityElement(true)
        captionView.mode = .bubble; captionView.context = ""
        captionView.showsCaptionHeader = false; captionView.backdrop = 0.7
        captionView.captionFooterHeight = 46
        panel.contentView = captionView
        bubble = panel; renderCaption()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.settings?.title == "让大肥鱼认识桌面",
                      self.model.autoAvoidanceEnabled, CGPreflightScreenCaptureAccess(), !self.model.onboardingScreenReady else { return }
                self.model.requestBackdropPermission()
            }
        positionBubble(); panel.orderFrontRegardless()
        if step == .permissions, OnboardingProgress.permissionReplay(defaults) != nil { showPermissions() }
    }
    func move(_ next: OnboardingProgress.Step) {
        hover?.cancel(); hover = nil; mouseDown = nil
        if next != .permissions { OnboardingProgress.clearPermissionResume(defaults) }
        if next == .connection { connectionMessage = "" }
        step = next
        if !replay { defaults.set(next.rawValue, forKey: "onboardingStep") }
        if next == .complete { finish() }
        else { renderCaption(); positionBubble() }
    }
    private func finish() {
        closeSettings()
        bubble?.parent?.removeChildWindow(bubble!)
        bubble?.orderOut(nil); bubble = nil
        buttons.forEach { $0.removeFromSuperview() }; buttons = []; actions = []
        hover?.cancel(); hover = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        model.onOnboardingDragEnded = nil
        model.observeOnboardingPointer(nil); model.onOnboardingLayout = nil
        model.onboardingActive = false
    }
    deinit { connectionOperation?.cancel(); hover?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    var invitation: String {
        if replay || model.audioRunning || model.onboardingScreenReady {
            return "如果你愿意，我还能对屏幕和声音做出反应。\n我们来看看权限设置吧！"
        }
        return "现在的我还看不到桌面，也听不到电脑的声音。\n\n如果你愿意给我一点权限，我就能对屏幕和声音做出反应啦！"
    }
    var interactionText: String {
        let ready: String
        if model.audioRunning && model.onboardingScreenReady { ready = "好耶，准备就绪！ ✨" }
        else if model.audioRunning { ready = "好耶，我能听到电脑的声音啦！ ✨\n屏幕可以以后再设置。" }
        else if model.onboardingScreenReady { ready = "好耶，我能看到桌面啦！ ✨\n声音可以以后再设置。" }
        else { ready = "没关系，我们先认识一下！" }
        return ready + "\n\n试试用鼠标摸摸我，或者把我拖到喜欢的位置吧～"
    }
    func positionBubble() {
        guard let bubble else { return }
        let character = model.onboardingCharacter
        guard let parent = character?.panel, parent.isVisible,
              let area = parent.screen?.visibleFrame else { bubble.orderOut(nil); return }
        let sprite = character!.subtitle.seatedSpriteRect
        let anchor = sprite.offsetBy(dx: parent.frame.minX, dy: parent.frame.minY)
        let scale = min(1.15, max(0.85, character!.subtitle.layoutScale))
        captionView.layoutScale = scale; captionView.fontSize = 18 * scale
        let width = min(area.width, 320 * scale)
        let size = NSSize(width: width, height: captionView.height(for: width))
        let (target, right) = AkimboDialogue.placement(sprite: anchor, area: area, size: size)
        captionView.sideTailTarget = NSPoint(x: right ? -12 : target.width + 12, y: target.height / 2)
        if target != lastFrame {
            bubble.setFrame(target, display: false); captionView.frame = NSRect(origin: .zero, size: size)
            lastFrame = target
        }
        let gap: CGFloat = 8
        let total = buttons.reduce(CGFloat(0)) { $0 + $1.frame.width } + CGFloat(max(0, buttons.count - 1)) * gap
        var x = (width - total) / 2
        for button in buttons { button.frame.origin = NSPoint(x: x, y: 20 * scale); x += button.frame.width + gap }
        if bubble.parent !== parent { bubble.parent?.removeChildWindow(bubble); parent.addChildWindow(bubble, ordered: .above) }
        if !bubble.isVisible { bubble.order(.above, relativeTo: parent.windowNumber) }
    }
    private func renderCaption() {
        captionView.text = caption
        captionView.setAccessibilityLabel(caption)
        bubble?.setAccessibilityLabel("蓝色大肥鱼 · 第一次见面")
        buttons.forEach { $0.removeFromSuperview() }; buttons = []; actions = []
        func add(_ title: String, _ action: @escaping () -> Void) {
            let button = BubbleReplyButton(title: title, target: self, action: #selector(pressButton(_:)))
            button.font = .systemFont(ofSize: 13, weight: .medium); button.isPrimary = buttons.isEmpty
            button.tag = buttons.count; button.bezelStyle = .rounded
            if buttons.isEmpty { button.keyEquivalent = "\r" }
            button.frame.size = NSSize(width: min(280, max(70, (title as NSString).size(withAttributes: [.font: button.font!]).width + 24)), height: 30)
            captionView.addSubview(button); buttons.append(button); actions.append(action)
        }
        switch step {
        case .greeting: add("你好呀！") { [weak self] in self?.move(.permissions) }
        case .permissions:
            add("好呀，开始设置") { [weak self] in self?.showPermissions() }
            add("以后再说") { [weak self] in self?.move(.interaction) }
        case .interaction: add("先继续") { [weak self] in self?.move(.feedback) }
        case .feedback: add("继续") { [weak self] in self?.move(.connection) }
        case .connection:
            if connectionMessage.isEmpty {
                add("连接 AI 工具") { [weak self] in self?.showConnection() }
                add("以后再说") { [weak self] in self?.skipConnection() }
            } else { add("继续") { [weak self] in self?.move(.farewell) } }
        case .farewell: add("开始与蓝色大肥鱼一起生活") { [weak self] in self?.move(.complete) }
        case .complete: break
        }
        lastFrame = .zero; captionView.needsDisplay = true
    }
    @objc private func pressButton(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }; actions[sender.tag]()
    }
    private var caption: String {
        switch step {
        case .greeting: return "你好呀 👋 我是蓝色大肥鱼！\n以后就让我在桌面上陪你吧～"
        case .permissions: return invitation
        case .interaction: return interactionText
        case .feedback: return "嘿嘿，我喜欢这里！"
        case .connection: return connectionMessage.isEmpty ? "对啦，如果你平时用 Codex、Claude Code 这些 AI 工具……\n\n我还可以同步它们的工作进度。\n\n想现在连接一个吗？" : connectionMessage
        case .farewell: return "那么，从今天开始，请多关照啦！💙"
        case .complete: return ""
        }
    }
    private func completeInteractionAfterRelease() {
        guard step == .interaction else { return }
        hover?.cancel()
        let done = DispatchWorkItem { [weak self] in
            guard let self, self.step == .interaction else { return }
            self.model.onboardingReact(); self.move(.feedback)
        }
        hover = done; DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: done)
    }
    private func pointer(_ event: NSEvent, at point: NSPoint) {
        guard step == .interaction, settings == nil, let character = model.onboardingCharacter else { return }
        let hit = character.panel.isVisible && character.panel.frame.contains(point)
            && character.subtitle.containsVisibleCharacter(at: character.subtitle.convert(character.panel.convertPoint(fromScreen: point), from: nil))
        switch event.type {
        case .leftMouseDown:
            hover?.cancel(); hover = nil
            mouseDown = hit ? point : nil
        case .leftMouseDragged:
            hover?.cancel(); hover = nil
        case .leftMouseUp:
            if mouseDown != nil {
                mouseDown = nil
                completeInteractionAfterRelease()
            }
        case .mouseMoved:
            if !hit { hover?.cancel(); hover = nil }
            else if hover == nil && NSEvent.pressedMouseButtons == 0 {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.step == .interaction, NSEvent.pressedMouseButtons == 0 else { return }
                    self.model.onboardingReact(); self.move(.feedback)
                }
                hover = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
        default: break
        }
    }
    private func openSettings<V: View>(title: String, view: V) {
        closeSettings()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 350),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentViewController = NSHostingController(rootView: view.frame(width: 440, height: 328))
        settings = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func closeSettings() {
        connectionOperation?.cancel(); connectionOperation = nil
        connectionCheckGeneration += 1; checkingConnections = false
        settings?.delegate = nil; settings?.close(); settings = nil
    }
    func showPermissions() {
        guard step == .permissions else { return }
        OnboardingProgress.checkpointPermissions(defaults, replay: replay)
        openSettings(title: "让大肥鱼认识桌面", view: OnboardingPermissions(flow: self, model: model))
    }
    func permissionsContinue() { closeSettings(); move(.interaction) }
    func enableScreen() {
        guard step == .permissions else { return }
        OnboardingProgress.checkpointPermissions(defaults, replay: replay)
        if let screenPermissionAction { screenPermissionAction(); return }
        model.autoAvoidanceEnabled = true; model.requestBackdropPermission()
    }
    func enableAudio() {
        guard step == .permissions else { return }
        OnboardingProgress.checkpointPermissions(defaults, replay: replay)
        if let audioPermissionAction { audioPermissionAction(); return }
        if model.audioRunning { return }
        if model.audioEnabled { model.openAudioPermissions() }
        else { model.audioEnabled = true }
    }
    func showConnection() {
        openSettings(title: "连接 AI 工具", view: OnboardingConnection(flow: self))
        refreshConnections()
    }
    func refreshConnections() {
        guard !checkingConnections else { return }
        connectionCheckGeneration += 1
        let generation = connectionCheckGeneration
        let roots = model.onboardingHarnessRoots
        let dshDetected = model.dshBridge.detected
        checkingConnections = true; availableConnectionSources = []; connectionCheckLimited = false
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let result = OnboardingHarnessDiscovery.discover(roots: roots, cancelled: { operation.isCancelled })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionCheckGeneration == generation, self.settings != nil else { return }
                var available = result.available
                if dshDetected && !available.contains(.deepseek) { available.append(.deepseek) }
                self.availableConnectionSources = available
                self.connectionCheckLimited = result.limited; self.checkingConnections = false
                self.connectionOperation = nil
            }
        }
        connectionOperation = operation; connectionQueue.addOperation(operation)
    }
    func connect(_ source: SessionSource) {
        model.connectOnboarding(source)
        connectionMessage = model.sessions.contains { $0.source == source }
            ? "好啦，我会留意它的工作进度！" : "已经设置好啦，等你开始使用，我就能跟上进度！"
        saveConnectionMessage(); closeSettings(); renderCaption(); positionBubble()
    }
    func cancelConnection() { closeSettings(); skipConnection() }
    private func saveConnectionMessage() { if !replay { defaults.set(connectionMessage, forKey: "onboardingConnectionMessage") } }
    func skipConnection() { connectionMessage = "没关系！我先在桌面上陪你。\n\n想连接的时候，随时来找我就好～"; saveConnectionMessage(); renderCaption(); positionBubble() }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settings else { return }
        let permission = step == .permissions
        settings = nil
        connectionOperation?.cancel(); connectionOperation = nil
        connectionCheckGeneration += 1; checkingConnections = false
        // Closing during a macOS permission restart is not an explicit skip.
        // Keep the checkpoint so the same window returns on the next launch.
        if !permission { skipConnection() }
    }
}

private struct OnboardingPermissions: View {
    @ObservedObject var flow: OnboardingController
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("可以只开启一项，也可以以后再设置。").font(.headline)
            HStack {
                Text("屏幕：" + (model.onboardingScreenReady ? "已就绪" : "尚未就绪")); Spacer()
                Button("让我看到桌面") { flow.enableScreen() }.disabled(model.onboardingScreenReady)
            }
            Text(model.avoidanceStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("声音：" + (model.audioRunning ? "已就绪" : "尚未就绪")); Spacer()
                Button("让我听到电脑声音") { flow.enableAudio() }.disabled(model.audioRunning)
            }
            Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
            Text("系统授权需要你确认。屏幕与声音分别设置；无需开启麦克风。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("继续") { flow.permissionsContinue() }.keyboardShortcut(.defaultAction)
                Button("以后再说") { flow.permissionsContinue() }
            }
        }.padding(24)
    }
}
private struct OnboardingConnection: View {
    @ObservedObject var flow: OnboardingController
    @ObservedObject private var bridge: DSHBridgeManager
    @State private var source: SessionSource = .codex
    init(flow: OnboardingController) { self.flow = flow; bridge = flow.model.dshBridge }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("选择想连接的 AI 工具").font(.headline)
            if flow.checkingConnections {
                ProgressView("正在检查本地会话…")
            } else if flow.availableConnectionSources.isEmpty {
                Text("暂未读取到可连接的工具。使用 AI 工具产生会话后，可以重新检查，也可以稍后在设置中连接。")
                    .foregroundStyle(.secondary)
            } else {
                Picker("AI 工具", selection: $source) {
                    ForEach(flow.availableConnectionSources, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if source == .deepseek { DSHBridgeSettingsView(bridge: flow.model.dshBridge) }
            }
            if flow.connectionCheckLimited {
                Text("部分目录尚未检查，可在完整设置中指定目录。").font(.caption).foregroundStyle(.secondary)
            }
            Button("重新检查") { flow.refreshConnections() }.disabled(flow.checkingConnections)
            Spacer()
            HStack {
                if !flow.availableConnectionSources.isEmpty {
                    Button(source == .deepseek && bridge.state != .connected ? "只同步字幕" : "连接") {
                        if flow.availableConnectionSources.contains(source) { flow.connect(source) }
                    }.disabled(flow.checkingConnections || !flow.availableConnectionSources.contains(source))
                        .keyboardShortcut(.defaultAction)
                }
                Button("以后再说") { flow.cancelConnection() }
            }
        }.padding(24)
        .onChange(of: flow.availableConnectionSources) { choices in
            if !choices.contains(source), let first = choices.first { source = first }
        }
    }
}
