import AppKit
private final class CrossBackdropView: NSView {
    var textured = false
    var localBlank = false
    override func draw(_ rect: NSRect) {
        NSColor(calibratedWhite:0.97,alpha:1).setFill(); bounds.fill()
        guard textured else { return }
        let end = localBlank ? bounds.width * 0.65 : bounds.width
        for y in stride(from:0,to:Int(bounds.height),by:12) {
            for x in stride(from:0,to:Int(end),by:12) {
                ((x+y)%24 == 0 ? NSColor.systemBlue : .systemOrange).setFill()
                NSRect(x:x,y:y,width:12,height:12).fill()
            }
        }
    }
}
@main struct CrossDisplayBackdropFixture {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let screens = NSScreen.screens
        guard screens.count >= 2 else { fatalError("Two physical displays required") }
        let source = Int(CommandLine.arguments[1])!
        var windows: [NSWindow] = []
        for (index,screen) in screens.enumerated() {
            let window = NSWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.level = .floating
            let view = CrossBackdropView(frame:NSRect(origin:.zero,size:screen.frame.size))
            view.textured = index == source
            view.localBlank = CommandLine.arguments.contains("--local-blank")
            window.contentView = view; window.orderFrontRegardless(); windows.append(window)
        }
        let s = screens[source]
        let info: [String:Any] = ["start":[s.frame.minX+220,s.frame.minY+240],"source":source,
            "screens":screens.map { ["id":($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value,"frame":[$0.frame.minX,$0.frame.minY,$0.frame.width,$0.frame.height]] as [String:Any] }]
        try JSONSerialization.data(withJSONObject:info).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        let commandIndex = CommandLine.arguments.firstIndex(of:"--commands")
        let commandPath = commandIndex.map { CommandLine.arguments[$0+1] }
        let end = ProcessInfo.processInfo.systemUptime+55
        let timer = Timer(timeInterval:0.5,repeats:true) { _ in
            if let path = commandPath, FileManager.default.fileExists(atPath:path) {
                for window in windows {
                    if let view = window.contentView as? CrossBackdropView, !view.textured {
                        view.textured = true; view.needsDisplay = true
                    }
                }
            }
            windows.forEach { $0.orderFrontRegardless() }
            if ProcessInfo.processInfo.systemUptime > end { app.terminate(nil) }
        }
        RunLoop.main.add(timer,forMode:.common); app.run()
    }
}
