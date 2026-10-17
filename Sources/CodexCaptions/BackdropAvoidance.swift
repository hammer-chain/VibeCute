import AppKit

/// Background pixels stay in memory; avoidance does not perform OCR.
struct BackdropScene {
    let pixels: BackdropUniformity
    let frame: CGRect
    let capturedAt: Double

    static func analyze(_ image: CGImage, frame: CGRect, at time: Double) throws -> BackdropScene {
        BackdropScene(pixels:BackdropUniformity(image:image),frame:frame,capturedAt:time)
    }
    private func normalized(_ rect: CGRect) -> CGRect {
        CGRect(x:(rect.minX-frame.minX)/frame.width,y:1-(rect.maxY-frame.minY)/frame.height,
               width:rect.width/frame.width,height:rect.height/frame.height)
    }
    func isObstructed(silhouette: BackdropSilhouette, sprite: CGRect) -> Bool {
        let regions = silhouette.tiles.map { tile in
            normalized(CGRect(x:sprite.minX+tile.minX*sprite.width,y:sprite.minY+tile.minY*sprite.height,
                width:tile.width*sprite.width,height:tile.height*sprite.height))
        }
        return !pixels.isUniform(regions)
    }
    func isBlank(_ rect: CGRect) -> Bool {
        let padded = rect.insetBy(dx:-6,dy:-6)
        return frame.contains(padded) && pixels.isUniform(normalized(padded))
    }
}

/// The character's actual alpha silhouette, excluding the transparent headroom and corners.
struct BackdropSilhouette {
    let tiles: [CGRect] // Normalized bottom-left rectangles.
    let bounds: CGRect
    init(image: CGImage) {
        let w = 24, h = 32
        var bytes = [UInt8](repeating:0,count:w*h*4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        }
        var boxes: [CGRect] = []
        for y in 0..<h { for x in 0..<w where bytes[(y*w+x)*4+3] > 80 {
            boxes.append(CGRect(x:Double(x)/Double(w),y:1-Double(y+1)/Double(h),width:1/Double(w),height:1/Double(h)))
        } }
        tiles = boxes
        bounds = boxes.reduce(CGRect.null) { $0.union($1) }
    }
    func worldBounds(in sprite: CGRect) -> CGRect {
        CGRect(x:sprite.minX+bounds.minX*sprite.width,y:sprite.minY+bounds.minY*sprite.height,
            width:bounds.width*sprite.width,height:bounds.height*sprite.height)
    }

}

/// Integral RGB statistics and edge density reject wallpaper, UI borders and image texture.
final class BackdropUniformity {
    let width: Int, height: Int
    private let stride: Int
    private var red: [Double], green: [Double], blue: [Double], squares: [Double], edges: [Double]
    init(image: CGImage) {
        width = min(960,image.width)
        height = max(1,Int(Double(image.height)*Double(width)/Double(image.width)))
        stride = width+1
        let count = (width+1)*(height+1)
        red = .init(repeating:0,count:count); green = red; blue = red; squares = red; edges = red
        var rgba = [UInt8](repeating:0,count:width*height*4)
        rgba.withUnsafeMutableBytes { buffer in
            let c = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.interpolationQuality = .low
            c.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        }
        for y in 0..<height {
            var r = 0.0, g = 0.0, b = 0.0, q = 0.0, e = 0.0
            for x in 0..<width {
                let p = (y*width+x)*4
                let vr = Double(rgba[p])/255, vg = Double(rgba[p+1])/255, vb = Double(rgba[p+2])/255
                r += vr; g += vg; b += vb; q += vr*vr+vg*vg+vb*vb
                var contrast = 0
                if x > 0 { for c in 0..<3 { contrast = max(contrast,abs(Int(rgba[p+c])-Int(rgba[p-4+c]))) } }
                if y > 0 { for c in 0..<3 { contrast = max(contrast,abs(Int(rgba[p+c])-Int(rgba[p-width*4+c]))) } }
                if contrast > 22 { e += 1 }
                let i = (y+1)*stride+x+1, above = y*stride+x+1
                red[i] = red[above]+r; green[i] = green[above]+g; blue[i] = blue[above]+b
                squares[i] = squares[above]+q; edges[i] = edges[above]+e
            }
        }
    }
    func isUniform(_ r: CGRect) -> Bool { isUniform([r]) }
    func isUniform(_ regions: [CGRect]) -> Bool {
        guard !regions.isEmpty else { return true }
        var count = 0.0, redSum = 0.0, greenSum = 0.0, blueSum = 0.0, squareSum = 0.0, edgeSum = 0.0
        for r in regions {
            guard r.width > 0, r.height > 0, CGRect(x:0,y:0,width:1,height:1).contains(r) else { return false }
            let x0 = max(0,Int(floor(r.minX*CGFloat(width)))), y0 = max(0,Int(floor(r.minY*CGFloat(height))))
            let x1 = min(width,Int(ceil(r.maxX*CGFloat(width)))), y1 = min(height,Int(ceil(r.maxY*CGFloat(height))))
            func sum(_ a: [Double]) -> Double { a[y1*stride+x1]-a[y0*stride+x1]-a[y1*stride+x0]+a[y0*stride+x0] }
            count += Double((x1-x0)*(y1-y0))
            redSum += sum(red); greenSum += sum(green); blueSum += sum(blue)
            squareSum += sum(squares); edgeSum += sum(edges)
        }
        guard count > 0 else { return false }
        let r = redSum/count, g = greenSum/count, b = blueSum/count
        let variance = max(0,squareSum/count-r*r-g*g-b*b)/3
        return variance <= pow(5.5/255,2) && edgeSum/count < 0.004
    }

}

