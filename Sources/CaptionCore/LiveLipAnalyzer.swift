import Foundation
import Accelerate

/// Streaming, bounded-memory analysis. 64 ms windows, one decision every 20 ms.
/// This estimates broad mouth shapes from spectral energy, not actual phonemes.
public final class LiveLipAnalyzer {
    private let size = 1024
    private let hop = 320
    private let rate: Double = 16_000
    private var ring = [Float](repeating: 0, count: 1024)
    private var cursor = 0, filled = 0, sinceHop = 0
    private var phase: Double = 0, sum: Float = 0, count: Float = 0
    private var dc: Float = 0
    private var input = [Float](repeating: 0, count: 1024)
    private var imaginary = [Float](repeating: 0, count: 1024)
    private var realOut = [Float](repeating: 0, count: 1024)
    private var imagOut = [Float](repeating: 0, count: 1024)
    private var power = [Float](repeating: 0, count: 512)
    private let window: [Float]
    private let fft: vDSP_DFT_Setup
    private var current = MouthShape.rest, pending = MouthShape.rest
    private var pendingCount = 0, quietCount = 0
    private var sinceVoiced = 100
    private var envelope: Float = 0
    private var recentPeak: Float = 0
    private var analyzedSamples = 0
    private let audioTimeOrigin: Double
    private let trackTempo: Bool
    private var family = MouthShape.eh
    private var familyPending = MouthShape.eh, familyVotes = 0
    public var sensitivity: Float = 1
    public var voicePriority = true
    public var scene = SoundScene.warming
    public var vowelProfile: LipVowelProfile?
    public var collectVowelFeatures = false
    public private(set) var lastVowelFeatures: [Float]?
    private let mfcc = LipMFCC()
    private var voiceGate = VoiceActivityGate()
    private var silentFrames = 0
    private var laughterQuietFrames = 6
    private var beatTracker = BeatTracker()
    #if !VIBECUTE_RELEASE
    private var aubioTracker = AubioTempoTracker()
    private var btrackTracker = BTrackTempoTracker()
    #endif
    private var beatnetTracker = BeatNetTempoTracker()
    public var tempoEngine: TempoEngine = BuildProfile.defaultTempo {
        didSet {
            if BuildProfile.isRelease { tempoEngine = .beatnet }
            guard oldValue != tempoEngine else { return }
            beatTracker = BeatTracker(); beatnetTracker = BeatNetTempoTracker()
            #if !VIBECUTE_RELEASE
            aubioTracker = AubioTempoTracker(); btrackTracker = BTrackTempoTracker()
            #endif
        }
    }

