import AppKit
@testable import CodexCaptions

@main
struct OrangeHoodieNativeChecks {
    static func main() throws {
        func require(_ value: Bool, _ message: String = "Native state check failed") throws {
            if !value { throw NSError(domain:"OrangeHoodieNativeChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let panel = NSPanel(contentRect:NSRect(x:400,y:350,width:300,height:240),styleMask:.borderless,
                            backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false
        let view = SubtitleView(frame:NSRect(x:0,y:0,width:300,height:240))
        view.mode = .character
        panel.contentView = view
        panel.orderFrontRegardless()
        view.setMascot(.orangeHoodie,animating:true)
        view.setAudioMouth(2)
        view.setMascot(.orangeHoodie,animating:true)
        try require(view.audioMouthIndex == 2, "Refreshing the binding must preserve the current mouth")
        try require(view.seatedGazeActive && view.mascotFrameCount == 8)
        let original = NSEvent.mouseLocation
        let height = CGDisplayBounds(CGMainDisplayID()).height
        func move(_ point: NSPoint) { CGWarpMouseCursorPosition(CGPoint(x:point.x,y:height-point.y)) }
        func settle() { let end = Date().addingTimeInterval(0.65); while Date() < end { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) } }
        defer { move(original); panel.orderOut(nil) }
        move(NSPoint(x:50,y:450)); settle()
        let left = view.seatedGazePosition
        move(NSPoint(x:1000,y:450)); settle()
        let right = view.seatedGazePosition
        try require(left.x < -0.5 && right.x > 0.5, "Native cursor must drive pupils in opposite directions")
        try require(view.audioMouthIndex == 2, "Gaze updates must not clear mouth")
        view.setAudioMouth(nil); settle()
        try require(view.seatedGazeActive && view.originalThinkingPoseActive)
        view.setMascot(.codex,animating:false)
        try require(!view.seatedGazeActive)
        view.setMascot(.orangeHoodie,animating:true); settle()
        try require(view.seatedGazeActive)
        print("PASS native window: cursor left/right \(left.x) / \(right.x), mouth survives refresh and gaze, thinking resumes, character switch restores gaze")
    }
}
