import AppKit

@main enum ClaudeNavigationChecks {
    static func main() {
        let session = "75fcd701-ca2c-4d68-8ac9-35a108808cd4"
        let other = "fde5bc0d-060e-4999-a3dc-3d91cc488985"
        let workspace = "EE888A93-AC51-4BE9-9F1F-898D7FEEF109"
        let surface = "739803BA-9C79-4E80-9C00-D42357BF15CB"
        func fixture(active: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["sessions": [session: ["workspaceId": workspace, "surfaceId": surface, "pid": 123]], "activeSessionsBySurface": [surface: ["sessionId": active]]])
        }
        precondition(ClaudeConversationNavigator.target(sessionID: session, data: fixture(active: session)) == .init(workspace: workspace, surface: surface, pid: 123))
        precondition(ClaudeConversationNavigator.target(sessionID: session, data: fixture(active: other)) == nil)
        precondition(ClaudeConversationNavigator.target(sessionID: other, data: fixture(active: session)) == nil)
        precondition(ClaudeConversationNavigator.target(sessionID: session, data: Data(repeating: 32, count: 2_000_001)) == nil)
        precondition(ClaudeConversationNavigator.target(sessionID: session, data: Data("{}".utf8)) == nil)
        precondition(ClaudeConversationNavigator.terminalTarget(sessionID: "not-a-session") == nil)
        precondition(ClaudeConversationNavigator.terminalTarget(sessionID: "00000000-0000-0000-0000-000000000000") == nil)
        print("PASS exact mapping, replaced session, missing session, oversized/corrupt registry, absent Terminal session")
        if CommandLine.arguments.count > 1 {
            _ = NSApplication.shared
            let ids = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
            if CommandLine.arguments.contains("--terminal-targets") {
                let targets = ids.map { ClaudeConversationNavigator.terminalTarget(sessionID: $0) }
                precondition(targets.allSatisfy { $0 != nil })
                precondition(Set(targets.compactMap { $0?.tty }).count == ids.count)
                for (id, target) in zip(ids, targets) { print("PASS Terminal mapping \(id) → \(target!.tty)") }
                return
            }
            for id in ids {
                var done = false
                var failure: String?
                let started = ProcessInfo.processInfo.systemUptime
                failure = ClaudeConversationNavigator.shared.open(sessionID: id) { error in failure = error; done = true }
                precondition(failure == nil, failure ?? "")
                while !done && ProcessInfo.processInfo.systemUptime - started < 40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                precondition(done && failure == nil, failure ?? "timeout")
                print("PASS live focus \(id) in \(ProcessInfo.processInfo.systemUptime - started)s")
            }
        }
    }
}
