import AppKit
import SwiftUI
import Darwin

/// A real renderer workbench. It shares the app's registered resources and
/// player; no log readers, audio capture or daily preferences are started.
final class CutoutStudioState: ObservableObject {
    let artwork: CutoutArtwork
    let candidatePath: String?
    let hasBlink: Bool
    let hasMouth: Bool
    @Published var action = "idle"
    @Published var clothes = "clothes-maid"
    @Published var hair = "hair-maid"
    @Published var headwear = "headwear-maid"
    @Published var tail = true
    @Published var wings = false
    @Published var playing = true
    @Published var mirrored = false
    @Published var skeleton = false
    @Published var scale = 1.0
    @Published var mouth = 0.0
    @Published var mouthMode = "neutral"
    @Published var mouthShape = "default"
    @Published var eyeMode = "auto"
    @Published var blink = 0.0
    @Published var gazeMode = "center"
    @Published var position = 0.0
    @Published var error: String?
    var fitPreview: ((NSSize) -> Void)?
    private(set) var clockOrigin = ProcessInfo.processInfo.systemUptime
    private var stoppedAt = 0.0

    init(artwork: CutoutArtwork, candidatePath: String? = nil) {
        self.artwork = artwork
        self.candidatePath = candidatePath
        hasBlink=(artwork.rig.expressions ?? [:]).contains{$0.key != "mouth" && $0.value.count>1}
        hasMouth=(artwork.rig.expressions?["mouth"]?.count ?? 0)>1
        action = artwork.player.clips.first(where:{$0.definition.id == "thinking-classic"})?.definition.id
            ?? artwork.player.clips.first(where:{$0.definition.id == "thinking"})?.definition.id
            ?? artwork.player.clips.first(where:{$0.definition.id == "idle"})?.definition.id
            ?? artwork.player.clips.first(where:{$0.definition.id == "head-sway"})?.definition.id
            ?? artwork.player.clips[0].definition.id
        clothes = artwork.selection["clothes"] ?? ""
        hair = artwork.selection["hair"] ?? ""
        headwear = artwork.selection["headwear"] ?? ""
        artwork.player.play(action, at: 0, transition: 0)
    }
    var clock: Double { playing ? ProcessInfo.processInfo.systemUptime-clockOrigin : stoppedAt }
    var duration: Double { artwork.player.clips[artwork.player.clipIndex].duration }
    func synchronizeAction() {
        let active = artwork.player.clips[artwork.player.clipIndex].definition.id
        if action != active { action = active; position = 0 }
    }
    func faceInputs(at time:Double)->(blink:Double,mouth:Double,gaze:CGPoint,shape:String?) {
        let b=eyeMode == "auto" ? artwork.player.automaticBlink(at:time,fallback:CutoutArtwork.blink(at:time)):min(1,max(0,blink))
        let m=(mouthMode == "talk" || mouthMode == "cycle") ? CutoutArtwork.talkingPreview(at:time):(mouthMode == "manual" ? min(1,max(0,mouth)):0)
        let shapes = artwork.rig.mouthShapes ?? []
        let shape = mouthMode == "cycle" && !shapes.isEmpty
            ? shapes[Int(max(0,time)/0.8) % shapes.count].id : mouthShape
        let gaze:CGPoint
        switch gazeMode {
        case "left":gaze=CGPoint(x:-1,y:0)
        case "right":gaze=CGPoint(x:1,y:0)
        case "up":gaze=CGPoint(x:0,y:1)
        case "down":gaze=CGPoint(x:0,y:-1)
        case "scan":gaze=CGPoint(x:sin(time*2*Double.pi/5.2),y:0.45*sin(time*2*Double.pi/7.1))
        default:gaze = .zero
        }
        return (hasBlink ? b:0,hasMouth ? m:0,gaze,shape == "default" ? nil : shape)
    }

