import Foundation

// MARK: - Öneri motorunun girdi ve çıktı tipleri (saf veri; bkz. AmmoAdvisor)

/// Yasal bağlam: o gün avlanabilir türler (sezon + av günü), ilde yasak ve korunan türler.
struct HuntLegalContext: Sendable {
    let openSpecies: Set<String>
    let provinceBanned: Set<String>
    let protectedNames: Set<String>

    init(openSpecies: Set<String>, provinceBanned: Set<String> = [], protectedNames: Set<String> = []) {
        self.openSpecies = openSpecies
        self.provinceBanned = provinceBanned
        self.protectedNames = protectedNames
    }

    /// MAK verisinden: o gün av günü olan gruplardaki türler (ilde yasak olanlar çıkarılmış).
    init(regs: Regulations, day: Date) {
        openSpecies = Set(regs.huntableToday(on: day).flatMap(\.species))
        provinceBanned = Set(regs.provinceBannedSpecies)
        protectedNames = Set(regs.protectedLatin?.values.map { $0 } ?? [])
    }
}

/// Bir tür neden seçilemez.
enum SpeciesRejection: Equatable, Sendable {
    case provinceBanned, protected, closedToday, unknown

    var text: String {
        switch self {
        case .provinceBanned: return L("İstanbul'da avı yasak")
        case .protected: return L("Korunan tür: avlanamaz")
        case .closedToday: return L("Bugün avı kapalı (sezon ya da av günü değil)")
        case .unknown: return L("Bilgi tablosunda yok")
        }
    }
}

struct AdvisorRequest: Sendable {
    var species: [String]
    /// AvMuhimmat.json `terrains` kimliği (isteğe bağlı).
    var terrain: String?
    var firearms: [Firearm]
}

enum ShotMaterial: String, Sendable {
    case lead, steel

    var title: String { self == .lead ? L("Kurşun") : L("Çelik") }
}

/// Saçmalı fişek önerisi.
struct ShotLoad: Equatable, Sendable {
    /// Bu fişeğin hangi türler için olduğu (ortak fişekte birden çok).
    let species: [String]
    let material: ShotMaterial
    /// Türk (kıta Avrupası) saçma numarası, ör. "7.5".
    let size: String
    let mm: Double?
    /// Önerilen gramaj aralığı (g); kalibre ve yatak boyuna göre kırpılmış.
    let grams: ClosedRange<Int>
    /// Fişek boyu (mm); her zaman yatak boyundan kısa ya da eşit.
    let shellMm: Int
}

enum AmmoChoice: Equatable, Sendable {
    case shot(ShotLoad)
    case slug(grams: ClosedRange<Int>?, shellMm: Int)
    case rifle(caliber: String)

    var shellMm: Int? {
        switch self {
        case .shot(let l): return l.shellMm
        case .slug(_, let mm): return mm
        case .rifle: return nil
        }
    }

    var isSlug: Bool { if case .slug = self { return true } else { return false } }
    var shotLoad: ShotLoad? { if case .shot(let l) = self { return l } else { return nil } }
}

/// Bir namlu için şok kararı.
struct BarrelPlan: Equatable, Sendable {
    enum Match: Equatable, Sendable {
        /// Önerilen şok elde / namluda.
        case exact
        /// Komşu şok kullanılır (önerilenden bir kademe farklı).
        case adjacent
        /// Önerilen şok yok; `use` en yakın kullanılabilir şoktur (varsa).
        case missing
        /// Bu namlu bu iş için kullanılmaz (ör. tek kurşunda dar sabit şok).
        case unusable
    }

    /// 0: 1. atış namlusu.
    let index: Int
    let want: Choke
    let use: Choke?
    let match: Match
    let fixed: Bool
}

