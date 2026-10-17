import AppKit

// Separate-process ordinary window for testing metadata, stacking and following.
@main
final class WindowPeekFixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var timer: Timer?
    var lastCommand = ""
    var keepFront = false
    var stableFrame:NSRect?
    var motionTimer:Timer?
    var motion:(started:Double,origin:NSPoint,points:[NSPoint],seconds:Double,accelerating:Bool)?
    var motionTrace:FileHandle?
    func argument(_ name:String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of:name),i+1 < CommandLine.arguments.count else {return nil}
        return CommandLine.arguments[i+1]
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        keepFront = CommandLine.arguments.contains("--keep-front")
        let area = NSScreen.screens.first!.visibleFrame
        let originY = CommandLine.arguments.contains("--low-window") ? area.minY+40 : area.midY-190
        window = NSWindow(contentRect:NSRect(x:area.midX-260,y:originY,width:520,height:420),
            styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "窗口探头 · 外部窗口验证"
        window.isReleasedWhenClosed = false
        if CommandLine.arguments.contains("--all-spaces") { window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary] }
        window.backgroundColor = NSColor(calibratedRed:0.92,green:0.96,blue:1,alpha:1)
        window.orderFrontRegardless()
        if CommandLine.arguments.contains("--stable-frame") {stableFrame=window.frame}
        if let path=argument("--motion-trace") {
            FileManager.default.createFile(atPath:path,contents:nil)
            motionTrace=FileHandle(forWritingAtPath:path)
        }
        let motionTimer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in
            guard let self else {return}
            // Opt-in deterministic placement for recovery tests. Explicit test
            // commands remain authoritative; ordinary drag fixtures are free.
            if let frame=self.stableFrame,self.window.frame != frame {
                self.window.setFrame(frame,display:true)
            }
            guard let motion=self.motion else {return}
            let elapsed=ProcessInfo.processInfo.systemUptime-motion.started
            let progress=min(1,max(0,elapsed/motion.seconds)),position=progress*Double(motion.points.count-1)
            let index=min(motion.points.count-2,Int(position)),linear=position-Double(index)
            let fraction=motion.accelerating ? linear*linear : linear
            let a=motion.points[index],b=motion.points[index+1]
            self.window.setFrameOrigin(NSPoint(x:motion.origin.x+a.x+(b.x-a.x)*fraction,y:motion.origin.y+a.y+(b.y-a.y)*fraction))
            if let trace=self.motionTrace,let data=try? JSONSerialization.data(withJSONObject:["uptime":ProcessInfo.processInfo.systemUptime,"frame":[self.window.frame.minX,self.window.frame.minY,self.window.frame.width,self.window.frame.height],"progress":progress]) {
                trace.write(data);trace.write(Data([10]))
            }
            if progress==1 {self.motion=nil}
        }
        self.motionTimer=motionTimer;RunLoop.main.add(motionTimer,forMode:.common)
        if let file = argument("--info") {
            let info: [String:Any] = ["window":window.windowNumber,"pid":ProcessInfo.processInfo.processIdentifier,
                "frame":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height],
                "screenFrame":[area.minX,area.minY,area.width,area.height],
                "fullScreenFrame":[NSScreen.screens.first!.frame.minX,NSScreen.screens.first!.frame.minY,
                    NSScreen.screens.first!.frame.width,NSScreen.screens.first!.frame.height]]
            try! JSONSerialization.data(withJSONObject:info).write(to:URL(fileURLWithPath:file),options:.atomic)
        }
        timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
            guard let self else { return }
            if self.keepFront { self.window.orderFrontRegardless() }
            guard let path=self.argument("--commands"),let data=try? Data(contentsOf:URL(fileURLWithPath:path)),
                  let command=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let token=command["token"] as? String,token != self.lastCommand else {return}
            self.lastCommand=token
            if command["front"] as? Bool == true { self.window.orderFrontRegardless() }
            if let keepFront = command["keepFront"] as? Bool { self.keepFront = keepFront }
            if command["close"] as? Bool == true { NSApp.terminate(nil); return }
            if command["minimize"] as? Bool == true { self.stableFrame=nil;self.window.miniaturize(nil) }
            if let f=command["frame"] as? [Double],f.count==4 {
                let frame=NSRect(x:f[0],y:f[1],width:max(340,f[2]),height:max(300,f[3]))
                if self.stableFrame != nil {self.stableFrame=frame}
                self.window.setFrame(frame,display:true)
            }
            if let points=command["drag"] as? [[Double]],let seconds=command["seconds"] as? Double,seconds>0,points.allSatisfy({$0.count==2}) {
                self.stableFrame=nil
                self.motion=(ProcessInfo.processInfo.systemUptime,self.window.frame.origin,
                    [.zero]+points.map{NSPoint(x:$0[0],y:$0[1])},seconds,command["accelerating"] as? Bool == true)
            }
        }
        let lifetime = argument("--lifetime").flatMap(Double.init) ?? 45
        DispatchQueue.main.asyncAfter(deadline:.now()+lifetime) { NSApp.terminate(nil) }
    }
    static func main() {
        let app=NSApplication.shared
        let delegate=WindowPeekFixture()
        app.setActivationPolicy(.accessory); app.delegate=delegate; app.run()
    }
}
