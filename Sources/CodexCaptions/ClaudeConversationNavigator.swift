import AppKit
import Darwin

/// Click-only terminal navigation: exact session IDs, never cwd/title guesses.
final class ClaudeConversationNavigator {
    static let shared = ClaudeConversationNavigator()
    private var process: Process?
    private var deadline: DispatchWorkItem?
    private var terminalBusy = false
    struct Target: Equatable { let workspace: String; let surface: String; let pid: Int }
    private struct Store: Decodable {
        struct Record: Decodable { let workspaceId: String; let surfaceId: String; let pid: Int }
        struct Active: Decodable { let sessionId: String }
        let sessions: [String: Record]
        let activeSessionsBySurface: [String: Active]
    }
    static func target(sessionID: String, data: Data) -> Target? {
        guard data.count <= 2_000_000, UUID(uuidString: sessionID) != nil,
              let store = try? JSONDecoder().decode(Store.self, from: data),
              let record = store.sessions[sessionID], record.pid > 0,
              store.activeSessionsBySurface[record.surfaceId]?.sessionId == sessionID,
              UUID(uuidString: record.workspaceId) != nil, UUID(uuidString: record.surfaceId) != nil else { return nil }
        return Target(workspace: record.workspaceId, surface: record.surfaceId, pid: record.pid)
    }
    private static func boundedRead(_ url: URL, limit: Int = 2_000_000) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
    func open(sessionID: String, completion: ((String?) -> Void)? = nil) -> String? {
        guard process == nil && !terminalBusy else { return "正在跳转，请稍候。" }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let data = Self.boundedRead(home.appendingPathComponent(".cmuxterm/claude-hook-sessions.json")),
              let target = Self.target(sessionID: sessionID, data: data),
              let live = Self.boundedRead(home.appendingPathComponent(".claude/sessions/\(target.pid).json")),
              let metadata = try? JSONSerialization.jsonObject(with: live) as? [String: Any],
              metadata["sessionId"] as? String == sessionID,
              metadata["pid"] as? Int == target.pid, kill(pid_t(target.pid), 0) == 0 else {
            return openTerminal(sessionID: sessionID, completion: completion)
        }
        return openCMUX(target: target, completion: completion)
    }
    func openCMUX(target: Target, completion: ((String?) -> Void)? = nil) -> String? {
        guard process == nil && !terminalBusy else { return "正在跳转，请稍候。" }
        let executable = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        guard FileManager.default.isExecutableFile(atPath: executable),
              let params = try? JSONSerialization.data(withJSONObject: ["workspace_id": target.workspace, "surface_id": target.surface]),
              let json = String(data: params, encoding: .utf8) else { return "无法使用 cmux 跳转接口。" }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["--json", "rpc", "surface.focus", json]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        process = child
        var timedOut = false
        child.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                self?.deadline?.cancel(); self?.deadline = nil; self?.process = nil
                let error = timedOut ? "跳转到 Claude 终端超时。" : (task.terminationStatus == 0 ? nil : "终端已关闭，或 cmux 拒绝了跳转。")
                if let completion { completion(error) }
                else if let error { NSApp.presentError(NSError(domain: "ClaudeConversationNavigation", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
            }
        }
        do { try child.run() } catch { process = nil; return "无法启动 cmux 跳转接口。" }
        let timeout = DispatchWorkItem { [weak child] in
            guard let child, child.isRunning else { return }
            timedOut = true; child.terminate()
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        return nil
    }
    struct TerminalTarget: Equatable { let pid: Int; let tty: String }
    private struct LiveSession: Decodable {
        let pid: Int
        let sessionId: String
        let startedAt: Double
    }
    static func terminalTarget(sessionID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> TerminalTarget? {
        guard UUID(uuidString: sessionID) != nil,
              let files = try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".claude/sessions"), includingPropertiesForKeys: nil),
              files.count <= 256 else { return nil }
        for file in files where file.pathExtension == "json" {
            guard let data = boundedRead(file, limit: 16_384), let live = try? JSONDecoder().decode(LiveSession.self, from: data),
                  live.sessionId == sessionID, live.pid > 0 else { continue }
            var info = proc_bsdinfo()
            guard proc_pidinfo(Int32(live.pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_start_tvsec > 0,
                  Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000 <= live.startedAt / 1000 + 1,
                  let name = devname(Int32(bitPattern: info.e_tdev), S_IFCHR) else { continue }
            let tty = String(cString: name)
            guard tty.hasPrefix("ttys"), tty.dropFirst(4).allSatisfy({ $0.isNumber }), tty.count <= 16 else { continue }
            return TerminalTarget(pid: live.pid, tty: "/dev/" + tty)
        }
        return nil
    }
    private func openTerminal(sessionID: String, completion: ((String?) -> Void)?) -> String? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty,
              let target = Self.terminalTarget(sessionID: sessionID) else {
            return "没有找到此 Claude 会话正在运行的 Terminal 或 cmux 终端。"
        }
        return openTerminalTarget(target, validate: { Self.terminalTarget(sessionID: sessionID) == target }, completion: completion)
    }
    func openTerminalTarget(_ target: TerminalTarget, validate: @escaping () -> Bool, completion: ((String?) -> Void)? = nil) -> String? {
        guard process == nil && !terminalBusy else { return "正在跳转，请稍候。" }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else { return "Terminal 未运行。" }
        terminalBusy = true
        // The device name above is constrained to /dev/ttys followed by digits.
        let source = """
        with timeout of 30 seconds
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(target.tty)" then
                            set selected tab of w to t
                            set miniaturized of w to false
                            set index of w to 1
                            activate
                            return (tty of selected tab of front window is "\(target.tty)")
                        end if
                    end repeat
                end repeat
                error "对应的 Terminal 窗口或标签页已关闭。"
            end tell
        end timeout
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var detail: NSDictionary?
            var failure: String?
            // Revalidate after scheduling, before sending an event to Terminal.
            if !validate() {
                failure = "会话已退出或更换终端。"
            } else if let script = NSAppleScript(source: source) {
                let result = script.executeAndReturnError(&detail)
                if detail?[NSAppleScript.errorNumber] as? Int == -1743 {
                    failure = "请在系统设置 → 隐私与安全性 → 自动化中允许VibeCute控制终端。"
                } else if detail != nil || !result.booleanValue {
                    failure = "无法聚焦对应的 Terminal 窗口或标签页。"
                }
            } else { failure = "无法创建 Terminal 跳转请求。" }
            DispatchQueue.main.async {
                self?.terminalBusy = false
                if let completion { completion(failure) }
                else if let failure { NSApp.presentError(NSError(domain: "ClaudeConversationNavigation", code: 2, userInfo: [NSLocalizedDescriptionKey: failure])) }
            }
        }
        return nil
    }

}
