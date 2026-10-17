import Foundation
import CaptionCore

enum VocalRuntimeChecks {
    static func run() throws {
        print("Checking native transport reset and timestamps")
        let worker = try VocalWorkerTransport(directory: VocalSeparationExperiment.runtime)
        let pcm = (0..<1024).map { Float(sin(Double($0) * 0.03)) * 0.1 }
        let a = try worker.transact(stereo: pcm, capturedEnd: 50, reset: true)
        let b = try worker.transact(stereo: pcm, capturedEnd: 51, reset: false)
        let replay = try worker.transact(stereo: pcm, capturedEnd: 52, reset: true)
        let replayError = zip(a.samples, replay.samples).map { abs($0.0 - $0.1) }.max() ?? 0
        print("Native counts: \(a.samples.count), \(b.samples.count), \(replay.samples.count); reset error \(replayError)")
        precondition(a.samples.count == 384 && b.samples.count == 512 && replay.samples.count == 384 && replayError <= 1e-6)
        precondition(abs(a.capturedEnd - (50 - 128 / 44100.0)) < 1e-8)
        worker.stop()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var checks = ["native reset replay and one-hop timestamp"]
        for mode in ["bad-ready", "exit", "bad-count", "hang-request", "hang-start"] {
            print("Checking worker failure: \(mode)")
            let directory = try fake(mode, root: temporary)
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let fakeWorker = try VocalWorkerTransport(directory: directory); defer { fakeWorker.stop() }
                _ = try fakeWorker.transact(stereo: pcm, capturedEnd: 50, reset: true)
                preconditionFailure("Must reject \(mode)")
            } catch { }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            print("Rejected \(mode): \(elapsed)s")
            precondition(elapsed < (mode == "hang-start" ? 10 : 3), "Worker failure must be bounded")
            checks.append(mode + " rejected in " + String(format: "%.3fs", elapsed))
        }
        let directory = try fake("identity", root: temporary)
        let pipeline = VocalSeparationPipeline(directory: directory)
        let lock = NSLock(); var outputs = [VocalSeparationPipeline.Output]()
        pipeline.onOutput = { result in lock.lock(); outputs.append(result); lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { pipeline.submit(stereo: pcm, sampleRate: 44100, capturedStart: now - 512 / 44100.0, audioTimeStart: 0, estimated: false) }
        Thread.sleep(forTimeInterval: 0.08)
        print("Startup burst: \(pipeline.snapshot().dropped) dropped, \(pipeline.snapshot().processed) processed")
        precondition(pipeline.snapshot().dropped >= 150 && pipeline.snapshot().processed <= 1, "Only the latest pending packet survives startup")
        var audioTime = 1.0
        func segment(rate: Double) {
            let base = ProcessInfo.processInfo.systemUptime, interval = 512 / rate
            for i in 0..<24 {
                let deadline = base + Double(i + 1) * interval
                Thread.sleep(forTimeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                pipeline.submit(stereo: pcm, sampleRate: rate, capturedStart: base + Double(i) * interval,
                    audioTimeStart: audioTime + Double(i) * interval, estimated: false)
            }
            audioTime += 24 * interval
            Thread.sleep(forTimeInterval: 0.03)
        }
        segment(rate: 44100)
        // A missed source interval and output rate switch must both reset history.
        audioTime += 0.03; segment(rate: 48000)
        lock.lock(); let captured = outputs; lock.unlock()
        print("Pipeline outputs: \(captured.count), resets: \(captured.filter(\.reset).count)")
        precondition(captured.count > 20 && captured.filter(\.reset).count >= 2)
        precondition(captured.allSatisfy { !$0.captureTimeEstimated && $0.capturedEnd.isFinite && $0.audioTimeEnd.isFinite })
        precondition(zip(captured, captured.dropFirst()).allSatisfy { $0.0.capturedEnd < $0.1.capturedEnd })
        let before = pipeline.snapshot().dropped
        pipeline.submit(stereo: pcm, sampleRate: 48000, capturedStart: ProcessInfo.processInfo.systemUptime - 1,
            audioTimeStart: 0, estimated: true)
        Thread.sleep(forTimeInterval: 0.03)
        precondition(pipeline.snapshot().dropped > before, "Do not analyze old input")
        pipeline.stop(); Thread.sleep(forTimeInterval: 0.03)
        lock.lock(); let stoppedCount = outputs.count; lock.unlock()
        pipeline.submit(stereo: pcm, sampleRate: 44100, capturedStart: ProcessInfo.processInfo.systemUptime,
            audioTimeStart: 0, estimated: false)
        Thread.sleep(forTimeInterval: 0.03)
        lock.lock(); precondition(outputs.count == stoppedCount); lock.unlock()
        checks.append("latest pending packet, source gap/rate reset, stale input, stop")
        let report: [String: Any] = ["passed": true, "checks": checks, "pipelineOutputs": captured.count,
            "pipelineResets": captured.filter(\.reset).count, "scope": "Native transport plus controlled fake pipe worker; not live separation quality"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: VocalSeparationExperiment.folder.appendingPathComponent("runtime-validation.json"))
        print(report)
    }
    static func fake(_ mode: String, root: URL) throws -> URL {
        let directory = root.appendingPathComponent(mode)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let code = """
        #!/usr/bin/python3
        import array, struct, sys, time
        mode = '\(mode)'
        def exact(count):
            data = b''
            while len(data) < count:
                part = sys.stdin.buffer.read(count - len(data))
                if not part: sys.exit(0)
                data += part
            return data
        if mode == 'hang-start': time.sleep(15)
        if mode == 'identity': time.sleep(0.04)
        sys.stdout.buffer.write(struct.pack('<IIIId', 0 if mode == 'bad-ready' else 0x564f434c, 2, 0, 0, 0))
        sys.stdout.buffer.flush()
        if mode == 'exit': sys.exit(0)
        previous = None
        while True:
            magic, flags, frames, reserved, end = struct.unpack('<IIIId', exact(24))
            pcm = array.array('f'); pcm.frombytes(exact(frames * 8))
            if mode == 'hang-request': time.sleep(15)
            if flags: previous = None
            mono = [(pcm[i] + pcm[i+1]) * .5 for i in range(0, len(pcm), 2)]
            result = ([] if previous is None else previous) + mono[:-128]
            previous = mono[-128:]
            sys.stdout.buffer.write(struct.pack('<IIIId', 0x564f434c, 0, 0xffffffff if mode == 'bad-count' else len(result), 128, end - 128 / 44100))
            sys.stdout.buffer.write(array.array('f', result).tobytes()); sys.stdout.buffer.flush()
        """
        let executable = directory.appendingPathComponent("captions-vocal")
        try Data(code.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return directory
    }
}
