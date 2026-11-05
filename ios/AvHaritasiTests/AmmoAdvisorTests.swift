import XCTest
@testable import AvHaritasi

/// Tüfek/şok/saçma öneri motoru: her sert kural (docs/plan/TUFEK_ONERI_PLANI.md) ve tipik senaryolar.
final class AmmoAdvisorTests: XCTestCase {
    private var k: AmmoKnowledge!
    /// Bilgi tablosundaki tüm türler açık (sezon/gün kuralını ayrı testler denetler).
    private var allOpen: HuntLegalContext!

    override func setUpWithError() throws {
        k = try AmmoKnowledge.load()
        allOpen = HuntLegalContext(openSpecies: Set(k.species.map(\.name)),
                                   provinceBanned: ["Kınalı keklik", "Kum kekliği", "Çilkeklik"],
                                   protectedNames: ["Boz kaz", "Sülün"])
    }

    // MARK: Örnek tüfekler

    private func superpoze(owned: [Choke] = [.improvedCylinder, .cylinder], barrel: Int = 66,
                           weight: WeightClass? = .light) -> Firearm {
        Firearm(name: "Süperpoze", type: .superpoze, gauge: .g12, chamber: .mm76, barrelCm: barrel,
                mobileChokes: true, ownedChokes: owned, steelProof: .no, weight: weight)
    }

    private func semiAuto(chamber: ChamberLength = .mm76, steel: SteelProof = .yes,
                          owned: [Choke] = [.improvedModified, .modified, .improvedCylinder]) -> Firearm {
        Firearm(name: "Otomatik", type: .yariOtomatik, gauge: .g12, chamber: chamber, barrelCm: 71,
                mobileChokes: true, ownedChokes: owned, steelProof: steel, weight: .medium)
    }

    private func pump(fixed: Choke, chamber: ChamberLength = .mm70) -> Firearm {
        Firearm(name: "Pompalı", type: .pompali, gauge: .g12, chamber: chamber, barrelCm: 71,
                mobileChokes: false, fixedChokes: [fixed], steelProof: .no)
    }

    private func rifle(_ caliber: String = ".308 Win") -> Firearm {
        Firearm(name: "Yivli", type: .yivli, barrelCm: 56, rifleCaliber: caliber)
    }

    private func advise(_ species: [String], _ guns: [Firearm], terrain: String? = nil,
                        legal: HuntLegalContext? = nil) -> AdvisorResult {
        AmmoAdvisor.advise(AdvisorRequest(species: species, terrain: terrain, firearms: guns),
                           knowledge: k, legal: legal ?? allOpen)
    }

    // MARK: Bilgi tablosu

    func testKnowledgeLoads() {
        XCTAssertEqual(k.species.count, 30)
        XCTAssertEqual(k.species(named: "Yaban domuzu")?.slug?.chokes, [.cylinder, .improvedCylinder, .paradox])
        XCTAssertEqual(k.steel.maxChokeId, 3)
        XCTAssertEqual(k.shiftedShot("7", by: -1, steel: false), "6")
        XCTAssertEqual(k.shiftedShot("0", by: -1, steel: false), "0", "Kurşunda çeliğe özgü iri numara yok")
    }

    // MARK: Sert kural 1 — İstanbul'da keklik yasak

    func testPartridgeNotSelectableInIstanbul() throws {
        let regs = try TestData.regs()
        // 2. grup kuşlar sezonda (Kasım, Cumartesi) ama İstanbul'da yasak
        let legal = HuntLegalContext(regs: regs, day: TestData.istanbul("2026-11-07T09:00"))
        let names = AmmoAdvisor.selectableSpecies(knowledge: k, legal: legal).map(\.name)
        XCTAssertFalse(names.contains("Kınalı keklik"))
        XCTAssertFalse(names.contains("Çilkeklik"))
        XCTAssertEqual(AmmoAdvisor.rejection(for: "Kınalı keklik", knowledge: k, legal: legal), .provinceBanned)
        let r = advise(["Kınalı keklik"], [superpoze()], legal: legal)
        XCTAssertTrue(r.picks.isEmpty)
        XCTAssertEqual(r.rejected, [RejectedSpecies(name: "Kınalı keklik", reason: .provinceBanned)])
    }

