import Foundation
import CoreGraphics

/// Artwork, the joint hierarchy and draw order are independent. Coordinates
/// are source pixels, y up. Animation values are deltas from the bind pose.
struct CutoutRig: Codable {
    struct Bone: Codable {
        var id: String
        var parent: String?
        var position: [Double]
    }
    struct Slot: Codable {
        var id: String
        var bone: String
        var order: Int
        var category: String
        var optional: Bool
    }
    struct Attachment: Codable {
        var slot: String
        var file: String
        /// Source placement in the bind pose, independent of PNG whitespace.
        var rect: [Double]
        /// Optional static orientation around a source-canvas attachment point.
        var rotation: Double? = nil
        var pivot: [Double]? = nil
        /// Source-canvas polygon removed once during material preparation.
        var maskOut: [[Double]]? = nil
    }
    struct Variant: Codable {
        var id: String
        var title: String
        var category: String
        var attachments: [Attachment]
        var underlaps: [Underlap]?
        /// nil inherits the rig default; an empty list disables cloth patches.
        var clothDeformations: [ClothDeformation]? = nil
        /// Garment-specific occlusion, prepared on swap rather than per frame.
        var slotOrders: [String:Int]? = nil
        /// Offline union of supported motion bounds, in the original canvas.
        /// Gives native windows room for wider/taller styles without refitting art.
        var displayBounds: [Double]?
    }
    struct Underlap: Codable {
        var bone: String
        var triggers: [String]
        var file: String
        var rect: [Double]
    }
    struct HairstyleDesign: Codable {
        var id: String
        var title: String
        var slots: [String]
        var variant: String?
    }
    struct Composite: Codable {
        var id: String
        var bone: String
        var slots: [String]
        /// Adjacent parts extracted from one overlay retain its original
        /// source-over blending even when every joint is in the bind pose.
        var sourceOver: Bool?
    }
    struct MouthShape: Codable {
        var id: String
        var title: String
        /// Tiny local opening atlas; frame zero is the existing neutral mouth.
        var forms: [String]
    }
    struct TwoBoneConstraint: Codable {
        var id: String
        var upper: String
        var middle: String
        var end: String
        var targetBone: String
        /// Bind-pose source coordinates, converted to target-bone local space.
        var targetPoint: [Double]
        var bend: Double
        var matchTargetRotation: Bool
    }
    struct EyeClip: Codable {
        var white: String
        var iris: String
        /// Optional closing line in normalized source-image y-down space.
        /// This gives clipped PSD whites a rounded animated opening.
        var closing: Double?
    }
    /// Small root-local cloth patch: shoulder motion fades to zero at waist.
    /// The owning slot stays on the root; joints use the named shoulder driver.
    struct ClothDeformation: Codable, Equatable {
        var slot: String
        var driver: String
        var region: [Double]
        var waistY: Double
        var shoulderY: Double
        var rows: Int
        var compression: Double
        var angleLimit: Double
    }
    /// A leaf control bends hair pixels while roots and all head joints stay put.
    struct HairDeformation: Codable {
        var slot: String
        var driver: String
        var rootY: Double
        var tipY: Double
        var maxOffset: Double
        var rows: Int
    }
    var schemaVersion: Int
    var canvas: [Double]
    var anchor: [Double]
    var pointsPerPixel: Double
    var bones: [Bone]
    var slots: [Slot]
    var variants: [Variant]
    var defaults: [String: String]
    var motions: String
    /// Local form atlases, registered per slot. The first form is neutral.
    var expressions: [String: [String]]?
    var mouthShapes: [MouthShape]?
    /// Source-space sole points used only by grounded clips.
    var contacts: [String: [Double]]?
    var hairstyleDesigns: [HairstyleDesign]?
    /// Small local atlases prevent filtering seams between adjacent head masks.
    /// Moving sub-parts automatically fall back to individual drawing.
    var composites: [Composite]?
    /// Cropped legacy ownership and complete redraws have different art QA;
    /// neither changes the original character identity reference snapshots.
    var artworkMode: String?
    var twoBoneConstraints: [TwoBoneConstraint]?
    /// Iris movement is clipped by the current eye opening, in head space.
    var eyeClips: [EyeClip]?
    var gazeRange: [Double]?
    var clothDeformations: [ClothDeformation]?
    var hairDeformations: [HairDeformation]? = nil
    /// One source-space crop for every clip and appearance. Never fit a pose.
    var motionBounds: [Double]? = nil
    /// Includes unique component pixels, expressions, masks and generated atlases.
    var decodedByteLimit: Int? = nil
    var cacheByteLimit: Int { decodedByteLimit ?? 24 * 1024 * 1024 }
    var sharedMotionBounds: CGRect {
        let b = motionBounds ?? [0, 0, canvas[0], canvas[1]]
        return CGRect(x:b[0], y:b[1], width:b[2]-b[0], height:b[3]-b[1])
    }

