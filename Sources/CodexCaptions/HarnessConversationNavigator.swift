import AppKit

/// Exact-ID navigation through the installed DSH client; no title matching.
final class HarnessConversationNavigator {
    static let shared = HarnessConversationNavigator()
    private let queue = DispatchQueue(label: "captions.dsh.navigation", qos: .userInitiated)
    private var busy = false
    func open(sessionID: String, completion: ((String?) -> Void)? = nil) -> String? {
        guard !busy else { return "正在跳转，请稍候。" }
        guard sessionID.hasPrefix("session-"), UUID(uuidString: String(sessionID.dropFirst(8))) != nil else {
            return "无法识别这条 DSH 会话。"
        }
        busy = true
        queue.async {
            var message: String?
            do {
                let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/vibecute/approval.sock").path
                let connection = try CodexQuestionConnection(path: path)
                connection.deadline = ProcessInfo.processInfo.systemUptime + 4
                let result = try connection.bridgeExchange(["version": 1, "operation": "navigate", "sessionID": sessionID])
                if result["status"] as? String != "ok" || result["sessionID"] as? String != sessionID {
                    message = "DSH 未能切换到对应会话，请确认 DSH 已打开并加载字幕导航插件。"
                }
            } catch { message = "无法连接 DSH 会话导航，请打开 DSH 后重试。" }
            DispatchQueue.main.async {
                self.busy = false
                if message == nil, let url = URL(string: "dsh://open"), !NSWorkspace.shared.open(url) {
                    message = "会话已切换，但无法唤起 DSH 窗口。"
                }
                if let completion { completion(message) }
                else if let message { NSApp.presentError(NSError(domain: "DSHConversationNavigation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])) }
            }
        }
        return nil
    }
}
