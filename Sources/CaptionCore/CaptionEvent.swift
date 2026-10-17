import Foundation

public enum CaptionKind: String, Sendable {
    case progress = "进度"
    case summary = "思考摘要"
    case reasoning = "思考"
    case answer = "回答"
    case tool = "工具调用"
    case subagent = "子任务"
}

public struct Caption: Equatable, Sendable {
    public let text: String
    public let kind: CaptionKind
    public let date: Date
    public init(text: String, kind: CaptionKind, date: Date) {
        self.text = text; self.kind = kind; self.date = date
    }
}

public struct CodexQuota: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let usedPercent: Double
        public let minutes: Int
        public let resetsAt: Date
    }
    public let observedAt: Date
    public let windows: [Window]
    public func displayText(now: Date = Date()) -> String? {
        let labels = windows.filter { $0.resetsAt > now }.map { window in
            let name: String
            switch window.minutes {
            case 10080: name = "周额度"
            case 1440: name = "日额度"
            default: name = window.minutes % 60 == 0 ? "\(window.minutes / 60)小时额度" : "\(window.minutes)分钟额度"
            }
            return String(format: "%@剩余 %.0f%%", name, max(0, min(100, 100 - window.usedPercent)))
        }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
    static func parse(_ value: Any?, date: Date) -> CodexQuota? {
        guard let value = value as? [String: Any], date != .distantPast,
              value["limit_id"] == nil || value["limit_id"] is NSNull || value["limit_id"] as? String == "codex" else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> Window? in
            guard let row = value[key] as? [String: Any], let used = row["used_percent"] as? Double,
                  used.isFinite, used >= 0, used <= 100,
                  let minutes = row["window_minutes"] as? Int, minutes > 0, minutes <= 525600,
                  let reset = row["resets_at"] as? Double, reset.isFinite, reset > 0 else { return nil }
            return Window(usedPercent: used, minutes: minutes, resetsAt: Date(timeIntervalSince1970: reset))
        }
        return windows.isEmpty ? nil : CodexQuota(observedAt: date, windows: windows)
    }
}

public enum SessionEvent: Sendable {
    case harnessResponseSpeed(HarnessResponseSpeed)
    case codexResponse(CodexResponseEvent)
    case quota(CodexQuota)
    case metadata(id: String, project: String)
    case title(String)
    case started(Date, turnID: String? = nil)
    case finished(Date, outcome: TaskOutcome = .completed, turnID: String? = nil)
    case caption(Caption)
    case question(UserQuestionRequest)
    case questionResolved(String)
    case questionsAnswered(Set<String>)
    case userContinued(Date)
}

/// An allowlist of user-facing text. Never use raw_content, encrypted_content,
/// analysis, tool results, system instructions, or user input as captions.
public enum EventParser {
    public static func parse(_ data: Data, includeResponseMetrics: Bool = false) -> [SessionEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let type = object["type"] as? String else { return [] }
        let date = parseDate(object["timestamp"] as? String) ?? .distantPast
        let subtype = payload["type"] as? String ?? ""
        let metrics = includeResponseMetrics ? CodexResponseEvent.parse(type: type, payload: payload, date: date).map { [SessionEvent.codexResponse($0)] } ?? [] : []
        return visibleEvents(type: type, payload: payload, date: date, subtype: subtype) + metrics
    }