    func validated() throws -> CutoutRig {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw CutoutError.invalid(message) }
        }
        func pair(_ v: [Double]) -> Bool { v.count == 2 && v.allSatisfy(\.isFinite) }
        try check(schemaVersion == 1 && pair(canvas) && canvas.allSatisfy { $0 > 0 && $0 <= 2048 }
                  && pair(anchor) && pointsPerPixel.isFinite && pointsPerPixel > 0 && pointsPerPixel <= 2,
                  "Invalid cutout coordinate/display registration")
        try check(!bones.isEmpty && bones.count <= 64 && slots.count <= 96 && variants.count <= 64,
                  "Cutout rig exceeds its bounded component budget")
        if let b = motionBounds {
            try check(b.count == 4 && b.allSatisfy { $0.isFinite && abs($0) <= 4096 }
                      && b[0] < b[2] && b[1] < b[3] && b[2]-b[0] <= 4096 && b[3]-b[1] <= 4096,
                      "Invalid shared motion crop")
        }
        try check((1...64*1024*1024).contains(cacheByteLimit), "Invalid decoded cache byte limit")
        try check(artworkMode == nil || ["cropped", "redrawn"].contains(artworkMode!), "Unknown cutout artwork mode")
        var seen = Set<String>()
        for (index, bone) in bones.enumerated() {
            try check(!bone.id.isEmpty && seen.insert(bone.id).inserted && pair(bone.position)
                      && (index == 0 ? bone.parent == nil : bone.parent.map { seen.contains($0) && $0 != bone.id } == true),
                      "Bones must have unique IDs and precede their children")
        }
        let boneIDs = seen
        let boneIndex = Dictionary(uniqueKeysWithValues:bones.enumerated().map{($0.element.id,$0.offset)})
        let constraints=twoBoneConstraints ?? []
        try check(constraints.count<=8 && Set(constraints.map(\.id)).count==constraints.count,
                  "Invalid or excessive two-bone constraints")
        var constrained=Set<String>()
        for c in constraints {
            guard let upper=boneIndex[c.upper],let middle=boneIndex[c.middle],let end=boneIndex[c.end],let target=boneIndex[c.targetBone] else {
                throw CutoutError.invalid("Constraint names an unknown bone")
            }
            try check(!c.id.isEmpty && bones[middle].parent==c.upper && bones[end].parent==c.middle
                      && target<upper && pair(c.targetPoint) && c.targetPoint.allSatisfy{abs($0)<=2048}
                      && (c.bend == 1 || c.bend == -1)
                      && hypot(bones[middle].position[0],bones[middle].position[1])>0.001
                      && hypot(bones[end].position[0],bones[end].position[1])>0.001,
                      "Constraint requires a nonzero chain and an earlier independent target")
            for bone in [c.upper,c.middle,c.end] {
                try check(constrained.insert(bone).inserted,"Constraints cannot write the same joint")
            }
        }
        try check(Set(slots.map(\.id)).count == slots.count && slots.allSatisfy {
            !$0.id.isEmpty && boneIDs.contains($0.bone) && !$0.category.isEmpty
        }, "Invalid or duplicate attachment slot")
        let bySlot = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        let hair=hairDeformations ?? []
        try check(hair.count<=8 && Set(hair.map(\.slot)).count==hair.count,"Invalid hair deformation count")
        for patch in hair {
            try check(bySlot[patch.slot]?.category == "hair" && boneIDs.contains(patch.driver)
                      && slots.allSatisfy({$0.bone != patch.driver}) && bones.allSatisfy({$0.parent != patch.driver})
                      && patch.rootY.isFinite && patch.tipY.isFinite && abs(patch.rootY)<=2048 && abs(patch.tipY)<=2048
                      && abs(patch.rootY-patch.tipY)>=1 && patch.maxOffset.isFinite && (0...24).contains(patch.maxOffset)
                      && (4...16).contains(patch.rows),"Invalid pinned hair-layer deformation")
        }
        let clothConfigurations=[clothDeformations ?? []]+variants.compactMap(\.clothDeformations)
        let cloth=clothConfigurations.flatMap { $0 }
        for configuration in clothConfigurations {
          try check(configuration.count<=4 && Set(configuration.map(\.slot)).count==configuration.count,"Too many or duplicate cloth patches")
          for patch in configuration {
            try check(bySlot[patch.slot]?.bone==bones.first?.id && boneIDs.contains(patch.driver)
                      && bones[boneIndex[patch.driver]!].parent==bones.first?.id
                      && patch.region.count==4 && patch.region.allSatisfy(\.isFinite)
                      && patch.region[2]>0 && patch.region[3]>0 && patch.region[2]*patch.region[3]<=65536
                      && patch.region.allSatisfy{abs($0)<=2048}
                      && patch.waistY.isFinite && patch.shoulderY.isFinite && patch.shoulderY>patch.waistY
                      && patch.waistY>=patch.region[1] && patch.shoulderY<=patch.region[1]+patch.region[3]
                      && (2...12).contains(patch.rows) && patch.compression.isFinite && (0...0.03).contains(patch.compression)
                      && patch.angleLimit.isFinite && patch.angleLimit>0 && patch.angleLimit<=6,
                      "Invalid local shoulder/waist cloth deformation")
          }
        }
        let eyes=eyeClips ?? []
        try check(eyes.count<=4 && Set(eyes.map(\.iris)).count==eyes.count && eyes.allSatisfy {
            $0.white != $0.iris && bySlot[$0.white] != nil && bySlot[$0.iris] != nil
                && ($0.closing == nil || ($0.closing!.isFinite && $0.closing!>=0 && $0.closing!<=1))
        },"Invalid eye aperture registration")
        if let range=gazeRange {
            try check(pair(range) && range.allSatisfy{$0>=0 && $0<=32},"Invalid gaze displacement range")
        }
        var compositeSets = [Set<String>]()
        try check((composites ?? []).count<=8,"Too many local composites")
        for group in composites ?? [] {
            try check(cloth.allSatisfy{!group.slots.contains($0.slot)},"Cloth patch cannot use a flattened composite")
            try check(boneIDs.contains(group.bone) && !group.id.isEmpty && !group.slots.isEmpty
                      && group.slots.count <= 24 && Set(group.slots).count == group.slots.count
                      && group.slots.allSatisfy { bySlot[$0] != nil },
                      "Invalid local composite")
            let current=Set(group.slots)
            try check(compositeSets.allSatisfy { previous in
                current.isDisjoint(with:previous) || current.isStrictSubset(of:previous)
            },"Composite groups must be disjoint or nested after their parent")
            compositeSets.append(current)
            try check(eyes.allSatisfy{!current.contains($0.iris)},"Dynamic iris clipping cannot use a flattened composite")
            let ordered = slots.enumerated().sorted {
                $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order
            }.map(\.element)
            let indices = ordered.indices.filter { group.slots.contains(ordered[$0].id) }
            try check(indices.count == group.slots.count && indices.last!-indices.first!+1 == indices.count,
                      "Composite slots must be contiguous in draw order")
        }
        try check(Set(variants.map(\.id)).count == variants.count, "Duplicate cutout variant")
        for variant in variants {
            if let orders=variant.slotOrders {
                try check(variant.category == "clothes" && orders.count<=slots.count && orders.allSatisfy { id,order in
                    guard let slot=bySlot[id] else {return false}
                    return (-128...128).contains(order) && (slot.category == "identity" || variant.attachments.contains {$0.slot==id})
                        && !(composites ?? []).contains {$0.slots.contains(id)}
                },"Draw-order overrides require known identity or owned clothing slots")
                let ordered=slots.enumerated().sorted { a,b in
                    let x=orders[a.element.id] ?? a.element.order,y=orders[b.element.id] ?? b.element.order
                    return x==y ? a.offset<b.offset : x<y
                }.map(\.element)
                for group in composites ?? [] {
                    let indices=ordered.indices.filter {group.slots.contains(ordered[$0].id)}
                    try check(indices.last!-indices.first!+1==indices.count,"Garment draw order separates a local composite")
                }
            }
            if let patches=variant.clothDeformations {
                try check(variant.category == "clothes" && patches.allSatisfy { patch in
                    variant.attachments.contains { $0.slot == patch.slot }
                },"Cloth overrides require an owning clothing attachment")
            }
            if let b=variant.displayBounds {
                try check(b.count==4 && b.allSatisfy { $0.isFinite && abs($0)<=2048 }
                          && b[0]<b[2] && b[1]<b[3], "Invalid appearance display bounds")
            }
            try check(!variant.id.isEmpty && !variant.title.isEmpty && !variant.category.isEmpty
                      && Set(variant.attachments.map(\.slot)).count == variant.attachments.count,
                      "Invalid or duplicate variant attachments")
            for part in variant.attachments {
                if let polygon=part.maskOut {
                    try check((3...32).contains(polygon.count) && polygon.allSatisfy {
                        pair($0) && $0.allSatisfy {abs($0)<=2048}
                    },"Invalid attachment exclusion polygon")
                }
                if let angle=part.rotation {
                    try check(angle.isFinite && abs(angle)<=30 && part.pivot?.count==2
                              && part.pivot!.allSatisfy { $0.isFinite && abs($0)<=2048 }
                              && !(composites ?? []).contains(where: { $0.slots.contains(part.slot) })
                              && expressions?[part.slot]==nil
                              && !cloth.contains(where: { $0.slot==part.slot }),
                              "Static orientation requires an independent attachment and finite pivot")
                } else {try check(part.pivot==nil,"Attachment pivot requires a static orientation")}
                try check(bySlot[part.slot]?.category == variant.category
                          && Self.safeResource(part.file) && part.rect.count == 4
                          && part.rect.allSatisfy(\.isFinite) && part.rect[2] > 0 && part.rect[3] > 0
                          && part.rect[2] <= 2048 && part.rect[3] <= 2048,
                          "Attachment violates its slot or coordinate contract")
            }
            for patch in variant.underlaps ?? [] {
                try check(boneIDs.contains(patch.bone) && !patch.triggers.isEmpty && patch.triggers.allSatisfy { boneIDs.contains($0) }
                          && Self.safeResource(patch.file) && patch.rect.count == 4 && patch.rect.allSatisfy(\.isFinite)
                          && patch.rect[2] > 0 && patch.rect[3] > 0 && patch.rect[2] <= 2048 && patch.rect[3] <= 2048,
                          "Invalid articulated joint coverage")
            }
            let required = Set(slots.filter { $0.category == variant.category && !$0.optional }.map(\.id))
            try check(required.isSubset(of: Set(variant.attachments.map(\.slot))),
                      "Variant omits a required identity/clothing component")
        }
        let categories = Set(slots.map(\.category))
        try check(Set(defaults.keys) == categories && defaults.allSatisfy { category, id in
            variants.contains { $0.id == id && $0.category == category }
        } && Self.safeResource(motions), "Invalid default appearance or motion resource")
        for (slot, files) in expressions ?? [:] {
            try check(bySlot[slot] != nil && !files.isEmpty && files.count <= 16 && files.allSatisfy(Self.safeResource),
                      "Invalid local expression atlas")
        }
        if let shapes = mouthShapes {
            try check(!shapes.isEmpty && shapes.count <= 8 && bySlot["mouth"] != nil
                      && Set(shapes.map(\.id)).count == shapes.count
                      && shapes.allSatisfy { !$0.id.isEmpty && $0.id != "default" && !$0.title.isEmpty
                          && (2...16).contains($0.forms.count) && $0.forms.allSatisfy(Self.safeResource)
                          && $0.forms.first == expressions?["mouth"]?.first },
                      "Invalid bounded mouth-shape atlas")
            try check((composites ?? []).allSatisfy { !$0.slots.contains("mouth") },
                      "Named mouth shapes require an independent mouth slot")
        }
        for (bone, point) in contacts ?? [:] {
            try check(boneIDs.contains(bone) && pair(point) && point.allSatisfy { abs($0) <= 2048 }, "Invalid support contact")
        }
        if let designs = hairstyleDesigns {
            try check(designs.count <= 32 && Set(designs.map(\.id)).count == designs.count,
                      "Invalid hairstyle catalogue")
            for design in designs {
                try check(!design.id.isEmpty && !design.title.isEmpty && design.slots.allSatisfy { bySlot[$0]?.category == "hair" }
                          && (design.variant == nil || variants.contains { $0.id == design.variant && $0.category == "hair" }),
                          "Hairstyle catalogue violates the hair-slot contract")
            }
        }
        return self
    }

    static func safeResource(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\")
            && value.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }
}

