import AppKit
@main struct RainWeatherLive {
    static func main() async throws {
        let cities = try await RainWeatherClient.cities(named: "Beijing, China")
        guard let city = cities.first(where: { $0.id == 1816670 }) else { fatalError("Beijing identity missing") }
        let start = Date()
        let reading = try await RainWeatherClient.weather(for: city)
        let report: [String: Any] = ["city": city.label, "provider": "Open-Meteo", "raining": reading.raining,
            "weatherTime": ISO8601DateFormatter().string(from: reading.date),
            "requestSeconds": Date().timeIntervalSince(start), "fresh": reading.isFresh(at: Date()), "weatherRequests": 1]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "output/desktop-rain/live-weather.json"))
        print("Beijing live city search and current-weather request passed")
    }
}
