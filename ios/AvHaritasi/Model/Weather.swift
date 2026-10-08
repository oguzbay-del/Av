import CoreLocation
import Foundation

/// Open-Meteo saatlik tahmini (ücretsiz, API anahtarı gerekmez).
/// https://open-meteo.com — veri © Open-Meteo, CC BY 4.0
struct WeatherForecast: Codable, Equatable {
    struct Hour: Codable, Equatable, Identifiable {
        var id: Date { time }
        let time: Date
        let temperature: Double        // °C
        let windSpeed: Double          // km/sa
        let windGusts: Double          // km/sa
        let windFrom: Double           // derece; rüzgârın GELDİĞİ yön (meteorolojik)
        let pressure: Double           // hPa (yüzey)
        let precipitationChance: Double // %
        let cloudCover: Double          // %
    }

    let latitude: Double
    let longitude: Double
    let fetched: Date
    let hours: [Hour]

    /// `date`e en yakın saat.
    func hour(at date: Date) -> Hour? {
        hours.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    /// Son 3 saatteki basınç değişimi (hPa). Pozitif = yükseliyor.
    func pressureTrend(at date: Date) -> Double? {
        guard let now = hour(at: date),
              let before = hour(at: date.addingTimeInterval(-3 * 3600)), before.time != now.time else { return nil }
        return now.pressure - before.pressure
    }

    func upcoming(from date: Date, count: Int) -> [Hour] {
        Array(hours.filter { $0.time >= date.addingTimeInterval(-1800) }.prefix(count))
    }
}

enum Compass {
    static func name(_ degrees: Double) -> String {
        let names = AppLocale.isEnglish
            ? ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
            : ["K", "KKD", "KD", "DKD", "D", "DGD", "GD", "GGD", "G", "GGB", "GB", "BGB", "B", "BKB", "KB", "KKB"]
        let i = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
        return names[i]
    }

    /// Türkçe rüzgâr adı (yaklaşık, 8 yön).
    static func windName(from degrees: Double) -> String {
        let names = AppLocale.isEnglish
            ? ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"]
            : ["Yıldız (K)", "Poyraz (KD)", "Gündoğusu (D)", "Keşişleme (GD)",
               "Kıble (G)", "Lodos (GB)", "Günbatısı (B)", "Karayel (KB)"]
        let i = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return names[i]
    }
}

final class WeatherService {
    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("hava.json")
    }()

    /// Diskteki son tahmin (internet yokken de gösterilir).
    func cached() -> WeatherForecast? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(WeatherForecast.self, from: data)
    }

    func fetch(for c: CLLocationCoordinate2D) async throws -> WeatherForecast {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", c.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", c.longitude)),
            .init(name: "hourly", value: "temperature_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,surface_pressure,precipitation_probability,cloud_cover"),
            .init(name: "wind_speed_unit", value: "kmh"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "past_hours", value: "6"),
            .init(name: "forecast_days", value: "3"),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct Raw: Decodable {
            struct Hourly: Decodable {
                let time: [Double]
                let temperature_2m: [Double?]
                let wind_speed_10m: [Double?]
                let wind_gusts_10m: [Double?]
                let wind_direction_10m: [Double?]
                let surface_pressure: [Double?]
                let precipitation_probability: [Double?]
                let cloud_cover: [Double?]
            }
            let hourly: Hourly
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let h = raw.hourly
        var hours: [WeatherForecast.Hour] = []
        for i in h.time.indices {
            guard let t = h.temperature_2m[safe: i] ?? nil, let ws = h.wind_speed_10m[safe: i] ?? nil,
                  let wd = h.wind_direction_10m[safe: i] ?? nil, let p = h.surface_pressure[safe: i] ?? nil else { continue }
            hours.append(.init(time: Date(timeIntervalSince1970: h.time[i]), temperature: t, windSpeed: ws,
                               windGusts: (h.wind_gusts_10m[safe: i] ?? nil) ?? ws, windFrom: wd, pressure: p,
                               precipitationChance: (h.precipitation_probability[safe: i] ?? nil) ?? 0,
                               cloudCover: (h.cloud_cover[safe: i] ?? nil) ?? 0))
        }
        let forecast = WeatherForecast(latitude: c.latitude, longitude: c.longitude, fetched: Date(), hours: hours)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(forecast).write(to: cacheURL, options: .atomic)
        return forecast
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Koku konisi: kokunun rüzgârla taşındığı yön (rüzgâr altı).
enum ScentCone {
    static func polygon(from c: CLLocationCoordinate2D, windFrom: Double, windSpeed: Double) -> [CLLocationCoordinate2D] {
        let toward = (windFrom + 180).truncatingRemainder(dividingBy: 360)
        // Hızlı rüzgârda koku uzağa ama dar taşınır; hafif rüzgârda yayılır.
        let length = min(1_000, max(300, 200 + windSpeed * 40))
        let halfAngle = windSpeed < 6 ? 40.0 : (windSpeed < 15 ? 28.0 : 18.0)
        let proj = LocalProjection(c)
        var pts = [c]
        for k in 0...8 {
            let a = (toward - halfAngle + Double(k) * halfAngle / 4) * .pi / 180
            let dx = sin(a) * length, dy = cos(a) * length
            pts.append(CLLocationCoordinate2D(latitude: c.latitude + dy / proj.mPerDegLat,
                                              longitude: c.longitude + dx / proj.mPerDegLon))
        }
        return pts
    }
}
