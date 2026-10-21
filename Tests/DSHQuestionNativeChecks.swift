import AppKit
import CaptionCore
@testable import CodexCaptions

@main struct DSHQuestionNativeChecks {
    static func main() throws {
        _ = NSApplication.shared
        let path = CommandLine.arguments[CommandLine.arguments.firstIndex(of:"--log")!+1]
        let record = SessionRecord(url:URL(fileURLWithPath:path),source:.deepseek)
        for _ in 0..<128 { _ = try record.poll() }
        let request = record.snapshot.pendingQuestions.first { $0.externalQuestion }!
        precondition(request.questions.count == 2 && request.questions.map(\.id) == ["taxonomy","source"])
        let controller = OverlayController()
        var submitted = false
        controller.update(text:"",context:"DSH · 等待回复",title:"优化素材分析提示词",live:false,mascot:nil,
            font:18,opacity:1,bottom:50,screenIndex:0,movable:true,visible:true,mode:.bubble,
            question:request,onOpenConversation:{nil},onQuestionReply:{ answers,done in
                precondition(answers.count == 2)
                submitted = true; done(.success(()))
            })
        RunLoop.main.run(until:Date().addingTimeInterval(0.6))
        let view = controller.panel.contentView!
        func buttons(_ v:NSView) -> [NSButton] { v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        func visible(_ title:String) -> NSButton { buttons(view).first { $0.title == title && !$0.isHidden }! }
        let choices = buttons(view).filter { $0.title == request.questions[0].options[0] }
        precondition(choices.count == 1 && choices[0].state == .off && !submitted)
        choices[0].performClick(nil)
        visible("›").performClick(nil)
        precondition(buttons(view).contains { $0.title == request.questions[1].options[0] })
        buttons(view).first { $0.title == request.questions[1].options[0] }!.performClick(nil)
        visible("发送回复").performClick(nil)
        precondition(submitted, "Only the fixture callback receives the local test choices")
        let output = URL(fileURLWithPath:"output/dsh-questions/native.png")
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try controller.exportPreview(to:output)
        controller.hide()
        print("PASS: real pending DSH log renders two unselected questions, native next page/options and complete batch; fixture callback only, no real answer sent")
    }
}
