import Foundation
import CaptionCore

enum ClaudeChecks {
    static func run() throws {
        let parser = ClaudeEventParser()
        var session = SessionSnapshot(path: "claude-fixture")
        session.source = .claude
        var serial = 0
        func row(_ type: String, _ fields: [String: Any] = [:]) throws -> Data {
            serial += 1
            var value: [String: Any] = ["type": type, "sessionId": "claude-id", "cwd": "/fixture",
                "uuid": "row-\(serial)", "timestamp": "2026-10-08T01:00:00.000Z"]
            value.merge(fields) { _, new in new }
            return try JSONSerialization.data(withJSONObject: value)
        }
        func apply(_ data: Data) { parser.parse(data).forEach { session.apply($0) } }
        apply(try row("user", ["message": ["content": "PRIVATE PROMPT"]]))
        precondition(session.active && session.caption?.text == "正在处理…" && session.id == "claude-id")
        apply(try row("assistant", ["message": ["content": [["type": "thinking", "thinking": "PRIVATE THOUGHT", "signature": "PRIVATE SIGNATURE"]]]]))
        precondition(session.caption?.text == "正在处理…")
        let progress = try row("assistant", ["message": ["stop_reason": "tool_use",
            "content": [["type": "text", "text": "正在检查字幕。"]]]])
        apply(progress)
        precondition(session.active && session.caption?.text == "正在检查字幕。")
        precondition(parser.parse(progress).isEmpty, "duplicated transcript UUID is not replayed")
        apply(try row("assistant", ["message": ["content": [["type": "tool_use", "id": "tool-1", "name": "Bash",
            "input": ["command": "SECRET COMMAND"]]]]]))
        precondition(session.caption?.text == "正在调用：Bash")
        apply(try row("user", ["message": ["content": [["type": "tool_result", "tool_use_id": "tool-1",
            "content": "SECRET OUTPUT", "is_error": true]]]]))
        precondition(session.active && session.caption?.text == "调用失败：Bash")
        let before = session
        for hidden in [try row("attachment", ["content": "PRIVATE"]),
                       try row("assistant", ["isSidechain": true, "message": ["content": [["type": "text", "text": "CHILD BODY"]]]]),
                       try row("user", ["isMeta": true, "message": ["content": "SYSTEM PROMPT"]])] {
            apply(hidden)
            precondition(session.caption == before.caption && session.active == before.active)
        }
        apply(try row("assistant", ["message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "接入完成。"]]]]))
        precondition(!session.active && session.answer?.text == "接入完成。" && session.outcome == .completed)
        precondition(session.displayCaption(showAnswers: true)?.text == "接入完成。")
        precondition(session.displayCaption(showAnswers: false)?.text != "接入完成。")
        apply(try row("custom-title", ["customTitle": "自定义标题"])); precondition(session.title == "自定义标题")
        parser.reset(); session.resetActivity()
        apply(progress); precondition(session.active && session.caption?.text == "正在检查字幕。")
        apply(try row("system", ["subtype": "turn_duration"])); precondition(!session.active)
        apply(try row("user", ["message": ["content": "新一轮"]]))
        apply(try row("user", ["message": ["content": "[Request interrupted by user]妥善停止"]]))
        precondition(session.outcome == .interrupted && !session.active)
        precondition(parser.parse(Data("{broken".utf8)).isEmpty)
        print("PASS: Claude transcript allowlist, lifecycle, tools, deduplication, reset, titles and answer toggle")
    }
}
