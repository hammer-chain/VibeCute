import AppKit
@main struct Probe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in
            do {
                let screen = NSScreen.screens[Int(CommandLine.arguments[1])!]
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
                let start = ProcessInfo.processInfo.systemUptime
                let image = try await BackdropCapture().capture(displayID:id)
                let captured = ProcessInfo.processInfo.systemUptime
                let scene = try BackdropScene.analyze(image,frame:screen.frame,at:captured)
                var blank: CGRect?
                for x in 0..<5 {
                    for y in 0..<5 {
                        let px = screen.frame.minX+40+CGFloat(x)*(screen.frame.width-280)/4
                        let py = screen.frame.minY+40+CGFloat(y)*(screen.frame.height-280)/4
                        let rect = CGRect(x:px,y:py,width:200,height:200)
                        if blank == nil && scene.isBlank(rect) { blank = rect }
                    }
                }
                let patch: [CGFloat] = blank.map { [$0.minX,$0.minY,$0.width,$0.height] } ?? []
                let result: [String:Any] = ["displayID":id,"blank":blank != nil,"blankPatch":patch,
                    "captureMS":(captured-start)*1000,"analysisMS":(ProcessInfo.processInfo.systemUptime-captured)*1000,
                    "buildOptimization":"swiftc default (unoptimized probe)"]
                print("CAPTURE ",String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
            } catch { print("ERROR",error); exit(1) }
            app.terminate(nil)
        }
        app.run()
    }
}
