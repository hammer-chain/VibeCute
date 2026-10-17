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
    var original: OverlayController? { overlays.character(for: .codex) }
    var cutout: OverlayController? { overlays.character(for: .deepseek) }
    private let bindings: [CaptionMascot: CharacterChoice] = [.codex: .deepseek, .deepseek: .deepseekCutout]

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); refresh(); return }
        previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 440,height: 154),
            styleMask: [.titled,.closable,.miniaturizable],backing: .buffered,defer: false)
        window.title = "DeepSeek 两版对比"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: CutoutComparisonControls(controller: self))
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
        refresh(); NSApp.activate(ignoringOtherApps: true)
        if let area = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: area.midX-window.frame.width/2, y:area.minY+530))
        }
        runSmokeIfRequested()
        runHairstyleSmokeIfRequested()
    }
    private func refresh(visible: Bool = true) {
        guard let window else { return }
        let visible = visible && window.isVisible && !window.isMiniaturized
        let items = visible ? [
            OverlayItem(id:"cutout-comparison-original",text:"原逐帧版",header:"DeepSeek · 原逐帧",title:"原逐帧版",active:true,mascot:.codex),
            OverlayItem(id:"cutout-comparison-layered",text:motion == "thinking-classic" ? "Cutout · 原版节奏" : "Cutout · 发梢轻摆",
                        header:"DeepSeek · Cutout",title:"Cutout 版",active:true,mascot:.deepseek)
        ] : []
        overlays.update(items,font:16,opacity:0.72,bottom:80,screenIndex:0,movable:true,
            focusedID:"cutout-comparison-original",characterScale:scale,characterBindings:bindings,
            cutoutHair:[.deepseek:hair])
        cutout?.subtitle.cutoutRenderer?.setThinkingClip(motion)
    }
    func windowWillClose(_ notification: Notification) {
        refresh(visible:false); window = nil
        if let previousActivationPolicy { NSApp.setActivationPolicy(previousActivationPolicy) }
        previousActivationPolicy = nil
    }
    func windowDidMiniaturize(_ notification: Notification) { refresh(visible:false) }
    func windowDidDeminiaturize(_ notification: Notification) { refresh() }

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
        }.padding(16).frame(width:440)
    }
}
