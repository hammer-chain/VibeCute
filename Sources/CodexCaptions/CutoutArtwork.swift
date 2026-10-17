import AppKit
import ImageIO

/// Only the current selection is retained. A failed swap leaves the previous
/// appearance and pose intact. Shared images survive successful swaps by path;
/// obsolete images are released instead of retaining every outfit ever seen.
final class CutoutArtwork {
    struct Part {
        let slot: Int
        let bone: Int
        let image: CGImage
        let rect: CGRect
        let orientation: CGAffineTransform
    }
    struct Underlap {
        let bone: Int
        let triggers: [Int]
        let image: CGImage
        let rect: CGRect
    }
    struct Composite {
        let key: String
        let bone: Int
        let sourceOver: Bool
        let members: [Int]
        let memberBones: [Int]
        let rect: CGRect
        let forms: [CGImage]
        let masks: [CGImage]
        let blinkCount: Int
        let mouthCount: Int
        var bytes: Int { forms.reduce(0) { $0+$1.width*$1.height*5 } }
    }
    struct EyeAperture {
        let key: String
        let iris: Int
        let bone: Int
        let rect: CGRect
        let masks: [CGImage]
        var bytes:Int {masks.reduce(0){$0+$1.width*$1.height}}
    }
    struct ClothTriangle {
        let a:CGPoint, b:CGPoint, c:CGPoint
    }
    struct ClothPatch {
        let key:String
        let definition:CutoutRig.ClothDeformation
        let driver:Int
        let forms:[CGImage]
        let angleSteps:Int
        let rect:CGRect
        let outside:CGPath
        let vertices:[CGPoint]
        var bytes:Int {forms.reduce(0){$0+$1.width*$1.height*4}}
    }
    let rig: CutoutRig
    let player: CutoutPlayer
    private let resource: (String) -> URL?
    private(set) var selection: [String: String] = [:]
    private(set) var parts: [Part] = []
    private var underlaps: [Underlap] = []
    private var images: [String: CGImage] = [:]
    private(set) var decodedImages = 0
    private(set) var resourceReads = 0
    private(set) var decodedBytes = 0
    private(set) var drawCount = 0
    private(set) var drawOperations = 0
    private var expressionImages: [String: [CGImage]] = [:]
    private var mouthShapeImages: [String: [CGImage]] = [:]
    private var composites: [Composite] = []
    private var eyeApertures: [Int:EyeAperture] = [:]
    private var clothPatches:[Int:ClothPatch] = [:]
    private(set) var clothPatchImagesBuilt = 0
    private(set) var eyeMaskImagesBuilt = 0
    private(set) var compositeBuilds = 0
    private(set) var compositeBuildsByID: [String:Int] = [:]
    private var expressionBytes: Int {
        (Array(expressionImages.values) + Array(mouthShapeImages.values)).flatMap { $0 }
            .reduce(0) { $0+$1.width*$1.height*4 }
    }

    init(rig: CutoutRig, resource: @escaping (String) -> URL?) throws {
        self.rig = try rig.validated(); self.resource = resource
        guard let url = resource(rig.motions) else { throw CutoutError.invalid("Missing cutout motions") }
        resourceReads += 1
        let motions = try JSONDecoder().decode(CutoutMotionLibrary.self, from: Data(contentsOf: url))
        player = try CutoutPlayer(rig: rig, motions: motions)
        // Finite local expression atlas; cache only tiny patches, never bodies.
        for (slot, files) in rig.expressions ?? [:] {
            for file in files {
                let image=try decode(file)
                guard expressionBytes+image.width*image.height*4<=8*1024*1024 else {throw CutoutError.invalid("Expression atlas exceeds 8 MiB")}
                expressionImages[slot,default:[]].append(image)
            }
        }
        let neutralMouth = expressionImages["mouth"]?.first
        for shape in rig.mouthShapes ?? [] {
            for file in shape.forms {
                let image: CGImage
                if file == rig.expressions?["mouth"]?.first, let neutralMouth { image = neutralMouth }
                else { image = try decode(file) }
                guard let neutralMouth, image.width == neutralMouth.width, image.height == neutralMouth.height,
                      expressionBytes+image.width*image.height*4 <= 8*1024*1024 else {
                    throw CutoutError.invalid("Mouth shape must match its registered local patch and 8 MiB budget")
                }
                mouthShapeImages[shape.id, default: []].append(image)
            }
        }
        try select(rig.defaults)
    }

