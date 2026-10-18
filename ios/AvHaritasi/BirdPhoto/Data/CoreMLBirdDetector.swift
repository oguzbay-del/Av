import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import os

/// Kuş bulucu (tamamen cihazda): YOLOX-S (Megvii, Apache-2.0; COCO "bird" sınıfı) fotoğraftaki kuşların
/// kutularını verir; tür modeli bu kutulardan kırpılan görüntüde çalışır. Dönüştürme: tools/kus_bulucu.
///
/// Model çalışma anında paketten yüklenir; `BirdDetector.mlpackage` yoksa ya da açılamazsa `detect` nil
/// döner ve sınıflandırıcı eski belirgin nesne (saliency) kırpmasına düşer. Çıktının çözümü
/// (eşik, koordinat, örtüşme bastırma) saf ve birim testli `DetectionDecoder`'dadır.
///
/// `detect` bloklayan bir çağrıdır; ana iş parçacığında değil, arka plan kuyruğunda çağrılmalıdır.
/// Ad, Xcode'un modelden ürettiği `BirdDetector` sınıfıyla çakışmasın diye farklıdır.
final class CoreMLBirdDetector: @unchecked Sendable {
    static let modelName = "BirdDetector"
    static let shared = CoreMLBirdDetector()

    private enum ModelState {
        case notLoaded
        case loaded(MLModel)
        case missing
    }

    private let bundle: Bundle
    private let lock = NSLock()
    private var state: ModelState = .notLoaded
    private let log = Logger(subsystem: "AvHaritasi", category: "kusbulucu")

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Model yüklenebiliyor mu (ilk çağrıda yükler).
    var isAvailable: Bool { model() != nil }

    /// Görüntüdeki kuşlar (puana göre, en çok `limit`). Model yoksa ya da çalışmazsa nil; kuş yoksa boş dizi.
    func detect(_ image: CGImage, threshold: Double = DetectionDecoder.defaultThreshold,
                limit: Int = DetectionDecoder.maxBirds) -> [BirdBox]? {
        guard let model = model() else { return nil }
        let side = DetectionDecoder.inputSize
        guard let buffer = Self.letterbox(image, side: side) else { return nil }
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
            let out = try model.prediction(from: input)
            guard let boxes = out.featureValue(for: "boxes")?.multiArrayValue,
                  let scores = out.featureValue(for: "scores")?.multiArrayValue else { return nil }
            return DetectionDecoder.decode(boxes: Self.values(boxes), scores: Self.values(scores),
                                           imageWidth: image.width, imageHeight: image.height, inputSize: side,
                                           threshold: threshold, limit: limit)
        } catch {
            log.error("Kuş bulucu çalışmadı: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func model() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .loaded(let m): return m
        case .missing: return nil
        case .notLoaded:
            // Xcode .mlpackage'ı derleyip pakete .mlmodelc olarak koyar
            guard let url = bundle.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
                log.info("BirdDetector.mlmodelc yok; belirgin nesne kırpması kullanılacak")
                state = .missing
                return nil
            }
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let m = try MLModel(contentsOf: url, configuration: config)
                state = .loaded(m)
                return m
            } catch {
                log.error("Kuş bulucu açılamadı: \(error.localizedDescription, privacy: .public)")
                state = .missing
                return nil
            }
        }
    }

    /// Görüntü → `side`×`side` BGRA piksel arabelleği: en-boy oranı korunarak sol üst köşeye ölçeklenir,
    /// kalan alan YOLOX'un gri dolgusuyla (114) doldurulur.
    static func letterbox(_ image: CGImage, side: Int) -> CVPixelBuffer? {
        let lb = DetectionDecoder.letterbox(width: image.width, height: image.height, inputSize: side)
        guard lb.scale > 0 else { return nil }
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        let gray = CGFloat(DetectionDecoder.padValue) / 255
        ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        // CGContext kökeni sol alttadır: görüntünün üst kenarı arabelleğin ilk satırına gelsin
        ctx.draw(image, in: CGRect(x: 0, y: side - lb.height, width: lb.width, height: lb.height))
        return buffer
    }

    /// MLMultiArray → satır sıralı Float dizisi (adımlar/strides dikkate alınır; çıktı küçük: 500 değer).
    static func values(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let count = shape.reduce(1, *)
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        var index = [Int](repeating: 0, count: shape.count)
        for k in 0..<count {
            out[k] = array[index.map { NSNumber(value: $0) }].floatValue
            // Sonraki çok boyutlu sıra
            var d = shape.count - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < shape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return out
    }
}
