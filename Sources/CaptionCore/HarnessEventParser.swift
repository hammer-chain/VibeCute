import Foundation

public enum SessionSource: String, CaseIterable, Sendable {
    case codex = "Codex"
    case deepseek = "DeepSeek Harness"
    case claude = "Claude Code"
    case doubao = "豆包工作"
    case opencode = "OpenCode"
    case zcode = "zcode"
    case workbuddy = "WorkBuddy"

    /// Stable preference key, independent of the display name.
    public var preferenceID: String {
        switch self {
        case .codex: return "codex"
        case .deepseek: return "deepseek"
        case .claude: return "claude"
        case .doubao: return "doubao"
        case .opencode: return "opencode"
        case .zcode: return "zcode"
        case .workbuddy: return "workbuddy"
        }
    }
}

public enum HarnessLogFormat {
    public static func version(for url: URL) -> Int? {
        switch url.lastPathComponent {
        case "session.jsonl", "session.jsonl.zstd": return 0
        case "session.v3.jsonl", "session.v3.jsonl.zstd": return 3
        case "session.v4.jsonl", "session.v4.jsonl.zstd": return 4
        default: return nil
        }
    }
    /// A migration leaves older artifacts behind in the same session directory.
    public static func preferred(_ urls: [URL]) -> [URL] {
        var sessions: [String: URL] = [:]
        for url in urls {
            guard let version = version(for: url) else { continue }
            let directory = url.deletingLastPathComponent().path
            if let old = sessions[directory], let previous = Self.version(for: old),
               previous > version || (previous == version && old.path >= url.path) { continue }
            sessions[directory] = url
        }
        return Array(sessions.values)
    }
}

/// Only the Harness UI's model reasoning/text blocks and tool activity are displayed.
/// Prompt/context, user input, tool output, and unrecognized records are ignored.
public final class HarnessEventParser {
    public private(set) var isSubagent = false
    public private(set) var parentSessionID: String?
    private var reasoning: [Int: String] = [:]
    private var tools: [String: (name: String, date: Date)] = [:]
    private var responseTiming = HarnessResponseTiming()

    public init() {}
    public func reset() { reasoning.removeAll(); tools.removeAll(); isSubagent = false; parentSessionID = nil; responseTiming = HarnessResponseTiming() }