enum CutoutError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let s): return s } }
}

struct CutoutTransform: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var rotation: Double = 0
    static let identity = CutoutTransform()

    static func blend(_ a: Self, _ b: Self, _ weight: Double) -> Self {
        let w = min(1, max(0, weight))
        let angle = atan2(sin((b.rotation-a.rotation) * .pi/180), cos((b.rotation-a.rotation) * .pi/180)) * 180 / .pi
        return Self(x: a.x+(b.x-a.x)*w, y: a.y+(b.y-a.y)*w, rotation: a.rotation+angle*w)
    }
}

struct CutoutMotionLibrary: Codable {
    enum Interpolation: String, Codable { case smooth, step }
    struct ScalarKey: Codable {
        var time: Double
        var value: Double
    }
    struct Key: Codable {
        var time: Double
        var value: CutoutTransform
    }
    struct Track: Codable {
        var bone: String
        var keys: [Key]
        var interpolation: Interpolation? = nil
    }
    struct Clip: Codable {
        var id: String
        var title: String
        var duration: Double
        var loop: Bool
        var tracks: [Track]
        var grounded: Bool?
        var constraints: [String]?
        /// Optional authored lid timing; manual eyes remain independent.
        var blink: [ScalarKey]?
        /// Durations of the sorted union of bone/lid key intervals, in seconds.
        /// Sampling remains continuous; no full-body bitmap frames are generated.
        var frameDurations: [Double]? = nil
        var startPose: String? = nil
        var endPose: String? = nil
        /// Non-looping clips hold their endpoint when absent.
        var fallback: String? = nil
        var interpolation: Interpolation? = nil
        /// Optional source-frame IDs for checking an authored cadence.
        var referenceFrames: [Int]? = nil
    }
    var schemaVersion: Int
    var clips: [Clip]
    /// Unspecified bones in a named pose use their bind-pose delta (identity).
    var poses: [String: [String: CutoutTransform]]? = nil
}

