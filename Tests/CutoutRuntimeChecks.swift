import Foundation
import CoreGraphics

@main struct CutoutRuntimeChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let configuration = root.appendingPathComponent("Sources/CodexCaptions/Resources/CutoutCharacters/deepseek-cutout.json")
        let character = try CutoutCharacter.load(configuration)
        let rig = character.cutout!, playback = character.cutoutPlayback!
        let resources = root.appendingPathComponent("Sources/CodexCaptions/Resources/" + character.resourceDirectory)
        let art = try CutoutArtwork(rig: rig) { resources.appendingPathComponent($0) }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw CutoutError.invalid(message) }
        }
        func render() throws -> CutoutPixels {
            let context = CGContext(data: nil, width: Int(rig.canvas[0]), height: Int(rig.canvas[1]), bitsPerComponent: 8,
                bytesPerRow: Int(rig.canvas[0])*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            art.draw(in: context, anchor: CGPoint(x: rig.anchor[0], y: rig.anchor[1]), scale: 1/rig.pointsPerPixel)
            return try CutoutPixels(context.makeImage()!)
        }
        _ = art.player.play("idle", at: 0, transition: 0); art.player.sample(at: 0)
        let baseline = try CutoutPixels(CutoutPixels.load(resources.appendingPathComponent("neutral.png")))
        try require(try render().rgba == baseline.rgba, "Neutral assembly changed")
        let reads = art.resourceReads, decodes = art.decodedImages, cloth = art.clothPatchImagesBuilt, bytes = art.decodedBytes
        var samples = 0
        for clip in [playback.thinkingClip] + playback.alternativeThinkingClips {
            try require(art.player.play(clip, at: 0, transition: 0), "Missing configured thinking clip")
            let duration = art.player.clips[art.player.clipIndex].definition.duration
            for frame in 0...Int(ceil(duration*30)) {
                let t = Double(frame)/30
                art.player.sample(at: t, gaze: CGPoint(x: sin(t), y: cos(t)))
                _ = try render(); samples += 1
            }
        }
        try require(reads == art.resourceReads && decodes == art.decodedImages && cloth == art.clothPatchImagesBuilt
            && bytes == art.decodedBytes, "Animation tick prepared resources")
        // Invalid mappings and paths fail at load time, before the frame clock.
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as! [String: Any]
        let temporary = root.appendingPathComponent(".build/cutout/runtime-invalid.json")
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["resourceDirectory"] = "../outside" },
            { var p = $0["cutoutPlayback"] as! [String: Any]; p["mouthOpenness"] = [2.0]; $0["cutoutPlayback"] = p },
            { var p = $0["cutoutPlayback"] as! [String: Any]; p["mouthShapeIDs"] = Array(repeating: "unknown", count: 12); $0["cutoutPlayback"] = p },
            { var r = $0["cutout"] as! [String: Any]; r["motions"] = "../outside.json"; $0["cutout"] = r }
        ]
        defer { try? FileManager.default.removeItem(at: temporary) }
        for mutate in mutations {
            var invalid = original; mutate(&invalid)
            try JSONSerialization.data(withJSONObject: invalid).write(to: temporary)
            do { _ = try CutoutCharacter.load(temporary); throw CutoutError.invalid("Invalid runtime configuration accepted") }
            catch CutoutError.invalid(let message) { try require(message != "Invalid runtime configuration accepted", message) }
        }
        print("PASS cutout runtime: exact neutral assembly, \(samples) thinking samples, zero tick preparation, 4 invalid configurations rejected")
    }
}
