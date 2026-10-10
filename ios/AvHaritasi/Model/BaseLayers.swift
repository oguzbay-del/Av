import MapKit
import UIKit

/// Harita altlığı. Apple katmanları MapKit'in kendisidir; OpenTopoMap ve
/// OpenStreetMap ise karo katmanı olarak eklenir. Çevrimdışı topo cihazdaki paketlerden çizilir.
enum BaseLayer: String, CaseIterable, Identifiable {
    case appleHybrid, appleSatellite, appleStandard, openTopoMap, openStreetMap, offlineTopo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleHybrid: return L("Apple Uydu + yol")
        case .appleSatellite: return L("Apple Uydu")
        case .appleStandard: return L("Apple Standart")
        case .openTopoMap: return L("OpenTopoMap (eş yükselti, patika)")
        case .openStreetMap: return "OpenStreetMap"
        case .offlineTopo: return L("Çevrimdışı topo (İstanbul)")
        }
    }

    /// İnternet gerektiren altlık mı (Apple katmanları da çevrimiçidir).
    var isOnline: Bool { self != .offlineTopo }

    /// Gösterilecek altlık: internet yokken çevrimiçi bir altlık seçiliyse ve çevrimdışı paket
    /// varsa çevrimdışı topo; internet varken kullanıcının seçimi. Paket silindiyse Apple'a dönülür.
    static func effective(chosen: BaseLayer, online: Bool, offlineAvailable: Bool) -> BaseLayer {
        if chosen == .offlineTopo { return offlineAvailable ? .offlineTopo : .appleHybrid }
        if !online, offlineAvailable { return .offlineTopo }
        return chosen
    }

    /// 3B gerçekçi arazi (eğilince tepeler görünür), sade renkler, işletme simgeleri kapalı.
    var configuration: MKMapConfiguration {
        switch self {
        case .appleHybrid:
            let c = MKHybridMapConfiguration(elevationStyle: .realistic)
            c.pointOfInterestFilter = .excludingAll
            return c
        case .appleSatellite:
            return MKImageryMapConfiguration(elevationStyle: .realistic)
        default:
            let c = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            c.showsTraffic = false
            return c
        }
    }

    var icon: String {
        switch self {
        case .appleHybrid: return "globe.europe.africa.fill"
        case .appleSatellite: return "photo"
        case .appleStandard: return "map"
        case .openTopoMap: return "mountain.2"
        case .openStreetMap: return "point.topleft.down.to.point.bottomright.curvepath"
        case .offlineTopo: return "arrow.down.circle"
        }
    }

    var shortTitle: String {
        switch self {
        case .appleHybrid: return L("Uydu + yol")
        case .appleSatellite: return L("Uydu")
        case .appleStandard: return L("Standart")
        case .openTopoMap: return L("Topoğrafik")
        case .openStreetMap: return "OSM"
        case .offlineTopo: return L("Çevrimdışı")
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
        case .offlineTopo: return 18
        default: return 21
        }
    }

    var attribution: String? {
        switch self {
        case .openTopoMap: return L("© OpenStreetMap katkıcıları, SRTM · Stil: © OpenTopoMap (CC-BY-SA)")
        case .openStreetMap: return L("© OpenStreetMap katkıcıları")
        case .offlineTopo: return OfflineBasemap.fallbackAttribution
        default: return nil
        }
    }
}

/// Uzak karo katmanı; görüntülenen karoları Caches klasöründe saklar ve
/// internet yokken oradan gösterir (toplu indirme yapmaz — OSM kullanım
/// politikası gereği yalnızca gezilen bölgeler önbelleğe alınır).
/// İnternet yokken (NWPathMonitor) ağ hiç denenmez; zaman aşımı beklenmeden önbellek gösterilir.
final class CachingTileOverlay: MKTileOverlay {
    let layer: BaseLayer
    private let directory: URL
    private let session: URLSession

    init(layer: BaseLayer) {
        self.layer = layer
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("tiles/\(layer.rawValue)", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "AvHaritasi/1.0 (+https://github.com/oguzbay-del/harita-veri; iOS)"]
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
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
        guard NetworkState.shared.isOnline else {
            // Çevrimdışı: eski karo varsa o, yoksa hemen hata (MapKit boş bırakır)
            result(cached, cached == nil ? URLError(.notConnectedToInternet) : nil)
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
