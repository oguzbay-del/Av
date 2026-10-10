import Foundation

/// iPhone'dan Apple Watch'a (WatchConnectivity) gönderilen av durumu.
/// Hem iOS uygulaması hem AvSaat (watchOS) bu dosyayı derler.
struct WatchStatus: Codable, Equatable, Sendable {
    /// 0 bilinmiyor, 1 avlanabilir, 2 dikkat, 3 avlanmayın (Assessment.Level.rawValue)
    var level: Int
    var title: String
    var detail: String
    var wind: String?
    /// En yakın yasak alan: uzaklık ve yön (ör. "Yasak alan 450 m · KD")
    var nearest: String?
    var updated: Date
    /// Şu anki ya da sıradaki avlanma saati aralığı (saat komplikasyonu için; eski sürümlerde yok).
    var huntStart: Date?
    var huntEnd: Date?

    /// WatchConnectivity sözlüğündeki anahtar (değer: JSON verisi).
    static let key = "watchStatus"

    init(level: Int, title: String, detail: String, wind: String? = nil, nearest: String? = nil, updated: Date = Date(),
         huntStart: Date? = nil, huntEnd: Date? = nil) {
        self.level = level
        self.title = title
        self.detail = detail
        self.wind = wind
        self.nearest = nearest
        self.updated = updated
        self.huntStart = huntStart
        self.huntEnd = huntEnd
    }

    /// JSON olarak kodlanmış hâli (UserDefaults ve WatchConnectivity için).
    var encoded: Data? { try? JSONEncoder().encode(self) }

    /// `updateApplicationContext` / `sendMessage` için özellik listesi uyumlu sözlük.
    var dictionary: [String: Any] {
        guard let data = encoded else { return [:] }
        return [Self.key: data]
    }

    init?(data: Data) {
        guard let s = try? JSONDecoder().decode(WatchStatus.self, from: data) else { return nil }
        self = s
    }

    init?(dictionary: [String: Any]) {
        guard let data = dictionary[Self.key] as? Data else { return nil }
        self.init(data: data)
    }

    /// Zaman damgası dışında aynı içerik mi? (gereksiz gönderimleri azaltmak için)
    func sameContent(as other: WatchStatus) -> Bool {
        level == other.level && title == other.title && detail == other.detail
            && wind == other.wind && nearest == other.nearest
            && huntStart == other.huntStart && huntEnd == other.huntEnd
    }
}
