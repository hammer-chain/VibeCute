import AppKit

@main
struct HeadPatCursorFixture {
    static func main() {
        guard CGPreflightPostEventAccess() else { fputs("Real mouse event permission is unavailable\n", stderr); exit(2) }
        let original = NSEvent.mouseLocation
        let top = CGDisplayBounds(CGMainDisplayID()).height
        func post(_ x: Double, _ y: Double) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: x, y: top-y), mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        defer { post(original.x, original.y) }
        let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
        let width = Double(CommandLine.arguments[3])!, mode = CommandLine.arguments[4]
        if mode == "hover" {
            post(x+width*0.5, y); Thread.sleep(forTimeInterval: 0.6)
        } else {
            let count = mode == "pass" ? 10 : 30
            for i in 0...count {
                let segment = min(2, i/10), p = Double(i-segment*10)/10
                let u = mode == "pass" ? 0.25+p*0.5 : segment == 1 ? 0.75-p*0.5 : 0.25+p*0.5
                post(x+width*u, y)
                Thread.sleep(forTimeInterval: 0.025)
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
}
