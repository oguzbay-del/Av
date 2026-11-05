import XCTest
@testable import AvHaritasi

final class MapOverlayLayoutTests: XCTestCase {
    func testPanelStaysWithoutCards() {
        // Kart yoksa (ya da ölçülmeden önce) panel hiç gizlenmez
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 300, safety: 200, cards: 0, controls: 44, panel: 220, spacing: 12))
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 0, safety: 200, cards: 100, controls: 44, panel: 220, spacing: 12))
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 300, safety: 200, cards: 100, controls: 44, panel: 0, spacing: 12))
    }

    func testPanelHidesOnlyWhenCardsDoNotFit() {
        // iPhone 17 Pro Max saha modu: sorgu kartı sığar
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 790, safety: 160, cards: 100, controls: 44, panel: 220, spacing: 12))
        // iPhone SE saha modu: şerit + kart + sınır satırı + panel sığmaz → panel çekilir
        XCTAssertTrue(MapOverlayLayout.hidesPanel(available: 556, safety: 160, cards: 140, controls: 44, panel: 220, spacing: 12))
        // Sınır: tam sığıyorsa gizlenmez
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 560, safety: 160, cards: 100, controls: 44, panel: 220, spacing: 12))
        XCTAssertTrue(MapOverlayLayout.hidesPanel(available: 559, safety: 160, cards: 100, controls: 44, panel: 220, spacing: 12))
    }

    func testRailRegionStartsBelowSafetyBanner() {
        XCTAssertEqual(MapOverlayLayout.railRegion(available: 556, safety: 156, spacing: 12), 388)
        // Ölçülmeden önce ve şerit alanı aşınca 0 (sütun şeridin altında kalır, onu örtmez)
        XCTAssertEqual(MapOverlayLayout.railRegion(available: 0, safety: 156, spacing: 12), 0)
        XCTAssertEqual(MapOverlayLayout.railRegion(available: 150, safety: 156, spacing: 12), 0)
    }

    func testRailFitsWithoutScrollingOnLargeScreens() {
        // Ölçülmeden önce kaydırma yok
        XCTAssertNil(MapOverlayLayout.railOptionalHeight(region: 0, side: 48, chrome: 22))
        // iPhone SE normal: 7 × 48 + 22 = 358 ≤ 432
        XCTAssertNil(MapOverlayLayout.railOptionalHeight(region: 432, side: 48, chrome: 22))
        // Tam sınır
        XCTAssertNil(MapOverlayLayout.railOptionalHeight(region: 358, side: 48, chrome: 22))
    }

    func testRailScrollsOnlyOptionalGroupOnSmallScreens() {
        // iPhone SE saha modu: 7 × 62,4 + 26 = 462,8 > 388 → üst grup kaydırılır, alt grup (4 × 62,4) tam boy
        let h = MapOverlayLayout.railOptionalHeight(region: 388, side: 62.4, chrome: 26)
        XCTAssertNotNil(h)
        XCTAssertEqual(h ?? 0, 388 - 26 - 4 * 62.4, accuracy: 0.001)
        // Üst grup + alt grup + iç boşluk bölgeyi aşmaz
        XCTAssertLessThanOrEqual((h ?? 0) + 4 * 62.4 + 26, 388.001)
    }

    func testRailOptionalGroupKeepsAtLeastOneButton() {
        // Çok kısa alanda bile üst grup bir düğme boyunda kalır (Katmanlar kaydırılarak erişilir)
        XCTAssertEqual(MapOverlayLayout.railOptionalHeight(region: 200, side: 60, chrome: 26), 60)
    }
}
