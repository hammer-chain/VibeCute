import Foundation
import BTrackBridge

/// Fixed 44.1 kHz/512-hop BTrack input, resampled from the analyzer's 16 kHz clock.
/// Confidence is a local stability gate; BTrack does not expose a probability.
final class BTrackTempoTracker {
    private var tracker: UnsafeMutableRawPointer?
    private var input = [Double](repeating: 0, count: 512)
    private var index = 0
    private var previous: Float = 0
    private var previousTime: Double?
    private var nextTime: Double?
    private var lastBeat: Double?
    private var rawBPM: Double?
    private var stable = 0
    private var active = false
    private var lastMusic = -Double.infinity
    deinit { caption_btrack_free(tracker) }

    func setMusical(_ musical: Bool, at time: Double) {
        active = musical
        if musical {
            lastMusic = time
            if tracker == nil { tracker = caption_btrack_create() }
        }
        else if time - lastMusic > 2 && previousTime != nil { reset() }
    }
    private func reset() {
        caption_btrack_free(tracker); tracker = nil
        index = 0; previousTime = nil; nextTime = nil
        lastBeat = nil; rawBPM = nil; stable = 0
    }
    func consume(_ value: Float, at time: Double) {
        guard value.isFinite, time.isFinite, active || time - lastMusic <= 2 else { return }
        if let previousTime, time <= previousTime || time - previousTime > 0.1 {
            reset(); tracker = caption_btrack_create()
        }
        guard let start = previousTime else {
            previousTime = time; previous = value; nextTime = time; return
        }
        var next = nextTime ?? start
        while next <= time {
            let fraction = max(0, min(1, (next - start) / (time - start)))
            input[index] = Double(previous) + fraction * Double(value - previous)
            index += 1
            if index == input.count, let tracker {
                index = 0
                let detected = input.withUnsafeBufferPointer { caption_btrack_process(tracker, $0.baseAddress) != 0 }
                let bpm = caption_btrack_bpm(tracker)
                if detected && bpm.isFinite && (60...360).contains(bpm) {
                    stable = rawBPM.map { abs(bpm - $0) / $0 < 0.1 } == true ? min(8, stable + 1) : 1
                    rawBPM = bpm; lastBeat = next
                }
            }
            next += 1 / 44_100.0
        }
        nextTime = next; previousTime = time; previous = value
    }
    func estimate(at time: Double, reference: BeatEstimate) -> BeatEstimate {
        let fresh = lastBeat.map { (0...2).contains(time - $0) } ?? false
        let attacks = reference.lastAccentTime.map { (0...2).contains(time - $0) } ?? false
        let usable = active && fresh && attacks && stable >= 4
        return BeatEstimate(bpm: usable ? rawBPM : nil, confidence: usable ? 0.75 : 0,
                            audioTime: time, lastBeatTime: usable ? lastBeat : nil,
                            lastAccentTime: reference.lastAccentTime, engine: .btrack, rawBPM: rawBPM)
    }
}