struct BackdropAvoidancePlan {
    enum Movement: String { case scoot = "坐姿挪动", frontRetreat = "正面急退", walk = "起身走过去", singingStep = "唱歌小步移动" }
    let from: CGPoint, to: CGPoint
    let movement: Movement
    let destinationBody: CGRect
    var distance: Double { hypot(to.x-from.x,to.y-from.y) }
}

enum BackdropAvoidancePlanner {
    static func movement(distance: Double, scale: CGFloat, singing: Bool) -> BackdropAvoidancePlan.Movement {
        if singing { return .singingStep }
        if distance <= 120*scale { return .scoot }
        if distance <= 360*scale { return .frontRetreat }
        return .walk
    }
    static func plan(scene: BackdropScene, silhouette: BackdropSilhouette, sprite: CGRect,
                     panelOrigin: CGPoint, allowedOrigins: CGRect, scale: CGFloat,
                     destinationBounds: CGRect? = nil, singing: Bool = false,
                     requireObstruction: Bool = true, maxDistance: Double? = nil) -> BackdropAvoidancePlan? {
        guard (!requireObstruction || scene.isObstructed(silhouette:silhouette,sprite:sprite)), !allowedOrigins.isNull else { return nil }
        // Obstruction uses the current alpha mask; destination must also fit the final seated pose.
        let currentBody = silhouette.worldBounds(in:sprite)
        let body = currentBody.union(destinationBounds ?? currentBody).insetBy(dx:-4*scale,dy:-4*scale)
        let inset = CGPoint(x:body.minX-panelOrigin.x,y:body.minY-panelOrigin.y)
        var candidates: [CGPoint] = []
        let step = max(10,16*scale)
        let search = maxDistance.map {
            allowedOrigins.intersection(CGRect(x:panelOrigin.x-$0,y:panelOrigin.y-$0,width:$0*2,height:$0*2))
        } ?? allowedOrigins
        guard !search.isNull else { return nil }
        for y in stride(from:search.minY,through:search.maxY,by:step) {
            for x in stride(from:search.minX,through:search.maxX,by:step) {
                if let maxDistance, hypot(x-panelOrigin.x,y-panelOrigin.y)>maxDistance { continue }
                candidates.append(CGPoint(x:x,y:y))
            }
        }
        candidates.sort {
            hypot($0.x-panelOrigin.x,$0.y-panelOrigin.y) < hypot($1.x-panelOrigin.x,$1.y-panelOrigin.y)
        }
        for destination in candidates {
            guard destination.x >= allowedOrigins.minX, destination.x <= allowedOrigins.maxX,
                  destination.y >= allowedOrigins.minY, destination.y <= allowedOrigins.maxY else { continue }
            let distance = hypot(destination.x-panelOrigin.x,destination.y-panelOrigin.y)
            guard distance >= 8*scale else { continue }
            let rect = CGRect(x:destination.x+inset.x,y:destination.y+inset.y,width:body.width,height:body.height)
            guard scene.isBlank(rect) else { continue }
            return BackdropAvoidancePlan(from:panelOrigin,to:destination,
                movement:movement(distance:distance,scale:scale,singing:singing),destinationBody:rect)
        }
        return nil
    }
}

/// Two consistent observations, a cooldown after movement, and explicit manual-drag suppression.
struct BackdropAvoidanceTrigger {
    static let confirmationScanInterval = 0.25
    private var previous: BackdropAvoidancePlan?
    private var previousAt = -Double.infinity
    private var quickChecksRemaining = 0
    var needsQuickConfirmation: Bool { previous != nil && quickChecksRemaining > 0 }
    private(set) var cooldownUntil = -Double.infinity
    mutating func reset(until time: Double? = nil) {
        previous = nil
        quickChecksRemaining = 0
        if let time { cooldownUntil = time }
    }
    mutating func observe(_ plan: BackdropAvoidancePlan?, at now: Double) -> Bool {
        guard now >= cooldownUntil, let plan else { previous = nil; quickChecksRemaining = 0; return false }
        // One fast follow-up per candidate sequence. Changing targets fall back to normal polling.
        quickChecksRemaining = previous == nil ? 1 : max(0,quickChecksRemaining-1)
        defer { previous = plan; previousAt = now }
        guard let old = previous, now-previousAt <= 5,
              hypot(old.from.x-plan.from.x,old.from.y-plan.from.y) < 3,
              hypot(old.to.x-plan.to.x,old.to.y-plan.to.y) < 24 else { return false }
        return true
    }
}