/// Compiled indices avoid searching IDs or reparsing JSON on each tick. Clips
/// never mention a costume, hair PNG or optional attachment.
final class CutoutPlayer {
    struct Track {
        let bone: Int
        let keys: [CutoutMotionLibrary.Key]
        var stepped = false
        func value(at t: Double) -> CutoutTransform {
            guard let first = keys.first, let last = keys.last else { return .identity }
            if t <= first.time { return first.value }
            if t >= last.time { return last.value }
            let time = stepped ? t+1e-9 : t
            var low = 0, high = keys.count-1
            while high-low > 1 {
                let middle = (low+high)/2
                if keys[middle].time <= time { low = middle } else { high = middle }
            }
            if stepped { return keys[low].value }
            let a = keys[low], b = keys[high], w = (t-a.time)/(b.time-a.time)
            return .blend(a.value, b.value, w*w*(3-2*w))
        }
    }
    struct Clip {
        let definition: CutoutMotionLibrary.Clip
        let tracks: [Track]
        let constraintIndices: Set<Int>
        let blinkTrack: Track?
        let keyTimes: [Double]
        let frameEnds: [Double]
        let duration: Double
        let identityTiming: Bool
        private func frameIndex(at t:Double)->Int {
            var low=0,high=frameEnds.count-1
            while low<high {
                let middle=(low+high)/2
                if t+1e-9 < frameEnds[middle] {high=middle} else {low=middle+1}
            }
            return low
        }
        func referenceFrame(at elapsed:Double)->Int? {
            guard let frames=definition.referenceFrames else {return nil}
            let t=definition.loop ? max(0,elapsed).truncatingRemainder(dividingBy:duration):min(max(0,elapsed),duration)
            return frames[frameIndex(at:t)]
        }
        func remainingFrameTime(at elapsed:Double)->Double {
            let t=definition.loop ? max(0,elapsed).truncatingRemainder(dividingBy:duration):min(max(0,elapsed),duration)
            return max(0.0001,frameEnds[frameIndex(at:t)]-t)
        }
        func phase(at elapsed: Double) -> Double {
            let t = definition.loop ? elapsed.truncatingRemainder(dividingBy:duration) : min(elapsed,duration)
            if identityTiming { return t }
            if t >= duration { return definition.duration }
            var low = 0, high = frameEnds.count-1
            while low < high {
                let mid = (low+high)/2
                if t < frameEnds[mid] { high = mid } else { low = mid+1 }
            }
            let start = low == 0 ? 0 : frameEnds[low-1]
            return keyTimes[low] + (keyTimes[low+1]-keyTimes[low]) * (t-start)/(frameEnds[low]-start)
        }
    }
    private struct Constraint {
        let upper:Int, middle:Int, end:Int, target:Int
        let point:CGPoint
        let upperLength:Double, lowerLength:Double, upperAngle:Double, lowerAngle:Double
        let bend:Double, matchRotation:Bool
    }
    let rig: CutoutRig
    let clips: [Clip]
    let indices: [String: Int]
    let parents: [Int?]
    let bindWorld: [CGPoint]
    private let contactPoints: [(Int, CGPoint)]
    private let constraints:[Constraint]
    private var constraintWeights:[Double]
    private var sourceConstraintWeights:[Double]
    private(set) var local: [CutoutTransform]
    private(set) var world: [CGAffineTransform]
    private var source: [CutoutTransform]
    private var transitionStarted = 0.0
    private var transitionDuration = 0.0
    private var sourceBlink = 0.0
    private(set) var clipIndex = 0
    private(set) var startedAt = 0.0
    private(set) var sampledBones = 0
    private(set) var sampledTracks = 0
    private(set) var constraintSolves = 0
    private(set) var constraintRecomputedBones = 0
    private var inspectionTime: Double?

