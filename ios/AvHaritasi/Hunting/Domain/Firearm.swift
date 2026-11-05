import Foundation

// MARK: - Tüfek modeli (yalnızca cihazda; bkz. FirearmStore)
//
// Marka/model yok: öneri motoru için tüfeğin teknik özellikleri ve sahip olunan şoklar yeterli.
// Saf veri; arayüz metinleri `title` özelliklerinde L() ile.

/// Tüfek tipi (mekanizma).
enum FirearmType: String, Codable, CaseIterable, Identifiable, Sendable {
    case yariOtomatik, pompali, superpoze, cifte, tekKirma, yivli

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yariOtomatik: return L("Yarı otomatik")
        case .pompali: return L("Pompalı")
        case .superpoze: return L("Süperpoze")
        case .cifte: return L("Yan yana çifte")
        case .tekKirma: return L("Tek kırma")
        case .yivli: return L("Yivli tüfek")
        }
    }

    var symbol: String {
        switch self {
        case .superpoze, .cifte: return "equal"
        case .yivli: return "scope"
        default: return "minus"
        }
    }

    /// Namlu sayısı (her namlunun ayrı şoku olur).
    var barrelCount: Int {
        switch self {
        case .superpoze, .cifte: return 2
        case .yivli: return 0
        default: return 1
        }
    }

    /// Haznesi olan yivsiz tüfek: avda takoz (2+1) gerekir (MAK 10/1-a).
    var hasMagazine: Bool { self == .yariOtomatik || self == .pompali }

    var isRifled: Bool { self == .yivli }
}

/// Yivsiz kalibre (ga).
enum Gauge: String, Codable, CaseIterable, Identifiable, Sendable {
    case g12 = "12", g16 = "16", g20 = "20", g28 = "28", g410 = ".410"

    var id: String { rawValue }
}

/// Fişek yatağı (hazne) boyu, mm.
enum ChamberLength: Int, Codable, CaseIterable, Identifiable, Sendable {
    case mm70 = 70, mm76 = 76, mm89 = 89

    var id: Int { rawValue }
}

/// Şok: 1 Full · 2 IM · 3 Modified · 4 IC · 5 Silindir; ayrıca paradoks / yivli şok (yalnızca tek kurşun).
enum Choke: Int, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case full = 1, improvedModified = 2, modified = 3, improvedCylinder = 4, cylinder = 5, paradox = 9

    var id: Int { rawValue }

    /// Saçma şokları (paradoks hariç), dardan açığa.
    static let shotChokes: [Choke] = [.full, .improvedModified, .modified, .improvedCylinder, .cylinder]

    static func < (a: Choke, b: Choke) -> Bool { a.rawValue < b.rawValue }

    /// Rozet yazısı: "1" … "5", paradoks "P".
    var badge: String { self == .paradox ? "P" : String(rawValue) }

    /// Kısa uluslararası ad.
    var shortName: String {
        switch self {
        case .full: return "Full"
        case .improvedModified: return "IM"
        case .modified: return "M"
        case .improvedCylinder: return "IC"
        case .cylinder: return "Cyl"
        case .paradox: return L("Paradoks")
        }
    }

    /// Türkçe adı.
    var title: String {
        switch self {
        case .full: return L("Tam şok")
        case .improvedModified: return L("3/4 şok")
        case .modified: return L("Yarım şok")
        case .improvedCylinder: return L("1/4 şok")
        case .cylinder: return L("Silindir")
        case .paradox: return L("Paradoks / yivli şok")
        }
    }

    /// Saçma şokları arasında komşu mu (paradoks komşusuzdur).
    func distance(to other: Choke) -> Int? {
        guard self != .paradox, other != .paradox else { return self == other ? 0 : nil }
        return abs(rawValue - other.rawValue)
    }

    /// 1…5 aralığında şok (sınır dışı değer kırpılır).
    static func clamped(_ v: Int) -> Choke { Choke(rawValue: min(5, max(1, v))) ?? .modified }
}

/// Çelik saçmaya uygunluk (namlu "STEEL" / çelik muayene damgası).
enum SteelProof: String, Codable, CaseIterable, Identifiable, Sendable {
    case yes, no, unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yes: return L("Evet")
        case .no: return L("Hayır")
        case .unknown: return L("Bilmiyorum")
        }
    }
}

