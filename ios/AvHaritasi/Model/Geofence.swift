import CoreLocation
import Foundation

/// Uygulama kapalıyken de yasak alana yaklaşınca uyarı (Core Location CLMonitor, iOS 17).
///
/// iOS en fazla 20 bölge izletir ve yalnızca daire kabul eder; yasak alanlar ise karmaşık
/// çokgenler. Bu yüzden "güvenli daire" yöntemi kullanılır: bulunduğunuz yerin çevresine,
/// en yakın yasak alana değmeyecek büyüklükte tek bir daire kurulur. Daireden çıkınca iOS
/// uygulamayı arka planda uyandırır; uygulama konumu alıp değerlendirir, gerekiyorsa bildirim
/// gönderir ve daireyi yeni konuma göre yeniden kurar. Sürekli GPS'e göre pil tüketimi çok azdır.
@MainActor
final class Geofence {
    static let identifier = "guvenli_daire"
    /// iOS bölge izlemesi ~100 m altında güvenilir değil.
    static let minRadius: CLLocationDistance = 120
    static let maxRadius: CLLocationDistance = 3_000

    private var monitor: CLMonitor?
    private var eventsTask: Task<Void, Never>?
    private(set) var armedCenter: CLLocation?
    private(set) var armedRadius: CLLocationDistance = 0

    /// Daireden çıkıldığında çağrılır.
    var onExit: (() -> Void)?

    /// Uygulama açılır açılmaz çağrılmalı: iOS, uyandırdığı uygulamaya olayı ancak aynı adla
    /// yeniden oluşturulan monitör üzerinden iletir.
    func start() async {
        guard monitor == nil else { return }
        let m = await CLMonitor("av_sinirlari")
        monitor = m
        eventsTask = Task { [weak self] in
            do {
                for try await event in await m.events where event.identifier == Self.identifier {
                    if event.state == .unsatisfied { self?.onExit?() }
                }
            } catch {}
        }
    }

    /// Daireyi `center` çevresine, en yakın yasak alana `distanceToForbidden` metre kalacak şekilde kur.
    func arm(at center: CLLocation, distanceToForbidden: CLLocationDistance?) async {
        guard let monitor else { return }
        // Yasak alana ~100 m kala uyanalım; içerideysek en küçük daire (çıkışı yakalamak için).
        let d = distanceToForbidden ?? Self.maxRadius
        let radius = min(Self.maxRadius, max(Self.minRadius, d - 100))
        // Gereksiz yeniden kurulumdan kaçın
        if let c = armedCenter, center.distance(from: c) < armedRadius * 0.3, abs(radius - armedRadius) < 50 { return }
        await monitor.remove(Self.identifier)
        let condition = CLMonitor.CircularGeographicCondition(center: center.coordinate, radius: radius)
        await monitor.add(condition, identifier: Self.identifier, assuming: .satisfied)
        armedCenter = center
        armedRadius = radius
    }

    func stop() async {
        guard let monitor else { return }
        await monitor.remove(Self.identifier)
        armedCenter = nil
        armedRadius = 0
    }
}
