import CoreLocation
import Foundation

/// Değerlendirmede kullanılan tüm veri.
struct HuntContext {
    let map: HuntingMap
    let features: MapFeatures?
    let regs: Regulations?
    var osm: OSMLayer? = nil
}

struct EvaluationSettings {
    /// Kullanıcının "yasak alana yaklaşma" uyarı mesafesi (yasal zorunluluk olmayan durumlar için).
    var warningBuffer: Double = 300
    /// Zaman kuralları (av günü, saat, sezon) da değerlendirilsin mi?
    var includeTime: Bool = true
}

/// Tek bir kuralın sonucu.
struct RuleCheck: Identifiable, Equatable {
    enum Kind: String { case place, time }

    let id: String
    let kind: Kind
    let level: Assessment.Level
    let title: String
    let detail: String
}

/// Bir konumun ve anın avlanma açısından değerlendirmesi.
struct Assessment: Equatable {
    enum Level: Int, Comparable {
        case unknown = 0, safe, caution, danger
        static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }
    }

    let level: Level
    /// Yalnızca mekânsal kuralların seviyesi (uyarı / bildirim buna göre verilir).
    let placeLevel: Level
    let title: String
    let detail: String
    let zone: ZoneClass?
    let unitName: String?
    let checks: [RuleCheck]

    static let waiting = Assessment(level: .unknown, placeLevel: .unknown, title: "Konum bekleniyor…",
                                    detail: "GPS sinyali alınıyor.", zone: nil, unitName: nil, checks: [])

    /// "Kesin Konum" kapalı: iOS konumu km'lerce bulanıklaştırdığı için alan belirlenemez.
    static func reducedAccuracy(_ accuracy: CLLocationAccuracy) -> Assessment {
        let detail = "iPhone yalnızca yaklaşık konum veriyor (±\(Int(accuracy)) m). Yasak alanda olup olmadığınız belirlenemez. Kesin Konum'u açın."
        return Assessment(level: .danger, placeLevel: .caution, title: "Kesin Konum kapalı",
                          detail: detail, zone: nil, unitName: nil,
                          checks: [RuleCheck(id: "kesin_konum", kind: .place, level: .danger,
                                             title: "Kesin Konum kapalı",
                                             detail: "Ayarlar › Gizlilik › Konum Servisleri › Av Haritası › Kesin Konum")])
    }

    static func evaluate(_ c: CLLocationCoordinate2D,
                         accuracy: CLLocationAccuracy,
                         at date: Date,
                         context ctx: HuntContext,
                         settings: EvaluationSettings) -> Assessment {
        var checks = placeChecks(c, accuracy: accuracy, context: ctx, settings: settings)
        let placeLevel = checks.map(\.level).max() ?? .unknown
        if settings.includeTime, let regs = ctx.regs {
            checks += timeChecks(c, at: date, regs: regs)
        }
        let zone = ctx.map.zone(at: c)
        let unit = unitName(at: c, context: ctx)
        return summarize(checks, zone: zone, unit: unit, placeLevel: placeLevel)
    }

    /// Haritada seçilen nokta için yalnızca mekânsal değerlendirme.
    static func evaluatePlace(_ c: CLLocationCoordinate2D, context ctx: HuntContext, settings: EvaluationSettings) -> Assessment {
        let checks = placeChecks(c, accuracy: 0, context: ctx, settings: settings)
        let level = checks.map(\.level).max() ?? .unknown
        return summarize(checks, zone: ctx.map.zone(at: c), unit: unitName(at: c, context: ctx), placeLevel: level)
    }

    private static func unitName(at c: CLLocationCoordinate2D, context ctx: HuntContext) -> String? {
        // Avlak birimleri 2024-25 haritasından; 2026-27'de yasak/korunan olan yerlerde
        // (ör. yeni Sarıkavak D.A.) eski ad yanıltıcı olur, gösterme.
        guard let zone = ctx.map.zone(at: c), zone.status == .izinli || zone.status == .dikkat,
              let label = ctx.features?.unitLabel(at: c) else { return nil }
        return ctx.regs?.unitAliases[label] ?? label
    }

    private static func summarize(_ checks: [RuleCheck], zone: ZoneClass?, unit: String?, placeLevel: Level) -> Assessment {
        let level = checks.map(\.level).max() ?? .unknown
        let sorted = checks.sorted { $0.level > $1.level }
        let title: String
        let detail: String
        switch level {
        case .danger:
            let reasons = sorted.filter { $0.level == .danger }
            title = "AVLANMAYIN: " + reasons[0].title
            detail = reasons.count > 1
                ? reasons[0].detail + " (+\(reasons.count - 1) yasak daha)"
                : reasons[0].detail
        case .caution:
            title = "Dikkat: " + sorted[0].title
            detail = sorted[0].detail
        case .safe:
            title = "Avlanabilirsiniz" + (unit.map { " · \($0)" } ?? "")
            detail = checks.filter { $0.kind == .time }.map(\.title).joined(separator: " · ")
        case .unknown:
            title = sorted.first?.title ?? "Bilinmiyor"
            detail = sorted.first?.detail ?? ""
        }
        return Assessment(level: level, placeLevel: placeLevel, title: title, detail: detail,
                          zone: zone, unitName: unit, checks: sorted)
    }

    // MARK: - Mekân

    static func placeChecks(_ c: CLLocationCoordinate2D, accuracy: CLLocationAccuracy,
                            context ctx: HuntContext, settings: EvaluationSettings) -> [RuleCheck] {
        let acc = max(0, accuracy)
        var out: [RuleCheck] = []
        guard let zone = ctx.map.zone(at: c) else {
            return [RuleCheck(id: "kapsam", kind: .place, level: .unknown, title: "Harita kapsamı dışında",
                              detail: "Bu konum \(ctx.map.meta.title) sınırları dışında.")]
        }
        let rule = { (id: String) in ctx.regs?.distanceRule(id) }

        // 1) Haritadaki alan (2024-2025)
        switch zone.status {
        case .yasak:
            out.append(RuleCheck(id: "alan", kind: .place, level: .danger, title: zone.name, detail: zone.description))
        case .dikkat:
            out.append(RuleCheck(id: "alan", kind: .place, level: .caution, title: zone.name, detail: zone.description))
        case .disarida:
            out.append(RuleCheck(id: "alan", kind: .place, level: .caution, title: "Avlak olarak işaretli değil",
                                 detail: zone.description))
        case .izinli:
            out.append(RuleCheck(id: "alan", kind: .place, level: .safe, title: zone.name,
                                 detail: "Harita (\(ctx.map.meta.season)): \(zone.name)."))
        }

        // 2) 2026-2027 kararıyla tamamı kapatılan avlak birimleri
        if let label = ctx.features?.unitLabel(at: c),
           let closed = ctx.regs?.closedUnits?.first(where: { $0.label == label }) {
            out.append(RuleCheck(id: "kapali-" + label, kind: .place, level: .danger, title: closed.name,
                                 detail: "Avlağın tamamında av yasaktır (\(closed.ref)). Avlak sınırı eski haritadan yaklaşık belirlendi."))
        }

        // 3) 2026-2027 kararıyla gelen yeni alanlar (yaklaşık sınırlar)
        for o in ctx.regs?.overrides ?? [] {
            let inside = Geo.contains(o.polygon, c)
            let level: Level = o.status == .yasak ? .danger : .caution
            if inside {
                out.append(RuleCheck(id: "ov-" + o.id, kind: .place, level: level, title: o.name,
                                     detail: "\(o.note) (\(o.ref))"))
            } else {
                let d = Geo.distanceToBoundary(o.polygon, c)
                if o.buffer > 0, d - acc <= o.buffer {
                    out.append(RuleCheck(id: "ov-" + o.id, kind: .place, level: .danger,
                                         title: "\(o.name) sınırına \(Geo.formatDistance(d))",
                                         detail: "Bu sahanın \(Int(o.buffer)) m yakınında avlanmak yasaktır (MAK Madde 9). Sınır yaklaşıktır."))
                } else if d - acc <= settings.warningBuffer {
                    out.append(RuleCheck(id: "ov-" + o.id, kind: .place, level: .caution,
                                         title: "\(o.name) sınırına \(Geo.formatDistance(d))",
                                         detail: "Sınır yaklaşık çizildi; temkinli olun."))
                }
            }
        }

        // 4) Korunan alanların ve YHYS'nin 300 m çevresi yasak (Madde 9)
        if zone.key != "korunan_alan", zone.key != "yaban_hayvani_yerlestirme" {
            let m = rule("korunan")?.meters ?? 300
            if let n = ctx.map.nearest(to: c, within: m + acc, where: { $0.key == "korunan_alan" || $0.key == "yaban_hayvani_yerlestirme" }) {
                out.append(RuleCheck(id: "korunan", kind: .place, level: .danger,
                                     title: "\(n.zone.name) sınırına \(Geo.formatDistance(n.distance))",
                                     detail: "Korunan alanların \(Int(m)) m yakınında avlanmak ve kılıfsız tüfekle köpekle dolaşmak yasaktır (\(rule("korunan")?.ref ?? "Madde 9"))."))
            }
        }
        // Ava yasak alana yaklaşma (yasal tampon yok; kullanıcı uyarısı)
        if zone.key != "ava_yasak",
           let n = ctx.map.nearest(to: c, within: settings.warningBuffer + acc, where: { $0.key == "ava_yasak" }) {
            out.append(RuleCheck(id: "yasak-yakin", kind: .place, level: .caution,
                                 title: "Ava yasak alana \(Geo.formatDistance(n.distance))",
                                 detail: "Sınıra yakınsınız; haritanın sınır hassasiyeti birkaç yüz metredir."))
        }

        // 5) Meskûn yerler, mesire yerleri ve KGM yolları (Madde 8/7: 300 m)
        if let f = ctx.features {
            let m = rule("meskun")?.meters ?? 300
            if let p = f.nearestPlace(kinds: ["koy"], to: c, within: m + 500 + acc) {
                let legal = p.distance - acc <= m
                out.append(RuleCheck(id: "meskun", kind: .place, level: legal ? .danger : .caution,
                                     title: "\(p.place.title) \(Geo.formatDistance(p.distance))",
                                     detail: legal
                                        ? "Meskûn yerlere \(Int(m)) m içinde avlanmak yasaktır (\(rule("meskun")?.ref ?? "Madde 8/7"))."
                                        : "Köyün evleri merkez noktasından daha geniş bir alana yayılır; en yakın eve \(Int(m)) m kuralını uygulayın."))
            }
            if let p = f.nearestPlace(kinds: ["ilce", "il"], to: c, within: m + 1500 + acc) {
                let legal = p.distance - acc <= m
                out.append(RuleCheck(id: "meskun-ilce", kind: .place, level: legal ? .danger : .caution,
                                     title: "\(p.place.title) \(Geo.formatDistance(p.distance))",
                                     detail: "Yerleşim alanına \(Int(m)) m içinde avlanmak yasaktır; ilçe yerleşimleri geniş bir alana yayılır."))
            }
            let mm = rule("mesire")?.meters ?? 300
            if let p = f.nearestPlace(kinds: ["mesire"], to: c, within: mm + 200 + acc) {
                let legal = p.distance - acc <= mm
                out.append(RuleCheck(id: "mesire", kind: .place, level: legal ? .danger : .caution,
                                     title: "Mesire yerine \(Geo.formatDistance(p.distance))",
                                     detail: "Mesire, piknik ve orman içi dinlenme yerlerine \(Int(mm)) m içinde avlanmak yasaktır (\(rule("mesire")?.ref ?? "Madde 8"))."))
            }
            let rm = rule("kgm")?.meters ?? 300
            if let d = f.nearestRoad(kind: "kgm", to: c, within: rm + acc) {
                out.append(RuleCheck(id: "kgm", kind: .place, level: .danger,
                                     title: "Karayoluna \(Geo.formatDistance(d))",
                                     detail: "Karayolları Genel Müdürlüğü yollarına \(Int(rm)) m içinde avlanmak yasaktır (\(rule("kgm")?.ref ?? "Madde 8")). Yol sınıfı haritadan alınmıştır."))
            } else if let d = f.nearestRoad(kind: "asfalt", to: c, within: rm + acc) {
                out.append(RuleCheck(id: "asfalt", kind: .place, level: .caution,
                                     title: "Asfalt yola \(Geo.formatDistance(d))",
                                     detail: "Bu yol bir KGM yoluysa \(Int(rm)) m içinde avlanmak yasaktır."))
            }
        }

        // 6) OpenStreetMap: yerleşim alanları, okul, sağlık, askeri alan, cezaevi vb. (300/500 m)
        if let osm = ctx.osm {
            let maxMeters = osm.classes.map(\.meters).max() ?? 500
            let near = osm.nearestPerClass(to: c, within: maxMeters + acc)
            for cls in osm.classes {
                guard let d = near[cls.id], d - acc <= cls.meters else { continue }
                let level: Level = cls.level == "yasak" ? .danger : .caution
                out.append(RuleCheck(id: "osm-" + cls.key, kind: .place, level: level,
                                     title: "\(cls.name): \(Geo.formatDistance(d))",
                                     detail: (level == .danger
                                        ? "Buraya \(Int(cls.meters)) m içinde avlanmak yasaktır (\(cls.rule))."
                                        : "Orman içi, belediye veya DSİ göletiyse \(Int(cls.meters)) m içinde avlanmak yasaktır (\(cls.rule)).")
                                        + " Kaynak: OpenStreetMap."))
            }
        }

        if acc > max(50, settings.warningBuffer / 2) {
            out.append(RuleCheck(id: "gps", kind: .place, level: .caution, title: "GPS doğruluğu düşük (±\(Int(acc)) m)",
                                 detail: "Konum kesinleşene kadar mesafe kurallarına göre temkinli olun."))
        }
        return out
    }

    // MARK: - Zaman

    static func timeChecks(_ c: CLLocationCoordinate2D, at date: Date, regs: Regulations) -> [RuleCheck] {
        var out: [RuleCheck] = []
        let inSeason = regs.groupsInSeason(on: date)
        let today = regs.huntableToday(on: date)
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        time.timeZone = TimeZone(identifier: "Europe/Istanbul")

        if inSeason.isEmpty {
            out.append(RuleCheck(id: "sezon", kind: .time, level: .danger, title: "Av sezonu kapalı",
                                 detail: "Bugün \(regs.region) bölgesinde avına izin verilen tür yok."))
            return out
        }
        if today.isEmpty {
            let next = regs.upcomingHuntingDays(from: date.addingTimeInterval(86_400), count: 1).first
            let f = DateFormatter()
            f.locale = Locale(identifier: "tr_TR")
            f.dateFormat = "d MMMM EEEE"
            f.timeZone = TimeZone(identifier: "Europe/Istanbul")
            out.append(RuleCheck(id: "gun", kind: .time, level: .danger, title: "Bugün av günü değil",
                                 detail: "Av günleri: Çarşamba, Cumartesi, Pazar ve resmi tatiller (Salı: yaban domuzu, 1. ve 3. grup kuşlar)."
                                    + (next.map { " Sonraki av günü: \(f.string(from: $0.date))." } ?? "")))
        } else {
            let species = today.flatMap(\.species)
            out.append(RuleCheck(id: "gun", kind: .time, level: .safe,
                                 title: regs.holiday(on: date).map { "Av günü (\($0))" } ?? "Bugün av günü",
                                 detail: "Açık türler: " + species.joined(separator: ", ")))
        }
        if let w = regs.huntingWindow(on: date, at: c) {
            let window = "\(time.string(from: w.start))–\(time.string(from: w.end))"
            if date < w.start || date > w.end {
                out.append(RuleCheck(id: "saat", kind: .time, level: .danger, title: "Avlanma saati dışında",
                                     detail: "Bugün avlanma zamanı \(window) (gün doğumundan 1 saat önce – gün batımından 1 saat sonra)."))
            } else {
                out.append(RuleCheck(id: "saat", kind: .time, level: .safe, title: "Av saati \(window)",
                                     detail: "Gün doğumundan 1 saat önce ile gün batımından 1 saat sonrası arası."))
            }
        }
        return out
    }
}
