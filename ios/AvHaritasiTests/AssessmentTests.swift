import CoreLocation
import XCTest
@testable import AvHaritasi

private func describe(_ a: Assessment) -> String {
    a.checks.map { "\($0.id)=\($0.level)" }.joined(separator: ", ")
}

/// Mekânsal kurallar: bilinen noktalarda beklenen seviye (GPX senaryolarıyla aynı yerler).
final class AssessmentTests: XCTestCase {
    private let settings = EvaluationSettings()
    /// 7 Ekim 2026 Çarşamba 09:30 (İstanbul): av günü, av saati içinde.
    private let huntingMorning = TestData.istanbul("2026-10-07T09:30")

    func testSarikavakStartIsSafeDevletAvlagi() throws {
        let ctx = try TestData.context()
        let a = Assessment.evaluate(Points.sarikavakStart, accuracy: 5, at: huntingMorning, context: ctx, settings: settings)
        XCTAssertEqual(a.zone?.key, "devlet_avlagi")
        XCTAssertEqual(a.placeLevel, .safe, describe(a))
        XCTAssertEqual(a.level, .safe, "Av günü ve saatinde genel durum da güvenli olmalı: \(describe(a))")
        XCTAssertFalse(a.checks.contains { $0.id == "yasak-yakin" }, "Yasak sınıra ~800 m: 300 m uyarısı çıkmamalı")
        XCTAssertTrue(a.checks.contains { $0.id == "alan" && $0.level == .safe })
    }

    func testInsideAvaYasakAlanIsDanger() throws {
        let ctx = try TestData.context()
        let a = Assessment.evaluate(Points.avaYasakDeep, accuracy: 5, at: huntingMorning, context: ctx, settings: settings)
        XCTAssertEqual(a.zone?.key, "ava_yasak")
        XCTAssertEqual(a.zone?.status, .yasak)
        XCTAssertEqual(a.placeLevel, .danger, describe(a))
        XCTAssertEqual(a.level, .danger)
        XCTAssertTrue(a.checks.contains { $0.id == "alan" && $0.level == .danger })
        XCTAssertEqual(a.checks.first?.level, .danger, "Kontroller en kötüden iyiye sıralı olmalı")
        // İçerideyken "yasak alana yaklaşma" uyarısı ayrıca eklenmez
        XCTAssertFalse(a.checks.contains { $0.id == "yasak-yakin" })
    }

    func testEvaluatePlaceMatchesPlaceLevel() throws {
        let ctx = try TestData.context()
        for c in [Points.sarikavakStart, Points.avaYasakDeep, Points.sileQuiet, Points.nearDereli] {
            let full = Assessment.evaluate(c, accuracy: 0, at: huntingMorning, context: ctx, settings: settings)
            let place = Assessment.evaluatePlace(c, context: ctx, settings: settings)
            XCTAssertEqual(place.level, full.placeLevel, "\(c.latitude),\(c.longitude)")
            XCTAssertFalse(place.checks.contains { $0.kind == .time })
        }
    }

    func testSileQuietPointIsSafe() throws {
        let ctx = try TestData.context()
        let a = Assessment.evaluatePlace(Points.sileQuiet, context: ctx, settings: settings)
        XCTAssertEqual(a.level, .safe, describe(a))
        XCTAssertNil(ctx.map.nearest(to: Points.sileQuiet, within: 3_000) { $0.status == .yasak },
                     "Senaryo 06: en yakın yasak alan 3 km'den uzak")
    }

    func testNearVillageIsDanger() throws {
        let ctx = try TestData.context()
        let a = Assessment.evaluatePlace(Points.nearDereli, context: ctx, settings: settings)
        XCTAssertEqual(a.level, .danger, describe(a))
        XCTAssertTrue(a.checks.contains { $0.id == "meskun" && $0.level == .danger }, describe(a))
    }

    func testOutsideMapIsUnknown() throws {
        let ctx = try TestData.context()
        XCTAssertNil(ctx.map.zone(at: Points.ankara))
        let a = Assessment.evaluatePlace(Points.ankara, context: ctx, settings: settings)
        XCTAssertEqual(a.level, .unknown)
        XCTAssertEqual(a.checks.map(\.id), ["kapsam"])
    }