/// Kısa açıklamalar (gerekçe, uyarı, eleme nedeni). Testler durumları, ekran `text`i kullanır.
enum AdvisorNote: Hashable, Sendable {
    // Eleme
    case rifleBanned(species: String)
    case gaugeUnsuitable(gauge: String, species: String)
    case slugTightChoke
    case slugChokeMissing
    case rifleCaliberWeak(caliber: String, species: String)
    case loadNeedsMagnum(species: String)
    // Uyarı
    case chokeSuggested(Choke)
    case chokeAdjacent(have: Choke, want: Choke)
    case fixedChokeOff(have: Choke, want: Choke)
    case fireOpenBarrelFirst
    case slugOnlyBarrel(Choke)
    case shortChamber(species: String, grams: Int)
    case steelNotProof
    case steelUnknown
    case steelFixedTight
    case steelNeedsMagnum
    case longBarrelInCover
    case shortBarrelForPass
    case heavyForWalking
    case unknownRifleCaliber
    case twoLoads
    case compromise
    // Gerekçe
    case chokesReady
    case slugChokeReady
    case magnumOk
    case lightGauge
    case strongGauge
    case barrelFits
    case shortBarrelForDrive
    case lightForWalking
    case twoBarrels
    case steelOk
    case softRecoil
    case rifleCaliberGood(caliber: String)
    case rifleForBoar
    // Genel
    case pattern
    case takoz
    case boarSlugOnly
    case boarConflict(species: [String])
    case wetlandNonToxic
    case lowConfidence(species: String)
    // Eksik
    case noFirearms
    case needSlugOrRifle
    case needShotgun(species: String)
    case needGauge(species: String, gauge: String)
    case needMagnum(species: String)

    // swiftlint:disable:next function_body_length
    var text: String {
        switch self {
        case .rifleBanned(let s): return L("Yivli tüfek %@ avında kullanılamaz (MAK 10/1-ğ).", LD(s))
        case .gaugeUnsuitable(let g, let s): return L("%@ kalibre %@ için önerilmez.", g, LD(s))
        case .slugTightChoke: return L("Tek kurşun 1–3 numara dar şokla atılmaz; 5 (silindir), 4 ya da paradoks şok gerekir.")
        case .slugChokeMissing: return L("Tek kurşun için 5 (silindir), 4 ya da paradoks şok gerekir; elinizde yok.")
        case .rifleCaliberWeak(let c, let s): return L("%@ %@ için zayıf (en az 6,5 mm önerilir).", c, LD(s))
        case .loadNeedsMagnum(let s): return L("%@ için gereken yük 70 mm yatağa sığmaz: 76 mm (magnum) yatak gerekir.", LD(s))
        case .chokeSuggested(let c): return L("%@ numara şok önerilir (%@); elinizde yok.", c.badge, c.title)
        case .chokeAdjacent(let h, let w): return L("Elinizdeki %@ numara şok kullanılır; %@ numara daha uygun.", h.badge, w.badge)
        case .fixedChokeOff(let h, let w): return L("Sabit %@ numara şok, önerilen %@ numaradan farklı: atış mesafesini ona göre seçin.", h.badge, w.badge)
        case .fireOpenBarrelFirst: return L("Önce daha açık şoklu namluyu ateşleyin (seçici tetik).")
        case .slugOnlyBarrel(let c): return L("Tek kurşunu yalnızca %@ numara şoklu namluda kullanın; diğer namlu dar.", c.badge)
        case .shortChamber(let s, let g): return L("Yatak kısa: %@ için en çok %@ g fişek atılabilir; mesafeyi kısa tutun.", LD(s), String(g))
        case .steelNotProof: return L("Tüfek çeliğe uygun değil: kurşun önerildi. Kurşunsuz istiyorsanız bizmut ya da tungsten kullanın.")
        case .steelUnknown: return L("Çelik uygunluğu bilinmiyor: namluda \"STEEL\" / çelik muayene damgası yoksa çelik atmayın; kurşun önerildi.")
        case .steelFixedTight: return L("Sabit şok çelik için çok dar (en dar 3 numara): kurşun önerildi.")
        case .steelNeedsMagnum: return L("Gereken çelik yükü bu yatağa sığmaz: kurşun önerildi.")
        case .longBarrelInCover: return L("Namlu bu arazi için uzun; çalıda hızlı dönüşü zorlaştırır.")
        case .shortBarrelForPass: return L("Namlu bu arazi için kısa; uzak atışta salınım zorlaşır.")
        case .heavyForWalking: return L("Ağır tüfek uzun yürüyüşte yorar.")
        case .unknownRifleCaliber: return L("Kalibre listede yok: mermi enerjisini kontrol edin (100 m'de en az 2000 J önerilir).")
        case .twoLoads: return L("Bu türler için ortak saçma yok: iki ayrı fişek taşıyın.")
        case .compromise: return L("Birden çok tür için ortak öneri: tek tek en iyisi değil, birlikte en dengelisi.")
        case .chokesReady: return L("Önerilen şoklar elinizde.")
        case .slugChokeReady: return L("Tek kurşun için uygun şok var.")
        case .magnumOk: return L("76 mm yatak magnum fişek atabilir.")
        case .lightGauge: return L("Hafif kalibre bu küçük av için yeterli ve rahat.")
        case .strongGauge: return L("12 kalibre iri av için güçlü.")
        case .barrelFits: return L("Namlu boyu bu arazi için uygun.")
        case .shortBarrelForDrive: return L("Kısa namlu sürekte hızlı.")
        case .lightForWalking: return L("Hafif tüfek yürüyüş avında yormaz.")
        case .twoBarrels: return L("İki namlu: yakın ve uzak atış için iki farklı şok.")
        case .steelOk: return L("Çeliğe uygun: sulak alanda kurşunsuz saçma atabilir.")
        case .softRecoil: return L("Yarı otomatik: iri fişekte geri tepme daha yumuşak.")
        case .rifleCaliberGood(let c): return L("%@ bu av için yeterli.", c)
        case .rifleForBoar: return L("Yivli tüfek domuzda uzak ve isabetli atış sağlar.")
        case .pattern: return L("Öneri başlangıç noktasıdır: tüfeğinizi 30–35 m'de patern tahtasında deneyin. Yasal sorumluluk avcıdadır.")
        case .takoz: return L("Yarı otomatik ve pompalıda hazneye takoz: en çok 2+1 fişek (MAK 10/1-a).")
        case .boarSlugOnly: return L("Domuz avında yalnızca tek kurşunlu fişek bulundurulabilir; saçmalı fişek yanınızda olmasın (MAK 10/1-ı).")
        case .boarConflict(let s):
            return L("Domuz avında yalnızca tek kurşun bulundurulabildiği için %@ aynı avda seçilemez.", s.map(LD).joined(separator: ", "))
        case .wetlandNonToxic: return L("Sulak alanda kurşunsuz (çelik, bizmut, tungsten) saçma etik öneridir; yasal zorunluluk değildir.")
        case .lowConfidence(let s): return L("%@ için bilgi güveni düşük: değerleri doğrulanmamış başlangıç noktası sayın.", LD(s))
        case .noFirearms: return L("Önce Tüfeklerim'e en az bir tüfek ekleyin.")
        case .needSlugOrRifle: return L("Yaban domuzu için 5 (silindir), 4 ya da paradoks şoklu yivsiz tüfek ya da en az 6,5 mm yivli tüfek gerekir.")
        case .needShotgun(let s): return L("%@ avında yivli kullanılamaz; yivsiz av tüfeği gerekir.", LD(s))
        case .needGauge(let s, let g): return L("%@ için en az %@ kalibre yivsiz tüfek gerekir.", LD(s), g)
        case .needMagnum(let s): return L("%@ için 12 kalibre ve 76 mm (magnum) yatak önerilir.", LD(s))
        }
    }
}

