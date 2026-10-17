import Foundation
#if canImport(CaptionCore)
import CaptionCore
#endif

/// Projects a desktop IPC frame while reading it. Long chats include tool bodies
/// and image data in their snapshots; none of that is needed to answer a question.
/// Memory is bounded independently of frame size, with no transcript cache.
final class CodexReplySnapshot {
    private enum Context { case envelope, params, change, state, transcript, entities, content, raw }
    private let readChunk: (Int) throws -> Data
    private var remaining: Int
    private var buffer: [UInt8] = []
    private var index = 0
    private var retainedBytes = 0
    private var nodes = 0
    private let maximumStringBytes = 512 * 1024
    private let maximumRetainedBytes = 8 * 1024 * 1024
    private let approvalsOnly: Bool

    init(length: Int, approvalsOnly: Bool = false, read: @escaping (Int) throws -> Data) {
        remaining = length; readChunk = read; self.approvalsOnly = approvalsOnly
    }

    func decode() throws -> [String: Any] {
        guard let value = try value(.envelope, depth: 0) as? [String: Any] else {
            throw QuestionReplyError.protocolChanged
        }
        try whitespace()
        guard index == buffer.count, remaining == 0 else { throw QuestionReplyError.protocolChanged }
        return value
    }

    private func peek() throws -> UInt8? {
        if index == buffer.count, remaining > 0 {
            let count = min(65_536, remaining)
            buffer = Array(try readChunk(count)); index = 0; remaining -= count
            guard buffer.count == count else { throw QuestionReplyError.unavailable }
        }
        return index < buffer.count ? buffer[index] : nil
    }

    private func whitespace() throws {
        while let byte = try peek(), byte == 32 || byte == 10 || byte == 13 || byte == 9 { index += 1 }
    }

    private func expect(_ byte: UInt8) throws {
        try whitespace()
        guard try peek() == byte else { throw QuestionReplyError.protocolChanged }
        index += 1
    }

    // Copy contiguous spans, never one Data append per character. Ignored strings
    // are scanned without allocating their contents, even across chunk boundaries.
    private func string(keep: Bool) throws -> String? {
        try expect(34)
        var data = Data([34]), escaped = false
        while try peek() != nil {
            let start = index
            var ended = false
            while index < buffer.count {
                let byte = buffer[index]; index += 1
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { ended = true; break }
                else if byte < 32 { throw QuestionReplyError.protocolChanged }
            }
            if keep {
                if data.count + index - start > maximumStringBytes {
                    throw QuestionReplyError.historyTooLarge
                }
                data.append(contentsOf: buffer[start..<index])
            }
            if ended {
                guard keep else { return nil }
                retainedBytes += data.count
                guard retainedBytes <= maximumRetainedBytes else { throw QuestionReplyError.historyTooLarge }
                guard let text = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
                    throw QuestionReplyError.protocolChanged
                }
                return text
            }
        }
        throw QuestionReplyError.protocolChanged
    }

    private func field(_ key: String, in context: Context) -> Context? {
        switch context {
        case .raw: return .raw
        case .envelope:
            if key == "params" { return .params }
            return ["type", "method", "sourceClientId", "targetClientIds", "requestId", "resultType", "result", "error"].contains(key) ? .raw : nil
        case .params:
            if key == "change" { return .change }
            return ["conversationId", "hostId"].contains(key) ? .raw : nil
        case .change:
            if key == "conversationState" { return .state }
            return ["type", "revision"].contains(key) ? .raw : nil
        case .state:
            if ["turns", "turnHistory"].contains(key) { return .transcript }
            if approvalsOnly { return ["id", "requests"].contains(key) ? .raw : nil }
            return ["id", "cwd", "requests", "threadRuntimeStatus", "latestCollaborationMode"].contains(key) ? .raw : nil
        case .transcript:
            if key == "entitiesByKey" { return .entities }
            if ["turns", "turnHistory", "history", "items", "data"].contains(key) { return .transcript }
            if ["content", "input"].contains(key) { return approvalsOnly ? nil : .content }
            if key == "questions", approvalsOnly { return nil }
            return ["type", "id", "turnId", "questions", "status", "changes"].contains(key) ? .raw : nil
        case .entities: return .transcript
        case .content: return ["type", "text"].contains(key) ? .raw : nil
        }
    }

    private func value(_ context: Context?, depth: Int) throws -> Any? {
        guard depth <= 64 else { throw QuestionReplyError.historyTooLarge }
        try whitespace()
        guard let byte = try peek() else { throw QuestionReplyError.protocolChanged }
        if context != nil {
            nodes += 1
            guard nodes <= 100_000 else { throw QuestionReplyError.historyTooLarge }
        }
        switch byte {
        case 34: return try string(keep: context != nil)
        case 123:
            index += 1
            var object: [String: Any] = [:]
            try whitespace()
            if try peek() == 125 { index += 1; return context == nil ? nil : object }
            while true {
                let key = try string(keep: context != nil)
                try expect(58)
                let child = context.flatMap { field(key!, in: $0) }
                if let parsed = try value(child, depth: depth + 1), let key { object[key] = parsed }
                try whitespace()
                if try peek() == 125 { index += 1; break }
                try expect(44)
            }
            if context == .transcript, let type = object["type"] as? String {
                if !(approvalsOnly ? ["fileChange"] : ["agentMessage", "userMessage", "steeringUserMessage", "fileChange"]).contains(type) {
                    return nil
                }
                if type != "agentMessage" { object.removeValue(forKey: "questions") }
                if type != "userMessage" && type != "steeringUserMessage" {
                    object.removeValue(forKey: "content"); object.removeValue(forKey: "input")
                }
                if type != "fileChange" { object.removeValue(forKey: "changes") }
            }
            return context == nil || object.isEmpty ? nil : object
        case 91:
            index += 1
            var array: [Any] = []
            try whitespace()
            if try peek() == 93 { index += 1; return context == nil ? nil : array }
            while true {
                if let parsed = try value(context, depth: depth + 1) { array.append(parsed) }
                try whitespace()
                if try peek() == 93 { index += 1; break }
                try expect(44)
            }
            return context == nil ? nil : array
        default:
            var scalar: [UInt8] = []
            while let next = try peek(), next != 44 && next != 93 && next != 125 && next != 32 && next != 10 && next != 13 && next != 9 {
                guard scalar.count < 64 else { throw QuestionReplyError.protocolChanged }
                scalar.append(next); index += 1
            }
            guard !scalar.isEmpty else { throw QuestionReplyError.protocolChanged }
            let parsed = try JSONSerialization.jsonObject(with: Data(scalar), options: .fragmentsAllowed)
            return context == nil ? nil : parsed
        }
    }
}
