#if !VIBECUTE_RELEASE
import AppKit
import SwiftUI

final class HybridHoodieStudioController {
    static let shared = HybridHoodieStudioController()
    private var window: NSWindow?
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Claude Code工服 · 混合分层"
        window.contentView = NSHostingView(rootView: HybridHoodieStudio())
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 550)
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct HybridHoodieStudio: View {
    @State private var playing = true
    @State private var phase = 0.0
    @State private var showBody = true
    @State private var head = true
    @State private var hair = true
    @State private var epoch = Date()
    var body: some View {
        VStack(spacing:12) {
            HStack {
                Button(playing ? "暂停" : "播放") {
                    if playing {phase=max(0,Date().timeIntervalSince(epoch)).truncatingRemainder(dividingBy:2.88)}
                    else {epoch=Date().addingTimeInterval(-phase)}
                    playing.toggle()
                }
                Slider(value:$phase,in:0...2.88).disabled(playing)
                Text(String(format:"%.2f s",phase)).monospacedDigit().opacity(playing ? 0:1)
                Toggle("身体",isOn:$showBody)
                Toggle("头部",isOn:$head)
                Toggle("头发",isOn:$hair)
            }
            TimelineView(.animation(minimumInterval:1/30,paused:!playing)) { timeline in
                let time=playing ? max(0,timeline.date.timeIntervalSince(epoch)):phase
                HStack {
                    VStack {Text("原版像素帧");HybridHoodiePreview(time:time,original:true,visible:[])}
                    VStack {Text("混合思考动画");HybridHoodiePreview(time:time,original:false,
                        visible:Set([(showBody ? HybridHoodieArtwork.Part.body:nil),
                                     (head ? .head:nil),(hair ? .hair:nil)].compactMap {$0}))}
                }
            }
        }.padding(16).frame(minWidth:650,minHeight:500)
    }
}

private struct HybridHoodiePreview:NSViewRepresentable {
    let time:Double
    let original:Bool
    let visible:Set<HybridHoodieArtwork.Part>
    func makeNSView(context:Context)->HybridHoodiePreviewView { HybridHoodiePreviewView() }
    func updateNSView(_ view:HybridHoodiePreviewView,context:Context) {
        view.time=time;view.original=original;view.visible=visible;view.needsDisplay=true
    }
}
private final class HybridHoodiePreviewView:NSView {
    var time=0.0
    var original=false
    var visible=Set(HybridHoodieArtwork.Part.allCases)
    override func draw(_ dirtyRect:NSRect) {
        NSColor(white:0.18,alpha:1).setFill();bounds.fill()
        let scale=min(bounds.width/384,bounds.height/512)
        let rect=NSRect(x:(bounds.width-384*scale)/2,y:(bounds.height-512*scale)/2,width:384*scale,height:512*scale)
        if original {
            let sequence=MascotAnimation.sequence
            let frame=sequence[Int(max(0,time)/0.16)%sequence.count]
            MascotAnimation.orangeHoodie.frames[frame].draw(in:rect)
        } else {MascotAnimation.hybridHoodie.hybridThinking?.draw(at:time,in:rect,visible:visible)}
    }
}
#endif
