import AppKit

struct RainCity: Codable, Equatable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let admin1: String?
    let country: String?
    var label: String { [name, admin1, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    var valid: Bool { latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 }
}

struct RainWeatherReading {
    let raining: Bool
    let date: Date
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -300 && age <= 1800
    }
}

enum RainWeatherError: Error { case invalidResponse, stale }

/// Open-Meteo's non-commercial endpoint. Only the selected city's coordinates
/// leave the device. No device location, conversation content, cookies or API key.
enum RainWeatherClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 2; config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 65_536 else {
            throw RainWeatherError.invalidResponse
        }
        return data
    }

    static func cities(named name: String) async throws -> [RainCity] {
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: String(name.prefix(100))),
            URLQueryItem(name: "count", value: "5"), URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "format", value: "json")]
        struct Response: Decodable { let results: [RainCity]? }
        return try JSONDecoder().decode(Response.self, from: await get(url.url!)).results?.filter(\.valid) ?? []
    }

    static func weather(for city: RainCity) async throws -> RainWeatherReading {
        guard city.valid else { throw RainWeatherError.invalidResponse }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(city.latitude)),
            URLQueryItem(name: "longitude", value: String(city.longitude)),
            URLQueryItem(name: "current", value: "weather_code,rain,showers"),
            URLQueryItem(name: "timeformat", value: "unixtime"), URLQueryItem(name: "forecast_days", value: "1")]
        return try decode(await get(url.url!))
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> RainWeatherReading {
        struct Current: Decodable { let time: Double; let weather_code: Int; let rain: Double; let showers: Double }
        struct Response: Decodable { let current: Current }
        let current = try JSONDecoder().decode(Response.self, from: data).current
        guard current.time.isFinite, current.rain.isFinite, current.showers.isFinite,
              current.rain >= 0, current.showers >= 0,
              [0,1,2,3,45,48,51,53,55,56,57,61,63,65,66,67,71,73,75,77,80,81,82,85,86,95,96,97,99].contains(current.weather_code) else {
            throw RainWeatherError.invalidResponse
        }
        // Current codes/amounts only. Snow/fog and forecast probabilities do not trigger rain.
        let rainCodes = [51,53,55,56,57,61,63,65,66,67,80,81,82,95,96,97,99]
        let reading = RainWeatherReading(raining: rainCodes.contains(current.weather_code) || current.rain + current.showers > 0,
                                         date: Date(timeIntervalSince1970: current.time))
        guard reading.isFresh(at: now) else { throw RainWeatherError.stale }
        return reading
    }
}

/// One request per 15 minutes, no overlap or stored history. Changing city or
/// turning off cancels work and invalidates late responses.
final class RainWeatherMonitor {
    static let interval: TimeInterval = 900
    var onChange: ((Bool, String) -> Void)?
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var city: RainCity?
    private var generation = 0
    private var lastAttempt = Date.distantPast
    private var reading: RainWeatherReading?
    private(set) var requestCount = 0
    private var wakeObserver: NSObjectProtocol?
    private let fetch: (RainCity) async throws -> RainWeatherReading

    init(fetch: @escaping (RainCity) async throws -> RainWeatherReading = RainWeatherClient.weather) {
        self.fetch = fetch
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    deinit {
        timer?.invalidate(); request?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func configure(city: RainCity?) {
        guard self.city != city else { return }
        self.city = city; generation += 1
        timer?.invalidate(); timer = nil; request?.cancel(); request = nil
        reading = nil; lastAttempt = .distantPast
        onChange?(false, city == nil ? "选择城市后启用自动天气" : "正在检测天气…")
        guard city?.valid == true else { return }
        refresh()
        let clock = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
        clock.tolerance = 15; RunLoop.main.add(clock, forMode: .common); timer = clock
    }

    func refresh(manual: Bool = false) {
        guard let city, city.valid else { return }
        if let reading, !reading.isFresh(at: Date()) {
            self.reading = nil; onChange?(false, "天气数据已过期 · 等待重新检测")
        }
        guard request == nil, Date().timeIntervalSince(lastAttempt) >= (manual ? 60 : Self.interval) else { return }
        lastAttempt = Date(); generation += 1; requestCount += 1
        let token = generation, fetch = self.fetch
        onChange?(reading?.raining ?? false, "正在检测 \(city.name) 的天气…")
        request = Task { @MainActor [weak self] in
            do {
                let reading = try await fetch(city)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                guard reading.isFresh(at: Date()) else { throw RainWeatherError.stale }
                self.reading = reading; self.request = nil
                let time = reading.date.formatted(date: .omitted, time: .shortened)
                self.onChange?(reading.raining, "\(city.name) · \(reading.raining ? "当前有雨 · 雨效开启" : "当前无雨 · 雨效待机") · \(time)")
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.reading = nil; self.request = nil
                self.onChange?(false, error as? RainWeatherError == .stale
                    ? "天气数据已过期 · 自动雨效暂停" : "天气检测失败 · 自动雨效暂停，15 分钟后重试")
            }
        }
    }

    var diagnostics: [String: Any] {
        ["enabled": city != nil, "requests": requestCount, "polling": timer != nil,
         "inFlight": request != nil, "raining": reading?.raining ?? false, "provider": "Open-Meteo"]
    }
}