    public init(audioTimeOrigin: Double = 0, trackTempo: Bool = true) {
        self.audioTimeOrigin = audioTimeOrigin; self.trackTempo = trackTempo
        window = (0..<1024).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / 1023) }
        fft = vDSP_DFT_zop_CreateSetup(nil, 1024, .FORWARD)!
    }
    deinit { vDSP_DFT_DestroySetup(fft) }

    /// Caller supplies mono PCM; there is no retained audio beyond the last window.
    public func consume(_ sample: Float, sampleRate: Double) -> LiveLipFrame? {
        guard sampleRate.isFinite, sampleRate >= rate, sample.isFinite else { return nil }
        sum += max(-1, min(1, sample)); count += 1
        phase += rate
        guard phase >= sampleRate else { return nil }
        phase -= sampleRate
        let value = sum / max(1, count); sum = 0; count = 0
        dc += 0.008 * (value - dc)
        ring[cursor] = value - dc
        analyzedSamples += 1
        #if !VIBECUTE_RELEASE
        if trackTempo && tempoEngine == .aubio { aubioTracker.consume(value - dc, at: audioTimeOrigin + Double(analyzedSamples) / rate) }
        if trackTempo && tempoEngine == .btrack { btrackTracker.consume(value - dc, at: audioTimeOrigin + Double(analyzedSamples) / rate) }
        #endif
        if trackTempo && tempoEngine == .beatnet { beatnetTracker.consume(value - dc, at: audioTimeOrigin + Double(analyzedSamples) / rate) }
        cursor = (cursor + 1) % size
        filled = min(size, filled + 1); sinceHop += 1
        guard filled == size, sinceHop >= hop else { return nil }
        sinceHop = 0
        return analyze()
    }

    /// Offline replay only: wait for queued tempo work without dropping accelerated input.
    public func drainTempoAnalysis() { beatnetTracker.drain() }

    private func analyze() -> LiveLipFrame {
        let audioTime = audioTimeOrigin + Double(analyzedSamples) / rate
        var context = scene.fresh(at: audioTime)
        let rhythmContext = context
        var energy: Float = 0, fastEnergy: Float = 0
        for i in 0..<size {
            let value = ring[(cursor + i) % size]
            energy += value * value
            if i >= size - hop { fastEnergy += value * value }
            input[i] = value * window[i]
        }
        let rms = sqrt(energy / Float(size))
        let fastRMS = sqrt(fastEnergy / Float(hop))
        let gain = max(0.25, min(4, sensitivity))
        silentFrames = fastRMS * gain < 0.0008 ? min(10, silentFrames + 1) : 0
        // Actual silence is immediate acoustic evidence. Don't leave a stale
        // music/instrument label onscreen while the slower model winds down.
        if silentFrames >= 10 { context = SoundScene(kind: .silence, audioTime: audioTime) }
        let level = min(1, rms * gain * 7)
        envelope += (level > envelope ? 0.65 : 0.3) * (level - envelope)
        vDSP_DFT_Execute(fft, input, imaginary, &realOut, &imagOut)
        for i in 0..<power.count { power[i] = realOut[i] * realOut[i] + imagOut[i] * imagOut[i] }
        // A short quiet interval between drum hits is still part of the rhythm.
        // Use classifier context here; the tracker expires missing onsets itself.
        let musical = rhythmContext.ready && rhythmContext.kind != .silence &&
            (rhythmContext.music >= 0.3 || rhythmContext.singing >= 0.3)
        var beat = BeatEstimate.unknown
        if trackTempo {
            let spectralBeat = beatTracker.sample(power: power, rms: fastRMS, at: audioTime, musical: musical)
            #if VIBECUTE_RELEASE
            beatnetTracker.setMusical(musical, at: audioTime)
            beat = beatnetTracker.estimate(at: audioTime, reference: spectralBeat)
            #else
            aubioTracker.setMusical(tempoEngine == .aubio && musical, at: audioTime)
            btrackTracker.setMusical(tempoEngine == .btrack && musical, at: audioTime)
            beatnetTracker.setMusical(tempoEngine == .beatnet && musical, at: audioTime)
            beat = tempoEngine == .beatnet ? beatnetTracker.estimate(at: audioTime, reference: spectralBeat) : tempoEngine == .btrack ? btrackTracker.estimate(at: audioTime, reference: spectralBeat) : tempoEngine == .aubio
                ? aubioTracker.estimate(at: audioTime, reference: spectralBeat) : spectralBeat
            #endif
        }
        func band(_ low: Double, _ high: Double) -> Float {
            let lo = max(1, Int(low * Double(size) / rate))
            let hi = min(power.count - 1, Int(high * Double(size) / rate))
            return power[lo...hi].reduce(0, +)
        }
        let total = max(0.0000001, band(60, 7800))
        let voice = band(180, 3800) / total
        let bass = band(60, 180) / total
        let high = band(3800, 7800) / total
        let peak = (4..<250).map { power[$0] }.max() ?? 0
        let speechBins = power[12...224]
        let mean = max(0.0000001, speechBins.reduce(0, +) / Float(speechBins.count))
        let flatness = exp(speechBins.reduce(Float.zero) { $0 + log(max($1, 0.0000001)) }
            / Float(speechBins.count)) / mean
        // Suppress silence, bass kicks, and near-pure alert tones. Instruments can
        // still resemble vowels; don't advertise this as a vocal separator.
        let voiced = rms * gain > 0.0035 && voice > 0.5 && bass < 0.65 && peak / total < 0.58 && flatness < 0.38
        sinceVoiced = voiced ? 0 : sinceVoiced + 1
        let fricative = sinceVoiced < 8 && rms * gain > 0.006 && voice > 0.22 && high > 0.32 && high < 0.78
        recentPeak = max(fastRMS, recentPeak * 0.965)
        let closure = sinceVoiced < 12 && (fastRMS * gain < 0.0025 || fastRMS < recentPeak * 0.12)
        let laughHint = context.kind == .laughter && context.laughter >= 0.25
        let laughBurst = laughHint && fastRMS * gain > 0.0035 && voice > 0.18 && bass < 0.8
        laughterQuietFrames = laughBurst ? 0 : min(6, laughterQuietFrames + 1)
        // Smooth short breaths between ha-ha bursts; a hint cannot open silence.
        let laughing = laughHint && laughterQuietFrames < 6
        let gateOpen = voiceGate.update(candidate: laughing || ((voiced || fricative) && !closure), scene: context)
        let allowed = !voicePriority || gateOpen
        let formants = !laughing && voiced && !closure && allowed ? estimateFormants() : nil
        lastVowelFeatures = collectVowelFeatures || (!laughing && voiced && !closure && allowed && vowelProfile != nil)
            ? mfcc.features(power: power) : nil
        var confidence: Float = 0
        var mfccConfidence: Float?
        var usedMFCC = false
        var candidate: MouthShape = .rest
        if laughing && allowed {
            // A coherent open laugh, rather than vowel guesses on every burst.
            // Hysteresis keeps varying breath strength from fluttering aperture.
            candidate = laughBurst && fastRMS * gain > (current == .ah ? 0.012 : 0.018) ? .ah : .eh
            confidence = context.laughter
        } else if voiced && allowed {
            let low = band(200, 550), mid = band(550, 1100), upper = band(1100, 1900), front = band(1900, 3500)
            if front > (low + mid) * 0.6 { candidate = mid > low * 0.85 ? .eh : .ee }
            else if mid > low * 0.85 { candidate = .ah }
            else if upper > front * 1.2 && upper > mid * 0.65 { candidate = .oh }
            else { candidate = .oo }
            confidence = 0.35
            if let formants {
                let prototypes: [(MouthShape, Float, Float)] = [
                    (.ah, 800, 1300), (.eh, 550, 2000), (.ee, 300, 2400), (.oh, 500, 1000), (.oo, 300, 700)
                ]
                let ranked = prototypes.map { pose, f1, f2 in
                    (pose, pow((formants.0 - f1) / 220, 2) + pow((formants.1 - f2) / 450, 2))
                }.sorted { $0.1 < $1.1 }
                let margin = ranked[1].1 - ranked[0].1
                if ranked[0].1 < 4.5 && margin > 0.04 {
                    candidate = ranked[0].0
                    confidence = min(0.9, 0.45 + margin * 0.15)
                }
            }
            if let features = lastVowelFeatures, let match = vowelProfile?.match(features) {
                mfccConfidence = match.confidence
                if match.confidence >= 0.55 {
                    candidate = match.shape
                    confidence = max(confidence, match.confidence)
                    usedMFCC = true
                }
            }
            // Hysteresis on the vowel family precedes the opening-size choice.
            if candidate == familyPending { familyVotes += 1 } else { familyPending = candidate; familyVotes = 1 }
            let singing = context.kind == .singing
            let requiredVotes = singing ? 3 : (confidence >= 0.65 ? 1 : 2)
            if familyVotes >= requiredVotes || current == .rest || current == .closed { family = candidate }
            candidate = family
            let relativeLevel = fastRMS / max(0.012, recentPeak)
            // Loudness controls opening within a family. A quiet rounded vowel
            // must not become a generic unrounded slight-open mouth.
            // Separate opening/closing thresholds prevent vibrato and a falling
            // envelope from repeatedly crossing one aperture boundary.
            let smallAh = current == .slight && family == .ah
            let narrowEe = current == .narrow && family == .ee
            if family == .ah && fastRMS * gain < (smallAh ? 0.012 : 0.008) { candidate = .slight }
            else if family == .ee && (fastRMS * gain < (narrowEe ? 0.012 : 0.008)
                || relativeLevel < (narrowEe ? 0.60 : 0.44)
                || (formants?.0 ?? 400) < (narrowEe ? 270 : 210)) { candidate = .narrow }
            else if family == .oh && (formants?.0 ?? 0) > 580 && relativeLevel > 0.7 { candidate = .roundedWide }
        } else if fricative && allowed {
            candidate = high > 0.56 ? .narrow : .fv
            confidence = 0.3
        }
        if closure && !laughing { candidate = .rest; confidence = 0.6 }
        if candidate == .rest {
            quietCount += 1
            // Hold through up to two uncertain windows in a sustained vowel.
            // A real pause still closes, and sustained silence restores idle.
            if quietCount >= 6 { current = .rest; familyVotes = 0 }
            else if quietCount >= 3 && current != .rest { current = .closed }
            pending = .rest; pendingCount = 0
        } else {
            quietCount = 0
            if candidate == pending { pendingCount += 1 } else { pending = candidate; pendingCount = 1 }
            // Vowels already passed family hysteresis above. Applying a second
            // two-frame wait here swallowed short vowels and delayed every turn.
            if voiced || current == .rest || current == .closed || pendingCount >= 2 { current = candidate }
        }
        var frame = LiveLipFrame(shape: current, level: envelope, voiceLike: (laughing || ((voiced || fricative) && !closure)) && allowed,
            confidence: confidence, audioTime: audioTime,
            firstFormant: formants?.0, secondFormant: formants?.1, scene: context, voiceGateOpen: allowed, beat: beat)
        frame.usedMFCC = usedMFCC; frame.mfccConfidence = mfccConfidence
        frame.laughterPriority = laughing && allowed
        return frame
    }

    /// Autocorrelation LPC envelope with pre-emphasis. Peaks are only usable
    /// acoustic hints; no language/phoneme identity is inferred from them.
    private func estimateFormants() -> (Float, Float)? {
        let order = 14
        // Fit the speech envelope at 8 kHz. At 16 kHz this LPC order often
        // merges close low resonances (oo) into a false higher first formant.
        // A short low-pass filter precedes 2:1 decimation; the 64 ms history
        // and 20 ms decision cadence are unchanged.
        let formantRate = rate / 2
        let length = size / 2
        let taps: [Float] = [-0.0456, 0, 0.2838, 0.5236, 0.2838, 0, -0.0456]
        var reduced = [Float](repeating: 0, count: length)
        for i in 0..<length {
            for j in taps.indices {
                let index = 2 * i + j - 3
                if (0..<size).contains(index) { reduced[i] += taps[j] * ring[(cursor + index) % size] }
            }
        }
        var signal = [Double](repeating: 0, count: length)
        for i in 1..<length {
            signal[i] = Double((reduced[i] - 0.92 * reduced[i - 1]) * window[2 * i])
        }
        var correlation = [Double](repeating: 0, count: order + 1)
        for lag in 0...order {
            for i in lag..<length { correlation[lag] += signal[i] * signal[i - lag] }
        }
        guard correlation[0] > 1e-10 else { return nil }
        // Diagonal loading prevents near-pure tones from producing unstable poles.
        var residual = correlation[0] * 1.0001
        var coefficients = [Double](repeating: 0, count: order + 1); coefficients[0] = 1
        for i in 1...order {
            var value = correlation[i]
            if i > 1 { for j in 1..<i { value += coefficients[j] * correlation[i - j] } }
            let reflection = -value / residual
            guard reflection.isFinite, abs(reflection) < 0.999 else { return nil }
            let previous = coefficients
            if i > 1 { for j in 1..<i { coefficients[j] = previous[j] + reflection * previous[i - j] } }
            coefficients[i] = reflection
            residual *= 1 - reflection * reflection
            guard residual > correlation[0] * 1e-9 else { return nil }
        }
        for i in 0..<size { input[i] = i <= order ? Float(coefficients[i]) : 0 }
        vDSP_DFT_Execute(fft, input, imaginary, &realOut, &imagOut)
        var envelope = [Float](repeating: 0, count: 512)
        for i in 1..<512 { envelope[i] = 1 / max(1e-12, realOut[i] * realOut[i] + imagOut[i] * imagOut[i]) }
        let largest = envelope[24...448].max() ?? 1
        let peaks = (24..<448).filter { envelope[$0] > envelope[$0 - 1] && envelope[$0] >= envelope[$0 + 1]
            && envelope[$0] > largest * 0.025 }
        guard let first = peaks.first(where: { $0 <= 140 }),
              let second = peaks.first(where: { $0 >= first + 28 && $0 >= 70 }) else { return nil }
        return (Float(first) * Float(formantRate) / Float(size), Float(second) * Float(formantRate) / Float(size))
    }
}
