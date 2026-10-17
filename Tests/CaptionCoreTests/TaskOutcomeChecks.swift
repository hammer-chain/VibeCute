import Foundation
import CaptionCore

enum TaskOutcomeChecks {
    static func run() throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func parse(_ payload: [String: Any], at seconds: Double = 1) throws -> [SessionEvent] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": payload,
                "timestamp": formatter.string(from: base.addingTimeInterval(seconds))])
            return EventParser.parse(data)
        }
        for type in ["task_complete", "task_completed", "turn_complete"] {
            for (error, expected) in [(NSNull() as Any, TaskOutcome.completed),
                                      (["message": "terminal failure"] as Any, .failed)] {
                let events = try parse(["type": type, "turn_id": "a", "error": error])
                guard case let .finished(_, outcome, id) = events.first else { preconditionFailure("Missing terminal event") }
                precondition(outcome == expected && id == "a")
            }
        }
        guard case .finished(_, .interrupted, _) = try parse(["type": "turn_aborted",
            "turn_id": "a", "reason": "interrupted", "error": ["message": "cancelled"]]).first else {
            preconditionFailure("Abort must remain interruption")
        }
        for payload: [String: Any] in [
            ["type": "stream_error", "message": "retrying"], ["type": "error", "message": "transient"],
            ["type": "warning", "message": "warning"],
            ["type": "item_completed", "item": ["type": "CommandExecution", "status": "failed"]]
        ] {
            let events = try parse(payload)
            precondition(!events.contains { if case .finished = $0 { return true }; return false })
        }
        var tracker = TaskOutcomeTracker(notBefore: base)
        var starts = TaskOutcomeTracker(notBefore: base)
        precondition(starts.observe(.started(base.addingTimeInterval(-1), turnID: "old")) == nil)
        let firstStart = starts.observe(.started(base.addingTimeInterval(1), turnID: "new"))
        precondition(firstStart?.outcome == .started && firstStart?.turnID == "new")
        precondition(starts.observe(.started(base.addingTimeInterval(2), turnID: "new")) == nil)
        precondition(starts.observe(.finished(base.addingTimeInterval(3), outcome: .completed, turnID: "new"))?.outcome == .completed)
        precondition(starts.observe(.started(base.addingTimeInterval(4), turnID: "new")) == nil)
        precondition(starts.observe(.started(base.addingTimeInterval(5)))?.outcome == .started)
        var aliases = TaskOutcomeTracker(notBefore: base)
        precondition(aliases.observe(.started(base.addingTimeInterval(1)))?.outcome == .started)
        precondition(aliases.observe(.started(base.addingTimeInterval(2), turnID: "named")) == nil)
        precondition(aliases.observe(.finished(base.addingTimeInterval(3), outcome: .completed, turnID: "named"))?.turnID == "named")
        aliases.resetLog(at: base.addingTimeInterval(5))
        precondition(aliases.observe(.started(base.addingTimeInterval(4), turnID: "replayed")) == nil)
        precondition(tracker.observe(.finished(base, turnID: "old")) == nil)
        _ = tracker.observe(.started(base, turnID: "a"))
        precondition(tracker.observe(.finished(base.addingTimeInterval(1), turnID: "a"))?.outcome == .completed)
        precondition(tracker.observe(.finished(base.addingTimeInterval(2), turnID: "a")) == nil)
        _ = tracker.observe(.started(base.addingTimeInterval(3), turnID: "b"))
        precondition(tracker.observe(.finished(base.addingTimeInterval(4), turnID: "a")) == nil)
        precondition(tracker.observe(.finished(base.addingTimeInterval(5), outcome: .interrupted, turnID: "b"))?.outcome == .interrupted)
        _ = tracker.observe(.started(base.addingTimeInterval(6), turnID: "c"))
        precondition(tracker.observe(.finished(base.addingTimeInterval(7), outcome: .failed, turnID: "c"))?.outcome == .failed)
        tracker.resetLog(at: base.addingTimeInterval(8))
        precondition(tracker.observe(.finished(base.addingTimeInterval(7), turnID: "new-history")) == nil)
        _ = tracker.observe(.started(base.addingTimeInterval(9), turnID: "d"))
        precondition(tracker.observe(.finished(base.addingTimeInterval(10), turnID: "d")) != nil)
        precondition(tracker.observe(.finished(.distantPast)) == nil)
        var legacy = TaskOutcomeTracker(notBefore: base)
        let noID = SessionEvent.finished(base.addingTimeInterval(1))
        precondition(legacy.observe(noID) != nil && legacy.observe(noID) == nil)
        var snapshot = SessionSnapshot(path: "fixture")
        snapshot.apply(.started(base, turnID: "new"))
        snapshot.apply(.finished(base.addingTimeInterval(1), turnID: "old"))
        precondition(snapshot.active && snapshot.outcome == nil)
        snapshot.apply(.finished(base.addingTimeInterval(2), outcome: .failed, turnID: "new"))
        precondition(!snapshot.active && snapshot.outcome == .failed)
        snapshot.apply(.started(base.addingTimeInterval(3), turnID: "next"))
        precondition(snapshot.outcome == nil)
        snapshot.resetActivity()
        snapshot.apply(.caption(Caption(text: "new log progress", kind: .progress, date: base)))
        snapshot.apply(.finished(base.addingTimeInterval(4), turnID: "replacement"))
        precondition(!snapshot.active && snapshot.outcome == .completed)
        print("PASS: outcome schemas, terminal errors, interruption, retry/tool exclusion, historical reads, duplicate turns, reset and stale terminals")
    }
}
