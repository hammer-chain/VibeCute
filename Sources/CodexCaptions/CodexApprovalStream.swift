import Foundation
import Darwin
#if canImport(CaptionCore)
import CaptionCore
#endif

/// One event-driven connection, at most 16 already monitored chats. Retains only
/// requests and pending file details, never the transcript. No idle polling.
final class CodexApprovalStream {
    private let queue = DispatchQueue(label: "captions.codex.approvals", qos: .utility)
    private let path: String
    private let onChange: ([CodexApproval]) -> Void
    private var requested: [String] = [] // main thread
    private var targets = Set<String>() // remaining properties live on queue
    private var followed = Set<String>()
    private var connection: CodexQuestionConnection?
    private var clientID = ""
    private var source: DispatchSourceRead?
    private var retry: DispatchWorkItem?
    private var retryDelay: Double = 5
    private var buffer = Data()
    private var stores: [String: CodexApprovalProjection] = [:]
    private var lastResnapshot: [String: TimeInterval] = [:]
    private var published: [CodexApproval] = []
    init(path: String, onChange: @escaping ([CodexApproval]) -> Void) { self.path = path; self.onChange = onChange }
    func watch(_ threadIDs: [String]) {
        let bounded = Array(Set(threadIDs.prefix(16))).sorted()
        guard bounded != requested else { return }
        requested = bounded
        queue.async { self.targets = Set(bounded); self.reconcile() }
    }
    private func reconcile() {
        if targets.isEmpty { disconnect(reconnecting: false); return }
        if connection == nil {
            guard retry == nil else { return }
            do {
                let socket = try CodexQuestionConnection(path: path)
                clientID = try socket.initialize(); connection = socket
                let reader = DispatchSource.makeReadSource(fileDescriptor: socket.fd, queue: queue)
                reader.setEventHandler { [weak self] in self?.readAvailable() }
                reader.setCancelHandler { withExtendedLifetime(socket) {} }
                source = reader; reader.resume()
            } catch { disconnect(reconnecting: true); return }
        }
        guard let socket = connection else { return }
        do {
            socket.deadline = ProcessInfo.processInfo.systemUptime + 8
            for id in followed.subtracting(targets) {
                try socket.follow(id, clientID: clientID, following: false); stores.removeValue(forKey: id); lastResnapshot.removeValue(forKey: id)
            }
            for id in targets.subtracting(followed) { try socket.follow(id, clientID: clientID, following: true) }
            followed = targets; publish()
        } catch { disconnect(reconnecting: true) }
    }
    private func disconnect(reconnecting: Bool) {
        retry?.cancel(); retry = nil
        source?.cancel(); source = nil
        // The cancel handler retains the descriptor until the source stops.
        connection = nil; followed = []; stores = [:]; lastResnapshot = [:]; buffer.removeAll(keepingCapacity: false); publish()
        guard reconnecting, !targets.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.retry = nil; self?.reconcile() }
        retry = work; queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(60, retryDelay * 2)
    }
    private func readAvailable() {
        guard let socket = connection else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Bound each callback so target changes and disconnects cannot starve.
        do {
            for _ in 0..<64 {
                let count = Darwin.read(socket.fd, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
                guard count > 0 else { throw QuestionReplyError.unavailable }
                buffer.append(contentsOf: bytes.prefix(count))
                while buffer.count >= 4 {
                    let size = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                    guard size > 0, size <= 256 * 1024 * 1024 else { throw QuestionReplyError.protocolChanged }
                    if size > 16 * 1024 * 1024 {
                        // Large initial snapshots contain image/tool history.
                        // Scan in chunks, retaining requests and bounded file-change details.
                        let prefix = Data(buffer.dropFirst(4)); buffer.removeAll(keepingCapacity: false)
                        var offset = 0
                        socket.deadline = ProcessInfo.processInfo.systemUptime + 30
                        let row = try CodexReplySnapshot(length: size, approvalsOnly: true) { count in
                            let retained = min(count, prefix.count - offset)
                            var data = Data(prefix.dropFirst(offset).prefix(retained)); offset += retained
                            if retained < count { data.append(try socket.read(count - retained)) }
                            return data
                        }.decode()
                        try accept(row)
                        publish()
                        return
                    }
                    guard buffer.count >= size + 4 else { break }
                    let data = Data(buffer.dropFirst(4).prefix(size)); buffer.removeFirst(size + 4)
                    guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuestionReplyError.protocolChanged }
                    try accept(row)
                }
            }
            publish()
        } catch { disconnect(reconnecting: true) }
    }
    private func accept(_ row: [String: Any]) throws {
        if row["method"] as? String == "client-status-changed",
           let values = row["params"] as? [String: Any], values["status"] as? String == "disconnected",
           let owner = values["clientId"] as? String {
            for id in stores.keys where stores[id]?.owner == owner { stores.removeValue(forKey: id); try resnapshot(id) }
            return
        }
        guard row["type"] as? String == "broadcast", row["method"] as? String == "thread-stream-state-changed",
              let params = row["params"] as? [String: Any], params["hostId"] as? String == "local",
              let id = params["conversationId"] as? String, followed.contains(id),
              let change = params["change"] as? [String: Any], let owner = row["sourceClientId"] as? String else { return }
        if let targets = params["targetClientIds"] as? [String], !targets.contains(clientID) { return }
        var projection = stores[id] ?? CodexApprovalProjection(threadID: id)
        let outcome = projection.accept(change, owner: owner)
        stores[id] = projection
        if outcome == .resnapshot { stores.removeValue(forKey: id); try resnapshot(id) }
        else if outcome == .accepted { retryDelay = 5 }
    }
    private func resnapshot(_ id: String) throws {
        guard let socket = connection else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastResnapshot[id] ?? -.infinity) >= 2 else { throw QuestionReplyError.protocolChanged }
        lastResnapshot[id] = now
        socket.deadline = ProcessInfo.processInfo.systemUptime + 8
        try socket.follow(id, clientID: clientID, following: false)
        try socket.follow(id, clientID: clientID, following: true)
    }
    private func publish() {
        let result = stores.values.flatMap(\.approvals).sorted { $0.key < $1.key }
        guard result != published else { return }; published = result
        DispatchQueue.main.async { [onChange] in onChange(result) }
    }
}

