import AppKit

/// Lossless, pose-local ownership masks. No synthesized clothing or resampled body.
/// Parts contain only pixels visible in the source pose; concealed artwork is not invented.
final class HybridHoodieArtwork {
    enum Part: Int, CaseIterable { case body, head, hair }
    struct Pose {
        let parts: [NSImage]
        let composite: NSImage
    }
    private(set) var poses: [Pose] = []
    private(set) var decodedBytes = 0
    static let byteBudget = 24 * 1024 * 1024
    static let size = NSSize(width: 384, height: 512)

    init(frames: [NSImage]) {
        for (index, frame) in frames.enumerated() {
            guard let image = frame.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  image.width == 384, image.height == 512 else { continue }
            let stride = 384 * 4, count = stride * 512
            var source = [UInt8](repeating: 0, count: count)
            source.withUnsafeMutableBytes { bytes in
                let ctx = CGContext(data: bytes.baseAddress, width: 384, height: 512,
                    bitsPerComponent: 8, bytesPerRow: stride,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(origin: .zero, size: Self.size))
            }
            var ownership = [Part](repeating: .body, count: 384 * 512)
            var buffers = Part.allCases.map { _ in [UInt8](repeating: 0, count: count) }
            for y in 0..<512 { for x in 0..<384 {
                let offset = y * stride + x * 4
                guard source[offset+3] != 0 else { continue }
                ownership[y*384+x] = Self.owner(x: x, y: y, frame: index, rgba: source, offset: offset)
            } }
            Self.removeDetachedHair(&ownership, source: source)
            for y in 0..<512 { for x in 0..<384 {
                let offset = y * stride + x * 4
                guard source[offset+3] != 0 else { continue }
                let part = ownership[y*384+x]
                for channel in 0..<4 { buffers[part.rawValue][offset+channel] = source[offset+channel] }
            } }
            let parts = buffers.map { Self.image($0) }
            // Assemble BEFORE display scaling. Filtering disjoint layers separately
            // creates hairline seams at fractional zoom, even with exact masks.
            var composite = [UInt8](repeating: 0, count: count)
            for buffer in buffers {
                for offset in Swift.stride(from: 0, to: count, by: 4) where buffer[offset+3] != 0 {
                    for c in 0..<4 { composite[offset+c] = buffer[offset+c] }
                }
            }
            precondition(composite == source, "Hybrid split must preserve every source pixel")
            // 3 parts + assembled frame, actual decoded RGBA backing size.
            decodedBytes += count * 4
            precondition(decodedBytes <= Self.byteBudget)
            poses.append(Pose(parts: parts, composite: Self.image(composite)))
        }
    }

    /// Blue lash highlights and the tail outline are not independent hair strands.
    private static func removeDetachedHair(_ owners: inout [Part], source: [UInt8]) {
        var visited = [Bool](repeating: false, count: owners.count)
        for seed in owners.indices where !visited[seed] && owners[seed] == .hair && source[seed*4+3] > 12 {
            var component = [seed], cursor = 0
            visited[seed] = true
            while cursor < component.count {
                let p = component[cursor]; cursor += 1
                let x = p % 384, y = p / 384
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x+dx, ny = y+dy
                    guard nx >= 0, nx < 384, ny >= 0, ny < 512 else { continue }
                    let n = ny*384+nx
                    if !visited[n] && owners[n] == .hair && source[n*4+3] > 12 {
                        visited[n] = true; component.append(n)
                    }
                } }
            }
            if component.count < 200 {
                for p in component { owners[p] = p/384 < 244 ? .head : .body }
            }
        }
    }

    private static func image(_ bytes: [UInt8]) -> NSImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: 384, height: 512, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 384 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: size)
    }

    /// Source top-left coordinates. Blue irises and the whale tail belong to
    /// head/body, respectively; the raised hand belongs to the pixel body.
    private static func owner(x: Int, y: Int, frame: Int, rgba: [UInt8], offset: Int) -> Part {
        let px = Double(x) + 0.5, py = Double(y) + 0.5
        // The tail begins outside the skirt on the right, underneath long hair.
        let tail: [[Double]] = [[378,328],[366,341],[342,347],[326,352],[313,362],
            [305,379],[295,396],[281,406],[263,415],[240,423],[384,512],[384,328]]
        if py >= 390 || (py > 328 && px > 240 && contains(tail, px, py)) { return .body }
        let tilted = (2...4).contains(frame)
        let eyes: [[Double]] = tilted
            ? [[118,183],[127,177],[140,178],[151,186],[158,198],[154,210],[144,216],[130,214],[120,205]]
            : [[120,192],[128,185],[139,184],[150,190],[155,200],[152,211],[141,218],[128,215],[120,207]]
        let rightEye: [[Double]] = tilted
            ? [[188,205],[194,198],[206,197],[219,202],[228,212],[228,225],[217,232],[203,229],[192,219]]
            : [[194,204],[200,196],[209,192],[221,195],[234,204],[233,215],[224,223],[212,226],[201,222],[195,215]]
        if contains(eyes, px, py) || contains(rightEye, px, py) { return .head }
        // Keep the hair-mounted orange clip with the hair instead of punching a hole.
        if px > 240 && px < 305 && py > 120 && py < 195 { return .hair }
        let r = Int(rgba[offset]), g = Int(rgba[offset+1]), b = Int(rgba[offset+2])
        let blue = b > r + 8 && b * 100 > g * 106
        if blue { return .hair }
        // Face below the jaw is bounded independently from the fixed raised hand.
        let jaw: [[Double]] = tilted
            ? [[112,204],[241,215],[230,244],[210,259],[181,260],[174,252],
               [166,246],[155,244],[147,248],[133,242],[116,227]]
            : [[106,198],[246,198],[239,228],[221,246],[197,255],[179,256],
               [174,251],[166,246],[155,243],[147,249],[131,245],[116,232]]
        if py < 244 || contains(jaw, px, py) { return .head }
        return .body
    }

    private static func contains(_ polygon: [[Double]], _ x: Double, _ y: Double) -> Bool {
        var inside = false, j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a[1] > y) != (b[1] > y), x < (b[0]-a[0])*(y-a[1])/(b[1]-a[1])+a[0] { inside.toggle() }
            j = i
        }
        return inside
    }

    func draw(frame: Int, in rect: NSRect, visible: Set<Part> = Set(Part.allCases)) {
        guard poses.indices.contains(frame) else { return }
        if visible.count == Part.allCases.count {
            poses[frame].composite.draw(in: rect)
        } else {
            for part in Part.allCases where visible.contains(part) { poses[frame].parts[part.rawValue].draw(in: rect) }
        }
    }
}
