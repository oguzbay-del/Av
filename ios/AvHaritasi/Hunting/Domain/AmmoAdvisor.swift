import Foundation

// MARK: - Tüfek, şok ve saçma öneri motoru (saf mantık; AmmoAdvisorTests)
//
// Önce sert kurallar elenir (docs/plan/TUFEK_ONERI_PLANI.md "Sert kurallar"), sonra uygun tüfekler puanlanır:
//  1. İlde yasak (keklik), korunan ve o gün kapalı türler seçilemez.
//  2. Domuz avında yalnızca tek kurşun ya da yivli (MAK 10/1-ı); domuz dışındaki türlere tek kurşun hiç önerilmez
//     (ihtiyatlı uygulama kuralı, yasal iddia değil). Domuz kuş/tavşanla aynı avda seçilemez.
//  3. Yivli tüfek kuş ve tavşanda elenir (MAK 10/1-ğ).
//  4. Fişek boyu hiçbir zaman yatak boyunu aşmaz; gereken yük sığmıyorsa tüfek elenir ya da kurşuna geçilir.
//  5. Çelik yalnızca "çeliğe uygun: evet" tüfekte; çelikte 1 ve 2 numara şok önerilmez (en dar 3).
//  6. Tek kurşun yalnızca 5, 4 ya da paradoks şokla.
// Puan: şok sahipliği (tam > komşu > yok), yatak/magnum, kalibre, namlu-arazi uyumu, ağırlık-yürüyüş, çelik.

enum AmmoAdvisor {
    /// Bugün seçilebilir türler (bilgi tablosu sırasıyla).
    static func selectableSpecies(knowledge: AmmoKnowledge, legal: HuntLegalContext) -> [AmmoKnowledge.Species] {
        knowledge.species.filter { rejection(for: $0.name, knowledge: knowledge, legal: legal) == nil }
    }

    static func rejection(for name: String, knowledge: AmmoKnowledge, legal: HuntLegalContext) -> SpeciesRejection? {
        if legal.provinceBanned.contains(name) { return .provinceBanned }
        if legal.protectedNames.contains(name) { return .protected }
        guard knowledge.species(named: name) != nil else { return .unknown }
        guard legal.openSpecies.contains(name) else { return .closedToday }
        return nil
    }

    static func advise(_ request: AdvisorRequest, knowledge k: AmmoKnowledge, legal: HuntLegalContext) -> AdvisorResult {
        var rejected: [RejectedSpecies] = []
        var species: [AmmoKnowledge.Species] = []
        for name in request.species where !species.contains(where: { $0.name == name }) {
            if let r = rejection(for: name, knowledge: k, legal: legal) {
                rejected.append(RejectedSpecies(name: name, reason: r))
            } else if let s = k.species(named: name) {
                species.append(s)
            }
        }
        var notes: [AdvisorNote] = []
        func finish(_ picks: [Recommendation] = [], _ unsuitable: [UnsuitableFirearm] = [],
                    missing: [AdvisorNote] = []) -> AdvisorResult {
            AdvisorResult(picks: picks, unsuitable: unsuitable, rejected: rejected, species: species.map(\.name),
                          notes: notes + [.pattern], missing: missing)
        }
        guard !species.isEmpty else { return finish() }

        // Domuz avı: yalnızca tek kurşun/yivli → saçma gerektiren türlerle birleşmez
        let boarHunt = species.contains { $0.slug != nil }
        if boarHunt {
            let conflict = species.filter { $0.slug == nil && $0.rifle == nil }
            if !conflict.isEmpty {
                notes.append(.boarConflict(species: conflict.map(\.name)))
                return finish()
            }
            notes.append(.boarSlugOnly)
        }
        let terrain = k.terrain(request.terrain)
        if !boarHunt && (terrain?.id == "sulak_alan" || species.contains(where: \.isWaterfowl)) {
            notes.append(.wetlandNonToxic)
        }
        notes += species.filter(\.isLowConfidence).map { .lowConfidence(species: $0.name) }

        guard !request.firearms.isEmpty else { return finish(missing: [.noFirearms]) }

        var picks: [Recommendation] = []
        var unsuitable: [UnsuitableFirearm] = []
        for f in request.firearms {
            switch evaluate(f, species: species, boarHunt: boarHunt, terrain: terrain, knowledge: k) {
            case .success(let r): picks.append(r)
            case .failure(let e): unsuitable.append(UnsuitableFirearm(firearm: f, reasons: e.reasons))
            }
        }
        picks.sort { $0.score != $1.score ? $0.score > $1.score : $0.firearm.name < $1.firearm.name }
        if picks.contains(where: { $0.firearm.type.hasMagazine }) { notes.insert(.takoz, at: 0) }
        let missing = picks.isEmpty ? needs(for: species, boarHunt: boarHunt, firearms: request.firearms) : []
        return finish(picks, unsuitable, missing: missing)
    }

