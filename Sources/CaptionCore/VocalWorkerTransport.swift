import Foundation

/// One synchronous transaction at a time, owned by a background worker.
/// PCM is carried only through local pipes. The capture callback never calls this.
public final class VocalWorkerTransport {
    public struct Result {
        public let samples: [Float]
        public let capturedEnd: Double
    }
    public enum Failure: Error { case protocolError, closed, unavailable }
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let lifetime = NSLock()
    private var primed = false
    private var stopped = false
    private var operation = 0

    public init(directory: URL) throws {
        let sending = Pipe(), receiving = Pipe()
        input = sending.fileHandleForWriting; output = receiving.fileHandleForReading
        process.executableURL = directory.appendingPathComponent("captions-vocal")
        process.arguments = [directory.appendingPathComponent("model.onnx").path]
        process.standardInput = sending; process.standardOutput = receiving
        // Native errors contain no PCM. Keep them on the host's stderr.
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            let token = deadline(after: 8)
            defer { finish(token) }
            let ready = try read(24)
            guard integer(ready, 0) == 0x564f434c, integer(ready, 4) == 2,
                  integer(ready, 8) == 0 else { throw Failure.protocolError }
        } catch { stop(); throw error }
    }

    public func transact(stereo: [Float], capturedEnd: Double, reset: Bool) throws -> Result {
        lifetime.lock(); let active = !stopped; lifetime.unlock()
        guard active, process.isRunning else { throw Failure.unavailable }
        let frames = stereo.count / 2
        guard stereo.count == frames * 2, (128...1024).contains(frames), frames % 128 == 0,
              capturedEnd.isFinite, stereo.allSatisfy(\.isFinite) else { throw Failure.protocolError }
        let token = deadline(after: 0.4)
        defer { finish(token) }
        var request = Data()
        for value: UInt32 in [0x564f434c, reset ? 1 : 0, UInt32(frames), 0] {
            var encoded = value.littleEndian; withUnsafeBytes(of: &encoded) { request.append(contentsOf: $0) }
        }
        var time = capturedEnd.bitPattern.littleEndian
        withUnsafeBytes(of: &time) { request.append(contentsOf: $0) }
        stereo.withUnsafeBytes { request.append(contentsOf: $0) }
        try input.write(contentsOf: request)
        let header = try read(24)
        let count = Int(integer(header, 8)), end = Double(bitPattern: header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self).littleEndian })
        guard integer(header, 0) == 0x564f434c, integer(header, 4) == 0, integer(header, 12) == 128,
              count == frames - ((!primed || reset) ? 128 : 0), end.isFinite,
              abs(end - (capturedEnd - 128 / 44100.0)) < 1e-7 else { throw Failure.protocolError }
        let pcm = try read(count * MemoryLayout<Float>.size)
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
        guard samples.allSatisfy(\.isFinite) else { throw Failure.protocolError }
        primed = true
        return Result(samples: samples, capturedEnd: end)
    }

    private func integer(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
    private func read(_ count: Int) throws -> Data {
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            guard let next = try output.read(upToCount: count - result.count), !next.isEmpty else { throw Failure.closed }
            result.append(next)
        }
        return result
    }
    /// The token prevents a delayed watchdog from aborting the next request.
    private func deadline(after seconds: Double) -> Int {
        lifetime.lock(); operation += 1; let token = operation; lifetime.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.lifetime.lock()
            guard !self.stopped, self.operation == token else { self.lifetime.unlock(); return }
            self.stopped = true; self.lifetime.unlock()
            self.closeProcess()
        }
        return token
    }
    private func finish(_ token: Int) {
        lifetime.lock(); if operation == token { operation += 1 }; lifetime.unlock()
    }
    public func stop() {
        lifetime.lock()
        guard !stopped else { lifetime.unlock(); return }
        stopped = true; lifetime.unlock()
        closeProcess()
    }
    private func closeProcess() {
        try? input.close()
        if process.isRunning { process.terminate() }
        try? output.close()
    }
    deinit { stop() }
}
