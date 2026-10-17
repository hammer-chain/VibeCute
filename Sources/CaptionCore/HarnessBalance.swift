import Foundation

public struct HarnessAccountGrant: Equatable {
    let token: String
    /// Reads only the account grant in Harness's small local YAML credential store.
    /// API keys and the browser connection secret are never used.
    public static func parse(_ data: Data) -> HarnessAccountGrant? {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else { return nil }
        var inRecords = false, inAccount = false, inPayload = false
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 { inRecords = trimmed == "records:"; inAccount = false; inPayload = false }
            else if inRecords && indent == 2 {
                inAccount = trimmed == "deepseek-account-platform/default:"; inPayload = false
            } else if inAccount, let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon])
                let raw = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if indent == 4 {
                    inPayload = key == "payload"
                    if key == "kind" { fields[key] = scalar(raw) }
                } else if indent == 6 && inPayload && ["version", "token", "issuer"].contains(key) {
                    guard fields[key] == nil else { return nil }
                    fields[key] = scalar(raw)
                }
            }
        }
        guard fields["kind"] == "grant", fields["version"] == "1",
              fields["issuer"] == "https://platform.deepseek.com", let token = fields["token"],
              !token.isEmpty, token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { return nil }
        return HarnessAccountGrant(token: token)
    }
    private static func scalar(_ text: String) -> String? {
        if text.hasPrefix("\"") { return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) as? String }
        if text.hasPrefix("'") && text.hasSuffix("'") { return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return text
    }
    static func read(_ url: URL) -> HarnessAccountGrant? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 65_537) else { return nil }
        return parse(data)
    }
}

public enum HarnessBalance {
    public static func displayText(_ data: Data) -> String? {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] as? Int == 0, let envelope = object["data"] as? [String: Any],
              envelope["biz_code"] as? Int == 0, let value = envelope["biz_data"] as? [String: Any],
              let normal = wallets(value["normal_wallets"]), let bonus = wallets(value["bonus_wallets"], omitZero: true),
              !normal.isEmpty else { return nil }
        let paid = normal.map { $0 }.joined(separator: " · ")
        let gifts = bonus.isEmpty ? "" : " · 赠送 " + bonus.joined(separator: " · ")
        return "账户余额 " + paid + gifts
    }
    /// Exact paid CNY balance only. Bonus wallets never affect alert eligibility.
    public static func normalCNY(_ data: Data) -> Decimal? {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] as? Int == 0, let envelope = object["data"] as? [String: Any],
              envelope["biz_code"] as? Int == 0, let value = envelope["biz_data"] as? [String: Any],
              let rows = value["normal_wallets"] as? [[String: Any]], wallets(rows) != nil else { return nil }
        let amounts = rows.filter { $0["currency"] as? String == "CNY" }.compactMap {
            ($0["balance"] as? String).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        }
        guard !amounts.isEmpty else { return nil }
        let result = amounts.reduce(Decimal.zero, +)
        return result.isNaN ? nil : result
    }

    public static func isLow(normalCNY: Decimal?, threshold: Double) -> Bool {
        guard let normalCNY, !normalCNY.isNaN, threshold.isFinite, threshold >= 0,
              let limit = Decimal(string: String(threshold), locale: Locale(identifier: "en_US_POSIX")) else { return false }
        return normalCNY < limit
    }

    private static func wallets(_ value: Any?, omitZero: Bool = false) -> [String]? {
        guard let rows = value as? [[String: Any]], rows.count <= 8 else { return nil }
        var texts: [String] = []
        for row in rows {
            guard let currency = row["currency"] as? String, ["CNY", "USD"].contains(currency),
                  let text = row["balance"] as? String, text.count <= 128,
                  text.range(of: "^-?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
                  let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else { return nil }
            if omitZero && amount == 0 { continue }
            let symbol = currency == "CNY" ? "¥" : "$"
            var value = amount, rounded = Decimal()
            NSDecimalRound(&rounded, &value, 2, .down)
            if amount != 0 && rounded == 0 {
                texts.append(amount > 0 ? symbol + "<0.01" : "-" + symbol + "0.01")
            } else {
                let formatter = NumberFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
                let magnitude = NSDecimalNumber(decimal: rounded < 0 ? -rounded : rounded)
                guard let formatted = formatter.string(from: magnitude) else { return nil }
                texts.append((rounded < 0 ? "-" : "") + symbol + formatted)
            }
        }
        return texts
    }
}

/// One finite read per hover, with a bounded response and no redirects or automatic retries.
public final class HarnessBalanceQuery: NSObject, URLSessionDataDelegate {
    private let credentialsURL: URL
    private let grant: HarnessAccountGrant
    private let completion: (String, Decimal?) -> Void
    private var bytes = Data()
    private var accepted = false
    private var session: URLSession?
    private init(credentialsURL: URL, grant: HarnessAccountGrant, completion: @escaping (String, Decimal?) -> Void) {
        self.credentialsURL = credentialsURL; self.grant = grant; self.completion = completion
    }
    public static func fetch(credentialsURL: URL, completion: @escaping (String) -> Void) {
        fetchBalance(credentialsURL: credentialsURL) { text, _ in completion(text) }
    }
    public static func fetchBalance(credentialsURL: URL, completion: @escaping (String, Decimal?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let grant = HarnessAccountGrant.read(credentialsURL) else {
                DispatchQueue.main.async { completion("账户余额不可用 · 请登录 Harness", nil) }; return
            }
            let query = HarnessBalanceQuery(credentialsURL: credentialsURL, grant: grant, completion: completion)
            query.start()
        }
    }
    private func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!)
        request.setValue(grant.token, forHTTPHeaderField: "x-dsh-auth-token")
        request.setValue("", forHTTPHeaderField: "x-client-bundle-id")
        request.setValue("desktop-mac", forHTTPHeaderField: "x-client-platform")
        request.setValue("1.0", forHTTPHeaderField: "x-client-version")
        request.setValue("zh_CN", forHTTPHeaderField: "x-client-locale")
        request.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "x-client-timezone-offset")
        session?.dataTask(with: request).resume()
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        accepted = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= 65_536
        completionHandler(accepted ? .allow : .cancel)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 65_536 else { accepted = false; dataTask.cancel(); return }
        bytes.append(data)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let sameAccount = HarnessAccountGrant.read(credentialsURL) == grant
        let text = sameAccount && accepted && error == nil ? HarnessBalance.displayText(bytes) : nil
        let normal = text == nil ? nil : HarnessBalance.normalCNY(bytes)
        bytes.removeAll(); session.finishTasksAndInvalidate(); self.session = nil
        DispatchQueue.main.async { self.completion(text ?? "账户余额查询失败", normal) }
    }
}
