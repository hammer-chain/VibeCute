import Foundation

/// Finite read-only replay of the same bounded startup tail as the application.
@main struct CodexResponseSpeedChecks {
    static func main() throws {
        for path in CommandLine.arguments.dropFirst() {
            let started = ProcessInfo.processInfo.systemUptime
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            let size = try file.seekToEnd()
            let offset = size > 2_000_000 ? size - 2_000_000 : 0
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: 2_000_000) ?? Data()
            try file.close()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var projection = CodexResponseSpeedProjection(), samples = [[String: Any]](), rows = 0
            let parts = data.split(separator: 10, omittingEmptySubsequences: false)
            for line in parts.dropLast().dropFirst(offset > 0 ? 1 : 0) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = object["type"] as? String, let payload = object["payload"] as? [String: Any],
                      let stamp = object["timestamp"] as? String, let date = formatter.date(from: stamp) else { continue }
                rows += 1
                let previous = projection.latest
                if let event = CodexResponseEvent.parse(type: type, payload: payload, date: date) { projection.accept(event) }
                if let latest = projection.latest, latest != previous {
                    samples.append(["outputTokens": latest.outputTokens, "seconds": latest.seconds,
                        "tokensPerSecond": latest.tokensPerSecond, "recordedAt": formatter.string(from: latest.recordedAt)])
                }
            }
            let summary: [String: Any] = ["bytesRead": data.count, "rows": rows, "samples": samples.count,
                "lastSamples": Array(samples.suffix(3)), "replaySeconds": ProcessInfo.processInfo.systemUptime - started]
            print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)
        }
    }
}