/// Uygun bir tüfek için öneri.
struct Recommendation: Identifiable, Equatable, Sendable {
    var id: UUID { firearm.id }
    let firearm: Firearm
    let score: Int
    let ammo: [AmmoChoice]
    let barrels: [BarrelPlan]
    let reasons: [AdvisorNote]
    let cautions: [AdvisorNote]
}

/// Uygun olmayan tüfek ve nedenleri.
struct UnsuitableFirearm: Identifiable, Equatable, Sendable {
    var id: UUID { firearm.id }
    let firearm: Firearm
    let reasons: [AdvisorNote]
}

struct RejectedSpecies: Equatable, Sendable {
    let name: String
    let reason: SpeciesRejection
}

struct AdvisorResult: Equatable, Sendable {
    /// Uygun tüfekler, en iyisi önce.
    let picks: [Recommendation]
    let unsuitable: [UnsuitableFirearm]
    let rejected: [RejectedSpecies]
    /// Hesaba katılan türler (bilgi tablosundaki adlar).
    let species: [String]
    /// Genel notlar (takoz, domuz avı, sulak alan, düşük güven, patern).
    let notes: [AdvisorNote]
    /// Uygun tüfek yoksa ne gerektiği.
    let missing: [AdvisorNote]

    var first: Recommendation? { picks.first }
    var second: Recommendation? { picks.dropFirst().first }
    var others: [Recommendation] { Array(picks.dropFirst(2)) }
}
