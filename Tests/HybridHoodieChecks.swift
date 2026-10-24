import AppKit

@main struct HybridHoodieChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let atlas = NSImage(contentsOf: root.appendingPathComponent("Sources/CodexCaptions/Resources/OrangeHoodieThinking/thinking-atlas.png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let frames = (0..<8).map { i in NSImage(cgImage: atlas.cropping(to: CGRect(x: i%4*384, y: i/4*512, width: 384, height: 512))!, size: HybridHoodieArtwork.size) }
        let start = ProcessInfo.processInfo.systemUptime
        let hybrid = HybridHoodieArtwork(frames: frames)
        let prepareMS = (ProcessInfo.processInfo.systemUptime-start)*1000
        precondition(hybrid.poses.count == 8)
        func render(_ frame: Int, _ width: Int, _ original: Bool, _ visible: Set<HybridHoodieArtwork.Part> = Set(HybridHoodieArtwork.Part.allCases)) -> NSBitmapImageRep {
            let height = width*4/3
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width*4, bitsPerPixel: 32)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let rect = NSRect(x: 0, y: 0, width: width, height: height)
            NSColor(white: 0.18, alpha: 1).setFill(); rect.fill()
            if original { frames[frame].draw(in: rect) } else { hybrid.draw(frame: frame, in: rect, visible: visible) }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        var maximumDelta = 0
        for size in [192,384,576,768] { for frame in 0..<8 {
            let a = render(frame,size,true), b = render(frame,size,false)
            for i in 0..<a.bytesPerRow*a.pixelsHigh {
                maximumDelta = max(maximumDelta, abs(Int(a.bitmapData![i])-Int(b.bitmapData![i])))
            }
        } }
        precondition(maximumDelta <= 2, "Hybrid changed source appearance by \(maximumDelta)")
        for (name, parts) in [("body",Set([HybridHoodieArtwork.Part.body])),("head",Set([.head])),("hair",Set([.hair])),("composite",Set(HybridHoodieArtwork.Part.allCases))] {
            let bitmap = render(0,768,false,parts)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("output/hybrid-hoodie/\(name).png"))
        }
        // These anchors cover neck, raised hand, sleeves, skirt, socks and shoes.
        let bodyAnchors = [(160,263),(180,262),(180,300),(160,354),(180,365),(190,395),(144,449),(209,474)]
        for frame in 0..<8 {
            let source = render(frame,384,true), body = render(frame,384,false,[.body])
            for (x,y) in bodyAnchors {
                for c in 0..<4 {
                    let i = (y*384+x)*4+c
                    precondition(source.bitmapData![i] == body.bitmapData![i], "Body lost original pixel at \(frame):\(x),\(y)")
                }
            }
        }
        let layerDirectory = root.appendingPathComponent("output/hybrid-hoodie/layers")
        try FileManager.default.createDirectory(at:layerDirectory,withIntermediateDirectories:true)
        for frame in 0..<8 { for part in HybridHoodieArtwork.Part.allCases {
            let image = hybrid.poses[frame].parts[part.rawValue].cgImage(forProposedRect:nil,context:nil,hints:nil)!
            let bitmap = NSBitmapImageRep(cgImage:image)
            try bitmap.representation(using:.png,properties:[:])!.write(to:layerDirectory.appendingPathComponent("frame-\(frame)-\(part).png"))
        } }
        let sheet = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1536,pixelsHigh:768,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:1536*4,bitsPerPixel:32)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:sheet)
        NSColor(white:0.18,alpha:1).setFill(); NSRect(x:0,y:0,width:1536,height:768).fill()
        for frame in 0..<8 { for part in HybridHoodieArtwork.Part.allCases {
            hybrid.draw(frame:frame,in:NSRect(x:frame*192,y:(2-part.rawValue)*256,width:192,height:256),visible:[part])
        } }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("output/hybrid-hoodie/layers-all-frames.png"))
        var samples: [Double] = []
        for i in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = render(i%8,384,false)
            samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        samples.sort()
        print("8 poses; 32 scale/frame comparisons; max channel delta \(maximumDelta); decoded bytes \(hybrid.decodedBytes); prepare \(prepareMS) ms; draw p95 \(samples[94]) ms")
    }
}
