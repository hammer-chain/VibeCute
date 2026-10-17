import Foundation

/// WorkBuddy 5.7 local transcripts. Database metadata owns task lifecycle;
/// message.status == completed also occurs before tools, so is not a turn end.
public final class WorkBuddyEventParser {
    public private(set) var lastAssistant: Caption?
    public private(set) var latestUserRequest: Date?
    private var seen = Set<String>()
    private var order: [String] = []
    public init() {}
    public func reset() { lastAssistant = nil; latestUserRequest = nil; seen.removeAll(); order.removeAll() }

    public func parse(_ data: Data, sessionID: String, cwd: String) -> [SessionEvent] {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["sessionId"] as? String == sessionID,
              row["cwd"] == nil || row["cwd"] as? String == cwd,
              row["isSidechain"] as? Bool != true, row["isSynthetic"] as? Bool != true,
              row["parentSessionId"] == nil,
              let type = row["type"] as? String,
              ["message", "reasoning", "function_call", "function_call_result"].contains(type) else { return [] }
        let provider = row["providerData"] as? [String: Any] ?? [:]
        guard provider["agent"] == nil || provider["agent"] as? String == "cli",
              provider["isSynthetic"] as? Bool != true,
              let timestamp = row["timestamp"] as? NSNumber,
              timestamp.doubleValue.isFinite else { return [] }
        let date = Date(timeIntervalSince1970: timestamp.doubleValue / 1000)
        var caption: Caption?
        var started = false
        if type == "reasoning" {
            let blocks = row["rawContent"] as? [[String: Any]] ?? []
            let text = CaptionText.clean(blocks.prefix(16).compactMap { block -> String? in
                guard block["type"] as? String == "reasoning_text", let text = block["text"] as? String else { return nil }
                return String(text.prefix(8000))
            }.joined(separator: "\n"))
            guard !text.isEmpty else { return [] }
            caption = Caption(text: String(text.prefix(8000)), kind: .reasoning, date: date)
        } else if type == "message" {
            if row["role"] as? String == "user" {
                started = provider["startsNewUserRequest"] as? Bool == true
                guard started else { return [] }
            } else if row["role"] as? String == "assistant" {
                let blocks = row["content"] as? [[String: Any]] ?? []
                let text = CaptionText.clean(blocks.prefix(16).compactMap { block -> String? in
                    guard block["type"] as? String == "output_text", let text = block["text"] as? String else { return nil }
                    return String(text.prefix(8000))
                }.prefix(16).joined(separator: "\n"))
                guard !text.isEmpty else { return [] }
                caption = Caption(text: String(text.prefix(8000)), kind: .progress, date: date)
            } else { return [] }
        } else {
            guard let name = row["name"] as? String,
                  name.range(of: "^[A-Za-z][A-Za-z0-9_./:-]{0,79}$", options: .regularExpression) != nil else { return [] }
            let label: String
            if type == "function_call" { label = "正在调用" }
            else {
                switch (row["status"] as? String ?? "").lowercased() {
                case "completed": label = "调用完成"
                case "failed", "error": label = "调用失败"
                case "cancelled", "canceled", "terminated": label = "调用已中断"
                default: return []
                }
            }
            caption = Caption(text: label + "：" + name, kind: .tool, date: date)
        }
        let key = type + ":" + String((row["id"] as? String ?? "").prefix(200)) + ":" + String(timestamp.doubleValue)
            + ":" + String((caption?.text ?? "started").hashValue)
        guard seen.insert(key).inserted else { return [] }
        order.append(key)
        if order.count > 512 { seen.remove(order.removeFirst()) }
        if started {
            lastAssistant = nil
            latestUserRequest = date
            return [.started(date, turnID: provider["conversationRequestId"] as? String)]
        }
        lastAssistant = caption?.kind == .progress ? caption : nil
        return caption.map { [.caption($0)] } ?? []
    }
}
