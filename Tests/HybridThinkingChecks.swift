import AppKit
import ImageIO

@main struct HybridThinkingChecks {
    static func main() throws {
        func check(_ condition:Bool,_ message:String="check failed",line:Int=#line) {
            if !condition { FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8));exit(1) }
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let src=NSImage(contentsOf:root.appendingPathComponent("Sources/CodexCaptions/Resources/OrangeHoodieThinking/thinking-atlas.png"))!.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let frames=(0..<8).map {i in NSImage(cgImage:src.cropping(to:CGRect(x:i%4*384,y:i/4*512,width:384,height:512))!,size:NSSize(width:384,height:512))}
        let art=HybridHoodieArtwork(frames:frames)
        let thinking=HybridHoodieThinking(artwork:art,resourceRoot:root.appendingPathComponent("Sources/CodexCaptions/Resources/OrangeHoodieThinking/Hybrid"))!
        let times=[0.0,0.96,1.04,1.12,1.44,1.60,1.68,1.76,1.84,1.96,2.16,2.64]
        let sheet=CGContext(data:nil,width:384*6,height:512*2,bitsPerComponent:8,bytesPerRow:384*6*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        sheet.setFillColor(NSColor(white:0.18,alpha:1).cgColor);sheet.fill(CGRect(x:0,y:0,width:384*6,height:512*2))
        for (i,t) in times.enumerated() {
            let image=thinking.image(at:t)
            sheet.draw(image,in:CGRect(x:i%6*384,y:(1-i/6)*512,width:384,height:512))
            let dst=CGImageDestinationCreateWithURL(root.appendingPathComponent("output/hybrid-hoodie/thinking/frame-\(i).png") as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(dst,image,nil);CGImageDestinationFinalize(dst)
        }
        let dst=CGImageDestinationCreateWithURL(root.appendingPathComponent("output/hybrid-hoodie/thinking/contact.png") as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(dst,sheet.makeImage()!,nil);CGImageDestinationFinalize(dst)
        func bytes(_ image:CGImage)->[UInt8] {
            let c=CGContext(data:nil,width:384,height:512,bitsPerComponent:8,bytesPerRow:384*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:384,height:512))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:384*512*4))
        }
        let neutral=bytes(thinking.image(at:0))
        check(neutral==bytes(thinking.image(at:2.88)))
        check(neutral==bytes(thinking.image(at:2.84)),"Loop end must settle exactly onto entry pose")
        let heldHead=bytes(thinking.image(at:1.76,visible:[.head]))
        let firstHair=bytes(thinking.image(at:1.76,visible:[.hair]))
        var hairChanged=false
        for i in 0..<34 {
            let t=1.76+Double(i)/30
            check(HybridThinkingSample.sample(t).headDegrees==0)
            check(heldHead==bytes(thinking.image(at:t,visible:[.head])),"Head moved during hair settle")
            if bytes(thinking.image(at:t,visible:[.hair])) != firstHair {hairChanged=true}
        }
        check(hairChanged,"Hair must move independently after head return")
        let gif=CGImageDestinationCreateWithURL(root.appendingPathComponent("output/hybrid-hoodie/thinking/loop.gif") as CFURL,"com.compuserve.gif" as CFString,72,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        var costs:[Double]=[],anchors=0,minNeckAlpha=255,maxBodyDelta=0
        for i in 0..<72 {
            let t=Double(i)*0.04
            let start=ProcessInfo.processInfo.systemUptime
            let image=thinking.image(at:t)
            costs.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            let rgba=bytes(image), sample=HybridThinkingSample.sample(t)
            let source=bytes(art.poses[sample.bodyFrame].composite.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
            for (x,y) in [(160,263),(180,300),(160,354),(180,365),(190,395),(144,449),(209,474)] {
                for c in 0..<4 {maxBodyDelta=max(maxBodyDelta,abs(Int(rgba[(y*384+x)*4+c])-Int(source[(y*384+x)*4+c])));check(abs(Int(rgba[(y*384+x)*4+c])-Int(source[(y*384+x)*4+c]))<=2,"Body/hand pixel changed at \(t):\(x),\(y) channel \(c): \(rgba[(y*384+x)*4+c]) vs \(source[(y*384+x)*4+c])")}
                anchors += 1
            }
            for y in 257..<263 {for x in 182..<197 {minNeckAlpha=min(minNeckAlpha,Int(rgba[(y*384+x)*4+3]))}}
            let c=CGContext(data:nil,width:768,height:512,bitsPerComponent:8,bytesPerRow:768*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(NSColor(white:0.18,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:768,height:512))
            let original=HybridThinkingSample.sequence[min(17,Int(t/0.16))]
            c.draw(art.poses[original].composite.cgImage(forProposedRect:nil,context:nil,hints:nil)!,in:CGRect(x:0,y:0,width:384,height:512))
            c.draw(image,in:CGRect(x:384,y:0,width:384,height:512))
            CGImageDestinationAddImage(gif,c.makeImage()!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary)
        }
        check(CGImageDestinationFinalize(gif))
        check(minNeckAlpha>=245,"Neck exposed transparent holes: \(minNeckAlpha)")
        costs.sort()
        print("PASS: 72 animated samples, \(anchors) original body/hand anchors, neck minimum alpha \(minNeckAlpha), body max channel delta \(maxBodyDelta), 34 locked-head checks with independent hair movement, exact loop endpoints")
        print("prepared \(thinking.preparedBytes), retained \(thinking.retainedDecodedBytes), draw p95 \(costs[68]) ms")
    }
}