    // MARK: Sert kural 2 — yalnızca o gün açık türler

    func testClosedSeasonAndNonHuntingDayRejected() throws {
        let regs = try TestData.regs()
        // 1. grup kuşlar 15 Kasım'da kapanır
        let late = HuntLegalContext(regs: regs, day: TestData.istanbul("2026-12-05T09:00"))
        XCTAssertEqual(AmmoAdvisor.rejection(for: "Bıldırcın", knowledge: k, legal: late), .closedToday)
        XCTAssertNil(AmmoAdvisor.rejection(for: "Çulluk", knowledge: k, legal: late))
        // Perşembe av günü değil: hiçbir tür seçilemez
        let thursday = HuntLegalContext(regs: regs, day: TestData.istanbul("2026-11-05T09:00"))
        XCTAssertTrue(AmmoAdvisor.selectableSpecies(knowledge: k, legal: thursday).isEmpty)
        // Salı yalnızca domuz ile 1. ve 3. grup kuşlar
        let tuesday = HuntLegalContext(regs: regs, day: TestData.istanbul("2026-11-10T09:00"))
        XCTAssertNil(AmmoAdvisor.rejection(for: "Yaban domuzu", knowledge: k, legal: tuesday))
        XCTAssertEqual(AmmoAdvisor.rejection(for: "Yaban tavşanı", knowledge: k, legal: tuesday), .closedToday)
        XCTAssertEqual(AmmoAdvisor.rejection(for: "Çakal", knowledge: k, legal: tuesday), .closedToday)
    }

    // MARK: Sert kural 3 — tek kurşun yalnızca domuzda; domuzda yalnızca tek kurşun/yivli

    func testBoarGetsOnlySlugOrRifle() {
        let r = advise(["Yaban domuzu"], [semiAuto(owned: [.cylinder, .modified]), rifle(), superpoze()])
        XCTAssertFalse(r.picks.isEmpty)
        for p in r.picks {
            for a in p.ammo {
                switch a {
                case .slug, .rifle: break
                case .shot: XCTFail("Domuz avında saçma önerildi: \(p.firearm.name)")
                }
            }
        }
        XCTAssertTrue(r.notes.contains(.boarSlugOnly))
    }

    func testSlugNeverRecommendedForOtherSpecies() {
        let guns = [semiAuto(owned: [.cylinder, .paradox, .modified]), superpoze(owned: [.paradox, .cylinder, .improvedCylinder])]
        for s in k.species where s.slug == nil {
            let r = advise([s.name], guns)
            XCTAssertFalse(r.picks.flatMap(\.ammo).contains(where: \.isSlug), "Tek kurşun önerildi: \(s.name)")
        }
    }

    func testBoarCannotBeCombinedWithShotSpecies() {
        let r = advise(["Yaban domuzu", "Çulluk"], [semiAuto(owned: [.cylinder])])
        XCTAssertTrue(r.picks.isEmpty)
        XCTAssertTrue(r.notes.contains(.boarConflict(species: ["Çulluk"])))
        // Çakal domuz avında tek kurşun/yivliyle vurulabilir: çakışma yok
        let r2 = advise(["Yaban domuzu", "Çakal"], [rifle()])
        XCTAssertEqual(r2.first?.ammo, [.rifle(caliber: ".308 Win")])
    }

    // MARK: Sert kural 4 — yivli kuş ve tavşanda yok

    func testRifleRejectedForBirdsAndHare() {
        for name in ["Çulluk", "Yeşilbaş", "Yaban tavşanı"] {
            let r = advise([name], [rifle()])
            XCTAssertTrue(r.picks.isEmpty, name)
            XCTAssertEqual(r.unsuitable.first?.reasons, [.rifleBanned(species: name)])
        }
        XCTAssertTrue(advise(["Yaban tavşanı"], [rifle()]).missing.contains(.needShotgun(species: "Yaban tavşanı")))
    }

    func testRifleAllowedForFoxJackalBoar() {
        XCTAssertEqual(advise(["Tilki"], [rifle(".223 Rem")]).first?.ammo, [.rifle(caliber: ".223 Rem")])
        XCTAssertEqual(advise(["Çakal"], [rifle(".243 Win")]).first?.ammo, [.rifle(caliber: ".243 Win")])
        XCTAssertNotNil(advise(["Yaban domuzu"], [rifle()]).first)
    }

