import CoreLocation
import Foundation

/// Değerlendirmede kullanılan tüm veri.
struct HuntContext {
    let map: HuntingMap
    let features: MapFeatures?
    let regs: Regulations?
    var osm: OSMLayer? = nil
    /// Kullanıcının yüklediği AVBİS izin belgeleri (boşsa izin denetimi yapılmaz).
    var permits: [HuntPermit] = []
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

    static let waiting = Assessment(level: .unknown, placeLevel: .unknown, title: L("Konum bekleniyor…"),
                                    detail: L("GPS sinyali alınıyor."), zone: nil, unitName: nil, checks: [])

    /// "Kesin Konum" kapalı: iOS konumu km'lerce bulanıklaştırdığı için alan belirlenemez.
    static func reducedAccuracy(_ accuracy: CLLocationAccuracy) -> Assessment {
        let detail = L("iPhone yalnızca yaklaşık konum veriyor (±%@ m). Yasak alanda olup olmadığınız belirlenemez. Kesin Konum'u açın.", String(Int(accuracy)))
        return Assessment(level: .danger, placeLevel: .caution, title: L("Kesin Konum kapalı"),
                          detail: detail, zone: nil, unitName: nil,
                          checks: [RuleCheck(id: "kesin_konum", kind: .place, level: .danger,
                                             title: L("Kesin Konum kapalı"),
                                             detail: L("Ayarlar › Gizlilik › Konum Servisleri › Av Haritası › Kesin Konum"))])
    }

