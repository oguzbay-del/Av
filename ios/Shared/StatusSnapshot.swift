import Foundation
import SwiftUI

/// Uygulama ile eklentilerin (ana ekran / kilit ekranı aracı, saat komplikasyonu) ve Siri
/// kısayollarının paylaştığı App Group. Kimlik Info.plist'teki `AvAppGroup` anahtarından okunur
/// (değeri derleme ayarı `APP_GROUP_ID`; varsayılan `group.<uygulama Bundle ID>.paylasim`).
enum AppGroup {
    static let identifier: String? = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AvAppGroup") as? String,
              !id.isEmpty, !id.contains("$(") else { return nil }
        return id
    }()

    /// Paylaşılan UserDefaults (App Group yoksa yerel UserDefaults).
    static var defaults: UserDefaults {
        identifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
}

/// Son hesaplanan av durumu: uygulama her durum değişiminde App Group'a yazar; araçlar ve Siri
/// kısayolu uygulama çalışmıyorken bunu okur (internet gerekmez).
struct StatusSnapshot: Codable, Equatable, Sendable {
    /// 0 bilinmiyor, 1 avlanabilir, 2 dikkat, 3 avlanmayın
    var level: Int
    var title: String
    /// Durumun gerekçesi (seviyeyi belirleyen kural).
    var reason: String
    /// En yakın ava yasak alan (metin, ör. "Yasak alan 450 m · KD") ve metre cinsinden uzaklık.
    var nearest: String?
    var nearestMeters: Double?
    /// Bugünün ve yarının avlanma saatleri (konuma göre, gün doğumu/batımından).
    var huntStart: Date?
    var huntEnd: Date?
    var nextHuntStart: Date?
    var nextHuntEnd: Date?
    var updated: Date

    static let key = "statusSnapshot"
    /// Bu süreden eski durum "güncel değil" sayılır (bu arada yer değişmiş olabilir).
    static let staleAfter: TimeInterval = 30 * 60

    func isStale(at now: Date) -> Bool { now.timeIntervalSince(updated) > Self.staleAfter }

    static func load(from defaults: UserDefaults = AppGroup.defaults) -> StatusSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StatusSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults = AppGroup.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// Zaman damgası dışında aynı içerik mi?
    func sameContent(as o: StatusSnapshot) -> Bool {
        level == o.level && title == o.title && reason == o.reason && nearest == o.nearest
            && huntStart == o.huntStart && huntEnd == o.huntEnd && nextHuntStart == o.nextHuntStart
    }

    /// Şu anki ya da sıradaki avlanma saati aralığı ve şu an içinde olup olmadığı.
    func huntWindow(at now: Date) -> (start: Date, end: Date, active: Bool)? {
        if let s = huntStart, let e = huntEnd, now < e { return (s, e, now >= s) }
        if let s = nextHuntStart, let e = nextHuntEnd, now < e { return (s, e, now >= s) }
        return nil
    }
}

/// Seviye → renk, simge, kısa ad (araçlar ve komplikasyon ortak kullanır).
struct AvDurumStili {
    let level: Int
    var stale = false

    var color: Color {
        if stale { return .gray }
        switch level {
        case 3: return .red
        case 2: return .orange
        case 1: return .green
        default: return .gray
        }
    }

    var symbol: String {
        if stale { return "clock.badge.exclamationmark" }
        switch level {
        case 3: return "xmark.octagon.fill"
        case 2: return "exclamationmark.triangle.fill"
        case 1: return "checkmark.shield.fill"
        default: return "location.slash"
        }
    }

    var short: String {
        switch level {
        case 3: return L("AVLANMAYIN")
        case 2: return L("DİKKAT")
        case 1: return L("AVLANABİLİR")
        default: return "—"
        }
    }
}