    func testSmallRifleCaliberTooWeakForBoar() {
        let r = advise(["Yaban domuzu"], [rifle(".223 Rem")])
        XCTAssertTrue(r.picks.isEmpty)
        XCTAssertEqual(r.unsuitable.first?.reasons, [.rifleCaliberWeak(caliber: ".223 Rem", species: "Yaban domuzu")])
    }

    // MARK: Sert kural 5 — takoz

    func testMagazineReminder() {
        XCTAssertTrue(advise(["Tahtalı"], [semiAuto()]).notes.contains(.takoz))
        XCTAssertFalse(advise(["Tahtalı"], [superpoze()]).notes.contains(.takoz))
    }

    // MARK: Sert kural 6 — fişek yataktan uzun olamaz

    func testShellNeverLongerThanChamber() {
        let guns: [Firearm] = ChamberLength.allCases.flatMap { c in
            [semiAuto(chamber: c), pump(fixed: .modified, chamber: c),
             Firearm(name: "20", type: .superpoze, gauge: .g20, chamber: c, barrelCm: 66, ownedChokes: [.improvedCylinder, .cylinder])]
        }
        for s in k.species {
            for g in guns {
                let r = advise([s.name], [g])
                for p in r.picks {
                    for a in p.ammo {
                        if let mm = a.shellMm, let chamber = g.chamber {
                            XCTAssertLessThanOrEqual(mm, chamber.rawValue, "\(s.name) / \(g.name) \(chamber.rawValue)")
                        }
                    }
                }
            }
        }
    }

    func testGooseWith70mmChamberIsCappedAndFlagged() {
        let r = advise(["Sakarca"], [semiAuto(chamber: .mm70, steel: .yes)])
        let load = r.first?.ammo.first?.shotLoad
        XCTAssertEqual(load?.shellMm, 70)
        XCTAssertEqual(load?.material, .lead, "Çelikle kaz 76 mm ister; 70 mm yatakta kurşuna geçilir")
        XCTAssertTrue(r.first?.cautions.contains(.steelNeedsMagnum) == true)
        XCTAssertTrue(r.first?.cautions.contains(.shortChamber(species: "Sakarca", grams: 36)) == true)
        // 76 mm yatakta magnum çelik fişek
        let r76 = advise(["Sakarca"], [semiAuto(chamber: .mm76, steel: .yes)])
        XCTAssertEqual(r76.first?.ammo.first?.shotLoad?.shellMm, 76)
        XCTAssertEqual(r76.first?.ammo.first?.shotLoad?.material, .steel)
    }

    // MARK: Sert kural 7 — çelik

    func testSteelOnlyForSteelProofGuns() {
        for proof in [SteelProof.no, .unknown] {
            let r = advise(["Yeşilbaş"], [semiAuto(steel: proof)], terrain: "sulak_alan")
            XCTAssertEqual(r.first?.ammo.first?.shotLoad?.material, .lead)
            XCTAssertTrue(r.first?.cautions.contains(proof == .no ? .steelNotProof : .steelUnknown) == true)
        }
        let ok = advise(["Yeşilbaş"], [semiAuto(steel: .yes)], terrain: "sulak_alan")
        XCTAssertEqual(ok.first?.ammo.first?.shotLoad?.material, .steel)
        XCTAssertEqual(ok.first?.ammo.first?.shotLoad?.size, "2")
    }

    func testSteelNeverWithTightChokes() {
        let gun = semiAuto(steel: .yes, owned: [.full, .improvedModified, .modified])
        for s in k.species where s.isWaterfowl {
            let r = advise([s.name], [gun], terrain: "sulak_alan")
            guard let p = r.first, p.ammo.first?.shotLoad?.material == .steel else { continue }
            for b in p.barrels {
                XCTAssertGreaterThanOrEqual(b.want.rawValue, 3, s.name)
                if let u = b.use { XCTAssertGreaterThanOrEqual(u.rawValue, 3, s.name) }
            }
        }
        // Sabit tam şoklu tüfekte çelik yok
        let fixedFull = Firearm(name: "Eski", type: .tekKirma, gauge: .g12, chamber: .mm70, barrelCm: 76,
                                mobileChokes: false, fixedChokes: [.full], steelProof: .yes)
        let r = advise(["Yeşilbaş"], [fixedFull], terrain: "sulak_alan")
        XCTAssertEqual(r.first?.ammo.first?.shotLoad?.material, .lead)
        XCTAssertTrue(r.first?.cautions.contains(.steelFixedTight) == true)
    }