    func setAction(_ value: String) {
        guard let clip=artwork.player.clips.first(where:{$0.definition.id == value}) else {
            error = "当前角色没有这个动作："+value;return
        }
        let time=clock,face=faceInputs(at:time)
        _ = artwork.player.play(value, at: time,transition:clip.definition.interpolation == .step ? 0 : 0.25,blink:face.blink)
        action = value; position = 0
    }
    func setPlaying(_ value: Bool) {
        if value == playing { return }
        if value { clockOrigin = ProcessInfo.processInfo.systemUptime-stoppedAt }
        else {
            stoppedAt = clock
            artwork.player.sample(at:stoppedAt)
            action = artwork.player.clips[artwork.player.clipIndex].definition.id
            let elapsed=max(0,stoppedAt-artwork.player.startedAt)
            position=artwork.player.clips[artwork.player.clipIndex].definition.loop
                ? elapsed.truncatingRemainder(dividingBy:duration)/duration : min(1,elapsed/duration)
        }
        playing = value
    }
    func seek(_ value: Double) {
        setPlaying(false)
        position = min(1,max(0,value))
        artwork.player.seek(to:position*duration,at:stoppedAt)
    }
    func select(_ category: String, _ value: String) {
        do {
            try artwork.select([category:value]); error = nil
            if category == "clothes" { clothes = value }
            if category == "hair" { hair = value }
            if category == "headwear" { headwear = value }
            if category == "tail" { tail = value == "whale-tail" }
            if category == "wings" { wings = value == "fin-wings" }
        } catch { self.error = String(describing:error) }
    }
    func setScale(_ value: Double) {
        guard value.isFinite else { return }
        scale = min(2,max(0.5,value))
        // Resize the inspection surface, preserving registered character scale.
        // This runs on control changes, never on an animation tick.
        let pixelScale=artwork.rig.pointsPerPixel*scale
        fitPreview?(NSSize(width:max(680,artwork.rig.canvas[0]*pixelScale+340),
                           height:max(550,artwork.rig.canvas[1]*pixelScale+180)))
    }
}

final class CutoutCanvasView: NSView {
    var state: CutoutStudioState?
    private var timer: Timer?
    private(set) var ticks = 0
    private(set) var redraws = 0
    private(set) var sampleSeconds = 0.0
    private(set) var drawSeconds = 0.0
    private(set) var paintedArea = 0.0
    private var lastPaint = CGRect.zero
    private var pendingTime:Double?
    override var isOpaque: Bool { false }

