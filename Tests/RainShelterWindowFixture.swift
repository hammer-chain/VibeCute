import AppKit

@main struct RainShelterWindowFixture {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        guard let screen = NSScreen.screens.first else { fatalError("Graphical session required") }
        let a = screen.visibleFrame
        let wide = CommandLine.arguments.contains("--wide")
        let width = wide ? min(420,a.width-400) : 40
        let window = NSWindow(contentRect:NSRect(x:a.minX+(wide ? 380 : 24),y:a.minY+60,width:width,height:300),
            styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "VibeCute · 避雨验收"
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps:true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let front = windows.first {
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
            (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
        }?[kCGWindowNumber as String] as? NSNumber
        precondition(front?.intValue == window.windowNumber,"Fixture is not the actual foreground window; do not sample another app")
        let f = window.frame
        let report: [String:Any] = ["window":window.windowNumber,"foregroundWindowVerified":true,"width":width,
            "appKitFrame":["x":f.minX,"y":f.minY,"width":f.width,"height":f.height],
            "content":"test-owned blank fixture; no user window contents"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        RunLoop.main.run(until:Date().addingTimeInterval(90))
        window.close()
    }
}
