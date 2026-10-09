import XCTest
@testable import AvHaritasi

/// İnternetsiz yer arama: Türkçeye duyarsız eşleştirme ve OCR'dan gelen bölünmüş adlar.
final class PlaceIndexTests: XCTestCase {
    private static let index: Result<PlaceIndex, Error> = Result {
        let ctx = try TestData.context()
        return PlaceIndex(features: ctx.features, regs: ctx.regs, areas: AvlakAreas())
    }

    private func search(_ q: String) throws -> [String] {
        try Self.index.get().search(q).map { PlaceIndex.normalize($0.name) }
    }

    func testNormalize() {
        XCTAssertEqual(PlaceIndex.normalize("ŞİLE"), "sile")
        XCTAssertEqual(PlaceIndex.normalize("Şile"), "sile")
        XCTAssertEqual(PlaceIndex.normalize("Ağva"), "agva")
        XCTAssertEqual(PlaceIndex.normalize("KIRKLARELİ"), "kirklareli")
        XCTAssertEqual(PlaceIndex.normalize("Gaz İtepe"), "gaz itepe")
        XCTAssertEqual(PlaceIndex.normalize("  Çatalca-Göçbeyli  "), "catalca gocbeyli")
        XCTAssertEqual(PlaceIndex.normalize("Üsküdar"), "uskudar")
    }

    func testSileWithoutTurkishLetters() throws {
        let r = try search("sile")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(r.contains { $0.hasPrefix("sile") }, "\(r)")
        XCTAssertEqual(try search("ŞİLE"), r, "Büyük/küçük harf ve Türkçe harf fark etmez")
    }

    func testAgva() throws {
        let r = try search("agva")
        XCTAssertTrue(r.contains { $0.hasPrefix("agva") }, "\(r)")
        XCTAssertEqual(try search("Ağva"), r)
    }

    func testOCRSplitNames() throws {
        // Haritadan okunan köy adı "Gaz İtepe" (OCR "Gazitepe"yi bölmüş): her iki yazım da bulmalı
        for q in ["gazitepe", "Gazitepe", "gaz itepe", "GAZ İTEPE", "gazite"] {
            let r = try search(q)
            XCTAssertEqual(r.first, "gaz itepe", "sorgu: \(q) → \(r)")
        }
    }

    func testExactMatchRanksFirst() throws {
        let r = try Self.index.get().search("dereli")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(r.prefix(2).allSatisfy { PlaceIndex.normalize($0.name) == "dereli" })
    }

    func testShortOrUnknownQueries() throws {
        XCTAssertTrue(try search("s").isEmpty, "En az 2 harf")
        XCTAssertTrue(try search("zzqqxx").isEmpty)
    }

    func testLimit() throws {
        XCTAssertLessThanOrEqual(try Self.index.get().search("ko", limit: 5).count, 5)
    }
}
