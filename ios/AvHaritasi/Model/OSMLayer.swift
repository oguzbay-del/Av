import CoreLocation
import Foundation

/// OpenStreetMap'ten üretilen hassas yer katmanı (`tools/osm_layer.py`):
/// yerleşim alanları, okullar, sağlık tesisleri, askeri alanlar vb.
/// Avlak haritasıyla aynı ızgarada; her hücre bir sınıf kimliği taşır.
final class OSMLayer: @unchecked Sendable {
    struct OSMClass: Decodable {
        let id: Int
        let key: String
        let name: String
        let meters: Double
        let rule: String
        let level: String       // "yasak" | "dikkat"
    }

    private struct Meta: Decodable {
        let source: String
        let fetched: String?
        let file: String
        let width: Int
        let height: Int
        let lonLatToPixel: [Double]
        let classes: [OSMClass]
    }

    let source: String
    let fetched: String?
    let classes: [OSMClass]
    private let grid: [UInt8]
    private let width: Int
    private let height: Int
    private let h: [Double]

    init(resourceName: String = "istanbul_osm", bundle: Bundle = .main) throws {
        let url = try HuntingMap.resourceURL(for: resourceName + ".json", in: bundle)
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: url))
        let compressed = try Data(contentsOf: try HuntingMap.resourceURL(for: meta.file, in: bundle))
        let raw = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard raw.count == meta.width * meta.height, meta.lonLatToPixel.count == 9 else { throw HuntingMapError.badZoneData }
        grid = [UInt8](raw)
        width = meta.width
        height = meta.height
        h = meta.lonLatToPixel
        source = meta.source
        fetched = meta.fetched
        classes = meta.classes
    }

    private func pixel(lon: Double, lat: Double) -> (x: Double, y: Double) {
        let w = h[6] * lon + h[7] * lat + h[8]
        return ((h[0] * lon + h[1] * lat + h[2]) / w, (h[3] * lon + h[4] * lat + h[5]) / w)
    }

    /// `radius` metre içindeki her sınıf için en yakın hücreye uzaklık (metre).
    func nearestPerClass(to c: CLLocationCoordinate2D, within radius: Double) -> [Int: Double] {
        let lat = c.latitude, lon = c.longitude
        let p0 = pixel(lon: lon, lat: lat)
        let d = 0.001
        let pLon = pixel(lon: lon + d, lat: lat)
        let pLat = pixel(lon: lon, lat: lat + d)
        let a = (pLon.x - p0.x) / d, b = (pLat.x - p0.x) / d
        let cc = (pLon.y - p0.y) / d, dd = (pLat.y - p0.y) / d
        let det = a * dd - b * cc
        guard det != 0 else { return [:] }

        let mPerDegLon = 111_320 * cos(lat * .pi / 180)
        let mPerDegLat = 110_540.0
        let rLon = radius / mPerDegLon, rLat = radius / mPerDegLat
        let rx = Int((abs(a) * rLon + abs(b) * rLat).rounded(.up)) + 1
        let ry = Int((abs(cc) * rLon + abs(dd) * rLat).rounded(.up)) + 1
        let cx = Int(p0.x.rounded(.down)), cy = Int(p0.y.rounded(.down))
        let x0 = max(0, cx - rx), x1 = min(width - 1, cx + rx)
        let y0 = max(0, cy - ry), y1 = min(height - 1, cy + ry)
        guard x0 <= x1, y0 <= y1 else { return [:] }

        var best: [Int: Double] = [:]
        for iy in y0...y1 {
            let row = iy * width
            let dy = Double(iy) + 0.5 - p0.y
            for ix in x0...x1 {
                let v = Int(grid[row + ix])
                guard v != 0 else { continue }
                let dx = Double(ix) + 0.5 - p0.x
                let dLon = (dd * dx - b * dy) / det
                let dLat = (-cc * dx + a * dy) / det
                // Hücre yarı genişliği kadar pay: nokta hücrenin içindeyse uzaklık ~0
                let dist = max(0, (dLon * mPerDegLon * dLon * mPerDegLon + dLat * mPerDegLat * dLat * mPerDegLat).squareRoot() - 15)
                if dist <= radius, dist < (best[v] ?? .infinity) { best[v] = dist }
            }
        }
        return best
    }
}
