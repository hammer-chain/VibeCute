import Foundation
import CaptionCore

private func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
private func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    precondition(a == b, "Values differ: \(a) != \(b)", file: file, line: line)
}
private func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}

final class CaptionCoreTests {
    func testTypewriterSpeedMapping() {
        var previous = 0.0
        for tps in 0...1000 {
            let value = TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: Double(tps))
            XCTAssertTrue(value >= previous && (tps <= 10 || value > previous) && value >= 5 && value <= 60)
            previous = value
        }
        XCTAssertEqual(TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: 1000), 60)
        XCTAssertEqual(TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: 5000), 60)
        XCTAssertEqual(TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: nil, fallback: 31), 31)
        for value in [Double.nan, -1, Double.infinity] {
            XCTAssertEqual(TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: value), 15)
        }
        XCTAssertEqual(TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: 5), 5)
        XCTAssertEqual(TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: 10), 5)
        XCTAssertTrue(TypewriterSpeedMapping.charactersPerSecond(tokensPerSecond: 11) > 5)
    }

    func testCodexResponseSpeed() throws {
        var session = SessionSnapshot(path: "speed-fixture")
        func feed(_ type: String, _ payload: [String: Any], _ seconds: Int) throws {
            let data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload,
                "timestamp": String(format: "2026-10-09T10:00:%02d.000Z", seconds)])
            EventParser.parse(data, includeResponseMetrics: true).forEach { session.apply($0) }
        }
        func usage(_ output: Int, _ total: Int) -> [String: Any] {
            ["type": "token_count", "info": ["last_token_usage": ["output_tokens": output],
                "total_token_usage": ["output_tokens": total]]]
        }
        try feed("event_msg", ["type": "task_started"], 0)
        try feed("response_item", ["type": "reasoning", "encrypted_content": "NEVER RETAIN"], 2)
        try feed("response_item", ["type": "function_call", "arguments": "NEVER RETAIN"], 5)
        try feed("event_msg", usage(100, 100), 15)
        XCTAssertEqual(session.codexResponseSpeed?.tokensPerSecond, 20)
        XCTAssertEqual(session.codexResponseSpeed?.seconds, 5)
        // Delayed usage must end at generated output, not at its notification.
        try feed("event_msg", usage(100, 100), 16)
        XCTAssertEqual(session.codexResponseSpeed?.tokensPerSecond, 20)
        try feed("response_item", ["type": "function_call_output", "output": "NEVER RETAIN"], 20)
        try feed("response_item", ["type": "message", "role": "assistant", "phase": "analysis"], 24)
        try feed("event_msg", usage(40, 140), 29)
        XCTAssertEqual(session.codexResponseSpeed?.tokensPerSecond, 10)
        try feed("event_msg", ["type": "task_started"], 30)
        XCTAssertEqual(session.codexResponseSpeed?.tokensPerSecond, 10)
        try feed("response_item", ["type": "reasoning"], 32)
        try feed("event_msg", usage(100, 140), 33) // duplicate counter must not close output
        try feed("event_msg", usage(60, 200), 34)
        XCTAssertEqual(session.codexResponseSpeed?.tokensPerSecond, 30)
        try feed("event_msg", usage(10, 10), 35) // reset, not another response
        XCTAssertEqual(session.codexResponseSpeed?.tokensPerSecond, 30)
        session.resetActivity()
        XCTAssertNil(session.codexResponseSpeed)
        try feed("response_item", ["type": "reasoning"], 36)
        try feed("event_msg", usage(50, 60), 37)
        XCTAssertNil(session.codexResponseSpeed) // tail starts mid-response: unknown start
        XCTAssertTrue(captions(try record("event_msg", usage(50, 60))).isEmpty)
        print("PASS codex-tps response timing: first wait, tool exclusion, delayed/duplicate usage, next round, reset and incomplete tail")
    }
    func testCodexQuota() throws {
        let reset = 1791950314.0
        let limits: [String: Any] = ["limit_id": "codex", "primary": [
            "used_percent": 69.0, "window_minutes": 10080, "resets_at": reset], "secondary": NSNull()]
        let events = EventParser.parse(try record("event_msg", ["type": "token_count", "rate_limits": limits]))
        guard case let .quota(value)? = events.first else { preconditionFailure("Expected API quota") }
        XCTAssertEqual(value.displayText(now: Date(timeIntervalSince1970: reset - 1)), "周额度剩余 31%")
        XCTAssertNil(value.displayText(now: Date(timeIntervalSince1970: reset)))
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(captions(try record("event_msg", ["type": "token_count", "rate_limits": limits])).isEmpty)
        XCTAssertTrue(EventParser.parse(try record("event_msg", ["type": "token_count", "rate_limits": NSNull()])).isEmpty)
        var other = limits; other["limit_id"] = "other-model"
        XCTAssertTrue(EventParser.parse(try record("event_msg", ["type": "token_count", "rate_limits": other])).isEmpty)
        var dual = limits
        dual["secondary"] = ["used_percent": 20.0, "window_minutes": 300, "resets_at": reset]
        guard case let .quota(two)? = EventParser.parse(try record("event_msg", ["type": "token_count", "rate_limits": dual])).first else {
            preconditionFailure("Expected both actual windows")
        }
        XCTAssertEqual(two.displayText(now: Date(timeIntervalSince1970: reset - 1)), "周额度剩余 31% · 5小时额度剩余 80%")
        var session = SessionSnapshot(path: "fixture")
        session.apply(.quota(two)); session.apply(.quota(value))
        XCTAssertEqual(session.codexQuota, value)
        XCTAssertFalse(session.active)
        print("PASS Codex API quota: remaining percent, real window labels, absent values, expiry and no caption/task side effects")
    }
    private func harness(_ type: String, _ data: [String: Any], time: Double = 1785498588575) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "data": data, "seq": 1, "time": time])
    }
    private func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload, "timestamp": "2026-09-27T03:00:00.000Z"])
    }
    private func captions(_ data: Data) -> [Caption] {
        EventParser.parse(data).compactMap { if case let .caption(value) = $0 { return value }; return nil }
    }

    func testAllowlistNeverDisplaysPrivateOrToolContent() throws {
        for phase in ["analysis", "unknown", ""] {
            XCTAssertTrue(captions(try record("response_item", ["type": "message", "role": "assistant", "phase": phase,
                "content": [["type": "output_text", "text": "PRIVATE"]]])).isEmpty)
        }
        XCTAssertTrue(captions(try record("response_item", ["type": "reasoning", "summary": [],
            "encrypted_content": "PRIVATE", "content": [["type": "text", "text": "PRIVATE"]]])).isEmpty)
        XCTAssertTrue(captions(try record("event_msg", ["type": "item_completed", "item": [
            "type": "Reasoning", "summary_text": [], "raw_content": ["PRIVATE"]]])).isEmpty)
        for type in ["function_call", "function_call_output", "custom_tool_call_output"] {
            XCTAssertTrue(captions(try record("response_item", ["type": type, "output": "PRIVATE"])).isEmpty)
        }
        for role in ["user", "system", "developer"] {
            XCTAssertTrue(captions(try record("response_item", ["type": "message", "role": role, "phase": "commentary",
                "content": [["type": "output_text", "text": "PRIVATE"]]])).isEmpty)
        }
    }

    func testPublicSummaryAndProgressSchemas() throws {
        let progress = try record("response_item", ["type": "message", "role": "assistant", "phase": "commentary",
            "content": [["type": "output_text", "text": "正在检查 **字幕**。"]]])
        XCTAssertEqual(captions(progress).first?.text, "正在检查 字幕。")
        XCTAssertEqual(captions(progress).first?.kind, .progress)
        let item = try record("event_msg", ["type": "item_completed", "item": ["type": "AgentMessage", "phase": "commentary",
            "content": [["type": "Text", "text": "公开进度"]]]])
        XCTAssertEqual(captions(item).first?.text, "公开进度")
        let summary = try record("response_item", ["type": "reasoning", "summary": [["type": "summary_text", "text": "公开摘要"]], "encrypted_content": "PRIVATE"])
        XCTAssertEqual(captions(summary).first?.text, "公开摘要")
        let persisted = try record("event_msg", ["type": "item_completed", "item": ["type": "Reasoning", "summary_text": ["公开摘要"], "raw_content": ["PRIVATE"]]])
        XCTAssertEqual(captions(persisted).first?.text, "公开摘要")
    }

    func testToolRecordsHaveCommandDurationAndFileCounts() throws {
        let command = try record("event_msg", ["type": "item_completed", "item": [
            "type": "CommandExecution", "command": ["/bin/zsh", "-lc", "swift build"],
            "status": "completed", "duration": ["secs": 13, "nanos": 0], "stdout": "PRIVATE"]])
        XCTAssertEqual(captions(command).first?.text, "命令完成 · 13s：swift build")
        XCTAssertEqual(captions(command).first?.kind, .tool)
        let change = try record("event_msg", ["type": "item_completed", "item": [
            "type": "FileChange", "status": "completed", "changes": ["/tmp/Package.swift": [
                "type": "update", "unified_diff": "--- old\n+++ new\n@@ -1 +1 @@\n-old\n+new\n+extra"]]]])
        XCTAssertEqual(captions(change).first?.text, "已编辑 Package.swift +2 −1")
        let publicCall = try record("response_item", ["type": "function_call", "name": "functions.exec_command",
            "arguments": "{\"cmd\":\"swift build\"}"])
        XCTAssertEqual(captions(publicCall).first?.text, "正在运行：swift build")
        let redacted = ToolCaption.command("API_KEY=secret curl --token=hidden -H 'Authorization: Bearer private'")
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("hidden"))
        XCTAssertFalse(redacted.contains("private"))
    }

    func testTruncatedMalformedAndUnknownRecordsAreIgnored() {
        for text in ["{", "not json", "{}", "[]", "null"] { XCTAssertTrue(EventParser.parse(Data(text.utf8)).isEmpty) }
    }

    func testDuplicateRepresentationsDoNotRestartCaption() {
        var session = SessionSnapshot(path: "a")
        let first = Caption(text: "检查中", kind: .progress, date: Date(timeIntervalSince1970: 1))
        let duplicate = Caption(text: "检查中", kind: .progress, date: Date(timeIntervalSince1970: 2))
        session.apply(.caption(first)); session.apply(.caption(duplicate))
        XCTAssertEqual(session.caption, first)
        session.apply(.started(Date()))
        XCTAssertNil(session.caption)
        XCTAssertTrue(session.active)
        session.apply(.finished(Date()))
        XCTAssertFalse(session.active)
    }

    func testSelectionPrefersActiveAndHonorsPin() {
        let now = Date()
        let active = SessionSnapshot(path: "active", active: true, activity: now.addingTimeInterval(-30))
        let complete = SessionSnapshot(path: "complete", activity: now)
        let abandoned = SessionSnapshot(path: "old", active: true, activity: now.addingTimeInterval(-7200))
        XCTAssertEqual(SessionSelection.choose([complete, active, abandoned], pinned: nil, now: now)?.path, "active")
        XCTAssertEqual(SessionSelection.choose([complete, active], pinned: "complete", now: now)?.path, "complete")
        XCTAssertEqual(SessionSelection.choose([complete, abandoned], pinned: nil, now: now)?.path, "complete")
        XCTAssertNil(SessionSelection.choose([active], pinned: "missing"))
    }

    func testSubagentStatusDoesNotReplaceParentProgressOrExposeChildBodies() {
        let tool = Caption(text: "调用完成：js", kind: .tool, date: Date(timeIntervalSince1970: 100))
        var parent = SessionSnapshot(path: "parent", active: true, caption: tool)
        XCTAssertEqual(parent.displayCaption(showAnswers: false), tool)
        parent.runningSubagentCount = 2
        parent.subagentActivity = Date(timeIntervalSince1970: 110)
        XCTAssertEqual(parent.displayCaption(showAnswers: false)?.text, "正在等待子 agent…（2 个）")
        XCTAssertEqual(parent.displayCaption(showAnswers: false)?.kind, .subagent)
        parent.runningSubagentCount = 1
        XCTAssertEqual(parent.displayCaption(showAnswers: false)?.text, "正在等待子 agent…")
        for value in [Caption(text: "正在汇总结果", kind: .progress, date: Date(timeIntervalSince1970: 120)),
                      Caption(text: "正在调用：js", kind: .tool, date: Date(timeIntervalSince1970: 120)),
                      Caption(text: "调用失败：js", kind: .tool, date: Date(timeIntervalSince1970: 120))] {
            parent.caption = value
            XCTAssertEqual(parent.displayCaption(showAnswers: false), value)
        }
        parent.caption = tool
        parent.answer = Caption(text: "父会话回答", kind: .answer, date: Date(timeIntervalSince1970: 130))
        XCTAssertEqual(parent.displayCaption(showAnswers: true), parent.answer)
        parent.runningSubagentCount = 0
        parent.subagentFinishedAt = Date(timeIntervalSince1970: 140)
        XCTAssertEqual(parent.displayCaption(showAnswers: false)?.text, "子 agent 已完成，正在继续处理…")
        parent.caption = Caption(text: "调用完成：js", kind: .tool, date: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(parent.displayCaption(showAnswers: false), parent.caption)
        parent.caption = tool
        parent.apply(.finished(Date(timeIntervalSince1970: 160)))
        XCTAssertEqual(parent.displayCaption(showAnswers: false), tool)
        XCTAssertEqual(parent.finishedAt, Date(timeIntervalSince1970: 160))
        parent.apply(.started(Date(timeIntervalSince1970: 170)))
        XCTAssertNil(parent.finishedAt)

        parent.source = .deepseek
        parent.caption = tool
        parent.runningSubagentCount = 2
        XCTAssertEqual(parent.displayCaption(showAnswers: false), tool)
        parent.runningSubagentCount = 0
        parent.subagentFinishedAt = Date(timeIntervalSince1970: 180)
        XCTAssertEqual(parent.displayCaption(showAnswers: false), tool)
        parent.answer = Caption(text: "父会话回答", kind: .answer, date: Date(timeIntervalSince1970: 190))
        XCTAssertEqual(parent.displayCaption(showAnswers: true), parent.answer)
        parent.caption = nil
        XCTAssertNil(parent.displayCaption(showAnswers: false))
    }

    func testTailPreservesUTF8PartialLinesAndHandlesTruncation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.jsonl")
        let line = Data("字幕👨‍👩‍👧‍👦\n".utf8)
        try line.prefix(2).write(to: url)
        let tail = LogTail(url: url)
        XCTAssertTrue(try tail.read().isEmpty)
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd(); try file.write(contentsOf: line.dropFirst(2)); try file.close()
        XCTAssertEqual(try tail.read(), [Data(line.dropLast())])
        XCTAssertTrue(try tail.read().isEmpty)
        try Data("a\n".utf8).write(to: url)
        XCTAssertEqual(try tail.read(), [Data("a".utf8)])
        XCTAssertTrue(tail.didReset)
    }

    func testTailDropsPartialHistoricalFirstLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("very-long-old-record\nnew\n".utf8).write(to: url)
        let tail = LogTail(url: url)
        XCTAssertEqual(try tail.read(maxInitialBytes: 8), [Data("new".utf8)])
    }

    func testTailIdleCostAndInvalidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var tails: [LogTail] = []
        for i in 0..<80 {
            let url = root.appendingPathComponent("\(i).jsonl")
            try Data("start\n中".utf8).write(to: url)
            let tail = LogTail(url: url)
            XCTAssertEqual(try tail.read(), [Data("start".utf8)])
            XCTAssertTrue(tail.lastOpenedFile)
            tails.append(tail)
        }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            for tail in tails {
                XCTAssertTrue(try tail.read().isEmpty)
                XCTAssertFalse(tail.lastOpenedFile)
                XCTAssertEqual(tail.lastReadBytes, 0)
                XCTAssertFalse(tail.hasUnreadBytes)
            }
        }
        print("PERF: 80 logs × 100 idle polls, opens=0 bytes=0 ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
        let tail = tails[0], url = tail.url
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("文\n".utf8)); try handle.close()
        XCTAssertEqual(try tail.read(), [Data("中文".utf8)])
        XCTAssertTrue(tail.lastOpenedFile)
        // Equal-size replacement still changes inode and must be read in full.
        let replacement = Data("other\n替换\n".utf8)
        XCTAssertEqual(replacement.count, try Data(contentsOf: url).count)
        try replacement.write(to: url, options: .atomic)
        XCTAssertEqual(try tail.read(), [Data("other".utf8), Data("替换".utf8)])
        XCTAssertTrue(tail.didReset && tail.lastOpenedFile)
        try Data().write(to: url)
        XCTAssertTrue(try tail.read().isEmpty)
        XCTAssertTrue(tail.didReset)
        XCTAssertFalse(tail.lastOpenedFile)
        try Data("retry\n".utf8).write(to: url)
        XCTAssertEqual(try tail.read(), [Data("retry".utf8)])
        try FileManager.default.removeItem(at: url)
        do { _ = try tail.read(); preconditionFailure("Missing logs must still report errors") }
        catch { XCTAssertFalse(tail.lastOpenedFile) }
        try Data("return\n".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(try tail.read(), [Data("return".utf8)])
        // Unchanged file size with a backlog must drain rather than take the idle path.
        let burst = Data((String(repeating: "x", count: 2_200_000) + "\n").utf8)
        try burst.write(to: url, options: .atomic)
        XCTAssertTrue(try tail.read(maxInitialBytes: Int.max).isEmpty)
        XCTAssertTrue(tail.hasUnreadBytes)
        XCTAssertEqual(try tail.read(), [Data(burst.dropLast())])
        XCTAssertTrue(tail.lastOpenedFile)
        XCTAssertFalse(tail.hasUnreadBytes)
    }

    func testPagesPreserveGraphemesAndDoNotLoseText() {
        let text = String(repeating: "字幕👨‍👩‍👧‍👦正在显示。", count: 30)
        let pages = CaptionText.pages(text, limit: 36)
        XCTAssertEqual(pages.joined(), text)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 36 })
        XCTAssertTrue(pages.count > 1)
        XCTAssertEqual(CaptionText.pages("短句"), ["短句"])
    }

    func testHarnessPackedReasoningAndMessageBoundaries() throws {
        let parser = HarnessEventParser()
        var session = SessionSnapshot(path: "harness")
        let header = try JSONSerialization.data(withJSONObject: ["type": "session", "version": 0,
            "id": "fixture", "cwd": "/fixture", "delegationDepth": 0])
        parser.parse(header).forEach { session.apply($0) }
        parser.parse(try harness("session/title", ["title": "Harness 对话标题"])).forEach { session.apply($0) }
        parser.parse(try harness("turn/start", [:])).forEach { session.apply($0) }
        let packed = try JSONSerialization.data(withJSONObject: ["type": "reasoning-chunks", "seq0": 2,
            "time0": 1785498588575, "data": ["turn": 1, "step": 1, "index": 0,
                "dt": [1, 2], "texts": ["正在", "核对", "实现。"]]])
        parser.parse(packed).forEach { session.apply($0) }
        XCTAssertEqual(session.caption?.text, "正在核对实现。")
        XCTAssertEqual(session.caption?.kind, .reasoning)
        XCTAssertEqual(session.caption?.date, Date(timeIntervalSince1970: 1785498588.578))
        parser.parse(try harness("assistant/chunk", ["chunk": ["type": "reasoning-delta", "index": 0, "text": "继续。"]])).forEach { session.apply($0) }
        XCTAssertEqual(session.caption?.text, "正在核对实现。继续。")
        let message: [String: Any] = ["message": ["role": "assistant", "content": [
            ["type": "reasoning", "text": "正在核对实现。继续。"], ["type": "text", "text": "最终回答"]]]]
        parser.parse(try harness("assistant/message", message, time: 1785498590000)).forEach { session.apply($0) }
        parser.parse(try harness("turn/end", [:])).forEach { session.apply($0) }
        XCTAssertFalse(session.active)
        XCTAssertEqual(session.displayCaption(showAnswers: false)?.kind, .reasoning)
        XCTAssertEqual(session.displayCaption(showAnswers: true)?.text, "最终回答")
        XCTAssertEqual(session.title, "Harness 对话标题")
        parser.reset()
        let child = try JSONSerialization.data(withJSONObject: ["type": "session", "version": 0,
            "id": "child", "delegationDepth": 1, "parentSession": "fixture"])
        _ = parser.parse(child)
        XCTAssertTrue(parser.isSubagent)
        XCTAssertEqual(parser.parentSessionID, "fixture")
        for version in [3, 4] {
            parser.reset()
            var modern = SessionSnapshot(path: "modern")
            let header = try JSONSerialization.data(withJSONObject: ["type": "session", "version": version,
                "id": "modern", "delegationDepth": 0])
            parser.parse(header).forEach { modern.apply($0) }
            parser.parse(try harness("assistant/message", ["message": ["role": "assistant", "content": [
                ["type": "reasoning", "text": "现代版本思考"], ["type": "text", "text": "回答"]]],
                "stream": [["type": "reasoning-chunks", "texts": ["现代版本思考"]]]])).forEach { modern.apply($0) }
            XCTAssertEqual(modern.id, "modern")
            XCTAssertEqual(modern.caption?.text, "现代版本思考")
        }
    }

    func testHarnessMigrationArtifactsSelectOneVersion() {
        let legacy = URL(fileURLWithPath: "/sessions/one/session.jsonl.zstd")
        let v3 = URL(fileURLWithPath: "/sessions/one/session.v3.jsonl.zstd")
        let v4 = URL(fileURLWithPath: "/sessions/one/session.v4.jsonl.zstd")
        let other = URL(fileURLWithPath: "/sessions/two/session.v3.jsonl")
        let unknown = URL(fileURLWithPath: "/sessions/three/session.v99.jsonl.zstd")
        XCTAssertEqual(Set(HarnessLogFormat.preferred([legacy, v4, v3, other, unknown])), Set([v4, other]))
    }

    func testHarnessToolsAndPrivateInputs() throws {
        let parser = HarnessEventParser()
        for type in ["user/message", "request/header", "request/context", "agent/inbox/spliced", "text-chunks", "unknown"] {
            XCTAssertTrue(parser.parse(try harness(type, ["text": "PRIVATE", "content": [["type": "text", "text": "PRIVATE"]]])).isEmpty)
        }
        XCTAssertTrue(parser.parse(try harness("assistant/message", ["message": ["role": "user", "content": [["type": "text", "text": "PRIVATE"]]]])).isEmpty)
        var session = SessionSnapshot(path: "harness")
        parser.parse(try harness("tool/call", ["callId": "call", "name": "bash",
            "arguments": "{\"command\":\"TOKEN=secret swift build\"}"])).forEach { session.apply($0) }
        XCTAssertEqual(session.caption?.text, "正在运行：TOKEN=••• swift build")
        parser.parse(try harness("tool/result", ["message": ["source": ["callId": "call"],
            "content": [["type": "tool-result", "isError": true, "content": [["type": "text", "text": "PRIVATE"]]]]]],
            time: 1785498591575)).forEach { session.apply($0) }
        XCTAssertEqual(session.caption?.text, "调用失败 · 3s：bash")
        XCTAssertTrue(parser.parse(try harness("tool/result", ["message": ["source": ["callId": "unknown"], "content": []]])).isEmpty)
    }

    func testZstdConcatenatedFramesPartialWritesAndReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func compress(_ text: String) throws -> Data {
            let input = root.appendingPathComponent("input")
            try Data(text.utf8).write(to: input)
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/zstd")
            process.arguments = ["-q", "-c", input.path]
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            return output
        }
        let first = try compress("header\n"), second = try compress("思考👨‍👩‍👧‍👦\n")
        let url = root.appendingPathComponent("session.jsonl.zstd")
        try (first + second.prefix(3)).write(to: url)
        let tail = ZstdLogTail(url: url)
        XCTAssertEqual(try tail.read(), [Data("header".utf8)])
        XCTAssertTrue(try tail.read().isEmpty)
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd(); try file.write(contentsOf: second.dropFirst(3)); try file.close()
        XCTAssertEqual(try tail.read(), [Data("思考👨‍👩‍👧‍👦".utf8)])
        XCTAssertTrue(try tail.read().isEmpty)
        try first.write(to: url)
        XCTAssertEqual(try tail.read(), [Data("header".utf8)])
        XCTAssertTrue(tail.didReset)
        let replacement = root.appendingPathComponent("replacement")
        try second.write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        XCTAssertEqual(try tail.read(), [Data("思考👨‍👩‍👧‍👦".utf8)])
        XCTAssertTrue(tail.didReset)
        let largeText = String(repeating: "一条字幕记录。\n", count: 120_000)
        try compress(largeText).write(to: url)
        let largeTail = ZstdLogTail(url: url)
        var lineCount = 0
        for _ in 0..<10 { lineCount += try largeTail.read().count }
        XCTAssertEqual(lineCount, 120_000)
        try Data("invalid zstandard stream".utf8).write(to: url)
        do { _ = try ZstdLogTail(url: url).read(); preconditionFailure("Corrupt data must fail") }
        catch { }
    }
}

