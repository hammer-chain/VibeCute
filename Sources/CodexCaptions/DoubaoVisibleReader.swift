import AppKit
import ApplicationServices
import CaptionCore

/// Read-only AX adapter for the current Doubao Work window. Never opens a
/// conversation, types, clicks, enables browser debugging, or reads inputs.
final class DoubaoVisibleReader {
    private let tracker = DoubaoVisibleSession()
    private var application: AXUIElement?
    private var webArea: AXUIElement?
    private var editor: AXUIElement?
    private var controlsRoot: AXUIElement?
    private var processID: pid_t?
    private var sessionID = ""
    private var lastProcessScan = Date.distantPast
    private var nodes = 0
    private var serial = 0
    private var workControls: [String] = []
    private var elapsedMS = 0.0
    private var trusted = false
    private var phase = "等待豆包工作"
    private var cached: ([SessionSnapshot], String?) = ([], nil)
    private var lastPoll = -Double.infinity
    private var deadline = Double.infinity
    private var attributeReads = 0
    private var budgetExceeded = false
    private var windowElement: AXUIElement?
    private let diagnosticsLock = NSLock()
    private var latestDiagnostics: [String: Any] = [:]

    private var includesTools = true
    func setIncludesTools(_ enabled: Bool) {
        diagnosticsLock.lock(); includesTools = enabled; diagnosticsLock.unlock()
    }
    private var shouldIncludeTools: Bool {
        diagnosticsLock.lock(); defer { diagnosticsLock.unlock() }; return includesTools
    }
    var diagnostics: [String: Any] {
        diagnosticsLock.lock(); defer { diagnosticsLock.unlock() }
        return latestDiagnostics
    }
    private func withinBudget() -> Bool {
        if ProcessInfo.processInfo.systemUptime > deadline || nodes >= 384 {
            budgetExceeded = true; return false
        }
        return true
    }
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard withinBudget() else { return nil }
        attributeReads += 1
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func children(_ element: AXUIElement, limit: Int = 128, last: Bool = false) -> [AXUIElement] {
        guard withinBudget() else { return [] }
        attributeReads += 2
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else { return [] }
        var values: CFArray?
        guard count > 0, AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, last ? max(0, count - limit) : 0, min(count, limit), &values) == .success else { return [] }
        let result = values as? [AXUIElement] ?? []
        return result
    }
    private func childrenWindows(_ app: AXUIElement) -> [AXUIElement] {
        guard withinBudget() else { return [] }
        attributeReads += 1
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 16, &values) == .success else { return [] }
        return values as? [AXUIElement] ?? []
    }
    private typealias Node = DoubaoVisibleContent.Info
    private func info(_ element: AXUIElement) -> Node? {
        guard withinBudget() else { return nil }
        nodes += 1; attributeReads += 1
        let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
              let items = values as? [Any], items.count == 4 else { return nil }
        var label = (items[1] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? (items[2] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Disabled Chromium controls sometimes expose their visible label as
        // AXValue rather than title/description. Only read a button's label;
        // message values and hidden reasoning filters remain unchanged.
        if items[0] as? String == kAXButtonRole, label.isEmpty {
            label = (value(element, kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if items[0] as? String == kAXButtonRole, label.contains("处理") || label.contains("用时") {
            workControls.append(String(label.prefix(80)))
        }
        return Node(role: items[0] as? String ?? "", label: label, identifier: items[3] as? String ?? "")
    }
    private func url(_ element: AXUIElement) -> String {
        if let result = value(element, kAXURLAttribute) as? URL { return result.absoluteString }
        return value(element, kAXURLAttribute) as? String ?? ""
    }
    private func find(_ root: AXUIElement, skipDocument: Bool = false, match: (Node) -> Bool) -> AXUIElement? {
        var pending = [(root, 0)], index = 0
        let stopAt = min(384, nodes + 160)
        while index < pending.count && nodes < stopAt && withinBudget() {
            let (element, depth) = pending[index]; index += 1
            guard let node = info(element) else { continue }
            if match(node) { return element }
            if skipDocument && (node.label == "doc_editor" || node.identifier == "doc_editor") { continue }
            guard depth < 10, ![kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, kAXButtonRole, "AXLink", kAXMenuRole].contains(node.role) else { continue }
            pending += children(element).prefix(24).map { ($0, depth + 1) }
        }
        return nil
    }
    func poll() -> ([SessionSnapshot], String?) {
        let start = ProcessInfo.processInfo.systemUptime
        guard start - lastPoll >= 1.3 else { return cached }
        lastPoll = start; deadline = start + (editor == nil ? 0.8 : 0.25)
        nodes = 0; workControls = []; attributeReads = 0; budgetExceeded = false; serial += 1
        let result = read()
        elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        diagnosticsLock.lock()
        latestDiagnostics = ["pollSerial": serial, "pollMs": elapsedMS, "nodeReads": nodes,
            "attributeReads": attributeReads, "trusted": trusted, "phase": phase,
            "workControls": workControls, "budgetExceeded": budgetExceeded, "processID": processID as Any? ?? NSNull(), "conversationID": sessionID]
        diagnosticsLock.unlock()
        cached = budgetExceeded ? ([], "豆包工作：读取暂时超时，下一轮重试。") : result
        return cached
    }

    private func read() -> ([SessionSnapshot], String?) {
        trusted = AXIsProcessTrusted()
        guard trusted else {
            tracker.reset(); phase = "需要辅助功能权限"
            return ([], "豆包工作：请在系统设置 → 隐私与安全性 → 辅助功能中允许“VibeCute”。")
        }
        if Date().timeIntervalSince(lastProcessScan) > 8 {
            lastProcessScan = Date()
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.work.pc.doubao").first
            if running?.processIdentifier != processID {
                processID = running?.processIdentifier; webArea = nil; editor = nil; controlsRoot = nil; windowElement = nil; sessionID = ""; tracker.reset()
                application = processID.map { AXUIElementCreateApplication($0) }
                if let application { AXUIElementSetMessagingTimeout(application, 0.08) }
            }
        }
        guard let application else { phase = "等待豆包工作"; return ([], nil) }
        let windows = childrenWindows(application)
        func isChatWindow(_ element: AXUIElement) -> Bool {
            let title = value(element, kAXTitleAttribute) as? String ?? ""
            return title == "豆包工作" || title.hasSuffix(" - 豆包工作")
        }
        let focused = value(application, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        guard let window = focused.flatMap({ isChatWindow($0) ? $0 : nil })
                ?? windows.first(where: isChatWindow) else {
            phase = "等待对话窗口"; tracker.reset(); webArea = nil; editor = nil; controlsRoot = nil; windowElement = nil
            return ([], nil)
        }
        if windowElement.map({ !CFEqual($0, window) }) ?? true { webArea = nil; editor = nil; controlsRoot = nil; windowElement = window }
        if webArea == nil { webArea = find(window) { $0.role == "AXWebArea" } }
        guard let webArea else { phase = "无法识别对话页面"; return ([], nil) }
        let location = url(webArea)
        let prefix = "chrome://doubaowork-chat/chat/"
        guard location.hasPrefix(prefix), !location.dropFirst(prefix.count).isEmpty,
              location.dropFirst(prefix.count).utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            sessionID = ""; self.webArea = nil; editor = nil; controlsRoot = nil; tracker.reset(); phase = "等待打开对话"; return ([], nil)
        }
        let id = String(location.dropFirst(prefix.count))
        if id != sessionID { sessionID = id; editor = nil; controlsRoot = nil; tracker.reset() }
        if let editor, value(editor, kAXRoleAttribute) == nil { self.editor = nil; controlsRoot = nil }
        if editor == nil { editor = find(webArea) { $0.label == "doc_editor" || $0.identifier == "doc_editor" } }
        guard let editor else { phase = "等待对话内容"; return ([], nil) }
        if controlsRoot == nil { controlsRoot = value(editor, kAXParentAttribute).map { $0 as! AXUIElement } }
        let title = (value(window, kAXTitleAttribute) as? String ?? "豆包工作").replacingOccurrences(of: " - 豆包工作", with: "")
        // The controls live outside the historical message list.
        let stopControl = find(controlsRoot ?? webArea, skipDocument: true) { $0.role == kAXButtonRole && ["停止生成", "停止回答", "停止任务", "停止"].contains($0.label) } != nil
        let row = DoubaoVisibleContent.latestActivity(in: editor, info: info,
            children: { self.children($0, limit: $1 ? 6 : 16, last: $1) })
        let generating = stopControl || row?.running == true
        let progress = row.flatMap { $0.running ? DoubaoVisibleContent.progress(in: $0.element, info: info,
            children: { self.children($0, limit: $1 ? 6 : 16, last: $1) },
            value: { self.value($0, kAXValueAttribute) as? String }, includeTools: shouldIncludeTools) : nil }
        let text = DoubaoVisibleContent.extract(rows: generating ? [] : row.map { [$0.element] } ?? [], info: info,
            children: { self.children($0) }, value: { self.value($0, kAXValueAttribute) as? String })
        guard !budgetExceeded else { phase = "读取超时，等待重试"; return ([], nil) }
        phase = generating ? "当前对话运行中" : text == nil ? "等待可识别的助手回复" : "已读取当前助手回复"
        let snapshot = tracker.update(id: id, title: title, assistantText: generating ? nil : text, progressText: progress?.text, generating: generating)
        return (snapshot.map { [$0] } ?? [], nil)
    }
}