    override init(frame frameRect:NSRect) {
        super.init(frame:frameRect)
        NotificationCenter.default.addObserver(self,selector:#selector(applicationHidden),name:NSApplication.didHideNotification,object:NSApp)
        NotificationCenter.default.addObserver(self,selector:#selector(applicationShown),name:NSApplication.didUnhideNotification,object:NSApp)
        NotificationCenter.default.addObserver(self,selector:#selector(occlusionChanged),name:NSWindow.didChangeOcclusionStateNotification,object:nil)
    }
    required init?(coder:NSCoder) { fatalError("CutoutCanvas is created programmatically") }
    @objc private func applicationHidden() { stop() }
    @objc private func applicationShown() { update() }
    @objc private func occlusionChanged(_ notification:Notification) {
        if let changed=notification.object as? NSWindow, changed === window { refreshClock() }
    }

    func update() {
        pendingTime = nil
        needsDisplay = true
        refreshClock()
    }
    private func refreshClock() {
        let active = state?.playing == true && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
        guard active else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let value = Timer(timeInterval:1.0/30, repeats:true) { [weak self] _ in
            guard let self else { return }
            guard self.window?.isVisible == true, self.window?.isMiniaturized == false, self.state?.playing == true else {
                self.refreshClock(); return
            }
            self.ticks += 1
            if let state = self.state {
                let time = state.clock,before = ProcessInfo.processInfo.systemUptime
                let face=state.faceInputs(at:time)
                state.artwork.player.sample(at:time,gaze:face.gaze)
                state.synchronizeAction()
                self.sampleSeconds += ProcessInfo.processInfo.systemUptime-before
                self.pendingTime = time
                let current = state.artwork.motionBounds(anchor:CGPoint(x:self.bounds.midX,y:24),scale:state.scale,
                    mirrored:state.mirrored).union(state.skeleton
                        ? state.artwork.displayBounds(anchor:CGPoint(x:self.bounds.midX,y:24),scale:state.scale,mirrored:state.mirrored,skeleton:true) : .null)
                self.setNeedsDisplay(current.union(self.lastPaint))
                let clip=state.artwork.player.clips[state.artwork.player.clipIndex]
                if clip.definition.interpolation == .step {
                    // Match the app preview: reuse this clock and also wake at
                    // held-pose boundaries instead of rounding to a 30 Hz tick.
                    let remaining=clip.remainingFrameTime(at:time-state.artwork.player.startedAt)-(state.clock-time)
                    self.timer?.fireDate=Date(timeIntervalSinceNow:max(0.0001,min(1/30,remaining)))
                }
            }
        }
        value.tolerance = 0.002
        timer = value; RunLoop.main.add(value,forMode:.common)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshClock() }
    func stop() { timer?.invalidate(); timer = nil }
    var timerActive: Bool { timer != nil }
    deinit { timer?.invalidate();NotificationCenter.default.removeObserver(self) }

    override func draw(_ dirtyRect: NSRect) {
        guard let state, let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let floor = CGPoint(x:bounds.midX,y:24)
        context.setStrokeColor(NSColor.separatorColor.cgColor);context.setLineWidth(1)
        context.move(to:CGPoint(x:bounds.minX+20,y:floor.y));context.addLine(to:CGPoint(x:bounds.maxX-20,y:floor.y));context.strokePath()
        let time = pendingTime ?? state.clock, before = ProcessInfo.processInfo.systemUptime
        let face=state.faceInputs(at:time)
        if pendingTime == nil { state.artwork.player.sample(at:time,gaze:face.gaze) }
        pendingTime = nil
        let sampled = ProcessInfo.processInfo.systemUptime
        state.artwork.draw(in:context,anchor:floor,scale:state.scale,mirrored:state.mirrored,
                           blink:face.blink,mouth:face.mouth,mouthShape:face.shape,skeleton:state.skeleton)
        let drawn = ProcessInfo.processInfo.systemUptime
        redraws += 1;sampleSeconds += sampled-before;drawSeconds += drawn-sampled
        paintedArea += dirtyRect.width*dirtyRect.height
        lastPaint = state.artwork.displayBounds(anchor:floor,scale:state.scale,mirrored:state.mirrored,skeleton:state.skeleton)
    }
}

private struct CutoutCanvas: NSViewRepresentable {
    @ObservedObject var state: CutoutStudioState
    let onView: (CutoutCanvasView) -> Void
    func makeNSView(context: Context) -> CutoutCanvasView {
        let view = CutoutCanvasView(); view.state = state; onView(view); return view
    }
    func updateNSView(_ view: CutoutCanvasView,context:Context) { view.state = state;view.update() }
}

private struct CutoutStudioView: View {
    @ObservedObject var state: CutoutStudioState
    let onView: (CutoutCanvasView) -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(state.candidatePath == nil ? "DeepSeek · Cutout" : "DeepSeek · 原图拆层候选（未验收）").font(.title2)
                Spacer()
                Button(state.playing ? "暂停" : "播放") { state.setPlaying(!state.playing) }
            }
            HStack(alignment:.top,spacing:16) {
                CutoutCanvas(state:state,onView:onView).frame(minWidth:300,minHeight:420)
                VStack(alignment:.leading,spacing:14) {
                Picker("动作",selection:Binding(get:{state.action},set:{state.setAction($0)})) {
                    ForEach(state.artwork.player.clips,id:\.definition.id) { Text($0.definition.title).tag($0.definition.id) }
                }
                HStack {
                Toggle("镜像",isOn:$state.mirrored).toggleStyle(.checkbox)
                Toggle("关节",isOn:$state.skeleton).toggleStyle(.checkbox)
                }
                Picker("服装",selection:Binding(get:{state.clothes},set:{state.select("clothes",$0)})) {
                    ForEach(state.artwork.rig.variants.filter { $0.category == "clothes" },id:\.id) { Text($0.title).tag($0.id) }
                }
                Picker("发型",selection:Binding(get:{state.hair},set:{state.select("hair",$0)})) {
                    ForEach(state.artwork.rig.variants.filter { $0.category == "hair" },id:\.id) { Text($0.title).tag($0.id) }
                }
            Picker("头饰",selection:Binding(get:{state.headwear},set:{state.select("headwear",$0)})) {
                ForEach(state.artwork.rig.variants.filter { $0.category == "headwear" },id:\.id) { Text($0.title).tag($0.id) }
            }
            VStack(alignment:.leading,spacing:12) {
                ForEach(["tail", "wings"],id:\.self) { category in
                    if state.artwork.rig.variants.contains(where:{$0.category == category}) {
                        Picker(category == "tail" ? "尾巴" : "翅膀",selection:Binding(
                            get:{state.artwork.selection[category] ?? ""},
                            set:{state.select(category,$0)})) {
                            ForEach(state.artwork.rig.variants.filter{$0.category == category},id:\.id) { variant in
                                Text(variant.title).tag(variant.id)
                            }
                        }
                    }
                }
            }
            HStack {
                Text("\(Int(state.scale*100))%")
                Slider(value:Binding(get:{state.scale},set:{state.setScale($0)}),in:0.5...2).frame(width:100)
            }
            if state.hasBlink {
                Picker("眼睛",selection:$state.eyeMode) {
                    Text("自然眨眼").tag("auto")
                    Text("手动开合").tag("manual")
                }
                if state.eyeMode == "manual" {Slider(value:$state.blink,in:0...1).accessibilityLabel("闭眼程度")}
            }
            if state.artwork.rig.eyeClips?.isEmpty == false {
                Picker("视线",selection:$state.gazeMode) {
                    Text("中间").tag("center");Text("左右巡视").tag("scan")
                    Text("向左").tag("left");Text("向右").tag("right")
                    Text("向上").tag("up");Text("向下").tag("down")
                }
            }
            if state.hasMouth {
                Picker("嘴部",selection:$state.mouthMode) {
                    Text("中性微笑").tag("neutral");Text("说话开合预览").tag("talk");Text("手动开合").tag("manual")
                    if state.artwork.rig.mouthShapes?.isEmpty == false {Text("口形轮换预览").tag("cycle")}
                }
                if let shapes = state.artwork.rig.mouthShapes, !shapes.isEmpty {
                    Picker("口形",selection:$state.mouthShape) {
                        Text("原版微笑").tag("default")
                        ForEach(shapes,id:\.id) {Text($0.title).tag($0.id)}
                    }.onChange(of:state.mouthShape) { _ in
                        if state.mouthMode == "neutral" {state.mouthMode="manual";state.mouth=0.8}
                    }
                }
                if state.mouthMode == "manual" {Slider(value:$state.mouth,in:0...1).accessibilityLabel("张嘴程度")}
            }
            Text("\(state.artwork.rig.bones.count) 个关节 · \(state.artwork.parts.count) 个组件 · 同一套动作")
                .font(.caption).foregroundStyle(.secondary)
            if let error = state.error { Text(error).foregroundStyle(.red).font(.caption) }
                }.frame(width:260)
            }
            HStack {
                Text("姿态")
                Slider(value:Binding(get:{state.position},set:{state.seek($0)}),in:0...1)
            }
        }.padding(20).frame(minWidth:680,minHeight:state.artwork.rig.mouthShapes?.isEmpty == false ? 620:550)
    }
}

