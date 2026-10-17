import AppKit
import Darwin

/// Exact, click-only lookup of the route registered by the OpenCode TUI plugin.
enum OpenCodeConversationNavigator {
    struct Record: Codable, Equatable {
        let version: Int
        let sessionID: String
        let pid: Int
        let processStart: Double
        let workspace: String?
        let surface: String?
    }
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexCaptions/OpenCodeNavigation")
    static func decode(_ data: Data, sessionID: String) -> Record? {
        guard data.count <= 4096, sessionID.hasPrefix("ses_"), sessionID.count <= 100,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
              record.sessionID == sessionID, record.pid > 0, record.pid <= Int32.max,
              record.processStart.isFinite else { return nil }
        return record
    }
    static func tty(_ record: Record) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(Int32(record.pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              abs(Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000 - record.processStart) < 2,
              let name = devname(Int32(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let tty = String(cString: name)
        guard tty.hasPrefix("ttys"), tty.count <= 16, !tty.dropFirst(4).isEmpty,
              tty.dropFirst(4).allSatisfy({ $0.isNumber }) else { return nil }
        return "/dev/" + tty
    }
    static func find(sessionID: String, directory: URL = root) -> Record? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), files.count <= 256 else { return nil }
        var matches: [Record] = []
        for file in files where file.pathExtension == "json" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = try? handle.read(upToCount: 4097); try? handle.close()
            if let data, let record = decode(data, sessionID: sessionID), file.lastPathComponent == "\(record.pid).json", tty(record) != nil { matches.append(record) }
        }
        // Opening one conversation in two terminals is ambiguous; never choose arbitrarily.
        return matches.count == 1 ? matches[0] : nil
    }
    static func open(sessionID: String, completion: ((String?) -> Void)? = nil) -> String? {
        guard let record = find(sessionID: sessionID), let tty = tty(record) else {
            return "未找到唯一的 OpenCode 终端。请加载字幕导航插件后重新打开此会话。"
        }
        let navigator = ClaudeConversationNavigator.shared
        if let workspace = record.workspace, let surface = record.surface,
           UUID(uuidString: workspace) != nil, UUID(uuidString: surface) != nil {
            return navigator.openCMUX(target: .init(workspace: workspace, surface: surface, pid: record.pid), completion: completion)
        }
        return navigator.openTerminalTarget(.init(pid: record.pid, tty: tty), validate: {
            find(sessionID: sessionID) == record
        }, completion: completion)
    }
}
