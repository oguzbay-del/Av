import XCTest
@testable import AvHaritasi

final class ProximityHapticsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func decide(_ prev: Double?, _ cur: Double?, lastTick: Date? = nil, at s: TimeInterval = 0) -> ProximityTickPolicy.Intensity? {
        ProximityTickPolicy.decide(previous: prev, current: cur, lastTick: lastTick, now: t0.addingTimeInterval(s))
    }

    func testSteps() {
        XCTAssertEqual(ProximityTickPolicy.steps, [300, 250, 200, 150, 100, 50])
    }

    func testTicksWhenCrossingStepDownward() {
        XCTAssertEqual(decide(310, 295), .light)
        XCTAssertEqual(decide(260, 250), .light, "eşiğe tam inmek de geçiştir")
        XCTAssertEqual(decide(160, 140), .light)
        XCTAssertEqual(decide(105, 95), .strong, "100 m altında güçlü")
        XCTAssertEqual(decide(60, 40), .strong)
    }

    func testNoTickWithinStepOrFar() {
        XCTAssertNil(decide(290, 260), "aynı aralıkta kalınca tık yok")
        XCTAssertNil(decide(900, 400), "300 m üstünde tık yok")
        XCTAssertNil(decide(40, 20), "50 m altında yeni eşik yok")
    }

    func testNoTickWhenMovingAway() {
        XCTAssertNil(decide(240, 260))
        XCTAssertNil(decide(95, 105))
        XCTAssertNil(decide(100, 100))
    }

    func testNoTickWithoutHistory() {
        XCTAssertNil(decide(nil, 120), "ilk konumda tık yok")
        XCTAssertNil(decide(120, nil), "yasak alana girildi / alan uzaklaştı")
    }

    func testRateLimit() {
        XCTAssertNil(decide(210, 190, lastTick: t0, at: 4.9))
        XCTAssertEqual(decide(210, 190, lastTick: t0, at: 5), .light)
    }

    func testStatefulUpdate() {
        var p = ProximityTickPolicy()
        XCTAssertNil(p.update(distance: 320, now: t0))
        XCTAssertEqual(p.update(distance: 290, now: t0.addingTimeInterval(1)), .light)
        XCTAssertNil(p.update(distance: 240, now: t0.addingTimeInterval(3)), "5 sn dolmadı")
        XCTAssertNil(p.update(distance: 230, now: t0.addingTimeInterval(10)), "250 zaten geçildi")
        XCTAssertEqual(p.update(distance: 90, now: t0.addingTimeInterval(20)), .strong, "birden çok eşik tek tık")
        XCTAssertNil(p.update(distance: 160, now: t0.addingTimeInterval(30)), "uzaklaşırken tık yok")
        XCTAssertEqual(p.update(distance: 140, now: t0.addingTimeInterval(40)), .light, "yeniden yaklaşınca tık")
    }
}
