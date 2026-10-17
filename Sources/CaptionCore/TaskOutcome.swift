import Foundation

public enum TaskOutcome: String, CaseIterable, Sendable, Identifiable {
    case started, completed, interrupted, failed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .started: return "开始"
        case .completed: return "完成"
        case .interrupted: return "中断"
        case .failed: return "失败"
        }
    }
    public var soundName: String {
        switch self {
        case .started: return "Tink"
        case .completed: return "Glass"
        case .interrupted: return "Pop"
        case .failed: return "Basso"
        }
    }
}

public struct TaskOutcomeNotice: Equatable, Sendable {
    public let outcome: TaskOutcome
    public let date: Date
    public let turnID: String?
}

/// One bounded tracker per retained log. Historical reads establish state;
/// only lifecycle events newer than the connection can produce a sound.
public struct TaskOutcomeTracker {
    private var notBefore: Date
    private var turnID: String?
    private var active = false
    private var seen: Set<String> = []
    private var order: [String] = []
    public init(notBefore: Date) { self.notBefore = notBefore }

    /// Replacing or truncating a log replays state without replaying sounds.
    public mutating func resetLog(at date: Date) {
        notBefore = max(notBefore, date); turnID = nil; active = false
    }

    public mutating func observe(_ event: SessionEvent) -> TaskOutcomeNotice? {
        switch event {
        case let .started(date, id):
            let resolvedID = id ?? (active ? turnID : nil)
            let key = resolvedID.map { "start:turn:" + $0 } ?? "start:date:\(date.timeIntervalSince1970)"
            if date > notBefore, seen.contains(key) { return nil }
            let duplicate = active && (id == nil || turnID == nil || id == turnID)
            turnID = resolvedID
            active = true
            guard date > notBefore else { return nil }
            if duplicate {
                if id != nil { _ = remember(key) }
                return nil
            }
            return notice(.started, date: date, id: turnID, key: key)
        case let .finished(date, outcome, id):
            let resolvedID = id ?? turnID
            // Reject a delayed terminal record from a different turn.
            if active, let id, let turnID, id != turnID { return nil }
            active = false
            guard date > notBefore else { return nil }
            let key = resolvedID.map { "turn:" + $0 } ?? "date:\(date.timeIntervalSince1970)"
            return notice(outcome, date: date, id: resolvedID, key: key)
        default: return nil
        }
    }
    private mutating func notice(_ outcome: TaskOutcome, date: Date, id: String?, key: String) -> TaskOutcomeNotice? {
        guard remember(key) else { return nil }
        return TaskOutcomeNotice(outcome: outcome, date: date, turnID: id)
    }
    private mutating func remember(_ key: String) -> Bool {
        guard seen.insert(key).inserted else { return false }
        order.append(key)
        if order.count > 64 { seen.remove(order.removeFirst()) }
        return true
    }
}
