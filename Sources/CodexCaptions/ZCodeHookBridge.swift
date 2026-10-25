import AppKit
import CaptionCore
import Darwin
import Foundation

/// Receives only live PermissionRequest hooks. A closed socket leaves the native
/// zcode prompt in charge; no database rows are used as actionable requests.
final class ZCodeHookBridge {
    struct Item {
        let sessionID: String
        let request: UserQuestionRequest
    }
    private struct Pending {
        let item: Item
        let fd: Int32
        let source: DispatchSourceRead
        let input: [String: Any]
    }
    var onChange: (() -> Void)?
    private(set) var items: [Item] = []
    private var pending: [String: Pending] = [:]
    private let queue = DispatchQueue(label: "vibecute.zcode.hooks", qos: .utility)
    private var listener: Int32 = -1
    private var listening = false
    private(set) var socketPath: String

    init(socketPath: String = "/tmp/vibecute-zcode-\(getuid()).sock") {
        self.socketPath = socketPath
    }

    func start() {
        guard !listening else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                for (index, byte) in bytes.enumerated() { $0[index] = byte }
            }
        }
        // A live owner must never be displaced. A dead socket can be removed.
        if FileManager.default.fileExists(atPath: socketPath) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            close(probe)
            if connected { close(fd); return }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: socketPath),
                  attrs[.type] as? FileAttributeType == .typeSocket,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { close(fd); return }
            _ = unlink(socketPath)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(fd, 16) == 0 else { close(fd); return }
        _ = chmod(socketPath, 0o600)
        listener = fd; listening = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while self.listening {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                self.queue.async { [weak self] in
                    if let self { self.receive(client) } else { _ = close(client) }
                }
            }
        }
    }

    func stop() {
        guard listening else { return }
        listening = false
        shutdown(listener, SHUT_RDWR); close(listener); listener = -1
        _ = unlink(socketPath)
        for key in Array(pending.keys) { discard(key) }
    }

    private func receive(_ fd: Int32) {
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { close(fd); return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 65_536 {
            let count = read(fd, &byte, 1)
            if count != 1 { close(fd); return }
            if byte == 10 { break }
            bytes.append(byte)
        }
        guard bytes.count < 65_536,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { close(fd); return }
        DispatchQueue.main.async { [weak self] in
            if let self { self.register(fd: fd, input: object) } else { _ = close(fd) }
        }
    }

    private func register(fd: Int32, input: [String: Any]) {
        guard listening,
              input["hook_event_name"] as? String == "PermissionRequest",
              let session = input["session_id"] as? String, session.hasPrefix("session_"), session.count <= 128,
              let call = input["tool_use_id"] as? String, !call.isEmpty, call.count <= 128,
              let tool = input["tool_name"] as? String, !tool.isEmpty, tool.count <= 128,
              let raw = input["tool_input"] as? [String: Any] else { close(fd); return }
        let id = session + ":" + call
        guard pending[id] == nil, pending.count < 32 else { close(fd); return }
        let date = Date()
        let question: UserQuestionRequest?
        if tool.lowercased() == "askuserquestion" {
            guard let rows = raw["questions"] as? [[String: Any]], (1...4).contains(rows.count) else { close(fd); return }
            let normalized = rows.enumerated().map { index, row -> [String: Any] in
                ["id": "\(id):\(index)", "question": row["question"] ?? "", "options": row["options"] ?? [],
                 "multiSelect": row["multiSelect"] ?? false]
            }
            question = UserQuestionRequest.parse(id: id, turnID: input["turn_id"] as? String,
                asynchronous: false, questions: normalized, date: date)
        } else {
            let reason = (input["reason"] as? String ?? "").prefix(4_000)
            let detail = Self.preview(tool: tool, input: raw)
            let title = "权限申请 · \(tool)"
            question = UserQuestionRequest.parse(id: id, turnID: input["turn_id"] as? String,
                asynchronous: false, questions: [["id": id, "question": "\(title)\n\(reason)\n\(detail)",
                    "options": [["label": "允许本次", "description": "仅批准当前工具调用。"],
                                ["label": "拒绝", "description": "拒绝当前工具调用。"]]]], date: date)
        }
        guard var request = question else { close(fd); return }
        request.externalZCode = true
        if tool.lowercased() != "askuserquestion" {
            request.approval = true
            request.approvalContent = ApprovalContent(title: "权限申请 · \(tool)",
                reason: String((input["reason"] as? String ?? "").prefix(4_000)),
                details: Self.preview(tool: tool, input: raw))
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var extra: UInt8 = 0
            if read(fd, &extra, 1) <= 0 {
                DispatchQueue.main.async { [weak self] in self?.discard(id) }
            }
        }
        source.resume()
        let item = Item(sessionID: session, request: request)
        pending[id] = Pending(item: item, fd: fd, source: source, input: raw)
        items.append(item); onChange?()
    }

    private static func preview(tool: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "filePath", "path", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return String(value.prefix(12_000)) }
        }
        return "工具：" + tool + "。请在 zcode 查看完整参数。"
    }

    func submit(sessionID: String, request: UserQuestionRequest, answers: [String: String],
                completion: @escaping (Result<Void, Error>) -> Void) {
        guard let record = pending[request.id], record.item.sessionID == sessionID,
              record.item.request == request else { completion(.failure(QuestionReplyError.stale)); return }
        let decision: [String: Any]
        if request.approval {
            guard let answer = answers[request.questions[0].id], ["允许本次", "拒绝"].contains(answer) else {
                completion(.failure(QuestionReplyError.invalidAnswer)); return
            }
            decision = ["behavior": answer == "允许本次" ? "allow" : "deny"]
        } else {
            var values: [String: String] = [:]
            for question in request.questions {
                guard let answer = answers[question.id] else { completion(.failure(QuestionReplyError.invalidAnswer)); return }
                if question.multiSelect {
                    guard let array = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String],
                          !array.isEmpty, array.allSatisfy(question.options.contains) else {
                        completion(.failure(QuestionReplyError.invalidAnswer)); return
                    }
                    values[question.title] = array.joined(separator: ", ")
                } else {
                    guard question.options.contains(answer) else { completion(.failure(QuestionReplyError.invalidAnswer)); return }
                    values[question.title] = answer
                }
            }
            var modified = record.input; modified["answers"] = values
            decision = ["behavior": "allow", "updatedInput": modified]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: output), data.count < 32_768 else {
            completion(.failure(QuestionReplyError.protocolChanged)); return
        }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) { setsockopt(record.fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
        let written = data.withUnsafeBytes { pointer in write(record.fd, pointer.baseAddress!, data.count) }
        if written == data.count { discard(request.id); completion(.success(())) }
        else { discard(request.id); completion(.failure(QuestionReplyError.uncertain)) }
    }

    func handoff(_ id: String) { discard(id) }

    private func discard(_ id: String) {
        guard let record = pending.removeValue(forKey: id) else { return }
        record.source.cancel(); close(record.fd)
        items.removeAll { $0.request.id == id }; onChange?()
    }
}
