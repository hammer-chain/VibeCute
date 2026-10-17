import Foundation
import Darwin

@main
enum CodexQuestionReplyChecks {
    static func main() throws {
        let path = CommandLine.arguments[1], scenario = CommandLine.arguments[2]
        let sync = scenario.hasPrefix("sync")
        let rows: [[String: Any]] = sync
            ? [["id": "choice", "question": "选择布局", "options": [["label": "紧凑", "description": "节省空间"], ["label": "舒展", "description": "留白更多"]]]]
            : [["title": "怎么展示？", "options": ["紧凑", "舒展"]]]
        let request = UserQuestionRequest.parse(id: "call-fixture", turnID: "turn-fixture", asynchronous: !sync, questions: rows, date: Date())!
        let client = CodexQuestionReply(socketPath: path)
        var result: Result<Void, Error>?
        let start = ProcessInfo.processInfo.systemUptime
        client.submit(threadID: "thread-fixture", request: request,
            answers: [request.questions[0].id: scenario == "empty" ? "" : "自定义中文回复👨‍👩‍👧‍👦\n第二行"]) { result = $0 }
        while result == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        switch result! {
        case .success:
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("{\"success\":true,\"milliseconds\":\((ProcessInfo.processInfo.systemUptime - start) * 1000),\"peakRSSBytes\":\(usage.ru_maxrss)}")
        case let .failure(error):
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["success": false, "error": error.localizedDescription]), as: UTF8.self)
            print(text)
        }
    }
}
