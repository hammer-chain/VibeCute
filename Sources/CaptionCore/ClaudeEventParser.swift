import Foundation

/// Passive transcript allowlist. Thinking/signatures, prompts, attachments,
/// tool inputs/results and sidechains never become subtitle text.
public final class ClaudeEventParser {
    private var inTurn = false
    private var tools: [String: String] = [:]
    private var seen = Set<String>()
    private var order: [String] = []
    private let formatter = ISO8601DateFormatter()
    private let plainFormatter = ISO8601DateFormatter()

    public init() { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    public func reset() { inTurn = false; tools.removeAll(); seen.removeAll(); order.removeAll() }

    public static func metadata(_ object: [String: Any]) -> [SessionEvent] {
        guard object["isSidechain"] as? Bool != true,
              let type = object["type"] as? String,
              ["user", "assistant", "system", "custom-title", "ai-title", "summary"].contains(type) else { return [] }
        var events: [SessionEvent] = []
        if let id = object["sessionId"] as? String, !id.isEmpty,
           let cwd = object["cwd"] as? String, !cwd.isEmpty {
            events.append(.metadata(id: id, project: cwd))
        }
        let title: String?
        switch type {
        case "custom-title": title = object["customTitle"] as? String
        case "ai-title": title = object["aiTitle"] as? String
        case "summary": title = object["summary"] as? String
        default: title = nil
        }
        if let title, !title.isEmpty { events.append(.title(String(title.prefix(200)))) }
        return events
    }

    public func parse(_ data: Data) -> [SessionEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["isSidechain"] as? Bool != true,
              let type = object["type"] as? String else { return [] }
        if let uuid = object["uuid"] as? String {
            guard seen.insert(uuid).inserted else { return [] }
            order.append(uuid)
            if order.count > 512 { seen.remove(order.removeFirst()) }
        }
        var events = Self.metadata(object)
        let timestamp = object["timestamp"] as? String ?? ""
        let date = formatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp) ?? .distantPast
        if type == "system", object["subtype"] as? String == "turn_duration" {
            inTurn = false; tools.removeAll(); events.append(.finished(date)); return events
        }
        guard type == "user" || type == "assistant",
              object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return events }
        let blocks = message["content"] as? [[String: Any]] ?? []
        if type == "user" {
            // A tool result is encoded as a user message, but does not start a turn.
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            if !results.isEmpty {
                for result in results.prefix(32) {
                    let name = tools.removeValue(forKey: result["tool_use_id"] as? String ?? "") ?? "工具"
                    let label = result["is_error"] as? Bool == true ? "调用失败：" : "调用完成："
                    events.append(.caption(Caption(text: label + name, kind: .tool, date: date)))
                }
            } else if let text = message["content"] as? String,
                      text.hasPrefix("[Request interrupted by user") {
                inTurn = false; tools.removeAll(); events.append(.finished(date, outcome: .interrupted))
            } else if message["content"] is String || blocks.contains(where: { $0["type"] as? String == "text" }) {
                inTurn = true; tools.removeAll(); events.append(.started(date))
                events.append(.caption(Caption(text: "正在处理…", kind: .progress, date: date)))
            }
            return events
        }
        if !inTurn { inTurn = true; events.append(.started(date)) }
        let terminal = ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "")
        for block in blocks.prefix(32) {
            switch block["type"] as? String {
            case "text":
                let text = CaptionText.clean(String((block["text"] as? String ?? "").prefix(8_000)))
                if !text.isEmpty { events.append(.caption(Caption(text: text, kind: terminal ? .answer : .progress, date: date))) }
            case "tool_use":
                // Names only: never display commands, arguments or returned data.
                let rawName = String((block["name"] as? String ?? "工具").prefix(100))
                let name = rawName.filter { $0.isLetter || $0.isNumber || "_-. :".contains($0) }
                if let id = block["id"] as? String {
                    if tools.count >= 64 { tools.removeAll() }
                    tools[id] = name
                }
                events.append(.caption(Caption(text: "正在调用：" + name, kind: .tool, date: date)))
            default: break
            }
        }
        // Split assistant blocks can share a terminal stop reason. Wait for
        // the visible text (or explicit turn_duration), never expose thinking.
        if terminal && blocks.contains(where: { $0["type"] as? String == "text" }) {
            inTurn = false; tools.removeAll(); events.append(.finished(date))
        }
        return events
    }
}
