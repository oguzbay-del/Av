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
    /// İnternetsiz yer arama dizini (köy/ilçe/mesire ve avlak adları).
    @ObservationIgnored private(set) var placeIndex = PlaceIndex.empty
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
    /// Son konum bu kadar saniyeden eskiyse değerlendirme "güncel değil" olur (eski konumla "güvenli" denmez).
    static let staleAfter = PowerModePolicy.staleAfter
    /// Konum güncel değil mi (GPS alınamıyor).
    private(set) var locationStale = false
    /// Son konum hatası (ör. GPS sinyali yok); yeni konum gelince temizlenir.
    private(set) var locationError: String?
    /// İnceleme (App Review) demo modu: İstanbul'da yasak alana giden yapay yürüyüş.
    private(set) var demoActive = false

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
    /// Başarısız hava durumu denemesinden sonra üstel bekleme (15 sn'de bir yeniden denenmesin).
    @ObservationIgnored private var weatherBackoff = Backoff()
    @ObservationIgnored private var alertPolicy = AlertPolicy()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let geofence = Geofence()
    @ObservationIgnored private var permitObserver: AnyCancellable?
    /// Arka plan konum oturumu (iOS 17+): sürekli takip açıkken iOS'un güncellemeleri kesmemesi için.
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    /// iOS 18 hizmet oturumu (uygulama açıkken konum yetkisini etkin tutar).
    @ObservationIgnored private var serviceSession: AnyObject?
    @ObservationIgnored private var lastGeofenceCheck: (CLLocation, Date)?
    @ObservationIgnored private var powerMode = PowerModePolicy()
    @ObservationIgnored private var demoTask: Task<Void, Never>?

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
        placeIndex = PlaceIndex(features: features, regs: regs, areas: avlakAreas)
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

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = AppClock.now()
                self?.requestFreshFixIfQuiet()
                self?.reassess()
                self?.refreshWeatherIfNeeded()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-demoKonum") { startDemo() }
    }

    /// Hareketsizken mesafe filtresi yüzünden konum gelmez; 45 sn sessizlikte filtreyi kaldırıp
    /// taze ölçüm iste (ilk ölçümde updatePowerMode filtreyi geri koyar). Böylece "eski konum" ile
    /// "GPS yok" ayırt edilir.
    private func requestFreshFixIfQuiet() {
        guard !demoActive, PowerModePolicy.shouldRequestFreshFix(lastFix: location?.timestamp, now: Date()) else { return }
        if manager.distanceFilter != kCLDistanceFilterNone { manager.distanceFilter = kCLDistanceFilterNone }
    }

    // MARK: İnceleme demo modu

    /// App Review için: gerçek GPS yerine Sarıkavak'ta (İstanbul) devlet avlağından ava yasak alana
    /// yürüyüş oynatılır (test senaryosu 01). Sarı uyarı ~25 sn, kırmızı uyarı ~40 sn sonra gelir.
    func startDemo() {
        guard !demoActive else { return }
        demoActive = true
        FieldLog.shared.log(.demo(active: true))
        manager.stopUpdatingLocation()
        Task { await geofence.stop() }
        let start = CLLocationCoordinate2D(latitude: 41.02446, longitude: 29.65804)
        let deepest = CLLocationCoordinate2D(latitude: 41.01971, longitude: 29.64790)
        let steps = 50 // ~1 km, adım ~20 m, saniyede bir
        demoTask = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                // İleri, sonra geri; sonsuz döngü
                let k = i % (2 * steps)
                let t = Double(k <= steps ? k : 2 * steps - k) / Double(steps)
                let c = CLLocationCoordinate2D(latitude: start.latitude + (deepest.latitude - start.latitude) * t,
                                               longitude: start.longitude + (deepest.longitude - start.longitude) * t)
                self?.ingest(CLLocation(coordinate: c, altitude: 120, horizontalAccuracy: 5, verticalAccuracy: 5,
                                        course: k <= steps ? 240 : 60, speed: 1.4, timestamp: Date()))
                i += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopDemo() {
        guard demoActive else { return }
        demoTask?.cancel()
        demoTask = nil
        demoActive = false
        FieldLog.shared.log(.demo(active: false))
        location = nil
        assessment = .waiting
        alertPolicy.lastAlertLevel = .unknown
        if geofenceAlerts { Task { await geofence.start() } }
        start()
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
            FieldLog.shared.log(.backgroundSession(active: true))
            requestNotifications()
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
            FieldLog.shared.log(.backgroundSession(active: false))
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

    /// Bulunulan nokta ava yasak bir bölgenin içinde mi.
    var insideForbidden: Bool {
        guard let map, let c = location?.coordinate else { return false }
        return map.zone(at: c)?.status == .yasak
    }

    /// GPS hassasiyet kademesi (bkz. `PowerModePolicy`).
    private func updatePowerMode(_ loc: CLLocation) {
        let p = powerMode.update(with: loc, nearestForbidden: nearestForbidden?.distance, insideForbidden: insideForbidden)
        isStationary = p.isStationary
        lowPowerTier = p.lowPowerTier
        if manager.desiredAccuracy != p.desiredAccuracy { manager.desiredAccuracy = p.desiredAccuracy }
        if manager.distanceFilter != p.distanceFilter { manager.distanceFilter = p.distanceFilter }
        FieldLog.shared.log(.powerTier(isStationary ? .pusu : (lowPowerTier ? .uzak : .yakin)))
    }

    private func updateInspected() {
        guard let c = inspectedCoordinate, let ctx = context else { inspected = nil; return }
        inspected = Assessment.evaluatePlace(c, context: ctx, settings: settings)
    }

    private func reassess() {
        guard let ctx = context, let location else { return }
        let age = Date().timeIntervalSince(location.timestamp)
        let stale = PowerModePolicy.isStale(age: age)
        if stale != locationStale { FieldLog.shared.log(locationStale ? .staleEnd : .staleStart(age: Int(age))) }
        locationStale = stale
        var new = Assessment.evaluate(location.coordinate, accuracy: location.horizontalAccuracy,
                                      at: AppClock.now(), context: ctx, settings: settings)
        if reducedAccuracy && !demoActive { new = .reducedAccuracy(location.horizontalAccuracy) }
        if locationStale { new = .stale(age: age, last: new) }
        if new.level != assessment.level { FieldLog.shared.log(.levelChange(from: assessment.level.rawValue, to: new.level.rawValue, title: new.title)) }
        assessment = new
        if let map, map.zone(at: location.coordinate)?.status != .yasak {
            nearestForbidden = map.nearest(to: location.coordinate, within: 3_000) { $0.status == .yasak }
        } else {
            nearestForbidden = nil
        }
        ProximityHaptics.shared.update(distance: nearestForbidden?.distance)
        alertIfNeeded(new)
        updateLiveStatus()
        // Güvenli daireyi her güncellemede değil, 50 m hareket ya da 60 sn sonra yeniden değerlendir
        if geofenceAlerts && !demoActive {
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

    /// 30 dakikada bir ya da 5 km'den fazla yer değişince yenile. İnternet yokken denenmez:
    /// önbellekteki tahmin yaşıyla gösterilir, hata mesajı yağdırılmaz. Başarısızlıktan sonra
    /// 1, 2, 4 … dk (en çok 30 dk, ±%10) beklenir; `force` beklemeyi atlar.
    func refreshWeatherIfNeeded(force: Bool = false) {
        guard let c = referenceCoordinate, weatherTask == nil, NetworkState.shared.isOnline else { return }
        if !force, !weatherBackoff.canAttempt(at: Date()) { return }
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
                weatherBackoff.recordSuccess()
                FieldLog.shared.log(.weatherOK)
            } catch {
                weatherBackoff.recordFailure(at: Date())
                FieldLog.shared.log(.weatherFail(message: error.localizedDescription))
                // Eski tahmin varsa o gösterilmeye devam eder (yaşıyla); hata yalnızca hiç veri yokken
                weatherError = weather == nil ? L("Hava durumu alınamadı: %@", error.localizedDescription) : nil
            }
            weatherTask = nil
            updateLiveStatus()
        }
    }

    private func updateLiveStatus() {
        liveStatus.update(enabled: liveActivityEnabled, assessment: assessment, wind: windSummary)
        let a = assessment, near = nearestForbidden
        WatchLink.shared.send(WatchStatus(
            level: a.level.rawValue, title: a.title,
            detail: a.checks.first { $0.level == a.level }?.detail ?? a.detail, wind: windSummary,
            nearest: near.map { L("Yasak alan %@ · %@", Geo.formatDistance($0.distance), Compass.name($0.bearing)) },
            updated: AppClock.now()))
    }

    /// Uyarı kararı `AlertPolicy`de (yalnızca mekânsal duruma göre); yan etkiler `AlertNotifier`da.
    private func alertIfNeeded(_ a: Assessment) {
        if let alert = alertPolicy.update(with: a, now: Date()) {
            AlertNotifier.deliver(alert)
            FieldLog.shared.log(.alert(level: alert.level.rawValue, title: alert.title,
                                       background: UIApplication.shared.applicationState != .active))
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
            // Çok eski ya da geçersiz ölçümleri yok say; demo modunda gerçek GPS'i yok say.
            guard !self.demoActive, last.horizontalAccuracy >= 0, abs(last.timestamp.timeIntervalSinceNow) < 30 else { return }
            self.ingest(last)
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
        FieldLog.shared.log(.locationError(code: (error as? CLError)?.code.rawValue ?? -1, message: error.localizedDescription))
        let code = (error as? CLError)?.code
        Task { @MainActor in
            switch code {
            case .locationUnknown:
                // Geçici: iOS denemeyi sürdürür; eski konum 90 sn sonra "güncel değil" olur
                self.locationError = L("GPS sinyali zayıf")
            case .denied:
                self.locationError = L("Konum izni yok")
                self.manager.stopUpdatingLocation()
            default:
                self.locationError = error.localizedDescription
            }
            self.reassess()
        }
    }
}

extension AppModel {
    /// Gerçek ya da demo konumunu işle.
    fileprivate func ingest(_ loc: CLLocation) {
        let first = location == nil
        location = loc
        locationError = nil
        if !demoActive { tracks.append(loc) }
        reassess()
        FieldLog.shared.log(.location(loc))
        if !demoActive { updatePowerMode(loc) }
        refreshWeatherIfNeeded(force: first && weather == nil)
    }
}
