import AudioToolbox
import Combine
import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications

/// Konum takibi, değerlendirme ve uyarılar.
/// Değerlendirme konum güncellemesinde (ve dakikada bir, saat kuralları için)
/// burada yapılır; böylece uygulama arka plandayken de uyarı verilebilir.
@MainActor
@Observable
final class AppModel: NSObject {
    private(set) var map: HuntingMap?
    private(set) var features: MapFeatures?
    private(set) var regs: Regulations?
    private(set) var osm: OSMLayer?
    private(set) var loadError: String?
    private(set) var location: CLLocation?
    private(set) var assessment: Assessment = .waiting
    private(set) var authorization: CLAuthorizationStatus
    /// "Kesin Konum" kapalıysa iOS konumu km'lerce bulanıklaştırır; alan kararı verilemez.
    private(set) var reducedAccuracy = false
    /// Pusula yönü (derece, gerçek kuzeye göre); pusula yoksa nil.
    private(set) var heading: Double?
    /// Pusuda (hareketsiz) pil tasarrufu modu etkin mi.
    private(set) var isStationary = false
    /// Yasak alanlardan 1,5 km'den uzakta düşük hassasiyet kademesi etkin mi.
    private(set) var lowPowerTier = false
    /// Bildirim izni (nil: henüz bilinmiyor).
    private(set) var notificationsAllowed: Bool?
    /// Kurulu "güvenli daire" yarıçapı (kapalıyken uyarı açıksa).
    private(set) var geofenceRadius: Double?
    private(set) var now = AppClock.now()
    private(set) var weather: WeatherForecast?
    private(set) var weatherError: String?
    let harvest = HarvestLog()
    let permits = PermitStore()
    let tracks = TrackLog()
    let avlakAreas = AvlakAreas()
    /// Haritada vurgulanan avlak (izin belgesinden ya da elle seçim).
    var highlightedAvlak: String? = UserDefaults.standard.string(forKey: "highlightedAvlak") {
        didSet { UserDefaults.standard.set(highlightedAvlak, forKey: "highlightedAvlak") }
    }
    /// Keskin vektör bölge çokgenleri (haritanın varsayılan görünümü).
    private(set) var zoneShapes: [ZoneShapes] = []
    /// Haritayı bir noktaya götürme isteği (arama).
    var focus: MapFocus?
    /// Bulunulan yerden 3 km içindeki en yakın ava yasak bölge (içindeyken nil).
    private(set) var nearestForbidden: NearbyRestriction?

    /// Uzun basılarak haritada seçilen nokta.
    var inspectedCoordinate: CLLocationCoordinate2D? {
        didSet { updateInspected() }
    }
    private(set) var inspected: Assessment?

    var bufferMeters: Double {
        didSet { UserDefaults.standard.set(bufferMeters, forKey: "bufferMeters"); reassess(); updateInspected() }
    }
    var includeTimeRules: Bool {
        didSet { UserDefaults.standard.set(includeTimeRules, forKey: "includeTimeRules"); reassess() }
    }
    var backgroundTracking: Bool {
        didSet { UserDefaults.standard.set(backgroundTracking, forKey: "backgroundTracking"); applyBackgroundMode() }
    }
    var keepScreenOn: Bool {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn"); UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
    }

    /// Uygulama kapalıyken de yasak alana yaklaşınca bildirim (Core Location bölge izleme).
    var geofenceAlerts: Bool {
        didSet {
            UserDefaults.standard.set(geofenceAlerts, forKey: "geofenceAlerts")
            if geofenceAlerts {
                manager.requestAlwaysAuthorization()
                requestNotifications()
            }
            Task { await applyGeofence() }
        }
    }