    private static func visibleEvents(type: String, payload: [String: Any], date: Date, subtype: String) -> [SessionEvent] {
        if type == "session_meta" {
            return [.metadata(id: payload["id"] as? String ?? "", project: payload["cwd"] as? String ?? "")]
        }
        if type == "event_msg" {
            switch subtype {
            case "token_count":
                return CodexQuota.parse(payload["rate_limits"], date: date).map { [.quota($0)] } ?? []
            case "task_started", "turn_started":
                return [.started(date, turnID: payload["turn_id"] as? String)]
            case "task_complete", "task_completed", "turn_complete":
                // A completed turn can carry a terminal error. Tool failures,
                // retry events and silence alone never establish its outcome.
                let outcome: TaskOutcome = payload["error"] as? [String: Any] == nil ? .completed : .failed
                return [.finished(date, outcome: outcome, turnID: payload["turn_id"] as? String)]
            case "turn_aborted":
                return [.finished(date, outcome: .interrupted, turnID: payload["turn_id"] as? String)]
            case "user_message":
                return userReply(payload["message"] as? String ?? "", date: date)
            case "item_started", "item_completed":
                guard let item = payload["item"] as? [String: Any] else { return [] }
                switch item["type"] as? String {
                case "AgentMessage":
                    if let rows = item["questions"] as? [[String: Any]],
                       let request = UserQuestionRequest.parse(id: item["id"] as? String ?? "",
                        turnID: payload["turn_id"] as? String, asynchronous: true, questions: rows, date: date) {
                        return [.question(request)]
                    }
                    return message(item, date: date)
                case "Reasoning": return caption(strings(item["summary_text"]), kind: .summary, date: date)
                case "CommandExecution", "FileChange", "McpToolCall", "DynamicToolCall":
                    return caption(ToolCaption.text(item), kind: .tool, date: date)
                default: return []
                }
            default: return []
            }
        }
        if type == "response_item" {
            if subtype == "function_call", let name = payload["name"] as? String,
               name == "request_user_input" || name == "functions.request_user_input",
               let raw = payload["arguments"] as? String, let data = raw.data(using: .utf8),
               let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = args["questions"] as? [[String: Any]],
               let request = UserQuestionRequest.parse(id: payload["call_id"] as? String ?? "",
                    turnID: (payload["internal_chat_message_metadata_passthrough"] as? [String: Any])?["turn_id"] as? String,
                    asynchronous: false, questions: rows, date: date) { return [.question(request)] }
            if subtype == "function_call_output", let id = payload["call_id"] as? String {
                return [.questionResolved(id)]
            }
            if subtype == "message", payload["role"] as? String == "user" {
                let parts = payload["content"] as? [[String: Any]] ?? []
                return userReply(parts.compactMap { $0["text"] as? String }.joined(separator: "\n"), date: date)
            }
            if subtype == "function_call", let name = payload["name"] as? String,
               name.hasSuffix("exec_command"), let arguments = payload["arguments"] as? String,
               let data = arguments.data(using: .utf8),
               let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let command = args["cmd"] as? String {
                return caption("正在运行：" + ToolCaption.command(command), kind: .tool, date: date)
            }
            if subtype == "reasoning" {
                let parts = payload["summary"] as? [[String: Any]] ?? []
                return caption(parts.filter { $0["type"] as? String == "summary_text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n"), kind: .summary, date: date)
            }
            if subtype == "message", payload["role"] as? String == "assistant" {
                return message(payload, date: date)
            }
        }
        return []
    }

    private static func userReply(_ text: String, date: Date) -> [SessionEvent] {
        let ids = UserQuestionRequest.answeredIDs(in: text)
        if !ids.isEmpty { return [.questionsAnswered(ids)] }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.userContinued(date)]
    }

    private static func message(_ item: [String: Any], date: Date) -> [SessionEvent] {
        let phase = item["phase"] as? String ?? item["channel"] as? String
        // Unknown or absent phases are deliberately not displayed.
        guard phase == "commentary" || phase == "final" || phase == "final_answer" else { return [] }
        let parts = item["content"] as? [[String: Any]] ?? []
        let text = parts.filter { ["output_text", "text", "Text"].contains($0["type"] as? String ?? "") }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        return caption(text, kind: phase == "commentary" ? .progress : .answer, date: date)
    }

    private static func strings(_ value: Any?) -> String {
        if let string = value as? String { return string }
        return (value as? [String] ?? []).joined(separator: "\n")
    }

    private static func caption(_ text: String, kind: CaptionKind, date: Date) -> [SessionEvent] {
        let clean = CaptionText.clean(text)
        return clean.isEmpty ? [] : [.caption(Caption(text: clean, kind: kind, date: date))]
    }

    public static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

