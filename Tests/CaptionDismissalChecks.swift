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
        var working = SessionSnapshot(path: "/fixture/hidden-tool")
        working.source = .deepseek
        working.apply(.started(Date().addingTimeInterval(-600)))
        working.apply(.caption(Caption(text: "保留上一句思考。", kind: .reasoning, date: Date().addingTimeInterval(-500))))
        working.apply(.caption(Caption(text: "正在编辑：result.json", kind: .tool, date: Date())))
        let restarted = ProjectCaptionState(session: working)
        restarted.receive(working, answers: true, tools: false, font: 24)
        check(restarted.active && restarted.text == "保留上一句思考。", "restart during a long hidden tool retains the current-turn thought older than 90 seconds")
        restarted.receive(working, answers: true, tools: true, font: 24)
        check(restarted.text == "正在编辑：result.json", "enabling tools restores their current caption")
        restarted.receive(working, answers: true, tools: false, font: 24)
        check(restarted.text == "保留上一句思考。", "disabling tools immediately restores the thought")

    }
}