/// Applies only the requests subtree of Immer patches. Revisions from unrelated
/// text patches still advance, without replaying or retaining transcript data.
struct CodexApprovalProjection {
    enum Outcome { case accepted, ignored, resnapshot }
    let threadID: String
    var owner = ""
    private var revision: Int?
    private var rows: [[String: Any]] = []
    private var fileItems: [[String: Any]] = []
    private(set) var approvals: [CodexApproval] = []
    private(set) var projectionCount = 0
    private(set) var patchCount = 0
    init(threadID: String) { self.threadID = threadID }
    mutating func accept(_ change: [String: Any], owner: String) -> Outcome {
        guard let next = change["revision"] as? Int else { return .resnapshot }
        if change["type"] as? String == "snapshot" {
            guard let state = change["conversationState"] as? [String: Any], state["id"] as? String == threadID,
                  let pending = state["requests"] as? [[String: Any]], pending.count <= 128,
                  let data = CodexApproval.json(pending), data.count <= 512 * 1024 else { return .resnapshot }
            self.owner = owner; revision = next; rows = pending
            fileItems = Array(pending.lazy.compactMap { row -> [String: Any]? in
                guard row["method"] as? String == "item/fileChange/requestApproval", let p = row["params"] as? [String: Any],
                      let id = p["itemId"] as? String, let turn = p["turnId"] as? String,
                      let item = CodexApproval.fileItem(id: id, turnID: turn, state: state),
                      let data = CodexApproval.json(item), data.count <= 32_768 else { return nil }
                return item
            }.prefix(8))
            project(); return .accepted
        }
        guard change["type"] as? String == "patches", self.owner == owner,
              let base = change["baseRevision"] as? Int, base == revision,
              let patches = change["patches"] as? [[String: Any]], patches.count <= 4096 else { return .resnapshot }
        var modified: Any = rows, dirty = false
        for patch in patches {
            guard let path = patch["path"] as? [Any] else { return .resnapshot }
            guard path.first as? String == "requests" else { continue }
            guard let op = patch["op"] as? String,
                  let result = Self.apply(modified, path: Array(path.dropFirst()), op: op, value: patch["value"]) else { return .resnapshot }
            modified = result; dirty = true; patchCount += 1
        }
        revision = next
        if dirty {
            guard let pending = modified as? [[String: Any]], pending.count <= 128,
                  let data = CodexApproval.json(pending), data.count <= 512 * 1024 else { return .resnapshot }
            rows = pending; project()
            // A new file approval needs one fresh snapshot to display its diff.
            if rows.contains(where: { row in
                guard row["method"] as? String == "item/fileChange/requestApproval", let p = row["params"] as? [String: Any] else { return false }
                return !fileItems.contains { $0["id"] as? String == p["itemId"] as? String }
            }) { return .resnapshot }
        }
        return .accepted
    }
    private mutating func project() {
        projectionCount += 1
        let id = threadID, files = fileItems
        approvals = Array(rows.lazy.compactMap { CodexApproval.parse(threadID: id, row: $0,
            state: ["turns": [["items": files]]]) }.prefix(8))
        let pendingIDs = Set(rows.compactMap { ($0["params"] as? [String: Any])?["itemId"] as? String })
        fileItems.removeAll { !pendingIDs.contains($0["id"] as? String ?? "") }
    }
    static func apply(_ root: Any, path: [Any], op: String, value: Any?) -> Any? {
        guard ["add", "replace", "remove"].contains(op), path.count <= 12 else { return nil }
        guard let key = path.first else { return op == "remove" ? nil : value }
        if var array = root as? [Any], let index = key as? Int {
            guard index >= 0, index <= array.count else { return nil }
            if path.count == 1 {
                if op == "remove" { guard index < array.count else { return nil }; array.remove(at: index) }
                else if let value {
                    if op == "add" { array.insert(value, at: index) }
                    else { guard index < array.count else { return nil }; array[index] = value }
                } else { return nil }
            } else {
                guard index < array.count, let updated = apply(array[index], path: Array(path.dropFirst()), op: op, value: value) else { return nil }
                array[index] = updated
            }
            return array
        }
        if var map = root as? [String: Any], let key = key as? String {
            if path.count == 1 {
                if op == "remove" { guard map.removeValue(forKey: key) != nil else { return nil } }
                else if let value { map[key] = value } else { return nil }
            } else {
                guard let old = map[key], let updated = apply(old, path: Array(path.dropFirst()), op: op, value: value) else { return nil }
                map[key] = updated
            }
            return map
        }
        return nil
    }
}
