import AppKit

private final class DocumentFixture: NSView {
    var mode = "near"
    override func draw(_ rect: NSRect) {
        NSColor(calibratedWhite:0.97,alpha:1).setFill(); bounds.fill()
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.black]
        switch mode {
        case "shape":
            NSColor.systemBlue.setFill(); NSRect(x:196,y:170,width:45,height:40).fill()
        case "near", "near-zh":
            ((mode == "near-zh" ? "文字" : "TEXT") as NSString).draw(at:NSPoint(x:196,y:180),withAttributes:attributes)
        case "middle", "middle-left", "far", "far-left", "shift":
            let leftBlank = mode == "far-left" || mode == "middle-left" || mode == "shift"
            let start: CGFloat = leftBlank ? (mode == "middle-left" ? bounds.width-430 : 310) : 25
            let end: CGFloat = leftBlank ? bounds.width-20 : (mode == "middle" ? 430 : bounds.width*0.66)
            for y in stride(from:CGFloat(22),to:bounds.height-20,by:28) {
                var x = start
                while x < end-60 {
                    ("Read text" as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:attributes)
                    x += 90
                }
            }
        case "texture":
            for y in stride(from:0,to:Int(bounds.height),by:8) { for x in stride(from:0,to:Int(bounds.width),by:8) {
                ((x+y)%16 == 0 ? NSColor.systemBlue : NSColor.systemOrange).setFill()
                NSRect(x:x,y:y,width:8,height:8).fill()
            } }
            NSColor(calibratedWhite:0.97,alpha:1).setFill(); NSRect(x:185,y:166,width:100,height:45).fill()
            ("TEXT" as NSString).draw(at:NSPoint(x:196,y:180),withAttributes:attributes)
        default: break
        }
    }
}

@main struct BackdropFixture {
    static func main() throws {
        func argument(_ name: String) -> String? {
            guard let i = CommandLine.arguments.firstIndex(of:name), i+1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[i+1]
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let area = NSScreen.screens[0].visibleFrame
        let width = min(1120,area.width-100), height = min(660,area.height-110)
        let content = NSRect(x:area.midX-width/2,y:area.minY+50,width:width,height:height)
        let window = NSWindow(contentRect:content,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "角色背景避让测试 · 本机生成文档"
        window.isReleasedWhenClosed = false
        window.level = .floating // Keep the generated document beneath status-bar sprites and above unrelated normal windows.
        let view = DocumentFixture(frame:NSRect(origin:.zero,size:content.size))
        view.mode = argument("--mode") ?? "near"
        window.contentView = view
        window.orderFrontRegardless()
        let panelX = content.minX+((view.mode == "far-left" || view.mode == "middle-left") ? width-230 : 140)
        let info: [String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"window":window.windowNumber,
            "contentFrame":[content.minX,content.minY,content.width,content.height],
            "start":[panelX,content.minY+90],
            "searchRegion":[content.minX+16,content.minY+16,width-147-32,height-226-32]]
        if let path = argument("--info") {
            try JSONSerialization.data(withJSONObject:info).write(to:URL(fileURLWithPath:path),options:.atomic)
        }
        let deadline = ProcessInfo.processInfo.systemUptime+(Double(argument("--lifetime") ?? "65") ?? 65)
        var lastCommand = ""
        let commandsPath = argument("--commands")
        let timer = Timer(timeInterval:0.15,repeats:true) { _ in
            window.orderFrontRegardless()
            if let path = commandsPath, let data = try? Data(contentsOf:URL(fileURLWithPath:path)),
               let mode = String(data:data,encoding:.utf8), mode != lastCommand {
                lastCommand = mode; view.mode = mode; view.needsDisplay = true
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { app.terminate(nil) }
        }
        RunLoop.main.add(timer,forMode:.common)
        app.run()
    }
}
