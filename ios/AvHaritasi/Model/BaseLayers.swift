import MapKit
import UIKit

/// Harita altlığı. Apple katmanları MapKit'in kendisidir; OpenTopoMap ve
/// OpenStreetMap ise karo katmanı olarak eklenir.
enum BaseLayer: String, CaseIterable, Identifiable {
    case appleHybrid, appleSatellite, appleStandard, openTopoMap, openStreetMap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleHybrid: return "Apple Uydu + yol"
        case .appleSatellite: return "Apple Uydu"
        case .appleStandard: return "Apple Standart"
        case .openTopoMap: return "OpenTopoMap (eş yükselti, patika)"
        case .openStreetMap: return "OpenStreetMap"
        }
    }

    var mapType: MKMapType {
        switch self {
        case .appleHybrid: return .hybrid
        case .appleSatellite: return .satellite
        default: return .standard
        }
    }

    /// Karo adresi şablonu (Apple katmanları için nil).
    var template: String? {
        switch self {
        case .openTopoMap: return "https://tile.opentopomap.org/{z}/{x}/{y}.png"
        case .openStreetMap: return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        default: return nil
        }
    }

    var maxZoom: Int {
        switch self {
        case .openTopoMap: return 17
        case .openStreetMap: return 19
        default: return 21
        }
    }

    var attribution: String? {
        switch self {
        case .openTopoMap: return "© OpenStreetMap katkıcıları, SRTM · Stil: © OpenTopoMap (CC-BY-SA)"
        case .openStreetMap: return "© OpenStreetMap katkıcıları"
        default: return nil
        }
    }
}

/// Uzak karo katmanı; görüntülenen karoları Caches klasöründe saklar ve
/// internet yokken oradan gösterir (toplu indirme yapmaz — OSM kullanım
/// politikası gereği yalnızca gezilen bölgeler önbelleğe alınır).
final class CachingTileOverlay: MKTileOverlay {
    let layer: BaseLayer
    private let directory: URL
    private let session: URLSession

    init(layer: BaseLayer) {
        self.layer = layer
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("tiles/\(layer.rawValue)", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "AvHaritasi/1.0 (iOS; kisisel kullanim)"]
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        super.init(urlTemplate: layer.template)
        canReplaceMapContent = true
        maximumZ = layer.maxZoom
        tileSize = CGSize(width: 256, height: 256)
    }

    private func file(for path: MKTileOverlayPath) -> URL {
        directory.appendingPathComponent("\(path.z)/\(path.x)/\(path.y).png")
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let local = file(for: path)
        let cached = try? Data(contentsOf: local)
        // 30 günden yeni önbellek doğrudan kullanılır.
        if let cached,
           let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 30 * 86_400 {
            result(cached, nil)
            return
        }
        session.dataTask(with: url(forTilePath: path)) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: local, options: .atomic)
                result(data, nil)
            } else if let cached {
                result(cached, nil)      // çevrimdışı: eski karo
            } else {
                result(nil, error ?? URLError(.cannotLoadFromNetwork))
            }
        }.resume()
    }

    static func cacheSize() -> Int64 {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tiles")
        guard let e = FileManager.default.enumerator(at: caches, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func clearCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tiles")
        try? FileManager.default.removeItem(at: caches)
    }
}
