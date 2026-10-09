import UIKit
import XCTest
@testable import AvHaritasi

/// AVTP karo paketi (uygulamayla gelen istanbul_topo_low.avtp, z8–12) ve karo büyütme.
final class TilePackTests: XCTestCase {
    private func lowPackURL() throws -> URL {
        try HuntingMap.resourceURL(for: OfflineBasemap.lowPackName, in: .main)
    }

    private func lowPack() throws -> TilePack {
        try TilePack(url: lowPackURL(), minZoom: OfflineBasemap.lowZoom.lowerBound, maxZoom: OfflineBasemap.lowZoom.upperBound)
    }

    func testHeader() throws {
        let data = try Data(contentsOf: lowPackURL())
        XCTAssertEqual(data.prefix(4), Data("AVTP".utf8))
        let u32 = { (o: Int) -> Int in data.subdata(in: o..<(o + 4)).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) } }
        XCTAssertEqual(u32(4), 1, "Sürüm")
        let count = u32(8)
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThanOrEqual(12 + count * 24, data.count)
        // Tüm dizin girdileri z8–12 aralığında
        for i in 0..<count {
            XCTAssert(OfflineBasemap.lowZoom.contains(Int(data[12 + i * 24])), "girdi \(i)")
        }
    }

    func testKnownZ8TileDecodes() throws {
        let pack = try lowPack()
        // İstanbul'un doğusunu kapsayan z8 karosu (x 148, y 96)
        let tile = try XCTUnwrap(pack.tile(z: 8, x: 148, y: 96))
        let image = try XCTUnwrap(UIImage(data: tile), "Karo görüntü olarak çözülmeli (JPEG/PNG)")
        XCTAssertEqual(image.cgImage?.width, 256)
        XCTAssertEqual(image.cgImage?.height, 256)
    }

    func testMissingTileIsNil() throws {
        let pack = try lowPack()
        XCTAssertNil(pack.tile(z: 8, x: 0, y: 0))
        XCTAssertNil(pack.tile(z: 13, x: 148 << 5, y: 96 << 5), "Düşük pakette z13 yok")
    }

    func testBadFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bozuk-\(UUID().uuidString).avtp")
        try Data("XXXX\u{1}\0\0\0\u{5}\0\0\0".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try TilePack(url: url, minZoom: 8, maxZoom: 12))

        // Doğru imza ama dizin dosyadan uzun
        var d = Data("AVTP".utf8)
        d.append(contentsOf: [1, 0, 0, 0, 100, 0, 0, 0])
        try d.write(to: url)
        XCTAssertThrowsError(try TilePack(url: url, minZoom: 8, maxZoom: 12))
    }

    func testHuntingMapTilePackLoads() throws {
        let ctx = try TestData.context()
        XCTAssertEqual(ctx.map.tilePack.minZoom, ctx.map.meta.tiles.minZoom)
        XCTAssertEqual(ctx.map.tilePack.maxZoom, ctx.map.meta.tiles.maxZoom)
    }

    // MARK: - TileImage

    func testUpscaleSize() throws {
        let parent = try XCTUnwrap(try lowPack().tile(z: 8, x: 148, y: 96))
        // z10 karosu (dz = 2): üst karonun 64×64 px'lik çeyreği 256 pt @2x'e büyütülür
        let png = try XCTUnwrap(TileImage.upscale(parent, dz: 2, x: 148 * 4 + 1, y: 96 * 4 + 2,
                                                  size: CGSize(width: 256, height: 256), scale: 2))
        let img = try XCTUnwrap(UIImage(data: png)?.cgImage)
        XCTAssertEqual(img.width, 512)
        XCTAssertEqual(img.height, 512)

        let one = try XCTUnwrap(TileImage.upscale(parent, dz: 1, x: 297, y: 193, size: CGSize(width: 256, height: 256), scale: 1))
        XCTAssertEqual(UIImage(data: one)?.cgImage?.width, 256)
    }

    func testUpscaleRejectsBadInput() throws {
        let parent = try XCTUnwrap(try lowPack().tile(z: 8, x: 148, y: 96))
        XCTAssertNil(TileImage.upscale(parent, dz: 0, x: 148, y: 96, size: CGSize(width: 256, height: 256), scale: 1))
        XCTAssertNil(TileImage.upscale(Data("not an image".utf8), dz: 1, x: 0, y: 0, size: CGSize(width: 256, height: 256), scale: 1))
    }

    func testPlaceholderTiles() throws {
        for data in [TileImage.empty, TileImage.sea] {
            let img = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(img.width, 1)
            XCTAssertEqual(img.height, 1)
        }
    }
}

/// "Güvenli daire" yarıçapı (CLMonitor'dan bağımsız saf hesap).
final class GeofenceRadiusTests: XCTestCase {
    func testClamp() {
        XCTAssertEqual(Geofence.radius(distanceToForbidden: nil), Geofence.maxRadius - 100, "Yasak alan bilinmiyorsa maxRadius uzaklık varsayılır (−100 m)")
        XCTAssertEqual(Geofence.radius(distanceToForbidden: 0), Geofence.minRadius, "İçerideyken en küçük daire")
        XCTAssertEqual(Geofence.radius(distanceToForbidden: -50), Geofence.minRadius)
        XCTAssertEqual(Geofence.radius(distanceToForbidden: 250), Geofence.minRadius)
        XCTAssertEqual(Geofence.radius(distanceToForbidden: 300), 200)
        XCTAssertEqual(Geofence.radius(distanceToForbidden: 301), 201)
        XCTAssertEqual(Geofence.radius(distanceToForbidden: 800), 700, "Yasak alana ~100 m kala uyan")
        XCTAssertEqual(Geofence.radius(distanceToForbidden: 3_100), 3_000)
        XCTAssertEqual(Geofence.radius(distanceToForbidden: 50_000), Geofence.maxRadius)
    }

    func testBounds() {
        XCTAssertEqual(Geofence.minRadius, 200)
        XCTAssertEqual(Geofence.maxRadius, 3_000)
        for d in stride(from: -1_000.0, through: 10_000, by: 37) {
            let r = Geofence.radius(distanceToForbidden: d)
            XCTAssert((Geofence.minRadius...Geofence.maxRadius).contains(r))
        }
    }
}
