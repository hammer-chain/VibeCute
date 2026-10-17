import Foundation
import Darwin
#if canImport(CaptionCore)
import CaptionCore
#endif
#if canImport(CodexCaptions)
@testable import CodexCaptions
#endif

@main
enum CodexReplySnapshotChecks {
    static func main() throws {
        if CommandLine.arguments.count > 1 {
            let connection = try CodexQuestionConnection(path: CommandLine.arguments[1])
            let threadID = CommandLine.arguments[2]
            let start = ProcessInfo.processInfo.systemUptime
            let client = try connection.initialize()
            try connection.follow(threadID, clientID: client, following: true)
            defer { try? connection.follow(threadID, clientID: client, following: false) }
            let (state, _) = try connection.snapshot(threadID)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let report: [String: Any] = ["readOnly": true, "frameBytes": connection.maximumReceivedFrameBytes,
                "projectedBytes": try JSONSerialization.data(withJSONObject: state).count,
                "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                "peakRSSBytes": usage.ru_maxrss, "matchingThread": state["id"] as? String == threadID]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
            return
        }
        func project(_ data: Data, approvalsOnly: Bool = false) throws -> [String: Any] {
            var offset = 0
            let parser = CodexReplySnapshot(length: data.count, approvalsOnly: approvalsOnly, read: { count in
                // The socket reader supplies exactly count bytes. Escapes and
                // UTF-8 are split by the parser's 64 KiB boundary in the big case.
                defer { offset += count }
                return data.subdata(in: offset..<offset + count)
            })
            return try parser.decode()
        }
        let title = "橙色发卡版完成后，Claude Code 默认使用哪一版？两套素材都会保留。"
        let request = UserQuestionRequest.parse(id: "call-large", turnID: nil, asynchronous: true,
            questions: [["title": title, "options": ["橙色发卡版", "现有白色头带版"]]], date: Date())!
        let reply = try request.replyText(answers: [request.questions[0].id: "橙色发卡版"])
        let question: [String: Any] = ["questions": [["title": title, "options": request.questions[0].options]],
            "id": request.id, "type": "agentMessage"]
        // Put the type after content, and cross a chunk boundary inside an emoji
        // and escaped quotation marks. Object order must not affect projection.
        let user: [String: Any] = ["content": [["text": reply, "type": "text"]], "type": "userMessage"]
        let envelope: [String: Any] = ["type": "broadcast", "method": "thread-stream-state-changed", "params": [
            "conversationId": "fixture", "hostId": "local", "change": ["type": "snapshot", "conversationState": [
                "id": "fixture", "requests": [], "turnHistory": ["history": ["entitiesByKey": ["turn": ["items": [question, user]]]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let projected = try project(data)
        let state = ((projected["params"] as! [String: Any])["change"] as! [String: Any])["conversationState"] as! [String: Any]
        precondition(!CodexQuestionReply.isUnanswered(request, state: state))
        let prefix = Data("{\"ignored\":\"".utf8)
        let padding = Data(repeating: 120, count: 65_500)
        var boundary = prefix; boundary.append(padding)
        boundary.append(Data("\",\"type\":\"broadcast\",\"error\":\"中文👨‍👩‍👧‍👦\\\"\\\\\"}".utf8))
        let boundaryResult = try project(boundary)
        precondition(boundaryResult["error"] as? String == "中文👨‍👩‍👧‍👦\"\\")
        for malformed in ["{\"type\":\"unterminated}", "{\"type\":true} trailing", "{\"type\":tru}"] {
            do { _ = try project(Data(malformed.utf8)); preconditionFailure("Accepted malformed JSON") }
            catch {}
        }
        let huge = Data(("{\"error\":\"" + String(repeating: "x", count: 600_000) + "\"}").utf8)
        do { _ = try project(huge); preconditionFailure("Accepted oversized retained field") }
        catch QuestionReplyError.historyTooLarge {}
        let fileRequest: [String: Any] = ["id":"approve-file", "method":"item/fileChange/requestApproval",
            "params":["threadId":"fixture","turnId":"turn-1","itemId":"file-1","reason":"fixture"]]
        let diff = "@@ -1 +1 @@\n-old\n+new"
        let item: [String: Any] = ["type":"fileChange", "id":"file-1", "turnId":"turn-1",
            "changes":[["path":"fixture.txt","kind":["type":"update"],"diff":diff]]]
        let largeEnvelope: [String: Any] = ["method":"thread-stream-state-changed", "params":["change":["conversationState":[
            "id":"fixture", "requests":[fileRequest], "turnHistory":["history":["entitiesByKey":["turn-1":["items":[
                ["type":"agentMessage","id":"huge-answer","content":[["type":"text","text":String(repeating:"x",count:17 * 1024 * 1024)]]], item
            ]]]]]]]]]
        let hugeFrame = try JSONSerialization.data(withJSONObject:largeEnvelope,options:.sortedKeys)
        precondition(hugeFrame.count > 16 * 1024 * 1024)
        let clock = ProcessInfo.processInfo.systemUptime
        let projectedLarge = try project(hugeFrame, approvalsOnly:true)
        let largeState = (((projectedLarge["params"] as! [String:Any])["change"] as! [String:Any])["conversationState"] as! [String:Any])
        let approval = CodexApproval.parse(threadID:"fixture",row:fileRequest,state:largeState)!
        precondition(approval.fileDetail != nil && approval.question.questions[0].options.contains("允许本次"))
        let projectedSize = try JSONSerialization.data(withJSONObject:projectedLarge).count
        precondition(projectedSize < 4096)
        precondition(CodexApproval.fileItem(id:"file-1",turnID:"wrong-turn",state:largeState) == nil)
        print("PASS: >16 MiB approval frame keeps a small pending diff, excludes huge answer and preserves turn scope; seconds=\(ProcessInfo.processInfo.systemUptime-clock)")
        print("PASS: snapshot projection, answered question, arbitrary field order, Unicode/escape boundary, malformed data and retained-field bounds")
    }
}
