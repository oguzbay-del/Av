import CoreGraphics
import XCTest
@testable import AvHaritasi

/// AVBİS avlanma izin belgesinin OCR metninden çözümlenmesi. Metin gerçek belgenin düzenini
/// izleyen yapay bir örnektir (kişisel bilgiler uydurmadır).
final class PermitParserTests: XCTestCase {
    /// Satır düzeninde okunmuş belge: her tür adının yanında kotası.
    static let rowText = """
    T.C. TARIM VE ORMAN BAKANLIĞI
    Doğa Koruma ve Milli Parklar Genel Müdürlüğü
    İstanbul İli Beykoz Devlet Avlağı 2026-2027 Av Dönemi Avlanma İzin Belgesi
    Belge Numarası 42793703
    Adı Soyadı AHMET YILMAZ
    Avcılık Belgesi No 34-0012345
    Düzenlenme Tarihi 01.10.2026
    Geçerli Olduğu Tarih 4.10.2026
    Avına İzin Verilen Türler ve Kotaları
    Bıldırcın 10
    Üveyik 3
    Yasaklı Türler
    Keklik, Sülün, Yaban Tavşanı
    * Avına izin verilen türler dışında karga, saksağan ve tilki MAK kararına göre avlanabilir. Kota 5.
    Avlak sınırları için avlak haritasına bakınız.
    """

    func testRowLayoutPermit() throws {
        let regs = try TestData.regs()
        let r = PermitParser.parse(Self.rowText, regs: regs, verifyURL: nil)
        let p = try XCTUnwrap(r.permit)
        XCTAssertEqual(p.avlak, "Beykoz Devlet Avlağı")
        XCTAssertEqual(p.number, "42793703")
        XCTAssertEqual(Regulations.dayString(p.date), "2026-10-04", "'Geçerli' sonrasındaki tarih alınmalı, düzenlenme tarihi değil")
        XCTAssertEqual(p.quotas, [.init(species: "Bıldırcın", count: 10), .init(species: "Üveyik", count: 3)])
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(p.quota(for: "Bıldırcın"), 10)
        XCTAssertNil(p.quota(for: "Saksağan"), "Dipnottaki türler kotaya girmemeli")
    }

    func testColumnLayoutPermit() throws {
        // OCR tablo sütunlarını ayrı okumuş: önce adlar, sonra sayılar
        let text = Self.rowText.replacingOccurrences(of: "Bıldırcın 10\nÜveyik 3", with: "Bıldırcın\nÜveyik\n10\n3")
        let r = PermitParser.parse(text, regs: try TestData.regs(), verifyURL: nil)
        XCTAssertEqual(r.permit?.quotas, [.init(species: "Bıldırcın", count: 10), .init(species: "Üveyik", count: 3)])
    }

    func testMissingQuotaFallsBackToMAKLimit() throws {
        let text = Self.rowText.replacingOccurrences(of: "Bıldırcın 10\nÜveyik 3", with: "Bıldırcın")
        let r = PermitParser.parse(text, regs: try TestData.regs(), verifyURL: nil)
        XCTAssertEqual(r.permit?.quotas, [.init(species: "Bıldırcın", count: 10)])
        XCTAssertEqual(r.problems.count, 1, "Kota okunamadı uyarısı")
    }

    func testOCRSpacingAndCaseTolerance() throws {
        // Boşluklar kaymış ve Türkçe harfler sadeleşmiş
        let text = Self.rowText
            .replacingOccurrences(of: "Beykoz Devlet Avlağı", with: "BEYKOZDEVLET AVLAGI")
            .replacingOccurrences(of: "Bıldırcın", with: "BILDIRCIN")
        let r = PermitParser.parse(text, regs: try TestData.regs(), verifyURL: nil)
        XCTAssertEqual(r.permit?.avlak, "Beykoz Devlet Avlağı")
        XCTAssertEqual(r.permit?.quota(for: "Bıldırcın"), 10)
    }

    func testUnknownAvlakIsRejected() throws {
        let text = Self.rowText.replacingOccurrences(of: "Beykoz Devlet Avlağı", with: "Bilinmeyen Yer")
        let r = PermitParser.parse(text, regs: try TestData.regs(), verifyURL: nil)
        XCTAssertNil(r.permit)
        XCTAssertFalse(r.problems.isEmpty)
    }

