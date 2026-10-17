import Foundation
import CaptionCore

enum HarnessMetricsChecks {
    static func replay(_ paths: [String]) throws {
        var evidence: [[String: Any]] = []
        for path in paths {
            let tail = LogTail(url: URL(fileURLWithPath: path)), parser = HarnessEventParser()
            var snapshot = SessionSnapshot(path: path); snapshot.source = .deepseek
            let start = ProcessInfo.processInfo.systemUptime
            var bytes = 0, lines = 0
            repeat {
                let batch = try tail.read(maxInitialBytes: Int.max)
                bytes += tail.lastReadBytes; lines += batch.count
                for line in batch { parser.parse(line).forEach { snapshot.apply($0) } }
            } while tail.hasUnreadBytes
            let cold = ProcessInfo.processInfo.systemUptime - start
            let before = snapshot.harnessResponseSpeed
            let idleStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 {
                let unchanged = try tail.read(maxInitialBytes: Int.max)
                precondition(unchanged.isEmpty && tail.lastReadBytes == 0)
            }
            precondition(snapshot.harnessResponseSpeed == before)
            evidence.append(["file": URL(fileURLWithPath: path).lastPathComponent,
                "bytes": bytes, "lines": lines, "coldSeconds": cold,
                "unchanged100PollSeconds": ProcessInfo.processInfo.systemUptime - idleStart,
                "unchangedDecodedLines": 0, "speed": before?.tokensPerSecond ?? -1])
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    static func run() throws {
        let parser = HarnessEventParser()
        var snapshot = SessionSnapshot(path: "fixture"); snapshot.source = .deepseek
        func feed(_ type: String, _ data: [String: Any], _ time: Double, time0: Double? = nil) throws {
            var row: [String: Any] = ["type": type, "data": data, "time": time]
            if let time0 { row["time0"] = time0 }
            parser.parse(try JSONSerialization.data(withJSONObject: row)).forEach { snapshot.apply($0) }
        }
        let message: [String: Any] = ["role": "assistant", "content": []]
        // v4: ignore block-start/empty heartbeat; count output including reasoning exactly once.
        try feed("assistant/message", ["message": message, "usage": ["outputTokens": 100, "reasoningTokens": 80],
            "stream": [["type": "chunk", "time": 1000, "chunk": ["type": "block-start"]],
                       ["type": "reasoning-chunks", "time0": 2000, "texts": ["", "private"], "dt": [500]]]], 7500)
        precondition(snapshot.harnessResponseSpeed?.tokensPerSecond == 20)
        precondition(!snapshot.active && snapshot.caption == nil && snapshot.activity == .distantPast)
        // v0/v3: packed first token is time0, later dt must not move the start to the end.
        try feed("step/start", ["turn": 1, "step": 1], 10000)
        try feed("reasoning-chunks", ["turn": 1, "step": 1, "index": 0, "texts": ["first", "second"], "dt": [2000]], 0, time0: 11000)
        try feed("assistant/message", ["turn": 1, "step": 1, "message": message, "usage": ["outputTokens": 60]], 14000)
        precondition(snapshot.harnessResponseSpeed?.tokensPerSecond == 20)
        try feed("assistant/message", ["turn": 1, "step": 1, "message": message, "usage": ["outputTokens": 900]], 20000)
        precondition(snapshot.harnessResponseSpeed?.tokens == 60)
        // Long tool time and first-token waiting do not enter the next response's denominator.
        try feed("step/start", ["turn": 1, "step": 2], 90000)
        try feed("assistant/chunk", ["turn": 1, "step": 9, "chunk": ["type": "text-delta", "text": "wrong step"]], 91000)
        try feed("assistant/chunk", ["turn": 1, "step": 2, "chunk": ["type": "tool-call-delta", "argumentsDelta": "", "name": "bash"]], 95000)
        try feed("assistant/message", ["turn": 1, "step": 2, "message": message, "usage": ["outputTokens": 100]], 97000)
        precondition(snapshot.harnessResponseSpeed?.tokensPerSecond == 50)
        parser.reset(); snapshot.resetActivity()
        try feed("assistant/message", ["turn": 1, "step": 3, "message": message, "usage": ["outputTokens": 100]], 100000)
        precondition(snapshot.harnessResponseSpeed == nil)
        try feed("assistant/message", ["message": message, "usage": ["outputTokens": -1],
            "stream": [["type": "text-chunks", "time0": 101000, "texts": ["first"], "dt": []]]], 102000)
        precondition(snapshot.harnessResponseSpeed == nil)

        let yaml = """
        version: 1
        refs:
          DEEPSEEK_API_KEY: wrong-key
        records:
          client-connection/browser-session:
            kind: grant
            payload:
              secret: do-not-use
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: fake-account-token
              issuer: https://platform.deepseek.com
        """
        precondition(HarnessAccountGrant.parse(Data(yaml.utf8)) != nil)
        precondition(HarnessAccountGrant.parse(Data(yaml.replacingOccurrences(of: "https://platform.deepseek.com", with: "https://other.test").utf8)) == nil)
        precondition(HarnessAccountGrant.parse(Data(repeating: 32, count: 65_537)) == nil)
        func balance(_ paid: String, _ bonus: String, code: Int = 0) -> Data {
            try! JSONSerialization.data(withJSONObject: ["code": code, "data": ["biz_code": 0, "biz_data": [
                "normal_wallets": [["currency": "CNY", "balance": paid]],
                "bonus_wallets": [["currency": "CNY", "balance": bonus]]]]])
        }
        precondition(HarnessBalance.displayText(balance("86.5069896400000000", "0E-16")) == "账户余额 ¥86.50")
        precondition(HarnessBalance.displayText(balance(".009", "1e2")) == "账户余额 ¥<0.01 · 赠送 ¥100.00")
        precondition(HarnessBalance.displayText(balance("-1.239", "0")) == "账户余额 -¥1.24")
        precondition(HarnessBalance.displayText(balance("0", "0.00")) == "账户余额 ¥0.00")
        precondition(HarnessBalance.displayText(balance("1", ".009")) == "账户余额 ¥1.00 · 赠送 ¥<0.01")
        precondition(HarnessBalance.displayText(balance("NaN", "0")) == nil)
        precondition(HarnessBalance.displayText(balance("0", "0", code: 40003)) == nil)
        precondition(HarnessBalance.normalCNY(balance("0.9999", "99999")) == Decimal(string: "0.9999"))
        precondition(HarnessBalance.isLow(normalCNY: HarnessBalance.normalCNY(balance("0.9999", "99999")), threshold: 1))
        precondition(!HarnessBalance.isLow(normalCNY: HarnessBalance.normalCNY(balance("1", "0")), threshold: 1))
        precondition(!HarnessBalance.isLow(normalCNY: HarnessBalance.normalCNY(balance("1.0001", "0")), threshold: 1))
        precondition(HarnessBalance.isLow(normalCNY: HarnessBalance.normalCNY(balance("-0.01", "99999")), threshold: 0))
        precondition(!HarnessBalance.isLow(normalCNY: nil, threshold: 1))
        precondition(!HarnessBalance.isLow(normalCNY: 0, threshold: .nan))
        precondition(HarnessBalance.normalCNY(balance("NaN", "0")) == nil)
        precondition(HarnessBalance.normalCNY(balance("0", "0", code: 40003)) == nil)
        let usdOnly = Data(String(data: balance("0", "0"), encoding: .utf8)!.replacingOccurrences(of: "CNY", with: "USD").utf8)
        precondition(HarnessBalance.normalCNY(usdOnly) == nil)
        print("PASS Harness low balance: exact paid CNY only, bonus ignored, strict threshold, negative/zero, invalid/missing currency")
        print("PASS Harness speed: v4 and legacy timestamps, empty deltas, usage, tool/wait exclusion, reset, incomplete tail and malformed records")
        print("PASS Harness balance: scoped credentials, origin validation, wallet precision/currencies, separated bonus and missing/auth-failed data")
    }
}
