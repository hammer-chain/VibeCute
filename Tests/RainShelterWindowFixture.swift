import AppKit

@main struct RainShelterWindowFixture {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { fatalError("Graphical session required") }
        let a = screen.visibleFrame
        let wide = CommandLine.arguments.contains("--wide")
        let width = wide ? min(420,a.width-400) : 40
        let window = NSWindow(contentRect:NSRect(x:a.minX+(wide ? 380 : 24),y:a.minY+60,width:width,height:300),
            styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "VibeCute · 避雨验收"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let f = window.frame
        let report: [String:Any] = ["window":window.windowNumber,"width":width,
            "appKitFrame":["x":f.minX,"y":f.minY,"width":f.width,"height":f.height],
            "content":"test-owned blank fixture; no user window contents"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        RunLoop.main.run(until:Date().addingTimeInterval(90))
        window.close()
    }
}
