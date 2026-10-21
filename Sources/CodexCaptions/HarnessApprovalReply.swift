import Foundation
import CaptionCore

enum HarnessApprovalError: LocalizedError {
    case unavailable, stale, uncertain
    var errorDescription: String? {
        switch self {
        case .unavailable: return "DSH 审批桥接未连接，请到 DSH 处理。"
        case .stale: return "当前桥接无法匹配这条申请；启用前发起的申请仍需到 DSH 处理。"
        case .uncertain: return "未确认处理结果，请先到 DSH 查看，避免重复提交。"
        }
    }
}

enum HarnessQuestionError: LocalizedError {
    case stale, uncertain, unavailable
    var errorDescription: String? {
        switch self {
        case .stale: return "这组提问已处理或发生变化，请到 DSH 查看。"
        case .uncertain: return "未确认回复结果，请先到 DSH 查看，避免重复提交。"
        case .unavailable: return "DSH 提问桥接未连接，请到 DSH 回复。"
        }
    }
}

/// One user click, one bounded connection. No idle discovery or polling.
final class HarnessApprovalReply {
    private let queue = DispatchQueue(label: "captions.dsh.approval", qos: .userInitiated)
    private var busy = false
    private let socketPath: String
    init(socketPath: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/vibecute/approval.sock").path) {
        self.socketPath = socketPath
    }
    func submitQuestion(sessionID: String, request: UserQuestionRequest, answers: [String:String],
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard !busy, request.externalQuestion, !request.questions.isEmpty,
              request.questions.allSatisfy({ !$0.multiSelect && $0.options.contains(answers[$0.id] ?? "") }) else {
            completion(.failure(QuestionReplyError.invalidAnswer)); return
        }
        let questions: [[String:Any]] = request.questions.map {
            ["id":$0.id, "question":$0.title, "options":zip($0.options,$0.descriptions).map { ["label":$0.0,"description":$0.1] }]
        }
        let batch: [[String:Any]] = request.questions.map { ["id":$0.id,"selected":[answers[$0.id]!]] }
        busy = true
        queue.async {
            var sent = false
            let result: Result<Void,Error>
            do {
                let connection = try CodexQuestionConnection(path:self.socketPath)
                connection.deadline = ProcessInfo.processInfo.systemUptime + 5
                sent = true
                let response = try connection.bridgeExchange(["version":1,"operation":"question-answer", "sessionID":sessionID,
                    "id":request.id,"questions":questions,"answers":batch])
                if response["status"] as? String == "stale" { throw HarnessQuestionError.stale }
                guard response["status"] as? String == "ok", response["id"] as? String == request.id else {
                    throw HarnessQuestionError.uncertain
                }
                result = .success(())
            } catch let error as QuestionReplyError { result = .failure(error) }
            catch let error as HarnessQuestionError { result = .failure(error) }
            catch { result = .failure(sent ? HarnessQuestionError.uncertain : HarnessQuestionError.unavailable) }
            DispatchQueue.main.async { self.busy = false; completion(result) }
        }
    }
    func submit(sessionID: String, request: UserQuestionRequest, choice: String,
                completion: @escaping (Result<Void, Error>) -> Void) {
        guard !busy, request.externalApproval, let content = request.approvalContent,
              ["允许本次", "拒绝"].contains(choice), !sessionID.isEmpty else {
            completion(.failure(HarnessApprovalError.unavailable)); return
        }
        busy = true
        queue.async {
            var sent = false
            let result: Result<Void, Error>
            do {
                let connection = try CodexQuestionConnection(path: self.socketPath)
                connection.deadline = ProcessInfo.processInfo.systemUptime + 5
                let tool = String(content.title.dropFirst("权限申请 · ".count))
                let outcome = choice == "允许本次" ? "allowed-once" : "rejected"
                sent = true
                let response = try connection.bridgeExchange(["version": 1, "sessionID": sessionID,
                    "id": request.id, "toolName": tool, "reason": content.reason, "outcome": outcome])
                guard response["status"] as? String != "stale" else { throw HarnessApprovalError.stale }
                guard response["status"] as? String == "ok", response["outcome"] as? String == outcome else {
                    throw HarnessApprovalError.uncertain
                }
                result = .success(())
            } catch let error as HarnessApprovalError { result = .failure(error) }
            catch { result = .failure(sent ? HarnessApprovalError.uncertain : HarnessApprovalError.unavailable) }
            DispatchQueue.main.async { self.busy = false; completion(result) }
        }
    }
}
