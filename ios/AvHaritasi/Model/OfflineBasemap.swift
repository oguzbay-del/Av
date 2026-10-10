import CryptoKit
import Foundation
import MapKit
import UIKit

/// Çevrimdışı topoğrafik altlık (OSM + Copernicus DEM, AVTP karo paketleri):
/// - `istanbul_topo_low.avtp` (z8–12) uygulamayla gelir (yoksa da çalışır),
/// - `istanbul_topo_high.avtp` (z13–15) kullanıcı isteyince GitHub Releases'ten indirilir
///   ve Application Support/harita altında (iCloud yedeğine girmeden) saklanır.
struct BasemapManifest: Codable, Sendable, Equatable {
    struct File: Codable, Sendable, Equatable {
        let name: String
        let minZoom: Int
        let maxZoom: Int
        let bytes: Int64
        let sha256: String
        let url: String
    }

    let version: String
    let attribution: String
    let files: [File]

    var highPack: File? { files.first { $0.name == OfflineBasemap.highPackName } }
}

/// Cihazda kurulu indirilmiş paketin bilgisi (installed.json).
struct InstalledBasemap: Codable, Sendable, Equatable {
    let version: String
    let attribution: String
    let file: BasemapManifest.File
    let installed: Date
}

/// İndirme görevine iliştirilen bilgi (görevin `taskDescription`ında JSON; uygulama yeniden
/// açılsa da arka plan oturumu görevle birlikte geri verir).
struct BasemapDownloadJob: Codable, Sendable, Equatable {
    let version: String
    let attribution: String
    let file: BasemapManifest.File

    var encoded: String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }

    init(version: String, attribution: String, file: BasemapManifest.File) {
        self.version = version
        self.attribution = attribution
        self.file = file
    }

    init?(encoded: String?) {
        guard let d = encoded?.data(using: .utf8), let job = try? JSONDecoder().decode(Self.self, from: d) else { return nil }
        self = job
    }
}

enum OfflineBasemap {
    static let manifestURL = URL(string: "https://github.com/oguzbay-del/harita-veri/releases/download/basemap-istanbul/basemap_manifest.json")!
    static let lowPackName = "istanbul_topo_low.avtp"
    static let highPackName = "istanbul_topo_high.avtp"
    static let lowZoom = 8...12
    static let highZoom = 13...15
    /// Manifest okunamazsa gösterilecek kaynak bilgisi.
    static var fallbackAttribution: String {
        L("© OpenStreetMap katkıcıları (ODbL) · Yükselti: Copernicus DEM GLO-30 © DLR e.V., Airbus; AB ve ESA tarafından sağlanmıştır")
    }

    enum InstallError: Error, Sendable {
        case http(Int)
        case size(expected: Int64, actual: Int64)
        case checksum
        case badFile
        case io(String)

        var message: String {
            switch self {
            case .http(let code): return L("Sunucu hatası (HTTP %@)", String(code))
            case .size: return L("İndirilen dosya eksik; yeniden deneyin.")
            case .checksum: return L("Dosya doğrulanamadı (SHA-256 uyuşmuyor); yeniden deneyin.")
            case .badFile: return L("İndirilen dosya geçerli bir harita paketi değil.")
            case .io(let m): return L("Dosya kaydedilemedi: %@", m)
            }
        }
    }

    // MARK: Dosya yerleri

