import AppKit
import ImageIO
@main struct CharacterDragReactionChecks {
    static func main() throws {
        _ = NSApplication.shared
        let folder=URL(fileURLWithPath:"output/drag-paddling")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var state=CharacterDragReaction()
        precondition(!state.update(at:.zero,time:1,scale:1))
        state.begin(at:.zero,time:1)
        for i in 1...30 { state.update(at:NSPoint(x:Double(i)*10,y:0),time:1+Double(i)/60,scale:1) }
        precondition(state.lean < -2 && abs(state.lean) <= 2.5 && state.weight <= 1)
        state.end(at:1.5)
        for i in 1...52 { state.update(at:NSPoint(x:300,y:0),time:1.5+Double(i)/60,scale:1) }
        precondition(!state.active && state.transform(in:NSRect(x:0,y:0,width:126,height:168),scale:1) == .identity)
        state.begin(at:.zero,time:2)
        state.update(at:NSPoint(x:-30,y:0),time:2.016,scale:1)
        precondition(state.lean > 0)
        var landing=CharacterDragReaction()
        landing.begin(at:.zero,time:10)
        landing.update(at:.zero,time:11,scale:1)
        landing.end(at:11)
        var landingFrames:[Int]=[]
        for step in 1...6 {
            landing.update(at:.zero,time:11+Double(step)*0.12+0.001,scale:1)
            landingFrames.append(landing.frameIndex!)
        }
        precondition(landingFrames == [8,9,1,0,0,0])
        let start=ProcessInfo.processInfo.systemUptime
        for i in 0..<100000 {
            state.update(at:NSPoint(x:sin(Double(i))*1000,y:0),time:3+Double(i)/60,scale:1)
            precondition(abs(state.lean)<=2.5 && state.weight<=1)
        }
        let seconds=ProcessInfo.processInfo.systemUptime-start
        let gif=CGImageDestinationCreateWithURL(folder.appendingPathComponent("preview.gif") as CFURL,"com.compuserve.gif" as CFString,90,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        let artwork=CharacterDragArtwork(directory:URL(fileURLWithPath:"Sources/CodexCaptions/Resources/DeepSeekThinking/Drag"))
        precondition(artwork.available && artwork.decodedBytes <= 10*1024*1024)
        let image=artwork.frames[0]
        // Any midair loop frame can enter release; quick clicks reverse the lift.
        for frame in 0..<8 {
            var quick=CharacterDragReaction();quick.begin(at:.zero,time:10)
            quick.update(at:.zero,time:10+Double(frame)*0.12+0.001,scale:1)
            let release=10+Double(frame)*0.12+0.002
            quick.end(at:release)
            quick.update(at:.zero,time:release+0.85,scale:1)
            precondition(!quick.active && quick.frameIndex == nil)
        }
        state=CharacterDragReaction()
        for i in 0..<90 {
            let t=Double(i)/30
            if i==15 { state.begin(at:.zero,time:t) }
            if i==65 { state.end(at:t) }
            let x = i < 40 ? Double(max(0,i-15))*12 : 300-Double(min(25,i-40))*12
            state.update(at:NSPoint(x:x,y:0),time:t,scale:1)
            let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:448,pixelsHigh:580,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            NSColor.white.setFill();NSRect(x:0,y:0,width:448,height:580).fill()
            let label=i<15 ? "未按下" : i<40 ? "按住 · 向右拖" : i<65 ? "按住 · 向左拖" : "放下 · 收手坐好"
            (label as NSString).draw(at:NSPoint(x:135,y:550),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.darkGray])
            let rect=NSRect(x:32,y:20,width:384,height:512)
            NSGraphicsContext.current!.cgContext.concatenate(state.transform(in:rect,scale:512/168))
            if let frame=state.frameIndex { artwork.draw(frame:frame,in:rect) } else { image.draw(in:rect) }
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(gif,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
            if i==30 {try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("drag-right.png"))}
        }
        precondition(CGImageDestinationFinalize(gif))
        let report:[String:Any]=["passed":true,"updates":100000,"updateSeconds":seconds,"maxLeanDegrees":2.5,"newBitmapCacheBytes":artwork.decodedBytes,"coldLoadSeconds":artwork.loadSeconds,"newTimers":0,"releaseSettlesSeconds":CharacterDragReaction.releaseDuration,"scope":"Controlled geometry and whole-image rendering"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("validation.json"))
        print(report)
    }
}
