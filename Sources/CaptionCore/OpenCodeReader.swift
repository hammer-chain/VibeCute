import Foundation
import CSQLite

/// A passive reader of OpenCode's local session/message/part projections.
/// One connection, confined to the caller's reader queue; never opens a writer or server.
public final class OpenCodeReader {
    public static let sessionLimit = 32
    public static let messageLimit = 8
    public static let partLimit = 64
    public struct Metrics {
        public var queries = 0
        public var rows = 0
        public var decodedParts = 0
        public var fullScanSteps = 0
        public var sortOperations = 0
        public var discovered = false
        public var cacheHit = false
    }
    public private(set) var metrics = Metrics()
    public let url: URL
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var inode: UInt64?
    private var dataVersion: String?
    private var lastDiscovery = Date.distantPast
    private var snapshots: [String: SessionSnapshot] = [:]
    private var discoveredIDs: [String] = []
    private var parts: [String: (body: String, caption: Caption?)] = [:]
    private var lastPinned: String?
    private var schemaVersion = ""
    private var hasV1 = false
    private var hasV2 = false

    public init(url: URL) { self.url = url }
    deinit { close() }

    private func close() {
        statements.values.forEach { sqlite3_finalize($0) }; statements.removeAll()
        if let db { sqlite3_close(db) }; db = nil
        schemaVersion = ""; hasV1 = false; hasV2 = false
        dataVersion = nil; inode = nil; lastDiscovery = .distantPast
        snapshots.removeAll(); parts.removeAll()
        discoveredIDs.removeAll(); lastPinned = nil
    }

    private func failure() -> NSError {
        // Do not expose SQL, source text or credentials in the settings panel.
        NSError(domain: "OpenCodeReader", code: Int(db.map(sqlite3_errcode) ?? SQLITE_CANTOPEN),
                userInfo: [NSLocalizedDescriptionKey: "无法读取 OpenCode 数据库，请检查目录、权限或数据库格式。"])
    }

