import XCTest
@testable import AvHaritasi

/// Av defteri: güne ait tüfek + fişek notu (yalnızca cihazda, yedekten hariç), gün anahtarı ve geçmiş listesi.
final class HarvestLogTests: XCTestCase {
    /// Her test kendi geçici klasörünü kullanır.
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("defter-\(UUID().uuidString)", isDirectory: true)

    /// İstanbul saatiyle tarih.
    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f.date(from: s)!
    }

    @MainActor
    func testGearPersistsAndExcludedFromBackup() throws {
        let log = HarvestLog(directory: dir)
        let day = date("2026-11-07T08:30:00")
        log.setGear(.init(firearm: "Süperpoze 12", ammo: "8 numara kurşun, 32 g"), on: day)
        let reloaded = HarvestLog(directory: dir)
        XCTAssertEqual(reloaded.gear(on: day), .init(firearm: "Süperpoze 12", ammo: "8 numara kurşun, 32 g"))
        #if os(iOS)
        let values = try log.gearURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        #endif
    }

    @MainActor
    func testEmptyGearRemovesNote() {
        let log = HarvestLog(directory: dir)
        let day = date("2026-11-07T08:30:00")
        log.setGear(.init(firearm: "Otomatik 12", ammo: nil), on: day)
        XCTAssertNotNil(log.gear(on: day))
        log.setGear(.init(firearm: "  ", ammo: ""), on: day)
        XCTAssertNil(log.gear(on: day))
        log.setGear(.init(firearm: "Otomatik 12", ammo: nil), on: day)
        log.setGear(nil, on: day)
        XCTAssertNil(HarvestLog(directory: dir).gear(on: day))
    }

    @MainActor
    func testNormalizedTrimsAndCaps() {
        let g = HarvestLog.DayGear(firearm: "  Yivli .308 \n", ammo: String(repeating: "a", count: 200)).normalized
        XCTAssertEqual(g?.firearm, "Yivli .308")
        XCTAssertEqual(g?.ammo?.count, 80)
        XCTAssertNil(HarvestLog.DayGear(firearm: nil, ammo: " ").normalized)
    }

    /// Gün İstanbul saatine göre değişir: 23:30 ile ertesi 00:30 farklı günlerdir, aynı günün sabahı ve akşamı aynı.
    @MainActor
    func testDayKeyUsesIstanbulTime() {
        XCTAssertEqual(HarvestLog.dayKey(date("2026-11-07T23:30:00")), "2026-11-07")
        XCTAssertEqual(HarvestLog.dayKey(date("2026-11-08T00:30:00")), "2026-11-08")
        XCTAssertEqual(HarvestLog.dayKey(date("2026-11-07T05:00:00")), HarvestLog.dayKey(date("2026-11-07T18:00:00")))
        let start = HarvestLog.day(fromKey: "2026-11-07")
        XCTAssertNotNil(start)
        XCTAssertEqual(start.map(HarvestLog.dayKey), "2026-11-07")
    }

    @MainActor
    func testGearOnlyDayListedInHistory() {
        let log = HarvestLog(directory: dir)
        log.add("Çulluk", at: nil, date: date("2026-11-07T09:00:00"))
        log.setGear(.init(firearm: "Süperpoze 12", ammo: nil), on: date("2026-11-07T07:00:00"))
        log.setGear(.init(firearm: nil, ammo: "4 numara çelik"), on: date("2026-11-08T07:00:00"))
        let days = log.days()
        XCTAssertEqual(days.map { HarvestLog.dayKey($0.day) }, ["2026-11-08", "2026-11-07"])
        XCTAssertTrue(days[0].items.isEmpty)
        XCTAssertEqual(days[1].items.first?.species, "Çulluk")
    }
}
