import Foundation
import CaptionCore
import CSQLite

private func workBuddyCheck(_ value: Bool, _ message: String = "") { precondition(value, message) }

enum WorkBuddyChecks {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workbuddy-check-" + UUID().uuidString)
        let project: URL
        var db: OpaquePointer?
        init() throws {
            project = root.appendingPathComponent("projects/project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            workBuddyCheck(sqlite3_open(root.appendingPathComponent("workbuddy.db").path, &db) == SQLITE_OK)
            exec("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE sessions(id TEXT PRIMARY KEY,cwd TEXT,title TEXT,custom_title TEXT,status TEXT,
                    created_at INTEGER,updated_at INTEGER,last_activity_at INTEGER,deleted_at INTEGER,transport TEXT,project_id TEXT);
                """)
        }
        deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
        func exec(_ sql: String) { workBuddyCheck(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sql) }
        func session(_ id: String, at: Int64, status: String = "working", transport: String = "local") {
            exec("INSERT INTO sessions VALUES('\(id)','/fixture','测试任务',NULL,'\(status)',\(at),\(at),\(at),NULL,'\(transport)',NULL)")
        }
        func status(_ id: String, _ status: String, at: Int64) {
            exec("UPDATE sessions SET status='\(status)',updated_at=\(at),last_activity_at=\(at) WHERE id='\(id)'")
        }
        func log(_ id: String) -> URL { project.appendingPathComponent(id + ".jsonl") }
        func append(_ id: String, _ row: [String: Any]) throws {
            var row = row; row["sessionId"] = row["sessionId"] ?? id; row["cwd"] = row["cwd"] ?? "/fixture"
            let data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys) + Data([10])
            if !FileManager.default.fileExists(atPath: log(id).path) { try Data().write(to: log(id)) }
            let handle = try FileHandle(forWritingTo: log(id)); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
        func text(_ id: String, _ text: String, at: Int64, role: String = "assistant", rowID: String = UUID().uuidString) throws {
            try append(id, ["type": "message", "id": rowID, "timestamp": at, "status": "completed", "role": role,
                "providerData": ["agent": "cli", "startsNewUserRequest": role == "user"],
                "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]])
        }
    }
    static func run() throws {
        let f = try Fixture(), now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        f.session("parent", at: ms); f.session("cloud", at: ms + 1, transport: "cloud")
        try f.text("parent", "PRIVATE_USER", at: ms, role: "user")
        try f.text("cloud", "PRIVATE_CLOUD", at: ms)
        try f.text("child", "PRIVATE_CHILD", at: ms)
        try f.append("parent", ["type": "reasoning", "id": "internal", "timestamp": ms,
            "rawContent": [["type": "text", "text": "PRIVATE_THINKING"]]])
        let reader = WorkBuddyReader(root: f.root)
        var values = try reader.poll(now: now)
        workBuddyCheck(values.count == 1 && values[0].active && values[0].caption == nil)
        workBuddyCheck(values[0].source == .workbuddy && values[0].projectID.isEmpty)
        try f.text("parent", "公开进度", at: ms + 1)
        values = try reader.poll(now: now.addingTimeInterval(0.7))
        workBuddyCheck(values[0].caption?.text == "公开进度" && values[0].active && values[0].answer == nil)
        workBuddyCheck(reader.metrics.queries == 1 && reader.metrics.logReads == 1 && reader.metrics.directoryEntries == 0)
        let unchanged = try reader.poll(now: now.addingTimeInterval(1.4))
        workBuddyCheck(unchanged == values && reader.metrics.logReads == 0 && reader.metrics.bytesRead == 0)
        try f.append("parent", ["type": "function_call", "id": "call", "name": "Bash", "timestamp": ms + 2,
            "arguments": "PRIVATE_TOKEN", "providerData": ["reasoning": "PRIVATE_THINKING"]])
        values = try reader.poll(now: now.addingTimeInterval(2.1))
        workBuddyCheck(values[0].caption?.text == "公开进度", "same-poll/rapid tools must not erase unread assistant text")
        try f.append("parent", ["type": "function_call_result", "id": "result", "name": "Bash", "timestamp": ms + 3,
            "status": "failed", "output": ["text": "PRIVATE_OUTPUT"]])
        values = try reader.poll(now: now.addingTimeInterval(2.8))
        workBuddyCheck(values[0].active && values[0].outcome == nil && values[0].caption?.text == "公开进度")
        try f.text("parent", "公开最终回答", at: ms + 4)
        f.status("parent", "completed", at: ms + 3) // final public text can arrive after the DB terminal stamp
        values = try reader.poll(now: now.addingTimeInterval(3.5))
        workBuddyCheck(!values[0].active && values[0].answer?.text == "公开最终回答" && values[0].outcome == .completed)
        workBuddyCheck(reader.metrics.fullScanSteps == 0 && reader.metrics.sortOperations == 0)
        workBuddyCheck(values[0].displayCaption(showAnswers: true)?.kind == .answer)
        workBuddyCheck(values[0].displayCaption(showAnswers: false) == nil)
        // A new user log can arrive before the database leaves its old terminal state.
        try f.text("parent", "PRIVATE_NEW_USER", at: ms + 5, role: "user")
        values = try reader.poll(now: now.addingTimeInterval(4.2))
        workBuddyCheck(values[0].active && values[0].answer == nil && values[0].caption == nil)
        f.status("parent", "working", at: ms + 5)
        try f.text("parent", "继续执行", at: ms + 6)
        _ = try reader.poll(now: now.addingTimeInterval(4.9))
        f.status("parent", "terminated", at: ms + 7)
        values = try reader.poll(now: now.addingTimeInterval(5.6))
        workBuddyCheck(!values[0].active && values[0].outcome == .interrupted && values[0].answer == nil)
        // Metadata can start a new turn before its log arrives; no old text survives.
        f.status("parent", "planning", at: ms + 8)
        values = try reader.poll(now: now.addingTimeInterval(6.3))
        workBuddyCheck(values[0].active && values[0].caption == nil && values[0].outcome == nil)
        // Atomic log replacement resets the parser and its visible body.
        try Data().write(to: f.log("parent"), options: .atomic)
        try f.text("parent", "替换后的公开文本", at: ms + 9)
        values = try reader.poll(now: now.addingTimeInterval(7))
        workBuddyCheck(values[0].caption?.text == "替换后的公开文本")
        let replacement = String(data: try Data(contentsOf: f.log("parent")), encoding: .utf8)!
            .replacingOccurrences(of: "替换后的公开文本", with: "重写后的公开文本")
        let writer = try FileHandle(forWritingTo: f.log("parent"))
        try writer.write(contentsOf: Data(replacement.utf8)); try writer.close()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: f.log("parent").path)
        values = try reader.poll(now: now.addingTimeInterval(7.1))
        workBuddyCheck(values[0].caption?.text == "重写后的公开文本")
        try FileManager.default.removeItem(at: f.log("parent"))
        workBuddyCheck(try reader.poll(now: now.addingTimeInterval(7.2)).isEmpty)
        try f.text("parent", "文件恢复后继续", at: ms + 10)
        workBuddyCheck(try reader.poll(now: now.addingTimeInterval(7.4))[0].caption?.text == "文件恢复后继续")
        workBuddyCheck(reader.metrics.fullScanSteps == 0 && reader.metrics.directoryEntries == 0)
        // Streaming partial UTF-8/JSON does not leak or lose the eventual line.
        let row: [String: Any] = ["type": "message", "id": "partial", "timestamp": ms + 11, "sessionId": "parent",
            "cwd": "/fixture", "role": "assistant", "content": [["type": "output_text", "text": "中文👨‍👩‍👧‍👦续写"]]]
        let data = try JSONSerialization.data(withJSONObject: row) + Data([10])
        let handle = try FileHandle(forWritingTo: f.log("parent")); try handle.seekToEnd()
        try handle.write(contentsOf: data.dropLast(5)); _ = try reader.poll(now: now.addingTimeInterval(7.5))
        try handle.write(contentsOf: data.suffix(5)); try handle.close()
        values = try reader.poll(now: now.addingTimeInterval(7.6))
        workBuddyCheck(values[0].caption?.text == "中文👨‍👩‍👧‍👦续写")
        let parser = WorkBuddyEventParser()
        for row in [
            ["type": "message", "role": "assistant", "sessionId": "other"],
            ["type": "message", "role": "assistant", "sessionId": "parent", "cwd": "/other"],
            ["type": "message", "role": "assistant", "sessionId": "parent", "isSidechain": true],
            ["type": "message", "role": "assistant", "sessionId": "parent", "providerData": ["agent": "child"]],
            ["type": "message", "role": "system", "sessionId": "parent"]
        ] as [[String: Any]] {
            var row = row; row["timestamp"] = ms
            row["content"] = [["type": "output_text", "text": "PRIVATE_REJECTED"]]
            workBuddyCheck(parser.parse(try JSONSerialization.data(withJSONObject: row), sessionID: "parent", cwd: "/fixture").isEmpty)
        }
        f.exec("UPDATE sessions SET custom_title='改名',project_id='same-id' WHERE id='parent'")
        values = try reader.poll(now: now.addingTimeInterval(7.7))
        workBuddyCheck(values[0].title == "改名" && values[0].projectID == "workbuddy:same-id")
        // A burst larger than the per-read budget drains across unchanged polls.
        let burst = Data(String(repeating: "{\"type\":\"reasoning\",\"rawContent\":\"" + String(repeating: "x", count: 2400) + "\"}\n", count: 1000).utf8)
        let burstWriter = try FileHandle(forWritingTo: f.log("parent")); try burstWriter.seekToEnd()
        try burstWriter.write(contentsOf: burst); try burstWriter.close()
        try f.text("parent", "突发记录末尾", at: ms + 12)
        _ = try reader.poll(now: now.addingTimeInterval(7.71))
        workBuddyCheck(reader.metrics.bytesRead == 2_000_000)
        values = try reader.poll(now: now.addingTimeInterval(7.72))
        workBuddyCheck(values[0].caption?.text == "突发记录末尾" && reader.metrics.logReads == 1)
        f.exec("UPDATE sessions SET deleted_at=1 WHERE id='parent'")
        workBuddyCheck(try reader.poll(now: now.addingTimeInterval(7.8)).isEmpty)
        f.exec("UPDATE sessions SET deleted_at=NULL WHERE id='parent'")
        workBuddyCheck(try reader.poll(now: now.addingTimeInterval(9)).count == 1)
        f.exec("ALTER TABLE sessions RENAME TO unavailable")
        do { _ = try reader.poll(now: now.addingTimeInterval(18)); preconditionFailure("Unsupported schema accepted") } catch {}
        f.exec("ALTER TABLE unavailable RENAME TO sessions")
        workBuddyCheck(try reader.poll(now: now.addingTimeInterval(19)).count == 1)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("workbuddy.db"))
        workBuddyCheck(try reader.poll(now: now.addingTimeInterval(20)).isEmpty)
        let textFixture = try Fixture()
        textFixture.session("thinking", at: ms)
        try textFixture.append("thinking", ["type": "reasoning", "timestamp": ms,
            "providerData": ["agent": "cli"], "content": [],
            "rawContent": [["type": "reasoning_text", "text": "正在比较两个实现方案。"],
                           ["type": "text", "text": "PRIVATE_OTHER_RAW"]]])
        try textFixture.append("thinking", ["type": "function_call", "timestamp": ms + 1, "name": "Read", "arguments": "PRIVATE_ARGUMENTS"])
        try textFixture.append("thinking", ["type": "function_call_result", "timestamp": ms + 2, "name": "Read", "status": "completed", "output": "PRIVATE_OUTPUT"])
        let textReader = WorkBuddyReader(root: textFixture.root)
        var textValues = try textReader.poll(now: now)
        workBuddyCheck(textValues[0].caption?.kind == .reasoning && textValues[0].caption?.text == "正在比较两个实现方案。")
        textValues = try textReader.poll(now: now.addingTimeInterval(5))
        workBuddyCheck(textValues[0].caption?.text == "调用完成：Read" && textReader.metrics.logReads == 0)
        try textFixture.text("thinking", "请确认交付方式。", at: ms + 10)
        try textFixture.append("thinking", ["type": "function_call", "timestamp": ms + 11, "name": "AskUserQuestion"])
        textFixture.status("thinking", "pending", at: ms + 11)
        textValues = try textReader.poll(now: now.addingTimeInterval(6))
        workBuddyCheck(!textValues[0].active && textValues[0].caption?.text == "请确认交付方式。")
        workBuddyCheck(try textReader.poll(now: now.addingTimeInterval(16))[0].caption?.text == "请确认交付方式。")
        try textFixture.text("thinking", "最终交付结果。", at: ms + 12)
        textFixture.status("thinking", "completed", at: ms + 12)
        textValues = try textReader.poll(now: now.addingTimeInterval(17))
        workBuddyCheck(textValues[0].answer?.text == "最终交付结果。" && textValues[0].caption == nil)
        print("PASS: WorkBuddy reasoning_text, readable text before rapid tools, pending replies, final answer, allowlist, local identity, lifecycle, Unicode, replacement and retry")
    }
    static func performance() throws {
        let f = try Fixture(), now = Date(), start = ProcessInfo.processInfo.systemUptime
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        f.exec("BEGIN")
        for i in 0..<10_000 {
            let id = String(format: "s%05d", i); f.session(id, at: ms - Int64(i), status: "working")
            try Data().write(to: f.log(id))
        }
        f.exec("COMMIT")
        // Large historical bodies must not be decoded on idle or metadata-only polls.
        var history = Data()
        for i in 0..<1000 {
            let row: [String: Any] = ["type": "reasoning", "id": "history-\(i)", "sessionId": "s00000", "cwd": "/fixture",
                "timestamp": ms - 1_000_000, "content": [], "providerData": ["agent": "cli"],
                "rawContent": [["type": "reasoning_text", "text": String(repeating: "x", count: 950)]]]
            history.append(try JSONSerialization.data(withJSONObject: row)); history.append(10)
        }
        let handle = try FileHandle(forWritingTo: f.log("s00000"))
        for _ in 0..<100 { try handle.write(contentsOf: history) }; try handle.close()
        for i in 0..<32 { try f.text(String(format: "s%05d", i), "近期公开文本", at: ms - Int64(i)) }
        print(String(format: "WorkBuddy fixture: 10000 sessions/logs, 100000 historical records; preparation %.3f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        let reader = WorkBuddyReader(root: f.root)
        func measure(_ label: String, at date: Date, count: Int = 32) throws {
            let start = ProcessInfo.processInfo.systemUptime
            let values = try reader.poll(now: date), m = reader.metrics
            workBuddyCheck(values.count == count)
            workBuddyCheck(m.fullScanSteps <= (m.discovered ? 10_000 : 0) && m.sortOperations <= (m.discovered ? 1 : 0))
            workBuddyCheck(m.bytesRead <= (m.discovered ? 600_000 : 2_000_000))
            print(String(format: "WorkBuddy %@: %.3f ms queries=%d rows=%d scan=%d sorts=%d entries=%d stats=%d reads=%d bytes=%d lines=%d", label,
                (ProcessInfo.processInfo.systemUptime - start) * 1000, m.queries, m.rows, m.fullScanSteps, m.sortOperations,
                m.directoryEntries, m.statCalls, m.logReads, m.bytesRead, m.decodedLines))
        }
        try measure("cold", at: now)
        try measure("idle", at: now.addingTimeInterval(0.7))
        workBuddyCheck(reader.metrics.queries == 1 && reader.metrics.logReads == 0 && reader.metrics.decodedLines == 0)
        try f.text("s00000", "单条变化", at: ms + 1)
        try measure("one appended line", at: now.addingTimeInterval(1.4))
        workBuddyCheck(reader.metrics.logReads == 1 && reader.metrics.decodedLines == 1 && reader.metrics.directoryEntries == 0)
        f.exec("UPDATE sessions SET custom_title='新标题' WHERE id='s00000'")
        try measure("metadata change", at: now.addingTimeInterval(2.1))
        workBuddyCheck(reader.metrics.queries <= 33 && reader.metrics.logReads == 0 && reader.metrics.directoryEntries == 0)
        try measure("discovery", at: now.addingTimeInterval(9))
        workBuddyCheck(reader.metrics.logReads == 0 && reader.metrics.decodedLines == 0)
        try measure("idle after discovery", at: now.addingTimeInterval(9.7), count: 32)
        let pinned = try reader.poll(pinned: f.log("s09999").path, now: now.addingTimeInterval(10.4))
        workBuddyCheck(pinned.count == 33 && pinned.contains { $0.id == "s09999" })
        let unpinned = try reader.poll(now: now.addingTimeInterval(11.1)); workBuddyCheck(unpinned.count == 32)
        var idleTimes: [Double] = []
        for _ in 0..<32 {
            let start = ProcessInfo.processInfo.systemUptime
            workBuddyCheck(try reader.poll(now: now.addingTimeInterval(11.2)).count == 32)
            idleTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            workBuddyCheck(reader.metrics.queries == 1 && reader.metrics.logReads == 0
                && reader.metrics.decodedLines == 0 && reader.metrics.directoryEntries == 0)
        }
        idleTimes.sort()
        print(String(format: "WorkBuddy 32 steady idle rounds: median %.3f ms p95 %.3f ms max %.3f ms; one query and zero body reads each",
                     idleTimes[16], idleTimes[30], idleTimes[31]))
        if let path = ProcessInfo.processInfo.environment["WORKBUDDY_CHECK_ROOT"] {
            let real = WorkBuddyReader(root: URL(fileURLWithPath: path))
            for label in ["cold", "idle"] {
                let start = ProcessInfo.processInfo.systemUptime; let values = try real.poll()
                print(String(format: "WorkBuddy real %@: %.3f ms sessions=%d reads=%d bytes=%d lines=%d", label,
                    (ProcessInfo.processInfo.systemUptime - start) * 1000, values.count, real.metrics.logReads, real.metrics.bytesRead, real.metrics.decodedLines))
            }
        }
    }
}
