import Foundation
import CaptionCore

final class SessionRecord {
    let tail: LogTail?
    let compressedTail: ZstdLogTail?
    let source: SessionSource
    let harness = HarnessEventParser()
    let claude = ClaudeEventParser()
    var snapshot: SessionSnapshot
    var isSubagent = false
    var parentSessionID: String?
    private var outcomeTracker: TaskOutcomeTracker
    private var codexMetadataKnown = false

    init(url: URL, source: SessionSource, notBefore: Date = Date()) {
        self.source = source
        outcomeTracker = TaskOutcomeTracker(notBefore: notBefore)
        tail = url.pathExtension == "zstd" ? nil : LogTail(url: url)
        compressedTail = url.pathExtension == "zstd" ? ZstdLogTail(url: url) : nil
        snapshot = SessionSnapshot(path: url.path)
        snapshot.source = source
        if source == .claude {
            snapshot.id = url.deletingPathExtension().lastPathComponent
            loadClaudeHeader(from: url)
        }
        loadCodexHeader(from: url)
    }

    private func applyClaudeMetadata(_ event: SessionEvent) {
        snapshot.apply(event)
        if case let .metadata(_, project) = event {
            let directory = URL(fileURLWithPath: project).standardizedFileURL
            snapshot.projectName = directory.lastPathComponent
            snapshot.projectID = "claude:" + directory.path
        }
    }

    private func loadClaudeHeader(from url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 262_144) else { return }
        for line in data.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            ClaudeEventParser.metadata(object).forEach(applyClaudeMetadata)
        }
    }

    private func classifyCodexMetadata(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, !id.isEmpty else { return }
        codexMetadataKnown = true
        let origin = payload["source"] as? [String: Any]
        isSubagent = origin?["subagent"] != nil
        parentSessionID = nil
        // Guardian/internal agents are excluded but never counted as delegated work.
        if let subagent = origin?["subagent"] as? [String: Any],
           let spawn = subagent["thread_spawn"] as? [String: Any] {
            parentSessionID = spawn["parent_thread_id"] as? String
        }
    }

    private func loadCodexHeader(from url: URL) {
        // Codex's bounded tail may start after the header.
        if source == .codex, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 262_144), let end = data.firstIndex(of: 10) {
                let line = Data(data[..<end])
                EventParser.parse(line).forEach { snapshot.apply($0) }
                classifyCodexMetadata(line)
            }
        }
    }

    func poll() throws -> [TaskOutcomeNotice] {
        var notices: [TaskOutcomeNotice] = []
        let lines: [Data]
        let reset: Bool
        if let compressedTail { lines = try compressedTail.read(); reset = compressedTail.didReset }
        else if let tail { lines = try tail.read(maxInitialBytes: source == .deepseek ? Int.max : 2_000_000); reset = tail.didReset }
        else { return [] }
        if reset {
            outcomeTracker.resetLog(at: Date())
            snapshot.resetActivity()
            if source == .codex {
                codexMetadataKnown = false; isSubagent = false; parentSessionID = nil
                loadCodexHeader(from: URL(fileURLWithPath: snapshot.path))
            }
            if source == .deepseek { harness.reset(); snapshot.id = ""; snapshot.title = "" }
            if source == .claude {
                claude.reset(); snapshot.title = ""; snapshot.projectName = ""; snapshot.projectID = ""
                snapshot.project = ""; snapshot.id = URL(fileURLWithPath: snapshot.path).deletingPathExtension().lastPathComponent
                loadClaudeHeader(from: URL(fileURLWithPath: snapshot.path))
            }
        }
        for line in lines {
            // A newly discovered file may still be empty or have a partial
            // header. Resolve its origin before any late-written child event.
            if source == .codex, !codexMetadataKnown { classifyCodexMetadata(line) }
            if isSubagent {
                // Only lifecycle metadata is needed for child status. Avoid
                // decoding child text into captions even temporarily.
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if source == .codex {
                    guard object["type"] as? String == "event_msg",
                          let payload = object["payload"] as? [String: Any],
                          ["task_started", "turn_started", "task_complete", "task_completed", "turn_complete", "turn_aborted"]
                            .contains(payload["type"] as? String ?? "") else { continue }
                } else {
                    guard ["session", "turn/start", "turn/end"].contains(object["type"] as? String ?? "") else { continue }
                }
            }
            let events: [SessionEvent]
            switch source {
            case .codex: events = EventParser.parse(line, includeResponseMetrics: true)
            case .deepseek: events = harness.parse(line)
            case .claude: events = claude.parse(line)
            case .doubao, .opencode, .zcode, .workbuddy: events = []
            }
            if source == .deepseek {
                isSubagent = harness.isSubagent; parentSessionID = harness.parentSessionID
            }
            for event in events {
                if isSubagent, case .caption = event { continue }
                if source == .codex, codexMetadataKnown, !isSubagent, let notice = outcomeTracker.observe(event) {
                    notices.append(notice)
                }
                if source == .claude { applyClaudeMetadata(event) }
                else { snapshot.apply(event) }
            }
        }
        if source == .deepseek { isSubagent = harness.isSubagent }
        snapshot.readable = true
        if snapshot.active, let attrs = try? FileManager.default.attributesOfItem(atPath: snapshot.path),
           let date = attrs[.modificationDate] as? Date { snapshot.activity = max(snapshot.activity, date) }
        return notices
    }
}

