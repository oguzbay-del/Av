import CoreLocation
import XCTest
@testable import AvHaritasi

final class PowerModePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = CLLocationCoordinate2D(latitude: 41.0, longitude: 29.0)

    /// `origin`den kuzeye `north` metre, `t0`dan `seconds` sn sonra.
    private func fix(north: Double = 0, seconds: TimeInterval = 0) -> CLLocation {
        let c = CLLocationCoordinate2D(latitude: origin.latitude + north / 111_320, longitude: origin.longitude)
        return CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                          timestamp: t0.addingTimeInterval(seconds))
    }

    private let near = PowerModePolicy.Settings(isStationary: false, lowPowerTier: false,
                                                desiredAccuracy: kCLLocationAccuracyBest, distanceFilter: 5)
    private let far = PowerModePolicy.Settings(isStationary: false, lowPowerTier: true,
                                               desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 20)
    private let still = PowerModePolicy.Settings(isStationary: true, lowPowerTier: false,
                                                 desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 15)

    // MARK: Uzaklık

    func testDistanceToForbidden() {
        XCTAssertEqual(PowerModePolicy.distanceToForbidden(nearest: 800, inside: false), 800)
        XCTAssertEqual(PowerModePolicy.distanceToForbidden(nearest: 800, inside: true), 0)
        XCTAssertEqual(PowerModePolicy.distanceToForbidden(nearest: nil, inside: true), 0)
        XCTAssertEqual(PowerModePolicy.distanceToForbidden(nearest: nil, inside: false), .infinity)
    }

    // MARK: Kademeler (hareket hâlinde)

    func testFirstFixSetsAnchorAndIsNotStationary() {
        var p = PowerModePolicy()
        let loc = fix()
        XCTAssertEqual(p.update(with: loc, nearestForbidden: 400, insideForbidden: false), near)
        XCTAssertTrue(p.stillAnchor === loc)
        XCTAssertFalse(p.isStationary)
    }

    func testFarTierBeyond1500m() {
        var p = PowerModePolicy()
        XCTAssertEqual(p.update(with: fix(), nearestForbidden: nil, insideForbidden: false), far)
        var q = PowerModePolicy()
        XCTAssertEqual(q.update(with: fix(), nearestForbidden: 1_501, insideForbidden: false), far)
        var r = PowerModePolicy()
        XCTAssertEqual(r.update(with: fix(), nearestForbidden: 1_500, insideForbidden: false), near, "tam 1,5 km: yakın kademe")
    }

    func testInsideForbiddenIsFullAccuracy() {
        var p = PowerModePolicy()
        XCTAssertEqual(p.update(with: fix(), nearestForbidden: nil, insideForbidden: true), near)
    }

    // MARK: Pusu (hareketsiz)

    func testBecomesStationaryAfterMoreThan180sWithin20m() {
        var p = PowerModePolicy()
        _ = p.update(with: fix(), nearestForbidden: 700, insideForbidden: false)
        XCTAssertEqual(p.update(with: fix(north: 10, seconds: 100), nearestForbidden: 700, insideForbidden: false), near)
        XCTAssertEqual(p.update(with: fix(north: 5, seconds: 180), nearestForbidden: 700, insideForbidden: false), near,
                       "tam 180 sn: henüz değil")
        XCTAssertEqual(p.update(with: fix(north: 15, seconds: 181), nearestForbidden: 700, insideForbidden: false), still)
        XCTAssertTrue(p.isStationary)
    }

    func testStationaryAnchorIsFirstFixNotLatest() {
        var p = PowerModePolicy()
        let first = fix()
        _ = p.update(with: first, nearestForbidden: 700, insideForbidden: false)
        _ = p.update(with: fix(north: 10, seconds: 100), nearestForbidden: 700, insideForbidden: false)
        XCTAssertTrue(p.stillAnchor === first)
    }

    func testNotStationaryWhenForbiddenWithin600m() {
        var p = PowerModePolicy()
        _ = p.update(with: fix(), nearestForbidden: 600, insideForbidden: false)
        XCTAssertEqual(p.update(with: fix(seconds: 1_000), nearestForbidden: 600, insideForbidden: false), near)
        XCTAssertFalse(p.isStationary)
    }

    func testStationaryEndsWhenForbiddenComesWithin600m() {
        var p = PowerModePolicy()
        _ = p.update(with: fix(), nearestForbidden: 700, insideForbidden: false)
        XCTAssertEqual(p.update(with: fix(seconds: 200), nearestForbidden: 700, insideForbidden: false), still)
        XCTAssertEqual(p.update(with: fix(seconds: 210), nearestForbidden: 600, insideForbidden: false), near)
        XCTAssertFalse(p.isStationary)
    }

    func testStationaryFarFromForbiddenUsesStationaryNotLowPowerTier() {
        var p = PowerModePolicy()
        _ = p.update(with: fix(), nearestForbidden: nil, insideForbidden: false)
        XCTAssertEqual(p.update(with: fix(seconds: 200), nearestForbidden: nil, insideForbidden: false), still)
    }

    func testMoving20mOrMoreResetsAnchor() {
        var p = PowerModePolicy()
        _ = p.update(with: fix(), nearestForbidden: 700, insideForbidden: false)
        XCTAssertEqual(p.update(with: fix(seconds: 200), nearestForbidden: 700, insideForbidden: false), still)
        let moved = fix(north: 25, seconds: 210)
        XCTAssertEqual(p.update(with: moved, nearestForbidden: 700, insideForbidden: false), near)
        XCTAssertFalse(p.isStationary)
        XCTAssertTrue(p.stillAnchor === moved)
        // Yeni çapadan 180 sn sonra yeniden pusu
        XCTAssertEqual(p.update(with: fix(north: 25, seconds: 391), nearestForbidden: 700, insideForbidden: false), still)
    }

    func testInitWithPreviousState() {
        let anchor = fix()
        var p = PowerModePolicy(stillAnchor: anchor, isStationary: true)
        XCTAssertEqual(p.update(with: fix(north: 5, seconds: 10), nearestForbidden: 900, insideForbidden: false), still)
    }

    // MARK: Taze ölçüm / güncel değil

    func testShouldRequestFreshFixAfterMoreThan45s() {
        XCTAssertFalse(PowerModePolicy.shouldRequestFreshFix(lastFix: nil, now: t0))
        XCTAssertFalse(PowerModePolicy.shouldRequestFreshFix(lastFix: t0, now: t0.addingTimeInterval(45)))
        XCTAssertTrue(PowerModePolicy.shouldRequestFreshFix(lastFix: t0, now: t0.addingTimeInterval(45.1)))
    }

    func testStaleAfterMoreThan90s() {
        XCTAssertFalse(PowerModePolicy.isStale(age: 0))
        XCTAssertFalse(PowerModePolicy.isStale(age: 90))
        XCTAssertTrue(PowerModePolicy.isStale(age: 90.1))
        XCTAssertEqual(PowerModePolicy.staleAfter, 90)
    }
}
