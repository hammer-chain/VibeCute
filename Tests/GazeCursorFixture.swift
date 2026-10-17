import AppKit

@main
struct GazeCursorFixture {
    static func main() {
        let original = NSEvent.mouseLocation
        let height = CGDisplayBounds(CGMainDisplayID()).height
        func warp(_ x: CGFloat, _ y: CGFloat) { CGWarpMouseCursorPosition(CGPoint(x:x,y:height-y)) }
        defer { warp(original.x, original.y) }
        let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
        for offset in [CGPoint(x:-600,y:0),CGPoint(x:600,y:0),CGPoint(x:0,y:600),
                       CGPoint(x:0,y:-600),CGPoint.zero] {
            warp(x+offset.x,y+offset.y)
            Thread.sleep(forTimeInterval:0.7)
        }
    }
}
