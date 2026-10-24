import AppKit
@testable import CodexCaptions

@main struct HybridThinkingNativeChecks {
    static func main() {
        _ = NSApplication.shared
        func pump(_ duration:Double) {
            let end=Date().addingTimeInterval(duration)
            while Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        }
        let view=SubtitleView(frame:NSRect(x:0,y:0,width:300,height:240))
        view.mode = .character
        view.setMascot(.hybridHoodie,animating:true)
        precondition(MascotAnimation.hybridHoodie.hybridThinking != nil)
        precondition(view.mascotAnimating && view.mascotFrameCount==8)
        pump(1.20)
        precondition(view.mascotFrameIndex==2,"Hybrid pixel body must follow the original beat clock")
        view.setMascot(.hybridHoodie,animating:false)
        precondition(view.mascotAnimating,"Stopping mid-turn must finish the return before idle")
        pump(1.82)
        precondition(!view.mascotAnimating && view.mascotFrameIndex==0)
        view.setMascot(.hybridHoodie,animating:true)
        precondition(view.mascotFrameIndex==0)
        pump(0.20)
        view.setMascot(.orangeHoodie,animating:true)
        pump(1.15)
        precondition(view.mascotFrameIndex==2)
        view.setMascot(.orangeHoodie,animating:false)
        precondition(!view.mascotAnimating,"Original pixel stop behavior must remain immediate")
        view.setMascot(.hybridHoodie,animating:true)
        pump(0.15)
        view.setMascot(.codex,animating:false)
        precondition(!view.mascotAnimating)
        print("PASS native playback: original body timing, finish-cycle return to idle, restart at entry, character switch, original pixel stop unchanged")
    }
}
