import AppKit

/// Uses production capture and complete scene analysis; keeps pixels only in memory.
@main struct BackdropPerformanceProbe {
    static func main() async throws {
        let screen = NSScreen.screens[0]
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        let capture = BackdropCapture()
        var samples: [[String:Any]] = []
        for i in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            let image = try await capture.capture(displayID:display)
            let captured = ProcessInfo.processInfo.systemUptime
            let scene = try BackdropScene.analyze(image,frame:screen.frame,at:start)
            let analyzed = ProcessInfo.processInfo.systemUptime
            samples.append(["index":i,"captureMs":(captured-start)*1000,
                "analysisMs":(analyzed-captured)*1000,"totalMs":(analyzed-start)*1000,
                "analysisMode":"uniformity","fullFrameUniform":scene.pixels.isUniform(CGRect(x:0,y:0,width:1,height:1)),"width":image.width,"height":image.height])
        }
        let data = try JSONSerialization.data(withJSONObject:samples,options:[.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
    }
}
