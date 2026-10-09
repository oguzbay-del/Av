import XCTest
@testable import AvHaritasi

/// Kuş tanıma yardımcıları: benzer korunan tür işareti, BirdNET haftası, model etiketi ayrıştırma.
final class BirdLookalikeTests: XCTestCase {
    private let huntable = ["Anas platyrhynchos": "Yeşilbaş", "Coturnix coturnix": "Bıldırcın"]
    private let protected = ["Anser anser": "Boz kaz", "Tadorna tadorna": "Angıt"]

    private func det(_ sci: String?, _ common: String, _ conf: Double) -> BirdDetection {
        BirdDetection(scientificName: sci, commonName: common, confidence: conf, start: 0, end: 3, source: .onDevice)
    }

    func testCloseProtectedRivalMarksHuntable() {
        let d = det("Anas platyrhynchos", "Mallard", 0.80)
        let rival = det("Anser anser", "Greylag Goose", 0.70)   // fark 0,10 < 0,15
        let out = BirdLookalike.mark([d], candidates: [rival], huntable: huntable, protected: protected)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].similarProtected, AppLocale.isEnglish ? "Greylag Goose" : "Boz kaz")
    }

    func testDistantProtectedRivalIsIgnored() {
        let d = det("Anas platyrhynchos", "Mallard", 0.80)
        let rival = det("Anser anser", "Greylag Goose", 0.60)   // fark 0,20 ≥ 0,15
        let out = BirdLookalike.mark([d], candidates: [rival], huntable: huntable, protected: protected)
        XCTAssertNil(out[0].similarProtected)
    }

    func testHigherScoringProtectedAmongDetections() {
        // Korunan tür daha yüksek skorla aynı kayıtta: av türü yine işaretlenir; korunan tür değişmez
        let d = det("Coturnix coturnix", "Common Quail", 0.55)
        let p = det("Tadorna tadorna", "Common Shelduck", 0.90)
        let out = BirdLookalike.mark([d, p], candidates: [], huntable: huntable, protected: protected)
        XCTAssertEqual(out[0].similarProtected, AppLocale.isEnglish ? "Common Shelduck" : "Angıt")
        XCTAssertNil(out[1].similarProtected, "Korunan türün kendisi işaretlenmez")
    }

    func testBestRivalChosen() {
        let d = det("Anas platyrhynchos", "Mallard", 0.70)
        let a = det("Anser anser", "Greylag Goose", 0.60)
        let b = det("Tadorna tadorna", "Common Shelduck", 0.68)
        let out = BirdLookalike.mark([d], candidates: [a, b], huntable: huntable, protected: protected)
        XCTAssertEqual(out[0].similarProtected, AppLocale.isEnglish ? "Common Shelduck" : "Angıt")
    }

    func testNonHuntableAndUnknownUntouched() {
        let unknown = det(nil, "Kuş", 0.9)
        let other = det("Passer domesticus", "House Sparrow", 0.9)
        let rival = det("Anser anser", "Greylag Goose", 0.95)
        let out = BirdLookalike.mark([unknown, other], candidates: [rival], huntable: huntable, protected: protected)
        XCTAssertEqual(out.map(\.similarProtected), [nil, nil])
        XCTAssertEqual(out.map(\.id), [unknown.id, other.id], "Kimlik ve sıra korunur")
    }

    func testMarginMatchesCandidateFloor() {
        XCTAssertEqual(BirdLookalike.margin, 0.15, accuracy: 1e-9)
    }

    func testRealRegulationsDictionaries() throws {
        let regs = try TestData.regs()
        let huntable = try XCTUnwrap(regs.huntableLatin)
        let protected = try XCTUnwrap(regs.protectedLatin)
        XCTAssertEqual(huntable["Anas platyrhynchos"], "Yeşilbaş")
        XCTAssertNotNil(protected["Anser anser"])
        let out = BirdLookalike.mark([det("Anas platyrhynchos", "Mallard", 0.8)], candidates: [det("Anser anser", "Greylag Goose", 0.75)],
                                     huntable: huntable, protected: protected)
        XCTAssertNotNil(out[0].similarProtected)
    }
}

final class BirdNETWeekTests: XCTestCase {
    private func week(_ s: String) -> Int { BirdNETWeek.week(for: TestData.istanbul(s)) }

    func testWeekBoundaries() {
        XCTAssertEqual(week("2026-01-01T12:00"), 1)
        XCTAssertEqual(week("2026-01-07T12:00"), 1)
        XCTAssertEqual(week("2026-01-08T12:00"), 2)
        XCTAssertEqual(week("2026-01-15T12:00"), 3)
        XCTAssertEqual(week("2026-01-22T12:00"), 4)
        XCTAssertEqual(week("2026-01-31T12:00"), 4, "22. günden sonrası 4. hafta")
        XCTAssertEqual(week("2026-02-01T12:00"), 5)
        XCTAssertEqual(week("2026-10-07T09:30"), 37)
        XCTAssertEqual(week("2026-12-31T23:30"), 48)
    }

    func testUsesIstanbulDay() {
        // 7 Ocak 23:30 UTC = 8 Ocak 02:30 İstanbul → 2. hafta
        let d = ISO8601DateFormatter().date(from: "2026-01-07T23:30:00Z")!
        XCTAssertEqual(BirdNETWeek.week(for: d), 2)
    }

    func testAlwaysInRange() {
        var d = TestData.istanbul("2026-01-01T12:00")
        for _ in 0..<366 {
            XCTAssert((1...48).contains(BirdNETWeek.week(for: d)))
            d.addTimeInterval(86_400)
        }
    }
}

final class BirdLabelTests: XCTestCase {
    func testUnderscoreFormat() {
        let r = BirdLabel.parse("Anas platyrhynchos_Mallard")
        XCTAssertEqual(r.scientific, "Anas platyrhynchos")
        XCTAssertEqual(r.common, "Mallard")
    }

    func testUnderscoreWithHyphenatedCommonName() {
        let r = BirdLabel.parse("Columba palumbus_Common Wood-Pigeon")
        XCTAssertEqual(r.scientific, "Columba palumbus")
        XCTAssertEqual(r.common, "Common Wood Pigeon")
    }

    func testParenthesisFormat() {
        let r = BirdLabel.parse("Mallard (Anas platyrhynchos)")
        XCTAssertEqual(r.scientific, "Anas platyrhynchos")
        XCTAssertEqual(r.common, "Mallard")
    }

    func testScientificOnly() {
        let r = BirdLabel.parse("Coturnix coturnix")
        XCTAssertEqual(r.scientific, "Coturnix coturnix")
        XCTAssertEqual(r.common, "Coturnix coturnix")
    }

    func testPlainName() {
        let r = BirdLabel.parse("duck")
        XCTAssertNil(r.scientific)
        XCTAssertEqual(r.common, "duck")
    }

    func testNonScientificPrefix() {
        let r = BirdLabel.parse("Bird_Song")
        XCTAssertNil(r.scientific)
        XCTAssertEqual(r.common, "Song")
    }

    func testLooksScientific() {
        XCTAssertTrue(BirdLabel.looksScientific("Anas platyrhynchos"))
        XCTAssertFalse(BirdLabel.looksScientific("Anas Platyrhynchos"))
        XCTAssertFalse(BirdLabel.looksScientific("anas platyrhynchos"))
        XCTAssertFalse(BirdLabel.looksScientific("Anas"))
        XCTAssertFalse(BirdLabel.looksScientific("Anas platyrhynchos domesticus"))
    }
}
