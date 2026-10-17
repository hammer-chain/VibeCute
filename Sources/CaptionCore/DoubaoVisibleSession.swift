import Foundation

/// A single visible conversation. Changes alone advance the caption date;
/// repeated UI observations do not replay old answers or restart typing.
public final class DoubaoVisibleSession {
    private var current: SessionSnapshot?
    private var lastText = ""
    private var lastGenerating = false
    public init() {}
    public func reset() { current = nil; lastText = ""; lastGenerating = false }

    public func update(id: String, title: String, assistantText: String?, progressText: String? = nil, generating: Bool, now: Date = Date()) -> SessionSnapshot? {
        guard !id.isEmpty else { reset(); return nil }
        if current?.id != id {
            current = SessionSnapshot(path: "doubao-visible:" + id, id: id, title: String(title.prefix(200)))
            current?.source = .doubao; lastText = ""; lastGenerating = false
        }
        current?.title = String(title.prefix(200))
        let text = (generating ? progressText : assistantText).map { CaptionText.clean(String($0.prefix(8_000))) } ?? ""
        if generating && !lastGenerating { current?.apply(.started(now)) }
        if text != lastText || generating != lastGenerating {
            if !text.isEmpty { current?.apply(.caption(Caption(text: text, kind: generating ? .progress : .answer, date: now))) }
            else if generating { current?.apply(.caption(Caption(text: "豆包正在处理…", kind: .progress, date: now))) }
            if !generating && text.isEmpty { current?.caption = nil; current?.answer = nil }
            if !generating && (lastGenerating || !text.isEmpty) {
                current?.apply(.finished(now))
            }
        }
        lastText = text; lastGenerating = generating
        current?.readable = true
        return current
    }
}
