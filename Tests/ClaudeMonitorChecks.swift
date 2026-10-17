import Foundation
import CaptionCore
import Darwin

private func check(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
        exit(1)
    }
}

@main
enum ClaudeMonitorChecks {
    static func main() throws {
        DoubaoChecks.run()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let project = temp.appendingPathComponent("projects/project")
        let root = project.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("parent.jsonl")
        let child = project.appendingPathComponent("parent/subagents/agent-child.jsonl")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func encode(_ type: String, _ fields: [String: Any] = [:]) throws -> Data {
            var row: [String: Any] = ["type": type, "sessionId": "parent", "cwd": "/fixture/字幕项目",
                "timestamp": formatter.string(from: Date()), "uuid": UUID().uuidString]
            row.merge(fields) { _, new in new }
            return try JSONSerialization.data(withJSONObject: row) + Data([10])
        }
        let start = try encode("user", ["message": ["content": "private"]])
        try start.write(to: file)
        try encode("assistant", ["message": ["content": [["type": "text", "text": "CHILD MUST NOT APPEAR"]]]]).write(to: child)
        let monitor = SessionMonitor(root: temp.appendingPathComponent("missing-codex"), harnessRoot: nil,
                                     claudeRoot: root, enabledSources: [.claude])
        var snapshots: [SessionSnapshot] = []
        var expectReadError = false
        monitor.onChange = { values, error in check((error != nil) == expectReadError); snapshots = values }
        func poll() { monitor.poll(); RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        poll()
        check(snapshots.count == 1 && snapshots[0].source == .claude && snapshots[0].active)
        check(snapshots[0].projectName == "字幕项目" && snapshots[0].projectID == "claude:/fixture/字幕项目")
        let text = try encode("assistant", ["message": ["content": [["type": "text", "text": "新增字幕中文"]]]])
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: text.dropLast(4)); poll()
        check(snapshots[0].caption?.text == "正在处理…", "partial UTF-8 JSON is withheld")
        try handle.write(contentsOf: text.suffix(4)); try handle.close(); poll()
        check(snapshots[0].caption?.text == "新增字幕中文")
        let unchanged = snapshots; poll(); check(snapshots == unchanged)
        try encode("assistant", ["message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "完成"]]]]).write(to: file, options: .atomic)
        poll(); check(!snapshots[0].active && snapshots[0].answer?.text == "完成")
        check(snapshots[0].caption == nil, "replacement clears stale captions and parser state")
        expectReadError = true
        try FileManager.default.removeItem(at: file); poll(); check(!snapshots[0].readable)
        expectReadError = false
        try start.write(to: file); poll(); check(snapshots[0].readable && snapshots[0].active)
        let disabled = SessionMonitor(root: temp.appendingPathComponent("missing"), harnessRoot: nil,
                                      claudeRoot: root, enabledSources: [])
        var disabledCalled = false
        disabled.onChange = { values, error in check(values.isEmpty && error == nil); disabledCalled = true }
        disabled.poll(); RunLoop.main.run(until: Date().addingTimeInterval(0.005)); check(disabledCalled)
        let visibleTracker = DoubaoVisibleSession()
        var visibleEnabled = true, visibleCalls = 0, visibleError: String?
        let visibleMonitor = SessionMonitor(root: temp.appendingPathComponent("missing"), harnessRoot: nil,
            enabledSources: [.doubao], visibleReader: {
                visibleCalls += 1
                return (visibleEnabled ? [visibleTracker.update(id: "visible", title: "豆包可见对话",
                    assistantText: "可见回复", generating: false)!] : [], visibleError)
            })
        var visibleSnapshots: [SessionSnapshot] = [], observedError: String?
        visibleMonitor.onChange = { visibleSnapshots = $0; observedError = $1 }
        func visiblePoll() { visibleMonitor.poll(); RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        visiblePoll()
        check(visibleSnapshots.count == 1 && visibleSnapshots[0].source == .doubao && observedError == nil)
        visibleEnabled = false; visibleError = "需要辅助功能权限"; visiblePoll()
        check(visibleSnapshots.isEmpty && observedError == visibleError)
        visibleEnabled = true; visibleError = nil; visiblePoll()
        check(visibleSnapshots.count == 1 && observedError == nil && visibleCalls == 3, "visible source failure/retry")
        let disabledVisible = SessionMonitor(root: temp, harnessRoot: nil, enabledSources: [],
            visibleReader: { fatalError("disabled source must perform zero UI reads") })
        disabledVisible.poll(); RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        print("PASS: Doubao-only monitor, permission failure/retry and zero reads when disabled")
        // Large historical content must be skipped while the header supplies cwd.
        let large = start + Data(repeating: 120, count: 4_000_000) + Data([10]) + text
        try large.write(to: file, options: .atomic); poll()
        check(snapshots[0].projectName == "字幕项目" && snapshots[0].caption?.text == "新增字幕中文")
        let tail = LogTail(url: file)
        let initialLines = try tail.read(), idleLines = try tail.read()
        check(initialLines.count == 1 && idleLines.isEmpty)
        print("PASS: Claude discovery, child exclusion, partial append, idle, inode replacement, read failure/retry, disabled source and bounded historical tail")

        let frozen = URL(fileURLWithPath: CommandLine.arguments[1])
        let frozenFiles = try FileManager.default.contentsOfDirectory(at: frozen.appendingPathComponent("sample"), includingPropertiesForKeys: nil)
        let target = frozenFiles.first!
        let benchmark = SessionMonitor(root: temp.appendingPathComponent("missing"), harnessRoot: nil,
                                       claudeRoot: frozen, enabledSources: [.claude])
        var measured: [SessionSnapshot] = []
        benchmark.onChange = { values, _ in measured = values }
        func time(_ action: () throws -> Void) rethrows -> Double {
            let clock = ProcessInfo.processInfo; let start = clock.systemUptime
            try action(); return (clock.systemUptime - start) * 1000
        }
        let cold = time { benchmark.poll() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        let expected = measured
        var idle: [Double] = []
        for _ in 0..<30 { idle.append(time { benchmark.poll() }) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01)); check(measured == expected)
        var incremental: [Double] = []
        for _ in 0..<20 {
            let h = try FileHandle(forWritingTo: target); try h.seekToEnd()
            try h.write(contentsOf: encode("assistant", ["message": ["content": [["type": "text", "text": "性能增量检查"]]]]))
            try h.close()
            incremental.append(time { benchmark.poll() })
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(measured.contains { $0.caption?.text == "性能增量检查" })
        let rebuild = SessionMonitor(root: temp, harnessRoot: nil, claudeRoot: frozen, enabledSources: [.claude])
        let reconstruction = time { rebuild.poll() }
        func stats(_ values: [Double]) -> [String: Double] {
            let s = values.sorted(); return ["medianMs": s[s.count / 2], "p95Ms": s[Int(Double(s.count - 1) * 0.95)], "maxMs": s.last!]
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["coldMs": cold, "reconstructionMs": reconstruction, "idle": stats(idle),
            "incremental": stats(incremental), "peakRSSBytes": usage.ru_maxrss, "idleRounds": 30, "incrementalRounds": 20,
            "newRecordsPerRound": 1, "networkRequests": 0, "modelCalls": 0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        check(cold < 5000 && incremental.sorted()[18] < 50 && idle.max()! < 50, "reader budget")
    }
}