struct SessionOutcomeNotice: Sendable {
    let path: String
    let title: String
    let notice: TaskOutcomeNotice
}

/// Passive readers only: no API calls, resumed turns, repairs, or source configuration writes.
final class SessionMonitor {
    private let queue = DispatchQueue(label: "local.codex-captions.reader", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var records: [String: SessionRecord] = [:]
    private var lastScan = Date.distantPast
    private var pinned: String?
    private let titleIndex: SessionTitleIndex
    private let projectIndex: SessionProjectIndex
    private let roots: [(SessionSource, URL)]
    private let visibleReader: (() -> ([SessionSnapshot], String?))?
    private let openCode: OpenCodeReader?
    private var openCodeSnapshots: [SessionSnapshot] = []
    private let zcode: OpenCodeReader?
    private var zcodeSnapshots: [SessionSnapshot] = []
    private let workBuddy: WorkBuddyReader?
    private var scanErrors: [String] = []
    private let connectedAt = Date()
    var onChange: (([SessionSnapshot], String?) -> Void)?
    var onOutcomes: (([SessionOutcomeNotice]) -> Void)?

    init(root: URL, harnessRoot: URL?, claudeRoot: URL? = nil, openCodeRoot: URL? = nil, zcodeRoot: URL? = nil, workBuddyRoot: URL? = nil,
         enabledSources: Set<SessionSource> = Set(SessionSource.allCases),
         visibleReader: (() -> ([SessionSnapshot], String?))? = nil) {
        self.visibleReader = enabledSources.contains(.doubao) ? visibleReader : nil
        roots = ([ (SessionSource.codex, root) ] + (harnessRoot.map { [(SessionSource.deepseek, $0)] } ?? [])
            + (claudeRoot.map { [(SessionSource.claude, $0)] } ?? []))
            .filter { enabledSources.contains($0.0) }
        openCode = enabledSources.contains(.opencode) ? openCodeRoot.map {
            OpenCodeReader(url: $0.appendingPathComponent("opencode.db"))
        } : nil
        zcode = enabledSources.contains(.zcode) ? zcodeRoot.map {
            OpenCodeReader(url: $0.appendingPathComponent("cli/db/db.sqlite"), source: .zcode)
        } : nil
        workBuddy = enabledSources.contains(.workbuddy) ? workBuddyRoot.map { WorkBuddyReader(root: $0) } : nil
        titleIndex = SessionTitleIndex(url: root.deletingLastPathComponent().appendingPathComponent("session_index.jsonl"))
        projectIndex = SessionProjectIndex(url: root.deletingLastPathComponent().appendingPathComponent(".codex-global-state.json"))
    }

    func pin(_ path: String?) { queue.async { self.pinned = path; self.lastScan = .distantPast } }
    func start() {
        guard !roots.isEmpty || openCode != nil || zcode != nil || workBuddy != nil || visibleReader != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(700), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in autoreleasepool { self?.poll() } }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        if roots.contains(where: { $0.0 == .codex }) { titleIndex.refresh(); projectIndex.refresh() }
        if Date().timeIntervalSince(lastScan) > 8 { discover(); lastScan = Date() }
        var readErrors = false
        var outcomes: [SessionOutcomeNotice] = []
        for record in records.values {
            var notices: [TaskOutcomeNotice] = []
            do { notices = try record.poll() } catch { record.snapshot.readable = false; readErrors = true }
            if record.source == .codex {
                record.snapshot.title = titleIndex.title(for: record.snapshot.id)
                record.snapshot.projectName = projectIndex.name(for: record.snapshot.id)
                record.snapshot.projectID = projectIndex.id(for: record.snapshot.id) ?? ""
            }
            outcomes += notices.map { SessionOutcomeNotice(path: record.snapshot.path,
                title: record.snapshot.headerName, notice: $0) }
        }
        let now = Date()
        var databaseErrors: [String] = []
        if let openCode {
            do { openCodeSnapshots = try openCode.poll(pinned: pinned, now: now) }
            catch {
                openCodeSnapshots = []
                databaseErrors.append(error.localizedDescription)
            }
        }
        if let zcode {
            do { zcodeSnapshots = try zcode.poll(pinned: pinned, now: now) }
            catch {
                zcodeSnapshots = []
                databaseErrors.append(error.localizedDescription)
            }
        }
        let parents = records.values.filter { !$0.isSubagent && !$0.snapshot.id.isEmpty }
        for parent in parents {
            let children = records.values.filter {
                $0.isSubagent && $0.source == parent.source && $0.parentSessionID == parent.snapshot.id
            }
            let running = children.filter { $0.snapshot.readable && $0.snapshot.active
                && now.timeIntervalSince($0.snapshot.activity) < 3600 }
            parent.snapshot.runningSubagentCount = running.count
            parent.snapshot.subagentActivity = running.map { $0.snapshot.activity }.max() ?? .distantPast
            let allFinished = !children.isEmpty && children.allSatisfy {
                $0.snapshot.readable && !$0.snapshot.active && $0.snapshot.finishedAt != nil
            }
            parent.snapshot.subagentFinishedAt = allFinished
                ? children.compactMap { $0.snapshot.finishedAt }.max() ?? .distantPast : .distantPast
            if parent.snapshot.active {
                parent.snapshot.activity = max(parent.snapshot.activity, parent.snapshot.subagentActivity)
            }
        }
        // Child sessions must not displace the parent from the visible shortlist.
        let visible = visibleReader?() ?? ([], nil)
        var snapshots = SessionSource.allCases.flatMap { source in
            parents.filter { $0.source == source }.map(\.snapshot).sorted { $0.activity > $1.activity }.prefix(16)
        }
        if let pinned, !snapshots.contains(where: { $0.path == pinned }),
           let parent = parents.first(where: { $0.snapshot.path == pinned }) {
            snapshots.append(parent.snapshot)
        }
        snapshots += visible.0.prefix(1)
        snapshots += openCodeSnapshots.prefix(16)
        snapshots += zcodeSnapshots.prefix(16)
        if let workBuddy {
            do {
                let values = try workBuddy.poll(pinned: pinned, now: now)
                snapshots += values.prefix(16)
                if let pinned, !snapshots.contains(where: { $0.path == pinned }),
                   let value = values.first(where: { $0.path == pinned }) { snapshots.append(value) }
            } catch { databaseErrors.append(error.localizedDescription) }
        }
        // A pinned older OpenCode conversation must remain selectable.
        if let pinned, !snapshots.contains(where: { $0.path == pinned }),
           let snapshot = openCodeSnapshots.first(where: { $0.path == pinned }) { snapshots.append(snapshot) }
        if let pinned, !snapshots.contains(where: { $0.path == pinned }),
           let snapshot = zcodeSnapshots.first(where: { $0.path == pinned }) { snapshots.append(snapshot) }
        snapshots.sort { $0.activity > $1.activity }
        var errors = scanErrors
        errors += databaseErrors
        if let error = visible.1 { errors.append(error) }
        if readErrors { errors.append("部分会话暂时无法读取，请检查日志或会话目录。") }
        let error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        let orderedOutcomes = outcomes.sorted { $0.notice.date < $1.notice.date }
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(snapshots, error)
            if !orderedOutcomes.isEmpty { self?.onOutcomes?(orderedOutcomes) }
        }
    }

    private func discoveredFiles(_ candidates: [(URL, Date, SessionSource)], limit: Int) -> [(URL, Date, SessionSource)] {
        var recent = Array(candidates.sorted { $0.1 > $1.1 }.prefix(limit))
        // Also recover a saved pin on first connection, before records has it.
        if let pinned, !recent.contains(where: { $0.0.path == pinned }),
           let older = candidates.first(where: { $0.0.path == pinned }) { recent.append(older) }
        return recent
    }

    private func discover() {
        let manager = FileManager.default
        var files: [(URL, Date, SessionSource)] = []
        scanErrors = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for (source, root) in roots {
            // Harness is optional until installed or selected; its missing default must not block Codex.
            guard manager.fileExists(atPath: root.path) else {
                if source == .codex { scanErrors.append("找不到 Codex 会话目录，请在菜单中选择目录。") }
                continue
            }
            var scanError = false
            if source == .claude {
                // Only project-level parent transcripts. Never traverse
                // subagent trees, attachments, checkpoints or tool results.
                do {
                    var candidates: [(URL, Date, SessionSource)] = []
                    let projects = try manager.contentsOfDirectory(at: root,
                        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        do {
                            for url in try manager.contentsOfDirectory(at: project, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles]) {
                                guard url.pathExtension == "jsonl", !url.lastPathComponent.hasPrefix("agent-"),
                                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                                candidates.append((url, values.contentModificationDate ?? .distantPast, source))
                            }
                        } catch { scanError = true }
                    }
                    files += discoveredFiles(candidates, limit: 32)
                } catch { scanError = true }
                if scanError { scanErrors.append("部分 Claude Code 会话目录无法读取。") }
                continue
            }
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles], errorHandler: { _, _ in scanError = true; return true }) else {
                scanErrors.append("无法扫描 \(source.rawValue) 会话目录。"); continue
            }
            var candidates: [(URL, Date, SessionSource)] = []
            for case let url as URL in enumerator {
                let accepted = source == .codex
                    ? url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
                    : HarnessLogFormat.version(for: url) != nil
                guard accepted, let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                candidates.append((url, values.contentModificationDate ?? .distantPast, source))
            }
            if source == .deepseek {
                let preferred = Set(HarnessLogFormat.preferred(candidates.map { $0.0 }).map(\.path))
                candidates = candidates.filter { preferred.contains($0.0.path) }
            }
            // Keep a bounded child-status pool, while the UI still lists at
            // most sixteen parent conversations per source.
            files += discoveredFiles(candidates, limit: source == .codex ? 80 : 32)
            if scanError { scanErrors.append("部分 \(source.rawValue) 会话目录无法读取。") }
        }
        var retained = Set(files.map { $0.0.path })
        if let pinned, records[pinned] != nil { retained.insert(pinned) }
        records = records.filter { retained.contains($0.key) }
        for (url, _, source) in files where records[url.path] == nil {
            records[url.path] = SessionRecord(url: url, source: source, notBefore: connectedAt)
        }
    }
}
