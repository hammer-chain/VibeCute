import Foundation

/// Uses explicit desktop project membership, not the session's working folder:
/// projectless chats also have a cwd, and project labels can differ from paths.
public final class SessionProjectIndex {
    private let url: URL
    private var modificationDate: Date?
    private var fileSize: Int?
    private var assignments: [String: String] = [:]
    private var names: [String: String] = [:]
    private var projectless = Set<String>()

    public init(url: URL) { self.url = url }

    public func refresh() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            assignments.removeAll(); names.removeAll(); projectless.removeAll()
            modificationDate = nil; fileSize = nil
            return
        }
        let date = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.intValue
        guard date != modificationDate || size != fileSize else { return }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let memberships = state["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
        assignments = memberships.compactMapValues { $0["projectId"] as? String }
        let projects = state["local-projects"] as? [String: [String: Any]] ?? [:]
        names = projects.compactMapValues { entry in
            (entry["name"] as? String)?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        projectless = Set(state["projectless-thread-ids"] as? [String] ?? [])
        modificationDate = date; fileSize = size
    }

    public func name(for threadID: String) -> String {
        guard let projectID = id(for: threadID) else { return "" }
        return names[projectID] ?? ""
    }

    public func id(for threadID: String) -> String? {
        guard !projectless.contains(threadID) else { return nil }
        return assignments[threadID]
    }
}