    static func evaluate(_ c: CLLocationCoordinate2D,
                         accuracy: CLLocationAccuracy,
                         at date: Date,
                         context ctx: HuntContext,
                         settings: EvaluationSettings) -> Assessment {
        var checks = placeChecks(c, accuracy: accuracy, context: ctx, settings: settings)
        if let p = permitCheck(c, at: date, context: ctx) { checks.append(p) }
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
            title = L("AVLANMAYIN: %@", reasons[0].title)
            detail = reasons.count > 1
                ? reasons[0].detail + " " + L("(+%@ yasak daha)", String(reasons.count - 1))
                : reasons[0].detail
        case .caution:
            title = L("Dikkat: %@", sorted[0].title)
            detail = sorted[0].detail
        case .safe:
            title = L("Avlanabilirsiniz") + (unit.map { " · \($0)" } ?? "")
            detail = checks.filter { $0.kind == .time }.map(\.title).joined(separator: " · ")
        case .unknown:
            title = sorted.first?.title ?? L("Bilinmiyor")
            detail = sorted.first?.detail ?? ""
        }
        return Assessment(level: level, placeLevel: placeLevel, title: title, detail: detail,
                          zone: zone, unitName: unit, checks: sorted)
    }

    // MARK: - İzin belgesi

    /// Genel ve devlet avlaklarında AVBİS'ten o güne ve o avlağa ait avlanma izin belgesi gerekir (Madde 6).
    /// Yalnızca kullanıcı en az bir belge yüklediyse denetlenir.
    static func permitCheck(_ c: CLLocationCoordinate2D, at date: Date, context ctx: HuntContext) -> RuleCheck? {
        guard !ctx.permits.isEmpty, let regs = ctx.regs, let label = ctx.features?.unitLabel(at: c),
              let zone = ctx.map.zone(at: c), zone.status == .izinli else { return nil }
        let here = regs.avlaklar.filter { $0.unit == label }
        guard let hereName = here.first?.name else { return nil }
        let today = ctx.permits.filter { $0.isValid(on: date) }
        if today.isEmpty {
            return RuleCheck(id: "izin", kind: .place, level: .caution, title: L("Bugün için izin belgesi yok"),
                             detail: L("Genel ve devlet avlaklarında AVBİS'ten o güne ait avlanma izin belgesi gerekir. Yüklediğiniz belgeler başka günler için."))
        }
        if let p = today.first(where: { pm in here.contains { $0.name == pm.avlak } }) {
            let q = p.quotas.map { "\(LD($0.species)) \($0.count)" }.joined(separator: " · ")
            return RuleCheck(id: "izin", kind: .place, level: .safe, title: L("İzin belgesi: %@", LD(p.avlak)),
                             detail: q.isEmpty ? L("Bugün geçerli.") : L("Bugün geçerli. Kota: %@", q))
        }
        return RuleCheck(id: "izin", kind: .place, level: .caution, title: L("İzin belgeniz bu avlak için değil"),
                         detail: L("Belgeniz %@ için; şu an %@ içindesiniz (avlak sınırı yaklaşık).", LD(today[0].avlak), LD(hereName)))
    }

    // MARK: - Mekân

    static func placeChecks(_ c: CLLocationCoordinate2D, accuracy: CLLocationAccuracy,
                            context ctx: HuntContext, settings: EvaluationSettings) -> [RuleCheck] {
        let acc = max(0, accuracy)
        var out: [RuleCheck] = []
        guard let zone = ctx.map.zone(at: c) else {
            return [RuleCheck(id: "kapsam", kind: .place, level: .unknown, title: L("Harita kapsamı dışında"),
                              detail: L("Bu konum %@ sınırları dışında.", LD(ctx.map.meta.title)))]
        }
        let rule = { (id: String) in ctx.regs?.distanceRule(id) }

        // 1) Haritadaki alan (2024-2025)
        switch zone.status {
        case .yasak:
            out.append(RuleCheck(id: "alan", kind: .place, level: .danger, title: LD(zone.name), detail: LD(zone.description)))
        case .dikkat:
            out.append(RuleCheck(id: "alan", kind: .place, level: .caution, title: LD(zone.name), detail: LD(zone.description)))
        case .disarida:
            out.append(RuleCheck(id: "alan", kind: .place, level: .caution, title: L("Avlak olarak işaretli değil"),
                                 detail: LD(zone.description)))
        case .izinli:
            out.append(RuleCheck(id: "alan", kind: .place, level: .safe, title: LD(zone.name),
                                 detail: L("Harita (%@): %@.", ctx.map.meta.season, LD(zone.name))))
        }

        // 2) 2026-2027 kararıyla tamamı kapatılan avlak birimleri
        if let label = ctx.features?.unitLabel(at: c),
           let closed = ctx.regs?.closedUnits?.first(where: { $0.label == label }) {
            out.append(RuleCheck(id: "kapali-" + label, kind: .place, level: .danger, title: LD(closed.name),
                                 detail: L("Avlağın tamamında av yasaktır (%@). Avlak sınırı eski haritadan yaklaşık belirlendi.", LD(closed.ref))))
        }

        // 3) 2026-2027 kararıyla gelen yeni alanlar (yaklaşık sınırlar)
        for o in ctx.regs?.overrides ?? [] {
            let inside = Geo.contains(o.polygon, c)
            let level: Level = o.status == .yasak ? .danger : .caution
            if inside {
                out.append(RuleCheck(id: "ov-" + o.id, kind: .place, level: level, title: LD(o.name),
                                     detail: "\(LD(o.note)) (\(LD(o.ref)))"))
            } else {
                let d = Geo.distanceToBoundary(o.polygon, c)
                if o.buffer > 0, d - acc <= o.buffer {
                    out.append(RuleCheck(id: "ov-" + o.id, kind: .place, level: .danger,
                                         title: L("%@ sınırına %@", LD(o.name), Geo.formatDistance(d)),
                                         detail: L("Bu sahanın %@ m yakınında avlanmak yasaktır (MAK Madde 9). Sınır yaklaşıktır.", String(Int(o.buffer)))))
                } else if d - acc <= settings.warningBuffer {
                    out.append(RuleCheck(id: "ov-" + o.id, kind: .place, level: .caution,
                                         title: L("%@ sınırına %@", LD(o.name), Geo.formatDistance(d)),
                                         detail: L("Sınır yaklaşık çizildi; temkinli olun.")))
                }
            }
        }

        // 4) Korunan alanların ve YHYS'nin 300 m çevresi yasak (Madde 9)
        if zone.key != "korunan_alan", zone.key != "yaban_hayvani_yerlestirme" {
            let m = rule("korunan")?.meters ?? 300
            if let n = ctx.map.nearest(to: c, within: m + acc, where: { $0.key == "korunan_alan" || $0.key == "yaban_hayvani_yerlestirme" }) {
                out.append(RuleCheck(id: "korunan", kind: .place, level: .danger,
                                     title: L("%@ sınırına %@", LD(n.zone.name), Geo.formatDistance(n.distance)),
                                     detail: L("Korunan alanların %@ m yakınında avlanmak ve kılıfsız tüfekle köpekle dolaşmak yasaktır (%@).", String(Int(m)), LD(rule("korunan")?.ref ?? "Madde 9"))))
            }
        }
        // Ava yasak alana yaklaşma (yasal tampon yok; kullanıcı uyarısı)
        if zone.key != "ava_yasak",
           let n = ctx.map.nearest(to: c, within: settings.warningBuffer + acc, where: { $0.key == "ava_yasak" }) {
            out.append(RuleCheck(id: "yasak-yakin", kind: .place, level: .caution,
                                 title: L("Ava yasak alana %@", Geo.formatDistance(n.distance)),
                                 detail: L("Sınıra yakınsınız; haritanın sınır hassasiyeti birkaç yüz metredir.")))
        }

        // 5) Meskûn yerler, mesire yerleri ve KGM yolları (Madde 8/7: 300 m)
        if let f = ctx.features {
            let m = rule("meskun")?.meters ?? 300
            if let p = f.nearestPlace(kinds: ["koy"], to: c, within: m + 500 + acc) {
                let legal = p.distance - acc <= m
                out.append(RuleCheck(id: "meskun", kind: .place, level: legal ? .danger : .caution,
                                     title: "\(p.place.title) \(Geo.formatDistance(p.distance))",
                                     detail: legal
                                        ? L("Meskûn yerlere %@ m içinde avlanmak yasaktır (%@).", String(Int(m)), LD(rule("meskun")?.ref ?? "Madde 8/7"))
                                        : L("Köyün evleri merkez noktasından daha geniş bir alana yayılır; en yakın eve %@ m kuralını uygulayın.", String(Int(m)))))
            }
            if let p = f.nearestPlace(kinds: ["ilce", "il"], to: c, within: m + 1500 + acc) {
                let legal = p.distance - acc <= m
                out.append(RuleCheck(id: "meskun-ilce", kind: .place, level: legal ? .danger : .caution,
                                     title: "\(p.place.title) \(Geo.formatDistance(p.distance))",
                                     detail: L("Yerleşim alanına %@ m içinde avlanmak yasaktır; ilçe yerleşimleri geniş bir alana yayılır.", String(Int(m)))))
            }
            let mm = rule("mesire")?.meters ?? 300
            if let p = f.nearestPlace(kinds: ["mesire"], to: c, within: mm + 200 + acc) {
                let legal = p.distance - acc <= mm
                out.append(RuleCheck(id: "mesire", kind: .place, level: legal ? .danger : .caution,
                                     title: L("Mesire yerine %@", Geo.formatDistance(p.distance)),
                                     detail: L("Mesire, piknik ve orman içi dinlenme yerlerine %@ m içinde avlanmak yasaktır (%@).", String(Int(mm)), LD(rule("mesire")?.ref ?? "Madde 8"))))
            }
            let rm = rule("kgm")?.meters ?? 300
            if let d = f.nearestRoad(kind: "kgm", to: c, within: rm + acc) {
                out.append(RuleCheck(id: "kgm", kind: .place, level: .danger,
                                     title: L("Karayoluna %@", Geo.formatDistance(d)),
                                     detail: L("Karayolları Genel Müdürlüğü yollarına %@ m içinde avlanmak yasaktır (%@). Yol sınıfı haritadan alınmıştır.", String(Int(rm)), LD(rule("kgm")?.ref ?? "Madde 8"))))
            } else if let d = f.nearestRoad(kind: "asfalt", to: c, within: rm + acc) {
                out.append(RuleCheck(id: "asfalt", kind: .place, level: .caution,
                                     title: L("Asfalt yola %@", Geo.formatDistance(d)),
                                     detail: L("Bu yol bir KGM yoluysa %@ m içinde avlanmak yasaktır.", String(Int(rm)))))
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
                                     title: "\(LD(cls.name)): \(Geo.formatDistance(d))",
                                     detail: (level == .danger
                                        ? L("Buraya %@ m içinde avlanmak yasaktır (%@).", String(Int(cls.meters)), LD(cls.rule))
                                        : L("Orman içi, belediye veya DSİ göletiyse %@ m içinde avlanmak yasaktır (%@).", String(Int(cls.meters)), LD(cls.rule)))
                                        + " " + L("Kaynak: OpenStreetMap.")))
            }
        }

        if acc > max(50, settings.warningBuffer / 2) {
            out.append(RuleCheck(id: "gps", kind: .place, level: .caution, title: L("GPS doğruluğu düşük (±%@ m)", String(Int(acc))),
                                 detail: L("Konum kesinleşene kadar mesafe kurallarına göre temkinli olun.")))
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
            out.append(RuleCheck(id: "sezon", kind: .time, level: .danger, title: L("Av sezonu kapalı"),
                                 detail: L("Bugün %@ bölgesinde avına izin verilen tür yok.", LD(regs.region))))
            return out
        }
        if today.isEmpty {
            let next = regs.upcomingHuntingDays(from: date.addingTimeInterval(86_400), count: 1).first
            let f = DateFormatter()
            f.locale = AppLocale.current
            f.dateFormat = "d MMMM EEEE"
            f.timeZone = TimeZone(identifier: "Europe/Istanbul")
            out.append(RuleCheck(id: "gun", kind: .time, level: .danger, title: L("Bugün av günü değil"),
                                 detail: L("Av günleri: Çarşamba, Cumartesi, Pazar ve resmi tatiller (Salı: yaban domuzu, 1. ve 3. grup kuşlar).")
                                    + (next.map { " " + L("Sonraki av günü: %@.", f.string(from: $0.date)) } ?? "")))
        } else {
            let species = today.flatMap(\.species)
            out.append(RuleCheck(id: "gun", kind: .time, level: .safe,
                                 title: regs.holiday(on: date).map { L("Av günü (%@)", LD($0)) } ?? L("Bugün av günü"),
                                 detail: L("Açık türler: %@", species.map(LD).joined(separator: ", "))))
        }
        if let w = regs.huntingWindow(on: date, at: c) {
            let window = "\(time.string(from: w.start))–\(time.string(from: w.end))"
            if date < w.start || date > w.end {
                out.append(RuleCheck(id: "saat", kind: .time, level: .danger, title: L("Avlanma saati dışında"),
                                     detail: L("Bugün avlanma zamanı %@ (gün doğumundan 1 saat önce – gün batımından 1 saat sonra).", window)))
            } else {
                out.append(RuleCheck(id: "saat", kind: .time, level: .safe, title: L("Av saati %@", window),
                                     detail: L("Gün doğumundan 1 saat önce ile gün batımından 1 saat sonrası arası.")))
            }
        }
        return out
    }
}
