import AudioToolbox
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Konum takibi, bölge değerlendirmesi ve uyarılar.
/// Değerlendirme konum güncellemesi geldiğinde burada yapılır; böylece uygulama
/// arka plandayken de (takip açıksa) uyarı verilebilir.
@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published private(set) var map: HuntingMap?
    @Published private(set) var loadError: String?
    @Published private(set) var location: CLLocation?
    @Published private(set) var assessment: Assessment = .waiting
    @Published private(set) var authorization: CLAuthorizationStatus

    /// Uzun basılarak haritada seçilen nokta.
    @Published var inspectedCoordinate: CLLocationCoordinate2D?

    @Published var bufferMeters: Double {
        didSet { UserDefaults.standard.set(bufferMeters, forKey: "bufferMeters"); reassess() }
    }
    @Published var backgroundTracking: Bool {
        didSet { UserDefaults.standard.set(backgroundTracking, forKey: "backgroundTracking"); applyBackgroundMode() }
    }
    @Published var keepScreenOn: Bool {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn"); UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
    }

    private let manager = CLLocationManager()
    private var lastAlertLevel: Assessment.Level = .unknown
    private var lastDangerAlert: Date = .distantPast

    override init() {
        let d = UserDefaults.standard
        bufferMeters = d.object(forKey: "bufferMeters") as? Double ?? 300
        backgroundTracking = d.bool(forKey: "backgroundTracking")
        keepScreenOn = d.bool(forKey: "keepScreenOn")
        authorization = .notDetermined
        super.init()
        authorization = manager.authorizationStatus

        do {
            map = try HuntingMap(resourceName: "istanbul_2024_2025")
        } catch {
            loadError = error.localizedDescription
        }

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            applyBackgroundMode()
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    var inspectedZone: ZoneClass? {
        guard let c = inspectedCoordinate else { return nil }
        return map?.zone(at: c)
    }

    private func applyBackgroundMode() {
        let authorized = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
        guard authorized else { return }
        manager.allowsBackgroundLocationUpdates = backgroundTracking
        manager.showsBackgroundLocationIndicator = backgroundTracking
        if backgroundTracking {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func reassess() {
        guard let map, let location else { return }
        let new = Assessment.evaluate(location.coordinate, accuracy: location.horizontalAccuracy,
                                      on: map, buffer: bufferMeters)
        assessment = new
        alertIfNeeded(new)
    }

    private func alertIfNeeded(_ a: Assessment) {
        defer { lastAlertLevel = a.level }
        let worsened = a.level > lastAlertLevel && a.level >= .caution
        // Yasak alanda kalındıkça 2 dakikada bir hatırlat.
        let repeatDanger = a.level == .danger && Date().timeIntervalSince(lastDangerAlert) > 120
        guard worsened || repeatDanger else { return }
        if a.level == .danger { lastDangerAlert = Date() }

        let haptic = UINotificationFeedbackGenerator()
        haptic.notificationOccurred(a.level == .danger ? .error : .warning)
        AudioServicesPlayAlertSound(a.level == .danger ? SystemSoundID(1005) : SystemSoundID(1007))

        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = a.level == .danger ? "⛔️ \(a.title)" : "⚠️ \(a.title)"
            content.body = a.detail
            content.sound = .default
            let req = UNNotificationRequest(identifier: "zone-alert", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }
}

extension AppModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            // Çok eski ya da geçersiz ölçümleri yok say.
            guard last.horizontalAccuracy >= 0, abs(last.timestamp.timeIntervalSinceNow) < 30 else { return }
            self.location = last
            self.reassess()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