    // MARK: Sert kural 8 — tek kurşun dar şokla değil

    func testSlugWithFullChokeOnlyIsRejected() {
        let r = advise(["Yaban domuzu"], [pump(fixed: .full)])
        XCTAssertTrue(r.picks.isEmpty)
        XCTAssertEqual(r.unsuitable.first?.reasons, [.slugTightChoke])
        XCTAssertEqual(r.missing, [.needSlugOrRifle])
        // Mobil şoklu ama yalnızca dar şoklar elde
        let r2 = advise(["Yaban domuzu"], [semiAuto(owned: [.full, .improvedModified])])
        XCTAssertEqual(r2.unsuitable.first?.reasons, [.slugChokeMissing])
    }

    func testSlugUsesOnlyOpenBarrel() {
        let gun = Firearm(name: "Çifte", type: .cifte, gauge: .g12, chamber: .mm70, barrelCm: 61,
                          mobileChokes: false, fixedChokes: [.improvedCylinder, .full], steelProof: .no)
        let p = advise(["Yaban domuzu"], [gun]).first
        XCTAssertEqual(p?.barrels.map(\.match), [.exact, .unusable])
        XCTAssertTrue(p?.cautions.contains(.slugOnlyBarrel(.improvedCylinder)) == true)
    }

    // MARK: Sert kural 9 — korunan türler

    func testProtectedSpeciesRejected() {
        XCTAssertEqual(AmmoAdvisor.rejection(for: "Boz kaz", knowledge: k, legal: allOpen), .protected)
        XCTAssertEqual(advise(["Boz kaz"], [semiAuto()]).rejected.first?.reason, .protected)
    }

    // MARK: Sert kural 10 — patern ve sorumluluk notu her zaman

    func testPatternNoteAlwaysPresent() {
        XCTAssertEqual(advise(["Çulluk"], [superpoze()]).notes.last, .pattern)
        XCTAssertEqual(advise([], []).notes.last, .pattern)
    }

    // MARK: Senaryolar

    func testWoodcockWithOverUnderOwning4And5() {
        let r = advise(["Çulluk"], [superpoze(), semiAuto()])
        let p = try? XCTUnwrap(r.first)
        XCTAssertEqual(p?.firearm.type, .superpoze)
        XCTAssertEqual(p?.barrels.map(\.want), [.cylinder, .improvedCylinder], "1. atış daha açık")
        XCTAssertEqual(p?.barrels.map(\.match), [.exact, .exact])
        let load = p?.ammo.first?.shotLoad
        XCTAssertEqual(load?.size, "8")
        XCTAssertEqual(load?.material, .lead)
        XCTAssertEqual(load?.shellMm, 70)
        XCTAssertEqual(load?.mm, 2.3)
        XCTAssertEqual(r.second?.firearm.type, .yariOtomatik)
    }

    func testDuck70mmNotSteelProofGetsLead() {
        let gun = Firearm(name: "Eski otomatik", type: .yariOtomatik, gauge: .g12, chamber: .mm70, barrelCm: 71,
                          ownedChokes: [.modified, .improvedModified], steelProof: .no)
        let r = advise(["Yeşilbaş"], [gun], terrain: "sulak_alan")
        let p = r.first
        XCTAssertEqual(p?.ammo.first?.shotLoad?.material, .lead)
        XCTAssertEqual(p?.ammo.first?.shotLoad?.size, "4")
        XCTAssertEqual(p?.ammo.first?.shotLoad?.shellMm, 70)
        XCTAssertTrue(p?.cautions.contains(.steelNotProof) == true)
        XCTAssertTrue(r.notes.contains(.wetlandNonToxic))
        XCTAssertTrue(r.notes.contains(.takoz))
    }

