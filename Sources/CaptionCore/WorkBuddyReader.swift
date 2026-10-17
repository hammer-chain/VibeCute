import Foundation
import CSQLite

/// A read-only SQLite task shortlist plus bounded incremental parent transcripts.
/// Confined to the monitor queue. No IPC, hooks, source writes or model calls.
public final class WorkBuddyReader {
    public static let sessionLimit = 32
    public struct Metrics {
        public var queries = 0, rows = 0, fullScanSteps = 0, sortOperations = 0
        public var directoryEntries = 0, statCalls = 0, logReads = 0, bytesRead = 0, decodedLines = 0
        public var discovered = false
    }
    public private(set) var metrics = Metrics()
    public let root: URL
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var inode: UInt64?
    private var version: String?
    private var lastDiscovery = Date.distantPast
    private var metadata: [String: [String]] = [:]
    private var baseIDs: [String] = []
    private var records: [String: Record] = [:]
    private var lastPinned: String?
    private final class Record {
        var tail: LogTail
        let parser = WorkBuddyEventParser()
        var snapshot: SessionSnapshot
        var fingerprint = ""
        var fileSize: UInt64?
        var body: Caption?
        var bodyUntil = Date.distantPast
        func resetBody() { body = nil; bodyUntil = .distantPast }
        init(url: URL, id: String) {
            tail = LogTail(url: url); snapshot = SessionSnapshot(path: url.path, id: id)
            snapshot.source = .workbuddy
        }
    }
    public init(root: URL) { self.root = root.standardizedFileURL }
    deinit { close() }
    private func close() {
        statements.values.forEach { sqlite3_finalize($0) }; statements.removeAll()
        if let db { sqlite3_close(db) }; db = nil
        inode = nil; version = nil; lastDiscovery = .distantPast
        metadata.removeAll(); baseIDs.removeAll(); records.removeAll(); lastPinned = nil
    }
    private func failure() -> NSError {
        NSError(domain: "WorkBuddyReader", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "无法读取 WorkBuddy 本地会话，请检查数据目录、权限或数据库格式。"])
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
        for (index, value) in arguments.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw failure() }
        }
        metrics.queries += 1
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            metrics.rows += 1
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
        }
    }
    private static let selection = """
        SELECT id,cwd,substr(COALESCE(NULLIF(custom_title,''),title,''),1,200),status,
          MAX(COALESCE(last_activity_at,0),updated_at,created_at),COALESCE(project_id,'')
        FROM sessions WHERE transport='local' AND deleted_at IS NULL
        """
    private func discoverPaths(ids: Set<String>) throws -> [String: URL] {
        let manager = FileManager.default
        let folder = root.appendingPathComponent("projects")
        guard manager.fileExists(atPath: folder.path) else { return [:] }
        var result: [String: URL] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for project in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) {
            metrics.directoryEntries += 1
            let attributes = try project.resourceValues(forKeys: Set(keys))
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            for file in try manager.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                metrics.directoryEntries += 1
                let id = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "jsonl", ids.contains(id) else { continue }
                let attributes = try file.resourceValues(forKeys: Set(keys))
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
                // Duplicate identities are ambiguous, never pick another project's body.
                if result[id] != nil { throw failure() }
                result[id] = file
            }
        }
        return result
    }
    public func poll(pinned: String? = nil, now: Date = Date()) throws -> [SessionSnapshot] {
        metrics = Metrics()
        let url = root.appendingPathComponent("workbuddy.db")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { close(); return [] }
        let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if db != nil && currentInode != inode { close() }
        if db == nil {
            var connection: OpaquePointer?
            guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let connection { sqlite3_close(connection) }; throw failure()
            }
            db = connection; inode = currentInode; sqlite3_busy_timeout(connection, 20)
        }
        do {
            let currentVersion = try query("PRAGMA data_version").first?.first ?? ""
            let discover = now.timeIntervalSince(lastDiscovery) >= 8
            let pinChanged = pinned != lastPinned
            if discover {
                let rows = try query(Self.selection + " ORDER BY MAX(COALESCE(last_activity_at,0),updated_at,created_at) DESC,id DESC LIMIT 32")
                baseIDs = rows.map { $0[0] }
                metadata = Dictionary(uniqueKeysWithValues: rows.map { ($0[0], $0) })
                metrics.discovered = true
            } else if currentVersion != version {
                // Fixed statement count and PK lookups, not a table sort per update.
                var refreshed: [String: [String]] = [:]
                for id in metadata.keys {
                    if let row = try query(Self.selection + " AND id=?", [id]).first { refreshed[id] = row }
                }
                metadata = refreshed
            }
            if let pinned, pinned.hasPrefix(root.appendingPathComponent("projects").path + "/") {
                let id = URL(fileURLWithPath: pinned).deletingPathExtension().lastPathComponent
                if metadata[id] == nil, let row = try query(Self.selection + " AND id=?", [id]).first { metadata[id] = row }
            }
            let retained = Set(baseIDs).union(pinned.map { [URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent] } ?? [])
            metadata = metadata.filter { retained.contains($0.key) }
            if discover || pinChanged {
                let paths = try discoverPaths(ids: Set(metadata.keys))
                records = records.filter { paths[$0.key]?.path == $0.value.tail.url.path && metadata[$0.key] != nil }
                for (id, path) in paths where records[id] == nil { records[id] = Record(url: path, id: id) }
            }
            records = records.filter { metadata[$0.key] != nil }
            for (id, record) in records {
                autoreleasepool {
                    guard let row = metadata[id] else { return }
                    if !record.snapshot.project.isEmpty && record.snapshot.project != row[1] {
                        record.snapshot.resetActivity(); record.parser.reset()
                        record.resetBody()
                        record.tail = LogTail(url: record.tail.url); record.fingerprint = ""
                    }
                    let date = Date(timeIntervalSince1970: (Double(row[4]) ?? 0) / 1000)
                    let status = row[3].lowercased()
                    if ["working", "planning", "running", "preparing", "connecting"].contains(status),
                       let finished = record.snapshot.finishedAt, date > finished {
                        record.snapshot.resetActivity(); record.parser.reset()
                        record.resetBody()
                    }
                    metrics.statCalls += 1
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: record.tail.url.path) else {
                        record.snapshot.readable = false; return
                    }
                    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let fingerprint = "\(attributes[.systemFileNumber] ?? ""):\(attributes[.size] ?? ""):\(modified)"
                    let changed = fingerprint != record.fingerprint
                    if changed || record.tail.hasUnreadBytes {
                        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                        // A same-inode, same-length rewrite leaves an ordinary tail at EOF.
                        // Invalidate its cursor as well as the public-text cache.
                        if changed, let previous = record.fileSize, size <= previous {
                            record.tail = LogTail(url: record.tail.url)
                            record.snapshot.resetActivity(); record.parser.reset()
                            record.resetBody()
                        }
                        let lines: [Data]
                        do { lines = try record.tail.read(maxInitialBytes: 512_000) }
                        catch { record.snapshot.readable = false; return }
                        metrics.logReads += 1; metrics.bytesRead += record.tail.lastReadBytes
                        if record.tail.didReset { record.snapshot.resetActivity(); record.parser.reset(); record.resetBody() }
                        for line in lines {
                            metrics.decodedLines += 1
                            for event in record.parser.parse(line, sessionID: id, cwd: row[1]) {
                                record.snapshot.apply(event)
                                switch event {
                                case .started: record.resetBody()
                                case let .caption(caption) where caption.kind != .tool:
                                    record.body = caption
                                    // The CLI commonly persists reasoning and its following tool in one poll.
                                    // Preserve enough reading time for one page, including slow typewriter settings.
                                    record.bodyUntil = now.addingTimeInterval(min(9, max(4, Double(caption.text.prefix(38).count) / 5)))
                                default: break
                                }
                            }
                        }
                        record.fingerprint = fingerprint
                        record.fileSize = size
                    }
                    record.snapshot.readable = true; record.snapshot.project = row[1]; record.snapshot.title = row[2]
                    record.snapshot.projectID = row[5].isEmpty ? "" : "workbuddy:" + row[5]
                    record.snapshot.activity = max(record.snapshot.activity, date)
                    switch status {
                    case "completed", "failed", "error", "terminated", "cancelled", "canceled":
                        // Public output can be persisted after SQLite commits completion.
                        // Only a newer user request proves this is an old turn's terminal state.
                        if let request = record.parser.latestUserRequest, date < request { return }
                        if status == "completed", let answer = record.parser.lastAssistant {
                            record.snapshot.apply(.caption(Caption(text: answer.text, kind: .answer, date: answer.date)))
                            record.snapshot.caption = nil
                        }
                        record.snapshot.apply(.finished(date, outcome: status == "completed" ? .completed
                            : ["terminated", "cancelled", "canceled"].contains(status) ? .interrupted : .failed))
                    case "working", "planning", "running", "preparing", "connecting": record.snapshot.active = true
                    default: record.snapshot.active = false // Pending/unknown is not a successful completion.
                    }
                }
            }
            version = currentVersion; lastPinned = pinned
            if discover { lastDiscovery = now }
            return records.values.filter { $0.snapshot.readable }.map { record in
                var snapshot = record.snapshot
                if snapshot.answer == nil, let body = record.body,
                   (snapshot.active && now < record.bodyUntil
                    || metadata[snapshot.id]?[3].lowercased() == "pending" && body.kind == .progress) {
                    snapshot.caption = body
                }
                return snapshot
            }.sorted { $0.activity > $1.activity }
        } catch { close(); throw failure() }
    }
}
