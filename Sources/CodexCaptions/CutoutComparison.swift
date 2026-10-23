import AppKit
import SwiftUI
import Darwin

/// Uses the normal source-to-character binding and separate caption/character
/// windows. Comparison has no saved positions and never alters daily bindings.
final class CutoutComparisonController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = CutoutComparisonController()
    private var window: NSWindow?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private let overlays = ProjectOverlays()
    @Published var scale = 1.0 { didSet { refresh() } }
    @Published var motion = "thinking-classic" { didSet { refresh() } }
    @Published var hair = "hair-original" { didSet { refresh() } }
    var hairstyles:[CutoutRig.Variant] {
        MascotAnimation.cutoutCharacter.cutout!.variants.filter { $0.category == "hair" && $0.id != "hair-none" }
    }
    private(set) var smokeRows = [[String: Any]]()
    private var rhythmTimer: Timer?
    private var dragTimer: Timer?
    private var replayGeneration=0
    var original: OverlayController? { overlays.character(for: .codex) }
    var cutout: OverlayController? { overlays.character(for: .deepseek) }
    private let bindings: [CaptionMascot: CharacterChoice] = [.codex: .deepseek, .deepseek: .deepseekCutout]

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); refresh(); return }
        previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 440,height: 184),
            styleMask: [.titled,.closable,.miniaturizable],backing: .buffered,defer: false)
        window.title = "DeepSeek 两版对比"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: CutoutComparisonControls(controller: self))
        self.window = window
        overlays.onCharacterDragStarted = { [weak self] _ in self?.startDragUpdates() }
        window.center(); window.makeKeyAndOrderFront(nil)
        replay(); NSApp.activate(ignoringOtherApps: true)
        if let area = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: area.midX-window.frame.width/2, y:area.minY+530))
        }
        runSmokeIfRequested()
        runHairstyleSmokeIfRequested()
        runRhythmSmokeIfRequested()
        runDragSmokeIfRequested()
    }
    /// This controller owns its overlays independently of AppModel's refresh.
    /// Keep the interaction clock only until the drag and landing have finished.
    private func startDragUpdates() {
        guard dragTimer == nil else { return }
        let timer=Timer(timeInterval:1/60,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.overlays.finishReleasedCharacterDrags()
            self.overlays.updateDragReactions(at:ProcessInfo.processInfo.systemUptime)
            let interacting=[self.original,self.cutout].compactMap { $0 }.contains {
                $0.panel.isManuallyDragging || $0.subtitle.dragReaction.active
            }
            if !interacting {
                self.dragTimer?.invalidate();self.dragTimer=nil
                // The normal pixel landing returns to frame zero. Restart the
                // comparison together instead of leaving it out of phase.
                self.replay()
            }
        }
        dragTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func replay() {
        // Prepare both renderers before either starts. Initial Cutout decoding
        // must not consume the pixel preview's first 100 ms of playback.
        refresh(active:false)
        replayGeneration+=1;let generation=replayGeneration
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [weak self] in
            guard let self,self.replayGeneration==generation,self.window?.isVisible==true else {return}
            self.refresh()
        }
    }
    private func refresh(visible: Bool = true, active: Bool = true) {
        guard let window else { return }
        let visible = visible && window.isVisible && !window.isMiniaturized
        let items = visible ? [
            OverlayItem(id:"cutout-comparison-original",text:"原逐帧版",header:"DeepSeek · 原逐帧",title:"原逐帧版",active:active,mascot:.codex),
            OverlayItem(id:"cutout-comparison-layered",text:motion == "thinking-classic" ? "Cutout · 原版节奏" : "Cutout · 发梢轻摆",
                        header:"DeepSeek · Cutout",title:"Cutout 版",active:active,mascot:.deepseek)
        ] : []
        overlays.update(items,font:16,opacity:0.72,bottom:80,screenIndex:0,movable:true,
            focusedID:"cutout-comparison-original",characterScale:scale,characterBindings:bindings,
            cutoutHair:[.deepseek:hair])
        cutout?.subtitle.cutoutRenderer?.setThinkingClip(motion)
    }
    func windowWillClose(_ notification: Notification) {
        rhythmTimer?.invalidate();rhythmTimer=nil
        dragTimer?.invalidate();dragTimer=nil
        replayGeneration+=1
        refresh(visible:false); window = nil
        if let previousActivationPolicy { NSApp.setActivationPolicy(previousActivationPolicy) }
        previousActivationPolicy = nil
    }
    func windowDidMiniaturize(_ notification: Notification) { refresh(visible:false) }
    func windowDidDeminiaturize(_ notification: Notification) { refresh() }

    /// Exercise the actual panel callbacks and common-mode interaction timer.
    /// No synthetic mouse events or replacement animation clock are used.
    private func runDragSmokeIfRequested() {
        let args=CommandLine.arguments
        guard let i=args.firstIndex(of:"--cutout-drag-smoke-out"),i+1<args.count else {return}
        let out=URL(fileURLWithPath:args[i+1])
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var rows=[[String:Any]]()
        func record(_ stage:String) {
            guard let original=self.original,let renderer=self.cutout?.subtitle.cutoutRenderer else {return}
            let row:[String:Any]=["stage":stage,"time":ProcessInfo.processInfo.systemUptime,
                "manualDragging":original.panel.isManuallyDragging,
                "dragActive":original.subtitle.dragReaction.active,
                "dragFrame":original.subtitle.dragReaction.frameIndex ?? -1,
                "interactionTimer":self.dragTimer != nil,"originalAnimating":original.subtitle.mascotAnimating,
                "originalFrame":original.subtitle.mascotFrameIndex,
                "cutoutFrame":renderer.sampledReferenceFrame ?? -1,"cutoutTicks":renderer.diagnostics["ticks"] ?? 0]
            rows.append(row)
            let report:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleURL.path,
                "input":"panel begin/move/release callbacks","rows":rows]
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:out.appendingPathComponent("runtime.json"),options:.atomic)
            }
        }
        func at(_ t:Double,_ action:@escaping()->Void) {DispatchQueue.main.asyncAfter(deadline:.now()+t,execute:action)}
        at(1) {
            record("before")
            guard let panel=self.original?.panel else {return}
            panel.beginManualDrag()
            panel.setFrameOrigin(NSPoint(x:panel.frame.minX+40,y:panel.frame.minY+20))
            record("began")
        }
        // Physical button state is up in this callback fixture. The interaction
        // timer must discover that release itself, as after performDrag.
        at(1.3) {record("released-and-landing")}
        for index in 0..<12 {at(2.6+Double(index)*0.16) {record("resumed-\(index)")}}
        at(4.6) {record("final")}
    }

    /// Read the two real renderers; no synthetic clock drives either side.
    private func runRhythmSmokeIfRequested() {
        let args=CommandLine.arguments
        guard let i=args.firstIndex(of:"--cutout-rhythm-smoke-out"),i+1<args.count else {return}
        let out=URL(fileURLWithPath:args[i+1])
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        window?.level = .floating;window?.orderFrontRegardless()
        let start=ProcessInfo.processInfo.systemUptime
        var originalEvents=[[String:Any]](),cutoutEvents=[[String:Any]]()
        var previousOriginal = -1,previousCutout = -1
        var samples=0,mismatches=0
        var maxUprightHeadError=0.0,hairMinimum=0.0,hairMaximum=0.0,hairRecoverySamples=0
        let timer=Timer(timeInterval:1/120,repeats:true) { [weak self] timer in
            guard let self,let original=self.original?.subtitle,let renderer=self.cutout?.subtitle.cutoutRenderer else {return}
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            let frame=original.mascotFrameIndex,cutoutFrame=renderer.sampledReferenceFrame ?? -1
            if cutoutFrame>=4,let h=renderer.artwork.player.indices["head"],let driver=renderer.artwork.player.indices["hair-return"] {
                let player=renderer.artwork.player,head=player.world[h],bind=player.bindWorld[h]
                maxUprightHeadError=max(maxUprightHeadError,abs(head.a-1),abs(head.b),abs(head.c),abs(head.d-1),abs(head.tx-bind.x),abs(head.ty-bind.y))
                let amount=player.local[driver].x
                hairMinimum=min(hairMinimum,amount);hairMaximum=max(hairMaximum,amount);hairRecoverySamples+=1
            }
            if frame != previousOriginal {originalEvents.append(["time":elapsed,"frame":frame]);previousOriginal=frame}
            if cutoutFrame != previousCutout {cutoutEvents.append(["time":elapsed,"frame":cutoutFrame]);previousCutout=cutoutFrame}
            samples+=1;if frame != cutoutFrame {mismatches+=1}
            if elapsed>=18 {
                timer.invalidate();self.rhythmTimer=nil
                let report:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleURL.path,
                    "originalEvents":originalEvents,"cutoutEvents":cutoutEvents,"samples":samples,"mismatchedSamples":mismatches,
                    "diagnostics":renderer.diagnostics,"originalFrame":frame,
                    "maxUprightHeadError":maxUprightHeadError,"hairMinimum":hairMinimum,"hairMaximum":hairMaximum,"hairRecoverySamples":hairRecoverySamples,
                    "originalWindow":self.original?.panel.windowNumber ?? 0,"cutoutWindow":self.cutout?.panel.windowNumber ?? 0]
                if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
                    try? data.write(to:out.appendingPathComponent("runtime.json"),options:.atomic)
                }
                try? self.original?.exportPreview(to:out.appendingPathComponent("original.png"))
                try? self.cutout?.exportPreview(to:out.appendingPathComponent("cutout.png"))
            }
        }
        rhythmTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }

    /// Opt-in native fixture: both actual app bindings, renderer diagnostics,
    /// scale changes, mouth input, minimize/resume and app hide/resume.
    private func runSmokeIfRequested() {
        let args=CommandLine.arguments
        guard let i=args.firstIndex(of:"--cutout-app-smoke-out"), i+1<args.count, smokeRows.isEmpty else { return }
        let folder=URL(fileURLWithPath:args[i+1])
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let identity:[String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleURL.path,
            "arguments":args,"originalWindow":original?.panel.windowNumber ?? 0,"cutoutWindow":cutout?.panel.windowNumber ?? 0,
            "controlWindow":window?.windowNumber ?? 0]
        if let data=try? JSONSerialization.data(withJSONObject:identity,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:folder.appendingPathComponent("session.json"),options:.atomic)
        }
        func at(_ time:Double,_ body:@escaping()->Void) { DispatchQueue.main.asyncAfter(deadline:.now()+time,execute:body) }
        func record(_ name:String) {
            var row=cutout?.subtitle.cutoutRenderer?.diagnostics ?? [:]
            row["running"] = cutout?.subtitle.cutoutRenderer?.running ?? false
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            row["processCPUSeconds"] = Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1e6
                + Double(usage.ru_stime.tv_sec)+Double(usage.ru_stime.tv_usec)/1e6
            row["uptime"] = ProcessInfo.processInfo.systemUptime
            row["peakRSSBytes"] = usage.ru_maxrss
            row["stage"]=name;row["scale"]=scale
            row["applicationHidden"] = NSApp.isHidden
            row["controlMiniaturized"] = window?.isMiniaturized ?? false
            row["activationPolicy"] = NSApp.activationPolicy().rawValue
            row["originalArtwork"]=original?.subtitle.mascotArtwork
            row["cutoutArtwork"]=cutout?.subtitle.mascotArtwork
            row["originalVisible"]=original?.panel.isVisible
            row["cutoutVisible"]=cutout?.panel.isVisible
            row["choiceRegistered"]=CharacterChoice.allCases.contains(.deepseekCutout)
            smokeRows.append(row)
            if let data=try? JSONSerialization.data(withJSONObject:smokeRows,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:folder.appendingPathComponent("runtime.json"),options:.atomic)
            }
        }
        at(1) { record("classic-start") }
        at(6) { record("classic-end");try? self.original?.exportPreview(to:folder.appendingPathComponent("original-100.png"));try? self.cutout?.exportPreview(to:folder.appendingPathComponent("cutout-100.png"));self.scale=2 }
        at(8) { record("200-percent");try? self.original?.exportPreview(to:folder.appendingPathComponent("original-200.png"));try? self.cutout?.exportPreview(to:folder.appendingPathComponent("cutout-200.png"));self.motion="thinking" }
        at(11) { record("modern"); self.cutout?.subtitle.setAudioMouth(1) }
        at(11.6) { record("mouth-closed"); self.cutout?.subtitle.setAudioMouth(2) }
        at(12) { record("mouth-open");try? self.cutout?.exportPreview(to:folder.appendingPathComponent("mouth-open.png"));self.cutout?.subtitle.setAudioMouth(nil);self.window?.miniaturize(nil) }
        at(13) { record("minimized-start") }
        at(15) { record("minimized-end");self.window?.deminiaturize(nil);self.scale=1;self.motion="thinking-classic" }
        at(17) { record("resumed");NSApp.hide(nil) }
        at(18) { record("hidden-start") }
        at(20) { record("hidden-end");NSApp.unhide(nil);self.window?.makeKeyAndOrderFront(nil) }
        at(22) { record("unhidden"); self.motion="thinking" }
        at(23) { record("final");try? self.original?.exportPreview(to:folder.appendingPathComponent("original-final.png"));try? self.cutout?.exportPreview(to:folder.appendingPathComponent("cutout-final.png")) }
        if MascotAnimation.cutoutCharacter.cutoutPlayback?.mouthShapeIDs != nil {
            for index in 0..<12 {
                at(24+Double(index)*0.35) {
                    self.cutout?.subtitle.setAudioMouth(index);record("mouth-input-\(index)")
                    try? self.cutout?.exportPreview(to:folder.appendingPathComponent("mouth-input-\(index).png"))
                }
            }
            at(28.5) { self.cutout?.subtitle.setAudioMouth(nil);record("mouth-input-reset") }
        }
    }

    private func runHairstyleSmokeIfRequested() {
        let args=CommandLine.arguments
        guard let i=args.firstIndex(of:"--cutout-hairstyles-smoke-out"),i+1<args.count else {return}
        let folder=URL(fileURLWithPath:args[i+1])
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let session:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleURL.path,
            "arguments":args,"styles":hairstyles.map(\.id),"controlWindow":window?.windowNumber ?? 0]
        if let data=try? JSONSerialization.data(withJSONObject:session,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:folder.appendingPathComponent("session.json"),options:.atomic)
        }
        var rows=[[String:Any]]()
        func at(_ t:Double,_ action:@escaping()->Void) {DispatchQueue.main.asyncAfter(deadline:.now()+t,execute:action)}
        func record(_ stage:String,_ phasePreserved:Bool?=nil) {
            var row=self.cutout?.subtitle.cutoutRenderer?.diagnostics ?? ["running":false,"ticks":0]
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            row["stage"]=stage;row["scale"]=self.scale;row["uptime"]=ProcessInfo.processInfo.systemUptime
            row["processCPUSeconds"]=Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1e6
                + Double(usage.ru_stime.tv_sec)+Double(usage.ru_stime.tv_usec)/1e6
            row["originalVisible"]=self.original?.panel.isVisible ?? false
            row["cutoutVisible"]=self.cutout?.panel.isVisible ?? false
            row["applicationHidden"]=NSApp.isHidden
            row["windowSize"]=[self.cutout?.panel.frame.width ?? 0,self.cutout?.panel.frame.height ?? 0]
            if let phasePreserved {row["swapPhasePreserved"]=phasePreserved}
            rows.append(row)
            if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:folder.appendingPathComponent("runtime.json"),options:.atomic)
            }
        }
        for (index,style) in hairstyles.enumerated() {
            let t=1+Double(index)*2
            at(t) {
                self.motion=index%2==0 ? "thinking-classic":"thinking"
                guard let player=self.cutout?.subtitle.cutoutRenderer?.artwork.player else {return}
                let pose=player.world,started=player.startedAt,clip=player.clipIndex
                self.hair=style.id
                record(style.id+"-start",pose==player.world && started==player.startedAt && clip==player.clipIndex)
            }
            at(t+0.8) {
                record(style.id+"-end")
                try? self.cutout?.exportPreview(to:folder.appendingPathComponent(style.id+"-100.png"))
                self.scale=2
                try? self.cutout?.exportPreview(to:folder.appendingPathComponent(style.id+"-200.png"))
                self.scale=0.5
                try? self.cutout?.exportPreview(to:folder.appendingPathComponent(style.id+"-50.png"))
                self.scale=1
            }
        }
        let end=1+Double(hairstyles.count)*2
        at(end) {self.window?.miniaturize(nil)}
        at(end+1) {record("minimized-start")}
        at(end+3) {record("minimized-end");self.window?.deminiaturize(nil)}
        at(end+5) {record("resumed");NSApp.hide(nil)}
        at(end+6) {record("hidden-start")}
        at(end+8) {record("hidden-end");NSApp.unhide(nil);self.window?.makeKeyAndOrderFront(nil)}
        at(end+10) {record("unhidden");self.hair="hair-style-high-twin-no-side-locks"}
        at(end+11) {record("final")}
    }
}

private struct CutoutComparisonControls: View {
    @ObservedObject var controller: CutoutComparisonController
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("Cutout 发型",selection:$controller.hair) {
                ForEach(controller.hairstyles,id:\.id) { Text($0.title).tag($0.id) }
            }
            Picker("Cutout 思考",selection:$controller.motion) {
                Text("原版节奏").tag("thinking-classic")
                Text("歪头 · 发梢轻摆").tag("thinking")
            }
            Picker("显示倍率",selection:$controller.scale) {
                Text("50%").tag(0.5);Text("100%").tag(1.0);Text("200%").tag(2.0)
            }.pickerStyle(.segmented)
            Button("重播") {controller.replay()}
        }.padding(16).frame(width:440)
    }
}
