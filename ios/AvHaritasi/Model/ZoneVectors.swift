import MapKit
import UIKit

/// Bir bölge sınıfının tüm çokgenleri (keskin vektör katman).
final class ZoneShapes: MKMultiPolygon {
    var zone: ZoneClass!
}

/// `tools/vectorize_zones.py` çıktısı: bölge ızgarasından üretilmiş çokgenler.
/// Izgarayla aynı veriden geldiği için ekranda görülen sınır, uyarı veren sınırla aynıdır.
enum ZoneVectors {
    static func load(for map: HuntingMap, bundle: Bundle = .main) -> [ZoneShapes] {
        struct File: Decodable { let classes: [String: [[[Double]]]] }
        guard let url = try? HuntingMap.resourceURL(for: map.meta.name + ".vectors.json", in: bundle),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }

        func ring(_ flat: [Double]) -> [CLLocationCoordinate2D] {
            stride(from: 0, to: flat.count - 1, by: 2).map { CLLocationCoordinate2D(latitude: flat[$0 + 1], longitude: flat[$0]) }
        }
        var out: [ZoneShapes] = []
        for zone in map.allClasses {
            guard let polys = file.classes[String(zone.id)], !polys.isEmpty else { continue }
            let mk: [MKPolygon] = polys.compactMap { rings in
                guard var outer = rings.first.map(ring), outer.count > 2 else { return nil }
                let holes = rings.dropFirst().map { r -> MKPolygon in
                    var c = ring(r)
                    return MKPolygon(coordinates: &c, count: c.count)
                }
                return MKPolygon(coordinates: &outer, count: outer.count, interiorPolygons: holes)
            }
            let shapes = ZoneShapes(mk)
            shapes.zone = zone
            out.append(shapes)
        }
        // Yasak alanlar en üstte çizilsin
        return out.sorted { $0.zone.displayOrder < $1.zone.displayOrder }
    }
}

extension ZoneClass {
    /// Haritada okunaklı, Google Haritalar tarzı renkler (resmi renkler lejantta kalır).
    var displayColor: UIColor {
        switch key {
        case "ava_yasak": return UIColor(red: 0.90, green: 0.16, blue: 0.16, alpha: 1)
        case "korunan_alan": return UIColor(red: 0.13, green: 0.55, blue: 0.27, alpha: 1)
        case "yaban_hayvani_yerlestirme": return UIColor(red: 0.96, green: 0.65, blue: 0.0, alpha: 1)
        case "ornek_avlak": return UIColor(red: 0.45, green: 0.35, blue: 0.75, alpha: 1)
        case "devlet_avlagi": return UIColor(red: 0.80, green: 0.62, blue: 0.30, alpha: 1)
        case "genel_avlak": return UIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        case "gol": return UIColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1)
        default: return .gray
        }
    }

    /// Dolgu saydamlığı: yasaklar belirgin, izinli alanlar hafif.
    var fillAlpha: CGFloat {
        switch status {
        case .yasak: return 0.30
        case .dikkat: return 0.22
        case .izinli: return key == "devlet_avlagi" ? 0.10 : 0.0
        case .disarida: return 0
        }
    }

    var displayOrder: Int {
        switch status {
        case .disarida: return 0
        case .izinli: return 1
        case .dikkat: return 2
        case .yasak: return 3
        }
    }
}