    func testPoorGPSAccuracyAddsCaution() throws {
        let ctx = try TestData.context()
        let a = Assessment.evaluate(Points.sarikavakStart, accuracy: 200, at: huntingMorning, context: ctx, settings: settings)
        XCTAssertTrue(a.checks.contains { $0.id == "gps" && $0.level == .caution }, describe(a))
        XCTAssertGreaterThanOrEqual(a.placeLevel, .caution, "Doğruluk kötüyken yeşil gösterilmemeli")
    }

    func testAccuracyWidensWarningBuffer() throws {
        let ctx = try TestData.context()
        // Sınıra ~800 m: ±600 m doğrulukla yasak alan uyarı tamponuna (300 m + 600 m) girer
        let a = Assessment.evaluate(Points.sarikavakStart, accuracy: 600, at: huntingMorning, context: ctx, settings: settings)
        XCTAssertTrue(a.checks.contains { $0.id == "yasak-yakin" }, describe(a))
    }

    // MARK: - Kesin Konum / bayat konum

    func testReducedAccuracyIsDanger() {
        let a = Assessment.reducedAccuracy(3_000)
        XCTAssertEqual(a.level, .danger)
        XCTAssertEqual(a.placeLevel, .caution)
        XCTAssertEqual(a.checks.map(\.id), ["kesin_konum"])
        XCTAssertNil(a.zone)
    }

    func testStaleNeverBelowCaution() {
        let zone = ZoneClass(id: 1, key: "devlet_avlagi", name: "Devlet Avlağı", status: .izinli, description: "", color: "#FFEBBE")
        for level in [Assessment.Level.unknown, .safe, .caution, .danger] {
            let last = Assessment(level: level, placeLevel: level, title: "t", detail: "d", zone: zone, unitName: "Birim",
                                  checks: [RuleCheck(id: "alan", kind: .place, level: level, title: "t", detail: "d")])
            for age in [5.0, 45, 600] {
                let s = Assessment.stale(age: age, last: last)
                XCTAssertEqual(s.level, max(level, .caution), "son=\(level) yaş=\(age)")
                XCTAssertEqual(s.placeLevel, max(level, .caution))
                XCTAssertGreaterThanOrEqual(s.level, .caution)
                XCTAssertEqual(s.checks.first?.id, "konum_eski")
                XCTAssertEqual(s.checks.count, 2, "Son değerlendirmenin kontrolleri ayrıntıda kalır")
                XCTAssertEqual(s.zone, zone)
                XCTAssertEqual(s.unitName, "Birim")
            }
        }
    }

    func testStaleOfRealEvaluations() throws {
        let ctx = try TestData.context()
        let safe = Assessment.evaluate(Points.sarikavakStart, accuracy: 5, at: huntingMorning, context: ctx, settings: settings)
        XCTAssertEqual(safe.level, .safe)
        let s = Assessment.stale(age: 120, last: safe)
        XCTAssertEqual(s.level, .caution)
        XCTAssertEqual(s.placeLevel, .caution)
        let danger = Assessment.evaluate(Points.avaYasakDeep, accuracy: 5, at: huntingMorning, context: ctx, settings: settings)
        XCTAssertEqual(Assessment.stale(age: 120, last: danger).level, .danger)
    }

    func testLevelOrdering() {
        XCTAssertLessThan(Assessment.Level.unknown, .safe)
        XCTAssertLessThan(Assessment.Level.safe, .caution)
        XCTAssertLessThan(Assessment.Level.caution, .danger)
    }
}

/// Zaman kuralları (av günü, saat, sezon): an `evaluate(at:)` / `timeChecks(at:)` ile verilir;
/// AppClock'a ya da `debugNow` ayarına gerek yoktur.
final class TimeRuleTests: XCTestCase {
    private let settings = EvaluationSettings()

    private func check(_ id: String, at s: String) throws -> RuleCheck? {
        let regs = try TestData.regs()
        return Assessment.timeChecks(Points.sarikavakStart, at: TestData.istanbul(s), regs: regs).first { $0.id == id }
    }

    func testWednesdayIsHuntingDay() throws {
        XCTAssertEqual(try check("gun", at: "2026-10-07T09:30")?.level, .safe)
        XCTAssertEqual(try check("saat", at: "2026-10-07T09:30")?.level, .safe)
    }