    private func query(_ sql: String, _ arguments: [String] = []) throws -> [[String]] {
        guard let db else { throw failure() }
        let statement: OpaquePointer
        if let cached = statements[sql] { statement = cached }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
            statements[sql] = prepared; statement = prepared
        }
        defer {
            metrics.fullScanSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 1))
            metrics.sortOperations += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_SORT, 1))
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient) == SQLITE_OK else { throw failure() }
        }
        metrics.queries += 1
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            metrics.rows += 1
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }

    private static let messages = """
        SELECT id,time_created,time_updated,json_extract(data,'$.role'),
          COALESCE(json_extract(data,'$.parentID'),''),COALESCE(json_extract(data,'$.finish'),''),
          COALESCE(json_extract(data,'$.time.completed'),''),COALESCE(json_extract(data,'$.error.name'),''),
          COALESCE(json_extract(data,'$.tokens.output'),''),COALESCE(json_extract(data,'$.tokens.reasoning'),0),
          COALESCE(json_extract(data,'$.time.created'),'')
        FROM message WHERE session_id=? ORDER BY time_created DESC,id DESC LIMIT 8
        """
    // Project only the UI-visible fields. Tool outputs, prompts, signatures, files,
    // provider metadata and inline assets never enter Swift or its caption cache.
    private static let partRows = """
        SELECT id,time_updated,json_object(
          'type',json_extract(data,'$.type'),'text',substr(json_extract(data,'$.text'),-2000),
          'synthetic',json_extract(data,'$.synthetic'),'ignored',json_extract(data,'$.ignored'),
          'tool',json_extract(data,'$.tool'),'status',json_extract(data,'$.state.status'),
          'command',substr(json_extract(data,'$.state.input.command'),1,2000),
          'filePath',substr(json_extract(data,'$.state.input.filePath'),1,2000),
          'path',substr(json_extract(data,'$.state.input.path'),1,2000),
          'start',json_extract(data,'$.state.time.start'),'end',json_extract(data,'$.state.time.end'))
        FROM part WHERE message_id=? ORDER BY id DESC LIMIT 64
        """

    // Normalize both stores without copying history or exposing tool output.
    private var metadata: String {
        let columns = "s.id,s.directory,COALESCE(s.title,''),s.project_id,COALESCE(p.name,''),s.time_updated"
        var stores: [String] = []
        if hasV2 { stores.append("SELECT \(columns),2 AS generation,s.parent_id,s.time_archived FROM session_v2 s LEFT JOIN project p ON p.id=s.project_id") }
        if hasV1 { stores.append("SELECT \(columns),1 AS generation,s.parent_id,s.time_archived FROM session s LEFT JOIN project p ON p.id=s.project_id" + (hasV2 ? " WHERE NOT EXISTS (SELECT 1 FROM session_v2 v WHERE v.id=s.id)" : "")) }
        return "SELECT * FROM (" + stores.joined(separator: " UNION ALL ") + ") s"
    }

    private static let messagesV2 = """
        SELECT id,time_created,time_updated,type,seq,COALESCE(json_extract(data,'$.finish'),''),
          COALESCE(json_extract(data,'$.time.completed'),''),COALESCE(json_extract(data,'$.error.type'),''),
          COALESCE(json_extract(data,'$.tokens.output'),''),COALESCE(json_extract(data,'$.tokens.reasoning'),0),
          COALESCE(json_extract(data,'$.time.created'),'')
        FROM session_message WHERE session_id=? AND type IN ('user','assistant')
        ORDER BY seq DESC LIMIT 8
        """
    private static let partsV2 = """
        SELECT m.id || ':' || j.key,m.time_updated,json_object(
          'type',json_extract(j.value,'$.type'),'text',substr(json_extract(j.value,'$.text'),-2000),
          'tool',json_extract(j.value,'$.name'),'status',json_extract(j.value,'$.state.status'),
          'command',substr(json_extract(j.value,'$.state.input.command'),1,2000),
          'filePath',substr(json_extract(j.value,'$.state.input.filePath'),1,2000),
          'path',substr(json_extract(j.value,'$.state.input.path'),1,2000),
          'start',json_extract(j.value,'$.time.ran'),'end',json_extract(j.value,'$.time.completed'))
        FROM session_message m,json_each(m.data,'$.content') j WHERE m.id=?
        ORDER BY CAST(j.key AS INTEGER) DESC LIMIT 64
        """

    /// Poll at the existing 700 ms cadence. Idle polls execute only data_version.
    /// Discovery scans session metadata at most every eight seconds; history is
    /// always bounded by indexed recent-message and per-message part queries.
    public func poll(pinned: String? = nil, now: Date = Date()) throws -> [SessionSnapshot] {
        metrics = Metrics()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            close(); return [] // Optional until OpenCode is installed.
        }
        let currentInode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        if db != nil && inode != currentInode { close() }
        if db == nil {
            var connection: OpaquePointer?
            guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let connection { sqlite3_close(connection) }; throw failure()
            }
            db = connection; inode = currentInode
            sqlite3_busy_timeout(connection, 50)
        }
        let version = try query("PRAGMA data_version").first?.first ?? ""
        guard version != dataVersion || pinned != lastPinned || now.timeIntervalSince(lastDiscovery) >= 8 else {
            metrics.cacheHit = true
            return Array(snapshots.values).sorted { $0.activity > $1.activity }
        }
        let currentSchema = try query("PRAGMA schema_version").first?.first ?? ""
        if schemaVersion != currentSchema {
            let tables = Set(try query("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('session','message','part','session_v2','session_message')").compactMap { $0.first })
            hasV1 = ["session", "message", "part"].allSatisfy { tables.contains($0) }
            hasV2 = ["session_v2", "session_message"].allSatisfy { tables.contains($0) }
            guard hasV1 || hasV2 else { throw failure() }
            schemaVersion = currentSchema; dataVersion = nil; lastDiscovery = .distantPast
        }
        // A short read transaction ensures message completion and part updates
        // come from the same WAL snapshot. End it before returning to the timer.
        _ = try query("BEGIN")
        defer { _ = try? query("ROLLBACK") }
        var baseIDs = discoveredIDs
        if snapshots.isEmpty || now.timeIntervalSince(lastDiscovery) >= 8 {
            baseIDs = try query(metadata + " WHERE s.parent_id IS NULL AND s.time_archived IS NULL ORDER BY s.time_updated DESC,s.id DESC LIMIT 32")
                .map { $0[0] }
            metrics.discovered = true
        }
        var ids = baseIDs
        // Pinning can retain an older conversation, but never expose a child.
        if let pinned, pinned.hasPrefix(url.path + "#"),
           let id = pinned.split(separator: "#").last.map(String.init), !ids.contains(id) { ids.append(id) }
        if version == dataVersion && Set(ids) == Set(snapshots.keys) {
            discoveredIDs = baseIDs
            if metrics.discovered { lastDiscovery = now }
            lastPinned = pinned; metrics.cacheHit = true
            return Array(snapshots.values).sorted { $0.activity > $1.activity }
        }
        var next: [String: SessionSnapshot] = [:]
        var retainedParts = Set<String>()
        for id in ids {
            guard let row = try query(metadata + " WHERE s.id=? AND s.parent_id IS NULL AND s.time_archived IS NULL", [id]).first else { continue }
            var snapshot = SessionSnapshot(path: url.path + "#" + id, id: id, project: row[1], title: row[2],
                                           activity: Self.date(row[5]))
            snapshot.source = .opencode
            // Use authoritative project identity; 'global' is projectless.
            if row[3] != "global" { snapshot.projectID = row[3]; snapshot.projectName = row[4] }
            let v2 = row[6] == "2"
            let recent = try query(v2 ? Self.messagesV2 : Self.messages, [id]).reversed()
            // Keep the last measured response during streaming or a long tool
            // chain. Never treat a tool-call message's execution time as model
            // generation time; use completed non-tool responses only.
            snapshot.openCodeResponseSpeed = snapshots[id]?.openCodeResponseSpeed
            for message in recent where message[3] == "assistant" && message[7].isEmpty
                && ["stop", "length", "content-filter"].contains(message[5]) {
                if let speed = OpenCodeResponseSpeed.parse(output: message[8], reasoning: message[9],
                                                           created: message[10], completed: message[6]),
                   snapshot.openCodeResponseSpeed == nil || speed.recordedAt >= snapshot.openCodeResponseSpeed!.recordedAt {
                    snapshot.openCodeResponseSpeed = speed
                }
            }
            let latestUser = recent.last(where: { $0[3] == "user" })
            let v2User = v2 ? try query("SELECT id,time_created,seq FROM session_message WHERE session_id=? AND type='user' ORDER BY seq DESC LIMIT 1", [id]).first : nil
            let turnID = v2User?[0] ?? latestUser?[0] ?? recent.last(where: { $0[3] == "assistant" })?[4] ?? ""
            let assistants = recent.filter { $0[3] == "assistant" && (v2 ? (Int64($0[4]) ?? 0) > (Int64(v2User?[2] ?? "-1") ?? -1) : (turnID.isEmpty || $0[4] == turnID)) }
            if let start = v2User ?? latestUser ?? assistants.first { snapshot.apply(.started(Self.date(start[1]), turnID: turnID)) }
            for message in assistants {
                for part in try query(v2 ? Self.partsV2 : Self.partRows, [message[0]]).reversed() {
                    retainedParts.insert(part[0])
                    let value: Caption?
                    if let cached = parts[part[0]], cached.body == part[2] {
                        value = cached.caption
                    } else {
                        metrics.decodedParts += 1
                        value = Self.caption(part[2], date: Self.date(part[1]))
                    }
                    // Completion can reclassify streaming text as an answer.
                    let caption = value.map { Caption(text: $0.text,
                        kind: $0.kind == .progress && message[5] == "stop" ? .answer : $0.kind, date: $0.date) }
                    parts[part[0]] = (part[2], value)
                    if let caption { snapshot.apply(.caption(caption)) }
                }
            }
            if let latest = assistants.last {
                let error = latest[7]
                let terminal = !error.isEmpty || (!latest[6].isEmpty && !latest[5].isEmpty && latest[5] != "tool-calls" && latest[5] != "unknown")
                if terminal {
                    let outcome: TaskOutcome = ["MessageAbortedError", "aborted", "AbortError"].contains(error) ? .interrupted : error.isEmpty ? .completed : .failed
                    snapshot.apply(.finished(Self.date(latest[6].isEmpty ? latest[2] : latest[6]), outcome: outcome, turnID: turnID))
                }
            }
            next[id] = snapshot
        }
        parts = parts.filter { retainedParts.contains($0.key) }
        snapshots = next; discoveredIDs = baseIDs; dataVersion = version; lastPinned = pinned
        if metrics.discovered { lastDiscovery = now }
        return Array(next.values).sorted { $0.activity > $1.activity }
    }

    private static func date(_ milliseconds: String) -> Date {
        Double(milliseconds).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
    }

    private static func caption(_ body: String, date: Date) -> Caption? {
        guard let data = body.data(using: .utf8),
              let part = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let type = part["type"] as? String ?? ""
        var text = ""
        var kind: CaptionKind = .progress
        switch type {
        case "text", "reasoning":
            guard part["synthetic"] as? Int != 1, part["ignored"] as? Int != 1 else { return nil }
            text = part["text"] as? String ?? ""
            kind = type == "reasoning" ? .reasoning : .progress
        case "tool":
            guard let tool = part["tool"] as? String,
                  let status = part["status"] as? String, ["pending", "streaming", "running", "completed", "error"].contains(status) else { return nil }
            let prefix = status == "error" ? "调用失败" : status == "completed" ? "调用完成" : "正在调用"
            var detail = tool
            if ["bash", "shell"].contains(tool), let command = part["command"] as? String { detail = ToolCaption.command(command) }
            else if ["write", "edit", "read"].contains(tool), let path = (part["filePath"] as? String) ?? (part["path"] as? String) {
                detail += " · " + URL(fileURLWithPath: path).lastPathComponent
            }
            let start = part["start"] as? Double, end = part["end"] as? Double
            let duration = start.flatMap { start in end.map { " · \(max(0, Int(($0 - start) / 1000)))s" } } ?? ""
            text = prefix + duration + "：" + detail; kind = .tool
        default: return nil
        }
        let clean = CaptionText.clean(text)
        return clean.isEmpty ? nil : Caption(text: clean, kind: kind, date: date)
    }
}