/// Ağırlık sınıfı (isteğe bağlı): yürüyüş avında hafif tüfek avantajlı.
enum WeightClass: String, Codable, CaseIterable, Identifiable, Sendable {
    case light, medium, heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return L("Hafif (< 3 kg)")
        case .medium: return L("Orta (3–3,5 kg)")
        case .heavy: return L("Ağır (> 3,5 kg)")
        }
    }
}

/// Yivli kalibreler (öneri motoru için mermi çapı, mm).
struct RifleCaliber: Hashable, Identifiable, Sendable {
    let name: String
    let boreMm: Double

    var id: String { name }

    static let all: [RifleCaliber] = [
        .init(name: ".222 Rem", boreMm: 5.7), .init(name: ".223 Rem", boreMm: 5.7),
        .init(name: ".22-250", boreMm: 5.7), .init(name: ".243 Win", boreMm: 6.2),
        .init(name: "6.5 Creedmoor", boreMm: 6.7), .init(name: "7x64", boreMm: 7.2),
        .init(name: ".308 Win", boreMm: 7.8), .init(name: ".30-06 Sprg", boreMm: 7.8),
        .init(name: "8x57 IS", boreMm: 8.2), .init(name: "9.3x62", boreMm: 9.3),
    ]

    static func named(_ name: String?) -> RifleCaliber? { all.first { $0.name == name } }
}

/// Kullanıcının tüfeği.
struct Firearm: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var type: FirearmType
    /// Yivsiz kalibre (yivlide nil).
    var gauge: Gauge?
    /// Yatak boyu (yivlide nil).
    var chamber: ChamberLength?
    /// Namlu boyu, cm.
    var barrelCm: Int
    /// Mobil (değiştirilebilir) şok mu; değilse `fixedChokes` namlulara sabittir.
    var mobileChokes: Bool
    /// Sabit şoklar, namlu sırasıyla (1. atış namlusu önce).
    var fixedChokes: [Choke]
    /// Sahip olunan mobil şoklar.
    var ownedChokes: [Choke]
    var steelProof: SteelProof
    var weight: WeightClass?
    /// Yivli kalibre adı (RifleCaliber.all ya da serbest).
    var rifleCaliber: String?

    init(id: UUID = UUID(), name: String, type: FirearmType, gauge: Gauge? = .g12, chamber: ChamberLength? = .mm70,
         barrelCm: Int = 71, mobileChokes: Bool = true, fixedChokes: [Choke] = [], ownedChokes: [Choke] = [],
         steelProof: SteelProof = .unknown, weight: WeightClass? = nil, rifleCaliber: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.gauge = type.isRifled ? nil : gauge
        self.chamber = type.isRifled ? nil : chamber
        self.barrelCm = barrelCm
        self.mobileChokes = mobileChokes
        self.fixedChokes = fixedChokes
        self.ownedChokes = ownedChokes
        self.steelProof = steelProof
        self.weight = weight
        self.rifleCaliber = type.isRifled ? rifleCaliber : nil
    }

    /// Kullanılabilir şoklar: mobilde sahip olunanlar, sabitte namlulardakiler.
    var availableChokes: [Choke] { Array(Set(mobileChokes ? ownedChokes : fixedChokes)).sorted() }

    /// Kısa teknik özet: "12 ga · 76 mm · 71 cm" / ".308 Win · 56 cm".
    var specLine: String {
        var parts: [String] = []
        if type.isRifled {
            parts.append(rifleCaliber ?? L("Yivli"))
        } else {
            if let g = gauge { parts.append(L("%@ ga", g.rawValue)) }
            if let c = chamber { parts.append(L("%@ mm", String(c.rawValue))) }
        }
        parts.append(L("%@ cm", String(barrelCm)))
        return parts.joined(separator: " · ")
    }

    /// Şok özeti: "Mobil: 2 3 4 5" / "Sabit: 4 / 2".
    var chokeLine: String? {
        guard !type.isRifled else { return nil }
        if mobileChokes {
            let list = ownedChokes.sorted().map(\.badge).joined(separator: " ")
            return list.isEmpty ? L("Mobil şok: hiç yok") : L("Mobil şok: %@", list)
        }
        return L("Sabit şok: %@", fixedChokes.map(\.badge).joined(separator: " / "))
    }

    /// Kayıt için geçerli mi (sabit şok sayısı namlu sayısına eşit vb.).
    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, (30...120).contains(barrelCm) else { return false }
        if type.isRifled { return true }
        guard gauge != nil, chamber != nil else { return false }
        return mobileChokes || fixedChokes.count == type.barrelCount
    }
}
