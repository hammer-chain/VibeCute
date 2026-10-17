import Foundation

/// Positive role identification precedes every body value read. The native
/// adapter supplies bounded AX access; fixtures exercise this same traversal.
public enum DoubaoVisibleContent {
    public struct Row<Element> {
        public let element: Element
        public let running: Bool
    }
    public struct Info {
        public let role: String
        public let label: String
        public let identifier: String
        public init(role: String, label: String = "", identifier: String = "") {
            self.role = role; self.label = label; self.identifier = identifier
        }
    }
    /// Chromium may expose decorative/virtualized wrappers that are absent
    /// from the visible AX tree. Search bounded structural nodes from the end
    /// of the document; only an explicit elapsed-work header or read-aloud footer qualifies.
    public static func latestRow<Element>(in document: Element, info: (Element) -> Info?,
                                           children: (Element, Bool) -> [Element]) -> Element? {
        latestActivity(in: document, info: info, children: children)?.element
    }
    public static func latestActivity<Element>(in document: Element, info: (Element) -> Info?,
                                               children: (Element, Bool) -> [Element]) -> Row<Element>? {
        var visited = 0
        func workHeader(_ element: Element, depth: Int) -> Bool {
            guard depth < 5, let node = info(element),
                  !["thinking", "reasoning", "cot"].contains(where: { node.identifier.lowercased().contains($0) }) else { return false }
            if node.role == "AXButton" { return node.label.hasPrefix("已处理") }
            guard node.role == "AXGroup", let first = children(element, false).first else { return false }
            return workHeader(first, depth: depth + 1)
        }
        func search(_ element: Element, depth: Int) -> Row<Element>? {
            guard depth < 10, visited < 96, let node = info(element),
                  ["AXGroup", "AXScrollArea", "AXList", "AXUnknown"].contains(node.role),
                  !["thinking", "reasoning", "cot"].contains(where: { node.identifier.lowercased().contains($0) }) else { return nil }
            visited += 1
            let first = children(element, false).prefix(16)
            // A one-child structural wrapper is not the message row. Resolve
            // its child before testing a nested header, so progress reads the
            // actual header/commentary/tool siblings rather than an ancestor.
            if first.count == 1, let child = first.first,
               let childNode = info(child), ["AXGroup", "AXScrollArea", "AXList", "AXUnknown"].contains(childNode.role) {
                return search(child, depth: depth + 1)
            }
            if first.first.map({ workHeader($0, depth: 0) }) == true { return Row(element: element, running: true) }
            if first.contains(where: { item in
                guard let control = info(item) else { return false }
                return control.role == "AXButton" && control.label == "朗读"
            }) { return Row(element: element, running: false) }
            for child in children(element, true).suffix(6).reversed() {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(document, depth: 0)
    }
    /// The running agent row has an explicit elapsed-work control, followed
    /// by public commentary and tool cards. Read only its newest six items.
    public static func progress<Element>(in row: Element, info: (Element) -> Info?,
                                         children: (Element, Bool) -> [Element], value: (Element) -> String?, includeTools: Bool = true) -> Caption? {
        let tools = ["正在读取", "已读取", "正在执行", "已执行", "正在搜索", "已搜索", "正在浏览", "已浏览", "正在运行", "已运行", "正在写入", "已写入", "正在编辑", "已编辑"]
        func toolTitle(_ element: Element, depth: Int) -> String? {
            guard depth < 8, let node = info(element),
                  !["thinking", "reasoning", "cot"].contains(where: { node.identifier.lowercased().contains($0) }) else { return nil }
            if node.role == "AXStaticText" {
                let text = String((value(element) ?? node.label).prefix(500))
                return tools.contains(where: text.hasPrefix) ? text : nil
            }
            guard node.role == "AXGroup" else { return nil }
            for item in children(element, false).prefix(4) {
                if let found = toolTitle(item, depth: depth + 1) { return found }
            }
            return nil
        }
        func commentaryText(_ element: Element, depth: Int = 0) -> String? {
            guard depth < 5, let node = info(element),
                  !["thinking", "reasoning", "cot"].contains(where: { node.identifier.lowercased().contains($0) }) else { return nil }
            if node.role == "AXStaticText" { return value(element) ?? node.label }
            guard node.role == "AXGroup" else { return nil }
            let parts = children(element, false)
            guard parts.count == 1, let first = parts.first else { return nil }
            return commentaryText(first, depth: depth + 1)
        }
        var commentary: String?, tool: String?
        for element in children(row, true).suffix(6) {
            if let prose = commentaryText(element) {
                let text = CaptionText.clean(String(prose.prefix(2_000)))
                if tools.contains(where: text.hasPrefix) { if includeTools { tool = text } }
                else if !text.isEmpty { commentary = text; tool = nil }
            } else if includeTools, let title = toolTitle(element, depth: 0) { tool = title }
        }
        if let tool { return Caption(text: [commentary, tool].compactMap { $0 }.joined(separator: "\n"), kind: .progress, date: Date()) }
        return commentary.map { Caption(text: $0, kind: .progress, date: Date()) }
    }
    public static func extract<Element>(rows: [Element], info: (Element) -> Info?,
                                        children: (Element) -> [Element], value: (Element) -> String?) -> String? {
        var remaining = 8_000
        let excluded = ["AXTextArea", "AXTextField", "AXButton", "AXPopUpButton", "AXLink", "AXImage", "AXTable"]
        let languages = Set(["markdown", "json", "python", "javascript", "typescript", "bash", "shell", "html", "svg", "css", "sql", "swift", "text", "plaintext", "xml", "yaml", "cpp", "c", "java"])
        func languageHeader(_ element: Element, depth: Int = 0) -> Bool {
            guard depth < 5, let node = info(element) else { return false }
            if node.role == "AXStaticText" {
                return languages.contains((value(element) ?? node.label).trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            guard node.role == "AXGroup" else { return false }
            return children(element).prefix(4).contains { languageHeader($0, depth: depth + 1) }
        }
        func body(_ element: Element, depth: Int) -> [String] {
            guard depth < 14, remaining > 0, let node = info(element),
                  !excluded.contains(node.role),
                  !["thinking", "reasoning", "cot"].contains(where: { node.identifier.lowercased().contains($0) }),
                  !node.label.hasPrefix("已思考"), !node.label.hasPrefix("思考过程") else { return [] }
            if node.role == "AXStaticText" {
                let text = String((value(element) ?? node.label).prefix(remaining))
                remaining -= text.count
                return text.isEmpty ? [] : [text]
            }
            let parts = children(element)
            // Doubao places the language header and code as two siblings;
            // following prose belongs to the reply, so keep that prose.
            if let header = parts.first, info(header)?.role == "AXGroup", languageHeader(header) {
                return parts.dropFirst(2).prefix(64).flatMap { body($0, depth: depth + 1) }
            }
            return parts.prefix(64).flatMap { body($0, depth: depth + 1) }
        }
        for row in rows.suffix(6).reversed() {
            let parts = children(row)
            guard parts.contains(where: { element in
                guard let node = info(element) else { return false }
                return node.role == "AXButton" && node.label == "朗读"
            }), let first = parts.first else { continue }
            return body(first, depth: 0).joined(separator: "\n")
        }
        return nil
    }
}