    init(rig: CutoutRig, motions: CutoutMotionLibrary) throws {
        self.rig = try rig.validated()
        let boneIndices = Dictionary(uniqueKeysWithValues: rig.bones.enumerated().map { ($0.element.id, $0.offset) })
        indices = boneIndices
        parents = rig.bones.map { $0.parent.flatMap { boneIndices[$0] } }
        var bind = [CGPoint]()
        for (i, bone) in rig.bones.enumerated() {
            let p = parents[i].map { bind[$0] } ?? .zero
            bind.append(CGPoint(x: p.x+bone.position[0], y: p.y+bone.position[1]))
        }
        bindWorld = bind
        let definitions=(rig.twoBoneConstraints ?? []).sorted{boneIndices[$0.upper]! < boneIndices[$1.upper]!}
        let constraintIndices=Dictionary(uniqueKeysWithValues:definitions.enumerated().map{($0.element.id,$0.offset)})
        constraints=definitions.map { c in
            let u=boneIndices[c.upper]!,m=boneIndices[c.middle]!,e=boneIndices[c.end]!,t=boneIndices[c.targetBone]!
            let upper=rig.bones[m].position,lower=rig.bones[e].position
            return Constraint(upper:u,middle:m,end:e,target:t,
                point:CGPoint(x:c.targetPoint[0]-bind[t].x,y:c.targetPoint[1]-bind[t].y),
                upperLength:hypot(upper[0],upper[1]),lowerLength:hypot(lower[0],lower[1]),
                upperAngle:atan2(upper[1],upper[0])*180 / .pi,lowerAngle:atan2(lower[1],lower[0])*180 / .pi,
                bend:c.bend,matchRotation:c.matchTargetRotation)
        }
        constraintWeights=Array(repeating:0,count:definitions.count)
        sourceConstraintWeights=constraintWeights
        contactPoints = (rig.contacts ?? [:]).map { name, point in
            let index = boneIndices[name]!
            return (index, CGPoint(x:point[0]-bind[index].x,y:point[1]-bind[index].y))
        }
        local = Array(repeating: .identity, count: rig.bones.count)
        world = Array(repeating: .identity, count: rig.bones.count)
        source = local
        guard motions.schemaVersion == 1, !motions.clips.isEmpty, motions.clips.count <= 64,
              Set(motions.clips.map(\.id)).count == motions.clips.count else {
            throw CutoutError.invalid("Invalid motion library")
        }
        let poses = motions.poses ?? [:]
        guard poses.count <= 64, poses.allSatisfy({ id, pose in
            !id.isEmpty && pose.allSatisfy { bone, v in
                boneIndices[bone] != nil && v.x.isFinite && v.y.isFinite && v.rotation.isFinite
                    && abs(v.x) <= 2048 && abs(v.y) <= 2048 && abs(v.rotation) <= 360
            }
        }) else { throw CutoutError.invalid("Invalid named endpoint pose") }
        clips = try motions.clips.map { clip in
            let active=clip.constraints ?? []
            guard Set(active).count==active.count,active.allSatisfy({constraintIndices[$0] != nil}) else {
                throw CutoutError.invalid("Motion names an unknown or duplicate constraint")
            }
            guard !clip.id.isEmpty, !clip.title.isEmpty, clip.duration.isFinite, clip.duration > 0, clip.duration <= 120,
                  clip.tracks.count <= rig.bones.count, Set(clip.tracks.map(\.bone)).count == clip.tracks.count else {
                throw CutoutError.invalid("Invalid motion clip")
            }
            let tracks = try clip.tracks.map { track -> Track in
                guard let index = boneIndices[track.bone], track.keys.count >= 2, track.keys.count <= 256,
                      track.keys.first?.time == 0, track.keys.last?.time == clip.duration else {
                    throw CutoutError.invalid("Invalid bone track or missing endpoint")
                }
                var previous = -1.0
                for key in track.keys {
                    guard key.time.isFinite, key.time > previous, key.time <= clip.duration,
                          key.value.x.isFinite, key.value.y.isFinite, key.value.rotation.isFinite,
                          abs(key.value.x) <= 2048, abs(key.value.y) <= 2048, abs(key.value.rotation) <= 360 else {
                        throw CutoutError.invalid("Invalid keyframe")
                    }
                    previous = key.time
                }
                if definitions.contains(where:{$0.middle==track.bone || $0.end==track.bone}),
                   track.keys.contains(where:{$0.value.x != 0 || $0.value.y != 0}) {
                    throw CutoutError.invalid("Constrained limb lengths cannot be translated by a track")
                }
                if clip.loop, track.keys.first!.value != track.keys.last!.value {
                    throw CutoutError.invalid("Loop must preserve its endpoint pose")
                }
                return Track(bone: index, keys: track.keys,stepped:(track.interpolation ?? clip.interpolation) == .step)
            }
            var blinkTrack:Track?
            if let keys=clip.blink {
                guard keys.count>=2,keys.count<=256,keys.first?.time==0,keys.last?.time==clip.duration,
                      !clip.loop || keys.first!.value==keys.last!.value else {
                    throw CutoutError.invalid("Invalid blink endpoints or key budget")
                }
                var previous = -1.0
                for key in keys {
                    guard key.time.isFinite,key.time>previous,key.time<=clip.duration,
                          key.value.isFinite,(0...1).contains(key.value) else {
                        throw CutoutError.invalid("Invalid blink timing or value")
                    }
                    previous=key.time
                }
                blinkTrack=Track(bone:-1,keys:keys.map{.init(time:$0.time,value:.init(x:$0.value,y:0,rotation:0))},stepped:clip.interpolation == .step)
            }
            for (name, end) in [(clip.startPose, false), (clip.endPose, true)] {
                if let name {
                    guard let pose = poses[name], rig.bones.enumerated().allSatisfy({ i, bone in
                        let value = tracks.first { $0.bone == i }.map { end ? $0.keys.last!.value : $0.keys.first!.value } ?? .identity
                        return value == (pose[bone.id] ?? .identity)
                    }) else { throw CutoutError.invalid("Clip \(clip.id) violates its locked endpoint pose") }
                }
            }
            let times = Array(Set([0,clip.duration] + tracks.flatMap { $0.keys.map(\.time) }
                + (clip.blink ?? []).map(\.time))).sorted()
            let original = zip(times,times.dropFirst()).map { $1-$0 }
            let durations = clip.frameDurations ?? original
            guard durations.count == original.count, durations.allSatisfy({ $0.isFinite && $0 >= 0.001 && $0 <= 120 }),
                  durations.reduce(0,+) <= 120, !clip.loop || clip.fallback == nil else {
                throw CutoutError.invalid("Invalid frame durations or looping fallback")
            }
            if let frames=clip.referenceFrames {
                guard clip.interpolation == .step, frames.count==durations.count,
                      frames.allSatisfy({(0...255).contains($0)}) else {
                    throw CutoutError.invalid("Invalid reference-frame cadence")
                }
            }
            let identity = zip(durations,original).allSatisfy { abs($0-$1) < 1e-10 }
            var total = 0.0
            let ends = durations.map { total += $0; return total }
            let playbackDuration=(total*1e12).rounded()/1e12
            return Clip(definition: clip, tracks: tracks,constraintIndices:Set(active.map{constraintIndices[$0]!}),blinkTrack:blinkTrack,
                        keyTimes:times,frameEnds:ends,duration:identity ? clip.duration : playbackDuration,identityTiming:identity)
        }
        for clip in clips {
            if let fallback = clip.definition.fallback {
                guard let target = clips.first(where: { $0.definition.id == fallback }),
                      target.definition.id != clip.definition.id,
                      clip.constraintIndices == target.constraintIndices,
                      (clip.definition.grounded == true) == (target.definition.grounded == true),
                      rig.bones.indices.allSatisfy({ i in
                          (clip.tracks.first { $0.bone == i }?.keys.last?.value ?? .identity)
                            == (target.tracks.first { $0.bone == i }?.keys.first?.value ?? .identity)
                      }), (clip.blinkTrack?.keys.last?.value.x ?? 0) == (target.blinkTrack?.keys.first?.value.x ?? 0) else {
                    throw CutoutError.invalid("Fallback must preserve body, constraints and lid endpoints")
                }
            }
            var visited = Set<String>(), current = clip
            while let next = current.definition.fallback {
                guard visited.insert(current.definition.id).inserted,
                      let target = clips.first(where: { $0.definition.id == next }) else {
                    throw CutoutError.invalid("Cyclic or missing fallback")
                }
                current = target
            }
        }
        sample(at: 0)
    }

