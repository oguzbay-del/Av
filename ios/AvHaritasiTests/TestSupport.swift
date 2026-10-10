import CoreLocation
import Foundation
@testable import AvHaritasi

struct TestDataError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Testlerde ortak veri: uygulama paketindeki gerçek harita, öğe, MAK ve OSM dosyaları
/// (testler uygulama içinde koşar; `Bundle.main` = AvHaritasi.app).
enum TestData {
    private static let loaded: Result<HuntContext, Error> = Result {
        let map = try HuntingMap(resourceName: "istanbul_2026_2027")
        let features = try MapFeatures(resourceName: "istanbul_2024_2025")
        let regs = try Regulations.load()
        let osm = try OSMLayer()
        return HuntContext(map: map, features: features, regs: regs, osm: osm)
    }

    static func context() throws -> HuntContext { try loaded.get() }

    static func regs() throws -> Regulations {
        guard let r = try context().regs else { throw TestDataError(message: "MAK verisi yok") }
        return r
    }

    /// İstanbul saatiyle tarih: "2026-10-07T09:30".
    static func istanbul(_ s: String) -> Date {
        guard let d = ISO8601DateFormatter().date(from: s + ":00+03:00") else { fatalError("Geçersiz tarih: \(s)") }
        return d
    }
}

/// Bilinen noktalar (ios/TestData/GPX/README.md, docs/saha_test_protokolu.md).
enum Points {
    /// Senaryo 01 başlangıcı: Sarıkavak tarafı devlet avlağı, ava yasak alan sınırına ~800 m.
    static let sarikavakStart = CLLocationCoordinate2D(latitude: 41.02446, longitude: 29.65804)
    /// Senaryo 01 en derin nokta: Ava Yasak Alan sınırının ~199 m içi.
    static let avaYasakDeep = CLLocationCoordinate2D(latitude: 41.01971, longitude: 29.64790)
    /// Senaryo 06: Şile devlet avlağı, yasaklardan > 3 km.
    static let sileQuiet = CLLocationCoordinate2D(latitude: 41.10000, longitude: 29.53000)
    /// Senaryo 03: Dereli köy noktasının ~90 m güneybatısı.
    static let nearDereli = CLLocationCoordinate2D(latitude: 41.06880, longitude: 29.64870)
    /// Harita dışı (Ankara).
    static let ankara = CLLocationCoordinate2D(latitude: 39.92, longitude: 32.85)

    /// Başarım ölçümü için 20 nokta: senaryo izleri + il genelinde farklı ortamlar
    /// (orman, köy yakını, korunan alan kıyısı, şehir merkezi).
    static let benchmark: [CLLocationCoordinate2D] = [
        (41.02446, 29.65804), (41.02066, 29.64993), (41.01971, 29.64790), (41.03182, 29.63986),
        (41.04014, 29.62140), (41.06162, 29.64336), (41.06880, 29.64870), (41.11797, 29.34740),
        (41.11518, 29.35688), (41.10000, 29.53000), (41.18000, 28.98000), (41.30000, 28.40000),
        (41.12000, 28.20000), (41.13000, 29.85000), (41.24000, 29.02000), (41.12000, 29.20000),
        (41.01000, 28.97000), (41.17670, 29.61308), (40.95000, 29.40000), (41.45000, 28.60000),
    ].map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
}
