import Foundation

/// Compile-time capability boundary; preferences and launch arguments cannot enable stripped features.
public enum BuildProfile {
#if VIBECUTE_RELEASE
    public static let isRelease = true
#else
    public static let isRelease = false
#endif
    public static let experiments = !isRelease
    public static var defaultTempo: TempoEngine { isRelease ? .beatnet : .aubio }
    public static var defaultLip: LipMatchingEngine { isRelease ? .mfcc : .acoustic }
}
