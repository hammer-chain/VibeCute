import Foundation
import CaptionCore

@main
struct CaptionDismissalChecks {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: " + message + "\n", stderr); exit(1) }
            print("PASS: " + message)
        }
        var session = SessionSnapshot(path: "/fixture/first", id: "first", active: true)
        var date = Date()
        func caption(_ text: String, kind: CaptionKind = .progress) {
            date = date.addingTimeInterval(0.01)
            session.caption = Caption(text: text, kind: kind, date: date)
        }
        caption("正在检查数据。")
        let state = ProjectCaptionState(session: session)
        func receive() { state.receive(session, answers: true, tools: true, font: 24) }
        receive(); check(state.hasContent && !state.isDismissed, "new captions initially appear")
        state.dismissCaption()
        for _ in 0..<100 { receive(); state.tick() }
        check(state.isDismissed, "unchanged monitor snapshots and page ticks do not revive a closed caption")
        caption("正在检查数据。随后继续检查更多内容。"); receive()
        check(state.isDismissed, "streaming continuation stays dismissed")
        caption("接下来生成报告。"); receive()
        check(!state.isDismissed, "a new message appears normally")
        state.dismissCaption()
        session.apply(.started(Date(), turnID: "next")); receive()
        check(state.isDismissed, "new task startup alone does not revive old text")
        caption("接下来生成报告。"); receive()
        check(!state.isDismissed, "same text in a new task can appear again")
        state.dismissCaption()
        session.path = "/fixture/other"; receive()
        check(!state.isDismissed, "another session does not inherit a dismissed caption")
    }
}
