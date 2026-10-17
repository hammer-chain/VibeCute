import AppKit

private final class PerformanceDocument: NSView {
    var mode = "blank"
    override func draw(_ rect: NSRect) {
        NSColor(calibratedWhite:0.97,alpha:1).setFill(); bounds.fill()
        guard mode != "blank" else { return }
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.black]
        let end = mode == "middle" ? CGFloat(460) : bounds.width-24
        for y in stride(from:CGFloat(24),to:bounds.height-32,by:36) {
            for x in stride(from:CGFloat(24),to:end-90,by:126) {
                ("Read text" as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:attrs)
            }
        }
    }
}

@main struct BackdropPerformanceFixture {
    static func main() throws {
        func argument(_ name: String) -> String? {
            guard let i = CommandLine.arguments.firstIndex(of:name), i+1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[i+1]
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let screen = NSScreen.screens[0], frame = screen.frame
        let window = NSWindow(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.title = "自动避让性能测试 · 生成文档"
        window.level = .floating; window.isReleasedWhenClosed = false
        let view = PerformanceDocument(frame:NSRect(origin:.zero,size:frame.size))
        view.mode = argument("--mode") ?? "blank"; window.contentView = view
        window.orderFrontRegardless()
        let info: [String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,
            "frame":[frame.minX,frame.minY,frame.width,frame.height],
            "scale":screen.backingScaleFactor,
            "start":[frame.minX+100,frame.minY+180],
            "searchRegion":[frame.minX+20,frame.minY+100,frame.width-200,frame.height-400]]
        if let path = argument("--info") { try JSONSerialization.data(withJSONObject:info).write(to:URL(fileURLWithPath:path),options:.atomic) }
        let commands = argument("--commands")
        var previous = view.mode
        let timer = Timer(timeInterval:0.2,repeats:true) { _ in
            window.orderFrontRegardless()
            if let path = commands, let mode = try? String(contentsOfFile:path,encoding:.utf8), mode != previous {
                previous = mode; view.mode = mode; view.needsDisplay = true
            }
        }
        RunLoop.main.add(timer,forMode:.common); app.run()
    }
}
