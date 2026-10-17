import AppKit
import ImageIO
import UniformTypeIdentifiers

enum WindowSwimChecks {
    static func run() throws {
        let folder = ProcessInfo.processInfo.environment["CAPTIONS_WINDOW_PEEK_OUTPUT"].map { URL(fileURLWithPath:$0) }
            ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/deepseek-window-peek")
        let screen = NSScreen.screens.first!.visibleFrame
        let controller = WindowPeekController()
        var evidence:[[String:Any]] = []
        for side in [DesktopWindowTarget.Side.left,.right] {
            let original = NSRect(x:screen.midX+(side == .left ? -120 : 120)-73.5,y:screen.minY+20,width:147,height:226)
            precondition(controller.start(from:original,scale:1,forceFixture:true,speed:160,hold:2.5))
            precondition(controller.route == .swimming && controller.target?.side == side,"Swim to the nearer lower corner")
            let started = ProcessInfo.processInfo.systemUptime
            let area = controller.fixture!.frame.union(original).insetBy(dx:-300,dy:-50)
            let count = Int((controller.duration+3)/0.08)
            let gif = CGImageDestinationCreateWithURL(folder.appendingPathComponent("swim-\(side.rawValue)-corner.gif") as CFURL,
                UTType.gif.identifier as CFString,count,nil)!
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            var phases:[String] = [], frames = Set<Int>(), positions = Set<String>(), heights:[CGFloat] = []
            for i in 0..<count {
                controller.tick(at:started+Double(i)*0.08)
                RunLoop.main.run(until:Date().addingTimeInterval(0.006))
                precondition(controller.isRunning)
                if phases.last != controller.phase.rawValue { phases.append(controller.phase.rawValue) }
                if controller.phase == .swimming {
                    frames.insert(controller.bodyView.swimFrame!)
                    positions.insert(NSStringFromRect(controller.body.frame)); heights.append(controller.body.frame.midY)
                    if i%10 == 0,let cg = controller.renderFixtureScene(in:area) {
                        try save(cg,to:folder.appendingPathComponent("swimming-\(side.rawValue).png"))
                    }
                }
                if controller.phase == .corner {
                    let angle = controller.bodyView.swimAngle
                    let x:CGFloat = (600-320)*224/640, y:CGFloat = (186-224)*224/640
                    let rotatedX = x*cos(angle)-y*sin(angle), rotatedY = x*sin(angle)+y*cos(angle)
                    let nose = NSPoint(x:controller.body.frame.midX+(controller.bodyView.mirrored ? -rotatedX : rotatedX),
                        y:controller.body.frame.midY+rotatedY)
                    let target = controller.target!
                    precondition(hypot(nose.x-target.edgeX,nose.y-target.frame.minY) < 40,"Head must arrive at the lower corner")
                }
                if controller.phase == .peeking {
                    let target = controller.target!, unit = controller.peek.frame.width/448
                    let handY = controller.peek.frame.minY+8+WindowPeekArtwork.gripY*unit
                    precondition(abs(handY-target.frame.minY-DesktopWindowTarget.cornerGripOffset)<1.1,"Peek starts by the lower corner")
                    precondition(abs(controller.peek.frame.minY+WindowPeekArtwork.lowerBodyExtension*unit-target.frame.minY-8)<1.1)
                    precondition(target.frame.contains(controller.coveredBodyRect))
                    if controller.peekView.peekFrame == 2,let cg = controller.renderFixtureScene(in:area) {
                        try save(cg,to:folder.appendingPathComponent("corner-peeking-\(side.rawValue).png"))
                    }
                }
                let row = controller.diagnostics
                if controller.body.level == .normal && controller.body.frame.intersects(controller.target!.frame) {
                    let ids = row["windowOrder"] as! [Int]
                    precondition(ids.firstIndex(of:Int(controller.target!.id))! < ids.firstIndex(of:controller.body.windowNumber)!)
                }
                if controller.phase == .parked,let cg = controller.renderFixtureScene(in:area) {
                    precondition(controller.peekView.concealment == 1 && controller.target!.frame.contains(controller.coveredBodyRect))
                    try save(cg,to:folder.appendingPathComponent("corner-parked-\(side.rawValue).png"))
                }
                CGImageDestinationAddImage(gif,controller.renderFixtureScene(in:area)!,
                    [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.08]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(gif))
            precondition(phases == ["浮起转身","游向窗口下角","抵达窗口下角","藏在窗口后面","扒着窗口探头","缩回窗口后面","停在窗口后"])
            precondition(frames.count == 8 && positions.count > 8 && heights.last! > heights.first!+40,"Actual upward swim with tail cycle")
            precondition(zip(heights,heights.dropFirst()).allSatisfy {$1 >= $0-0.5},"Swimming ascends toward the corner")
            let body = controller.body.frame, peek = controller.peek.frame
            controller.tick(at:started+controller.duration+120)
            precondition(controller.isRunning && controller.body.frame == body && controller.peek.frame == peek)
            evidence.append(["side":side.rawValue,"route":controller.route.rawValue,"phases":phases,
                "swimFrames":frames.sorted(),"positions":positions.count,"upwardDistance":heights.last!-heights.first!,"parked":true])
            controller.stop()
        }
        // Tie goes left; a character beside or above the bottom retains the walking route.
        let window = NSRect(x:500,y:300,width:520,height:420)
        precondition(DesktopWindowTarget.nearestLowerCorner(NSRect(x:686.5,y:20,width:147,height:226),window:window) == .left)
        for scale:CGFloat in [0.5,2] {
            let original = NSRect(x:screen.midX-200,y:screen.minY+10,width:147*scale,height:226*scale)
            precondition(controller.start(from:original,scale:scale,forceFixture:true,speed:180,hold:2))
            precondition(controller.route == .swimming)
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            let base = ProcessInfo.processInfo.systemUptime
            controller.tick(at:base+controller.duration+1)
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            precondition(controller.isRunning && controller.target!.frame.contains(controller.coveredBodyRect))
            precondition(abs(controller.peek.frame.minY+WindowPeekArtwork.lowerBodyExtension*147*scale/448-controller.target!.frame.minY-8*scale)<1.1)
            controller.stop()
        }
        try JSONSerialization.data(withJSONObject:["passed":true,"runs":evidence,"scales":[0.5,1,2],"nearestCornerTie":"left"],
            options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("swim-geometry-validation.json"))
        print("PASS: both nearest lower corners, upward curved swim, 8 tail frames, corner grip, persistent concealment, scales 50/100/200 percent")
    }
    private static func save(_ cg:CGImage,to url:URL) throws {
        try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:url)
    }
}
