import Foundation
import Darwin

/// Compiled against frozen before/after monitor copies by the performance script.
@main
enum TaskOutcomeMonitorProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let target = URL(fileURLWithPath: CommandLine.arguments[2])
        let original = try Data(contentsOf: target)
        let clock = ProcessInfo.processInfo
        func measure(_ body: () throws -> Void) rethrows -> Double {
            let start = clock.systemUptime
            try body()
            return (clock.systemUptime - start) * 1000
        }
        let monitor = SessionMonitor(root: root, harnessRoot: nil)
        let cold = measure { monitor.poll() }
        var idle: [Double] = []
        for _ in 0..<30 { idle.append(measure { monitor.poll() }) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var incremental: [Double] = []
        for index in 0..<20 {
            let id = "performance-\(index)"
            let timestamp = formatter.string(from: Date())
            let rows: [[String: Any]] = [
                ["type": "event_msg", "payload": ["type": "task_started", "turn_id": id]],
                ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "commentary",
                    "content": [["type": "output_text", "text": "正在验证任务结果音效的增量处理。"]]]],
                ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": id]]
            ]
            let file = try FileHandle(forWritingTo: target)
            try file.seekToEnd()
            for var row in rows {
                row["timestamp"] = timestamp
                try file.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10]))
            }
            try file.close()
            incremental.append(measure { monitor.poll() })
        }
        try original.write(to: target)
        let recomputed = SessionMonitor(root: root, harnessRoot: nil)
        let rebuild = measure { recomputed.poll() }
        func summary(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            return ["medianMs": sorted[sorted.count / 2], "p95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                    "maxMs": sorted.last!]
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["readerColdStartMs": cold, "readerReconstructionMs": rebuild,
            "unchangedPoll": summary(idle), "incrementalPoll": summary(incremental),
            "unchangedRounds": idle.count, "incrementalRounds": incremental.count, "newRecordsPerIncrementalRound": 3,
            "peakRSSBytes": usage.ru_maxrss]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