public enum ToolCaption {
    public static func text(_ item: [String: Any]) -> String {
        let status = item["status"] as? String ?? ""
        let failed = ["failed", "declined"].contains(status)
        let running = ["in_progress", "inProgress", "running"].contains(status)
        switch item["type"] as? String {
        case "CommandExecution":
            let parts = item["command"] as? [String] ?? []
            let raw = parts.contains("-lc") || parts.contains("-c") ? parts.last ?? "" : parts.joined(separator: " ")
            let title = running ? "正在运行" : failed ? "命令失败" : "命令完成"
            var duration = ""
            if let value = item["duration"] as? [String: Any], let seconds = value["secs"] as? Int {
                duration = " · \(seconds)s"
            }
            let exit = failed ? " · 退出 \(item["exit_code"] as? Int ?? -1)" : ""
            return "\(title)\(duration)\(exit)：\(command(raw))"
        case "FileChange":
            guard let changes = item["changes"] as? [String: [String: Any]] else { return "" }
            return changes.keys.sorted().map { path in
                let change = changes[path] ?? [:]
                let name = URL(fileURLWithPath: path).lastPathComponent
                let type = (change["type"] as? String ?? "").lowercased()
                let action = failed ? "编辑失败" : running ? "正在编辑" : type == "add" ? "已新增" : type == "delete" ? "已删除" : "已编辑"
                let diff = change["unified_diff"] as? String ?? ""
                let lines = diff.components(separatedBy: "\n")
                let plus = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                let minus = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                let stats = plus + minus > 0 ? " +\(plus) −\(minus)" : ""
                return "\(action) \(name)\(stats)"
            }.joined(separator: "；")
        case "McpToolCall", "DynamicToolCall":
            let name = item["tool"] as? String ?? "工具"
            return "\(running ? "正在调用" : failed ? "调用失败" : "调用完成")：\(name)"
        default: return ""
        }
    }

    public static func command(_ input: String) -> String {
        var text = input.components(separatedBy: .newlines).first ?? ""
        for pattern in [
            "(?i)\\b([A-Z0-9_]*(?:TOKEN|API_KEY|SECRET|PASSWORD)[A-Z0-9_]*)=(?:\"[^\"]*\"|'[^']*'|\\S+)",
            "(?i)(--(?:password|token|api-key|secret))(?:=|\\s+)\\S+",
            "(?i)(Bearer)\\s+[^\\s\"']+"
        ] { text = text.replacingOccurrences(of: pattern, with: "$1=•••", options: .regularExpression) }
        if input.contains("\n") { text += " …" }
        return String(text.prefix(180)) + (text.count > 180 ? "…" : "")
    }
}

public enum CaptionText {
    public static func clean(_ input: String) -> String {
        var text = input
        for (pattern, replacement) in [
            ("(?s)```.*?```", "〔代码已省略〕"),
            ("!\\[[^\\]]*\\]\\([^)]*\\)", "〔图片〕"),
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
            ("(?m)^\\s{0,3}#{1,6}\\s+", ""),
            ("\\*\\*|__|`", ""),
            ("\\s+", " ")
        ] { text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unicode-safe pages with punctuation boundaries and a hard maximum.
    public static func pages(_ text: String, limit: Int = 64) -> [String] {
        let limit = max(8, limit)
        var remaining = Array(text), pages: [String] = []
        let breaks: Set<Character> = Set("。！？；，、.!?;,: \n")
        while remaining.count > limit {
            let range = (limit / 2)..<limit
            let end = range.reversed().first { breaks.contains(remaining[$0]) }.map { $0 + 1 } ?? limit
            pages.append(String(remaining.prefix(end)).trimmingCharacters(in: .whitespaces))
            remaining.removeFirst(end)
        }
        if !remaining.isEmpty { pages.append(String(remaining).trimmingCharacters(in: .whitespaces)) }
        return pages.filter { !$0.isEmpty }
    }
}
