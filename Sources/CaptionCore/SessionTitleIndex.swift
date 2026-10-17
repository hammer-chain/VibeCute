import Foundation

/// Codex appends title updates to session_index.jsonl. Later entries replace
/// earlier names; reading this file never changes the underlying conversation.
public final class SessionTitleIndex {
    private let tail: LogTail
    private var titles: [String: String] = [:]

    public init(url: URL) { tail = LogTail(url: url) }

    public func refresh() {
        guard let lines = try? tail.read(maxInitialBytes: Int.max) else { return }
        if tail.didReset { titles.removeAll() }
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = entry["id"] as? String,
                  let title = entry["thread_name"] as? String else { continue }
            let normalized = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { titles[id] = normalized }
        }
    }

    public func title(for id: String) -> String { titles[id] ?? "" }
}
