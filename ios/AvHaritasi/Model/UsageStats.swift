import CryptoKit
import Foundation

// MARK: - Anonim kullanım istatistikleri (TelemetryDeck)
// Hangi özelliklerin ne sıklıkla ve hangi ilçe/avlakta kullanıldığı günlük sayaçlar olarak cihazda
// toplanır, günde en çok bir kez TelemetryDeck'e gönderilir. Ad, telefon, e-posta, koordinat, iz,
// tür adı ve ava yasak alanda bulunulduğu bilgisi hiçbir zaman toplanmaz. Uyarılar yalnızca sayıdır.
// Bu dosya yan etkisizdir (birim testli); disk ve ağ `UsageRecorder`da.

/// Kullanım istatistiklerinin tek ayar yeri.
enum UsageStats {
    /// TelemetryDeck uygulama kimliği (Dashboard › App › Set Up App). nil yapılırsa özellik tamamen kapalıdır:
    /// hiçbir şey kaydedilmez ya da gönderilmez, Ayarlar'da anahtar ve ilk açılış metninde cümle görünmez.
    static let appID: String? = "976D003C-9D53-4D37-A6CF-ACE85F467CE4"
    /// Kuruluşun TelemetryDeck ad alanı (namespace). nil: varsayılan uç nokta (https://nom.telemetrydeck.com/v2/).
    static let namespace: String? = nil
    /// Kurulum kimliği karılmadan önce eklenen tuz (TelemetryDeck önerisi: bir kez seçilen 64 karakter;
    /// değişirse tüm kullanıcılar yeni sayılır). Sunucu ayrıca kendi tuzuyla yeniden karar.
    static let salt = "wAwN7Kb6l3PGImmuZooJjiZTKeDu1qUMYLJIfOWyPt1Xl1QTtTeUQq8Grhkj9UY7"

    /// Ayarlar › "Anonim kullanım istatistikleri" (@AppStorage anahtarı).
    static let settingKey = "usageStats"
    static let defaultEnabled = true
    /// Bu kadar günden eski, gönderilememiş günler silinir.
    static let maxAgeDays = 30
    /// Gönderim denemeleri arası en az süre (başarısız denemeler de sayılır; ısrarla yeniden denenmez).
    static let sendInterval: TimeInterval = 24 * 3600
    /// Yer bilinmediğinde gönderilen ad.
    static let unknownArea = "bilinmiyor"

    /// Özellik yapılandırılmış mı (App ID var mı).
    static var isConfigured: Bool { appID?.isEmpty == false }

    /// Kullanıcı ayarı (varsayılan açık).
    static var isEnabledSetting: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? defaultEnabled
    }

    /// Günler İstanbul saatine göre ayrılır (uygulama yalnızca İstanbul için).
    static func dayKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Gönderilen yer adı: avlak adının ilk kısmı (açıklama parantezi atılır), en çok 60 karakter.
    static func areaName(_ unitName: String?) -> String? {
        guard let raw = unitName?.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        return String(raw.prefix(60))
    }

    // MARK: Kısa çağrılar (ölçüm noktalarında tek satır)

    static func record(_ feature: UsageFeature) { UsageRecorder.shared.record(feature) }
    static func alert() { UsageRecorder.shared.recordAlert() }
    static func birdID(_ kind: OnlineBirdID.Kind, topProbability: Double?, online: Bool) {
        UsageRecorder.shared.recordBirdID(kind == .photo ? .foto : .ses,
                                          confidence: UsageConfidence(probability: topProbability), online: online)
    }
}

/// Sayılan özellikler (ham değerler TelemetryDeck'te görünen adlardır).
enum UsageFeature: String, Codable, CaseIterable, Sendable {
    case harita, bugun, kurallar
    case kusSesi = "kus_ses"
    case kusFotografi = "kus_foto"
    case kusVideo = "kus_video"
    case isaretEkle = "isaret_ekle"
    case isaretYonlendirme = "isaret_yonlendirme"
    case sahaModu = "saha_modu"
    case geceTemasi = "gece_tema"
    case cevrimdisiHarita = "cevrimdisi_harita"
    case siri
    case saat
    case geriBildirim = "geri_bildirim"

    /// Sekme adından (ContentView "selectedTab").
    init?(tab: String) {
        switch tab {
        case "harita": self = .harita
        case "bugun": self = .bugun
        case "kurallar": self = .kurallar
        default: return nil
        }
    }
}

enum UsageBirdKind: String, Codable, Sendable { case foto, ses }

/// Kuş tanımada cihazdaki en yüksek olasılığın kabaca dilimi (tür adı tutulmaz).
enum UsageConfidence: String, Codable, CaseIterable, Sendable {
    case dusuk, orta, yuksek