    /// Application Support/harita (yedeklemeden hariç).
    static var directory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("harita", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    static var highPackURL: URL { directory.appendingPathComponent(highPackName) }
    private static var installedInfoURL: URL { directory.appendingPathComponent("installed.json") }
    private static var resumeDataURL: URL { directory.appendingPathComponent("indirme.resume") }
    private static var resumeJobURL: URL { directory.appendingPathComponent("indirme.json") }

    /// Uygulamayla gelen düşük ayrıntılı paket (henüz eklenmemiş olabilir).
    static var bundledLowPackURL: URL? {
        try? HuntingMap.resourceURL(for: lowPackName, in: .main)
    }

    static func installedInfo() -> InstalledBasemap? {
        guard FileManager.default.fileExists(atPath: highPackURL.path),
              let d = try? Data(contentsOf: installedInfoURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(InstalledBasemap.self, from: d)
    }

    static var hasAnyPack: Bool {
        bundledLowPackURL != nil || installedInfo() != nil
    }

    /// Paketleri aç (yüksek ayrıntı önce). Bozuk/eksik paket atlanır.
    static func loadPacks() -> [TilePack] {
        var packs: [TilePack] = []
        if let info = installedInfo(),
           let p = try? TilePack(url: highPackURL, minZoom: info.file.minZoom, maxZoom: info.file.maxZoom) {
            packs.append(p)
        }
        if let url = bundledLowPackURL, let p = try? TilePack(url: url, minZoom: lowZoom.lowerBound, maxZoom: lowZoom.upperBound) {
            packs.append(p)
        }
        return packs
    }

    // MARK: Yarım kalan indirme

    static func saveResume(_ data: Data, job: BasemapDownloadJob) {
        try? data.write(to: resumeDataURL, options: .atomic)
        try? JSONEncoder().encode(job).write(to: resumeJobURL, options: .atomic)
    }

    static func resume() -> (data: Data, job: BasemapDownloadJob)? {
        guard let d = try? Data(contentsOf: resumeDataURL),
              let j = try? Data(contentsOf: resumeJobURL),
              let job = try? JSONDecoder().decode(BasemapDownloadJob.self, from: j) else { return nil }
        return (d, job)
    }

    static func clearResume() {
        try? FileManager.default.removeItem(at: resumeDataURL)
        try? FileManager.default.removeItem(at: resumeJobURL)
    }

    // MARK: Kurulum

    /// İndirilen dosyayı doğrula (boyut, SHA-256, AVTP başlığı) ve yerine atomik olarak taşı.
    /// URLSession'ın verdiği geçici dosya bu çağrı dönünce silindiği için eşzamanlı çalışır.
    static func install(downloadedFile tmp: URL, job: BasemapDownloadJob, httpStatus: Int) -> Result<InstalledBasemap, InstallError> {
        guard httpStatus == 200 else { return .failure(.http(httpStatus)) }
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard size == job.file.bytes else { return .failure(.size(expected: job.file.bytes, actual: size)) }
        guard let header = try? FileHandle(forReadingFrom: tmp), (try? header.read(upToCount: 4)) == Data("AVTP".utf8) else {
            return .failure(.badFile)
        }
        try? header.close()
        guard let digest = sha256(of: tmp), digest == job.file.sha256.lowercased() else { return .failure(.checksum) }

        let staging = directory.appendingPathComponent(".\(highPackName).part")
        do {
            try? fm.removeItem(at: staging)
            try fm.moveItem(at: tmp, to: staging)
            if fm.fileExists(atPath: highPackURL.path) {
                _ = try fm.replaceItemAt(highPackURL, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: highPackURL)
            }
            var dest = highPackURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dest.setResourceValues(values)
            let info = InstalledBasemap(version: job.version, attribution: job.attribution, file: job.file, installed: Date())
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(info).write(to: installedInfoURL, options: .atomic)
            clearResume()
            return .success(info)
        } catch {
            try? fm.removeItem(at: staging)
            return .failure(.io(error.localizedDescription))
        }
    }

    static func removeInstalled() {
        try? FileManager.default.removeItem(at: highPackURL)
        try? FileManager.default.removeItem(at: installedInfoURL)
        clearResume()
    }

    /// Büyük dosyayı belleğe almadan, parça parça SHA-256.
    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = autoreleasepool { try? h.read(upToCount: 4 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Önemli veriler için kullanılabilir boş alan (bayt).
    static func availableCapacity() -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Yerel AVTP paketlerinden topoğrafik altlık. İnternet hiç gerekmez.
/// z15'ten sonrası (z16–18) ve indirilmemiş ayrıntılı paket yerine üst karo büyütülerek gösterilir;
/// paketlerde olmayan karolar (deniz, il dışı) deniz rengiyle doldurulur.
final class OfflineTopoOverlay: MKTileOverlay {
    private let packs: [TilePack]
    private let minPackZoom: Int
    private let maxPackZoom: Int
    private let cache = NSCache<NSString, NSData>()
    /// En çok bu kadar seviye büyütülür (2^6 = 64 kat; 256 px karonun 4 pikseli).
    private static let maxUpscale = 6

    init(packs: [TilePack] = OfflineBasemap.loadPacks()) {
        self.packs = packs
        minPackZoom = packs.map(\.minZoom).min() ?? 0
        maxPackZoom = packs.map(\.maxZoom).max() ?? 0
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = BaseLayer.offlineTopo.maxZoom
        cache.countLimit = 256
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        result(tile(at: path), nil)
    }

    private func tile(at path: MKTileOverlayPath) -> Data {
        guard !packs.isEmpty, path.z >= minPackZoom else { return TileImage.empty }
        var z = min(path.z, maxPackZoom)
        while z >= minPackZoom, path.z - z <= Self.maxUpscale {
            let dz = path.z - z
            for pack in packs where z >= pack.minZoom && z <= pack.maxZoom {
                guard let data = pack.tile(z: z, x: path.x >> dz, y: path.y >> dz) else { continue }
                if dz == 0 { return data }
                let key = "\(path.z)/\(path.x)/\(path.y)@\(path.contentScaleFactor)" as NSString
                if let cached = cache.object(forKey: key) { return cached as Data }
                guard let png = TileImage.upscale(data, dz: dz, x: path.x, y: path.y,
                                                  size: tileSize, scale: path.contentScaleFactor) else { return TileImage.empty }
                cache.setObject(png as NSData, forKey: key)
                return png
            }
            z -= 1
        }
        return TileImage.sea
    }
}