@main
enum CoreChecks {
    static func main() throws {
        if ProcessInfo.processInfo.environment["SINGING_ONLY"] == "1" { SingingChecks.run(); return }
        if ProcessInfo.processInfo.environment["BEATNET_ONLY"] == "1" { BeatNetChecks.run(); return }
        if let directory = ProcessInfo.processInfo.environment["BTRACK_PCM_DIRECTORY"] { try BTrackPCMChecks.run(directory: directory); return }
        if ProcessInfo.processInfo.environment["BTRACK_ONLY"] == "1" { BTrackChecks.run(); return }
        if ProcessInfo.processInfo.environment["WORKBUDDY_ONLY"] == "1" {
            try WorkBuddyChecks.run()
            if ProcessInfo.processInfo.environment["WORKBUDDY_PERFORMANCE"] == "1" { try WorkBuddyChecks.performance() }
            return
        }
        try WorkBuddyChecks.run()
        try OpenCodeChecks.run()
        if ProcessInfo.processInfo.environment["OPENCODE_PERFORMANCE"] == "1" { try OpenCodeChecks.performance() }
        if ProcessInfo.processInfo.environment["OPENCODE_ONLY"] == "1" { return }
        let tests = CaptionCoreTests()
        try HarnessMetricsChecks.run()
        if ProcessInfo.processInfo.environment["HARNESS_METRICS_REPLAY"] == "1" {
            try HarnessMetricsChecks.replay(Array(CommandLine.arguments.dropFirst()))
        }
        if ProcessInfo.processInfo.environment["HARNESS_METRICS_ONLY"] == "1" { return }
        try tests.testCodexQuota()
        tests.testTypewriterSpeedMapping()
        try tests.testCodexResponseSpeed()
        try ClaudeChecks.run()
        DoubaoChecks.run()
        try UserQuestionChecks.run()
        if ProcessInfo.processInfo.environment["QUESTIONS_ONLY"] == "1" { return }
        try TaskOutcomeChecks.run()
        if ProcessInfo.processInfo.environment["TASK_OUTCOME_ONLY"] == "1" { return }
        SpeechKeywordChecks.run()
        AudioRecognitionChecks.run()
        if ProcessInfo.processInfo.environment["SPEECH_KEYWORD_ONLY"] == "1" { return }
        SongEasterEggChecks.run()
        LipMFCCChecks.run()
        VocalDSPChecks.run()
        LipPrecisionChecks.run()
        MouthTransitionChecks.run()
        LaughterChecks.run()
        if ProcessInfo.processInfo.environment["LIP_PRECISION_ONLY"] == "1" { return }
        LiveLipChecks.run()
        try tests.testAllowlistNeverDisplaysPrivateOrToolContent()
        try tests.testPublicSummaryAndProgressSchemas()
        try tests.testToolRecordsHaveCommandDurationAndFileCounts()
        tests.testTruncatedMalformedAndUnknownRecordsAreIgnored()
        tests.testDuplicateRepresentationsDoNotRestartCaption()
        tests.testSelectionPrefersActiveAndHonorsPin()
        tests.testSubagentStatusDoesNotReplaceParentProgressOrExposeChildBodies()
        try tests.testTailPreservesUTF8PartialLinesAndHandlesTruncation()
        try tests.testTailDropsPartialHistoricalFirstLine()
        try tests.testTailIdleCostAndInvalidation()
        tests.testPagesPreserveGraphemesAndDoNotLoseText()
        try tests.testHarnessPackedReasoningAndMessageBoundaries()
        try tests.testHarnessToolsAndPrivateInputs()
        tests.testHarnessMigrationArtifactsSelectOneVersion()
        try tests.testZstdConcatenatedFramesPartialWritesAndReset()
        print("PASS: 14 core checks (Codex, Harness v0/v3/v4 reasoning/tools/filtering/migration, subagent status, compressed partial frames/reset, selection, UTF-8, pagination)")
    }
}
