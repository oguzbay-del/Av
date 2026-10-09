import CoreGraphics
import ImageIO
import UIKit

/// Görüntü hazırlama: büyük fotoğrafları belleği zorlamadan küçültür ve dik (.up) yöne çevirir.
/// Modeller 224–384 piksellik girdi ister; 1 600 px kırpma için yeterli ayrıntıyı korur.
enum BirdImageLoader {
    static let maxPixelSize = 1_600

    /// Fotoğraf verisinden (JPEG/HEIC/PNG) küçültülmüş, EXIF yönü uygulanmış görüntü.
    static func downsample(_ data: Data, maxPixelSize: Int = maxPixelSize) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw BirdIdentificationError.invalidImage
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF yönünü uygula → dik görüntü
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw BirdIdentificationError.invalidImage
        }
        return image
    }

    /// UIImage → dik CGImage (gerekirse yeniden çizilir ve küçültülür).
    static func upright(_ image: UIImage, maxPixelSize: Int = maxPixelSize) throws -> CGImage {
        let pixelW = image.size.width * image.scale, pixelH = image.size.height * image.scale
        guard pixelW > 0, pixelH > 0 else { throw BirdIdentificationError.invalidImage }
        if image.imageOrientation == .up, let cg = image.cgImage, max(cg.width, cg.height) <= maxPixelSize {
            return cg
        }
        let scale = min(1, CGFloat(maxPixelSize) / max(pixelW, pixelH))
        let size = CGSize(width: (pixelW * scale).rounded(), height: (pixelH * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = rendered.cgImage else { throw BirdIdentificationError.invalidImage }
        return cg
    }
}
