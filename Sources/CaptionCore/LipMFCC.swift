import Foundation

public enum LipMatchingEngine: String, CaseIterable, Identifiable {
    case acoustic, mfcc
    public static var available: [Self] { BuildProfile.isRelease ? [.mfcc] : allCases }
    public var id: String { rawValue }
    public var title: String { self == .acoustic ? "声学规则" : "MFCC 辅助（实验）" }
}

/// Gain-independent spectral features for calibrated vowel-family matching.
/// Input is the existing 1024-point / 16 kHz power spectrum; no new audio window.
public struct LipMFCC {
    public static let dimensions = 12
    private let filters: [[(Int, Float)]]
    private let cosine: [[Float]]

    public init() {
        let bands = 26
        func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
        let edges = (0..<(bands + 2)).map { hz(mel(80) + Double($0) / Double(bands + 1) * (mel(7600) - mel(80))) }
        filters = (0..<bands).map { band in
            (1..<512).compactMap { bin in
                let frequency = Double(bin) * 16000 / 1024
                let weight = min((frequency - edges[band]) / (edges[band + 1] - edges[band]),
                                 (edges[band + 2] - frequency) / (edges[band + 2] - edges[band + 1]))
                guard weight > 0 else { return nil }
                // Frequency-domain pre-emphasis; reuse the original FFT.
                let emphasis = 1 + 0.97 * 0.97 - 2 * 0.97 * cos(2 * .pi * frequency / 16000)
                return (bin, Float(weight * emphasis))
            }
        }
        cosine = (1...Self.dimensions).map { coefficient in
            (0..<bands).map { Float(cos(.pi * Double(coefficient) * (Double($0) + 0.5) / Double(bands))) }
        }
    }

    public func features(power: [Float]) -> [Float]? {
        guard power.count >= 512, power.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let total = power.reduce(0, +)
        guard total > 1e-10 else { return nil }
        let energies = filters.map { filter in
            log(max(1e-8, filter.reduce(Float.zero) { $0 + power[$1.0] * $1.1 } / total))
        }
        return cosine.map { row in zip(row, energies).reduce(Float.zero) { $0 + $1.0 * $1.1 } }
    }
}

/// Multiple templates per family preserve differences between calibrated voices.
/// This is an acoustic vowel classifier, not a language-independent phoneme model.
public struct LipVowelProfile: Codable {
    public struct Template: Codable {
        public let shape: Int
        public let features: [Float]
        public init(shape: MouthShape, features: [Float]) { self.shape = shape.rawValue; self.features = features }
    }
    public let version: Int
    public let scale: [Float]
    public let templates: [Template]
    public init(scale: [Float], templates: [Template]) {
        version = 1; self.scale = scale; self.templates = templates
    }
    public var isValid: Bool {
        let families: Set<Int> = [MouthShape.ah, .eh, .ee, .oh, .oo].reduce(into: []) { $0.insert($1.rawValue) }
        return version == 1 && scale.count == LipMFCC.dimensions && scale.allSatisfy { $0.isFinite && $0 > 0 }
            && !templates.isEmpty && templates.count <= 256
            && templates.allSatisfy { families.contains($0.shape) && $0.features.count == scale.count && $0.features.allSatisfy(\.isFinite) }
            && Set(templates.map(\.shape)) == families
    }
    public func match(_ features: [Float]) -> (shape: MouthShape, confidence: Float, distance: Float)? {
        guard isValid, features.count == scale.count, features.allSatisfy(\.isFinite) else { return nil }
        var best = [Int: Float]()
        for template in templates {
            let distance = zip(zip(features, template.features), scale).reduce(Float.zero) {
                $0 + pow(($1.0.0 - $1.0.1) / $1.1, 2)
            } / Float(scale.count)
            best[template.shape] = min(best[template.shape] ?? .greatestFiniteMagnitude, distance)
        }
        let ranked = best.sorted { $0.value < $1.value }
        guard ranked.count >= 2, let shape = MouthShape(rawValue: ranked[0].key) else { return nil }
        // Margin and absolute distance both matter: an unrelated instrument
        // must not receive a high score just because one template is nearest.
        let margin = max(0, (ranked[1].value - ranked[0].value) / max(0.05, ranked[1].value))
        let confidence = margin * exp(-ranked[0].value / 3)
        return (shape, confidence, ranked[0].value)
    }
}