final class CutoutStudioController: NSObject, NSWindowDelegate {
    static let shared = CutoutStudioController()
    private(set) var window: NSWindow?
    private(set) var state: CutoutStudioState?
    private(set) weak var canvas: CutoutCanvasView?

    func show() {
        if let window { NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);return }
        do {
            let artwork: CutoutArtwork
            var candidatePath: String?
            if let index=CommandLine.arguments.firstIndex(of:"--cutout-candidate") {
                guard CommandLine.arguments.indices.contains(index+1) else {throw CutoutError.invalid("Missing candidate rig path")}
                let url=URL(fileURLWithPath:CommandLine.arguments[index+1]).standardizedFileURL
                var rig=try JSONDecoder().decode(CutoutRig.self,from:Data(contentsOf:url))
                // Preview framing only; source geometry and registered runtime art stay unchanged.
                rig.anchor=[rig.canvas[0]/2,0]
                // The candidate registers its pixel scale. A 2x PSD export must
                // retain the same character size as the source reference.
                let directory=url.deletingLastPathComponent()
                artwork=try CutoutArtwork(rig:rig) {directory.appendingPathComponent($0)}
                candidatePath=url.path
            } else { artwork=try CutoutArtwork.bundled() }
            let state = CutoutStudioState(artwork:artwork,candidatePath:candidatePath)
            for (flag,category) in [("--cutout-clothes","clothes"),("--cutout-headwear","headwear")] {
                if let index=CommandLine.arguments.firstIndex(of:flag),CommandLine.arguments.indices.contains(index+1) {
                    state.select(category,CommandLine.arguments[index+1])
                    if let error=state.error {throw CutoutError.invalid(error)}
                }
            }
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:580),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title = candidatePath == nil ? "VibeCute · Cutout 动作工作台" : "VibeCute · Cutout 原图候选（未验收）"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentViewController = NSHostingController(rootView:CutoutStudioView(state:state) { [weak self] view in self?.canvas = view })
            self.window = window; self.state = state
            state.fitPreview = { [weak window] size in
                guard let window else { return }
                let current=window.contentLayoutRect.size
                window.setContentSize(NSSize(width:max(current.width,size.width),height:max(current.height,size.height)))
            }
            window.center();NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in self?.canvas?.update() }
            if let index = CommandLine.arguments.firstIndex(of:"--cutout-smoke-out"), CommandLine.arguments.indices.contains(index+1) {
                nativeSmoke(URL(fileURLWithPath:CommandLine.arguments[index+1]))
            }
        } catch { let alert = NSAlert();alert.messageText = "无法加载 Cutout 角色";alert.informativeText = String(describing:error);alert.runModal() }
    }
    func windowWillClose(_ notification:Notification) {
        canvas?.stop();window = nil;state = nil
    }
    func windowDidMiniaturize(_ notification:Notification) { canvas?.stop() }
    func windowDidDeminiaturize(_ notification:Notification) { canvas?.update() }

    /// Opt-in isolated native run, driven through the same methods as controls.
    /// Records process/window identity and real draw counters. It never changes
    /// daily settings or claims an offscreen bitmap is a screen capture.
    private func nativeSmoke(_ directory:URL) {
        if CommandLine.arguments.contains("--cutout-playback-smoke") || CommandLine.arguments.contains("--cutout-wardrobe-smoke") {
            playbackSmoke(directory); return
        }
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        // This opt-in fixture must remain visible while measuring playback.
        // Other ordinary windows can cover a newly launched same-bundle instance.
        // Real occlusion checks remain active; minimize/hide still stop its timer.
        window?.level = .floating
        window?.orderFrontRegardless()
        let start = ProcessInfo.processInfo.systemUptime
        let candidate = state?.candidatePath != nil
        let facialCandidate=state?.artwork.rig.eyeClips?.isEmpty == false && state?.hasMouth == true
        let thinkingCandidate=state?.artwork.player.clips.contains{$0.definition.id == "thinking"} == true
        let classicCandidate=state?.artwork.player.clips.contains{$0.definition.id == "thinking-classic"} == true
        if facialCandidate {state?.gazeMode="scan";state?.mouthMode="talk"}
        let initialSelection = state?.artwork.selection ?? [:]
        let variants = state?.artwork.rig.variants ?? []
        var alternateSelection = initialSelection
        if candidate {
            for category in ["clothes","hair"] {
                if let filled = variants.first(where: { $0.category == category && $0.id != initialSelection[category] && !$0.attachments.isEmpty }) {
                    alternateSelection[category] = filled.id
                } else if let empty = variants.first(where: { $0.category == category && $0.attachments.isEmpty }) {
                    alternateSelection[category] = empty.id
                }
            }
            if let empty = variants.first(where: { $0.category == "headwear" && $0.attachments.isEmpty }) {
                alternateSelection["headwear"] = empty.id
            }
        } else {
            alternateSelection.merge(["clothes":"clothes-claude","headwear":"headwear-claude","hair":"hair-claude"]) { _,next in next }
        }
        var componentSelection = alternateSelection
        if candidate {
            for category in ["tail","hair"] {
                if let empty = variants.first(where: { $0.category == category && $0.attachments.isEmpty }) {
                    componentSelection[category] = empty.id
                }
            }
        } else {componentSelection.merge(["tail":"no-tail","wings":"fin-wings"]) { _,next in next }}
        let alternateAction = candidate ? "tail-wag":"step"
        let resumedAction = thinkingCandidate ? "thinking" : (candidate ? "head-sway":"wave")
        var rows = [[String:Any]]()
        let identity:[String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleURL.path]
        if let data = try? JSONSerialization.data(withJSONObject:identity,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:directory.appendingPathComponent("session.json"))
        }
        func record(_ label:String) {
            guard let state = self.state, let canvas = self.canvas, let window = self.window else { return }
            var usage = rusage();getrusage(RUSAGE_SELF,&usage)
            let cpu = Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
            let rendered=state.artwork.displayBounds(anchor:CGPoint(x:canvas.bounds.midX,y:24),scale:state.scale,mirrored:state.mirrored)
            let face=state.faceInputs(at:state.clock)
            let player=state.artwork.player
            let head=player.indices["head"].map{player.world[$0]} ?? .identity
            let headRotation=atan2(head.b,head.a)*180 / Double.pi
            let torso=player.indices["torso"].map{player.world[$0]} ?? .identity
            let torsoRotation=atan2(torso.b,torso.a)*180 / Double.pi
            var hairRelativeRotation=0.0,hairRootError=0.0
            if let hairIndex=player.indices["hair-back"],let headIndex=player.indices["head"] {
                let hair=player.world[hairIndex]
                hairRelativeRotation=atan2(hair.b,hair.a)*180 / Double.pi-headRotation
                let localRoot=CGPoint(x:player.bindWorld[hairIndex].x-player.bindWorld[headIndex].x,
                                      y:player.bindWorld[hairIndex].y-player.bindWorld[headIndex].y)
                let expected=localRoot.applying(head)
                hairRootError=hypot(hair.tx-expected.x,hair.ty-expected.y)
            }
            let fixedBoneIDs=["root","tail"]
            let fixedBodyError=fixedBoneIDs.compactMap{player.indices[$0]}.reduce(0.0) { error,index in
                let pose=player.world[index],bind=player.bindWorld[index]
                return max(error,abs(pose.tx-bind.x),abs(pose.ty-bind.y),abs(pose.a-1),abs(pose.b))
            }
            var contactError=0.0
            if let constraint=state.artwork.rig.twoBoneConstraints?.first,
               let targetIndex=player.indices[constraint.targetBone],let endIndex=player.indices[constraint.end] {
                let bind=player.bindWorld[targetIndex],point=constraint.targetPoint
                let target=CGPoint(x:point[0]-bind.x,y:point[1]-bind.y).applying(player.world[targetIndex])
                let end=CGPoint.zero.applying(player.world[endIndex]);contactError=hypot(target.x-end.x,target.y-end.y)
            }
            rows.append(["label":label,"elapsed":ProcessInfo.processInfo.systemUptime-start,
                         "windowNumber":window.windowNumber,"visible":window.isVisible,"unoccluded":window.occlusionState.contains(.visible),
                         "nativeFixtureWindowLevel":window.level.rawValue,
                         "error":state.error ?? "","selection":state.artwork.selection,"action":state.action,"ticks":canvas.ticks,"redraws":canvas.redraws,
                         "timerActive":canvas.timerActive,"reads":state.artwork.resourceReads,"decodes":state.artwork.decodedImages,"compositeBuilds":state.artwork.compositeBuilds,
                         "decodedBytes":state.artwork.decodedBytes,"sampleSeconds":canvas.sampleSeconds,"drawSeconds":canvas.drawSeconds,"cpuSeconds":cpu,
                         "blink":face.blink,"mouth":face.mouth,"mouthShape":face.shape ?? "default","gaze":[face.gaze.x,face.gaze.y],"eyeMaskImagesBuilt":state.artwork.eyeMaskImagesBuilt,
                         "headRotation":headRotation,"wristContactError":contactError,
                         "torsoRotation":torsoRotation,"fixedBodyError":fixedBodyError,"clothPatchImagesBuilt":state.artwork.clothPatchImagesBuilt,
                         "hairRelativeRotation":hairRelativeRotation,"hairRootError":hairRootError,
                         "paintedArea":canvas.paintedArea,"canvasArea":canvas.bounds.width*canvas.bounds.height,
                         "scale":state.scale,"mirrored":state.mirrored,"withinCanvas":canvas.bounds.contains(rendered),
                         "renderWidth":rendered.width,"renderHeight":rendered.height])
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { record("ready") }
        DispatchQueue.main.asyncAfter(deadline:.now()+3) {
            record("initial-playing")
            for (category,id) in alternateSelection {self.state?.select(category,id)}
            self.state?.setAction(alternateAction)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+6) { record("alternate-playing");self.state?.setPlaying(false) }
        DispatchQueue.main.asyncAfter(deadline:.now()+7) { record("paused-start") }
        DispatchQueue.main.asyncAfter(deadline:.now()+9) {
            record("paused-end");self.state?.seek(0.25)
            for (category,id) in componentSelection {self.state?.select(category,id)}
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+10) {
            record("component-swap");self.state?.setPlaying(true);self.state?.setAction(resumedAction)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+13) {
            record("resumed")
            self.window?.miniaturize(nil)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+14) { record("minimized-start") }
        DispatchQueue.main.asyncAfter(deadline:.now()+16) {
            record("minimized-end");self.window?.deminiaturize(nil)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+18) {
            record("restored");NSApp.hide(nil)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+19) { record("hidden-start") }
        DispatchQueue.main.asyncAfter(deadline:.now()+21) {
            record("hidden-end");NSApp.unhide(nil);NSApp.activate(ignoringOtherApps:true);self.window?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+23) {
            record("unhidden")
            self.state?.setPlaying(false);self.canvas?.stop()
            for (category,id) in initialSelection {self.state?.select(category,id)}
            self.state?.setAction(self.state?.artwork.player.clips[0].definition.id ?? "idle")
            self.state?.seek(0)
            if facialCandidate {self.state?.eyeMode="manual";self.state?.blink=0;self.state?.mouthMode="neutral";self.state?.gazeMode="center"}
        }
        func capture(_ name:String) {
            guard let window=self.window else {return}
            let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            task.arguments=["-x","-o","-l",String(window.windowNumber),directory.appendingPathComponent(name+".png").path]
            do {try task.run();task.waitUntilExit()} catch {fputs("Native preview capture failed: \(error)\n",stderr)}
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+24) {self.state?.setScale(0.5);self.canvas?.update()}
        DispatchQueue.main.asyncAfter(deadline:.now()+25) {record("scale-half");capture("scale-half")}
        DispatchQueue.main.asyncAfter(deadline:.now()+26) {self.state?.mirrored=true;self.state?.setScale(1);self.canvas?.update()}
        DispatchQueue.main.asyncAfter(deadline:.now()+27) {record("scale-normal-mirror");capture("scale-normal-mirror")}
        DispatchQueue.main.asyncAfter(deadline:.now()+28) {self.state?.mirrored=false;self.state?.setScale(2);self.canvas?.update()}
        DispatchQueue.main.asyncAfter(deadline:.now()+29) {record("scale-double");capture("scale-double")}
        DispatchQueue.main.asyncAfter(deadline:.now()+30) {
            let report:[String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleURL.path,
                "candidatePath":self.state?.candidatePath ?? "","binary":Bundle.main.executableURL?.path ?? "","observations":rows,
                "expectedAlternateSelection":alternateSelection,"expectedComponentSelection":componentSelection,
                "expectedAlternateAction":alternateAction,"expectedResumedAction":resumedAction,
                "secondCostumeCovered":alternateSelection["clothes"] != initialSelection["clothes"],
                "secondHairstyleCovered":alternateSelection["hair"] != initialSelection["hair"] && variants.contains(where:{$0.id == alternateSelection["hair"] && !$0.attachments.isEmpty}),
                "boundary":"Native studio; desktop-caption/window-interaction migration is separate."]
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:directory.appendingPathComponent("native.json")) }
            self.state?.setScale(1);self.canvas?.update()
        }
        if facialCandidate {
            DispatchQueue.main.asyncAfter(deadline:.now()+31) {
                self.state?.setScale(2);self.state?.eyeMode="manual";self.state?.blink=0.5
                self.state?.mouthMode="manual";self.state?.mouth=0.5;self.state?.gazeMode="right";self.canvas?.update()
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+32) {record("face-half");capture("face-half")}
            DispatchQueue.main.asyncAfter(deadline:.now()+33) {
                self.state?.blink=1;self.state?.mouth=1;self.state?.gazeMode="left";self.canvas?.update()
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+34) {record("face-closed-open-mouth");capture("face-closed-open-mouth")}
            DispatchQueue.main.asyncAfter(deadline:.now()+35) {
                self.state?.blink=0;self.state?.mouthMode="neutral";self.state?.gazeMode="center";self.state?.setScale(1);self.canvas?.update()
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+35.5) {
                record("face-restored")
                let report:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"candidatePath":self.state?.candidatePath ?? "",
                    "observations":rows.filter{["scale-double","face-half","face-closed-open-mouth","face-restored"].contains($0["label"] as? String ?? "")},
                    "realAudioLipSyncCovered":false]
                if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:directory.appendingPathComponent("facial.json"))}
                self.state?.eyeMode="auto";self.canvas?.update()
            }
        }
        if thinkingCandidate {
            DispatchQueue.main.asyncAfter(deadline:.now()+36) {
                self.state?.setAction("thinking");self.state?.seek(1.6/8)
                self.state?.setScale(2);self.state?.eyeMode="manual";self.state?.blink=0
                self.state?.mouthMode="neutral";self.state?.gazeMode="center";self.canvas?.update()
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+37) {record("thinking-positive");capture("thinking-positive")}
            DispatchQueue.main.asyncAfter(deadline:.now()+38) {self.state?.seek(5.9/8);self.canvas?.update()}
            DispatchQueue.main.asyncAfter(deadline:.now()+39) {record("thinking-negative");capture("thinking-negative")}
            DispatchQueue.main.asyncAfter(deadline:.now()+40) {self.state?.seek(0);self.canvas?.update()}
            DispatchQueue.main.asyncAfter(deadline:.now()+41) {record("thinking-neutral");capture("thinking-neutral")}
            DispatchQueue.main.asyncAfter(deadline:.now()+42) {
                let report:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"candidatePath":self.state?.candidatePath ?? "",
                    "observations":rows.filter{["thinking-positive","thinking-negative","thinking-neutral"].contains($0["label"] as? String ?? "")}]
                if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:directory.appendingPathComponent("thinking.json"))}
                self.state?.setScale(1);self.state?.eyeMode="auto";self.state?.setPlaying(true);self.canvas?.update()
            }
        }
        if classicCandidate {
            DispatchQueue.main.asyncAfter(deadline:.now()+44) {
                self.state?.setAction("thinking-classic");self.state?.eyeMode="auto"
                self.state?.mouthMode="neutral";self.state?.gazeMode="center"
                self.state?.setScale(2);self.state?.seek(1.20/2.88)
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+45) {record("classic-tilt");capture("classic-tilt")}
            DispatchQueue.main.asyncAfter(deadline:.now()+46) {self.state?.seek(1.48/2.88)}
            DispatchQueue.main.asyncAfter(deadline:.now()+47) {record("classic-half");capture("classic-half")}
            DispatchQueue.main.asyncAfter(deadline:.now()+48) {self.state?.seek(1.65/2.88)}
            DispatchQueue.main.asyncAfter(deadline:.now()+49) {record("classic-closed");capture("classic-closed")}
            DispatchQueue.main.asyncAfter(deadline:.now()+50) {self.state?.seek(0)}
            DispatchQueue.main.asyncAfter(deadline:.now()+51) {record("classic-neutral");capture("classic-neutral")}
            DispatchQueue.main.asyncAfter(deadline:.now()+52) {
                self.state?.setScale(1);self.state?.seek(0);self.state?.setPlaying(true)
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+53) {record("classic-playing-start")}
            DispatchQueue.main.asyncAfter(deadline:.now()+56) {record("classic-playing-end")}
            DispatchQueue.main.asyncAfter(deadline:.now()+57) {
                let report:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,
                    "candidatePath":self.state?.candidatePath ?? "", "duration":self.state?.duration ?? 0,
                    "observations":rows.filter{($0["label"] as? String ?? "").hasPrefix("classic-")}]
                if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:directory.appendingPathComponent("classic-thinking.json"))}
            }
        }
        if let shapes = state?.artwork.rig.mouthShapes, !shapes.isEmpty {
            for (i,shape) in shapes.enumerated() {
                let time=58+Double(i)*1.2
                DispatchQueue.main.asyncAfter(deadline:.now()+time) {
                    self.state?.seek(1.2/2.88);self.state?.setScale(2)
                    self.state?.mouthMode="manual";self.state?.mouth=1;self.state?.mouthShape=shape.id
                    self.canvas?.update()
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+time+0.6) {
                    record("mouth-shape-"+shape.id);capture("mouth-shape-"+shape.id)
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+68) {
                let report:[String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,
                    "candidatePath":self.state?.candidatePath ?? "",
                    "observations":rows.filter{($0["label"] as? String ?? "").hasPrefix("mouth-shape-")}]
                if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
                    try? data.write(to:directory.appendingPathComponent("mouth-shapes.json"))
                }
                self.state?.mouthMode="cycle";self.state?.mouthShape="default";self.state?.setScale(1)
                self.state?.setPlaying(true);self.canvas?.update()
            }
        }
    }

    /// Isolated real-window acceptance for the configurable playback contract.
    private func playbackSmoke(_ directory:URL) {
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        window?.level = .floating; window?.orderFrontRegardless()
        var rows = [[String:Any]]()
        func record(_ label:String,_ phasePreserved:Bool?=nil) {
            guard let state=self.state,let canvas=self.canvas,let window=self.window else {return}
            let art=state.artwork,player=art.player
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            let cpu=Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
            let bounds=art.motionBounds(anchor:CGPoint(x:canvas.bounds.midX,y:24),scale:state.scale)
            var row:[String:Any] = ["label":label,"clock":state.clock,"pid":ProcessInfo.processInfo.processIdentifier,
                "bundle":Bundle.main.bundleURL.path,"visible":window.isVisible,"unoccluded":window.occlusionState.contains(.visible),
                "activeClip":player.clips[player.clipIndex].definition.id,"clipStartedAt":player.startedAt,
                "duration":player.clips[player.clipIndex].duration,"timerActive":canvas.timerActive,"ticks":canvas.ticks,"draws":canvas.redraws,
                "resourceReads":art.resourceReads,"decodedImages":art.decodedImages,"decodedBytes":art.decodedBytes,
                "decodedByteLimit":art.rig.cacheByteLimit,"peakResidentDecodedBytes":art.peakResidentDecodedBytes,"releasedDecodedBytes":art.releasedDecodedBytes,
                "cpuSeconds":cpu,"drawSeconds":canvas.drawSeconds,"hair":art.selection["hair"] ?? "",
                "clothes":art.selection["clothes"] ?? "","headwear":art.selection["headwear"] ?? "",
                "crop":[bounds.minX,bounds.minY,bounds.width,bounds.height],"withinCanvas":canvas.bounds.contains(bounds),"error":state.error ?? ""]
            if let phasePreserved {row["swapPhasePreserved"]=phasePreserved}
            rows.append(row)
            if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:directory.appendingPathComponent("observations.json"),options:.atomic)
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {record("default-action")}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
            self.state?.setAction("tail-wag-once"); self.canvas?.update(); record("start")
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5) {record("one-shot")}
        DispatchQueue.main.asyncAfter(deadline:.now()+3) {
            record("fallback"); self.state?.select("hair","hair-style-high-twin-no-side-locks")
            self.state?.setAction("thinking-classic");self.canvas?.update()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+5) {record("hair-playing");self.state?.setPlaying(false);self.canvas?.update()}
        DispatchQueue.main.asyncAfter(deadline:.now()+5.5) {record("paused-start")}
        DispatchQueue.main.asyncAfter(deadline:.now()+7.5) {
            record("paused-end");self.state?.select("hair","hair-original")
            self.state?.setPlaying(true);self.canvas?.update()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+9) {record("resumed");self.window?.miniaturize(nil)}
        DispatchQueue.main.asyncAfter(deadline:.now()+9.5) {record("hidden-start")}
        DispatchQueue.main.asyncAfter(deadline:.now()+11.5) {
            record("hidden-end"); self.window?.deminiaturize(nil);self.canvas?.update()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+13) {record("restored")}
        if CommandLine.arguments.contains("--cutout-wardrobe-smoke") {
            func change(_ category:String,_ value:String,_ label:String) {
                guard let state=self.state else {return}
                let player=state.artwork.player,pose=player.world,started=player.startedAt,clip=player.clipIndex
                state.select(category,value);self.canvas?.update()
                record(label,pose==player.world && started==player.startedAt && clip==player.clipIndex)
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+3.5) {change("clothes","clothes-original","maid-swap")}
            DispatchQueue.main.asyncAfter(deadline:.now()+4.2) {change("clothes","clothes-claude-code","workwear-swap")}
            DispatchQueue.main.asyncAfter(deadline:.now()+7.8) {change("hair","hair-style-low-twin-tied-v6-no-side-locks","workwear-low-twin")}
        }
    }
}
