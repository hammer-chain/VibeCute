import Foundation

public enum TempoEngine: String, CaseIterable, Identifiable {
    case aubio, btrack, beatnet, spectral
    public static var available: [Self] { BuildProfile.isRelease ? [.beatnet] : allCases }
    public var id: String { rawValue }
    public var title: String { self == .aubio ? "aubio tempo" : (self == .btrack ? "BTrack（实验）" : (self == .beatnet ? "BeatNet+（实验）" : "原频谱方案")) }
}

