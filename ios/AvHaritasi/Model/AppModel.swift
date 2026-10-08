import AudioToolbox
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Konum takibi, değerlendirme ve uyarılar.
/// Değerlendirme konum güncellemesinde (ve dakikada bir, saat kuralları için)
/// burada yapılır; böylece uygulama arka plandayken de uyarı verilebilir.
@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published private(set) var map: HuntingMap?
    @Published private(set) var features: MapFeatures?
    @Published private(set) var regs: Regulations?
    @Published private(set) var osm: OSMLayer?
    @Published private(set) var loadError: String?
    @Published private(set) var location: CLLocation?
    @Published private(set) var assessment: Assessment = .waiting
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var now = AppClock.now()
    @Published private(set) var weather: WeatherForecast?
    @Published private(set) var weatherError: String?
    let harvest = HarvestLog()
    /// Keskin vektör bölge çokgenleri (haritanın varsayılan görünümü).
    @Published private(set) var zoneShapes: [ZoneShapes] = []
    /// Haritayı bir noktaya götürme isteği (arama).
    @Published var focus: MapFocus?
    /// Bulunulan yerden 3 km içindeki en yakın ava yasak bölge (içindeyken nil).
    @Published private(set) var nearestForbidden: NearbyRestriction?

    /// Uzun basılarak haritada seçilen nokta.
    @Published var inspectedCoordinate: CLLocationCoordinate2D? {
        didSet { updateInspected() }
    }
    @Published private(set) var inspected: Assessment?

    @Published var bufferMeters: Double {
        didSet { UserDefaults.standard.set(bufferMeters, forKey: "bufferMeters"); reassess(); updateInspected() }
    }
    @Published var includeTimeRules: Bool {
        didSet { UserDefaults.standard.set(includeTimeRules, forKey: "includeTimeRules"); reassess() }
    }
    @Published var backgroundTracking: Bool {
        didSet { UserDefaults.standard.set(backgroundTracking, forKey: "backgroundTracking"); applyBackgroundMode() }
    }
    @Published var keepScreenOn: Bool {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn"); UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
    }

    /// Durum kilit ekranında (Live Activity / Apple Watch) gösterilsin mi.
    @Published var liveActivityEnabled: Bool {
        didSet { UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled"); updateLiveStatus() }
    }

    private let manager = CLLocationManager()
    private let weatherService = WeatherService()
    private let liveStatus = LiveStatus()
    private var weatherTask: Task<Void, Never>?
    private var lastAlertLevel: Assessment.Level = .unknown
    private var lastDangerAlert: Date = .distantPast
    private var timer: Timer?

    override init() {
        let d = UserDefaults.standard
        bufferMeters = d.object(forKey: "bufferMeters") as? Double ?? 300
        includeTimeRules = d.object(forKey: "includeTimeRules") as? Bool ?? true
        backgroundTracking = d.bool(forKey: "backgroundTracking")
        keepScreenOn = d.bool(forKey: "keepScreenOn")
        liveActivityEnabled = d.bool(forKey: "liveActivityEnabled")
        authorization = .notDetermined
        super.init()
        authorization = manager.authorizationStatus

        do {
            map = try HuntingMap(resourceName: "istanbul_2026_2027")
        } catch {
            loadError = error.localizedDescription
        }
        // Köy/yol vektörleri ve avlak birimleri 2024-25 GeoPDF'inden (2026-27 haritası taranmış görüntü).
        // Ek veriler yoksa uygulama yalnızca harita alanlarıyla çalışmaya devam eder.
        features = try? MapFeatures(resourceName: "istanbul_2024_2025")
        regs = try? Regulations.load()
        osm = try? OSMLayer()
        if let map { zoneShapes = ZoneVectors.load(for: map) }
        weather = weatherService.cached()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = AppClock.now()
                self?.reassess()
                self?.refreshWeatherIfNeeded()
            }
        }
    }

    var context: HuntContext? {
        guard let map else { return nil }
        return HuntContext(map: map, features: features, regs: regs, osm: osm)
    }

    var settings: EvaluationSettings {
        EvaluationSettings(warningBuffer: bufferMeters, includeTime: includeTimeRules)
    }

    /// Kural hesapları için kullanılacak nokta: konum yoksa harita merkezi.
    var referenceCoordinate: CLLocationCoordinate2D? {
        location?.coordinate ?? map?.center
    }

    func start() {
        refreshWeatherIfNeeded()
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

    private func applyBackgroundMode() {
        let authorized = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
        guard authorized else { return }
        manager.allowsBackgroundLocationUpdates = backgroundTracking
        manager.showsBackgroundLocationIndicator = backgroundTracking
        if backgroundTracking {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func updateInspected() {
        guard let c = inspectedCoordinate, let ctx = context else { inspected = nil; return }
        inspected = Assessment.evaluatePlace(c, context: ctx, settings: settings)
    }

    private func reassess() {
        guard let ctx = context, let location else { return }
        let new = Assessment.evaluate(location.coordinate, accuracy: location.horizontalAccuracy,
                                      at: AppClock.now(), context: ctx, settings: settings)
        assessment = new
        if let map, map.zone(at: location.coordinate)?.status != .yasak {
            nearestForbidden = map.nearest(to: location.coordinate, within: 3_000) { $0.status == .yasak }
        } else {
            nearestForbidden = nil
        }
        alertIfNeeded(new)
        updateLiveStatus()
    }

    // MARK: Hava durumu

    /// Şu anki saatin tahmini (rüzgâr kartı, koku konisi).
    var currentWeather: WeatherForecast.Hour? {
        guard let w = weather, let h = w.hour(at: now), abs(h.time.timeIntervalSince(now)) < 2 * 3600 else { return nil }
        return h
    }

    var windSummary: String? {
        currentWeather.map { "\(Compass.name($0.windFrom)) \(Int($0.windSpeed.rounded())) km/sa" }
    }

    /// 30 dakikada bir ya da 5 km'den fazla yer değişince yenile.
    func refreshWeatherIfNeeded(force: Bool = false) {
        guard let c = referenceCoordinate, weatherTask == nil else { return }
        if !force, let w = weather {
            let age = Date().timeIntervalSince(w.fetched)
            let moved = CLLocation(latitude: w.latitude, longitude: w.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if age < 30 * 60 && moved < 5_000 { return }
        }
        weatherTask = Task {
            do {
                weather = try await weatherService.fetch(for: c)
                weatherError = nil
            } catch {
                weatherError = "Hava durumu alınamadı: \(error.localizedDescription)"
            }
            weatherTask = nil
            updateLiveStatus()
        }
    }

    private func updateLiveStatus() {
        liveStatus.update(enabled: liveActivityEnabled, assessment: assessment, wind: windSummary)
    }

    /// Uyarılar yalnızca mekânsal duruma göre verilir (ör. Pazartesi günü sürekli
    /// "av günü değil" bildirimi gelmesin).
    private func alertIfNeeded(_ a: Assessment) {
        let level = a.placeLevel
        defer { lastAlertLevel = level }
        let worsened = level > lastAlertLevel && level >= .caution
        // Yasak noktada kalındıkça 2 dakikada bir hatırlat.
        let repeatDanger = level == .danger && Date().timeIntervalSince(lastDangerAlert) > 120
        guard worsened || repeatDanger else { return }
        if level == .danger { lastDangerAlert = Date() }

        let reason = a.checks.first { $0.kind == .place && $0.level == level }
        let title = (level == .danger ? "⛔️ " : "⚠️ ") + (reason?.title ?? a.title)
        let body = reason?.detail ?? a.detail

        UINotificationFeedbackGenerator().notificationOccurred(level == .danger ? .error : .warning)
        AudioServicesPlayAlertSound(level == .danger ? SystemSoundID(1005) : SystemSoundID(1007))

        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "zone-alert", content: content, trigger: nil))
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
            let first = self.location == nil
            self.location = last
            self.reassess()
            self.refreshWeatherIfNeeded(force: first && self.weather == nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
