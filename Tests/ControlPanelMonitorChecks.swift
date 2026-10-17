import Foundation
import CaptionCore

@main
enum ControlPanelMonitorChecks {
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let codex = temporary.appendingPathComponent("codex"), dsh = temporary.appendingPathComponent("dsh")
        for directory in [codex, dsh] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        try Data("{\"timestamp\":\"\(date)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"codex-test\",\"cwd\":\"/fixture\"}}\n".utf8)
            .write(to: codex.appendingPathComponent("rollout-test.jsonl"))
        try Data("{\"type\":\"session\",\"version\":4,\"delegationDepth\":0,\"id\":\"dsh-test\",\"cwd\":\"/fixture\"}\n".utf8)
            .write(to: dsh.appendingPathComponent("session.v4.jsonl"))
        for sources: Set<SessionSource> in [[], [.codex], [.deepseek], [.codex, .deepseek]] {
            let monitor = SessionMonitor(root: codex, harnessRoot: dsh, enabledSources: sources)
            var received: [SessionSnapshot]?
            monitor.onChange = { snapshots, error in
                precondition(error == nil); received = snapshots
            }
            monitor.poll()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            precondition(Set(received!.map(\.source)) == sources, "only enabled source records are read")
            print("PASS: enabled sources \(sources.map(\.preferenceID).sorted())")
        }
        // A disabled missing root must never raise an error or load an index.
        let monitor = SessionMonitor(root: temporary.appendingPathComponent("absent"), harnessRoot: dsh,
                                     enabledSources: [.deepseek])
        var received = false
        monitor.onChange = { snapshots, error in
            precondition(error == nil && snapshots.count == 1 && snapshots[0].source == .deepseek)
            received = true
        }
        monitor.poll(); RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(received); print("PASS: disabled Codex root is never scanned")
    }
}
