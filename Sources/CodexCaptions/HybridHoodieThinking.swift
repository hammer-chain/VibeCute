import AppKit

struct HybridThinkingSample: Equatable {
    static let duration = 2.88
    let time: Double
    let bodyFrame: Int
    let eyeFrame: Int
    let headDegrees: Double
    let hairShift: Double
    static let sequence = [0,0,0,0,0,1,1,2,2,3,4,5,6,6,7,7,7,7]
    static func angle(_ t: Double) -> Double {
        func ease(_ x:Double)->Double { let v=min(1,max(0,x));return v*v*(3-2*v) }
        if t < 0.96 { return 0 }
        if t < 1.12 { return 9 * ease((t-0.96)/0.16) }
        if t < 1.60 { return 9 }
        if t < 1.76 { return 9 * (1-ease((t-1.60)/0.16)) }
        return 0
    }
    static func sample(_ elapsed: Double) -> Self {
        let t = elapsed.isFinite ? max(0,elapsed).truncatingRemainder(dividingBy:duration) : 0
        let frame = sequence[min(17,Int(t/0.16))]
        let settle = t-1.76
        let hair = settle >= 0 && settle < 0.88
            ? 4.0 * sin(settle * .pi * 2 / 0.42) * pow(1-settle/0.88,2) : 0
        return Self(time:t,bodyFrame:t>=2.72 ? 0:frame,eyeFrame:frame==3 ? 1:(frame==4 ? 2:0),
            headDegrees:angle(t),hairShift:hair + (angle(t-0.06)-angle(t))*0.22)
    }
}

/// Continuous head motion over original pixel-body poses. Prepared repair layers
/// only fill hidden artwork. One output frame is cached, never a rendered-frame atlas.
final class HybridHoodieThinking {
    let artwork: HybridHoodieArtwork
    private let heads: [CGImage]
    private let hands: [CGImage]
    private let hair: CGImage
    private let hairPixels: [UInt8]
    private let underbody: CGImage
    private var lastHair: (angle:Double,sway:Double,image:CGImage)?
    private let strandWeights = (0..<384).map { 0.85+0.15*sin((Double($0)+0.5)*0.04) }
    private var last: (sample:HybridThinkingSample, visible:Set<HybridHoodieArtwork.Part>, image:CGImage)?
    private(set) var renderCount = 0
    let preparedBytes: Int
    var retainedDecodedBytes: Int { artwork.decodedBytes + preparedBytes + (last == nil ? 0 : 384*512*4) + (lastHair == nil ? 0 : 384*512*4) }
    static let byteBudget = 32*1024*1024
    static let canvas = CGRect(x:0,y:0,width:384,height:512)

