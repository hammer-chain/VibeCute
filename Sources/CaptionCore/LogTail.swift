import Foundation

/// Reads only appended bytes, preserving incomplete JSON and UTF-8 across polls.
public final class LogTail {
    private var offset: UInt64 = 0
    private var pending = Data()
    private var inode: UInt64?
    private var discardUntilNewline = false
    public private(set) var didReset = false
    public private(set) var lastReadBytes = 0
    public private(set) var lastOpenedFile = false
    public private(set) var hasUnreadBytes = false
    public let url: URL
    public init(url: URL) { self.url = url }

    public func read(maxInitialBytes: Int = 2_000_000) throws -> [Data] {
        didReset = false
        lastReadBytes = 0
        lastOpenedFile = false
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let newInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if (inode != nil && inode != newInode) || size < offset {
            offset = 0; pending.removeAll(); discardUntilNewline = false; didReset = true
        }
        inode = newInode
        // Keep the metadata check above: replacement/truncation must reset even
        // on idle polls. Pending partial UTF-8 survives until bytes are appended.
        if size == offset { hasUnreadBytes = false; return [] }
        let handle = try FileHandle(forReadingFrom: url)
        lastOpenedFile = true
        defer { try? handle.close() }
        if offset == 0 && size > UInt64(maxInitialBytes) {
            offset = size - UInt64(maxInitialBytes)
            discardUntilNewline = true
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: 2_000_000) ?? Data()
        lastReadBytes = data.count
        offset += UInt64(data.count)
        hasUnreadBytes = offset < size
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if discardUntilNewline { discardUntilNewline = false }
            else if !line.isEmpty { lines.append(line) }
        }
        // Oversized records (e.g. inline assets) must not accumulate indefinitely.
        if pending.count > 4_000_000 { pending.removeAll(); discardUntilNewline = true }
        return lines
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public var source: SessionSource = .codex
    public var codexQuota: CodexQuota?
    public var harnessResponseSpeed: HarnessResponseSpeed?
    public var openCodeResponseSpeed: OpenCodeResponseSpeed?
    private var codexResponseProjection = CodexResponseSpeedProjection()
    public var codexResponseSpeed: CodexResponseSpeed? { codexResponseProjection.latest }
    public var path: String
    public var id: String
    public var project: String
    public var title: String
    public var projectName: String = ""
    public var projectID: String = ""
    public var active: Bool
    public var activity: Date
    public var caption: Caption?
    public var answer: Caption?
    public var readable: Bool
    public var finishedAt: Date?
    public var outcome: TaskOutcome?
    public var pendingQuestions: [UserQuestionRequest] = []
    private var questionValidAfter = Date.distantPast
    private var currentTurnID: String?
    public var runningSubagentCount = 0
    public var subagentActivity = Date.distantPast
    public var subagentFinishedAt = Date.distantPast
    public init(path: String, id: String = "", project: String = "", title: String = "", active: Bool = false,
                activity: Date = .distantPast, caption: Caption? = nil, readable: Bool = true) {
        self.path = path; self.id = id; self.project = project; self.active = active
        self.title = title
        self.activity = activity; self.caption = caption; self.readable = readable
    }
    public var label: String {
        if !title.isEmpty { return "\(source.rawValue) · \(title) · \(id.suffix(6))" }
        let name = URL(fileURLWithPath: project).lastPathComponent
        return "\(source.rawValue) · \(name.isEmpty ? "未命名对话" : name) · \(id.suffix(6))"
    }
    public var headerName: String {
        if !projectName.isEmpty { return projectName }
        return title.isEmpty ? "未命名对话" : String(title.prefix(10))
    }
    public mutating func resetActivity() {
        active = false; caption = nil; answer = nil; finishedAt = nil; outcome = nil; currentTurnID = nil
        pendingQuestions = []; questionValidAfter = .distantPast
        codexResponseProjection = CodexResponseSpeedProjection()
        harnessResponseSpeed = nil
        openCodeResponseSpeed = nil
    }
    public mutating func apply(_ event: SessionEvent) {
        switch event {
        case let .harnessResponseSpeed(value):
            if source == .deepseek, harnessResponseSpeed == nil || value.observedAt >= harnessResponseSpeed!.observedAt {
                harnessResponseSpeed = value
            }
        case let .codexResponse(value):
            if source == .codex { codexResponseProjection.accept(value) }
        case let .quota(value):
            if codexQuota == nil || value.observedAt >= codexQuota!.observedAt { codexQuota = value }
        case let .metadata(id, project): self.id = id; self.project = project
        case let .title(title): self.title = title
        case let .started(date, turnID):
            // Questions belong to the current turn, including async prompts.
            pendingQuestions.removeAll { turnID == nil || $0.turnID == nil || $0.turnID != turnID }
            if turnID == nil || currentTurnID != turnID { questionValidAfter = max(questionValidAfter, date) }
            currentTurnID = turnID
            active = true; activity = date; caption = nil; answer = nil; finishedAt = nil; outcome = nil
        case let .finished(date, outcome, turnID):
            if active, let turnID, let currentTurnID, turnID != currentTurnID { return }
            active = false; activity = max(activity, date); finishedAt = date; self.outcome = outcome
            pendingQuestions.removeAll { turnID == nil || $0.turnID == nil || $0.turnID == turnID }
        case let .question(request):
            // Desktop async prompts are actionable only while their turn is
            // running. Completion must also reject delayed duplicate items.
            guard finishedAt == nil else { return }
            guard request.date >= questionValidAfter else { return }
            if let requestTurn = request.turnID, let currentTurnID, requestTurn != currentTurnID { return }
            if !pendingQuestions.contains(where: { $0.id == request.id }) {
                pendingQuestions.append(request)
                if pendingQuestions.count > 8 { pendingQuestions.removeFirst(pendingQuestions.count - 8) }
            }
            activity = max(activity, request.date)
        case let .questionResolved(id):
            pendingQuestions.removeAll { !$0.asynchronous && $0.id == id }
        case let .questionsAnswered(ids):
            pendingQuestions.removeAll { $0.questions.allSatisfy { ids.contains($0.id) } }
        case let .userContinued(date):
            questionValidAfter = max(questionValidAfter, date)
            pendingQuestions.removeAll { $0.date <= date }
        case let .caption(value):
            if value.kind == .answer {
                if answer?.text != value.text { answer = value }
            } else {
                if caption?.text != value.text || caption?.kind != value.kind { caption = value }
                active = true
            }
            activity = max(activity, value.date)
        }
    }
    public func displayCaption(showAnswers: Bool) -> Caption? {
        let latest: Caption?
        if showAnswers, let answer {
            latest = caption.map { $0.date > answer.date ? $0 : answer } ?? answer
        } else { latest = caption }
        // A wrapper tool finishing does not mean its delegated work finished.
        // Override only an idle completion caption, preserving new parent text
        // and running/failed tools. Child bodies never become parent captions.
        // Harness child lifecycle is tracked internally, but only parent content is shown.
        guard source != .deepseek, active, let latest, latest.kind == .tool,
              latest.text.hasPrefix("调用完成") else { return latest }
        if runningSubagentCount > 0 {
            let count = runningSubagentCount > 1 ? "（\(runningSubagentCount) 个）" : ""
            return Caption(text: "正在等待子 agent…" + count, kind: .subagent,
                           date: max(latest.date, subagentActivity))
        }
        if subagentFinishedAt > latest.date {
            return Caption(text: "子 agent 已完成，正在继续处理…", kind: .subagent,
                           date: subagentFinishedAt)
        }
        return latest
    }
}

public enum SessionSelection {
    public static func choose(_ sessions: [SessionSnapshot], pinned: String?, now: Date = Date()) -> SessionSnapshot? {
        if let pinned { return sessions.first { $0.path == pinned } }
        let readable = sessions.filter(\.readable)
        // A crashed process can leave a start event behind. Do not follow it forever.
        let active = readable.filter { $0.active && now.timeIntervalSince($0.activity) < 3600 }
        return (active.isEmpty ? readable : active).max { $0.activity < $1.activity }
    }
}
