import Foundation

public struct UserQuestion: Equatable, Sendable {
    public let id: String
    public let title: String
    public let options: [String]
    public let descriptions: [String]
    public var multiSelect: Bool = false
}

public struct ApprovalContent: Equatable, Sendable {
    public let title: String
    public let reason: String
    public let details: String
    public init(title: String, reason: String, details: String) {
        self.title = title; self.reason = reason; self.details = details
    }
}

public struct UserQuestionRequest: Equatable, Sendable {
    public let id: String
    public let turnID: String?
    public let asynchronous: Bool
    public let questions: [UserQuestion]
    public let date: Date
    public var externalApproval: Bool = false
    public var externalQuestion: Bool = false
    public var externalZCode: Bool = false
    public var applicationName: String { externalZCode ? "zcode" : externalApproval || externalQuestion ? "DSH" : "Codex" }
    public var approval: Bool = false
    public var approvalContent: ApprovalContent? = nil

    /// Accept only the two question tools, never arbitrary tool arguments.
    public static func parse(id: String, turnID: String?, asynchronous: Bool,
                             questions rows: [[String: Any]], date: Date) -> Self? {
        guard !id.isEmpty, (1...4).contains(rows.count) else { return nil }
        var questions: [UserQuestion] = []
        for (index, row) in rows.enumerated() {
            guard let title = row[asynchronous ? "title" : "question"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.utf8.count <= 32_768 else { return nil }
            let options: [String]
            let descriptions: [String]
            if asynchronous {
                options = row["options"] as? [String] ?? []
                descriptions = options.map { _ in "" }
            } else {
                let choices = row["options"] as? [[String: Any]] ?? []
                options = choices.compactMap { $0["label"] as? String }
                descriptions = choices.map { $0["description"] as? String ?? "" }
                guard options.count == descriptions.count else { return nil }
            }
            guard options.count <= 12, options.allSatisfy({ $0.utf8.count <= 8_192 }),
                  descriptions.allSatisfy({ $0.utf8.count <= 8_192 }) else { return nil }
            let questionID = asynchronous ? asyncQuestionID(itemID: id, index: index) : row["id"] as? String ?? ""
            guard !questionID.isEmpty, !questions.contains(where: { $0.id == questionID }) else { return nil }
            questions.append(UserQuestion(id: questionID, title: title, options: options, descriptions: descriptions,
                multiSelect: row["multi_select"] as? Bool ?? row["multiSelect"] as? Bool ?? false))
        }
        return Self(id: id, turnID: turnID, asynchronous: asynchronous, questions: questions, date: date)
    }

    /// Matches the installed desktop app's local thread deep-link route.
    /// An opaque path component must never introduce a query, prompt or another route.
    public static func conversationURL(threadID: String) -> URL? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "codex"; components.host = "threads"; components.path = "/" + threadID
        return components.url
    }

    public static func asyncQuestionID(itemID: String, index: Int) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["request_user_input_async", itemID, index], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    public func replyText(answers: [String: String]) throws -> String {
        let rows = questions.map { ["questionItemId": $0.id, "question": $0.title, "answer": answers[$0.id] ?? ""] }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes])
        return "<send_user_message_question_reply>\n" + String(decoding: data, as: UTF8.self)
            + "\n</send_user_message_question_reply>"
    }

    public static func answeredIDs(in text: String) -> Set<String> {
        let start = "<send_user_message_question_reply>", end = "</send_user_message_question_reply>"
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(start), value.hasSuffix(end),
              let data = value.dropFirst(start.count).dropLast(end.count).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows = object as? [[String: Any]] ?? (object as? [String: Any]).map { [$0] } ?? []
        return Set(rows.compactMap { $0["questionItemId"] as? String })
    }
}

public enum QuestionReplyError: LocalizedError {
    case unavailable, stale, invalidAnswer, protocolChanged, uncertain, rejected, historyTooLarge
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "无法连接 Codex。请确认桌面应用已打开，再重试。"
        case .stale: return "这条请求已处理、已取消或发生变化。请到 Codex 查看。"
        case .invalidAnswer: return "请为每个问题选择选项或输入回复。"
        case .protocolChanged: return "Codex 的回复接口暂不兼容。请到 Codex 中回复。"
        case .uncertain: return "未能确认提交结果。请先到 Codex 检查，避免重复提交。"
        case .rejected: return "Codex 未接受这次回复。内容已保留，请到 Codex 查看当前请求后重试。"
        case .historyTooLarge: return "这条聊天的数据超过回复读取上限。内容已保留，请到 Codex 中回复。"
        }
    }
}