    @discardableResult
    func play(_ id: String, at now: Double, transition: Double = 0.25, blink:Double? = nil) -> Bool {
        guard now.isFinite, transition.isFinite, let index = clips.firstIndex(where: { $0.definition.id == id }) else { return false }
        sample(at: now) // interrupted blends begin at the currently displayed pose
        sourceBlink=blink ?? automaticBlink(at:now,fallback:0)
        source = local
        sourceConstraintWeights = constraintWeights
        clipIndex = index; startedAt = now; transitionStarted = now
        transitionDuration = max(0, min(2, transition, clips[index].duration))
        inspectionTime = nil
        return true
    }

    func seek(to phase:Double,at now:Double) {
        guard phase.isFinite,now.isFinite else { return }
        startedAt = now-min(clips[clipIndex].duration,max(0,phase))
        transitionDuration = 0
        inspectionTime = now
        sample(at:now)
    }

    /// Resolve by absolute elapsed time, including late ticks. No timer or I/O.
    private func resolveCompletion(at now: Double) {
        guard inspectionTime != now else { return }
        inspectionTime = nil
        for _ in 0..<clips.count {
            let clip = clips[clipIndex]
            guard !clip.definition.loop, now-startedAt >= clip.duration,
                  let id = clip.definition.fallback,
                  let index = clips.firstIndex(where: { $0.definition.id == id }) else { return }
            startedAt += clip.duration; clipIndex = index
            transitionDuration = 0
            sourceConstraintWeights = constraints.indices.map { clips[index].constraintIndices.contains($0) ? 1 : 0 }
        }
    }

