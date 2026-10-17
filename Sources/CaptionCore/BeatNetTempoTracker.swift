import Foundation
import BeatNetBridge

public enum BeatNetRuntime {
    static var directory: URL {
        #if !VIBECUTE_RELEASE
        if let path = ProcessInfo.processInfo.environment["CAPTIONS_BEATNET_RUNTIME"] { return URL(fileURLWithPath: path) }
        #endif
        let bundled = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("BeatNet")
        if BuildProfile.isRelease { return bundled }
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("libcaption_beatnet.dylib").path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/beatnet/runtime")
    }
    public static var availability: String {
        let root = directory
        return ["libcaption_beatnet.dylib", "generic-f32.gguf"].allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            ? "运行时已安装（权重仅限非商业使用）" : "运行时缺失：运行 scripts/setup_beatnet.sh"
    }
}

/// 100 ms bounded batches; scalar C++ inference runs on one worker, never the capture callback.
final class BeatNetTempoTracker {
    private let queue = DispatchQueue(label: "captions.beatnet", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var generation = 0
    private var snapshot = BeatEstimate(engine: .beatnet)
    private var handle: UnsafeMutableRawPointer? // worker-owned
    private var attempted = false
    private var beatTimes: [Double] = [] // worker-owned, at most 8
    private var input: [Float] = []
    private var previous: Float = 0
    private var previousTime: Double?
    private var nextTime: Double?
    private var origin: Double?
    private var active = false
    private var lastMusic = -Double.infinity
    private var cleared = true
    private(set) var droppedBatches = 0
    init() { input.reserveCapacity(2205) }
    deinit { caption_beatnet_free(handle) }
    func drain() { queue.sync {} }
    func setMusical(_ musical: Bool, at time: Double) {
        active = musical
        if musical { lastMusic = time; cleared = false }
        else if time - lastMusic > 2 && !cleared { reset(); cleared = true }
    }
    private func reset() {
        input.removeAll(keepingCapacity: true); previousTime = nil; nextTime = nil; origin = nil
        lock.lock(); generation += 1; snapshot = BeatEstimate(engine: .beatnet); lock.unlock()
        queue.async { [self] in caption_beatnet_reset(handle); beatTimes.removeAll(keepingCapacity: true) }
    }
    func consume(_ value: Float, at time: Double) {
        guard value.isFinite, time.isFinite, active || time - lastMusic <= 2 else { return }
        if let previousTime, time <= previousTime || time - previousTime > 0.1 { reset() }
        guard let start = previousTime else {
            previousTime = time; previous = value; nextTime = time; origin = time; return
        }
        var next = nextTime ?? start
        while next <= time {
            let fraction = Float(max(0, min(1, (next - start) / (time - start))))
            input.append(previous + fraction * (value - previous))
            if input.count == 2205 {
                lock.lock()
                let accepted = pending < 3
                if accepted { pending += 1 }
                let epoch = generation
                lock.unlock()
                if accepted {
                    let batch = input, base = origin ?? start, end = next
                    queue.async { [self] in process(batch, origin: base, end: end, epoch: epoch) }
                    input.removeAll(keepingCapacity: true)
                } else {
                    droppedBatches += 1; reset()
                    return
                }
            }
            next += 1 / 22_050.0
        }
        nextTime = next; previousTime = time; previous = value
    }
    private func process(_ batch: [Float], origin: Double, end: Double, epoch: Int) {
        defer { lock.lock(); pending -= 1; lock.unlock() }
        lock.lock(); let current = generation; lock.unlock()
        guard epoch == current else { return }
        let started = ProcessInfo.processInfo.systemUptime
        if !attempted {
            attempted = true
            let root = BeatNetRuntime.directory
            handle = caption_beatnet_create(root.appendingPathComponent("libcaption_beatnet.dylib").path, root.appendingPathComponent("generic-f32.gguf").path)
            if handle == nil { fputs("BeatNet+ runtime could not load; run scripts/setup_beatnet.sh\n", stderr) }
        }
        guard let handle else { return }
        var events = [CaptionBeatEvent](repeating: CaptionBeatEvent(time: 0, type: 0), count: 16)
        let count = batch.withUnsafeBufferPointer { b in events.withUnsafeMutableBufferPointer { e in
            caption_beatnet_process(handle, b.baseAddress, Int32(b.count), e.baseAddress, Int32(e.count))
        }}
        guard count >= 0 else { caption_beatnet_reset(handle); beatTimes.removeAll(); return }
        for event in events.prefix(Int(count)) {
            let time = origin + event.time
            if time > (beatTimes.last ?? -.infinity) { beatTimes.append(time) }
            if beatTimes.count > 8 { beatTimes.removeFirst() }
        }
        let intervals = zip(beatTimes, beatTimes.dropFirst()).map { $1 - $0 }.filter { $0 > 0.1 && $0 < 1.2 }.sorted()
        let period = intervals.isEmpty ? nil : intervals[intervals.count / 2]
        let consistency = period.map { p in Float(intervals.filter { abs($0 - p) < p * 0.15 }.count) / Float(max(1, intervals.count)) } ?? 0
        let bpm = period.map { 60 / $0 }
        let ready = intervals.count >= 3 && consistency >= 0.7
        let result = BeatEstimate(bpm: ready ? bpm : nil, confidence: ready ? consistency : 0,
                                  audioTime: end, lastBeatTime: beatTimes.last, engine: .beatnet, rawBPM: bpm, processingMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        lock.lock(); if epoch == generation { snapshot = result }; lock.unlock()
    }
    func estimate(at time: Double, reference: BeatEstimate) -> BeatEstimate {
        lock.lock(); let value = snapshot; lock.unlock()
        let fresh = value.lastBeatTime.map { (0...2).contains(time - $0) } ?? false
        let attacks = reference.lastAccentTime.map { (0...2).contains(time - $0) } ?? false
        return BeatEstimate(bpm: active && fresh && attacks ? value.bpm : nil,
                            confidence: value.confidence, audioTime: time,
                            lastBeatTime: value.lastBeatTime, lastAccentTime: reference.lastAccentTime,
                            engine: .beatnet, rawBPM: value.rawBPM, droppedBatches: droppedBatches, processingMs: value.processingMs)
    }
}
