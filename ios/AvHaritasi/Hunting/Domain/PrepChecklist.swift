import Foundation

// MARK: - Ava hazırlık kontrol listesi (saf mantık; PrepChecklistTests)

enum PrepChecklist {
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String?
        /// Vurgulu (ör. bulunulan yer devlet avlağı).
        let important: Bool
    }

    /// Seçilen türler ve önerilere göre liste. `limit`: tür → günlük limit metni (MAK).
    static func items(species: [String], limit: (String) -> String?, picks: [Recommendation], boarHunt: Bool,
                      inStateAvlak: Bool) -> [Item] {
        var out: [Item] = []
        out.append(Item(id: "belge", title: L("Avcılık belgesi ve av tezkeresi"),
                        detail: L("Tezkere vizesi güncel olmalı; kimlikle birlikte yanınızda taşıyın."), important: false))
        out.append(Item(id: "avlak_izni", title: L("Avlak izni (devlet avlağında)"),
                        detail: inStateAvlak
                            ? L("Bulunduğunuz yer devlet avlağı: AVBİS'ten avlanma izin belgesi alın.")
                            : L("Devlet avlağında avlanacaksanız AVBİS'ten avlanma izin belgesi gerekir."),
                        important: inStateAvlak))
        if picks.prefix(2).contains(where: { $0.firearm.type.hasMagazine }) {
            out.append(Item(id: "takoz", title: L("Haznede takoz: en çok 2+1 fişek"),
                            detail: L("Yarı otomatik ve pompalıda zorunlu (MAK 10/1-a)."), important: true))
        }
        if boarHunt {
            out.append(Item(id: "tek_kursun", title: L("Yalnızca tek kurşunlu fişek"),
                            detail: L("Domuz avında saçmalı fişek bulundurulamaz (MAK 10/1-ı)."), important: true))
            out.append(Item(id: "surek", title: L("Sürek avıysa izin ve bildirim"),
                            detail: L("DKMP'ye en az 1 hafta önce başvuru, muhtarlığa en az 2 gün önce bildirim (MAK 13)."),
                            important: false))
        }
        // Aynı fişek iki tüfekte de öneriliyorsa tek satır (tüfek adları birleşir)
        var shells: [(summary: String, guns: [String])] = []
        for r in picks.prefix(2) {
            for a in r.ammo {
                if let k = shells.firstIndex(where: { $0.summary == a.summary }) {
                    shells[k].guns.append(r.firearm.name)
                } else {
                    shells.append((a.summary, [r.firearm.name]))
                }
            }
        }
        for (n, s) in shells.enumerated() {
            out.append(Item(id: "fisek_0_\(n)", title: L("Fişek: %@", s.summary),
                            detail: s.guns.joined(separator: ", "), important: false))
        }
        for s in species {
            let l = limit(s).map(LD) ?? L("Limitsiz")
            out.append(Item(id: "limit_\(s)", title: L("%@ — günlük limit: %@", LD(s), l), detail: nil, important: false))
        }
        out.append(Item(id: "kilif", title: L("Tüfek kılıfı"),
                        detail: L("Araçta tüfek kılıfında ve boş taşınır (MAK 11)."), important: false))
        out.append(Item(id: "turuncu", title: L("Turuncu şapka ya da yelek"),
                        detail: L("Zorunlu değil; sürek ve kalabalık avda görünür olmak güvenliği artırır."), important: false))
        return out
    }
}

/// O günün işaretleri: gün değişince boşalır.
struct ChecklistDay: Codable, Equatable, Sendable {
    var day: String
    var checked: Set<String>

    static let storageKey = "hazirlikKontrol"

    /// Kayıtlı durum bugüne aitse onu, değilse boş listeyi döndürür.
    static func current(stored: ChecklistDay?, today: String) -> ChecklistDay {
        if let stored, stored.day == today { return stored }
        return ChecklistDay(day: today, checked: [])
    }

    mutating func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }
}

// MARK: - Metin biçimleri

enum AmmoFormat {
    static func mm(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = AppLocale.current
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// Saçma numarası: "7.5" → Türkçede "7,5".
    static func shotNumber(_ id: String) -> String {
        AppLocale.isEnglish ? id : id.replacingOccurrences(of: ".", with: ",")
    }

    static func grams(_ r: ClosedRange<Int>) -> String {
        r.lowerBound == r.upperBound ? L("%@ g", String(r.lowerBound)) : L("%@–%@ g", String(r.lowerBound), String(r.upperBound))
    }
}

extension AmmoChoice {
    /// Tek satır özet: "8 numara kurşun (2,3 mm) · 28–32 g · 70 mm".
    var summary: String {
        switch self {
        case .shot(let l):
            var s = L("%@ numara %@", AmmoFormat.shotNumber(l.size), l.material.title.lowercased(with: AppLocale.current))
            if let mm = l.mm { s += " (" + L("%@ mm", AmmoFormat.mm(mm)) + ")" }
            return s + " · " + AmmoFormat.grams(l.grams) + " · " + L("%@ mm", String(l.shellMm))
        case .slug(let g, let mm):
            return [L("Tek kurşun"), g.map(AmmoFormat.grams), L("%@ mm", String(mm))].compactMap { $0 }.joined(separator: " · ")
        case .rifle(let c):
            return L("%@ av mermisi", c)
        }
    }
}
