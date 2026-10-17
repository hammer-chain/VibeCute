import Foundation

/// Only authoritative desktop pending requests are approvals. Tool arguments,
/// automatic reviews and historical permission items are never promoted.
public struct CodexApproval: Equatable, Sendable {
    public let threadID: String
    public let requestID: Data
    public let params: Data
    public let method: String
    public let question: UserQuestionRequest
    public let responses: [Data]
    public let fileDetail: Data?
    public var key: String { threadID + ":" + question.id }

    public static func json(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
    public static func parse(threadID: String, row: [String: Any], state: [String: Any] = [:]) -> Self? {
        guard let method = row["method"] as? String,
              ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "mcpServer/elicitation/request"].contains(method),
              row["completed"] as? Bool != true,
              let values = row["params"] as? [String: Any], values["threadId"] as? String == threadID,
              let turn = values["turnId"] as? String, !turn.isEmpty,
              let id = row["id"], id is String || id is NSNumber,
              let idData = json(id), let params = json(values), params.count <= 65_536 else { return nil }
        var title = "", options: [String] = [], descriptions: [String] = [], responses: [Data] = []
        var fileDetail: Data?
        func choice(_ label: String, _ explanation: String, _ response: Any) {
            guard let data = json(response) else { return }
            options.append(label); descriptions.append(explanation); responses.append(data)
        }
        func encoded(_ value: Any) -> String { json(value).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        let elicitation = method == "mcpServer/elicitation/request"
        let reason = (elicitation ? values["message"] : values["reason"]) as? String ?? "未提供原因"
        if elicitation {
            let meta = values["_meta"] as? [String: Any] ?? [:]
            title = "工具权限审批\n" + reason
            for (key, label) in [("connector_name", "应用"), ("tool_title", "操作"), ("origin", "目标网站"), ("file_transfer", "文件传输")] {
                if let value = meta[key] as? String { title += "\n" + label + "：" + value }
            }
            title += "\n服务：" + (values["serverName"] as? String ?? "未知")
            if let params = meta["tool_params"] { title += "\n操作参数：" + encoded(params) }
            let schema = values["requestedSchema"] as? [String: Any] ?? [:]
            // Desktop tool consent is identified by its protocol and empty
            // form, independent of the connector. Input forms stay in Codex.
            let toolConsent = values["mode"] as? String == "form"
                && meta["codex_approval_kind"] as? String == "mcp_tool_call"
                && schema["type"] as? String == "object"
                && (schema["properties"] as? [String: Any])?.isEmpty == true
                && (schema["required"] as? [String] ?? []).isEmpty
                && Set(schema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties"])
            if toolConsent {
                choice("允许本次", "仅允许上方操作。", ["action": "accept", "content": [:]] as [String: Any])
                let scopes = meta["persist"] as? [String] ?? []
                if scopes.contains("session") {
                    choice("本会话允许", "当前会话内记住这项授权。", ["action": "accept", "content": [:], "_meta": ["persist": "session"]] as [String: Any])
                }
                if scopes.contains("always") {
                    choice("始终允许", "持续记住这项授权，影响后续匹配的操作。", ["action": "accept", "content": [:], "_meta": ["persist": "always"]] as [String: Any])
                }
            } else {
                title += "\n请在 Codex 中填写或确认此请求。"
                if let schema = values["requestedSchema"] { title += "\n请求表单：" + encoded(schema) }
            }
        } else if method == "item/commandExecution/requestApproval" {
            let command = values["command"] as? String ?? (values["commandActions"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }.joined(separator: "\n")
            title = "执行审批\n" + reason + "\n\n命令：\n" + (command.isEmpty ? "未提供命令，请在 Codex 查看" : command)
            if let kind = values["kind"] as? String, kind != "command" { title += "\n操作类型：" + kind }
            if let cwd = values["cwd"] as? String { title += "\n工作目录：" + cwd }
            if let environment = values["environmentId"] as? String { title += "\n执行环境：" + environment }
            if let network = values["networkApprovalContext"], !(network is NSNull) { title += "\n网络请求：" + encoded(network) }
            if !command.isEmpty {
                choice("允许本次", "仅批准当前请求。", "accept")
                choice("本会话允许", "后续命中相同会话审批缓存的请求可直接运行。", "acceptForSession")
                if let prefix = values["proposedExecpolicyAmendment"] as? [String], !prefix.isEmpty,
                   let data = json(prefix), data.count <= 4_096 {
                    choice("保存命令规则", "保存以下命令前缀的审批规则，之后匹配的命令可直接运行：\n" + encoded(prefix),
                           ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": prefix]])
                }
            }
            if !command.isEmpty, let amendments = values["proposedNetworkPolicyAmendments"] as? [[String: Any]], amendments.count <= 4 {
                for amendment in amendments {
                    guard let action = amendment["action"] as? String, ["allow", "deny"].contains(action),
                          let host = amendment["host"] as? String, host.utf8.count <= 512 else { continue }
                    choice("保存网络规则：" + (action == "allow" ? "允许 " : "拒绝 ") + host,
                           "保存后会影响对该主机的后续访问：\n" + encoded(amendment),
                           ["applyNetworkPolicyAmendment": ["network_policy_amendment": amendment]])
                }
            }
        } else if method == "item/fileChange/requestApproval" {
            title = "文件修改审批\n" + reason
            if let root = values["grantRoot"] as? String { title += "\n请求写入范围：" + root }
            if let itemID = values["itemId"] as? String, let item = fileItem(id: itemID, turnID: turn, state: state),
               let data = json(item["changes"] ?? []), data.count <= 24_000,
               let changes = item["changes"] as? [[String: Any]], !changes.isEmpty {
                fileDetail = data
                for change in changes {
                    let kind = (change["kind"] as? [String: Any])?["type"] as? String ?? ""
                    title += "\n\n" + (change["path"] as? String ?? "未知路径") + "\n"
                        + (["add": "新增文件", "delete": "删除文件", "update": "更新文件"][kind] ?? encoded(change["kind"] ?? "修改"))
                    if let diff = change["diff"] as? String { title += "\n" + diff }
                }
                choice("允许本次", values["grantRoot"] as? String == nil ? "批准上方所列文件修改。"
                    : "批准上方文件修改及该请求的写入范围。", "accept")
                choice("本会话允许", "后续对相同文件的修改可直接运行。", "acceptForSession")
            } else { title += "\n文件详情未完整加载，请在 Codex 查看后批准。" }
        } else {
            guard let permissions = values["permissions"] as? [String: Any], !permissions.isEmpty else { return nil }
            title = "权限审批\n" + reason + "\n\n申请的权限："
            if let network = permissions["network"] as? [String: Any] {
                title += "\n网络：" + (network["enabled"] as? Bool == true ? "允许联网" : encoded(network))
                if network.keys.contains(where: { $0 != "enabled" }) { title += "\n其他网络权限：" + encoded(network) }
            } else if let network = permissions["network"], !(network is NSNull) {
                title += "\n网络：" + encoded(network)
            }
            if let files = permissions["fileSystem"] as? [String: Any] {
                for key in ["read", "write"] {
                    if let paths = files[key] as? [String] { title += "\n" + (key == "read" ? "读取：" : "写入：") + paths.joined(separator: "\n") }
                }
                if let entries = files["entries"] as? [[String: Any]] {
                    for entry in entries {
                        let path = entry["path"] as? [String: Any] ?? [:]
                        let location = path["path"] as? String ?? path["pattern"] as? String ?? encoded(path)
                        let access = entry["access"] as? String ?? ""
                        title += "\n" + (["read": "读取", "write": "写入", "deny": "禁止"][access] ?? access) + "：" + location
                        let unknown = entry.filter { !["access", "path"].contains($0.key) }
                        if !unknown.isEmpty { title += "\n其他路径权限：" + encoded(unknown) }
                    }
                }
                if let depth = files["globScanMaxDepth"] { title += "\n路径扫描深度：" + encoded(depth) }
                let unknown = files.filter { !["read", "write", "entries", "globScanMaxDepth"].contains($0.key) }
                if !unknown.isEmpty { title += "\n其他文件权限：" + encoded(unknown) }
            } else if let files = permissions["fileSystem"], !(files is NSNull) { title += "\n文件权限：" + encoded(files) }
            let otherPermissions = permissions.filter { !["network", "fileSystem"].contains($0.key) }
            if !otherPermissions.isEmpty { title += "\n其他申请权限：" + encoded(otherPermissions) }
            if let cwd = values["cwd"] as? String { title += "\n工作目录：" + cwd }
            choice("允许本轮", "只授予上方申请的权限，当前轮次结束后失效。", ["permissions": permissions, "scope": "turn"])
            choice("本会话允许", "上方权限在当前会话内持续有效。", ["permissions": permissions, "scope": "session"])
        }
        choice("拒绝", "不授予请求的权限，Codex 可以继续处理任务。", elicitation ? ["action": "decline"] as [String: Any] : method == "item/permissions/requestApproval" ? ["permissions": [:], "scope": "turn"] as [String: Any] : "decline")
        // Oversized content must never hide the scope of an approval.
        guard title.utf8.count <= 32_768 else { return nil }
        let started = (values["startedAtMs"] as? NSNumber)?.doubleValue ?? 0
        let requestKey = "approval:" + String(decoding: idData, as: UTF8.self) + ":" + turn + ":" + String(started)
        guard var question = UserQuestionRequest.parse(id: requestKey, turnID: turn, asynchronous: false,
            questions: [["id": requestKey, "question": title, "options": zip(options, descriptions).map { ["label": $0, "description": $1] }]],
            date: Date(timeIntervalSince1970: started / 1000)) else { return nil }
        question.approval = true
        let heading = title.components(separatedBy: "\n")[0]
        let prefix = heading + "\n" + reason
        question.approvalContent = ApprovalContent(title: heading, reason: reason,
            details: String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        return Self(threadID: threadID, requestID: idData, params: params, method: method,
                    question: question, responses: responses, fileDetail: fileDetail)
    }
    public static func fileItem(id: String, turnID: String, state: [String: Any]) -> [String: Any]? {
        var visited = 0
        func visit(_ value: Any) -> [String: Any]? {
            visited += 1; guard visited <= 50_000 else { return nil }
            if let rows = value as? [Any] { for row in rows { if let result = visit(row) { return result } }; return nil }
            guard let row = value as? [String: Any] else { return nil }
            if row["type"] as? String == "fileChange", row["id"] as? String == id { return row }
            if let currentTurn = row["turnId"] as? String, currentTurn != turnID { return nil }
            for key in ["turns", "turnHistory", "history", "entitiesByKey", "items", "data"] {
                if let value = row[key] {
                    if key == "entitiesByKey", let entities = value as? [String: Any] {
                        for item in entities.values { if let result = visit(item) { return result } }
                    } else if let result = visit(value) { return result }
                }
            }
            return nil
        }
        return visit(state)
    }
}