    // MARK: - Eksik açıklaması

    static func needs(for species: [AmmoKnowledge.Species], boarHunt: Bool, firearms: [Firearm]) -> [AdvisorNote] {
        if boarHunt { return [.needSlugOrRifle] }
        let onlyRifles = firearms.allSatisfy(\.type.isRifled)
        var out: [AdvisorNote] = []
        for s in species {
            if s.rifleBanned, onlyRifles { out.append(.needShotgun(species: s.name)) }
            if s.magnumNeeded {
                out.append(.needMagnum(species: s.name))
            } else if s.minGauge == "12" || s.minGauge == "16" || s.minGauge == "20" {
                out.append(.needGauge(species: s.name, gauge: s.minGauge))
            }
        }
        var seen = Set<AdvisorNote>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: - Tüfek değerlendirmesi

    struct Rejection: Error, Equatable { let reasons: [AdvisorNote] }

    static func evaluate(_ f: Firearm, species: [AmmoKnowledge.Species], boarHunt: Bool,
                         terrain: AmmoKnowledge.Terrain?, knowledge k: AmmoKnowledge) -> Result<Recommendation, Rejection> {
        if f.type.isRifled { return evaluateRifle(f, species: species, boarHunt: boarHunt) }
        guard let gauge = f.gauge, let chamber = f.chamber else { return .failure(Rejection(reasons: [])) }
        // Domuz avında kalibre yalnızca domuza göre (çakal da tek kurşunla vurulur)
        let gaugeCheck = boarHunt ? species.filter { $0.slug != nil } : species
        let badGauge = gaugeCheck.filter { !$0.gauges.contains(gauge.rawValue) }
        if !badGauge.isEmpty {
            return .failure(Rejection(reasons: badGauge.map { .gaugeUnsuitable(gauge: gauge.rawValue, species: $0.name) }))
        }
        if boarHunt, let boar = species.first(where: { $0.slug != nil }), let slug = boar.slug {
            return evaluateSlug(f, gauge: gauge, slug: slug, terrain: terrain)
        }
        return evaluateShot(f, gauge: gauge, chamber: chamber, species: species, terrain: terrain, knowledge: k)
    }

    // MARK: Yivli

    static func evaluateRifle(_ f: Firearm, species: [AmmoKnowledge.Species], boarHunt: Bool) -> Result<Recommendation, Rejection> {
        let banned = species.filter { $0.rifleBanned || $0.rifle == nil }
        if !banned.isEmpty { return .failure(Rejection(reasons: banned.map { .rifleBanned(species: $0.name) })) }
        let caliber = RifleCaliber.named(f.rifleCaliber)
        var weak: [AdvisorNote] = []
        for s in species {
            if let minMm = s.rifle?.minCaliberMm, let c = caliber, c.boreMm < minMm {
                weak.append(.rifleCaliberWeak(caliber: c.name, species: s.name))
            }
        }
        if !weak.isEmpty { return .failure(Rejection(reasons: weak)) }

        var score = 62
        var reasons: [AdvisorNote] = []
        var cautions: [AdvisorNote] = []
        let name = f.rifleCaliber ?? L("Yivli")
        if let c = caliber, species.allSatisfy({ $0.rifle?.calibers.contains(c.name) == true }) {
            score += 14
            reasons.append(.rifleCaliberGood(caliber: c.name))
        } else if caliber == nil {
            cautions.append(.unknownRifleCaliber)
        } else {
            score += 6
        }
        if boarHunt {
            score += 6
            reasons.append(.rifleForBoar)
        }
        return .success(Recommendation(firearm: f, score: score, ammo: [.rifle(caliber: name)], barrels: [],
                                       reasons: reasons, cautions: cautions))
    }

    // MARK: Tek kurşun (domuz)

    static func evaluateSlug(_ f: Firearm, gauge: Gauge, slug: AmmoKnowledge.Slug,
                             terrain: AmmoKnowledge.Terrain?) -> Result<Recommendation, Rejection> {
        let allowed = slug.chokes.isEmpty ? [Choke.cylinder, .improvedCylinder, .paradox] : slug.chokes
        let count = max(1, f.type.barrelCount)
        var barrels: [BarrelPlan] = []
        var cautions: [AdvisorNote] = []
        var reasons: [AdvisorNote] = []
        var score = 55
        if f.mobileChokes {
            guard let pick = allowed.first(where: { f.ownedChokes.contains($0) }) else {
                return .failure(Rejection(reasons: [.slugChokeMissing]))
            }
            barrels = (0..<count).map { BarrelPlan(index: $0, want: pick, use: pick, match: .exact, fixed: false) }
            reasons.append(.slugChokeReady)
            if pick == .paradox { score += 4 }
        } else {
            let fixed = Array(f.fixedChokes.prefix(count))
            let usable = fixed.filter { allowed.contains($0) }
            guard let firstUsable = usable.first else { return .failure(Rejection(reasons: [.slugTightChoke])) }
            barrels = fixed.enumerated().map { i, c in
                allowed.contains(c)
                    ? BarrelPlan(index: i, want: c, use: c, match: .exact, fixed: true)
                    : BarrelPlan(index: i, want: firstUsable, use: nil, match: .unusable, fixed: true)
            }
            if usable.count < fixed.count {
                cautions.append(.slugOnlyBarrel(firstUsable))
                score -= 6
            } else {
                reasons.append(.slugChokeReady)
            }
        }
        if f.barrelCm <= 61 {
            score += 6
            reasons.append(.shortBarrelForDrive)
        } else if f.barrelCm >= 71 {
            score -= 3
            cautions.append(.longBarrelInCover)
        }
        var grams: ClosedRange<Int>?
        if gauge == .g12 { grams = range(slug.grams12) }
        if gauge == .g20 { grams = range(slug.grams20) }
        return .success(Recommendation(firearm: f, score: score, ammo: [.slug(grams: grams, shellMm: ChamberLength.mm70.rawValue)],
                                       barrels: barrels, reasons: reasons, cautions: cautions))
    }

    // MARK: Saçma

    // swiftlint:disable:next function_body_length
    static func evaluateShot(_ f: Firearm, gauge: Gauge, chamber: ChamberLength, species: [AmmoKnowledge.Species],
                             terrain: AmmoKnowledge.Terrain?, knowledge k: AmmoKnowledge) -> Result<Recommendation, Rejection> {
        var reasons: [AdvisorNote] = []
        var cautions: [AdvisorNote] = []
        var score = 50
        let count = max(1, f.type.barrelCount)

        // Malzeme: sulak alan / su kuşu → çelik, yalnızca tüfek çeliğe uygunsa
        let wantsSteel = terrain?.id == "sulak_alan" || species.allSatisfy(\.isWaterfowl)
        var material: ShotMaterial = .lead
        if wantsSteel {
            switch f.steelProof {
            case .yes:
                if !f.mobileChokes, f.fixedChokes.contains(where: { $0.rawValue < k.steel.maxChokeId }) {
                    cautions.append(.steelFixedTight)
                } else {
                    material = .steel
                }
            case .no: cautions.append(.steelNotProof)
            case .unknown: cautions.append(.steelUnknown)
            }
        }

        // Fişek: ortak saçma ve gramaj; çelik yatağa sığmazsa kurşuna geç
        var loads = shotLoads(species: species, material: material, gauge: gauge, chamber: chamber, terrain: terrain, knowledge: k)
        if material == .steel, loads == nil {
            material = .lead
            cautions.append(.steelNeedsMagnum)
            loads = shotLoads(species: species, material: .lead, gauge: gauge, chamber: chamber, terrain: terrain, knowledge: k)
        }
        guard let built = loads else {
            let heavy = species.filter { minGrams($0, gauge: gauge) > gramCap(gauge: gauge, chamber: chamber, material: .lead) }
            return .failure(Rejection(reasons: heavy.map { .loadNeedsMagnum(species: $0.name) }))
        }
        cautions += built.cautions
        if material == .steel {
            score += 6
            reasons.append(.steelOk)
        } else if wantsSteel {
            score -= 3
        }

        // Şoklar: tür(ler)in 1./2. atış şoku, arazi kaydırması, çelikte en dar 3
        let wants = desiredChokes(species: species, steel: material == .steel, terrain: terrain, barrels: count,
                                  steelMax: k.steel.maxChokeId)
        let barrels = planBarrels(f, wants: wants, steel: material == .steel, steelMax: k.steel.maxChokeId)
        var chokePoints = 0
        for b in barrels {
            switch b.match {
            case .exact: chokePoints += 12
            case .adjacent:
                chokePoints += 5
                if let u = b.use { cautions.append(b.fixed ? .fixedChokeOff(have: u, want: b.want) : .chokeAdjacent(have: u, want: b.want)) }
            case .missing, .unusable:
                chokePoints -= b.fixed ? 8 : 12
                if b.fixed, let u = b.use {
                    cautions.append(.fixedChokeOff(have: u, want: b.want))
                } else {
                    cautions.append(.chokeSuggested(b.want))
                }
            }
        }
        score += chokePoints * 2 / count
        if barrels.allSatisfy({ $0.match == .exact }) { reasons.append(.chokesReady) }
        if count == 2, !f.mobileChokes, f.fixedChokes.count == 2, f.fixedChokes[0] < f.fixedChokes[1] {
            cautions.append(.fireOpenBarrelFirst)
        }
        if count == 2, species.contains(where: { $0.isWalkingHunt }) {
            score += 3
            reasons.append(.twoBarrels)
        }

        // Yatak / magnum
        if species.contains(where: \.magnumNeeded) {
            if chamber.rawValue >= ChamberLength.mm76.rawValue {
                score += 8
                reasons.append(.magnumOk)
            } else {
                score -= 10
            }
        }
        // Kalibre
        let small = species.allSatisfy { $0.minGauge == "28" || $0.minGauge == ".410" }
        if small, gauge != .g12 {
            score += 5
            reasons.append(.lightGauge)
        } else if gauge == .g12, species.contains(where: { $0.magnumNeeded || $0.minGauge == "12" }) {
            score += 4
            reasons.append(.strongGauge)
        }
        // Namlu boyu ↔ arazi
        let place = terrain?.id ?? species.first?.terrains.first ?? "acik_mera"
        let ideal = idealBarrel(place)
        if ideal.contains(f.barrelCm) {
            score += 6
            reasons.append(.barrelFits)
        } else if f.barrelCm > ideal.upperBound + 4 {
            score -= 4
            cautions.append(.longBarrelInCover)
        } else if f.barrelCm < ideal.lowerBound - 4 {
            score -= 4
            cautions.append(.shortBarrelForPass)
        }
        // Ağırlık ↔ yürüyüş
        let walking = species.allSatisfy(\.isWalkingHunt) && place != "gecit" && place != "sulak_alan"
        switch (f.weight, walking) {
        case (.light?, true):
            score += 4
            reasons.append(.lightForWalking)
        case (.heavy?, true):
            score -= 4
            cautions.append(.heavyForWalking)
        case (.heavy?, false): score += 2
        default: break
        }
        if f.type == .yariOtomatik, species.contains(where: { $0.magnumNeeded || $0.isWaterfowl }) {
            score += 2
            reasons.append(.softRecoil)
        }
        if species.count > 1, built.ammo.count == 1 { cautions.append(.compromise) }

        return .success(Recommendation(firearm: f, score: score, ammo: built.ammo, barrels: barrels,
                                       reasons: unique(reasons), cautions: unique(cautions)))
    }

    // MARK: - Fişek hesabı

    struct BuiltLoads: Equatable { let ammo: [AmmoChoice]; let cautions: [AdvisorNote] }

    /// Ortak saçma varsa tek fişek, yoksa tür başına fişek. Gereken en az gramaj yatağa sığmıyorsa nil.
    static func shotLoads(species: [AmmoKnowledge.Species], material: ShotMaterial, gauge: Gauge, chamber: ChamberLength,
                          terrain: AmmoKnowledge.Terrain?, knowledge k: AmmoKnowledge) -> BuiltLoads? {
        let steel = material == .steel
        let choices = species.compactMap { steel ? $0.steelShot : $0.leadShot }
        guard choices.count == species.count else { return nil }
        let shift = terrain?.shotShift ?? 0
        var groups: [(species: [AmmoKnowledge.Species], size: String)] = []
        if let common = commonShot(choices) {
            groups = [(species, common)]
        } else {
            groups = zip(species, choices).map { ([$0], $1.primary) }
        }
        var ammo: [AmmoChoice] = []
        var cautions: [AdvisorNote] = []
        if groups.count > 1 { cautions.append(.twoLoads) }
        for g in groups {
            let lo = g.species.map { minGrams($0, gauge: gauge, steel: steel) }.max() ?? 28
            let hiWanted = g.species.map { maxGrams($0, gauge: gauge, steel: steel) }.min() ?? 32
            let hi = max(lo, hiWanted)
            let magnum = g.species.contains(where: \.magnumNeeded)
            // Önce 70 mm; gerekiyorsa ve yatak izin veriyorsa 76/89 mm (yatak boyunu asla aşma)
            var shell = ChamberLength.mm70
            for c in ChamberLength.allCases where c.rawValue <= chamber.rawValue {
                shell = c
                let cap = gramCap(gauge: gauge, chamber: c, material: material)
                if cap >= hi || (!magnum && cap >= lo) { break }
            }
            let cap = gramCap(gauge: gauge, chamber: shell, material: material)
            guard cap >= lo else { return nil }
            // İri av çelikle yalnızca magnum (76 mm+) fişekle; kısa yatakta kurşuna geçilir
            if steel, magnum, shell.rawValue < ChamberLength.mm76.rawValue { return nil }
            if magnum, cap < hi, shell.rawValue < ChamberLength.mm76.rawValue, let s = g.species.first(where: \.magnumNeeded) {
                cautions.append(.shortChamber(species: s.name, grams: cap))
            }
            let size = k.shiftedShot(g.size, by: shift, steel: steel)
            ammo.append(.shot(ShotLoad(species: g.species.map(\.name), material: material, size: size, mm: k.shot(size)?.mm,
                                       grams: lo...min(hi, cap), shellMm: shell.rawValue)))
        }
        return BuiltLoads(ammo: ammo, cautions: cautions)
    }

    /// Tüm türlerin listesinde (birincil + alternatif) bulunan, sıra toplamı en küçük saçma.
    static func commonShot(_ choices: [AmmoKnowledge.ShotChoice]) -> String? {
        guard let firstChoice = choices.first else { return nil }
        var best: (id: String, cost: Int)?
        for id in firstChoice.all {
            var cost = 0
            var ok = true
            for c in choices {
                guard let i = c.all.firstIndex(of: id) else { ok = false; break }
                cost += i
            }
            if ok, best == nil || cost < best!.cost { best = (id, cost) }
        }
        return best?.id
    }

    /// Kalibreye göre tipik av yükü (12'de tablodaki değer; tabloda yoksa kalibrenin yaygın aralığı).
    static func gramRange(_ s: AmmoKnowledge.Species, gauge: Gauge) -> ClosedRange<Int> {
        switch gauge {
        case .g12: return range(s.loadGrams12) ?? 28...32
        case .g20: return range(s.loadGrams20) ?? 24...28
        case .g16: return 26...30
        case .g28: return 18...24
        case .g410: return 11...16
        }
    }

    /// Çelik saçma daha hafiftir: aynı yatakta ~4 g az.
    static func minGrams(_ s: AmmoKnowledge.Species, gauge: Gauge, steel: Bool = false) -> Int {
        gramRange(s, gauge: gauge).lowerBound - (steel ? 4 : 0)
    }

    static func maxGrams(_ s: AmmoKnowledge.Species, gauge: Gauge, steel: Bool = false) -> Int {
        gramRange(s, gauge: gauge).upperBound - (steel ? 4 : 0)
    }

    /// Yatak boyuna sığan en ağır yaygın yük (g). İhtiyatlı yuvarlak değerler.
    static func gramCap(gauge: Gauge, chamber: ChamberLength, material: ShotMaterial) -> Int {
        let lead: [Gauge: [ChamberLength: Int]] = [
            .g12: [.mm70: 36, .mm76: 46, .mm89: 57], .g16: [.mm70: 32, .mm76: 36, .mm89: 36],
            .g20: [.mm70: 28, .mm76: 35, .mm89: 35], .g28: [.mm70: 24, .mm76: 28, .mm89: 28],
            .g410: [.mm70: 14, .mm76: 18, .mm89: 18],
        ]
        let steel: [Gauge: [ChamberLength: Int]] = [
            .g12: [.mm70: 32, .mm76: 36, .mm89: 42], .g16: [.mm70: 28, .mm76: 30, .mm89: 30],
            .g20: [.mm70: 24, .mm76: 28, .mm89: 28], .g28: [.mm70: 18, .mm76: 21, .mm89: 21],
            .g410: [.mm70: 11, .mm76: 13, .mm89: 13],
        ]
        return (material == .lead ? lead : steel)[gauge]?[chamber] ?? 28
    }

    // MARK: - Şok hesabı

    /// İstenen şoklar, namlu sırasıyla (1. atış daha açık). Birden çok türde ortalama: 1. atış açığa, 2. dara yuvarlanır.
    static func desiredChokes(species: [AmmoKnowledge.Species], steel: Bool, terrain: AmmoKnowledge.Terrain?,
                              barrels: Int, steelMax: Int) -> [Choke] {
        let plans = species.compactMap(\.choke)
        guard !plans.isEmpty else { return Array(repeating: .modified, count: barrels) }
        let firsts = plans.map { steel ? $0.steelFirst : $0.first }
        let seconds = plans.map { steel ? $0.steelSecond : $0.second }
        let shift = terrain?.chokeShift ?? 0
        var first = Int((Double(firsts.reduce(0, +)) / Double(firsts.count)).rounded(.up)) + shift
        var second = Int((Double(seconds.reduce(0, +)) / Double(seconds.count)).rounded(.down)) + shift
        if steel {
            first = max(first, steelMax)
            second = max(second, steelMax)
        }
        if first < second { swap(&first, &second) }
        let a = Choke.clamped(first), b = Choke.clamped(second)
        return barrels >= 2 ? [a, b] : [a]
    }

    /// Her namlu için şok kararı. Mobilde sahip olunanlardan (çelikte 1–2 hariç), sabitte namludakinden.
    static func planBarrels(_ f: Firearm, wants: [Choke], steel: Bool, steelMax: Int) -> [BarrelPlan] {
        wants.enumerated().map { i, want in
            if !f.mobileChokes, i < f.fixedChokes.count {
                let have = f.fixedChokes[i]
                let d = have.distance(to: want) ?? 9
                return BarrelPlan(index: i, want: want, use: have, match: d == 0 ? .exact : (d == 1 ? .adjacent : .missing), fixed: true)
            }
            let owned = f.ownedChokes.filter { $0 != .paradox && (!steel || $0.rawValue >= steelMax) }
            if owned.contains(want) { return BarrelPlan(index: i, want: want, use: want, match: .exact, fixed: false) }
            let nearest = owned.min { (a, b) in
                let da = a.distance(to: want) ?? 9, db = b.distance(to: want) ?? 9
                return da != db ? da < db : a > b   // eşitlikte daha açık şok
            }
            if let n = nearest, n.distance(to: want) == 1 {
                return BarrelPlan(index: i, want: want, use: n, match: .adjacent, fixed: false)
            }
            return BarrelPlan(index: i, want: want, use: nearest, match: .missing, fixed: false)
        }
    }

    /// Arazi için uygun namlu boyu (cm).
    static func idealBarrel(_ terrain: String) -> ClosedRange<Int> {
        switch terrain {
        case "orman_cali": return 56...68
        case "sulak_alan": return 68...78
        case "gecit": return 71...81
        default: return 66...76
        }
    }

    private static func range(_ a: [Int]?) -> ClosedRange<Int>? {
        guard let a, a.count == 2, a[0] <= a[1] else { return nil }
        return a[0]...a[1]
    }

    private static func unique(_ a: [AdvisorNote]) -> [AdvisorNote] {
        var seen = Set<AdvisorNote>()
        return a.filter { seen.insert($0).inserted }
    }
}
