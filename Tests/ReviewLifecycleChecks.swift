import Foundation
import CaptionCore
@testable import CodexCaptions

@main
enum ReviewLifecycleChecks {
    static func wait(_ condition: () -> Bool, timeout: Double = 12) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "Timed out waiting for lifecycle transition")
    }
    static func main() throws {
        let started = ProcessInfo.processInfo.systemUptime
        for source in [SessionSource.codex, .claude, .deepseek] {
            for count in [17, source == .codex ? 81 : 33] { try retainedPin(source, count: count) }
        }
        print("PASS: pins survive 16 newer sessions and first discovery outside each source's record pool")
        try audioRecovery()
        print("Lifecycle checks wall seconds: \(ProcessInfo.processInfo.systemUptime - started)")
    }
    static func retainedPin(_ source: SessionSource, count: Int) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var oldest: URL!
        let formatter = ISO8601DateFormatter()
        for i in 0..<count {
            let time = Date(timeIntervalSince1970: 1_800_000_000 + Double(i))
            var url: URL, rows: [[String: Any]]
            if source == .codex {
                url = root.appendingPathComponent("rollout-\(i).jsonl")
                rows = [["type":"session_meta", "payload":["id":"session-\(i)","cwd":"/fixture"]],
                        ["type":"event_msg", "timestamp":formatter.string(from:time), "payload":["type":"task_started"]]]
            } else if source == .claude {
                url = root.appendingPathComponent("project/\(i).jsonl")
                rows = [["type":"user","sessionId":"session-\(i)","cwd":"/fixture","uuid":"row-\(i)",
                         "timestamp":formatter.string(from:time),"message":["content":"fixture request"]]]
            } else {
                url = root.appendingPathComponent("session-\(i)/session.v4.jsonl")
                rows = [["type":"session","version":4,"delegationDepth":0,"id":"session-\(i)","cwd":"/fixture"],
                        ["type":"turn/start","time":time.timeIntervalSince1970 * 1000,"data":[:]]]
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate:time], ofItemAtPath:url.path)
            if i == 0 { oldest = url }
        }
        // Match the URL returned by discovery (as the real selection UI does).
        // NSURL canonicalizes /private/var differently from FileManager enumeration.
        let enumerated = FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!.allObjects.compactMap { $0 as? URL }
        let pinnedPath = enumerated.first { $0.resolvingSymlinksInPath() == oldest.resolvingSymlinksInPath() }!.path
        let monitor = SessionMonitor(root:root, harnessRoot:root, claudeRoot:root, enabledSources:[source])
        var snapshots: [SessionSnapshot] = [], rounds = 0
        monitor.onChange = { values, _ in snapshots = values; rounds += 1 }
        monitor.pin(pinnedPath); monitor.start(); defer { monitor.stop() }
        wait { rounds > 0 }
        precondition(snapshots.count == 17 && snapshots.contains { $0.path == pinnedPath }, "Pin missing for \(source) / \(count)")
        precondition(Set(snapshots.map(\.path)).count == 17)
        monitor.pin(nil); let previous = rounds
        wait { rounds > previous }
        precondition(snapshots.count == 16, "Unpin restores bounded shortlist")
    }
    static func audioRecovery() throws {
        final class Fixture {
            let lock = NSLock()
            var attempts: [Double] = [], switchDevice = false
            func start() throws {
                lock.lock(); defer { lock.unlock() }
                attempts.append(ProcessInfo.processInfo.systemUptime)
                if [1, 2, 4].contains(attempts.count) { throw NSError(domain:"TransientFixture",code:1) }
            }
            func probe() -> Bool {
                lock.lock(); defer { lock.unlock() }
                let result = switchDevice; switchDevice = false; return result
            }
            var times: [Double] { lock.lock(); defer { lock.unlock() }; return attempts }
            func switchOutput() { lock.lock(); switchDevice = true; lock.unlock() }
        }
        let fixture = Fixture()
        let audio = RealtimeAudio(captureHooks:.init(start:{try fixture.start()},stop:{},needsReconnect:{fixture.probe()}))
        var connected = 0, closed = false
        audio.onStatus = { message, running in
            if running { connected += 1 }
            if message == "系统声音口型已关闭" { closed = true }
        }
        audio.setEnabled(true)
        wait({ connected == 1 }, timeout:12)
        let times = fixture.times
        precondition(times.count == 3 && times[1] - times[0] >= 1.9 && times[2] - times[1] >= 3.9, "Backoff must bound failed connection attempts")
        fixture.switchOutput()
        wait({ connected == 2 }, timeout:10)
        precondition(fixture.times.count == 5, "Device-switch failure must recover without toggling audio")
        audio.setEnabled(false); wait { closed }
        let attempts = fixture.times.count
        RunLoop.main.run(until:Date().addingTimeInterval(2.3))
        precondition(fixture.times.count == attempts, "Disabled audio must stop retries")
        audio.shutdown()
        print("PASS: initial failure x2, 2/4 second backoff, output switch failure/recovery, no retries after disable; no devices or permissions touched")
    }
}
