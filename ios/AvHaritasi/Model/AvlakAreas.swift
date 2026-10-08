import MapKit
import UIKit

/// Haritada vurgulanan avlak (izin belgesinden ya da elle seçilen).
final class AvlakHighlight: MKMultiPolygon {
    var name = ""
}

/// Avlak sınırları: 2024-25 haritasının avlak birimlerinden (`tools/vectorize_units.py`), yaklaşık.
struct AvlakAreas {
    struct Area {
        let unit: String
        let polygons: [MKPolygon]
        let labelPoint: CLLocationCoordinate2D
        fileprivate let rings: [[CLLocationCoordinate2D]]

        var boundingRect: MKMapRect {
            polygons.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
        }

        /// Yol tarifi hedefi: konum varsa avlağın size en yakın kenar noktası (Google/Apple en yakın
        /// yola yönlendirir), yoksa avlağın iç noktası.
        func destination(from c: CLLocationCoordinate2D?) -> CLLocationCoordinate2D {
            guard let c else { return labelPoint }
            let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
            var best = labelPoint
            var bestD = CLLocationDistance.infinity
            for ring in rings {
                for p in ring {
                    let d = here.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude))
                    if d < bestD { bestD = d; best = p }
                }
            }
            return best
        }
    }

    private let byUnit: [String: Area]

    init(resourceName: String = "istanbul_2024_2025", bundle: Bundle = .main) {
        struct File: Decodable {
            struct U: Decodable { let label: [Double]; let polygons: [[[Double]]] }
            let units: [String: U]
        }
        guard let url = try? HuntingMap.resourceURL(for: resourceName + ".units.vectors.json", in: bundle),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { byUnit = [:]; return }
        func ring(_ f: [Double]) -> [CLLocationCoordinate2D] {
            stride(from: 0, to: f.count - 1, by: 2).map { CLLocationCoordinate2D(latitude: f[$0 + 1], longitude: f[$0]) }
        }
        var out: [String: Area] = [:]
        for (unit, u) in file.units {
            var rings: [[CLLocationCoordinate2D]] = []
            let polys: [MKPolygon] = u.polygons.compactMap { rs in
                guard var outer = rs.first.map(ring), outer.count > 2 else { return nil }
                rings.append(outer)
                let holes = rs.dropFirst().map { r -> MKPolygon in var c = ring(r); return MKPolygon(coordinates: &c, count: c.count) }
                return MKPolygon(coordinates: &outer, count: outer.count, interiorPolygons: holes)
            }
            out[unit] = Area(unit: unit, polygons: polys,
                             labelPoint: CLLocationCoordinate2D(latitude: u.label[1], longitude: u.label[0]), rings: rings)
        }
        byUnit = out
    }

    func area(for avlak: Regulations.Avlak) -> Area? {
        avlak.unit.flatMap { byUnit[$0] }
    }
}

/// Google Haritalar / Apple Haritalar ile yol tarifi.
enum Directions {
    static func googleMaps(to c: CLLocationCoordinate2D) -> URL {
        // Evrensel bağlantı: Google Haritalar yüklüyse uygulamada, değilse tarayıcıda açılır.
        var comps = URLComponents(string: "https://www.google.com/maps/dir/")!
        comps.queryItems = [
            .init(name: "api", value: "1"),
            .init(name: "destination", value: String(format: "%.6f,%.6f", c.latitude, c.longitude)),
            .init(name: "travelmode", value: "driving"),
        ]
        return comps.url!
    }

    static func openAppleMaps(to c: CLLocationCoordinate2D, name: String) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}