    func testWrongSeasonIsFlagged() throws {
        let text = Self.rowText.replacingOccurrences(of: "2026-2027", with: "2024-2025")
        let r = PermitParser.parse(text, regs: try TestData.regs(), verifyURL: nil)
        XCTAssertNotNil(r.permit)
        XCTAssertEqual(r.problems.count, 1)
    }

    func testNormalize() {
        XCTAssertEqual(PermitParser.normalize("Avına İzin  Verilen—Türler"), "AVINA IZIN VERILEN TURLER")
        XCTAssertEqual(PermitParser.normalize("Üveyik; Bıldırcın"), "UVEYIK BILDIRCIN")
        XCTAssertEqual(PermitParser.normalize("4.10.2026"), "4.10.2026")
    }

    // MARK: - Konumlu OCR (Vision kutuları, sol-alt orijin)

    private func item(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.2, h: CGFloat = 0.03) -> PermitParser.TextItem {
        .init(text: text, box: CGRect(x: x, y: y, width: w, height: h))
    }

    /// Tablo + altta "izin verilen" geçen dipnot. Dipnot tablo başlığı sanılırsa tablo boş kalır
    /// ve metin sırasına (burada bilerek yanlış: "3 10") düşülür.
    private var geometricItems: [PermitParser.TextItem] {
        [
            item("İstanbul İli Beykoz Devlet Avlağı 2026-2027 Av Dönemi Avlanma İzin Belgesi", x: 0.05, y: 0.92, w: 0.9),
            item("Belge Numarası 42793703", x: 0.05, y: 0.86, w: 0.5),
            item("Geçerli Olduğu Tarih 4.10.2026", x: 0.05, y: 0.80, w: 0.5),
            item("Avına İzin Verilen Türler ve Kotaları", x: 0.05, y: 0.70, w: 0.6),
            item("Bıldırcın", x: 0.10, y: 0.60),
            item("Üveyik", x: 0.10, y: 0.55),
            item("3", x: 0.70, y: 0.552, w: 0.04),
            item("10", x: 0.70, y: 0.603, w: 0.05),
            item("Yasaklı Türler", x: 0.05, y: 0.45, w: 0.3),
            item("Keklik 2", x: 0.10, y: 0.40),
            item("* Avına izin verilen türler dışında karga ve saksağan avlanabilir", x: 0.05, y: 0.05, w: 0.9),
            item("Saksağan", x: 0.10, y: 0.02),
            item("5", x: 0.70, y: 0.02, w: 0.04),
        ]
    }

    func testGeometricQuotasIgnoreFootnoteHeader() {
        let q = PermitParser.geometricQuotas(geometricItems, species: ["Bıldırcın", "Üveyik"])
        XCTAssertEqual(q, ["Bıldırcın": 10, "Üveyik": 3])
    }

    func testParseUsesGeometryOverTextOrder() throws {
        // Metin sırası sütun düzeninde ve sayılar ters: yalnız metinle Bıldırcın 3 / Üveyik 10 çıkardı
        let text = geometricItems.map(\.text).joined(separator: "\n")
        let r = PermitParser.parse(text, items: geometricItems, regs: try TestData.regs(), verifyURL: "https://avbis.example/dogrula")
        let p = try XCTUnwrap(r.permit)
        XCTAssertEqual(p.quotas, [.init(species: "Bıldırcın", count: 10), .init(species: "Üveyik", count: 3)])
        XCTAssertEqual(p.verifyURL, "https://avbis.example/dogrula")
        XCTAssertEqual(p.number, "42793703")
    }

    // MARK: - Geçerlilik günü

    func testPermitValidOnlyOnItsIstanbulDay() throws {
        let p = try XCTUnwrap(PermitParser.parse(Self.rowText, regs: try TestData.regs(), verifyURL: nil).permit)
        XCTAssertTrue(p.isValid(on: TestData.istanbul("2026-10-04T00:10")))
        XCTAssertTrue(p.isValid(on: TestData.istanbul("2026-10-04T23:50")))
        XCTAssertFalse(p.isValid(on: TestData.istanbul("2026-10-05T00:10")))
        XCTAssertFalse(p.isValid(on: TestData.istanbul("2026-10-03T23:50")))
    }
}
