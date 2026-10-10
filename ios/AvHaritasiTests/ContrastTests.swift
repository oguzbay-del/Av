import XCTest
@testable import AvHaritasi

/// Durum şeridi renkleri WCAG 2.x AA (normal metin ≥ 4.5:1) sağlamalı; gündüz ve gece temasında.
final class ContrastTests: XCTestCase {
    private let levels: [Assessment.Level] = [.danger, .caution, .safe, .unknown]

    func testKnownContrastValues() {
        XCTAssertEqual(RGB.contrast(RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)), 21, accuracy: 0.01)
        XCTAssertEqual(RGB.contrast(RGB(hex: 0x777777), RGB(hex: 0xFFFFFF)), 4.48, accuracy: 0.01)
        XCTAssertEqual(RGB.contrast(RGB(hex: 0x123456), RGB(hex: 0x123456)), 1, accuracy: 0.0001)
    }

    func testBannerTextContrastAtLeastAA() {
        for night in [false, true] {
            for level in levels {
                let p = BannerPalette.of(level, night: night)
                let ratio = RGB.contrast(p.foreground, p.background)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(level) gece=\(night): \(ratio)")
                // Açılan kural listesi %15 siyah örtülü zeminde
                let inner = RGB.contrast(p.foreground, p.checksBackground)
                XCTAssertGreaterThanOrEqual(inner, 4.5, "\(level) gece=\(night) liste: \(inner)")
            }
        }
    }

    func testLevelsStayDistinguishable() {
        for night in [false, true] {
            let bgs = levels.map { BannerPalette.of($0, night: night).background }
            XCTAssertEqual(Set(bgs.map(\.hex)).count, levels.count, "gece=\(night): arka planlar ayrı olmalı")
        }
    }

    func testNightAutoWindow() {
        // İstanbul, 7 Ekim 2026: gün doğumu ~07:12, gün batımı ~18:44 (yerel saat)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let lat = 41.0, lon = 29.0
        func at(_ s: String) -> Date { TestData.istanbul("2026-10-07T" + s) }
        XCTAssertTrue(NightRedMode.isNight(at: at("03:00"), latitude: lat, longitude: lon, calendar: cal))
        XCTAssertTrue(NightRedMode.isNight(at: at("07:30"), latitude: lat, longitude: lon, calendar: cal), "doğumdan +30 dk içinde")
        XCTAssertFalse(NightRedMode.isNight(at: at("12:00"), latitude: lat, longitude: lon, calendar: cal))
        XCTAssertTrue(NightRedMode.isNight(at: at("18:30"), latitude: lat, longitude: lon, calendar: cal), "batımdan −30 dk içinde")
        XCTAssertFalse(NightRedMode.isNight(at: at("17:30"), latitude: lat, longitude: lon, calendar: cal))
        XCTAssertTrue(NightRedMode.isNight(at: at("22:00"), latitude: lat, longitude: lon, calendar: cal))
    }
}