    func testBoarWithRifleIsFirstChoice() {
        let r = advise(["Yaban domuzu"], [semiAuto(owned: [.cylinder]), rifle()])
        XCTAssertEqual(r.first?.firearm.type, .yivli)
        XCTAssertEqual(r.second?.ammo.first?.isSlug, true)
    }

    func testTwentyGaugeNotForGoose() {
        let gun = Firearm(name: "20", type: .superpoze, gauge: .g20, chamber: .mm76, barrelCm: 71,
                          ownedChokes: [.modified, .improvedModified], steelProof: .yes)
        let r = advise(["Sakarca"], [gun])
        XCTAssertTrue(r.picks.isEmpty)
        XCTAssertEqual(r.unsuitable.first?.reasons, [.gaugeUnsuitable(gauge: "20", species: "Sakarca")])
        XCTAssertEqual(r.missing, [.needMagnum(species: "Sakarca")])
    }

    func testOwnedChokeMatching() {
        // Çulluk 5/4 istenir; elde yalnızca 3 ve 4 → 1. namlu komşu (4), 2. tam
        let p = advise(["Çulluk"], [superpoze(owned: [.modified, .improvedCylinder])]).first
        XCTAssertEqual(p?.barrels.map(\.match), [.adjacent, .exact])
        XCTAssertTrue(p?.cautions.contains(.chokeAdjacent(have: .improvedCylinder, want: .cylinder)) == true)
        // Hiç uygun şok yok → yine kullanılabilir ama "5 numara şok önerilir"
        let q = advise(["Çulluk"], [superpoze(owned: [.full])]).first
        XCTAssertEqual(q?.barrels.first?.match, .missing)
        XCTAssertTrue(q?.cautions.contains(.chokeSuggested(.cylinder)) == true)
        // Tam eşleşme komşudan, komşu eksikten yüksek puan alır
        let exact = advise(["Çulluk"], [superpoze()]).first?.score ?? 0
        let adjacent = p?.score ?? 0
        let missing = q?.score ?? 0
        XCTAssertGreaterThan(exact, adjacent)
        XCTAssertGreaterThan(adjacent, missing)
    }

    func testMultiSpeciesCommonCompromise() {
        // Karatavuk (9; 8, 10) + öter ardıç (9; 8, 10) → ortak 9
        let r = advise(["Karatavuk", "Öter ardıç"], [superpoze()])
        XCTAssertEqual(r.first?.ammo.count, 1)
        XCTAssertEqual(r.first?.ammo.first?.shotLoad?.size, "9")
        XCTAssertTrue(r.first?.cautions.contains(.compromise) == true)
        // Çulluk (8) + yeşilbaş (4): ortak saçma yok → iki fişek
        let r2 = advise(["Çulluk", "Yeşilbaş"], [semiAuto(steel: .no)])
        XCTAssertEqual(r2.first?.ammo.compactMap(\.shotLoad?.size), ["8", "4"])
        XCTAssertTrue(r2.first?.cautions.contains(.twoLoads) == true)
    }

    func testTerrainShiftsChoke() {
        // Tahtalı 3/2; orman/çalı bir açar → 4/3
        let p = advise(["Tahtalı"], [superpoze(owned: [.improvedModified, .modified, .improvedCylinder])], terrain: "orman_cali").first
        XCTAssertEqual(p?.barrels.map(\.want), [.improvedCylinder, .modified])
    }

    func testLowConfidenceSpeciesShowsCaution() {
        let r = advise(["Karabatak"], [semiAuto()])
        XCTAssertTrue(r.notes.contains(.lowConfidence(species: "Karabatak")))
        XCTAssertFalse(advise(["Çulluk"], [superpoze()]).notes.contains(where: {
            if case .lowConfidence = $0 { return true } else { return false }
        }))
    }

    func testNoFirearmsExplainsMissing() {
        XCTAssertEqual(advise(["Çulluk"], []).missing, [.noFirearms])
    }

    func testEveryNoteHasText() {
        let notes: [AdvisorNote] = [.pattern, .takoz, .boarSlugOnly, .wetlandNonToxic, .slugTightChoke, .twoLoads,
                                    .chokeSuggested(.modified), .needSlugOrRifle, .rifleBanned(species: "Çulluk")]
        for n in notes { XCTAssertFalse(n.text.isEmpty) }
    }
}
