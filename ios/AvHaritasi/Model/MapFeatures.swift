import CoreLocation
import Foundation

/// Avlak haritasının vektör katmanlarından çıkarılan öğeler
/// (`tools/extract_features.py`): yerleşim merkezleri, mesire yerleri, yollar
/// ve avlak birimleri.
final class MapFeatures: @unchecked Sendable {
    struct Place: Decodable {
        let kind: String        // il, ilce, koy, mesire
        let name: String?
        let lat: Double
        let lon: Double

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

        var title: String {
            switch kind {
            case "mesire": return L("Mesire yeri")
            case "il": return L("%@ il merkezi", name ?? L("İl"))
            case "ilce": return L("%@ merkezi", name ?? L("İlçe"))
            default: return L("%@ köy merkezi", name ?? L("Köy"))
            }
        }
    }

    private struct Raw: Decodable {
        struct Units: Decodable {
            struct Name: Decodable { let id: Int; let label: String }
            let file: String
            let width: Int
            let height: Int
            let lonLatToPixel: [Double]
            let names: [Name]
        }
        let places: [Place]
        let roads: [String: [[[Double]]]]
        let units: Units
    }

    struct Segment {
        let a: (lat: Double, lon: Double)
        let b: (lat: Double, lon: Double)
        let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    }

    let places: [Place]
    /// Çizim için yol çizgileri (tür -> çizgiler -> [enlem, boylam]).
    let roadLines: [String: [[[Double]]]]
    private let segments: [String: [Segment]]

    private let unitGrid: [UInt8]
    private let unitWidth: Int
    private let unitHeight: Int
    private let unitH: [Double]
    private let unitNames: [Int: String]

    init(resourceName: String, bundle: Bundle = .main) throws {
        let url = try HuntingMap.resourceURL(for: resourceName + ".features.json", in: bundle)
        let raw = try JSONDecoder().decode(Raw.self, from: Data(contentsOf: url))
        places = raw.places
        roadLines = raw.roads
        var segs: [String: [Segment]] = [:]
        for (kind, lines) in raw.roads {
            var list: [Segment] = []
            for line in lines where line.count > 1 {
                for i in 1..<line.count {
                    let a = (lat: line[i - 1][0], lon: line[i - 1][1])
                    let b = (lat: line[i][0], lon: line[i][1])
                    list.append(Segment(a: a, b: b,
                                        minLat: min(a.lat, b.lat), maxLat: max(a.lat, b.lat),
                                        minLon: min(a.lon, b.lon), maxLon: max(a.lon, b.lon)))
                }
            }
            segs[kind] = list
        }
        segments = segs

        let u = raw.units
        let compressed = try Data(contentsOf: try HuntingMap.resourceURL(for: u.file, in: bundle))
        let bytes = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard bytes.count == u.width * u.height, u.lonLatToPixel.count == 9 else { throw HuntingMapError.badZoneData }
        unitGrid = [UInt8](bytes)
        unitWidth = u.width
        unitHeight = u.height
        unitH = u.lonLatToPixel
        unitNames = Dictionary(uniqueKeysWithValues: u.names.map { ($0.id, $0.label) })
    }

    /// Haritadaki (2024-2025) avlak birimi etiketi, ör. "ŞİLE D.A.".
    func unitLabel(at c: CLLocationCoordinate2D) -> String? {
        let h = unitH
        let w = h[6] * c.longitude + h[7] * c.latitude + h[8]
        let x = (h[0] * c.longitude + h[1] * c.latitude + h[2]) / w
        let y = (h[3] * c.longitude + h[4] * c.latitude + h[5]) / w
        let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
        guard ix >= 0, iy >= 0, ix < unitWidth, iy < unitHeight else { return nil }
        let id = Int(unitGrid[iy * unitWidth + ix])
        return id == 0 ? nil : unitNames[id]
    }

    func nearestPlace(kinds: Set<String>, to c: CLLocationCoordinate2D, within radius: Double) -> (place: Place, distance: Double)? {
        let proj = LocalProjection(c)
        let d = proj.degrees(for: radius)
        var best: (Place, Double)?
        for p in places where kinds.contains(p.kind) {
            guard abs(p.lat - c.latitude) <= d.lat, abs(p.lon - c.longitude) <= d.lon else { continue }
            let v = proj.xy(p.lat, p.lon)
            let dist = (v.x * v.x + v.y * v.y).squareRoot()
            if dist <= radius, dist < (best?.1 ?? .infinity) { best = (p, dist) }
        }
        return best
    }

    func nearestRoad(kind: String, to c: CLLocationCoordinate2D, within radius: Double) -> Double? {
        guard let list = segments[kind] else { return nil }
        let proj = LocalProjection(c)
        let d = proj.degrees(for: radius)
        var best = Double.infinity
        for s in list {
            guard c.latitude >= s.minLat - d.lat, c.latitude <= s.maxLat + d.lat,
                  c.longitude >= s.minLon - d.lon, c.longitude <= s.maxLon + d.lon else { continue }
            best = min(best, Geo.distanceToSegment(proj.xy(s.a.lat, s.a.lon), proj.xy(s.b.lat, s.b.lon)))
        }
        return best <= radius ? best : nil
    }
}
