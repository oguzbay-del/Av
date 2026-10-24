import Foundation

/// Haritadaki +/− düğmelerinin yönü.
enum MapZoomDirection: Equatable {
    case zoomIn
    case zoomOut
}

/// Harita temsilcisine iletilen tek seferlik yakınlaştırma isteği (MapFocus gibi: her dokunuş yeni kimlik).
struct MapZoomRequest: Equatable {
    let id = UUID()
    let direction: MapZoomDirection
}

/// Yakınlaştırma adımı: her dokunuş görünen alanı 2 kat büyütür/küçültür (saf mantık, birim testli).
enum MapZoomStep {
    /// Kamera uzaklığı üst sınırı: İstanbul'un tamamı (~200 km) görünür.
    static let maxDistance: Double = 200_000
    /// Her adımdaki çarpan.
    static let factor: Double = 2

    /// Bir sonraki kamera uzaklığı (metre). Sınır dışına taşmaz; sınırın ötesindeki
    /// uzaklık (ör. elle daha çok uzaklaşılmışsa) istenen yönün tersine sıçratılmaz.
    static func next(distance: Double, direction: MapZoomDirection, min lower: Double, max upper: Double) -> Double {
        let lo = Swift.max(0, Swift.min(lower, upper))
        let hi = Swift.max(lower, upper)
        guard distance.isFinite, distance > 0 else { return Swift.min(Swift.max(lo, 1), hi) }
        switch direction {
        case .zoomIn:
            guard distance > lo else { return distance }
            return Swift.max(distance / factor, lo)
        case .zoomOut:
            guard distance < hi else { return distance }
            return Swift.min(distance * factor, hi)
        }
    }
}
