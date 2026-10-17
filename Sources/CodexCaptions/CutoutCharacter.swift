import Foundation

/// Runtime data for a cutout character. Loaded once with its artwork;
/// references, edit regions and provenance receipts do not drive playback.
struct CutoutCharacter: Decodable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let resourceDirectory: String
    let cutout: CutoutRig?
    struct Playback: Decodable {
        let thinkingClip: String
        let alternativeThinkingClips: [String]
        let mouthOpenness: [Double]
        let mouthShapeIDs: [String]?
        func mouthInput(for index: Int?) -> (openness: Double, shape: String?) {
            guard let index, mouthOpenness.indices.contains(index) else { return (0, nil) }
            let shape = mouthShapeIDs?[index]
            return (mouthOpenness[index], shape == "default" ? nil : shape)
        }
    }
    let cutoutPlayback: Playback?

    static func load(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024 else { throw CutoutError.invalid("Cutout configuration exceeds 256 KiB") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, !value.id.isEmpty, !value.displayName.isEmpty,
              !value.resourceDirectory.isEmpty, value.resourceDirectory != ".", value.resourceDirectory != "..",
              (value.resourceDirectory as NSString).lastPathComponent == value.resourceDirectory,
              !value.resourceDirectory.contains("\n"), !value.resourceDirectory.contains("\\") else {
            throw CutoutError.invalid("Invalid cutout runtime registration")
        }
        guard let rig = value.cutout, let playback = value.cutoutPlayback else {
            throw CutoutError.invalid("Missing cutout rig or playback configuration")
        }
        _ = try rig.validated()
        let shapes = Set((rig.mouthShapes ?? []).map(\.id) + ["default"])
        guard !playback.thinkingClip.isEmpty, playback.alternativeThinkingClips.count <= 8,
              playback.alternativeThinkingClips.allSatisfy({ !$0.isEmpty }),
              playback.mouthOpenness.count == 12,
              playback.mouthOpenness.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              playback.mouthShapeIDs == nil || (playback.mouthShapeIDs!.count == 12
                  && playback.mouthShapeIDs!.allSatisfy({ shapes.contains($0) })) else {
            throw CutoutError.invalid("Invalid cutout thinking clips or audio mouth mapping")
        }
        return value
    }

    static func bundled(_ id: String = "deepseek-cutout") throws -> Self {
        guard id == (id as NSString).lastPathComponent, !id.isEmpty,
              let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "CutoutCharacters")
                ?? Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "CutoutCharacters") else {
            throw CutoutError.invalid("Missing cutout runtime configuration")
        }
        let value = try load(url)
        guard value.id == id else { throw CutoutError.invalid("Cutout character ID mismatch") }
        return value
    }

    /// Historical proof fixtures contain a rig in an old metadata envelope.
    /// Only the rig is read, without restoring the retired identity contract.
    static func loadRig(_ url: URL) throws -> CutoutRig {
        struct Envelope: Decodable { let cutout: CutoutRig }
        let rig = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).cutout
        return try rig.validated()
    }
}
