import XCTest
@testable import AvHaritasi

/// Tüfeklerim deposu: en çok 6 tüfek, yalnızca cihazda, yedekten hariç; Codable gidiş-dönüş.
final class FirearmStoreTests: XCTestCase {
    /// Her test kendi geçici klasörünü kullanır.
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tufek-\(UUID().uuidString)", isDirectory: true)

    private func gun(_ n: Int) -> Firearm {
        Firearm(name: "Tüfek \(n)", type: .superpoze, gauge: .g12, chamber: .mm76, barrelCm: 71,
                ownedChokes: [.modified, .improvedCylinder])
    }

    @MainActor
    func testSeventhFirearmRejected() throws {
        let store = FirearmStore(directory: dir)
        for i in 1...6 { try store.save(gun(i)) }
        XCTAssertEqual(store.items.count, 6)
        XCTAssertFalse(store.canAdd)
        XCTAssertThrowsError(try store.save(gun(7))) { XCTAssertEqual($0 as? FirearmStore.StoreError, .limitReached) }
        XCTAssertEqual(store.items.count, 6)
        // Var olanı güncellemek sınıra takılmaz
        var first = store.items[0]
        first.name = "Yeni ad"
        XCTAssertNoThrow(try store.save(first))
        XCTAssertEqual(store.items[0].name, "Yeni ad")
    }

    @MainActor
    func testPersistsAndExcludedFromBackup() throws {
        let store = FirearmStore(directory: dir)
        let f = Firearm(name: "Yivli", type: .yivli, barrelCm: 56, rifleCaliber: ".308 Win")
        try store.save(f)
        let reloaded = FirearmStore(directory: dir)
        XCTAssertEqual(reloaded.items, [f])
        #if os(iOS)
        let values = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        #endif
        reloaded.delete(f.id)
        XCTAssertTrue(FirearmStore(directory: dir).items.isEmpty)
    }

    @MainActor
    func testInvalidFirearmRejected() {
        let store = FirearmStore(directory: dir)
        let noName = Firearm(name: "  ", type: .pompali)
        XCTAssertThrowsError(try store.save(noName))
        // Süperpozede iki sabit şok gerekir
        let oneChoke = Firearm(name: "Çifte", type: .cifte, mobileChokes: false, fixedChokes: [.modified])
        XCTAssertFalse(oneChoke.isValid)
        XCTAssertTrue(Firearm(name: "Çifte", type: .cifte, mobileChokes: false, fixedChokes: [.modified, .full]).isValid)
    }

    func testRifleHasNoGaugeOrChamber() {
        let f = Firearm(name: "Yivli", type: .yivli, gauge: .g12, chamber: .mm76, rifleCaliber: "9.3x62")
        XCTAssertNil(f.gauge)
        XCTAssertNil(f.chamber)
        XCTAssertEqual(f.type.barrelCount, 0)
        XCTAssertTrue(f.isValid)
    }

    func testCodableRoundTrip() throws {
        let f = Firearm(name: "Otomatik", type: .yariOtomatik, gauge: .g20, chamber: .mm76, barrelCm: 66,
                        ownedChokes: [.paradox, .cylinder], steelProof: .yes, weight: .light)
        let data = try JSONEncoder().encode([f])
        XCTAssertEqual(try JSONDecoder().decode([Firearm].self, from: data), [f])
    }
}
