import Foundation
import CaptionCore

/// Project IDs are explicit membership; cwd and title are not project identity.
func captionGroup(_ session: SessionSnapshot) -> String {
    // OpenCode project IDs belong to its own namespace, even when another
    // harness happens to use the same literal identifier.
    if session.source == .opencode && !session.projectID.isEmpty {
        return "project:OpenCode:" + session.projectID
    }
    if !session.projectID.isEmpty { return "project:" + session.projectID }
    return "chat:" + session.source.rawValue + ":" + (session.id.isEmpty ? session.path : session.id)
}

final class ProjectCaptionState {
    var session: SessionSnapshot
    private var key = ""
    private var lastCaptionText = ""
    private var typingGeneration = UUID().uuidString
    private var dismissedGeneration: String?
    private var awaitingNewMessage = false
    var isDismissed: Bool { dismissedGeneration == typingGeneration }
    func dismissCaption() { dismissedGeneration = typingGeneration }
    private var pages: [String] = []
    private var pageIndex = 0
    private var nextPage = Date.distantFuture
    var hideAt = Date.distantPast
    var text = ""
    var hasContent: Bool { !text.isEmpty }
    var kind = "等待更新"
    var typewriterID: String? {
        kind == "等待更新" ? nil : "\(typingGeneration):\(pageIndex)"
    }
    var active: Bool { session.active && Date().timeIntervalSince(session.activity) < 3600 }
    var header: String {
        let page = pages.count > 1 ? "  \(pageIndex + 1)/\(pages.count)" : ""
        let sourceName = session.source == .deepseek ? "DSH" : session.source.rawValue
        return "\(sourceName)  ·  \(kind)\(page)  ·  \(session.headerName)"
    }

    init(session: SessionSnapshot) { self.session = session }

    func receive(_ value: SessionSnapshot, answers: Bool, tools: Bool, font: Double) {
        let wasActive = active
        if value.path != session.path {
            key = ""; pages = []; lastCaptionText = ""; nextPage = .distantFuture
            typingGeneration = UUID().uuidString
            text = ""; kind = "等待更新"; hideAt = .distantPast
        }
        if value.active && value.caption == nil && value.answer == nil && !lastCaptionText.isEmpty {
            awaitingNewMessage = true
        }
        session = value
        if wasActive && !active { hideAt = max(hideAt, Date().addingTimeInterval(18)) }
        // WorkBuddy can begin a turn in SQLite before publishing any public text.
        // A withdrawn body must also disappear from the rendered page cache.
        if value.source == .workbuddy && value.displayCaption(showAnswers: answers) == nil {
            key = ""; pages = []; lastCaptionText = ""; text = ""; kind = "等待更新"
            nextPage = .distantFuture
        }
        guard let caption = value.displayCaption(showAnswers: answers),
              caption.kind != .tool || tools else { return }
        let newKey = value.path + caption.kind.rawValue + String(caption.date.timeIntervalSince1970)
            + caption.text + String(font > 34)
        guard key != newKey else { return }
        key = newKey
        guard caption.kind == .subagent || Date().timeIntervalSince(caption.date) < 90 else { return }
        let continuing = !awaitingNewMessage && kind == caption.kind.rawValue
            && !lastCaptionText.isEmpty && caption.text.hasPrefix(lastCaptionText)
        if !continuing { typingGeneration = UUID().uuidString }
        awaitingNewMessage = false
        pages = CaptionText.pages(caption.text, limit: font > 34 ? 28 : 38)
        pageIndex = continuing ? min(pageIndex, max(0, pages.count - 1)) : 0
        text = pages.isEmpty ? "" : pages[pageIndex]
        kind = caption.kind.rawValue
        if !continuing { nextPage = Date().addingTimeInterval(dwell(text)) }
        hideAt = max(nextPage, Date()).addingTimeInterval(18)
        lastCaptionText = caption.text
    }

    func tick() {
        guard Date() >= nextPage, pageIndex + 1 < pages.count else { return }
        pageIndex += 1; text = pages[pageIndex]
        nextPage = Date().addingTimeInterval(dwell(text))
        hideAt = nextPage.addingTimeInterval(18)
    }

    func didReplyToQuestion(approval: Bool = false) {
        text = approval ? "决定已提交，等待 Codex 继续…" : "已回复，等待 Codex 继续…"; kind = "进度"
        pages = [text]; pageIndex = 0; nextPage = .distantFuture
        typingGeneration = UUID().uuidString
        hideAt = Date().addingTimeInterval(18)
    }

    private func dwell(_ value: String) -> TimeInterval { min(9, max(3.5, Double(value.count) / 7.5)) }

}
