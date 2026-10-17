import Foundation
import Darwin
#if canImport(CaptionCore)
import CaptionCore
#endif

/// Existing desktop ownership is essential: a separate app-server cannot answer
/// another client's pending request. This private IPC adapter is deliberately
/// isolated and fails closed on changed schemas. No idle connections or polling.
final class CodexQuestionReply {
    private let queue = DispatchQueue(label: "captions.codex.question-reply", qos: .userInitiated)
    private let socketPath: String
    private var busy = false // main-thread admission bounds the work queue to one
    init(socketPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/ipc/ipc.sock").path) { self.socketPath = socketPath }

    func submit(threadID: String, request: UserQuestionRequest, answers: [String: String],
                completion: @escaping (Result<Void, Error>) -> Void) {
        guard !busy else { completion(.failure(QuestionReplyError.unavailable)); return }
        busy = true
        queue.async {
            let result: Result<Void, Error>
            do {
                try self.send(threadID: threadID, request: request, answers: answers)
                result = .success(())
            } catch { result = .failure(error) }
            DispatchQueue.main.async { self.busy = false; completion(result) }
        }
    }

    func submitApproval(_ approval: CodexApproval, choice: String,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard !busy else { completion(.failure(QuestionReplyError.unavailable)); return }
        guard let index = approval.question.questions[0].options.firstIndex(of: choice),
              index < approval.responses.count else { completion(.failure(QuestionReplyError.invalidAnswer)); return }
        busy = true
        queue.async {
            let result: Result<Void, Error>
            do {
                let connection = try CodexQuestionConnection(path: self.socketPath)
                let client = try connection.initialize()
                try connection.follow(approval.threadID, clientID: client, following: true)
                defer { try? connection.follow(approval.threadID, clientID: client, following: false) }
                let (state, owner) = try connection.snapshot(approval.threadID)
                guard (state["requests"] as? [[String: Any]] ?? []).contains(where: { row in
                    guard let current = CodexApproval.parse(threadID: approval.threadID, row: row, state: state) else { return false }
                    return current == approval
                }) else { throw QuestionReplyError.stale }
                let payload = try JSONSerialization.jsonObject(with: approval.responses[index], options: [.fragmentsAllowed])
                let requestID = try JSONSerialization.jsonObject(with: approval.requestID, options: [.fragmentsAllowed])
                let permissions = approval.method == "item/permissions/requestApproval"
                let elicitation = approval.method == "mcpServer/elicitation/request"
                let method = elicitation ? "thread-follower-submit-mcp-server-elicitation-response"
                    : permissions ? "thread-follower-permissions-request-approval-response"
                    : approval.method == "item/fileChange/requestApproval" ? "thread-follower-file-approval-decision"
                    : "thread-follower-command-approval-decision"
                let response: [String: Any]
                do {
                    response = try connection.request(method, version: 1,
                        params: ["conversationId": approval.threadID, "requestId": requestID,
                                 permissions || elicitation ? "response" : "decision": payload], clientID: client, ownerID: owner)
                } catch { throw QuestionReplyError.uncertain }
                try Self.checkResponse(response)
                guard
                      (response["result"] as? [String: Any])?["ok"] as? Bool == true else { throw QuestionReplyError.protocolChanged }
                result = .success(())
            } catch { result = .failure(error) }
            DispatchQueue.main.async { self.busy = false; completion(result) }
        }
    }

    private func send(threadID: String, request: UserQuestionRequest, answers: [String: String]) throws {
        guard !threadID.isEmpty, request.questions.allSatisfy({
            let answer = answers[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !answer.isEmpty && answer.utf8.count <= 32_768
        }) else { throw QuestionReplyError.invalidAnswer }
        let connection = try CodexQuestionConnection(path: socketPath)
        let clientID = try connection.initialize()
        try connection.follow(threadID, clientID: clientID, following: true)
        defer { try? connection.follow(threadID, clientID: clientID, following: false) }
        let (state, ownerID) = try connection.snapshot(threadID)
        var method: String
        var params: [String: Any]
        if request.asynchronous {
            guard Self.isUnanswered(request, state: state) else { throw QuestionReplyError.stale }
            let text = try request.replyText(answers: answers)
            let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
            let messageID = UUID().uuidString
            let metadata = ["source": "codex", "client_type": "desktop_app"]
            if (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "active" {
                method = "thread-follower-steer-turn"
                let cwd = state["cwd"] as? String ?? "/"
                params = ["conversationId": threadID, "input": input,
                    "clientUserMessageId": messageID, "attachments": [],
                    "restoreMessage": ["id": messageID, "cwd": cwd, "createdAt": Date().timeIntervalSince1970 * 1000,
                        "responsesapiClientMetadata": metadata,
                        "context": ["prompt": text, "workspaceRoots": [cwd], "addedFiles": [],
                            "fileAttachments": [], "imageAttachments": [],
                            "collaborationMode": state["latestCollaborationMode"] ?? NSNull()]]]
            } else {
                method = "thread-follower-start-turn"
                params = Self.startTurnParams(threadID: threadID, input: input, messageID: messageID, metadata: metadata)
            }
        } else {
            guard let pending = Self.matchingPendingRequest(request, state: state), let requestID = pending["id"] else {
                throw QuestionReplyError.stale
            }
            method = "thread-follower-submit-user-input"
            params = ["conversationId": threadID, "requestId": requestID, "response": [
                "answers": answers.mapValues { ["answers": [$0]] }]]
        }
        // A write that may have reached the desktop is never retried automatically.
        var response: [String: Any]
        do { response = try connection.request(method, version: method == "thread-follower-start-turn" ? 2 : 1,
                    params: params, clientID: clientID, ownerID: ownerID) }
        catch { throw QuestionReplyError.uncertain }
        // The task can finish between the snapshot and the steer request. Only
        // this explicit pre-admission rejection allows one fresh-state fallback.
        // Transport failures and all other errors must never resend an answer.
        if method == "thread-follower-steer-turn", Self.isInactiveTurnRejection(response) {
            try connection.follow(threadID, clientID: clientID, following: true)
            let (fresh, freshOwner) = try connection.snapshot(threadID)
            guard Self.isUnanswered(request, state: fresh) else { throw QuestionReplyError.stale }
            guard (fresh["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "idle" else {
                throw QuestionReplyError.rejected
            }
            method = "thread-follower-start-turn"
            guard let input = params["input"] as? [[String: Any]], let messageID = params["clientUserMessageId"] as? String else {
                throw QuestionReplyError.protocolChanged
            }
            params = Self.startTurnParams(threadID: threadID, input: input,
                messageID: messageID,
                metadata: ["source": "codex", "client_type": "desktop_app"])
            do { response = try connection.request(method, version: 2, params: params,
                clientID: clientID, ownerID: freshOwner) }
            catch { throw QuestionReplyError.uncertain }
        }
        try Self.checkResponse(response)
    }

    private static func startTurnParams(threadID: String, input: [[String: Any]], messageID: String,
                                        metadata: [String: String]) -> [String: Any] {
        ["conversationId": threadID, "turnStart": ["request": [
            "threadId": threadID, "input": input, "clientUserMessageId": messageID,
            "responsesapiClientMetadata": metadata], "context": ["inheritThreadSettings": true]]]
    }

    static func isInactiveTurnRejection(_ response: [String: Any]) -> Bool {
        guard response["resultType"] as? String == "error", let error = response["error"] as? String else { return false }
        return error == "no active turn to steer"
            || (error.hasPrefix("Cannot steer conversation ") && error.hasSuffix(" because its active turn already ended"))
    }

    static func checkResponse(_ response: [String: Any]) throws {
        guard let type = response["resultType"] as? String else { throw QuestionReplyError.uncertain }
        if type == "success" { return }
        guard type == "error", let error = response["error"] as? String else { throw QuestionReplyError.uncertain }
        switch error {
        case "request-version-mismatch", "no-handler-for-request": throw QuestionReplyError.protocolChanged
        case "no-client-found", "client-coordination-service-unavailable": throw QuestionReplyError.unavailable
        case "request-timeout", "timeout", "client-disconnected", "server-closed": throw QuestionReplyError.uncertain
        case "no active turn to steer": throw QuestionReplyError.stale
        default: throw QuestionReplyError.rejected
        }
    }

    static func matchingPendingRequest(_ request: UserQuestionRequest, state: [String: Any]) -> [String: Any]? {
        (state["requests"] as? [[String: Any]] ?? []).first { row in
            guard row["method"] as? String == "item/tool/requestUserInput",
                  let params = row["params"] as? [String: Any],
                  let rows = params["questions"] as? [[String: Any]],
                  let current = UserQuestionRequest.parse(id: request.id, turnID: params["turnId"] as? String,
                    asynchronous: false, questions: rows, date: request.date),
                  current.questions == request.questions else { return false }
            return request.turnID == nil || current.turnID == request.turnID
        }
    }

    static func isUnanswered(_ request: UserQuestionRequest, state: [String: Any]) -> Bool {
        var found = false, answered = Set<String>()
        func visit(_ value: Any) {
            if let rows = value as? [Any] { rows.forEach(visit); return }
            guard let row = value as? [String: Any] else { return }
            let type = row["type"] as? String
            if type == "agentMessage", row["id"] as? String == request.id,
               let rows = row["questions"] as? [[String: Any]],
               let current = UserQuestionRequest.parse(id: request.id, turnID: request.turnID,
                    asynchronous: true, questions: rows, date: request.date) {
                found = current.questions == request.questions
            }
            if type == "userMessage" || (type == "steeringUserMessage" && row["status"] as? String == "accepted") {
                let parts = (row["content"] ?? row["input"]) as? [[String: Any]] ?? []
                answered.formUnion(UserQuestionRequest.answeredIDs(in: parts.compactMap { $0["text"] as? String }.joined(separator: "\n")))
            }
            // Restrict traversal to the desktop's transcript stores.
            for (key, value) in row where ["turns", "turnHistory", "history", "entitiesByKey", "items", "data"].contains(key) {
                if key == "entitiesByKey", let entities = value as? [String: Any] { entities.values.forEach(visit) }
                else { visit(value) }
            }
        }
        visit(state)
        return found && request.questions.allSatisfy { !answered.contains($0.id) }
    }
}

final class CodexQuestionConnection {
    let fd: Int32
    private(set) var maximumReceivedFrameBytes = 0
    var deadline = ProcessInfo.processInfo.systemUptime + 8
    private let maximumFrameBytes = 256 * 1024 * 1024
    init(path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFSOCK else { throw QuestionReplyError.unavailable }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QuestionReplyError.unavailable }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw QuestionReplyError.unavailable }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let addressLength = socklen_t(address.sun_len)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressLength) }
        }
        if connected < 0 {
            guard errno == EINPROGRESS else { close(fd); throw QuestionReplyError.unavailable }
            do { try ready(POLLOUT) } catch { close(fd); throw error }
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
            guard error == 0 else { close(fd); throw QuestionReplyError.unavailable }
        }
    }
    deinit { close(fd) }
    private func ready(_ eventMask: Int32) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw QuestionReplyError.unavailable }
        let events = Int16(eventMask)
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        guard Darwin.poll(&descriptor, 1, Int32(remaining * 1000)) > 0,
              descriptor.revents & events != 0 else { throw QuestionReplyError.unavailable }
    }
    private func write(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        var length = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(POLLOUT)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw QuestionReplyError.unavailable }; offset += count
            }
        }
    }
    func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try ready(POLLIN)
                let received = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard received > 0 else { throw QuestionReplyError.unavailable }; offset += received
            }
        }
        return data
    }
    private func receive() throws -> [String: Any] {
        let header = try read(4)
        let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        maximumReceivedFrameBytes = max(maximumReceivedFrameBytes, length)
        guard length > 0 else { throw QuestionReplyError.protocolChanged }
        guard length <= maximumFrameBytes else { throw QuestionReplyError.historyTooLarge }
        return try CodexReplySnapshot(length: length, read: { try self.read($0) }).decode()
    }
    func request(_ method: String, version: Int, params: [String: Any], clientID: String,
                 ownerID: String? = nil) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
            "version": version, "method": method, "params": params]
        if let ownerID { message["targetClientId"] = ownerID }
        try write(message)
        while true {
            let row = try receive()
            if row["type"] as? String == "response", row["requestId"] as? String == id { return row }
        }
    }
    func initialize() throws -> String {
        let response = try request("initialize", version: 0, params: ["clientType": "captions"], clientID: "initializing-client")
        guard response["resultType"] as? String == "success",
              let id = (response["result"] as? [String: Any])?["clientId"] as? String else { throw QuestionReplyError.protocolChanged }
        return id
    }
    func follow(_ threadID: String, clientID: String, following: Bool) throws {
        try write(["type": "broadcast", "sourceClientId": clientID, "version": 1,
            "method": "thread-stream-following-changed", "params": ["conversationId": threadID,
                "hostId": "local", "following": following]])
    }
    func snapshot(_ threadID: String) throws -> ([String: Any], String) {
        while true {
            let row = try receive()
            guard row["method"] as? String == "thread-stream-state-changed",
                  let params = row["params"] as? [String: Any], params["conversationId"] as? String == threadID,
                  params["hostId"] as? String == "local", let change = params["change"] as? [String: Any],
                  change["type"] as? String == "snapshot",
                  let state = change["conversationState"] as? [String: Any], state["id"] as? String == threadID,
                  let owner = row["sourceClientId"] as? String else { continue }
            return (state, owner)
        }
    }
}
