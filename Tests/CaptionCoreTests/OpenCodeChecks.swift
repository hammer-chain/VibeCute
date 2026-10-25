import Foundation
import CaptionCore
import CSQLite

enum OpenCodeChecks {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-checks-" + UUID().uuidString)
        var db: OpaquePointer?
        var url: URL { root.appendingPathComponent("opencode.db") }
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
            exec("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE project(id TEXT PRIMARY KEY,name TEXT);
                CREATE TABLE session(id TEXT PRIMARY KEY,project_id TEXT,parent_id TEXT,directory TEXT,title TEXT,time_updated INTEGER,time_archived INTEGER);
                CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);
                CREATE INDEX message_session_time_created_id_idx ON message(session_id,time_created,id);
                CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,time_updated INTEGER,data TEXT);
                CREATE INDEX part_message_id_id_idx ON part(message_id,id);
                INSERT INTO project VALUES('project','字幕项目');
                INSERT INTO project VALUES('global',NULL);
                """)
        }
        deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
        func exec(_ sql: String) { precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        func json(_ value: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), encoding: .utf8)!
                .replacingOccurrences(of: "'", with: "''")
        }
        func session(_ id: String = "session", parent: String? = nil, project: String = "project", at time: Int64 = 1000) {
            exec("INSERT INTO session VALUES('\(id)','\(project)',\(parent.map { "'\($0)'" } ?? "NULL"),'/fixture','OpenCode 对话',\(time),NULL)")
        }
        func message(_ id: String, _ body: [String: Any], session: String = "session", at time: Int64) {
            exec("INSERT OR REPLACE INTO message VALUES('\(id)','\(session)',\(time),\(time),'\(json(body))')")
        }
        func part(_ id: String, _ body: [String: Any], message: String = "a", session: String = "session", at time: Int64 = 1100) {
            exec("INSERT OR REPLACE INTO part VALUES('\(id)','\(message)','\(session)',\(time),'\(json(body))')")
        }
    }

    private static func versionTwo() throws {
        let f = try Fixture()
        f.session("legacy"); f.session("shared")
        let reader = OpenCodeReader(url: f.url)
        _ = try reader.poll()
        // Simulate an in-place upgrade while the reader remains open.
        f.exec("""
            CREATE TABLE session_v2 AS SELECT * FROM session WHERE 0;
            CREATE UNIQUE INDEX v2_id ON session_v2(id);
            INSERT INTO session_v2 SELECT * FROM session WHERE id='shared';
            CREATE TABLE session_message(id TEXT PRIMARY KEY,session_id TEXT,type TEXT,seq INTEGER,time_created INTEGER,time_updated INTEGER,data TEXT);
            CREATE UNIQUE INDEX v2_seq ON session_message(session_id,seq);
            CREATE INDEX v2_type_seq ON session_message(session_id,type,seq);
            """)
        func message(_ id: String, _ type: String, _ seq: Int, _ data: [String: Any]) {
            f.exec("INSERT OR REPLACE INTO session_message VALUES('\(id)','shared','\(type)',\(seq),\(1000+seq),\(1000+seq),'\(f.json(data))')")
        }
        message("u2", "user", 0, ["text": "PRIVATE_USER"])
        for seq in 1...10 {
            message("a\(seq)", "assistant", seq, ["content": [["type": "tool", "name": "shell", "state": ["status": "running", "input": ["command": "swift build"], "content": "PRIVATE_OUTPUT"]]], "finish": "tool-calls"])
        }
        var values = try reader.poll()
        precondition(values.count == 2 && Set(values.map(\.id)) == ["legacy", "shared"])
        var value = values.first { $0.id == "shared" }!
        precondition(value.active && value.caption?.text == "正在调用：swift build")
        message("a10", "assistant", 10, ["content": [["type": "reasoning", "text": "2.0 流式思考"]]])
        value = try reader.poll().first { $0.id == "shared" }!
        precondition(value.active && value.caption?.text == "2.0 流式思考")
        message("a10", "assistant", 10, ["content": [["type": "text", "text": "2.0 最终回答"]], "finish": "stop", "time": ["created": 1000, "completed": 2000], "tokens": ["output": 100]])
        value = try reader.poll().first { $0.id == "shared" }!
        precondition(!value.active && value.answer?.text == "2.0 最终回答" && value.openCodeResponseSpeed?.tokensPerSecond == 100)
        values = try reader.poll()
        precondition(reader.metrics.cacheHit && reader.metrics.queries == 1)
        message("u3", "user", 11, ["text": "PRIVATE_NEW_USER"])
        value = try reader.poll().first { $0.id == "shared" }!
        precondition(value.active && value.answer == nil && value.caption == nil)
        message("failed", "assistant", 12, ["error": ["type": "APIError", "message": "PRIVATE_ERROR"], "time": ["completed": 3000]])
        value = try reader.poll().first { $0.id == "shared" }!
        precondition(value.outcome == .failed && value.caption == nil)
        f.exec("DELETE FROM session_message WHERE seq>10")
        // V2-only installs must not prepare SQL against absent legacy tables.
        f.exec("DROP TABLE part; DROP TABLE message; DROP TABLE session")
        values = try reader.poll()
        precondition(values.count == 1 && values[0].answer?.text == "2.0 最终回答")
        print("PASS: OpenCode 2.0 streaming, shell, long tool turns, completion/speed, migration deduplication, live schema upgrade and V2-only database")
    }

    static func run() throws {
        try zcodeSchema()
        try versionTwo()
        try responseSpeed()
        let f = try Fixture()
        f.session(); f.session("child", parent: "session"); f.session("global", project: "global")
        f.message("u", ["role": "user"], at: 1000)
        f.part("user-text", ["type": "text", "text": "PRIVATE_USER"], message: "u")
        f.message("a", ["role": "assistant", "parentID": "u"], at: 1050)
        f.part("001", ["type": "reasoning", "text": "可见思考", "metadata": ["signature": "PRIVATE_SIGNATURE"]])
        f.part("002", ["type": "text", "text": "PRIVATE_SYNTHETIC", "synthetic": true])
        f.part("003", ["type": "text", "text": "PRIVATE_IGNORED", "ignored": true])
        f.part("004", ["type": "file", "url": "PRIVATE_ASSET"])
        f.message("child-a", ["role": "assistant"], session: "child", at: 1200)
        f.part("child-p", ["type": "text", "text": "PRIVATE_CHILD"], message: "child-a", session: "child")
        let reader = OpenCodeReader(url: f.url)
        let time = Date(timeIntervalSince1970: 2)
        func poll(_ at: Date? = nil, pinned: String? = nil) throws -> SessionSnapshot {
            let values = try reader.poll(pinned: pinned, now: at ?? time)
            precondition(values.count == 2 && !values.contains { $0.id == "child" })
            precondition(values.first { $0.id == "global" }?.projectID == "")
            return values.first { $0.id == "session" }!
        }
        var value = try poll()
        precondition(value.source == .opencode && value.caption?.text == "可见思考" && value.active)
        precondition(value.headerName == "字幕项目" && value.projectID == "project")
        let unchanged = try poll()
        precondition(unchanged == value && reader.metrics.cacheHit && reader.metrics.queries == 1 && reader.metrics.decodedParts == 0)
        // Projection changes must work even when the source reuses a timestamp.
        f.part("001", ["type": "reasoning", "text": "可见思考继续更新"])
        value = try poll()
        precondition(value.caption?.text == "可见思考继续更新" && reader.metrics.decodedParts == 1)
        f.part("005", ["type": "tool", "tool": "bash", "state": ["status": "running",
            "input": ["command": "API_KEY=PRIVATE_TOKEN swift build"], "output": "PRIVATE_OUTPUT"]])
        value = try poll()
        precondition(value.caption?.kind == .tool && !value.caption!.text.contains("PRIVATE"))
        f.part("005", ["type": "tool", "tool": "bash", "state": ["status": "error",
            "input": ["command": "swift build"], "error": "PRIVATE_ERROR", "time": ["start": 1000, "end": 3000]]])
        f.message("a", ["role": "assistant", "parentID": "u", "finish": "tool-calls", "time": ["completed": 3000]], at: 1050)
        value = try poll()
        precondition(value.active && value.outcome == nil && value.caption?.text == "调用失败 · 2s：swift build")
        f.part("005", ["type": "tool", "tool": "write", "state": ["status": "running", "input": ["path": "/fixture/Caption.swift"]]])
        value = try poll()
        precondition(value.caption?.text == "正在调用：write · Caption.swift")
        f.message("b", ["role": "assistant", "parentID": "u"], at: 4000)
        f.part("006", ["type": "text", "text": "最终回答"], message: "b", at: 4500)
        value = try poll()
        precondition(value.caption?.kind == .progress && value.active)
        f.message("b", ["role": "assistant", "parentID": "u", "finish": "stop", "time": ["completed": 5000]], at: 4000)
        value = try poll()
        precondition(!value.active && value.outcome == .completed && value.answer?.text == "最终回答")
        // Starting a new turn clears old answers; terminal errors need no finish.
        f.message("v", ["role": "user"], at: 6000)
        value = try poll()
        precondition(value.active && value.answer == nil && value.caption == nil)
        for (name, outcome) in [("MessageAbortedError", TaskOutcome.interrupted), ("APIError", .failed)] {
            f.message("c", ["role": "assistant", "parentID": "v", "error": ["name": name]], at: 7000)
            value = try poll()
            precondition(!value.active && value.outcome == outcome)
        }
        f.exec("UPDATE session SET title='同步改名' WHERE id='session'; UPDATE project SET name='更新项目' WHERE id='project'")
        value = try poll()
        precondition(value.title == "同步改名" && value.headerName == "更新项目")
        // A newly created session before the discovery interval becomes visible
        // on the scheduled scan even if the database then stops changing.
        f.session("new", at: 8000)
        _ = try reader.poll(now: time.addingTimeInterval(1))
        let discovered = try reader.poll(now: time.addingTimeInterval(9))
        precondition(discovered.contains { $0.id == "new" })
        // Failure does not commit a cursor; a repaired source can be retried.
        f.exec("ALTER TABLE part RENAME TO broken_part")
        do { _ = try reader.poll(now: time.addingTimeInterval(10)); preconditionFailure("Unreadable schema must fail") } catch { }
        f.exec("ALTER TABLE broken_part RENAME TO part")
        let retried = try reader.poll(now: time.addingTimeInterval(11))
        precondition(retried.contains { $0.id == "session" })
        // Replacement and missing optional database must invalidate all caches.
        let replacement = try Fixture(); replacement.session("replacement")
        f.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        replacement.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try FileManager.default.removeItem(at: f.url)
        try FileManager.default.copyItem(at: replacement.url, to: f.url)
        let replaced = try reader.poll(now: time.addingTimeInterval(12))
        precondition(replaced.map(\.id) == ["replacement"])
        try FileManager.default.removeItem(at: f.url)
        let missing = try reader.poll()
        precondition(missing.isEmpty && !FileManager.default.fileExists(atPath: f.url.path))
        let pool = try Fixture()
        for i in 0..<40 { pool.session("s\(i)", at: Int64(i)) }
        pool.session("hidden", parent: "s0", at: 100)
        let bounded = OpenCodeReader(url: pool.url)
        let unpinned = try bounded.poll()
        precondition(unpinned.count == OpenCodeReader.sessionLimit && !unpinned.contains { $0.id == "s0" })
        let pinned = try bounded.poll(pinned: pool.url.path + "#s0")
        precondition(pinned.count == 33 && pinned.contains { $0.id == "s0" })
        let hidden = try bounded.poll(pinned: pool.url.path + "#hidden")
        precondition(hidden.count == 32 && !hidden.contains { $0.id == "hidden" })
        pool.exec("UPDATE session SET time_archived=100 WHERE id='s39'")
        let archived = try bounded.poll()
        precondition(!archived.contains { $0.id == "s39" })
        print("PASS: OpenCode WAL streaming, allowlist/redaction, completion/tool continuation/errors, children, titles, idle, discovery, retry and replacement")
    }

    private static func zcodeSchema() throws {
        let f = try Fixture()
        f.exec("DROP TABLE project")
        f.session("zcode-main"); f.session("zcode-child", parent: "zcode-main")
        f.exec("ALTER TABLE session ADD COLUMN time_deleted INTEGER")
        f.message("u", ["role": "user"], session: "zcode-main", at: 1000)
        f.message("a", ["role": "assistant", "parentID": "u"], session: "zcode-main", at: 1100)
        f.part("p001", ["type": "reasoning", "text": "正在分析"], message: "a", session: "zcode-main")
        f.part("p002", ["type": "text", "text": "先检查文件"], message: "a", session: "zcode-main", at: 1101)
        f.part("p003", ["type": "tool", "tool": "Bash", "state": ["status": "running",
            "input": ["command": "swift build"]]], message: "a", session: "zcode-main", at: 1102)
        f.part("private", ["type": "text", "text": "USER_PRIVATE"], message: "u", session: "zcode-main")
        let reader = OpenCodeReader(url: f.url, source: .zcode)
        var values = try reader.poll()
        precondition(values.count == 1 && values[0].source == .zcode && values[0].active)
        precondition(values[0].caption?.kind == .tool && values[0].projectID.isEmpty)
        precondition(values[0].displayCaption(showAnswers: true, showTools: true)?.text == "先检查文件")
        precondition(!values[0].displayCaption(showAnswers: true, showTools: true)!.text.contains("USER_PRIVATE"))
        f.message("steer", ["role": "user"], session: "zcode-main", at: 1150)
        f.message("b", ["role": "assistant", "parentID": "u", "finish": "stop",
                        "time": ["created": 1200, "completed": 1250]], session: "zcode-main", at: 1200)
        f.part("answer", ["type": "text", "text": "已完成"], message: "b", session: "zcode-main", at: 1250)
        values = try reader.poll()
        precondition(values.count == 1 && !values[0].active && values[0].answer?.text == "已完成")
        if let path = ProcessInfo.processInfo.environment["ZCODE_CHECK_DATABASE"] {
            let real = OpenCodeReader(url: URL(fileURLWithPath: path), source: .zcode)
            for label in ["cold", "idle"] {
                let start = ProcessInfo.processInfo.systemUptime
                let values = try real.poll()
                precondition(values.allSatisfy { $0.source == .zcode && !$0.id.isEmpty })
                let withAssistantAndTool = values.filter { $0.caption?.kind == .tool && $0.lastNonToolCaption != nil }
                precondition(withAssistantAndTool.allSatisfy {
                    $0.displayCaption(showAnswers: true, showTools: true)?.kind != .tool
                })
                print(String(format: "zcode real %@: %.3f ms, sessions=%d assistantBeforeTool=%d queries=%d rows=%d decodedParts=%d", label,
                    (ProcessInfo.processInfo.systemUptime - start) * 1000, values.count, withAssistantAndTool.count,
                    real.metrics.queries, real.metrics.rows, real.metrics.decodedParts))
            }
        }
        print("PASS: zcode legacy SQLite schema, child exclusion, steering, visible captions, completion and private input isolation")
    }

    static func responseSpeed() throws {
        let f = try Fixture()
        f.session()
        f.message("u", ["role": "user"], at: 1000)
        let reader = OpenCodeReader(url: f.url)
        func response(_ output: Any = 120, reasoning: Any = 80, created: Any = 2000,
                      completed: Any = 6000, finish: String = "stop", error: String? = nil) {
            var body: [String: Any] = ["role": "assistant", "parentID": "u", "finish": finish,
                "tokens": ["output": output, "reasoning": reasoning],
                "time": ["created": created, "completed": completed]]
            if let error { body["error"] = ["name": error] }
            f.message("a", body, at: 2000)
        }
        func speed() -> OpenCodeResponseSpeed? { try! reader.poll().first?.openCodeResponseSpeed }
        // Incomplete / missing / invalid provider data must never invent speed.
        f.message("a", ["role": "assistant", "parentID": "u", "tokens": ["output": 200]], at: 2000)
        precondition(speed() == nil)
        for invalid in [-1, 0] {
            response(invalid, reasoning: 0)
            precondition(speed() == nil)
        }
        response(created: 6000, completed: 6000)
        precondition(speed() == nil)
        response(created: 7000)
        precondition(speed() == nil)
        response("NaN")
        precondition(speed() == nil)
        response(finish: "tool-calls")
        precondition(speed() == nil)
        response(error: "APIError")
        precondition(speed() == nil)
        response()
        let measured = speed()!
        precondition(measured.tokens == 200 && measured.seconds == 4 && measured.tokensPerSecond == 50)
        precondition(speed() == measured && reader.metrics.cacheHit && reader.metrics.queries == 1)
        // A new in-progress response retains the previous completed measurement.
        f.message("v", ["role": "user"], at: 7000)
        f.message("b", ["role": "assistant", "parentID": "v", "tokens": ["output": 0]], at: 8000)
        precondition(speed() == measured)
        f.message("b", ["role": "assistant", "parentID": "v", "finish": "stop",
            "tokens": ["output": 300], "time": ["created": 8000, "completed": 11000]], at: 8000)
        precondition(speed()?.tokensPerSecond == 100)
        // The bounded recent window can evict old measurements during tool work.
        for i in 0..<10 {
            f.message("tool\(i)", ["role": "assistant", "parentID": "v", "finish": "tool-calls",
                "tokens": ["output": 50], "time": ["created": 12000 + i, "completed": 13000 + i]], at: Int64(12000 + i))
        }
        precondition(speed()?.tokensPerSecond == 100)
        try FileManager.default.removeItem(at: f.url)
        let missing = try reader.poll()
        precondition(missing.isEmpty)
        print("PASS: OpenCode response throughput, reasoning, invalid usage/timing, tool exclusion, streaming retention and cache")
    }

    static func performance() throws {
        let f = try Fixture()
        let now = Date()
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        f.exec("BEGIN")
        for i in 0..<10_000 { f.session(String(format: "s%05d", i), at: millis - Int64(i)) }
        // 100,000 historical messages in one retained session: the indexed
        // recent-message query must not grow with this history on each poll.
        for i in 0..<100_000 {
            autoreleasepool {
                let id = String(format: "history%06d", i)
                f.message(id, ["role": "assistant", "parentID": "old", "finish": "stop", "time": ["completed": i]],
                          session: "s00000", at: Int64(i))
                f.part(id, ["type": "text", "text": "历史回答"], message: id, session: "s00000", at: Int64(i))
            }
        }
        for i in 0..<32 {
            let id = String(format: "s%05d", i)
            f.message("u" + id, ["role": "user"], session: id, at: millis)
            for m in 0..<7 {
                let message = "a\(m)" + id
                f.message(message, ["role": "assistant", "parentID": "u" + id, "finish": "tool-calls"], session: id, at: millis + Int64(m + 1))
                for p in 0..<4 { f.part("p\(p)" + message, ["type": "reasoning", "text": "可见思考"], message: message, session: id, at: millis + 10) }
            }
        }
        f.exec("COMMIT")
        let reader = OpenCodeReader(url: f.url)
        func measure(_ label: String, at date: Date) throws {
            let start = ProcessInfo.processInfo.systemUptime
            let values = try reader.poll(now: date)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let metrics = reader.metrics
            precondition(values.count == 32 && metrics.rows < 1400 && metrics.queries <= 325)
            precondition(metrics.fullScanSteps <= (metrics.discovered ? 10_032 : 0))
            precondition(metrics.sortOperations <= (metrics.discovered ? 1 : 0))
            print(String(format: "OpenCode %@: %.3f ms, queries=%d rows=%d decodedParts=%d fullScanSteps=%d sorts=%d", label, elapsed,
                         metrics.queries, metrics.rows, metrics.decodedParts, metrics.fullScanSteps, metrics.sortOperations))
        }
        try measure("cold (10000 sessions / 100256 messages / 100896 parts)", at: now)
        try measure("idle", at: now.addingTimeInterval(0.7))
        precondition(reader.metrics.cacheHit && reader.metrics.queries == 1)
        f.part("p3a6s00000", ["type": "reasoning", "text": "增量更新"], message: "a6s00000", session: "s00000", at: millis + 20)
        try measure("one changed part", at: now.addingTimeInterval(1.4))
        precondition(reader.metrics.decodedParts == 1)
        try measure("metadata rediscovery", at: now.addingTimeInterval(9))
        precondition(reader.metrics.decodedParts == 0)
        // Real data remains read-only; report counts/timing without source text.
        if let path = ProcessInfo.processInfo.environment["OPENCODE_CHECK_DATABASE"] {
            let real = OpenCodeReader(url: URL(fileURLWithPath: path))
            for label in ["cold", "warm"] {
                let start = ProcessInfo.processInfo.systemUptime
                let values = try real.poll()
                let measured = values.compactMap(\.openCodeResponseSpeed)
                print("OpenCode real measured sessions=\(measured.count); sample tps=\(measured.first?.tokensPerSecond ?? 0)")
                print(String(format: "OpenCode real %@: %.3f ms, sessions=%d queries=%d rows=%d decodedParts=%d", label,
                    (ProcessInfo.processInfo.systemUptime - start) * 1000, values.count,
                    real.metrics.queries, real.metrics.rows, real.metrics.decodedParts))
            }
        }
    }
}
