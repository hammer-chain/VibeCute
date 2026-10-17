import Foundation

public struct HarnessResponseSpeed: Equatable, Sendable {
    public let tokens: Double
    public let seconds: Double
    public let observedAt: Date
    public var tokensPerSecond: Double { tokens / seconds }
}

/// Retains only the open step's timing, never stream bodies or tool arguments.
struct HarnessResponseTiming {
    private var turn: Int?
    private var step: Int?
    private var firstToken: Double?

    mutating func observe(type: String, data: [String: Any], time: Double?) {
        if type == "turn/start" || type == "turn/end" || type == "step/end" {
            self = Self(); return
        }
        if type == "step/start" {
            turn = data["turn"] as? Int; step = data["step"] as? Int; firstToken = nil
            return
        }
        guard firstToken == nil, let turn, let step,
              data["turn"] as? Int == turn, data["step"] as? Int == step else { return }
        if type == "assistant/chunk", let chunk = data["chunk"] as? [String: Any], isTokenDelta(chunk) {
            firstToken = validTime(time)
        } else if ["reasoning-chunks", "text-chunks", "tool-call-chunks"].contains(type) {
            firstToken = packedFirstToken(type: type, data: data, time0: time)
        }
    }

    mutating func complete(data: [String: Any], time: Double?) -> HarnessResponseSpeed? {
        // v4 embeds its lossless stream on the completed message; v0/v3 stream separately.
        var first: Double?
        if let stream = data["stream"] as? [[String: Any]] {
            for entry in stream {
                let type = entry["type"] as? String ?? ""
                let candidate: Double?
                if type == "chunk", let chunk = entry["chunk"] as? [String: Any], isTokenDelta(chunk) {
                    candidate = validTime(entry["time"] as? Double)
                } else {
                    candidate = packedFirstToken(type: type, data: entry, time0: entry["time0"] as? Double)
                }
                if let candidate { first = candidate; break }
            }
        } else if let turn, let step, data["turn"] as? Int == turn, data["step"] as? Int == step {
            first = firstToken
        }
        self = Self() // A duplicate message without a recorded stream cannot consume the step again.
        guard let first, let end = validTime(time), end > first,
              let usage = data["usage"] as? [String: Any], let tokens = usage["outputTokens"] as? Double,
              tokens.isFinite, tokens >= 0 else { return nil }
        return HarnessResponseSpeed(tokens: tokens, seconds: (end - first) / 1000,
            observedAt: Date(timeIntervalSince1970: end / 1000))
    }

    private func validTime(_ time: Double?) -> Double? {
        time.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private func isTokenDelta(_ chunk: [String: Any]) -> Bool {
        switch chunk["type"] as? String {
        case "text-delta", "reasoning-delta": return !(chunk["text"] as? String ?? "").isEmpty
        case "tool-call-delta":
            return !(chunk["argumentsDelta"] as? String ?? "").isEmpty || chunk["name"] as? String != nil
        default: return false
        }
    }

    private func packedFirstToken(type: String, data: [String: Any], time0: Double?) -> Double? {
        guard ["reasoning-chunks", "text-chunks", "tool-call-chunks"].contains(type),
              var time = validTime(time0) else { return nil }
        let values = data[type == "tool-call-chunks" ? "args" : "texts"] as? [String] ?? []
        let gaps = data["dt"] as? [Double] ?? []
        for (index, value) in values.enumerated() {
            if index > 0 {
                guard gaps.indices.contains(index - 1), gaps[index - 1].isFinite, gaps[index - 1] >= 0 else { return nil }
                time += gaps[index - 1]
            }
            if !value.isEmpty || (type == "tool-call-chunks" && index == 0 && data["name"] as? String != nil) {
                return validTime(time)
            }
        }
        return nil
    }
}
