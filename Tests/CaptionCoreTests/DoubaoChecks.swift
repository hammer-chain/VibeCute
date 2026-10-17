import Foundation
import CaptionCore

private func doubaoCheck(_ value: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
    guard value() else {
        FileHandle.standardError.write(Data("FAIL Doubao line \(line): \(message)\n".utf8)); exit(1)
    }
}

enum DoubaoChecks {
    static func run() {
        let reader = DoubaoVisibleSession(), time = Date(timeIntervalSince1970: 100)
        let first = reader.update(id: "42", title: "可见对话", assistantText: "已完成检查。", generating: false, now: time)!
        doubaoCheck(first.source == .doubao && first.answer?.text == "已完成检查。" && !first.active)
        doubaoCheck(first.displayCaption(showAnswers: false) == nil, "answer toggle must suppress visible replies")
        let idle = reader.update(id: "42", title: "可见对话", assistantText: "已完成检查。", generating: false, now: time.addingTimeInterval(20))!
        doubaoCheck(idle == first, "polling unchanged UI must not replay or renew an answer")
        let running = reader.update(id: "42", title: "可见对话", assistantText: nil, generating: true, now: time.addingTimeInterval(30))!
        doubaoCheck(running.active && running.answer == nil && running.caption?.text == "豆包正在处理…")
        doubaoCheck(reader.update(id: "42", title: "可见对话", assistantText: nil, generating: true, now: time.addingTimeInterval(40)) == running)
        let ended = reader.update(id: "42", title: "可见对话", assistantText: nil, generating: false, now: time.addingTimeInterval(50))!
        doubaoCheck(!ended.active && ended.caption == nil && ended.answer == nil, "unidentified completion cannot leave stale progress")
        let done = reader.update(id: "42", title: "可见对话", assistantText: "新的回复。", generating: false, now: time.addingTimeInterval(60))!
        doubaoCheck(done.answer?.text == "新的回复。" && done.displayCaption(showAnswers: true)?.text == "新的回复。")
        let switched = reader.update(id: "43", title: "另一个对话", assistantText: nil, generating: false)!
        doubaoCheck(switched.answer == nil && switched.caption == nil && switched.path == "doubao-visible:43")
        reader.reset()
        doubaoCheck(reader.update(id: "", title: "首页", assistantText: "未识别内容", generating: false) == nil)
        let bounded = reader.update(id: "44", title: String(repeating: "题", count: 1000), assistantText: String(repeating: "文", count: 20000), generating: false)!
        doubaoCheck(bounded.title.count == 200 && bounded.answer!.text.count <= 8000)
        let unreadable = DoubaoVisibleSession()
        _ = unreadable.update(id: "same", title: "对话", assistantText: "旧回答", generating: false, now: time)
        let cleared = unreadable.update(id: "same", title: "对话", assistantText: nil, generating: false, now: time.addingTimeInterval(1))!
        doubaoCheck(cleared.answer == nil && cleared.caption == nil, "unidentified same-chat content cannot retain an old reply")
        runningChecks()
        contentChecks()
        print("Doubao visible conversation lifecycle and content privacy checks passed")
    }
    private static func runningChecks() {
        typealias Info = DoubaoVisibleContent.Info
        let info: [Int: Info] = [1: Info(role: "AXGroup"), 2: Info(role: "AXButton", label: "已处理 4 分 3 秒"),
            3: Info(role: "AXStaticText"), 4: Info(role: "AXGroup"), 5: Info(role: "AXGroup"), 6: Info(role: "AXStaticText"),
            7: Info(role: "AXStaticText"), 8: Info(role: "AXStaticText")]
        let edges = [1: [2, 8, 3, 4], 4: [5, 7], 5: [6]]
        let texts = [3: "继续阅读教程的下一节。", 6: "正在读取 教程.pdf", 7: "PRIVATE TOOL OUTPUT", 8: "先前过程"]
        func children(_ element: Int, _ last: Bool) -> [Int] { edges[element] ?? [] }
        let row = DoubaoVisibleContent.latestActivity(in: 1, info: { info[$0] }, children: children)!
        doubaoCheck(row.running && row.element == 1)
        let progress = DoubaoVisibleContent.progress(in: 1, info: { info[$0] }, children: children, value: { texts[$0] })!
        doubaoCheck(progress.text == "继续阅读教程的下一节。\n正在读取 教程.pdf" && progress.kind == .progress)
        let wrapped: [Int: Info] = [9: Info(role: "AXGroup"), 10: Info(role: "AXGroup"), 11: Info(role: "AXGroup")]
        let wrappedEdges = [1: [9, 11, 4], 9: [10], 10: [2], 11: [3]]
        func wrappedChildren(_ element: Int, _ last: Bool) -> [Int] { wrappedEdges[element] ?? edges[element] ?? [] }
        let wrappedRow = DoubaoVisibleContent.latestActivity(in: 1, info: { wrapped[$0] ?? info[$0] }, children: wrappedChildren)!
        doubaoCheck(wrappedRow.running && wrappedRow.element == 1, "elapsed control may have Chromium wrappers")
        func ancestorInfo(_ element: Int) -> Info? {
            if element == 12 || element == 13 { return Info(role: "AXGroup") }
            return wrapped[element] ?? info[element]
        }
        func ancestorChildren(_ element: Int, _ last: Bool) -> [Int] {
            if element == 12 { return [13] }; if element == 13 { return [1] }
            return wrappedChildren(element, last)
        }
        let ancestor = DoubaoVisibleContent.latestActivity(in: 12, info: ancestorInfo, children: ancestorChildren)!
        doubaoCheck(ancestor.running && ancestor.element == 1, "one-child ancestors cannot replace the running message row")
        let wrappedProgress = DoubaoVisibleContent.progress(in: 1, info: { wrapped[$0] ?? info[$0] }, children: wrappedChildren, value: { texts[$0] })!
        doubaoCheck(wrappedProgress.text == progress.text, "public commentary wrappers preserve progress")
        let proseOnly = DoubaoVisibleContent.progress(in: 1, info: { wrapped[$0] ?? info[$0] }, children: wrappedChildren, value: { texts[$0] }, includeTools: false)
        doubaoCheck(proseOnly?.text == "继续阅读教程的下一节。", "tool toggle preserves public commentary")
        var privateReads = 0
        let privateProgress = DoubaoVisibleContent.progress(in: 1,
            info: { $0 == 11 ? Info(role: "AXGroup", identifier: "reasoning-panel") : wrapped[$0] ?? info[$0] },
            children: wrappedChildren, value: { if $0 == 3 { privateReads += 1 }; return texts[$0] })
        doubaoCheck(privateReads == 0 && privateProgress?.text == "正在读取 教程.pdf", "hidden thought identifiers remain excluded")
        let tracker = DoubaoVisibleSession(), now = Date(timeIntervalSince1970: 123)
        let first = tracker.update(id: "live", title: "运行任务", assistantText: nil, progressText: progress.text, generating: true, now: now)!
        doubaoCheck(first.active && first.caption?.text == "继续阅读教程的下一节。 正在读取 教程.pdf" && first.answer == nil)
        doubaoCheck(tracker.update(id: "live", title: "运行任务", assistantText: nil, progressText: progress.text, generating: true, now: now.addingTimeInterval(1)) == first)
        let next = tracker.update(id: "live", title: "运行任务", assistantText: nil, progressText: "开始核对模型结构。", generating: true, now: now.addingTimeInterval(2))!
        doubaoCheck(next.caption?.text == "开始核对模型结构。" && next.activity > first.activity)
        let finished = tracker.update(id: "live", title: "运行任务", assistantText: "整理完成。", generating: false, now: now.addingTimeInterval(3))!
        doubaoCheck(!finished.active && finished.answer?.text == "整理完成。")
    }
    private static func contentChecks() {
        typealias Info = DoubaoVisibleContent.Info
        let nodes: [Int: Info] = [
            1: Info(role: "AXGroup"), 2: Info(role: "AXStaticText", label: "USER PRIVATE"),
            3: Info(role: "AXGroup"), 4: Info(role: "AXGroup"), 5: Info(role: "AXButton", label: "朗读"),
            6: Info(role: "AXStaticText"), 7: Info(role: "AXGroup", identifier: "reasoning-panel"),
            8: Info(role: "AXStaticText"), 9: Info(role: "AXTextArea"), 10: Info(role: "AXStaticText"),
            11: Info(role: "AXGroup"), 12: Info(role: "AXGroup"), 13: Info(role: "AXStaticText"),
            14: Info(role: "AXStaticText"), 15: Info(role: "AXTable"), 16: Info(role: "AXStaticText"),
            17: Info(role: "AXStaticText"), 18: Info(role: "AXStaticText"),
            19: Info(role: "AXGroup"), 20: Info(role: "AXStaticText"),
            21: Info(role: "AXGroup"), 22: Info(role: "AXGroup"), 23: Info(role: "AXGroup"),
            24: Info(role: "AXGroup"), 25: Info(role: "AXGroup"), 26: Info(role: "AXImage"), 27: Info(role: "AXGroup"), 28: Info(role: "AXGroup"), 29: Info(role: "AXGroup")]
        let edges = [1: [2], 3: [4, 5, 17], 4: [6, 7, 9, 11, 15, 18],
                     7: [8], 9: [10], 11: [12, 14], 12: [13], 15: [16], 19: [20], 21: [22, 25], 22: [23], 23: [24, 1, 3, 19], 25: [26], 27: [28, 14, 18], 28: [24, 29], 29: [13]]
        let texts = [2: "USER PRIVATE", 6: "助手可见回复。", 8: "PRIVATE THOUGHT", 10: "DRAFT PRIVATE",
                     13: "markdown", 14: "PRIVATE CODE", 16: "TABLE PRIVATE", 17: "FOOTER PRIVATE", 18: "已完成。", 20: "最新用户输入"]
        var reads: [Int] = [], visits = 0
        func extract(_ rows: [Int]) -> String? {
            reads = []; visits = 0
            return DoubaoVisibleContent.extract(rows: rows, info: { visits += 1; return nodes[$0] },
                children: { edges[$0] ?? [] }, value: { reads.append($0); return texts[$0] })
        }
        doubaoCheck(extract([1, 3, 19]) == "助手可见回复。\n已完成。")
        doubaoCheck(Set(reads).isSubset(of: [6, 13, 18]), "prompts, drafts, thinking, code, table and footer must never be read")
        doubaoCheck(extract([1, 19]) == nil && reads.isEmpty, "unknown/user rows fail closed")
        let expected = extract([1, 3, 19]), baseline = visits
        doubaoCheck(extract(Array(repeating: 1, count: 10000) + [3, 19]) == expected && visits <= baseline + 8,
                     "history growth cannot increase traversal beyond six message rows")
        func latest(_ document: Int, history: Int = 0) -> Int? {
            DoubaoVisibleContent.latestRow(in: document, info: { nodes[$0] }, children: { element, last in
                let parts = element == 23 && history > 0 ? Array(repeating: 1, count: history) + [3, 19] : edges[element] ?? []
                return last ? Array(parts.suffix(6)) : Array(parts.prefix(16))
            })
        }
        doubaoCheck(latest(21) == 3 && latest(21, history: 10000) == 3, "virtualized wrappers and decoration cannot hide latest assistant")
        doubaoCheck(latest(3) == 3, "one assistant row must not be unwrapped into its body and footer")
        doubaoCheck(latest(19) == nil, "user-only document has no assistant row")
        let mixed = DoubaoVisibleContent.extract(rows: [3], info: { nodes[$0] },
            children: { $0 == 3 ? [27, 5] : edges[$0] ?? [] }, value: { reads.append($0); return texts[$0] })
        doubaoCheck(mixed == "已完成。" && !reads.contains(14), "wrapped code header/body siblings must be skipped while following prose survives")
        let long = DoubaoVisibleContent.extract(rows: [3], info: { nodes[$0] }, children: { edges[$0] ?? [] },
            value: { $0 == 6 ? String(repeating: "字", count: 20000) : texts[$0] })!
        doubaoCheck(long.count <= 8000)
    }

}
