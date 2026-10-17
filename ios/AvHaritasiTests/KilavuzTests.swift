import XCTest
@testable import AvHaritasi

/// Uygulamaya gömülü kullanım kılavuzu (Help/Kilavuz.json) okunuyor ve tutarlı mı.
/// Kaynak yolları, web kopyaları ve ekran kuralı `tools/kilavuz.py --check` ile CI'da denetlenir.
final class KilavuzTests: XCTestCase {
    func testBundledGuideDecodes() throws {
        let k = try Kilavuz.yukle()
        XCTAssertFalse(k.bolumler.isEmpty)
        XCTAssertFalse(k.konular.isEmpty)
        XCTAssertEqual(Kilavuz.paket.konular.count, k.konular.count, "paket kopyası da aynı dosyayı okumalı")
    }

    func testIdsAreUniqueAndSectionsExist() throws {
        let k = try Kilavuz.yukle()
        XCTAssertEqual(Set(k.bolumler.map(\.id)).count, k.bolumler.count, "bölüm kimlikleri benzersiz olmalı")
        XCTAssertEqual(Set(k.konular.map(\.id)).count, k.konular.count, "konu kimlikleri benzersiz olmalı")
        let bolumler = Set(k.bolumler.map(\.id))
        for konu in k.konular {
            XCTAssertTrue(bolumler.contains(konu.bolum), "\(konu.id): tanımsız bölüm \(konu.bolum)")
            XCTAssertFalse(konu.baslik.isEmpty, konu.id)
            XCTAssertFalse(konu.metin.isEmpty, konu.id)
        }
    }

    func testOnboardingHasShortSetWithSafetyNotes() throws {
        let k = try Kilavuz.yukle()
        let t = k.tanitimKonulari
        XCTAssertTrue((3...4).contains(t.count), "tanıtım 3–4 sayfa olmalı, \(t.count) var")
        let ids = t.map(\.id)
        XCTAssertTrue(ids.contains("uyari_yasak"), "yasak alan uyarısı tanıtımda olmalı")
        XCTAssertTrue(ids.contains("kus_tanima"), "kuş tanıma tanıtımda olmalı")
        // Güvenlik notları metinden düşmesin
        let kus = try XCTUnwrap(t.first { $0.id == "kus_tanima" })
        XCTAssertTrue(kus.metin.contains("kesin teşhis değildir"))
        let yasak = try XCTUnwrap(t.first { $0.id == "uyari_yasak" })
        XCTAssertTrue(yasak.baslik.contains("susturulmaz"))
    }

    func testSearchIsCaseAndDiacriticInsensitive() throws {
        let k = try Kilavuz.yukle()
        XCTAssertEqual(k.gruplar().map(\.konular.count).reduce(0, +), k.konular.count)
        // "kus" → "kuşa" (aksan), "SES" → "Sesle" (büyük/küçük harf); her kelime eşleşmeli
        let sonuc = k.gruplar(arama: "kus SES").flatMap(\.konular).map(\.id)
        XCTAssertTrue(sonuc.contains("kus_ses"))
        XCTAssertTrue(k.gruplar(arama: "zzzz-yok").isEmpty)
    }
}
