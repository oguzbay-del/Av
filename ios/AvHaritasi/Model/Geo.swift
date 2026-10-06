import CoreLocation
import Foundation

/// Küçük alanlarda metre cinsinden düzlem yaklaşık izdüşümü (eşdikdörtgen).
struct LocalProjection {
    let lat0: Double
    let lon0: Double
    let mPerDegLat = 110_540.0
    let mPerDegLon: Double

    init(_ origin: CLLocationCoordinate2D) {
        lat0 = origin.latitude
        lon0 = origin.longitude
        mPerDegLon = 111_320 * cos(origin.latitude * .pi / 180)
    }

    func xy(_ lat: Double, _ lon: Double) -> (x: Double, y: Double) {
        ((lon - lon0) * mPerDegLon, (lat - lat0) * mPerDegLat)
    }

    /// Verilen metre yarıçapına karşılık gelen derece payları.
    func degrees(for meters: Double) -> (lat: Double, lon: Double) {
        (meters / mPerDegLat, meters / mPerDegLon)
    }
}

enum Geo {
    /// Orijindeki (0,0) noktanın [a,b] doğru parçasına uzaklığı.
    static func distanceToSegment(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        var t = len2 > 0 ? -(a.x * dx + a.y * dy) / len2 : 0
        t = min(1, max(0, t))
        let px = a.x + t * dx, py = a.y + t * dy
        return (px * px + py * py).squareRoot()
    }

    /// Nokta-çokgen içerme testi (ışın atma); çokgen [enlem, boylam] çiftleri.
    static func contains(_ polygon: [[Double]], _ c: CLLocationCoordinate2D) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let yi = polygon[i][0], xi = polygon[i][1]
            let yj = polygon[j][0], xj = polygon[j][1]
            if (yi > c.latitude) != (yj > c.latitude),
               c.longitude < (xj - xi) * (c.latitude - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Noktanın çokgen kenarına en kısa uzaklığı (metre).
    static func distanceToBoundary(_ polygon: [[Double]], _ c: CLLocationCoordinate2D) -> Double {
        let proj = LocalProjection(c)
        var best = Double.infinity
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = proj.xy(polygon[j][0], polygon[j][1])
            let b = proj.xy(polygon[i][0], polygon[i][1])
            best = min(best, distanceToSegment(a, b))
            j = i
        }
        return best
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1000 { return "\(max(0, Int((meters / 10).rounded()) * 10)) m" }
        return String(format: "%.1f km", meters / 1000)
    }
}
