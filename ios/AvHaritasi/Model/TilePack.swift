import Foundation
import MapKit
import UIKit

/// `tools/generate_assets.py` tarafından üretilen tek dosyalık karo paketi.
///
/// Biçim (little endian): "AVTP" | u32 sürüm | u32 adet |
/// adet x (u8 z, 3 bayt boşluk, u32 x, u32 y, u64 ofset, u32 uzunluk) | PNG verileri
final class TilePack: @unchecked Sendable {
    let minZoom: Int
    let maxZoom: Int
    private let data: Data
    private let index: [UInt64: Range<Int>]

    init(url: URL, minZoom: Int, maxZoom: Int) throws {
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 12, data.prefix(4) == Data("AVTP".utf8) else { throw HuntingMapError.badZoneData }

        var index: [UInt64: Range<Int>] = [:]
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let count = Int(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            guard 12 + count * 24 <= buf.count else { throw HuntingMapError.badZoneData }
            index.reserveCapacity(count)
            for i in 0..<count {
                let base = 12 + i * 24
                let z = Int(buf[base])
                let x = Int(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self)))
                let y = Int(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)))
                let off = Int(UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: base + 12, as: UInt64.self)))
                let len = Int(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: base + 20, as: UInt32.self)))
                guard off >= 0, len >= 0, off + len <= buf.count else { throw HuntingMapError.badZoneData }
                index[Self.key(z, x, y)] = off..<(off + len)
            }
        }
        self.data = data
        self.index = index
    }

    private static func key(_ z: Int, _ x: Int, _ y: Int) -> UInt64 {
        UInt64(z) << 56 | UInt64(x) << 28 | UInt64(y)
    }

    func tile(z: Int, x: Int, y: Int) -> Data? {
        guard let r = index[Self.key(z, x, y)] else { return nil }
        return data.subdata(in: r)
    }
}

/// Paketteki karoları MapKit'e veren katman. Paketin en yüksek yakınlaştırma
/// seviyesinden sonrası için üst karoyu kırpıp büyütür.
final class PackTileOverlay: MKTileOverlay {
    private let pack: TilePack
    private let cache = NSCache<NSString, NSData>()

    private static let emptyTile: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).pngData { _ in }
    }()

    init(pack: TilePack) {
        self.pack = pack
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = pack.minZoom
        maximumZ = pack.maxZoom + 6
        cache.countLimit = 256
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        if path.z <= pack.maxZoom {
            result(pack.tile(z: path.z, x: path.x, y: path.y) ?? Self.emptyTile, nil)
            return
        }

        let cacheKey = "\(path.z)/\(path.x)/\(path.y)@\(path.contentScaleFactor)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            result(cached as Data, nil)
            return
        }

        let dz = path.z - pack.maxZoom
        let px = path.x >> dz, py = path.y >> dz
        guard let parentData = pack.tile(z: pack.maxZoom, x: px, y: py),
              let parent = UIImage(data: parentData)?.cgImage else {
            result(Self.emptyTile, nil)
            return
        }
        let n = 1 << dz
        let sub = CGFloat(parent.width) / CGFloat(n)
        let rect = CGRect(x: CGFloat(path.x - (px << dz)) * sub,
                          y: CGFloat(path.y - (py << dz)) * sub,
                          width: sub, height: sub).integral
        guard let crop = parent.cropping(to: rect) else {
            result(Self.emptyTile, nil)
            return
        }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = path.contentScaleFactor
        let size = tileSize
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            ctx.cgContext.interpolationQuality = .medium
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
        }
        cache.setObject(png as NSData, forKey: cacheKey)
        result(png, nil)
    }
}
