import XCTest
@testable import AvHaritasi

final class MapZoomStepTests: XCTestCase {
    private let lo = 400.0
    private let hi = MapZoomStep.maxDistance

    func testZoomInHalvesAndZoomOutDoubles() {
        XCTAssertEqual(MapZoomStep.next(distance: 6_000, direction: .zoomIn, min: lo, max: hi), 3_000)
        XCTAssertEqual(MapZoomStep.next(distance: 6_000, direction: .zoomOut, min: lo, max: hi), 12_000)
    }

    func testClampsToLimits() {
        XCTAssertEqual(MapZoomStep.next(distance: 600, direction: .zoomIn, min: lo, max: hi), 400)
        XCTAssertEqual(MapZoomStep.next(distance: 400, direction: .zoomIn, min: lo, max: hi), 400)
        XCTAssertEqual(MapZoomStep.next(distance: 150_000, direction: .zoomOut, min: lo, max: hi), hi)
        XCTAssertEqual(MapZoomStep.next(distance: hi, direction: .zoomOut, min: lo, max: hi), hi)
    }

    func testOutOfRangeDistanceIsNotPushedTheWrongWay() {
        // Elle 200 km'den çok uzaklaşılmışsa "uzaklaştır" yakınlaştırmaz
        XCTAssertEqual(MapZoomStep.next(distance: 500_000, direction: .zoomOut, min: lo, max: hi), 500_000)
        XCTAssertEqual(MapZoomStep.next(distance: 500_000, direction: .zoomIn, min: lo, max: hi), 250_000)
        XCTAssertEqual(MapZoomStep.next(distance: 300, direction: .zoomIn, min: lo, max: hi), 300)
        XCTAssertEqual(MapZoomStep.next(distance: 300, direction: .zoomOut, min: lo, max: hi), 600)
    }

    func testInvalidDistanceFallsBackInsideRange() {
        XCTAssertEqual(MapZoomStep.next(distance: .nan, direction: .zoomIn, min: lo, max: hi), lo)
        XCTAssertEqual(MapZoomStep.next(distance: 0, direction: .zoomOut, min: lo, max: hi), lo)
    }

    func testRepeatedTapsStayInRange() {
        var d = 6_000.0
        for _ in 0..<20 { d = MapZoomStep.next(distance: d, direction: .zoomOut, min: lo, max: hi) }
        XCTAssertEqual(d, hi)
        for _ in 0..<20 { d = MapZoomStep.next(distance: d, direction: .zoomIn, min: lo, max: hi) }
        XCTAssertEqual(d, lo)
    }
}