    /// Durum kilit ekranında (Live Activity / Apple Watch) gösterilsin mi.
    var liveActivityEnabled: Bool {
        didSet { UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled"); updateLiveStatus() }
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let weatherService = WeatherService()
    @ObservationIgnored private let liveStatus = LiveStatus()
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var lastAlertLevel: Assessment.Level = .unknown
    @ObservationIgnored private var lastDangerAlert: Date = .distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let geofence = Geofence()
    @ObservationIgnored private var permitObserver: AnyCancellable?
    /// Arka plan konum oturumu (iOS 17+): sürekli takip açıkken iOS'un güncellemeleri kesmemesi için.
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    /// iOS 18 hizmet oturumu (uygulama açıkken konum yetkisini etkin tutar).
    @ObservationIgnored private var serviceSession: AnyObject?
    @ObservationIgnored private var lastGeofenceCheck: (CLLocation, Date)?
    @ObservationIgnored private var stillAnchor: CLLocation?

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
            // İzin açılışta bağlamsız sorulmaz: önce açıklama ekranı (DisclaimerView 2. adım) ya da haritadaki şerit
            break
        case .authorizedWhenInUse, .authorizedAlways:
            applyBackgroundMode()
            if #available(iOS 18.0, *), serviceSession == nil {
                serviceSession = CLServiceSession(authorization: .whenInUse)
            }
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
            // Oturum ön plandayken başlatılmalı; referans tutuldukça arka planda güncellemeler sürer
            if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
            requestNotifications()
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
    }

    /// Bildirim iznini tek yerden iste ve durumu güncelle.
    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshSystemStatus() }
        }
    }

    /// Uygulama öne gelince: bildirim izni gibi sistem durumlarını yenile.
    func refreshSystemStatus() {
        Task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            notificationsAllowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                || s.authorizationStatus == .ephemeral
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

    /// Kullanıcı açıklamayı okuyup "Konumu etkinleştir"e bastığında.
    func requestLocationPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// "Kesin Konum" kapalıysa bir kerelik tam doğruluk iste (Info.plist: AvSinirKontrolu).
    func requestFullAccuracy() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "AvSinirKontrolu")
    }

    private func applyGeofence() async {
        guard geofenceAlerts else { await geofence.stop(); geofenceRadius = nil; return }
        await geofence.start()
        if let location { await geofence.arm(at: location, distanceToForbidden: nearestForbidden?.distance ?? (insideForbidden ? 0 : nil)) }
        geofenceRadius = geofence.armedRadius > 0 ? geofence.armedRadius : nil
    }

    private var insideForbidden: Bool {
        guard let map, let c = location?.coordinate else { return false }
        return map.zone(at: c)?.status == .yasak
    }

    /// GPS hassasiyet kademeleri (Apple: gereken en düşük hassasiyeti kullan):
    /// - pusu: 3 dk 20 m içinde hareketsiz ve yasak alanlardan 600 m+ uzak → 10 m / 15 m filtre
    /// - uzak: en yakın yasak alan 1,5 km'den uzak → 10 m / 20 m filtre
    /// - yakın: tam hassasiyet / 5 m filtre (sınıra yaklaşırken gecikme olmasın)
    private func updatePowerMode(_ loc: CLLocation) {
        let dist = insideForbidden ? 0 : (nearestForbidden?.distance ?? .infinity)
        if let anchor = stillAnchor, loc.distance(from: anchor) < 20 {
            if !isStationary, dist > 600, loc.timestamp.timeIntervalSince(anchor.timestamp) > 180 {
                isStationary = true
            } else if isStationary, dist <= 600 {
                isStationary = false
            }
        } else {
            stillAnchor = loc
            isStationary = false
        }
        lowPowerTier = !isStationary && dist > 1_500
        let accuracy = isStationary || lowPowerTier ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
        let filter: CLLocationDistance = isStationary ? 15 : (lowPowerTier ? 20 : 5)
        if manager.desiredAccuracy != accuracy { manager.desiredAccuracy = accuracy }
        if manager.distanceFilter != filter { manager.distanceFilter = filter }
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
        // Güvenli daireyi her güncellemede değil, 50 m hareket ya da 60 sn sonra yeniden değerlendir
        if geofenceAlerts {
            let due = lastGeofenceCheck.map { location.distance(from: $0.0) > 50 || Date().timeIntervalSince($0.1) > 60 } ?? true
            if due {
                lastGeofenceCheck = (location, Date())
                Task { await applyGeofence() }
            }
        }
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
            self.tracks.append(last)
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.konum.error("Konum hatası: \(error.localizedDescription, privacy: .public)")
    }
}
