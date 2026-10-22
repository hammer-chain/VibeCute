// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Distributed apps use Contents/Resources, without SwiftPM's absolute build-path fallback.
let distributionBuild = ProcessInfo.processInfo.environment["CAPTIONS_DISTRIBUTION_BUILD"] == "1"

let releaseProfile = ProcessInfo.processInfo.environment["CAPTIONS_BUILD_PROFILE"] == "release"
if releaseProfile {
    let config = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("config/build-profiles/release.json"))) as! [String: Any]
    precondition(config["schema"] as? Int == 1 && config["tempo"] as? String == "beatnet" && config["lip"] as? String == "mfcc")
    precondition((config["features"] as? [String: Bool])?.values.allSatisfy { !$0 } == true, "Unsupported release capabilities")
}
let profileSettings: [SwiftSetting] = releaseProfile ? [.define("VIBECUTE_RELEASE")] : []
let releaseAppExcludes = ["DeveloperSettingsView.swift", "CutoutStudio.swift", "CutoutComparison.swift", "CutoutArtwork.swift", "CutoutOverlay.swift", "CutoutRig.swift", "CutoutCharacter.swift", "CutoutPixels.swift", "JapaneseKeywordSpeech.swift", "WhisperKeywordSpeech.swift", "KeywordSpeech.swift", "NowPlayingMonitor.swift"]
let releaseCoreExcludes = ["AubioTempoTracker.swift", "BTrackTempoTracker.swift", "VocalSeparationPipeline.swift", "VocalWorkerTransport.swift", "VocalStereoResampler.swift"]

let package = Package(
    name: "CodexCaptions",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexCaptions", targets: ["CodexCaptions"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "ZstdBridge"),
        .target(name: "BeatNetBridge", exclude: ["vendor", "runtime", "COPYING", "UPSTREAM.md"]),
        .target(name: "SamplerateBridge", exclude: ["COPYING"], cSettings: [.define("HAVE_STDBOOL_H"), .define("ENABLE_SINC_BEST_CONVERTER", to: "1"), .define("ENABLE_SINC_MEDIUM_CONVERTER", to: "1"), .define("ENABLE_SINC_FAST_CONVERTER", to: "1")]),
        .target(name: "BTrackBridge", dependencies: ["SamplerateBridge"], exclude: ["COPYING", "UPSTREAM.md"], cSettings: [.define("USE_KISS_FFT"), .headerSearchPath("vendor")], cxxSettings: [.define("USE_KISS_FFT"), .headerSearchPath("vendor")]),
        .target(name: "AubioBridge", exclude: ["COPYING", "UPSTREAM.md"],
                cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("."), .headerSearchPath("vendor")],
                linkerSettings: [.linkedFramework("Accelerate")]),
        .target(name: "CaptionCore", dependencies: releaseProfile ? ["ZstdBridge", "BeatNetBridge", "CSQLite"] : ["ZstdBridge", "AubioBridge", "BTrackBridge", "BeatNetBridge", "CSQLite"], exclude: releaseProfile ? releaseCoreExcludes : [], swiftSettings: profileSettings),
        .executableTarget(name: "CodexCaptions", dependencies: ["CaptionCore"],
                          exclude: (distributionBuild ? ["Resources"] : ["Resources/rain-bed.mp3", "Resources/rain-drops.mp3"]) + (releaseProfile ? releaseAppExcludes : []),
                          resources: distributionBuild ? [] : [.copy("Resources/DeepSeekThinking"), .copy("Resources/OrangeHoodieThinking"), .copy("Resources/DeepSeekCutout"), .copy("Resources/CutoutCharacters"), .copy("Resources/CodexThinking"), .copy("Resources/LipVowels.json"), .copy("Resources/rain-bed-loop.wav"), .copy("Resources/rain-drops-loop.wav"), .copy("Resources/thunder.wav"), .copy("Resources/thunder-soft.wav"), .copy("Resources/thunder-roll.wav"), .copy("Resources/thunder-double.wav"), .copy("Resources/basin-hit.wav"), .copy("Resources/OpenCodeNavigation"), .copy("Resources/DSHBridge")],
                          swiftSettings: profileSettings + (distributionBuild ? [.define("CAPTIONS_DISTRIBUTION_BUILD")] : [])),
        .executableTarget(name: "ReleaseCoreChecks", dependencies: ["CaptionCore"], path: "Tests/ReleaseCore"),
        .executableTarget(name: "CaptionCoreChecks", dependencies: ["CaptionCore", "CSQLite"], path: "Tests/CaptionCoreTests"),
        .executableTarget(name: "LipClassifierExperiment", dependencies: ["CaptionCore"], path: "Tests/LipClassifierExperiment"),
        .executableTarget(name: "VocalSeparationExperiment", dependencies: ["CaptionCore"], path: "Tests/VocalSeparationExperiment")
    ]
)
