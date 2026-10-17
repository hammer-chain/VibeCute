import Foundation
import Darwin

@main
enum CodexApprovalChecks {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        if mode == "projection" { try projectionChecks(); return }
        let path = CommandLine.arguments[2]
        if mode == "stream" {
            var received: [[CodexApproval]] = []
            let bridge = CodexApprovalStream(path: path) { received.append($0) }
            let ids = (0..<16).map { "thread-\($0)" }
            bridge.watch(ids)
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < 3 {
                bridge.watch(ids) // unchanged targets must not resubscribe
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            bridge.watch([])
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            precondition(received.contains { $0.count == 1 && $0[0].threadID == "thread-0" })
            precondition(received.last?.isEmpty == true)
            print("{\"success\":true,\"callbacks\":\(received.count)}")
            return
        }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
        let state = fixture["original"] as! [String: Any]
        let approval = CodexApproval.parse(threadID: "thread-fixture", row: (state["requests"] as! [[String: Any]])[0], state: state)!
        let choice = mode == "custom" ? "随便批准" : mode.contains("deny") ? "拒绝" : mode.contains("session") ? "本会话允许"
            : approval.method == "item/permissions/requestApproval" ? "允许本轮" : "允许本次"
        var result: Result<Void, Error>?
        let client = CodexQuestionReply(socketPath: path)
        client.submitApproval(approval, choice: choice) { result = $0 }
        while result == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let object: [String: Any]
        switch result! {
        case .success: object = ["success": true]
        case let .failure(error): object = ["success": false, "error": error.localizedDescription]
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    static func projectionChecks() throws {
        let params: [String: Any] = ["threadId": "thread-fixture", "turnId": "turn-fixture", "itemId": "command", "startedAtMs": 123,
                                   "command": "curl https://example.com/中文", "cwd": "/测试目录", "reason": "读取测试页面"]
        let row: [String: Any] = ["id": 17, "method": "item/commandExecution/requestApproval", "params": params]
        let command = CodexApproval.parse(threadID: "thread-fixture", row: row)!
        precondition(command.question.approval && command.responses.count == 3)
        precondition(CodexApproval.parse(threadID: "wrong-thread", row: row) == nil)
        var browserParams: [String: Any] = ["threadId": "thread-fixture", "turnId": "turn-fixture",
            "serverName": "cua_repl", "mode": "form", "message": "Allow upload to https://arena.ai?",
            "requestedSchema": ["type": "object", "properties": [:]],
            "_meta": ["codex_approval_kind": "mcp_tool_call", "connector_id": "browser-use",
                      "origin": "https://arena.ai", "file_transfer": "upload", "persist": ["session", "always"]]]
        var browserRow: [String: Any] = ["id": 759, "method": "mcpServer/elicitation/request", "params": browserParams]
        let browser = CodexApproval.parse(threadID: "thread-fixture", row: browserRow)!
        precondition(browser.question.questions[0].options == ["允许本次", "本会话允许", "始终允许", "拒绝"])
        precondition(browser.question.questions[0].title.contains("https://arena.ai"))
        let computerRow = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: "Tests/Fixtures/codex-computer-use-approval.json"))) as! [String: Any]
        let computer = CodexApproval.parse(threadID: "thread-fixture", row: computerRow)!
        precondition(computer.question.approval && computer.question.questions[0].options == ["允许本次", "本会话允许", "始终允许", "拒绝"])
        precondition(computer.question.approvalContent?.details.contains("请在 Codex") == false)
        precondition(computer.question.questions[0].title.contains("思考字幕后撤验收"))
        precondition(computer.responses == browser.responses)
        for connector in ["computer-use", "another-connector"] {
            var consentRow = computerRow
            var consentParams = consentRow["params"] as! [String: Any]
            var meta = consentParams["_meta"] as! [String: Any]
            meta["connector_id"] = connector; consentParams["_meta"] = meta; consentRow["params"] = consentParams
            precondition(CodexApproval.parse(threadID: "thread-fixture", row: consentRow)!.responses == browser.responses)
        }
        let extendedPermissions: [String: Any] = ["additionalPermission": ["access": "read"]]
        let extended = CodexApproval.parse(threadID: "thread-fixture", row: ["id": 18,
            "method": "item/permissions/requestApproval", "params": ["threadId": "thread-fixture",
                "turnId": "turn-fixture", "permissions": extendedPermissions]])!
        precondition(extended.question.questions[0].options == ["允许本轮", "本会话允许", "拒绝"])
        precondition(extended.question.questions[0].title.contains("additionalPermission"))
        let extendedResponse = try JSONSerialization.jsonObject(with: extended.responses[0]) as! [String: Any]
        precondition(CodexApproval.json(extendedResponse["permissions"]!) == CodexApproval.json(extendedPermissions))
        var ordinaryForm = computerRow
        var ordinaryParams = ordinaryForm["params"] as! [String: Any]
        ordinaryParams.removeValue(forKey: "_meta"); ordinaryForm["params"] = ordinaryParams
        precondition(CodexApproval.parse(threadID: "thread-fixture", row: ordinaryForm)!.question.questions[0].options == ["拒绝"])
        browserRow["completed"] = true
        precondition(CodexApproval.parse(threadID: "thread-fixture", row: browserRow) == nil)
        browserRow.removeValue(forKey: "completed")
        browserParams["requestedSchema"] = ["type": "object", "properties": ["name": ["type": "string"]]]
        browserRow["params"] = browserParams
        precondition(CodexApproval.parse(threadID: "thread-fixture", row: browserRow)!.question.questions[0].options == ["拒绝"])
        var browserProjection = CodexApprovalProjection(threadID: "thread-fixture")
        precondition(browserProjection.accept(["type": "snapshot", "revision": 1,
            "conversationState": ["id": "thread-fixture", "requests": [browserRow]]], owner: "owner") == .accepted)
        precondition(browserProjection.approvals.count == 1)
        precondition(browserProjection.accept(["type": "patches", "baseRevision": 1, "revision": 2,
            "patches": [["op": "add", "path": ["requests", 0, "completed"], "value": true]]], owner: "owner") == .accepted)
        precondition(browserProjection.approvals.isEmpty)
        precondition(CodexApproval.parse(threadID: "thread-fixture", row: ["id": 17, "method": "automaticApprovalReview", "params": params]) == nil)
        var projection = CodexApprovalProjection(threadID: "thread-fixture")
        let state: [String: Any] = ["id": "thread-fixture", "requests": [row]]
        precondition(projection.accept(["type": "snapshot", "revision": 1, "conversationState": state], owner: "owner") == .accepted)
        let start = ProcessInfo.processInfo.systemUptime
        for revision in 2...10_001 {
            precondition(projection.accept(["type": "patches", "baseRevision": revision - 1, "revision": revision,
                "patches": [["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "item", "text"], "value": "新字"]]], owner: "owner") == .accepted)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(projection.projectionCount == 1 && projection.patchCount == 0)
        precondition(projection.accept(["type": "patches", "baseRevision": 10_001, "revision": 10_002,
            "patches": [["op": "replace", "path": ["requests", 0, "params", "command"], "value": "other"]]], owner: "owner") == .accepted)
        precondition(projection.projectionCount == 2 && projection.approvals[0].question != command.question)
        precondition(projection.accept(["type": "patches", "baseRevision": 10_002, "revision": 10_003,
            "patches": [["op": "remove", "path": ["requests", 0]]]], owner: "owner") == .accepted)
        precondition(projection.approvals.isEmpty)
        precondition(projection.accept(["type": "patches", "baseRevision": 1, "revision": 10_004, "patches": []], owner: "owner") == .resnapshot)
        precondition(projection.accept(["type": "patches", "baseRevision": 10_003, "revision": 10_004, "patches": []], owner: "new-owner") == .resnapshot)
        let huge = ["id": "thread-fixture", "requests": Array(repeating: row, count: 129)] as [String: Any]
        precondition(projection.accept(["type": "snapshot", "revision": 1, "conversationState": huge], owner: "owner") == .resnapshot)
        var info = rusage(); getrusage(RUSAGE_SELF, &info)
        precondition(elapsed < 5) // broad headroom; operation counts are the stable regression guard
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["success": true,
            "unrelatedTextPatches": 10_000, "requestProjectionsDuringText": 0, "totalMilliseconds": elapsed * 1000,
            "peakRSSBytes": info.ru_maxrss, "requestProjectionsAfterChanges": projection.projectionCount]), as: UTF8.self))
    }
}
