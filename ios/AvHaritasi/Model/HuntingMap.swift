import CoreLocation
import Foundation

/// Bir bölge sınıfının avlanma açısından durumu.
enum ZoneStatus: String, Codable {
    case yasak      // avlanmak yasak
    case dikkat     // özel izin / ek kural gerekebilir
    case izinli     // belge, izin kartı ve MAK kararına uyarak avlanılabilir
    case disarida   // deniz / harita dışı / veri yok
}

struct ZoneClass: Codable, Identifiable, Hashable {
    let id: Int
    let key: String
    let name: String
    let status: ZoneStatus
    let description: String
    let color: String
}

struct MapMetadata: Codable {
    struct Bounds: Codable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double
    }

    struct Zones: Codable {
        let file: String
        let width: Int
        let height: Int
        /// (boylam, enlem, 1) -> (x, y, w) projektif dönüşüm, satır sırasıyla 3x3.
        let lonLatToPixel: [Double]
    }

    struct Tiles: Codable {
        let file: String
        let minZoom: Int
        let maxZoom: Int
    }

    let name: String
    let title: String
    let season: String
    let source: String
    let bounds: Bounds
    let zones: Zones
    let tiles: Tiles
    let classes: [ZoneClass]
}

struct NearbyRestriction {
    let zone: ZoneClass
    /// Metre cinsinden en yakın yasak alan hücresine uzaklık.
    let distance: Double
}

enum HuntingMapError: LocalizedError {
    case missingResource(String)
    case badZoneData

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Harita verisi bulunamadı: \(name)"
        case .badZoneData: return "Bölge verisi bozuk."
        }
    }
}

/// Avlak haritası: hangi koordinatın hangi bölgede olduğunu söyler.
/// Veriler `tools/generate_assets.py` ile resmi GeoPDF'ten üretilir.
final class HuntingMap: @unchecked Sendable {
    let meta: MapMetadata
    let tilePack: TilePack

    private let grid: [UInt8]
    private let width: Int
    private let height: Int
    private let h: [Double]
    private let classesByID: [Int: ZoneClass]
    private let restricted: [Bool]   // sınıf kimliği -> yasak mı

    init(resourceName: String, bundle: Bundle = .main) throws {
        let jsonURL = try Self.url(for: resourceName + ".json", in: bundle)
        let meta = try JSONDecoder().decode(MapMetadata.self, from: Data(contentsOf: jsonURL))
        self.meta = meta

        let compressed = try Data(contentsOf: try Self.url(for: meta.zones.file, in: bundle))
        let raw = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard raw.count == meta.zones.width * meta.zones.height, meta.zones.lonLatToPixel.count == 9 else {
            throw HuntingMapError.badZoneData
        }
        grid = [UInt8](raw)
        width = meta.zones.width
        height = meta.zones.height
        h = meta.zones.lonLatToPixel

        var byID: [Int: ZoneClass] = [:]
        var restricted = [Bool](repeating: false, count: 256)
        for c in meta.classes {
            byID[c.id] = c
            if c.status == .yasak, (0..<256).contains(c.id) { restricted[c.id] = true }
        }
        classesByID = byID
        self.restricted = restricted

        tilePack = try TilePack(url: try Self.url(for: meta.tiles.file, in: bundle),
                                minZoom: meta.tiles.minZoom, maxZoom: meta.tiles.maxZoom)
    }

    /// Kaynak dosyaları; Xcode bunları paketin köküne ya da MapData klasörüne kopyalayabilir.
    private static func url(for file: String, in bundle: Bundle) throws -> URL {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        if let u = bundle.url(forResource: name, withExtension: ext) { return u }
        if let u = bundle.url(forResource: name, withExtension: ext, subdirectory: "MapData") { return u }
        throw HuntingMapError.missingResource(file)
    }

    var allClasses: [ZoneClass] { meta.classes.sorted { $0.id < $1.id } }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (meta.bounds.south + meta.bounds.north) / 2,
                               longitude: (meta.bounds.west + meta.bounds.east) / 2)
    }

    private func pixel(lon: Double, lat: Double) -> (x: Double, y: Double) {
        let w = h[6] * lon + h[7] * lat + h[8]
        return ((h[0] * lon + h[1] * lat + h[2]) / w, (h[3] * lon + h[4] * lat + h[5]) / w)
    }

    /// Koordinatın bulunduğu bölge. Harita çerçevesinin dışındaysa `nil`.
    func zone(at c: CLLocationCoordinate2D) -> ZoneClass? {
        let p = pixel(lon: c.longitude, lat: c.latitude)
        let ix = Int(p.x.rounded(.down)), iy = Int(p.y.rounded(.down))
        guard ix >= 0, iy >= 0, ix < width, iy < height else { return nil }
        return classesByID[Int(grid[iy * width + ix])]
    }

    /// `radius` metre içindeki en yakın yasak alan (kendi hücresi hariç değil).
    func nearestRestricted(to c: CLLocationCoordinate2D, within radius: Double) -> NearbyRestriction? {
        let lat = c.latitude, lon = c.longitude
        let p0 = pixel(lon: lon, lat: lat)
        let d = 0.001
        let pLon = pixel(lon: lon + d, lat: lat)
        let pLat = pixel(lon: lon, lat: lat + d)
        // Jacobian: piksel / derece
        let a = (pLon.x - p0.x) / d, b = (pLat.x - p0.x) / d
        let cc = (pLon.y - p0.y) / d, dd = (pLat.y - p0.y) / d
        let det = a * dd - b * cc
        guard det != 0 else { return nil }

        let mPerDegLon = 111_320 * cos(lat * .pi / 180)
        let mPerDegLat = 110_540.0
        let rLon = radius / mPerDegLon, rLat = radius / mPerDegLat
        let rx = Int((abs(a) * rLon + abs(b) * rLat).rounded(.up)) + 1
        let ry = Int((abs(cc) * rLon + abs(dd) * rLat).rounded(.up)) + 1

        let cx = Int(p0.x.rounded(.down)), cy = Int(p0.y.rounded(.down))
        let x0 = max(0, cx - rx), x1 = min(width - 1, cx + rx)
        let y0 = max(0, cy - ry), y1 = min(height - 1, cy + ry)
        guard x0 <= x1, y0 <= y1 else { return nil }

        var best = Double.infinity
        var bestID = -1
        for iy in y0...y1 {
            let row = iy * width
            let dy = Double(iy) + 0.5 - p0.y
            for ix in x0...x1 {
                let v = Int(grid[row + ix])
                guard restricted[v] else { continue }
                let dx = Double(ix) + 0.5 - p0.x
                let dLon = (dd * dx - b * dy) / det
                let dLat = (-cc * dx + a * dy) / det
                let dist = (dLon * mPerDegLon * dLon * mPerDegLon + dLat * mPerDegLat * dLat * mPerDegLat).squareRoot()
                if dist < best {
                    best = dist
                    bestID = v
                }
            }
        }
        guard bestID >= 0, best <= radius, let zone = classesByID[bestID] else { return nil }
        return NearbyRestriction(zone: zone, distance: best)
    }
}