    func testThursdayIsNotHuntingDay() throws {
        XCTAssertEqual(try check("gun", at: "2026-10-08T09:30")?.level, .danger)
        let regs = try TestData.regs()
        XCTAssertTrue(regs.huntableToday(on: TestData.istanbul("2026-10-08T09:30")).isEmpty)
    }

    func testThursdayDangerKeepsPlaceLevelSafe() throws {
        let ctx = try TestData.context()
        let a = Assessment.evaluate(Points.sarikavakStart, accuracy: 5, at: TestData.istanbul("2026-10-08T09:30"),
                                    context: ctx, settings: settings)
        XCTAssertEqual(a.level, .danger, "Av günü değil")
        XCTAssertEqual(a.placeLevel, .safe, "Bildirimler mekânsal seviyeye göre: zaman kuralı placeLevel'i bozmamalı")
    }

    func testTimeRulesCanBeDisabled() throws {
        let ctx = try TestData.context()
        var s = settings
        s.includeTime = false
        let a = Assessment.evaluate(Points.sarikavakStart, accuracy: 5, at: TestData.istanbul("2026-10-08T09:30"),
                                    context: ctx, settings: s)
        XCTAssertEqual(a.level, .safe, describe(a))
        XCTAssertFalse(a.checks.contains { $0.kind == .time })
    }

    func testHolidayThursdayIsHuntingDay() throws {
        // 29 Ekim 2026 Perşembe: Cumhuriyet Bayramı
        let regs = try TestData.regs()
        XCTAssertNotNil(regs.holiday(on: TestData.istanbul("2026-10-29T10:00")))
        XCTAssertEqual(try check("gun", at: "2026-10-29T10:00")?.level, .safe)
    }

    func testTuesdayOnlyExtraGroups() throws {
        let regs = try TestData.regs()
        let groups = regs.huntableToday(on: TestData.istanbul("2026-10-06T10:00"))
        XCTAssertFalse(groups.isEmpty, "Salı: 1. grup kuşlar (bıldırcın, üveyik) açık")
        XCTAssertTrue(groups.allSatisfy { regs.huntingDays.extraTuesdayGroups.contains($0.id) })
        XCTAssertTrue(groups.flatMap(\.species).contains("Bıldırcın"))
        XCTAssertFalse(groups.flatMap(\.species).contains("Çakal"), "Salı memeliler: yalnız yaban domuzu")
    }

    func testOutsideHuntingHoursIsDanger() throws {
        XCTAssertEqual(try check("saat", at: "2026-10-07T03:00")?.level, .danger)
        XCTAssertEqual(try check("saat", at: "2026-10-07T23:30")?.level, .danger)
    }

    func testHuntingWindowAroundSun() throws {
        let regs = try TestData.regs()
        let w = try XCTUnwrap(regs.huntingWindow(on: TestData.istanbul("2026-10-07T12:00"), at: Points.sarikavakStart))
        // Ekim başı İstanbul: gün doğumu ~07:10, batımı ~18:40 → pencere ~06:10 – ~19:40
        XCTAssertGreaterThan(w.start, TestData.istanbul("2026-10-07T05:30"))
        XCTAssertLessThan(w.start, TestData.istanbul("2026-10-07T06:45"))
        XCTAssertGreaterThan(w.end, TestData.istanbul("2026-10-07T19:00"))
        XCTAssertLessThan(w.end, TestData.istanbul("2026-10-07T20:15"))
    }

    func testOffSeasonIsDanger() throws {
        // Haziran 2027 Çarşamba: tüm gruplar kapalı
        let checks = Assessment.timeChecks(Points.sarikavakStart, at: TestData.istanbul("2027-06-02T10:00"), regs: try TestData.regs())
        XCTAssertEqual(checks.map(\.id), ["sezon"])
        XCTAssertEqual(checks.first?.level, .danger)
    }

    func testUpcomingHuntingDaysSkipsThursdayFriday() throws {
        let regs = try TestData.regs()
        let days = regs.upcomingHuntingDays(from: TestData.istanbul("2026-10-08T09:00"), count: 2)
        XCTAssertEqual(days.map { Regulations.dayString($0.date) }, ["2026-10-10", "2026-10-11"])
    }
}
