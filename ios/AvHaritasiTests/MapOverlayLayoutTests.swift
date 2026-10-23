import XCTest
@testable import AvHaritasi

final class MapOverlayLayoutTests: XCTestCase {
    func testPanelStaysWithoutCards() {
        // Kart yoksa (ya da ölçülmeden önce) panel hiç gizlenmez
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 300, safety: 200, cards: 0, controls: 120, panel: 220, spacing: 12))
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 0, safety: 200, cards: 100, controls: 120, panel: 220, spacing: 12))
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 300, safety: 200, cards: 100, controls: 120, panel: 0, spacing: 12))
    }

    func testPanelHidesOnlyWhenCardsDoNotFit() {
        // iPhone 17 Pro Max saha modu: sorgu kartı sığar
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 790, safety: 160, cards: 100, controls: 120, panel: 220, spacing: 12))
        // iPhone SE saha modu: şerit + kart + kontroller + panel sığmaz → panel çekilir
        XCTAssertTrue(MapOverlayLayout.hidesPanel(available: 556, safety: 160, cards: 100, controls: 120, panel: 220, spacing: 12))
        // Sınır: tam sığıyorsa gizlenmez
        XCTAssertFalse(MapOverlayLayout.hidesPanel(available: 636, safety: 160, cards: 100, controls: 120, panel: 220, spacing: 12))
        XCTAssertTrue(MapOverlayLayout.hidesPanel(available: 635, safety: 160, cards: 100, controls: 120, panel: 220, spacing: 12))
    }
}
