import Foundation

/// Playback order is independent of atlas order: lean once, then rise without
/// returning to a crouch or dropping from the early full-height standing pose.
public enum SingingTimeline {
    public static let risingFrames = [0, 1, 5, 3, 6, 7, 4, 9, 8, 10, 12, 13, 14, 15]
    // Each key pose enters 0.04 cycles before its musical anchor and holds
    // through it. Entries remain equally spaced; shorten the intermediate
    // frames to give the accent a wider visible landing window.
    // This is a four-part gesture, not a claim about the song's time signature.
    public static let singingFrames = [16, 17, 18, 20, 19, 21, 22, 23]
    public static let singingFractions = [0.04, 0.20, 0.05, 0.20, 0.05, 0.25, 0.18, 0.03]
    public static let accentPhases = [0.08, 0.33, 0.58]
    public static let keyPosePhases = [0.08, 0.33, 0.58, 0.83]
    public static let defaultCycleDuration: TimeInterval = 3
    public static let segmentsPerCycle = 4.0
    public static func beatsPerSegment(forBPM bpm: Double) -> Double { bpm > 120 ? 2 : 1 }
    // Same 60–360 BPM range accepted by BeatEstimate. Unlocked motion keeps
    // the three-second fallback. Above 120 BPM, every quarter takes two beats.
    public static let cycleDurationRange = (segmentsPerCycle * 2 * 60 / 360)...(segmentsPerCycle * 60 / 60)
    public static let transitionDuration: TimeInterval = 1.2
    public static let transitionFrameDuration = transitionDuration / Double(risingFrames.count)

    public static func singingFrame(at phase: Double) -> Int {
        let position = phase - floor(phase)
        var end = 0.0
        for (frame, fraction) in zip(singingFrames, singingFractions) {
            end += fraction
            if position < end { return frame }
        }
        return singingFrames.last!
    }
}
