import CoreLocation
import Foundation

/// GPS hassasiyet kademeleri (Apple: gereken en düşük hassasiyeti kullan). Yan etkisiz;
/// `CLLocationManager` ayarlarını `AppModel` uygular.
/// - pusu: 3 dk 20 m içinde hareketsiz ve yasak alanlardan 600 m+ uzak → 10 m / 15 m filtre
/// - uzak: en yakın yasak alan 1,5 km'den uzak → 10 m / 20 m filtre
/// - yakın: tam hassasiyet / 5 m filtre (sınıra yaklaşırken gecikme olmasın)
struct PowerModePolicy {
    /// Bu yarıçap içinde kalan ölçümler "hareketsiz" sayılır.
    static let stillRadius: CLLocationDistance = 20
    /// Pusu kademesine geçmek için gereken hareketsizlik süresi.
    static let stillDuration: TimeInterval = 180
    /// Pusu kademesi yalnızca yasak alana bundan uzakken.
    static let stationaryMinDistance: CLLocationDistance = 600
    /// Düşük hassasiyet kademesi yalnızca yasak alana bundan uzakken.
    static let lowPowerMinDistance: CLLocationDistance = 1_500
    /// Bu kadar sessizlikten sonra mesafe filtresi kaldırılıp taze ölçüm istenir.
    static let quietAfter: TimeInterval = 45
    /// Son konum bu kadar saniyeden eskiyse değerlendirme "güncel değil" olur.
    static let staleAfter: TimeInterval = 90

    struct Settings: Equatable {
        let isStationary: Bool
        let lowPowerTier: Bool
        let desiredAccuracy: CLLocationAccuracy
        let distanceFilter: CLLocationDistance
    }

    /// Hareketsizlik ölçümünün başladığı konum.
    private(set) var stillAnchor: CLLocation?
    private(set) var isStationary = false

    init(stillAnchor: CLLocation? = nil, isStationary: Bool = false) {
        self.stillAnchor = stillAnchor
        self.isStationary = isStationary
    }

    /// Yasak alana uzaklık: içindeyken 0, yakında yoksa sonsuz.
    static func distanceToForbidden(nearest: CLLocationDistance?, inside: Bool) -> CLLocationDistance {
        inside ? 0 : (nearest ?? .infinity)
    }

    /// Yeni ölçümle kademeyi güncelle.
    mutating func update(with loc: CLLocation, nearestForbidden: CLLocationDistance?, insideForbidden: Bool) -> Settings {
        let dist = Self.distanceToForbidden(nearest: nearestForbidden, inside: insideForbidden)
        if let anchor = stillAnchor, loc.distance(from: anchor) < Self.stillRadius {
            if !isStationary, dist > Self.stationaryMinDistance,
               loc.timestamp.timeIntervalSince(anchor.timestamp) > Self.stillDuration {
                isStationary = true
            } else if isStationary, dist <= Self.stationaryMinDistance {
                isStationary = false
            }
        } else {
            stillAnchor = loc
            isStationary = false
        }
        let lowPowerTier = !isStationary && dist > Self.lowPowerMinDistance
        let accuracy = isStationary || lowPowerTier ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
        let filter: CLLocationDistance = isStationary ? 15 : (lowPowerTier ? 20 : 5)
        return Settings(isStationary: isStationary, lowPowerTier: lowPowerTier,
                        desiredAccuracy: accuracy, distanceFilter: filter)
    }

    /// Hareketsizken mesafe filtresi yüzünden konum gelmez; 45 sn sessizlikte taze ölçüm istenmeli mi.
    static func shouldRequestFreshFix(lastFix: Date?, now: Date) -> Bool {
        guard let lastFix else { return false }
        return now.timeIntervalSince(lastFix) > quietAfter
    }

    /// Konum yaşı "güncel değil" eşiğini aştı mı.
    static func isStale(age: TimeInterval) -> Bool {
        age > staleAfter
    }
}