    static func bundled(character: String = "deepseek-cutout") throws -> CutoutArtwork {
        let definition = try CutoutCharacter.bundled(character)
        let rig = definition.cutout!
        return try CutoutArtwork(rig: rig) { path in
            Bundle.main.url(forResource: path, withExtension: nil, subdirectory: definition.resourceDirectory)
                ?? Bundle.module.url(forResource: path, withExtension: nil, subdirectory: definition.resourceDirectory)
        }
    }

    private func decode(_ file: String) throws -> CGImage {
        guard let url = resource(file), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 2048, height <= 2048, width*height <= 2_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw CutoutError.invalid("Missing, corrupt or oversized component: \(file)")
        }
        resourceReads += 1; decodedImages += 1
        // ImageIO's immediate-cache hint still leaves a compressed provider in
        // AppKit display lists. Own the finite RGBA buffer so native compositing
        // cannot re-enter the PNG decoder on each frame.
        return try CutoutPixels(image).image(appKitFormat: true)
    }

    func select(_ changes: [String: String]) throws {
        var next = selection.isEmpty ? rig.defaults : selection
        for (category, id) in changes {
            guard rig.variants.contains(where: { $0.id == id && $0.category == category }) else {
                throw CutoutError.invalid("Unknown component selection: \(category)/\(id)")
            }
            next[category] = id
        }
        let variants = rig.variants.filter { next[$0.category] == $0.id }
        let attachments = variants.flatMap(\.attachments)
        let slotIndices = Dictionary(uniqueKeysWithValues: rig.slots.enumerated().map { ($0.element.id, $0.offset) })
        var cache: [String: CGImage] = [:], prepared: [Part] = []
        var bytes = 0
        for a in attachments {
            let index = slotIndices[a.slot]!, slot = rig.slots[index]
            let image: CGImage
            if let hit = cache[a.file] ?? images[a.file] { image = hit }
            else { image = try decode(a.file) }
            if cache[a.file] == nil { bytes += image.width*image.height*4; cache[a.file] = image }
            guard bytes <= 24*1024*1024 else { throw CutoutError.invalid("Selected skin exceeds the 24 MiB decoded budget") }
            let bone = player.indices[slot.bone]!, pivot = player.bindWorld[bone], r = a.rect
            var orientation=CGAffineTransform.identity
            if let angle=a.rotation, let p=a.pivot {
                let x=p[0]-pivot.x,y=p[1]-pivot.y
                orientation=orientation.translatedBy(x:x,y:y).rotated(by:angle * .pi/180).translatedBy(x:-x,y:-y)
            }
            prepared.append(Part(slot: index, bone: bone, image: image,
                rect: CGRect(x: r[0]-pivot.x, y: r[1]-pivot.y, width: r[2], height: r[3]),orientation:orientation))
        }
        prepared.sort {
            let a = rig.slots[$0.slot], b = rig.slots[$1.slot]
            return a.order == b.order ? $0.slot < $1.slot : a.order < b.order
        }
        var preparedUnderlaps = [Underlap]()
        for patch in variants.flatMap({ $0.underlaps ?? [] }) {
            let image: CGImage
            if let cached = cache[patch.file] ?? images[patch.file] { image = cached } else { image = try decode(patch.file) }
            if cache[patch.file] == nil { cache[patch.file] = image;bytes += image.width*image.height*4 }
            guard bytes+expressionBytes <= 24*1024*1024 else { throw CutoutError.invalid("Selected skin exceeds decoded budget") }
            let bone = player.indices[patch.bone]!, pivot = player.bindWorld[bone], r = patch.rect
            preparedUnderlaps.append(.init(bone:bone,triggers:patch.triggers.map { player.indices[$0]! },image:image,
                rect:CGRect(x:r[0]-pivot.x,y:r[1]-pivot.y,width:r[2],height:r[3])))
        }
        var preparedComposites = [Composite]()
        for group in rig.composites ?? [] {
            let members = prepared.filter { group.slots.contains(rig.slots[$0.slot].id) }
            guard !members.isEmpty else { continue }
            let key = group.id+":sourceOver=\(group.sourceOver == true):"+attachments.filter { group.slots.contains($0.slot) }.map { "\($0.slot):\($0.file):\($0.rect)" }.sorted().joined(separator:"|")
            let composite:Composite
            if let hit = composites.first(where: { $0.key == key }) { composite = hit }
            else { composite = try makeComposite(id:group.id,key:key,bone:player.indices[group.bone]!,members:members,sourceOver:group.sourceOver == true) }
            bytes += composite.bytes
            guard bytes+expressionBytes <= 24*1024*1024 else { throw CutoutError.invalid("Local atlas exceeds the selected decoded budget") }
            preparedComposites.append(composite)
        }
        var preparedEyes=[Int:EyeAperture]()
        for eye in rig.eyeClips ?? [] {
            let whiteIndex=slotIndices[eye.white]!,irisIndex=slotIndices[eye.iris]!
            guard let white=prepared.first(where:{$0.slot==whiteIndex}),prepared.contains(where:{$0.slot==irisIndex}) else {continue}
            let attachment=attachments.first{$0.slot==eye.white}!
            let key="\(eye.white):\(attachment.file):\(attachment.rect)"
            let aperture:EyeAperture
            if let hit=eyeApertures[irisIndex],hit.key==key {aperture=hit}
            else {
                let forms=expressionImages[eye.white] ?? [white.image]
                let masks=forms.enumerated().map { index,image in
                    Self.eyeMask(image,closing:eye.closing,amount:Double(index)/Double(max(1,forms.count-1)))
                }
                eyeMaskImagesBuilt += masks.count
                aperture=EyeAperture(key:key,iris:irisIndex,bone:white.bone,rect:white.rect,masks:masks)
            }
            bytes += aperture.bytes;preparedEyes[irisIndex]=aperture
        }
        var preparedCloth=[Int:ClothPatch]()
        for definition in rig.clothDeformations ?? [] {
            let slot=slotIndices[definition.slot]!
            guard let part=prepared.first(where:{$0.slot==slot}),let attachment=attachments.first(where:{$0.slot==definition.slot}) else {continue}
            let key="\(attachment.file)|\(part.rect)"
            let patch:ClothPatch
            if let cached=clothPatches[slot],cached.key==key {patch=cached}
            else {patch=try makeClothPatch(definition,part:part,key:key)}
            bytes+=patch.bytes;preparedCloth[slot]=patch
        }
        guard bytes+expressionBytes<=24*1024*1024 else {throw CutoutError.invalid("Selected face/skin exceeds decoded budget")}
        // Atomic commit after every file, slot and bounded local atlas is prepared.
        images = cache; parts = prepared; underlaps = preparedUnderlaps; selection = next
        composites = preparedComposites;eyeApertures=preparedEyes
        clothPatches=preparedCloth
        decodedBytes = bytes + expressionBytes
    }

    private func makeClothPatch(_ definition:CutoutRig.ClothDeformation,part:Part,key:String)throws->ClothPatch {
        let r=definition.region
        let rect=CGRect(x:r[0],y:r[1],width:r[2],height:r[3]).integral
        guard rect.intersects(part.rect), part.image.width==Int(part.rect.width),part.image.height==Int(part.rect.height) else {
            throw CutoutError.invalid("Cloth patch must have exact native pixel registration")
        }
        let outside=CGMutablePath();outside.addRect(part.rect.insetBy(dx:-8,dy:-8));outside.addRect(rect)
        var triangles=[ClothTriangle](),vertices=[CGPoint]()
        for row in 0...definition.rows {
            let y=rect.minY+rect.height*Double(row)/Double(definition.rows)
            vertices.append(CGPoint(x:rect.minX,y:y));vertices.append(CGPoint(x:rect.maxX,y:y))
        }
        for row in 0..<definition.rows {
            let a=vertices[row*2],b=vertices[row*2+1],c=vertices[row*2+3],d=vertices[row*2+2]
            triangles.append(ClothTriangle(a:a,b:b,c:c));triangles.append(ClothTriangle(a:a,b:c,c:d))
        }
        let steps=14,count=steps*2+1,width=Int(rect.width),height=Int(rect.height)
        guard width*height*4*count<=4*1024*1024,
              let source=CGContext(data:nil,width:part.image.width,height:part.image.height,bitsPerComponent:8,bytesPerRow:part.image.width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CutoutError.invalid("Cloth atlas exceeds its 4 MiB preparation budget")
        }
        source.interpolationQuality = .none;source.draw(part.image,in:CGRect(x:0,y:0,width:part.image.width,height:part.image.height))
        // Raw source pixels are borrowed from this context during atlas creation.
        defer {withExtendedLifetime(source) {}}
        let sourcePixels=source.data!.assumingMemoryBound(to:UInt8.self),sw=part.image.width,sh=part.image.height
        func channel(_ x:Int,_ y:Int,_ c:Int)->Double {
            guard x>=0,y>=0,x<sw,y<sh else {return 0}
            return Double(sourcePixels[(y*sw+x)*4+c])
        }
        var forms=[CGImage]()
        // Rasterize the inverse mesh once per bounded angle. A destination pixel
        // has one source coordinate; shared triangle edges never blend twice.
        for step in -steps...steps {
            let angle=Double(step)*definition.angleLimit/Double(steps)
            let rotation=CGAffineTransform(rotationAngle:angle * .pi/180)
            let compression=definition.compression*Double(abs(step))/Double(steps)
            let stub=ClothPatch(key:key,definition:definition,driver:player.indices[definition.driver]!,forms:[],angleSteps:steps,rect:rect,outside:outside,vertices:vertices)
            guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CutoutError.invalid("Cannot allocate local cloth form")
            }
            let dest=context.data!.assumingMemoryBound(to:UInt8.self)
            for triangle in triangles {
                let a=triangle.a,b=triangle.b,c=triangle.c
                let p=clothPoint(a,stub,rotation,compression),q=clothPoint(b,stub,rotation,compression),r=clothPoint(c,stub,rotation,compression)
                let u=b.x-a.x,v=b.y-a.y,w=c.x-a.x,z=c.y-a.y,det=u*z-v*w
                let aa=((q.x-p.x)*z-(r.x-p.x)*v)/det,cc=((r.x-p.x)*u-(q.x-p.x)*w)/det
                let bb=((q.y-p.y)*z-(r.y-p.y)*v)/det,dd=((r.y-p.y)*u-(q.y-p.y)*w)/det
                let inverse=CGAffineTransform(a:aa,b:bb,c:cc,d:dd,tx:p.x-aa*a.x-cc*a.y,ty:p.y-bb*a.x-dd*a.y).inverted()
                let x0=max(0,Int(floor(min(p.x,q.x,r.x)-rect.minX-0.5))),x1=min(width-1,Int(ceil(max(p.x,q.x,r.x)-rect.minX-0.5)))
                let y0=max(0,Int(floor(rect.maxY-max(p.y,q.y,r.y)-0.5))),y1=min(height-1,Int(ceil(rect.maxY-min(p.y,q.y,r.y)-0.5)))
                guard x0<=x1,y0<=y1 else {continue}
                for y in y0...y1 {for x in x0...x1 {
                    let sourcePoint=CGPoint(x:rect.minX+Double(x)+0.5,y:rect.maxY-Double(y)-0.5).applying(inverse)
                    let dx=sourcePoint.x-a.x,dy=sourcePoint.y-a.y,s=(dx*z-dy*w)/det,t=(u*dy-v*dx)/det
                    guard s>=(-1e-9),t>=(-1e-9),s+t<=1+1e-9 else {continue}
                    let sx=sourcePoint.x-part.rect.minX-0.5,sy=part.rect.maxY-sourcePoint.y-0.5
                    let ix=Int(floor(sx)),iy=Int(floor(sy)),fx=sx-Double(ix),fy=sy-Double(iy)
                    for component in 0..<4 {
                        let top=channel(ix,iy,component)*(1-fx)+channel(ix+1,iy,component)*fx
                        let bottom=channel(ix,iy+1,component)*(1-fx)+channel(ix+1,iy+1,component)*fx
                        dest[(y*width+x)*4+component]=UInt8(min(255,max(0,(top*(1-fy)+bottom*fy).rounded())))
                    }
                }}
            }
            guard let image=context.makeImage() else {throw CutoutError.invalid("Cannot finish cloth form")}
            forms.append(image)
        }
        clothPatchImagesBuilt+=forms.count
        return ClothPatch(key:key,definition:definition,driver:player.indices[definition.driver]!,forms:forms,angleSteps:steps,rect:rect,outside:outside,vertices:vertices)
    }

    private func clothPoint(_ p:CGPoint,_ patch:ClothPatch,_ rotation:CGAffineTransform,_ compressionAmount:Double)->CGPoint {
        let d=patch.definition,bind=player.bindWorld[patch.driver],root=player.bindWorld[0]
        let pivot=CGPoint(x:bind.x-root.x,y:bind.y-root.y)
        let t=min(1,max(0,(p.y-d.waistY)/(d.shoulderY-d.waistY))),weight=t*t*(3-2*t)
        let rotated=CGPoint(x:p.x-pivot.x,y:p.y-pivot.y).applying(rotation)
        let compression=compressionAmount*weight
        return CGPoint(x:p.x+(rotated.x+pivot.x-p.x)*weight-(p.x-pivot.x)*compression,
                       y:p.y+(rotated.y+pivot.y-p.y)*weight)
    }

    /// Reuse a local finite atlas: no per-tick rasterization or triangle clipping.
    /// The source image remains the exact neutral form.
    private func drawCloth(_ part:Part,_ patch:ClothPatch,in context:CGContext)->Int {
        let limit=patch.definition.angleLimit
        let angle=min(limit,max(-limit,player.local[patch.driver].rotation))
        let step=Int((angle/limit*Double(patch.angleSteps)).rounded())
        guard step != 0 else {context.draw(part.image,in:part.rect);return 1}
        context.saveGState();context.setShouldAntialias(false);context.addPath(patch.outside);context.clip(using:.evenOdd)
        context.draw(part.image,in:part.rect);context.restoreGState()
        context.draw(patch.forms[step+patch.angleSteps],in:patch.rect)
        return 2
    }

    private func makeComposite(id:String,key:String,bone:Int,members:[Part],sourceOver:Bool) throws -> Composite {
        let pivot = player.bindWorld[bone]
        let sourceRects = members.map { p in p.rect.offsetBy(dx:player.bindWorld[p.bone].x-pivot.x,dy:player.bindWorld[p.bone].y-pivot.y) }
        let rect = sourceRects.reduce(CGRect.null) { $0.union($1) }.integral
        let blinkCount = members.filter { rig.slots[$0.slot].id != "mouth" }.map { expressionImages[rig.slots[$0.slot].id]?.count ?? 1 }.max() ?? 1
        let mouthCount = members.filter { rig.slots[$0.slot].id == "mouth" }.map { expressionImages[rig.slots[$0.slot].id]?.count ?? 1 }.max() ?? 1
        let width=Int(rect.width),height=Int(rect.height),count=blinkCount*mouthCount
        guard width>0,height>0,width<=1024,height<=1024,count<=16,width*height*4*count<=8*1024*1024 else {
            throw CutoutError.invalid("Local composite exceeds its 8 MiB budget")
        }
        var forms=[CGImage]()
        let images = members.map { expressionImages[rig.slots[$0.slot].id] ?? [$0.image] }
        let masks = images.map { $0.map(Self.coverageMask) }
        for b in 0..<blinkCount { for m in 0..<mouthCount {
            guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CutoutError.invalid("Cannot allocate local composite")
            }
            context.translateBy(x:-rect.minX,y:-rect.minY);context.interpolationQuality = .none
            for (i,part) in members.enumerated() {
                let slot=rig.slots[part.slot].id,atlas=images[i]
                let v = slot == "mouth" ? Double(m)/Double(max(1,mouthCount-1)) : Double(b)/Double(max(1,blinkCount-1))
                let choice=min(atlas.count-1,Int((v*Double(atlas.count-1)).rounded()))
                // A source pixel retains its RGBA when hidden paint lies below
                // it. Binary coverage clips copy to actual painted pixels.
                context.saveGState();context.clip(to:sourceRects[i],mask:masks[i][choice]);context.setBlendMode(.copy)
                context.draw(atlas[choice],in:sourceRects[i]);context.restoreGState()
            }
            guard let image=context.makeImage() else { throw CutoutError.invalid("Cannot finish local composite") }
            forms.append(image)
        } }
        compositeBuilds += 1
        compositeBuildsByID[id,default:0] += 1
        return Composite(key:key,bone:bone,sourceOver:sourceOver,members:members.map(\.slot),memberBones:members.map(\.bone),rect:rect,forms:forms,masks:forms.map(Self.coverageMask),blinkCount:blinkCount,mouthCount:mouthCount)
    }

    private static func coverageMask(_ image:CGImage)->CGImage {
        let width=image.width,height=image.height
        var rgba=[UInt8](repeating:0,count:width*height*4)
        rgba.withUnsafeMutableBytes { b in
            let context=CGContext(data:b.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        }
        let mask=(0..<width*height).map { rgba[$0*4+3]>0 ? UInt8(0) : UInt8(255) }
        return CGImage(maskWidth:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,
            provider:CGDataProvider(data:Data(mask) as CFData)!,decode:nil,shouldInterpolate:false)!
    }

    private static func eyeMask(_ image:CGImage,closing:Double?,amount:Double)->CGImage {
        guard let closing else {return coverageMask(image)}
        let w=image.width,h=image.height,scale=1-amount,pivot=Double(h)*(1-closing)
        let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        if scale>0 {
            c.addEllipse(in:CGRect(x:0,y:pivot*(1-scale),width:Double(w),height:Double(h)*scale));c.clip()
            c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        }
        return coverageMask(c.makeImage()!)
    }

    /// At display scale, anchor always maps to the requested floor/support
    /// point. Mirroring shares the registration, rather than rescaling PNGs.
    func displayBounds(anchor:CGPoint,scale:Double = 1,mirrored:Bool = false,skeleton:Bool = false) -> CGRect {
        let amount = rig.pointsPerPixel*scale,sign = mirrored ? -amount : amount
        let display = CGAffineTransform(a:sign,b:0,c:0,d:amount,
            tx:anchor.x-rig.anchor[0]*sign,ty:anchor.y-rig.anchor[1]*amount)
        var bounds = CGRect.null
        for part in parts { bounds = bounds.union(part.rect.applying(part.orientation.concatenating(player.world[part.bone]).concatenating(display))) }
        for patch in underlaps { bounds = bounds.union(patch.rect.applying(player.world[patch.bone].concatenating(display))) }
        for patch in clothPatches.values {
            let angle=min(patch.definition.angleLimit,max(-patch.definition.angleLimit,player.local[patch.driver].rotation))
            let rotation=CGAffineTransform(rotationAngle:angle * .pi/180)
            let compression=patch.definition.compression*min(1,abs(angle)/patch.definition.angleLimit)
            let transform=player.world[0].concatenating(display)
            for vertex in patch.vertices {
                let p=clothPoint(vertex,patch,rotation,compression).applying(transform)
                bounds=bounds.union(CGRect(x:p.x,y:p.y,width:0.01,height:0.01))
            }
        }
        if skeleton {
            for bone in player.world {
                let p = CGPoint.zero.applying(bone.concatenating(display))
                bounds = bounds.union(CGRect(x:p.x-3,y:p.y-3,width:6,height:6))
            }
        }
        return bounds.isNull ? .zero : bounds.insetBy(dx:-3,dy:-3).integral
    }

    func draw(in context: CGContext, anchor: CGPoint, scale: Double = 1,
              mirrored: Bool = false, blink: Double = 0, mouth: Double = 0, mouthShape: String? = nil,
              skeleton: Bool = false) {
        guard anchor.x.isFinite, anchor.y.isFinite, scale.isFinite, scale > 0 else { return }
        context.saveGState(); defer { context.restoreGState() }
        let amount = rig.pointsPerPixel*scale
        context.translateBy(x: anchor.x, y: anchor.y)
        context.scaleBy(x: mirrored ? -amount : amount, y: amount)
        context.translateBy(x: -rig.anchor[0], y: -rig.anchor[1])
        // Linear texture sampling preserves pixel-art edges at the app's small
        // display size without the high-order resampling cost per component.
        context.interpolationQuality = .medium
        var covered = 0
        for patch in underlaps {
            let motion = patch.triggers.reduce(0.0) { amount,i in
                let v = player.local[i]
                return max(amount,abs(v.rotation),hypot(v.x,v.y))
            }
            guard motion > 0 else { continue }
            context.saveGState();context.concatenate(player.world[patch.bone]);context.setAlpha(min(1,motion*8))
            context.draw(patch.image,in:patch.rect);context.restoreGState();covered += 1
        }
        var index = 0, individual = 0
        func plane(_ bone:Int)->CGAffineTransform {
            CGAffineTransform(translationX:-player.bindWorld[bone].x,y:-player.bindWorld[bone].y).concatenating(player.world[bone])
        }
        func samePlane(_ a:CGAffineTransform,_ b:CGAffineTransform)->Bool {
            abs(a.a-b.a)<1e-9 && abs(a.b-b.b)<1e-9 && abs(a.c-b.c)<1e-9 && abs(a.d-b.d)<1e-9 && abs(a.tx-b.tx)<1e-9 && abs(a.ty-b.ty)<1e-9
        }
        while index < parts.count {
            let part = parts[index]
            context.saveGState()
            if let group = composites.first(where: { candidate in
                candidate.members.first == part.slot && candidate.memberBones.allSatisfy {
                    samePlane(plane($0),plane(candidate.bone))
                }
            }) {
                func form(_ value:Double,_ count:Int)->Int {
                    Int(((value.isFinite ? min(1,max(0,value)) : 0)*Double(count-1)).rounded())
                }
                context.concatenate(player.world[group.bone])
                let choice=form(blink,group.blinkCount)*group.mouthCount+form(mouth,group.mouthCount)
                // Exact RGBA replacement is valid only while lower attachments share
                // this plane. Once one moves independently, tiny-alpha edge
                // pixels must blend over it rather than erase its coverage.
                let alignedBelow = parts[..<index].allSatisfy {
                    $0.orientation.isIdentity && samePlane(plane($0.bone),plane(group.bone))
                }
                if alignedBelow && !group.sourceOver {
                    context.clip(to:group.rect,mask:group.masks[choice]);context.setBlendMode(.copy)
                } else {
                    context.setBlendMode(.normal)
                }
                context.draw(group.forms[choice],in:group.rect)
                context.restoreGState();index += group.members.count;covered += 1
                continue
            }
            if let eye=eyeApertures[part.slot] {
                let normalized=blink.isFinite ? min(1,max(0,blink)):0
                let choice=min(eye.masks.count-1,Int((normalized*Double(eye.masks.count-1)).rounded()))
                // The exact original neutral is retained. Once the iris moves
                // or the lid closes, the opening owns the visible iris area.
                if choice>0 || !samePlane(plane(part.bone),plane(eye.bone)) {
                    context.concatenate(player.world[eye.bone])
                    context.clip(to:eye.rect,mask:eye.masks[choice])
                    context.concatenate(player.world[eye.bone].inverted())
                }
            }
            context.concatenate(player.world[part.bone])
            if !part.orientation.isIdentity { context.concatenate(part.orientation) }
            var image = part.image
            let slot = rig.slots[part.slot].id
            let forms = slot == "mouth" ? mouthShape.flatMap { mouthShapeImages[$0] } ?? expressionImages[slot] : expressionImages[slot]
            if let forms, !forms.isEmpty {
                let value = slot == "mouth" ? mouth : blink
                let normalized = value.isFinite ? min(1,max(0,value)) : 0
                let choice = min(forms.count-1,max(0,Int((normalized*Double(forms.count-1)).rounded())))
                image = forms[choice]
            }
            if let patch=clothPatches[part.slot] {
                individual+=drawCloth(part,patch,in:context)-1
            } else {context.draw(image, in: part.rect)}
            context.restoreGState()
            index += 1;individual += 1
        }
        drawCount += 1; drawOperations += individual+covered
        if skeleton {
            context.setStrokeColor(NSColor.systemPink.cgColor); context.setFillColor(NSColor.systemPink.cgColor)
            context.setLineWidth(1.4/amount)
            for i in player.world.indices {
                let p = CGPoint.zero.applying(player.world[i])
                if let parent = player.parents[i] {
                    context.move(to: CGPoint.zero.applying(player.world[parent])); context.addLine(to: p); context.strokePath()
                }
                context.fillEllipse(in: CGRect(x: p.x-2/amount, y: p.y-2/amount, width: 4/amount, height: 4/amount))
            }
        }
    }

    static func blink(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        let t = max(0,time).truncatingRemainder(dividingBy: 3.7)
        guard t>=3.40 && t<=3.68 else {return 0}
        let amount=t<3.50 ? (t-3.40)/0.10 : (t<=3.56 ? 1:(3.68-t)/0.12)
        let value=min(1,max(0,amount));return value*value*(3-2*value)
    }

    /// Deterministic opening preview; real audio can feed draw(mouth:) directly.
    static func talkingPreview(at time:Double)->Double {
        guard time.isFinite else {return 0}
        let t=max(0,time).truncatingRemainder(dividingBy:4.6)
        guard t<3.6 else {return 0}
        let envelope=min(1,t/0.15,(3.6-t)/0.20)
        return max(0,envelope)*(0.5-0.5*cos(t*2*Double.pi*2.1))
    }
}