    /// nil (sonuç yok) ya da < %50 düşük, < %80 orta, üstü yüksek.
    init(probability: Double?) {
        switch probability ?? 0 {
        case ..<OnlineBirdID.uncertainBelow: self = .dusuk
        case ..<0.8: self = .orta
        default: self = .yuksek
        }
    }
}

/// Bir günün sayaçları.
struct UsageDay: Codable, Equatable, Sendable {
    var sessions = 0
    var features: [String: Int] = [:]
    /// Avlak/ilçe adı → o adla geçen oturum sayısı.
    var areas: [String: Int] = [:]
    var alerts = 0
    /// "foto|yuksek|cihaz" biçiminde anahtar → sayı.
    var birdIDs: [String: Int] = [:]
    var appVersion: String?
    var osVersion: String?
    var deviceModel: String?

    var isEmpty: Bool { sessions == 0 && features.isEmpty && areas.isEmpty && alerts == 0 && birdIDs.isEmpty }

    static func birdKey(_ kind: UsageBirdKind, _ confidence: UsageConfidence, online: Bool) -> String {
        "\(kind.rawValue)|\(confidence.rawValue)|\(online ? "cevrimici" : "cihaz")"
    }

    /// İki kaydı topla (ör. kilitliyken bellekte biriken sayaçlar diskteki kayda eklenirken).
    mutating func merge(_ o: UsageDay) {
        sessions += o.sessions
        alerts += o.alerts
        features.merge(o.features, uniquingKeysWith: +)
        areas.merge(o.areas, uniquingKeysWith: +)
        birdIDs.merge(o.birdIDs, uniquingKeysWith: +)
        appVersion = o.appVersion ?? appVersion
        osVersion = o.osVersion ?? osVersion
        deviceModel = o.deviceModel ?? deviceModel
    }
}

/// Cihazdaki tüm kayıt: günlük sayaçlar + rastgele kurulum kimliği (kapatınca birlikte silinir).
struct UsageLedger: Codable, Equatable, Sendable {
    var installID = UUID()
    /// "yyyy-MM-dd" → sayaçlar.
    var days: [String: UsageDay] = [:]
    var lastAttempt: Date?

    mutating func update(_ date: Date, _ change: (inout UsageDay) -> Void) {
        let key = UsageStats.dayKey(date)
        var d = days[key] ?? UsageDay()
        change(&d)
        days[key] = d
    }

    mutating func merge(_ o: UsageLedger) {
        for (k, d) in o.days { days[k, default: UsageDay()].merge(d) }
        if let a = o.lastAttempt { lastAttempt = max(lastAttempt ?? a, a) }
    }

    /// `maxAgeDays`ten eski günleri sil.
    mutating func prune(now: Date) {
        let cutoff = UsageStats.dayKey(now.addingTimeInterval(-Double(UsageStats.maxAgeDays) * 24 * 3600))
        days = days.filter { $0.key >= cutoff }
    }

