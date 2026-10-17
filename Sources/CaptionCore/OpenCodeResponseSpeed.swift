import Foundation

/// Effective throughput of a completed assistant response, including first-token
/// latency. OpenCode stores visible output and reasoning tokens separately.
public struct OpenCodeResponseSpeed: Equatable, Sendable {
    public let tokens: Double
    public let seconds: Double
    public let recordedAt: Date
    public var tokensPerSecond: Double { tokens / seconds }

    static func parse(output: String, reasoning: String, created: String,
                      completed: String) -> Self? {
        guard let output = Double(output), let reasoning = Double(reasoning),
              let start = Double(created), let end = Double(completed),
              output.isFinite, reasoning.isFinite, output >= 0, reasoning >= 0,
              start.isFinite, end.isFinite, start > 0, end > start else { return nil }
        let tokens = output + reasoning
        let seconds = (end - start) / 1000
        guard tokens.isFinite, tokens > 0, seconds.isFinite, seconds > 0,
              (tokens / seconds).isFinite else { return nil }
        return Self(tokens: tokens, seconds: seconds,
                    recordedAt: Date(timeIntervalSince1970: end / 1000))
    }
}