    /// Uses the same clip clock and compiled key sampler as skeletal motion.
    /// Caller supplies ordinary blinking when a clip has no authored lids.
    func automaticBlink(at now:Double,fallback:Double)->Double {
        guard now.isFinite else {return fallback}
        resolveCompletion(at:now)
        let clip=clips[clipIndex],elapsed=max(0,now-startedAt)
        let phase=clip.phase(at:elapsed)
        let target=clip.blinkTrack?.value(at:phase).x ?? fallback
        let blend=transitionDuration>0 ? min(1,max(0,(now-transitionStarted)/transitionDuration)):1
        let weight=blend*blend*(3-2*blend)
        return sourceBlink+(target-sourceBlink)*weight
    }

    func sample(at now: Double, gaze: CGPoint = .zero, mouth: Double = 0, blink: Double = 0) {
        guard now.isFinite else { return }
        resolveCompletion(at:now)
        let clip = clips[clipIndex], elapsed = max(0, now-startedAt)
        let t = clip.phase(at:elapsed)
        for i in local.indices { local[i] = .identity }
        for track in clip.tracks { local[track.bone] = track.value(at: t) }
        let blend = transitionDuration > 0 ? min(1, max(0, (now-transitionStarted)/transitionDuration)) : 1
        if blend < 1 {
            let eased = blend*blend*(3-2*blend)
            for i in local.indices { local[i] = .blend(source[i], local[i], eased) }
        }
        // Orthogonal channels replace only their declared feature joints.
        if let i = indices["gaze"], gaze.x.isFinite, gaze.y.isFinite {
            let radius = max(1, hypot(gaze.x, gaze.y)),range=rig.gazeRange ?? [4,3]
            local[i].x += gaze.x/radius*range[0]; local[i].y += gaze.y/radius*range[1]
        }
        // Expressions are local attachment choices, not a second body pose.
        _ = mouth; _ = blink
        for i in world.indices {
            let p = rig.bones[i].position, v = local[i], angle = v.rotation * .pi/180
            let localMatrix = CGAffineTransform(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle),
                                               tx: p[0]+v.x, ty: p[1]+v.y)
            world[i] = localMatrix.concatenating(parents[i].map { world[$0] } ?? .identity)
        }
        let easedBlend=blend*blend*(3-2*blend)
        for (index,c) in constraints.enumerated() {
            let targetWeight=clip.constraintIndices.contains(index) ? 1.0:0.0
            constraintWeights[index]=sourceConstraintWeights[index]+(targetWeight-sourceConstraintWeights[index])*easedBlend
            // Source poses already contain the previous solve. Re-applying a
            // partial source weight at blend=0 would jump on interruption.
            // Release uses the normal authored-pose blend; acquisition fades
            // the correction in unless the source was already fully locked.
            let weight=targetWeight==0 ? 0 : (sourceConstraintWeights[index]>=1 ? 1:easedBlend)
            guard weight>0 else {continue}
            let target=c.point.applying(world[c.target]),origin=CGPoint.zero.applying(world[c.upper])
            guard let (shoulder,elbow)=Self.solveIK(target:CGPoint(x:target.x-origin.x,y:target.y-origin.y),upper:c.upperLength,lower:c.lowerLength,bend:c.bend) else {continue}
            let parentAngle=parents[c.upper].map{atan2(world[$0].b,world[$0].a)*180 / .pi} ?? 0
            func rotated(_ value:CutoutTransform,_ angle:Double)->CutoutTransform {
                var goal=value;goal.rotation=angle;return .blend(value,goal,weight)
            }
            local[c.upper]=rotated(local[c.upper],shoulder-parentAngle-c.upperAngle)
            local[c.middle]=rotated(local[c.middle],elbow+c.upperAngle-c.lowerAngle)
            if c.matchRotation {
                let targetAngle=atan2(world[c.target].b,world[c.target].a)*180 / .pi
                local[c.end]=rotated(local[c.end],targetAngle-parentAngle-local[c.upper].rotation-local[c.middle].rotation)
            }
            for i in c.upper..<world.count {
                let p=rig.bones[i].position,v=local[i],angle=v.rotation * .pi/180
                let matrix=CGAffineTransform(a:cos(angle),b:sin(angle),c:-sin(angle),d:cos(angle),tx:p[0]+v.x,ty:p[1]+v.y)
                world[i]=matrix.concatenating(parents[i].map{world[$0]} ?? .identity)
            }
            constraintSolves+=1;constraintRecomputedBones+=world.count-c.upper
        }
        if clip.definition.grounded == true, !contactPoints.isEmpty {
            var floor = Double.infinity
            for (bone, point) in contactPoints { floor = min(floor,point.applying(world[bone]).y) }
            let correction = rig.anchor[1]-floor
            for i in world.indices { world[i].ty += correction }
        }
        sampledBones += rig.bones.count; sampledTracks += clip.tracks.count
    }

    /// Analytic two-link IK, clamped to reach. Used by interaction tracks rather
    /// than simulating an unconstrained physical ragdoll.
    static func solveIK(target: CGPoint, upper: Double, lower: Double, bend: Double = 1) -> (Double, Double)? {
        guard target.x.isFinite, target.y.isFinite, upper.isFinite, lower.isFinite,
              upper > 0, lower > 0, bend.isFinite else { return nil }
        let distance = min(upper+lower, max(abs(upper-lower)+0.000001, hypot(target.x, target.y)))
        let elbow = acos(min(1, max(-1, (distance*distance-upper*upper-lower*lower)/(2*upper*lower)))) * (bend >= 0 ? 1 : -1)
        let shoulder = atan2(target.y, target.x)-atan2(lower*sin(elbow), upper+lower*cos(elbow))
        return (shoulder*180 / .pi, elbow*180 / .pi)
    }
}