    init?(artwork:HybridHoodieArtwork, resourceRoot:URL) {
        guard artwork.poses.count==8 else {return nil}
        func load(_ name:String)->CGImage? {
            guard let image=NSImage(contentsOf:resourceRoot.appendingPathComponent(name+".png")) else {return nil}
            return image.cgImage(forProposedRect:nil,context:nil,hints:nil)
        }
        guard let body=load("body-underpainting"),let chin=load("face-underpainting"),
              body.width==384,body.height==512,chin.width==384,chin.height==512 else {return nil}
        self.artwork=artwork;underbody=body
        var prepared:[CGImage]=[]
        for expression in [0,3,4] {
            let c=Self.bitmapContext()
            c.draw(chin,in:Self.canvas)
            c.saveGState()
            c.addRect(Self.canvas)
            c.addRect(CGRect(x:144,y:512-289,width:36,height:49))
            c.clip(using:.evenOdd)
            Self.draw(artwork.poses[0].parts[1],in:c)
            c.restoreGState()
            if expression != 0 {
                let eye=Self.bitmapContext()
                eye.translateBy(x:175.5,y:512-203.5)
                eye.rotate(by:CGFloat(4.9 * Double.pi/180))
                eye.scaleBy(x:0.962,y:0.962)
                eye.translateBy(x:-175.5,y:-(512-203.75))
                Self.draw(artwork.poses[expression].composite,in:eye)
                let base=c.data!.assumingMemoryBound(to:UInt8.self)
                let replacement=eye.data!.assumingMemoryBound(to:UInt8.self)
                let topColors=[(135,179),(215,183)].map {x,y in (0..<4).map {Double(replacement[(y*384+x)*4+$0])}}
                let bottomColors=[(135,232),(220,233)].map {x,y in (0..<4).map {Double(replacement[(y*384+x)*4+$0])}}
                for y in 163..<239 { for x in 106..<247 {
                    let boxes=[CGRect(x:106,y:163,width:61,height:70),CGRect(x:183,y:168,width:64,height:71)]
                    var weight=0.0
                    for box in boxes where box.contains(CGPoint(x:x,y:y)) {
                        let edge=min(Double(x)-box.minX,box.maxX-Double(x),Double(y)-box.minY,box.maxY-Double(y))
                        let a=min(1,max(0,edge/6));weight=max(weight,a*a*(3-2*a))
                    }
                    let p=(y*384+x)*4
                    let side=x<175 ? 0:1
                    let inkBox=side==0 ? CGRect(x:110,y:expression==4 ? 189:185,width:56,height:43):CGRect(x:186,y:expression==4 ? 195:191,width:59,height:43)
                    let inkEdge=min(Double(x)-inkBox.minX,inkBox.maxX-Double(x),Double(y)-inkBox.minY,inkBox.maxY-Double(y))
                    let ink=min(1,max(0,inkEdge/5)),inkWeight=ink*ink*(3-2*ink)
                    let isHair=Int(replacement[p+2])>Int(replacement[p])+8 && y<195
                    let v=min(1,max(0,Double(y-170)/62))
                    for channel in 0..<4 {
                        let cleanSkin=topColors[side][channel]*(1-v)+bottomColors[side][channel]*v
                        let value=isHair ? cleanSkin:Double(replacement[p+channel])*inkWeight+cleanSkin*(1-inkWeight)
                        base[p+channel]=UInt8(min(255,max(0,(Double(base[p+channel])*(1-weight)+value*weight).rounded())))
                    }
                } }
            }
            prepared.append(c.makeImage()!)
        }
        heads=prepared
        hair=artwork.poses[0].parts[HybridHoodieArtwork.Part.hair.rawValue]
            .cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let hairContext=Self.bitmapContext()
        hairContext.draw(hair,in:Self.canvas)
        hairPixels=Array(UnsafeBufferPointer(start:hairContext.data!.assumingMemoryBound(to:UInt8.self),count:384*512*4))
        // The touching hand must remain in front of the independently moving face.
        hands=artwork.poses.map { pose in
            let c=Self.bitmapContext()
            let points:[CGPoint]=[(149.0,245.0),(155,243),(161,247),(166,246),(173,250),
                (176,258),(179,266),(176,279),(170,286),(153,281),(146,272),(146,254)]
                .map { CGPoint(x:$0.0,y:512-$0.1) }
            c.addLines(between:points);c.closePath();c.clip()
            Self.draw(pose.parts[0],in:c)
            let crop=c.makeImage()!.cropping(to:CGRect(x:144,y:242,width:36,height:47))!
            // CGImage.cropping can retain the full parent allocation. Copy into
            // a compact owning buffer so decoded-byte accounting is real.
            let compact=CGContext(data:nil,width:36,height:47,bitsPerComponent:8,bytesPerRow:36*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            compact.draw(crop,in:CGRect(x:0,y:0,width:36,height:47))
            return compact.makeImage()!
        }
        preparedBytes=(heads+hands+[underbody]).reduce(0) {$0+$1.bytesPerRow*$1.height}+hairPixels.count
        precondition(retainedDecodedBytes + 2*384*512*4 <= Self.byteBudget)
    }
    private static func bitmapContext()->CGContext {
        CGContext(data:nil,width:384,height:512,bitsPerComponent:8,bytesPerRow:384*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    private static func draw(_ image:NSImage,in context:CGContext) {
        context.draw(image.cgImage(forProposedRect:nil,context:nil,hints:nil)!,in:canvas)
    }
    /// One inverse sample per output pixel: continuous mesh, no strip seams or GPU readbacks.
    private func deformedHair(angle:Double,sway:Double)->CGImage {
        if angle==0 && sway==0 {return hair}
        if let lastHair,lastHair.angle==angle,lastHair.sway==sway {return lastHair.image}
        let c=Self.bitmapContext()
        let output=c.data!.assumingMemoryBound(to:UInt8.self)
        hairPixels.withUnsafeBufferPointer { input in
            let source=input.baseAddress!
            for y in 0..<512 {
                let py=511.5-Double(y),dy=py-264
                var w=min(1,max(0,(py-120)/145));w=w*w*(3-2*w)
                let a=angle*(0.20+0.80*w),co=cos(a),si=sin(a)
                let tip=min(1,max(0,(275-py)/150)),shift=sway*tip*tip
                let xBase = -175.5*co-dy*si+175.5
                let yBase = 247.5+175.5*si-dy*co
                for x in 0..<384 {
                    let sx=xBase+Double(x)*co-shift*strandWeights[x],sy=yBase-Double(x)*si
                    let ix=Int(floor(sx)),iy=Int(floor(sy))
                    guard ix>=0,ix<383,iy>=0,iy<511 else {continue}
                    let p=(iy*384+ix)*4,q=p+384*4,out=(y*384+x)*4
                    if source[p+3]==0 && source[p+7]==0 && source[q+3]==0 && source[q+7]==0 {continue}
                    let fx=sx-Double(ix),fy=sy-Double(iy)
                    let a=(1-fx)*(1-fy),b=fx*(1-fy),d=(1-fx)*fy,e=fx*fy
                    for channel in 0..<4 {
                        let value=Double(source[p+channel])*a+Double(source[p+4+channel])*b
                            + Double(source[q+channel])*d+Double(source[q+4+channel])*e
                        output[out+channel]=UInt8(min(255,max(0,value.rounded())))
                    }
                }
            }
        }
        let image=c.makeImage()!
        lastHair=(angle,sway,image)
        return image
    }

    func image(at elapsed:Double,visible:Set<HybridHoodieArtwork.Part> = Set(HybridHoodieArtwork.Part.allCases))->CGImage {
        let sample=HybridThinkingSample.sample(elapsed)
        if let last,last.sample==sample,last.visible==visible {return last.image}
        if sample.bodyFrame==0 && sample.eyeFrame==0 && sample.headDegrees==0 && sample.hairShift==0 && visible.count==3 {
            let image=artwork.poses[0].composite.cgImage(forProposedRect:nil,context:nil,hints:nil)!
            last=(sample,visible,image)
            return image
        }
        let c=Self.bitmapContext()
        if visible.contains(.body) {
            c.saveGState()
            c.addRect(CGRect(x:105,y:512-312,width:158,height:81))
            c.clip();c.draw(underbody,in:Self.canvas);c.restoreGState()
            c.saveGState()
            c.addRect(Self.canvas)
            c.addRect(CGRect(x:180,y:512-258,width:48,height:27))
            c.addRect(CGRect(x:110,y:512-248,width:36,height:17))
            c.clip(using:.evenOdd)
            Self.draw(artwork.poses[sample.bodyFrame].parts[0],in:c)
            c.restoreGState()
        }
        if visible.contains(.head) {
            c.saveGState();c.translateBy(x:176,y:264)
            c.rotate(by:CGFloat(-sample.headDegrees * .pi/180));c.translateBy(x:-176,y:-264)
            c.draw(heads[sample.eyeFrame],in:Self.canvas);c.restoreGState()
        }
        if visible.contains(.hair) {
            c.draw(deformedHair(angle:sample.headDegrees * .pi/180,sway:sample.hairShift),in:Self.canvas)
        }
        if visible.contains(.body) { c.draw(hands[sample.bodyFrame],in:CGRect(x:144,y:512-289,width:36,height:47)) }
        let image=c.makeImage()!
        renderCount += 1
        last=(sample,visible,image)
        precondition(retainedDecodedBytes <= Self.byteBudget)
        return image
    }
    func draw(at elapsed:Double,in rect:CGRect,visible:Set<HybridHoodieArtwork.Part> = Set(HybridHoodieArtwork.Part.allCases)) {
        NSGraphicsContext.current?.cgContext.draw(image(at:elapsed,visible:visible),in:rect)
    }
}
