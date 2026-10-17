import Foundation
import AubioBridge


/// Fixed-hop PCM adapter for aubio 0.4.9, using the sample clock throughout.
/// Raw confidence is aubio's score, not a probability and not normalized to 1.
final class AubioTempoTracker {
    private var tracker: UnsafeMutableRawPointer?
    // 8 ms hops at 16 kHz keep aubio's period grid fine enough for fast songs.
    private var input = [Float](repeating: 0, count: 128)
    private var writeIndex = 0
    private var origin: TimeInterval?
    private var lastSample: TimeInterval = -.infinity
    private var lastBeat: TimeInterval?
    private var stableBeats = 0
    private var previousBPM: Double?
    private var active = false
    private var scaleResolver = TempoScaleResolver()
    private var lastMusic: TimeInterval = -.infinity
    private(set) var rawBPM: Double?
    private(set) var confidence: Float = 0

    deinit { caption_aubio_free(tracker) }

    func setMusical(_ musical: Bool, at time: TimeInterval) {
        guard time.isFinite else { active = false; return }
        active = musical
        if musical {
            lastMusic = time
            if tracker == nil { tracker = caption_aubio_create(16_000, 1024, 128) }
        } else if tracker != nil && time - lastMusic > 2 {
            clear()
        }
        // Brief classifier gaps suppress output but keep feeding PCM into the
        // observation window. Repeated gaps must not restart an 8-second lock.
    }

    private func clear() {
        caption_aubio_free(tracker); tracker = nil
        writeIndex = 0; origin = nil; lastSample = -.infinity
        lastBeat = nil; stableBeats = 0; previousBPM = nil; rawBPM = nil; confidence = 0
        scaleResolver = TempoScaleResolver()
    }

    func consume(_ value: Float, at time: TimeInterval) {
        guard let tracker, value.isFinite, time.isFinite else { return }
        if time <= lastSample {
            clear()
            if active { self.tracker = caption_aubio_create(16_000, 1024, 128) }
            return
        }
        lastSample = time
        if origin == nil { origin = time - 1 / 16_000 }
        input[writeIndex] = value; writeIndex += 1
        guard writeIndex == input.count else { return }
        writeIndex = 0
        let detected = input.withUnsafeBufferPointer {
            caption_aubio_process(tracker, $0.baseAddress, UInt32($0.count)) != 0
        }
        let bpm = Double(caption_aubio_bpm(tracker))
        let score = caption_aubio_confidence(tracker)
        rawBPM = bpm.isFinite && (60...360).contains(bpm) ? bpm : nil
        confidence = score.isFinite ? max(0, score) : 0
        if detected, let rawBPM {
            let beat = (origin ?? 0) + Double(caption_aubio_last_beat_s(tracker))
            guard beat.isFinite, beat <= time + 1 / 16_000, beat > (lastBeat ?? -.infinity) else { return }
            if let previousBPM, abs(rawBPM - previousBPM) / previousBPM < 0.1 {
                stableBeats = min(4, stableBeats + 1)
            } else { stableBeats = 1 }
            previousBPM = rawBPM; lastBeat = beat
        }
    }

    func estimate(at time: TimeInterval, reference: BeatEstimate) -> BeatEstimate {
        let fresh = lastBeat.map { (0...2).contains(time - $0) } ?? false
        let attacksPresent = reference.lastAccentTime.map { (0...2).contains(time - $0) } ?? false
        let consistent = rawBPM.flatMap { bpm in previousBPM.map { abs(bpm - $0) / $0 < 0.1 } } ?? false
        let usable = active && fresh && attacksPresent && consistent && stableBeats >= 3 && confidence >= 0.01
        let selected = scaleResolver.sample(rawBPM: usable ? rawBPM : nil, reference: reference, at: time)
        // A corrected level uses the observed onset grid's phase. Never report
        // a slow aubio beat timestamp as if it were the faster subdivision.
        let beatTime = scaleResolver.multiplier != 1 && reference.reliable ? reference.lastBeatTime : (fresh ? lastBeat : nil)
        return BeatEstimate(bpm: scaleResolver.multiplier != 1 && !reference.reliable ? nil : selected, confidence: confidence, audioTime: time,
            lastBeatTime: beatTime, lastAccentTime: reference.lastAccentTime, engine: .aubio, rawBPM: rawBPM,
            referenceBPM: reference.reliable ? reference.bpm : nil, tempoMultiplier: scaleResolver.multiplier)
    }
}
