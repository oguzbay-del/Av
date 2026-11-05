import XCTest
@testable import AvHaritasi

/// Ava hazırlık kontrol listesi: içerik kuralları ve günlük işaret durumu.
final class PrepChecklistTests: XCTestCase {
    private func rec(_ type: FirearmType, ammo: [AmmoChoice]) -> Recommendation {
        Recommendation(firearm: Firearm(name: type.rawValue, type: type, barrelCm: 66, rifleCaliber: ".308 Win"),
                       score: 50, ammo: ammo, barrels: [], reasons: [], cautions: [])
    }

    private let lead8 = AmmoChoice.shot(ShotLoad(species: ["Çulluk"], material: .lead, size: "8", mm: 2.3,
                                                grams: 28...32, shellMm: 70))

    func testMagazineAddsTakozItem() {
        let items = PrepChecklist.items(species: ["Çulluk"], limit: { _ in "5" }, picks: [rec(.pompali, ammo: [lead8])],
                                        boarHunt: false, inStateAvlak: false)
        XCTAssertTrue(items.contains { $0.id == "takoz" && $0.important })
        XCTAssertTrue(items.contains { $0.id == "limit_Çulluk" })
        XCTAssertTrue(items.contains { $0.id == "fisek_0_0" })
        let noMag = PrepChecklist.items(species: ["Çulluk"], limit: { _ in nil }, picks: [rec(.superpoze, ammo: [lead8])],
                                        boarHunt: false, inStateAvlak: false)
        XCTAssertFalse(noMag.contains { $0.id == "takoz" })
    }

    func testBoarHuntAddsSlugOnlyAndDrivePermit() {
        let items = PrepChecklist.items(species: ["Yaban domuzu"], limit: { _ in nil },
                                        picks: [rec(.yivli, ammo: [.rifle(caliber: ".308 Win")])],
                                        boarHunt: true, inStateAvlak: true)
        XCTAssertTrue(items.contains { $0.id == "tek_kursun" })
        XCTAssertTrue(items.contains { $0.id == "surek" })
        XCTAssertTrue(items.contains { $0.id == "avlak_izni" && $0.important })
    }

    func testDayStateResetsOnNewDay() {
        var s = ChecklistDay.current(stored: nil, today: "2026-11-07")
        s.toggle("belge")
        XCTAssertEqual(ChecklistDay.current(stored: s, today: "2026-11-07").checked, ["belge"])
        XCTAssertTrue(ChecklistDay.current(stored: s, today: "2026-11-08").checked.isEmpty)
        s.toggle("belge")
        XCTAssertTrue(s.checked.isEmpty)
    }

    func testAmmoSummary() {
        XCTAssertTrue(lead8.summary.contains("8"))
        XCTAssertTrue(lead8.summary.contains("70"))
        XCTAssertTrue(AmmoChoice.slug(grams: 28...32, shellMm: 70).summary.contains("28"))
    }
}
