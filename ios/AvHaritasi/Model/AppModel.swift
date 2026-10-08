import AudioToolbox
import Combine
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
    /// "Kesin Konum" kapalıysa iOS konumu km'lerce bulanıklaştırır; alan kararı verilemez.
    @Published private(set) var reducedAccuracy = false
    /// Pusula yönü (derece, gerçek kuzeye göre); pusula yoksa nil.
    @Published private(set) var heading: Double?
    /// Pusuda (hareketsiz) pil tasarrufu modu etkin mi.
    @Published private(set) var isStationary = false
    @Published private(set) var now = AppClock.now()
    @Published private(set) var weather: WeatherForecast?
    @Published private(set) var weatherError: String?
    let harvest = HarvestLog()
    let permits = PermitStore()
    let avlakAreas = AvlakAreas()
    /// Haritada vurgulanan avlak (izin belgesinden ya da elle seçim).
    @Published var highlightedAvlak: String? = UserDefaults.standard.string(forKey: "highlightedAvlak") {
        didSet { UserDefaults.standard.set(highlightedAvlak, forKey: "highlightedAvlak") }
    }
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

    /// Uygulama kapalıyken de yasak alana yaklaşınca bildirim (Core Location bölge izleme).
    @Published var geofenceAlerts: Bool {
        didSet {
            UserDefaults.standard.set(geofenceAlerts, forKey: "geofenceAlerts")
            if geofenceAlerts {
                manager.requestAlwaysAuthorization()
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            Task { await applyGeofence() }
        }
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
    private let geofence = Geofence()
    private var permitObserver: AnyCancellable?
    private var stillAnchor: CLLocation?

    override init() {
        let d = UserDefaults.standard
        bufferMeters = d.object(forKey: "bufferMeters") as? Double ?? 300
        includeTimeRules = d.object(forKey: "includeTimeRules") as? Bool ?? true
        backgroundTracking = d.bool(forKey: "backgroundTracking")
        keepScreenOn = d.bool(forKey: "keepScreenOn")
        liveActivityEnabled = d.bool(forKey: "liveActivityEnabled")
        geofenceAlerts = d.bool(forKey: "geofenceAlerts")
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
        manager.headingFilter = 3
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn

        // Bölge izleme olayları uygulama arka planda uyandırıldığında da gelir:
        // tek seferlik konum al, değerlendir (gerekirse bildirim), daireyi yeniden kur.
        geofence.onExit = { [weak self] in self?.manager.requestLocation() }
        if geofenceAlerts { Task { await geofence.start() } }
        permitObserver = permits.$permits.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reassess() }
        }

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
        return HuntContext(map: map, features: features, regs: regs, osm: osm, permits: permits.permits)
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
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
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

    /// Vurgulanan avlak ve sınırı.
    var highlighted: (avlak: Regulations.Avlak, area: AvlakAreas.Area?)? {
        guard let name = highlightedAvlak, let a = regs?.avlaklar.first(where: { $0.name == name }) else { return nil }
        return (a, avlakAreas.area(for: a))
    }

    /// Avlağı haritada vurgula ve ekrana sığdır.
    func showAvlak(_ name: String) {
        highlightedAvlak = name
        if let area = highlighted?.area {
            focus = MapFocus(coordinate: area.labelPoint, rect: area.boundingRect)
        }
    }

    /// "Kesin Konum" kapalıysa bir kerelik tam doğruluk iste (Info.plist: AvSinirKontrolu).
    func requestFullAccuracy() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "AvSinirKontrolu")
    }

    private func applyGeofence() async {
        guard geofenceAlerts else { await geofence.stop(); return }
        await geofence.start()
        if let location { await geofence.arm(at: location, distanceToForbidden: nearestForbidden?.distance ?? (insideForbidden ? 0 : nil)) }
    }

    private var insideForbidden: Bool {
        guard let map, let c = location?.coordinate else { return false }
        return map.zone(at: c)?.status == .yasak
    }

    /// Pusuda 3 dk kıpırdamadan beklerken, yasak alanlardan uzaktaysa GPS hassasiyetini düşür;
    /// 20 m hareket edince hemen tam hassasiyete dön.
    private func updatePowerMode(_ loc: CLLocation) {
        guard let anchor = stillAnchor, loc.distance(from: anchor) < 20 else {
            stillAnchor = loc
            if isStationary {
                isStationary = false
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.distanceFilter = 5
            }
            return
        }
        let farFromForbidden = !insideForbidden && (nearestForbidden?.distance ?? .infinity) > 600
        if !isStationary, farFromForbidden, loc.timestamp.timeIntervalSince(anchor.timestamp) > 180 {
            isStationary = true
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 15
        } else if isStationary, !farFromForbidden {
            isStationary = false
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 5
        }
    }

    private func updateInspected() {
        guard let c = inspectedCoordinate, let ctx = context else { inspected = nil; return }
        inspected = Assessment.evaluatePlace(c, context: ctx, settings: settings)
    }

    private func reassess() {
        guard let ctx = context, let location else { return }
        var new = Assessment.evaluate(location.coordinate, accuracy: location.horizontalAccuracy,
                                      at: AppClock.now(), context: ctx, settings: settings)
        if reducedAccuracy { new = .reducedAccuracy(location.horizontalAccuracy) }
        assessment = new
        if let map, map.zone(at: location.coordinate)?.status != .yasak {
            nearestForbidden = map.nearest(to: location.coordinate, within: 3_000) { $0.status == .yasak }
        } else {
            nearestForbidden = nil
        }
        alertIfNeeded(new)
        updateLiveStatus()
        if geofenceAlerts { Task { await applyGeofence() } }
    }

    // MARK: Hava durumu

    /// Şu anki saatin tahmini (rüzgâr kartı, koku konisi).
    var currentWeather: WeatherForecast.Hour? {
        guard let w = weather, let h = w.hour(at: now), abs(h.time.timeIntervalSince(now)) < 2 * 3600 else { return nil }
        return h
    }

    var windSummary: String? {
        currentWeather.map { L("%@ %@ km/sa", Compass.name($0.windFrom), String(Int($0.windSpeed.rounded()))) }
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
                weatherError = L("Hava durumu alınamadı: %@", error.localizedDescription)
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
        let sound: AppSound = level == .danger ? .yasak : .dikkat
        sound.alert()

        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound.notificationSound
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "zone-alert", content: content, trigger: nil))
        }
    }
}

extension AppModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
        Task { @MainActor in
            self.authorization = status
            self.reducedAccuracy = reduced
            self.reassess()
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
            self.updatePowerMode(last)
            self.refreshWeatherIfNeeded(force: first && self.weather == nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            if let old = self.heading, abs(((h - old + 540).truncatingRemainder(dividingBy: 360)) - 180) < 3 { return }
            self.heading = h
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