    public func parse(_ line: Data) -> [SessionEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        if type == "session" {
            guard let version = object["version"] as? Int, [0, 3, 4].contains(version),
                  let depth = object["delegationDepth"] as? Int, depth >= 0,
                  let id = object["id"] as? String else { return [] }
            // Seeded/forked main chats also carry parentSession. Only delegation
            // depth establishes child-agent identity.
            isSubagent = depth > 0
            parentSessionID = isSubagent ? object["parentSession"] as? String : nil
            return [.metadata(id: id, project: object["cwd"] as? String ?? "")]
        }
        guard let data = object["data"] as? [String: Any] else { return [] }
        let date = (object["time"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        responseTiming.observe(type: type, data: data,
            time: object[type.hasSuffix("-chunks") ? "time0" : "time"] as? Double)
        switch type {
        case "approval/asked":
            guard let id = data["id"] as? String, !id.isEmpty,
                  let tool = data["toolName"] as? String, !tool.isEmpty,
                  let reason = data["reason"] as? String, !reason.isEmpty,
                  id.utf8.count <= 1024, tool.utf8.count <= 1024, reason.utf8.count <= 32_768 else { return [] }
            var request = UserQuestionRequest(id: id, turnID: nil, asynchronous: false,
                questions: [UserQuestion(id: id, title: "权限申请 · " + tool, options: ["允许本次", "拒绝"], descriptions: ["仅允许这一次操作", "拒绝这次操作"])], date: date)
            request.approval = true
            request.externalApproval = true
            request.approvalContent = ApprovalContent(title: "权限申请 · " + tool, reason: reason,
                details: "可在此允许一次或拒绝，也可前往 DSH 处理。")
            return [.question(request)]
        case "approval/decided":
            guard let id = data["id"] as? String, !id.isEmpty else { return [] }
            return [.questionResolved(id)]
        case "session/title":
            let title = CaptionText.clean(data["title"] as? String ?? "")
            return title.isEmpty ? [] : [.title(title)]
        case "turn/start":
            reasoning.removeAll(); tools.removeAll()
            return [.started(date)]
        case "turn/end": return [.finished(date)]
        case "step/start": reasoning.removeAll(); return []
        case "reasoning-chunks":
            guard let index = data["index"] as? Int, let texts = data["texts"] as? [String] else { return [] }
            let gaps = data["dt"] as? [Double] ?? []
            let time = (object["time0"] as? Double ?? 0) + gaps.reduce(0, +)
            return appendReasoning(texts.joined(), index: index, date: Date(timeIntervalSince1970: time / 1000))
        case "assistant/chunk":
            guard let chunk = data["chunk"] as? [String: Any], let index = chunk["index"] as? Int else { return [] }
            if chunk["type"] as? String == "reasoning-delta", let text = chunk["text"] as? String {
                return appendReasoning(text, index: index, date: date)
            }
            if chunk["type"] as? String == "block-end", let block = chunk["block"] as? [String: Any],
               block["type"] as? String == "reasoning", let text = block["text"] as? String {
                reasoning[index] = String(text.suffix(2000))
                return caption(reasoning[index] ?? "", kind: .reasoning, date: date)
            }
            return []
        case "assistant/message":
            guard let message = data["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let content = message["content"] as? [[String: Any]] else { return [] }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let kind: CaptionKind = content.contains { $0["type"] as? String == "tool-call" } ? .progress : .answer
            // Reasoning may only exist in a completed message (some providers do not stream it).
            let thought = content.filter { $0["type"] as? String == "reasoning" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let speed = responseTiming.complete(data: data, time: object["time"] as? Double)
            return (reasoning.isEmpty ? caption(thought, kind: .reasoning, date: date) : []) + caption(text, kind: kind, date: date)
                + (speed.map { [.harnessResponseSpeed($0)] } ?? [])
        case "tool/call":
            guard let name = data["name"] as? String, let id = data["callId"] as? String else { return [] }
            tools[id] = (name, date)
            var detail = "正在调用：\(name)"
            let args: [String: Any]?
            if let raw = data["arguments"] as? String, let bytes = raw.data(using: .utf8) {
                args = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            } else { args = data["arguments"] as? [String: Any] }
            if name == "bash", let command = args?["command"] as? String {
                detail = "正在运行：" + ToolCaption.command(command)
            } else if ["write", "edit", "apply_patch"].contains(name), let path = (args?["path"] ?? args?["filePath"]) as? String {
                detail = "正在编辑：" + URL(fileURLWithPath: path).lastPathComponent
            }
            if name == "ask_user_question", let rows = args?["questions"] as? [[String: Any]],
               var request = UserQuestionRequest.parse(id:id, turnID:nil, asynchronous:false, questions:rows, date:date) {
                request.externalQuestion = true
                return [.question(request)]
            }
            return caption(detail, kind: .tool, date: date)
        case "user/message":
            if let source = data["source"] as? [String:Any], source["kind"] as? String == "user-question-reply",
               let id = source["callId"] as? String { return [.questionResolved(id)] }
            return []
        case "tool/result":
            // Question results use either the current toolCallId or the legacy source.callId shape.
            if let message = data["message"] as? [String:Any],
               let id = message["toolCallId"] as? String ?? (message["source"] as? [String:Any])?["callId"] as? String,
               tools[id]?.name == "ask_user_question" {
                let blocks = message["content"] as? [[String:Any]] ?? []
                let waiting = blocks.contains { block in
                    guard let text = block["text"] as? String, let bytes = text.data(using:.utf8),
                          let payload = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { return false }
                    return payload["pending"] as? Bool == true
                }
                if waiting { return [] }
                tools.removeValue(forKey:id)
                return [.questionResolved(id)]
            }
            guard let message = data["message"] as? [String: Any], let source = message["source"] as? [String: Any],
                  let id = source["callId"] as? String, let call = tools.removeValue(forKey: id) else { return [] }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let failed = blocks.contains { $0["type"] as? String == "tool-result" && $0["isError"] as? Bool == true }
            let seconds = max(0, Int(date.timeIntervalSince(call.date)))
            return caption("\(failed ? "调用失败" : "调用完成") · \(seconds)s：\(call.name)", kind: .tool, date: date)
        default: return []
        }
    }

    private func appendReasoning(_ text: String, index: Int, date: Date) -> [SessionEvent] {
        guard reasoning.count < 64 || reasoning[index] != nil else { return [] }
        let value = String(((reasoning[index] ?? "") + text).suffix(2000))
        reasoning[index] = value
        return caption(value, kind: .reasoning, date: date)
    }
    private func caption(_ text: String, kind: CaptionKind, date: Date) -> [SessionEvent] {
        let text = CaptionText.clean(text)
        return text.isEmpty ? [] : [.caption(Caption(text: text, kind: kind, date: date))]
    }
}
