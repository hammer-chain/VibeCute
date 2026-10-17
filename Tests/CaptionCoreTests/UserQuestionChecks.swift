import Foundation
import CaptionCore

enum UserQuestionChecks {
    static func run() throws {
        let threadID = "01a11a0a-1a77-7263-addd-80d2f11e9c58"
        let url = UserQuestionRequest.conversationURL(threadID: threadID)!
        precondition(url.absoluteString == "codex://threads/" + threadID && url.query == nil)
        precondition(UserQuestionRequest.conversationURL(threadID: "../new?prompt=run") == nil)
        precondition(UserQuestionRequest.conversationURL(threadID: "") == nil)
        let asyncRows: [[String: Any]] = [["title": "怎么展示👨‍👩‍👧‍👦？", "options": ["选项一", "选项二"]], ["title": "补充说明？"]]
        let request = UserQuestionRequest.parse(id: "call-async", turnID: "turn-1", asynchronous: true,
            questions: asyncRows, date: Date())!
        precondition(request.questions[0].id == "[\"request_user_input_async\",\"call-async\",0]")
        let answers = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, "中文自定义\n第二行") })
        let reply = try request.replyText(answers: answers)
        precondition(UserQuestionRequest.answeredIDs(in: reply) == Set(request.questions.map(\.id)))
        precondition(UserQuestionRequest.answeredIDs(in: "系统文字 " + reply).isEmpty)
        var state = SessionSnapshot(path: "fixture")
        state.apply(.question(request)); state.apply(.question(request))
        precondition(state.pendingQuestions.count == 1, "duplicate question events dedupe")
        state.apply(.finished(Date(), turnID: "turn-1"))
        precondition(state.pendingQuestions.isEmpty, "completed async questions stop being actionable")
        state.apply(.questionsAnswered(Set(request.questions.map(\.id))))
        precondition(state.pendingQuestions.isEmpty)
        let syncRows: [[String: Any]] = [["id": "layout", "question": "选择布局", "options": [["label": "紧凑", "description": "节省空间"], ["label": "舒展", "description": "留白更多"]]]]
        let sync = UserQuestionRequest.parse(id: "call-sync", turnID: "turn-2", asynchronous: false, questions: syncRows, date: Date())!
        state.resetActivity()
        state.apply(.question(sync)); state.apply(.questionResolved("other-call"))
        precondition(state.pendingQuestions.count == 1)
        state.apply(.questionResolved("call-sync")); precondition(state.pendingQuestions.isEmpty)
        state.apply(.question(sync)); state.apply(.started(Date(), turnID: "turn-3")); precondition(state.pendingQuestions.isEmpty)
        state.apply(.question(request)); state.resetActivity(); precondition(state.pendingQuestions.isEmpty)
        for index in 0..<20 {
            state.apply(.question(UserQuestionRequest.parse(id: "\(index)", turnID: nil, asynchronous: true, questions: asyncRows, date: Date())!))
        }
        precondition(state.pendingQuestions.count == 8)
        func parse(_ payload: [String: Any], type: String) throws -> [SessionEvent] {
            EventParser.parse(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-10-08T00:00:00Z", "payload": payload]))
        }
        let event = try parse(["type": "item_completed", "turn_id": "turn-1", "item": ["type": "AgentMessage", "id": "call-async", "questions": asyncRows, "delivery": "async"]], type: "event_msg")
        precondition(event.count == 1)
        if case let .question(value) = event[0] { precondition(value.questions == request.questions) } else { preconditionFailure() }
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["questions": syncRows]), as: UTF8.self)
        let syncEvent = try parse(["type": "function_call", "name": "request_user_input", "call_id": "call-sync", "arguments": arguments], type: "response_item")
        if case .question = syncEvent.first {} else { preconditionFailure() }
        let unrelated = try parse(["type": "function_call", "name": "private_tool", "arguments": arguments], type: "response_item")
        precondition(unrelated.isEmpty)
        let accepted = try parse(["type": "function_call_output", "call_id": "call-async", "output": "{\"accepted\":true}"], type: "response_item")
        state.resetActivity(); state.apply(.question(request)); accepted.forEach { state.apply($0) }
        precondition(state.pendingQuestions.count == 1)
        let user = try parse(["type": "message", "role": "user", "content": [["type": "input_text", "text": reply]]], type: "response_item")
        user.forEach { state.apply($0) }; precondition(state.pendingQuestions.isEmpty)
        precondition(UserQuestionRequest.parse(id: "bad", turnID: nil, asynchronous: true,
            questions: [["title": ""]], date: Date()) == nil)
        let start = Date(timeIntervalSince1970: 1000)
        let fresh = UserQuestionRequest.parse(id: "fresh", turnID: "turn-fresh", asynchronous: true,
            questions: asyncRows, date: start.addingTimeInterval(1))!
        state.resetActivity(); state.apply(.started(start, turnID: "turn-fresh")); state.apply(.question(fresh))
        state.apply(.finished(start.addingTimeInterval(2), turnID: "turn-fresh"))
        precondition(state.pendingQuestions.isEmpty, "normal completion dismisses async questions")
        state.apply(.question(fresh))
        precondition(state.pendingQuestions.isEmpty, "late duplicate cannot revive a completed question")
        state.apply(.started(start.addingTimeInterval(3), turnID: "next-turn"))
        precondition(state.pendingQuestions.isEmpty, "a newer turn supersedes old async questions")
        state.apply(.question(fresh)); precondition(state.pendingQuestions.isEmpty, "delayed old-turn item cannot reappear")
        state.resetActivity(); state.apply(.started(start, turnID: "turn-fresh")); state.apply(.question(fresh))
        state.apply(.started(start, turnID: "turn-fresh"))
        precondition(state.pendingQuestions.count == 1, "duplicate same-turn start retains the current request")
        state.apply(.userContinued(start.addingTimeInterval(2))); precondition(state.pendingQuestions.isEmpty)
        state.apply(.question(fresh)); precondition(state.pendingQuestions.isEmpty, "answered/cancelled request cannot be replayed")
        for outcome in [TaskOutcome.interrupted, .failed] {
            state.resetActivity(); state.apply(.started(start, turnID: "turn-fresh")); state.apply(.question(fresh))
            state.apply(.finished(start.addingTimeInterval(2), outcome: outcome, turnID: "turn-fresh"))
            precondition(state.pendingQuestions.isEmpty, "cancelled/failed turn leaves no actionable async question")
        }
        let plain = try parse(["type": "message", "role": "user", "content": [["type": "input_text", "text": "继续下一步"]]], type: "response_item")
        if case .userContinued = plain.first {} else { preconditionFailure("plain desktop replies must supersede earlier prompts") }
        if let path = ProcessInfo.processInfo.environment["STALE_QUESTION_LOG"] {
            let url = URL(fileURLWithPath: path), reader = LogTail(url: url)
            let bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).intValue
            var replay = SessionSnapshot(path: path), legacy: [UserQuestionRequest] = [], rows = 0
            let began = ProcessInfo.processInfo.systemUptime
            for _ in 0..<(bytes / 2_000_000 + 3) {
                for line in try reader.read(maxInitialBytes: Int.max) {
                    rows += 1
                    for event in EventParser.parse(line) {
                        replay.apply(event)
                        // Frozen reproduction of the previous retention policy.
                        switch event {
                        case let .question(q):
                            if !legacy.contains(where: { $0.id == q.id }) { legacy.append(q); if legacy.count > 8 { legacy.removeFirst() } }
                        case .started: legacy.removeAll { !$0.asynchronous }
                        case let .finished(_, _, turn): legacy.removeAll { !$0.asynchronous && ($0.turnID == nil || $0.turnID == turn) }
                        case let .questionResolved(id): legacy.removeAll { !$0.asynchronous && $0.id == id }
                        case let .questionsAnswered(ids): legacy.removeAll { $0.questions.allSatisfy { ids.contains($0.id) } }
                        default: break
                        }
                    }
                }
            }
            precondition(!legacy.isEmpty && replay.pendingQuestions.isEmpty, "reported real chat must no longer show superseded prompts")
            let result: [String: Any] = ["sourceBytes": bytes, "recordsRead": rows, "previousPendingQuestions": legacy.count,
                "correctedPendingQuestions": replay.pendingQuestions.count,
                "replayMilliseconds": (ProcessInfo.processInfo.systemUptime - began) * 1000,
                "scope": "bounded production log reader; one full read-only replay of the reported chat, not per-poll work"]
            let target = URL(fileURLWithPath: "output/codex-questions/stale-replay-validation.json")
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: target)
            print("PASS: real-chat replay clears superseded prompts (previous: \(legacy.count), now: 0)")
        }
        print("PASS: question schemas, synchronous/async lifecycle, exact structured replies, Unicode, dedupe, reset and bounded retention")
    }
}
