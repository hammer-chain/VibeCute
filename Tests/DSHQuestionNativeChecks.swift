import AppKit
import CaptionCore
@testable import CodexCaptions

@main struct DSHQuestionNativeChecks {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        precondition(!NSScreen.screens.isEmpty, "Run this check in a graphical macOS session")
        var request = UserQuestionRequest.parse(id:"fixture-call",turnID:nil,asynchronous:false,questions:[
            ["id":"first","question":"选择一种","options":[["label":"A"],["label":"B"]]],
            ["id":"tags","question":"选择多个","multi_select":true,"options":[["label":"X, one"],["label":"Y"]]]
        ],date:Date())!
        if let index = CommandLine.arguments.firstIndex(of:"--log") {
            let record = SessionRecord(url:URL(fileURLWithPath:CommandLine.arguments[index+1]),source:.deepseek)
            for _ in 0..<128 { _ = try record.poll() }
            guard let pending = record.snapshot.pendingQuestions.first(where: { $0.externalQuestion }) else {
                fatalError("No pending DSH question in this log; omit --log to use the isolated fixture")
            }
            request = pending
        }
        request.externalQuestion = true
        precondition(request.questions.count == 2)
        let controller = OverlayController()
        var submissions = 0
        controller.update(text:"",context:"DSH · 等待回复",title:"DSH 作答交互验收",live:false,mascot:nil,
            font:18,opacity:1,bottom:50,screenIndex:0,movable:true,visible:true,mode:.bubble,
            question:request,onOpenConversation:{nil},onQuestionReply:{ answers,done in
                precondition(answers.count == request.questions.count)
                if request.questions[1].multiSelect {
                    let tags = try! JSONSerialization.jsonObject(with:Data(answers[request.questions[1].id]!.utf8)) as! [String]
                    precondition(tags == Array(request.questions[1].options.prefix(2)))
                }
                submissions += 1
                done(submissions == 1 ? .failure(HarnessQuestionError.unavailable) : .success(()))
            })
        RunLoop.main.run(until:Date().addingTimeInterval(0.6))
        let view = controller.panel.contentView!
        func descendants(_ v:NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        func button(_ title:String) -> NSButton {
            descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title && !$0.isHidden }!
        }
        func choice(_ page:Int,_ index:Int) -> NSButton { button(request.questions[page].options[index]) }
        func hasText(_ text:String) -> Bool {
            descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(text) }
        }
        precondition(choice(0,0).state == .off && !button("下一题").isEnabled && hasText("已选 0/2 题"))
        button("›").performClick(nil)
        precondition(choice(1,0).state == .off && !button("补全回复").isEnabled)
        choice(1,0).performClick(nil)
        if request.questions[1].multiSelect {
            choice(1,1).performClick(nil); choice(1,0).performClick(nil)
            precondition(choice(1,0).state == .off && choice(1,1).state == .on)
            choice(1,0).performClick(nil)
        }
        precondition(button("补全回复").isEnabled)
        button("补全回复").performClick(nil)
        precondition(choice(0,0).state == .off && submissions == 0)
        choice(0,0).performClick(nil)
        precondition(button("下一题").isEnabled && hasText("已选完全部"))
        button("下一题").performClick(nil)
        precondition(choice(1,0).state == .on && button("发送回复").isEnabled && submissions == 0)
        // A caption refresh retains choices, page and the existing native view.
        (view as! QuestionReplyView).configure(request,title:"DSH 作答交互验收",onSubmit:{ answers,done in
            precondition(answers.count == request.questions.count)
            if request.questions[1].multiSelect {
                let tags = try! JSONSerialization.jsonObject(with:Data(answers[request.questions[1].id]!.utf8)) as! [String]
                precondition(tags == Array(request.questions[1].options.prefix(2)))
            }
            submissions += 1
            done(submissions == 1 ? .failure(HarnessQuestionError.unavailable) : .success(()))
        })
        precondition(choice(1,0).state == .on && button("发送回复").isEnabled)
        button("发送回复").performClick(nil)
        precondition(submissions == 1 && button("发送回复").isEnabled && hasText("DSH 未连接"))
        button("发送回复").performClick(nil)
        precondition(submissions == 2 && !button("发送回复").isEnabled && hasText("已发送"))
        let output=URL(fileURLWithPath:"output/dsh-questions/native-guided.png")
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try controller.exportPreview(to:output)
        controller.hide()
        print("PASS: guided next/missing-question/send flow, unselected defaults, paging and refresh retention, multi-select toggle, unavailable retry, duplicate prevention; isolated callback only")
    }
}
