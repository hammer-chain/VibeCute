import Foundation

/// Effective per-response throughput, following codex-tps's rollout boundaries.
/// Keeps only numeric timing/usage; no transcript or tool arguments are retained.
public struct CodexResponseSpeed: Equatable, Sendable {
    public let outputTokens: Int
    public let seconds: Double
    public let recordedAt: Date
    public var tokensPerSecond: Double { Double(outputTokens) / seconds }
}

public enum CodexResponseEvent: Sendable {
    case started(Date)
    case input(Date)
    case generated(Date)
    case usage(Date, output: Int, total: Int?)

    static func parse(type: String, payload: [String: Any], date: Date) -> CodexResponseEvent? {
        guard date != .distantPast else { return nil }
        let kind = payload["type"] as? String ?? ""
        if type == "turn_context" { return .input(date) }
        if type == "event_msg" {
            if kind == "task_started" || kind == "turn_started" { return .started(date) }
            if kind == "user_message" { return .input(date) }
            if kind == "token_count", let info = payload["info"] as? [String: Any],
               let last = info["last_token_usage"] as? [String: Any],
               let output = last["output_tokens"] as? Int, output >= 0 {
                return .usage(date, output: output,
                    total: (info["total_token_usage"] as? [String: Any])?["output_tokens"] as? Int)
            }
        }
        if type == "response_item" {
            let role = payload["role"] as? String
            if kind == "reasoning" || kind.hasSuffix("_call") || (kind == "message" && role == "assistant") {
                return .generated(date)
            }
            if kind == "function_call_output" || kind == "custom_tool_call_output" || kind == "agent_message"
                || (kind == "message" && ["user", "developer", "system"].contains(role ?? "")) {
                return .input(date)
            }
        }
        return nil
    }
}

public struct CodexResponseSpeedProjection: Equatable, Sendable {
    private var samplingStart: Date?
    private var generatedEnd: Date?
    private var totalOutput: Int?
    public private(set) var latest: CodexResponseSpeed?
    public init() {}

    public mutating func accept(_ event: CodexResponseEvent) {
        switch event {
        case let .started(date): samplingStart = date; generatedEnd = nil
        case let .input(date):
            // Tool results move the next model-request boundary past execution.
            if generatedEnd == nil { samplingStart = date }
        case let .generated(date): generatedEnd = date
        case let .usage(date, output, total):
            if let total, let previous = totalOutput, total == previous { return }
            let consistent = total.map { current in
                current >= 0 && (totalOutput.map { current >= $0 && current - $0 == output } ?? true)
            } ?? true
            if let total { totalOutput = total }
            if consistent, output > 0, let start = samplingStart, let end = generatedEnd {
                let seconds = end.timeIntervalSince(start)
                if seconds.isFinite, seconds > 0 {
                    latest = CodexResponseSpeed(outputTokens: output, seconds: seconds, recordedAt: date)
                }
            }
            // Usage may arrive after tools finish. End time belongs to model
            // output, never to arrival of this usage notification.
            samplingStart = date; generatedEnd = nil
        }
    }
}