    /// Bitmiş (bugünden önceki), boş olmayan günler; eskiden yeniye.
    func completedDays(now: Date) -> [(key: String, day: UsageDay)] {
        let today = UsageStats.dayKey(now)
        return days.filter { $0.key < today && !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func isSendDue(now: Date) -> Bool {
        guard let a = lastAttempt else { return true }
        return now.timeIntervalSince(a) >= UsageStats.sendInterval || a > now
    }
}

/// TelemetryDeck Ingest API v2 sinyali (https://telemetrydeck.com/docs/ingest/v2). Biçim resmi Swift SDK ile
/// aynıdır: github.com/TelemetryDeck/SwiftSDK @ 58f4362 (2026-08-01), Sources/TelemetryDeck/Signals/Signal.swift
/// (`SignalPostBody`: isTestMode metin "true"/"false", payload yalnızca metin değerler, receivedAt
/// "yyyy-MM-dd'T'HH:mm:ssZ" UTC — Helpers/JSONFormatting.swift `telemetryEncoder`) ve SignalManager.swift
/// (uç nokta `v2/` ya da `v2/namespace/<ad>/`, clientUser = SHA-256(kimlik + tuz)).
struct UsageSignal: Codable, Equatable, Sendable {
    let receivedAt: String
    let appID: String
    let clientUser: String
    let sessionID: String
    let type: String
    let floatValue: Double?
    let payload: [String: String]
    let isTestMode: String
}

enum UsageSignalBuilder {
    /// SDK'nın oturum sinyali (Dashboard'daki kullanıcı/oturum grafikleri bunu sayar).
    static let sessionSignal = "TelemetryDeck.Session.started"
    /// Bir günde gönderilen en çok oturum sinyali.
    static let maxSessionSignals = 50

    /// TelemetryDeck'in beklediği karılmış kullanıcı: SHA-256(kurulum kimliği + tuz), küçük onaltılık
    /// (SDK Helpers/CryptoHashing.swift `sha256(string:salt:)` ile aynı). Sunucu bunu kendi tuzuyla yeniden karar.
    static func clientUser(installID: UUID, salt: String = UsageStats.salt) -> String {
        SHA256.hash(data: Data((installID.uuidString + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// SDK'nın varsayılan parametrelerinden yalnızca sürüm/cihaz bilgisi (Signal.swift `DefaultSignalPayload`;
    /// yeni ve eski adlarıyla). Dil, bölge, saat dilimi, ekran gibi diğerleri gönderilmez.
    static func defaultParameters(_ d: UsageDay, testMode: Bool) -> [String: String] {
        var p = ["TelemetryDeck.Device.platform": "iOS", "TelemetryDeck.Device.operatingSystem": "iOS",
                 "platform": "iOS", "operatingSystem": "iOS",
                 "TelemetryDeck.RunContext.isDebug": "\(testMode)", "isDebug": "\(testMode)"]
        if let v = d.appVersion {
            p["TelemetryDeck.AppInfo.version"] = v
            p["appVersion"] = v
        }
        if let os = d.osVersion {
            let parts = os.split(separator: ".").map(String.init)
            let full = "iOS " + (parts + ["0", "0"]).prefix(3).joined(separator: ".")
            let major = "iOS " + (parts.first ?? "0")
            let majorMinor = "iOS " + (parts + ["0"]).prefix(2).joined(separator: ".")
            p["TelemetryDeck.Device.systemVersion"] = full
            p["TelemetryDeck.Device.systemMajorVersion"] = major
            p["TelemetryDeck.Device.systemMajorMinorVersion"] = majorMinor
            p["systemVersion"] = full
            p["majorSystemVersion"] = major
            p["majorMinorSystemVersion"] = majorMinor
        }
        if let m = d.deviceModel {
            p["TelemetryDeck.Device.modelName"] = m
            p["modelName"] = m
        }
        return p
    }

    /// Bitmiş günlerden sinyaller: oturumlar, özellik, avlak, uyarı sayısı ve kuş tanıma dilimleri.
    /// receivedAt o günün öğlesidir (İstanbul, UTC+3), böylece Dashboard'da doğru güne düşer.
    static func signals(for days: [(key: String, day: UsageDay)], appID: String, installID: UUID,
                        testMode: Bool) -> [UsageSignal] {
        let user = clientUser(installID: installID)
        var out: [UsageSignal] = []
        for (key, d) in days {
            let session = UUID().uuidString
            let base = defaultParameters(d, testMode: testMode).merging(["Usage.day": key]) { _, new in new }
            func add(_ type: String, _ value: Double?, _ extra: [String: String] = [:]) {
                out.append(UsageSignal(receivedAt: "\(key)T09:00:00+0000", appID: appID, clientUser: user,
                                       sessionID: session, type: type, floatValue: value,
                                       payload: base.merging(extra) { _, new in new }, isTestMode: testMode ? "true" : "false"))
            }
            for _ in 0..<max(0, min(d.sessions, maxSessionSignals)) { add(sessionSignal, nil) }
            for (f, n) in d.features.sorted(by: { $0.key < $1.key }) { add("Usage.featureUsed", Double(n), ["Usage.feature": f]) }
            for (a, n) in d.areas.sorted(by: { $0.key < $1.key }) { add("Usage.areaOpened", Double(n), ["Usage.area": a]) }
            if d.alerts > 0 { add("Usage.alertsShown", Double(d.alerts)) }
            for (k, n) in d.birdIDs.sorted(by: { $0.key < $1.key }) {
                let p = k.split(separator: "|").map(String.init)
                guard p.count == 3 else { continue }
                add("Usage.birdIdentified", Double(n), ["Usage.BirdID.kind": p[0], "Usage.BirdID.confidence": p[1],
                                                        "Usage.BirdID.onlineFallback": p[2] == "cevrimici" ? "true" : "false"])
            }
        }
        return out
    }

    /// POST isteği. Gövde düz JSON dizisidir (SDK de sıkıştırmaz; belgelerde gzip yer almaz).
    static func request(_ signals: [UsageSignal], namespace: String? = UsageStats.namespace) throws -> URLRequest {
        let path = namespace.map { "v2/namespace/\($0)/" } ?? "v2/"
        guard let url = URL(string: "https://nom.telemetrydeck.com/" + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        r.httpBody = try enc.encode(signals)
        return r
    }
}
