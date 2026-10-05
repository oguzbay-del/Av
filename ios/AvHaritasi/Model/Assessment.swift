import CoreLocation
import Foundation

/// Bir konumun avlanma açısından değerlendirmesi.
struct Assessment: Equatable {
    enum Level: Int, Comparable {
        case unknown = 0, safe, caution, danger
        static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }
    }

    let level: Level
    let title: String
    let detail: String
    let zone: ZoneClass?
    let nearestRestrictedDistance: Double?

    static let waiting = Assessment(level: .unknown, title: "Konum bekleniyor…",
                                    detail: "GPS sinyali alınıyor.", zone: nil, nearestRestrictedDistance: nil)

    static func evaluate(_ coordinate: CLLocationCoordinate2D,
                         accuracy: CLLocationAccuracy,
                         on map: HuntingMap,
                         buffer: Double) -> Assessment {
        guard let zone = map.zone(at: coordinate) else {
            return Assessment(level: .unknown, title: "Harita kapsamı dışında",
                              detail: "Bu konum \(map.meta.title) sınırları dışında. Bulunduğunuz ilin avlak haritasını kontrol edin.",
                              zone: nil, nearestRestrictedDistance: nil)
        }

        let acc = accuracy >= 0 ? accuracy : 0
        // GPS hatası kadar ek pay: gerçek konumunuz bu daire içinde herhangi bir yerde olabilir.
        let radius = min(buffer + acc, 5_000)
        let nearby = map.nearestRestricted(to: coordinate, within: radius)

        var notes: [String] = []
        if let nearby {
            notes.append("\(nearby.zone.name) sınırına yaklaşık \(Self.format(nearby.distance)).")
        }
        if acc > 50 {
            notes.append("GPS doğruluğu düşük (±\(Int(acc)) m).")
        }

        switch zone.status {
        case .yasak:
            return Assessment(level: .danger, title: "AVA YASAK: \(zone.name)",
                              detail: zone.description, zone: zone, nearestRestrictedDistance: 0)
        case .dikkat:
            return Assessment(level: .caution, title: zone.name,
                              detail: ([zone.description] + notes).joined(separator: " "),
                              zone: zone, nearestRestrictedDistance: nearby?.distance)
        case .disarida:
            return Assessment(level: .caution, title: "Avlak olarak işaretli değil",
                              detail: ([zone.description] + notes).joined(separator: " "),
                              zone: zone, nearestRestrictedDistance: nearby?.distance)
        case .izinli:
            if nearby != nil {
                return Assessment(level: .caution, title: "Yasak alana yakınsınız",
                                  detail: (notes + ["Şu an: \(zone.name)."]).joined(separator: " "),
                                  zone: zone, nearestRestrictedDistance: nearby?.distance)
            }
            if acc > buffer {
                return Assessment(level: .caution, title: zone.name,
                                  detail: (notes + ["Konum kesinleşene kadar dikkatli olun."]).joined(separator: " "),
                                  zone: zone, nearestRestrictedDistance: nil)
            }
            return Assessment(level: .safe, title: zone.name,
                              detail: "\(zone.description) En yakın yasak alan \(Int(buffer)) m'den uzakta.",
                              zone: zone, nearestRestrictedDistance: nil)
        }
    }

    static func format(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int((meters / 10).rounded()) * 10) m" }
        return String(format: "%.1f km", meters / 1000)
    }
}
