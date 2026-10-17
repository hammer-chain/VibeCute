import AppKit
@main enum OpenCodeNavigationChecks {
    static func main() {
        let id = "ses_navigationFixture"
        let value = OpenCodeConversationNavigator.Record(version: 1, sessionID: id, pid: 123,
            processStart: 1, workspace: nil, surface: nil)
        let data = try! JSONEncoder().encode(value)
        precondition(OpenCodeConversationNavigator.decode(data, sessionID: id) == value)
        precondition(OpenCodeConversationNavigator.decode(data, sessionID: "ses_other") == nil)
        precondition(OpenCodeConversationNavigator.decode(Data(repeating: 32, count: 4097), sessionID: id) == nil)
        precondition(OpenCodeConversationNavigator.tty(value) == nil)
        print("PASS exact OpenCode session ID, foreign session, size bound and dead process")
        for id in CommandLine.arguments.dropFirst() {
            let start = ProcessInfo.processInfo.systemUptime
            guard let record = OpenCodeConversationNavigator.find(sessionID: id) else { fatalError("missing route registry") }
            print("PASS live OpenCode mapping \(id) → \(OpenCodeConversationNavigator.tty(record)!) in \(ProcessInfo.processInfo.systemUptime-start)s")
        }
    }
}
