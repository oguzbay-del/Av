import CoreLocation
import XCTest
@testable import AvHaritasi

final class WaypointTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 41.0, longitude: 29.0)

    func testBearingCardinalDirections() {
        let north = CLLocationCoordinate2D(latitude: 41.01, longitude: 29.0)
        let east = CLLocationCoordinate2D(latitude: 41.0, longitude: 29.01)
        let south = CLLocationCoordinate2D(latitude: 40.99, longitude: 29.0)
        let west = CLLocationCoordinate2D(latitude: 41.0, longitude: 28.99)
        XCTAssertEqual(WaypointMath.bearing(from: origin, to: north), 0, accuracy: 0.01)
        XCTAssertEqual(WaypointMath.bearing(from: origin, to: east), 90, accuracy: 0.1)
        XCTAssertEqual(WaypointMath.bearing(from: origin, to: south), 180, accuracy: 0.01)
        XCTAssertEqual(WaypointMath.bearing(from: origin, to: west), 270, accuracy: 0.1)
        let ne = CLLocationCoordinate2D(latitude: 41.01, longitude: 29.0 + 0.01 / cos(41 * .pi / 180))
        XCTAssertEqual(WaypointMath.bearing(from: origin, to: ne), 45, accuracy: 0.5)
    }

    func testRelativeAngleWrapsAround() {
        XCTAssertEqual(WaypointMath.relativeAngle(bearing: 10, heading: 350), 20, accuracy: 1e-9)
        XCTAssertEqual(WaypointMath.relativeAngle(bearing: 350, heading: 10), -20, accuracy: 1e-9)
        XCTAssertEqual(WaypointMath.relativeAngle(bearing: 90, heading: 90), 0, accuracy: 1e-9)
        XCTAssertEqual(WaypointMath.relativeAngle(bearing: 0, heading: 180), 180, accuracy: 1e-9)
        XCTAssertEqual(WaypointMath.relativeAngle(bearing: 270, heading: 0), -90, accuracy: 1e-9)
    }

    func testNormalizeAndOctant() {
        XCTAssertEqual(WaypointMath.normalize(-90), 270, accuracy: 1e-9)
        XCTAssertEqual(WaypointMath.normalize(720), 0, accuracy: 1e-9)
        XCTAssertEqual(WaypointMath.octant(0), 0)
        XCTAssertEqual(WaypointMath.octant(44), 1)
        XCTAssertEqual(WaypointMath.octant(100), 2)
        XCTAssertEqual(WaypointMath.octant(350), 0)
        XCTAssertEqual(WaypointMath.octant(-45), 7)
    }

    func testWalkingETA() {
        // 4 km/sa: 1 km = 15 dk, 1,2 km = 18 dk
        XCTAssertEqual(WaypointMath.etaMinutes(meters: 1_000), 15)
        XCTAssertEqual(WaypointMath.etaMinutes(meters: 1_200), 18)
        XCTAssertEqual(WaypointMath.etaMinutes(meters: 0), 1)
        XCTAssertEqual(WaypointMath.etaMinutes(meters: 10), 1)
        let p = WaypointMath.etaParts(meters: 5_000)
        XCTAssertEqual(p.hours, 1)
        XCTAssertEqual(p.minutes, 15)
    }

    func testGPXEscapesAndContainsWaypoints() {
        let w = Waypoint(kind: .arac, name: "Araç <&> \"1\"", lat: 41.1, lon: 29.2,
                         date: Date(timeIntervalSince1970: 0), note: "Yol & köprü")
        let gpx = WaypointMath.gpx([w])
        XCTAssertTrue(gpx.contains("<wpt lat=\"41.1\" lon=\"29.2\">"))
        XCTAssertTrue(gpx.contains("<name>Araç &lt;&amp;&gt; &quot;1&quot;</name>"))
        XCTAssertTrue(gpx.contains("<desc>Yol &amp; köprü</desc>"))
        XCTAssertTrue(gpx.contains("<type>arac</type>"))
        XCTAssertTrue(gpx.hasSuffix("</gpx>\n"))
    }

    @MainActor
    func testStorePersistsRenamesAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WaypointTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("isaretler.json")
        let store = WaypointStore(url: url)
        let a = try XCTUnwrap(store.add(kind: .pusu, name: "  ", coordinate: origin))
        XCTAssertFalse(a.name.isEmpty)
        let b = try XCTUnwrap(store.add(kind: .pusu, name: "Meşe", coordinate: origin, note: "  "))
        XCTAssertNil(b.note)
        store.rename(a.id, to: "Sırt")
        store.guidingID = b.id
        store.delete(b.id)
        XCTAssertNil(store.guidingID)

        let reloaded = WaypointStore(url: url)
        XCTAssertEqual(reloaded.items.map(\.name), ["Sırt"])
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    @MainActor
    func testStoreLimitAndDistanceSorting() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WaypointTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WaypointStore(url: url)
        store.add(kind: .su, name: "Uzak", coordinate: CLLocationCoordinate2D(latitude: 41.1, longitude: 29.0))
        store.add(kind: .su, name: "Yakın", coordinate: CLLocationCoordinate2D(latitude: 41.001, longitude: 29.0))
        let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        XCTAssertEqual(store.sorted(from: here).map(\.name), ["Yakın", "Uzak"])
        for i in store.items.count..<WaypointStore.maxCount {
            XCTAssertNotNil(store.add(kind: .not, name: "N\(i)", coordinate: origin))
        }
        XCTAssertTrue(store.isFull)
        XCTAssertNil(store.add(kind: .not, coordinate: origin))
    }
}
