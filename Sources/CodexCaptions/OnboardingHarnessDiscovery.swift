import Foundation
import CaptionCore

/// One-shot header probe for the invitation, never a live monitor or a full transcript replay.
enum OnboardingHarnessDiscovery {
    static let sources: [SessionSource] = [.codex, .claude, .deepseek]
    struct Limits {
        var entries = 4096
        var files = 8
        var seconds: Double = 0.75
    }
    struct Result {
        var available: [SessionSource] = []
        var entries = 0
        var files = 0
        var limited = false
    }
    static func discover(roots: [SessionSource: URL], limits: Limits = Limits(), cancelled: () -> Bool = { false }) -> Result {
        var result = Result()
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for source in sources {
            if cancelled() { break }
            guard let root = roots[source],
                  let values = try? root.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                      options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
            var entries = 0, files = 0
            for case let url as URL in enumerator {
                if cancelled() { return result }
                guard entries < limits.entries, files < limits.files,
                      ProcessInfo.processInfo.systemUptime < deadline else { result.limited = true; break }
                entries += 1; result.entries += 1
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isDirectory == true {
                    if url.pathComponents.count-root.pathComponents.count >= 6 || url.lastPathComponent == "subagents" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let accepted = source == .codex ? url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
                    : source == .claude ? url.pathExtension == "jsonl" && !url.lastPathComponent.hasPrefix("agent-")
                    : HarnessLogFormat.version(for: url) != nil
                guard accepted else { continue }
                files += 1; result.files += 1
                if hasSessionHeader(url, source: source) { result.available.append(source); break }
            }
        }
        return result
    }
    private static func hasSessionHeader(_ url: URL, source: SessionSource) -> Bool {
        let lines: [Data]
        if url.pathExtension == "zstd" {
            // Existing decoder bounds one call to 2 MB decoded output. Never drain the log.
            guard let decoded = try? ZstdLogTail(url: url).read() else { return false }
            lines = Array(decoded.prefix(32))
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65_536) else { return false }
            lines = Array(data.split(separator: 10).prefix(32)).map { Data($0) }
        }
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let events: [SessionEvent]
            switch source {
            case .codex:
                guard object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any],
                      (payload["source"] as? [String: Any])?["subagent"] == nil else { continue }
                events = EventParser.parse(line)
            case .claude: events = ClaudeEventParser.metadata(object)
            case .deepseek:
                let parser = HarnessEventParser(); events = parser.parse(line)
                if parser.isSubagent { continue }
            default: continue
            }
            if events.contains(where: { if case let .metadata(id, _) = $0 { return !id.isEmpty }; return false }) { return true }
        }
        return false
    }
}
