@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Videodan kare ve ses okuma (tamamen cihazda). Karar mantığı `VideoWindowSelector` ve
/// `FrameAggregator`'dadır; burada yalnızca AVFoundation/Vision işi vardır.
final class BirdVideoReader: @unchecked Sendable {
    let url: URL
    private let asset: AVURLAsset
    /// Tarama için küçük, sınıflandırma için büyük kare üreticisi (AVAssetImageGenerator iş parçacığı güvenlidir).
    private let scanGenerator: AVAssetImageGenerator
    private let frameGenerator: AVAssetImageGenerator

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        scanGenerator = Self.generator(asset, maxSide: 480)
        frameGenerator = Self.generator(asset, maxSide: CGFloat(BirdImageLoader.maxPixelSize))
    }

    private static func generator(_ asset: AVAsset, maxSide: CGFloat) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true // dik kare
        g.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
        g.requestedTimeToleranceBefore = tolerance
        g.requestedTimeToleranceAfter = tolerance
        return g
    }

    /// Süre (sn). Görüntü izi yoksa hata.
    func duration() async throws -> Double {
        let (d, tracks) = try await asset.load(.duration, .tracks)
        guard tracks.contains(where: { $0.mediaType == .video }), d.seconds.isFinite, d.seconds > 0 else {
            throw BirdIdentificationError.invalidImage
        }
        return d.seconds
    }

    func frame(at time: Double, large: Bool) async throws -> CGImage {
        let g = large ? frameGenerator : scanGenerator
        return try await g.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// Karenin kalitesi: kuş varlığı (yerleşik sınıflandırıcının kuş güveni ile kuş bulucunun en iyi kutu
    /// puanının büyüğü; bulucu yoksa yalnızca ilki) ve küçültülmüş gri görüntüde keskinlik.
    static func quality(_ image: CGImage, time: Double, detector: CoreMLBirdDetector = .shared) -> FrameQuality {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let detected = detector.detect(image, limit: 1)?.first?.score ?? 0
        let presence = max(CoreMLBirdClassifier.birdPresence(request.results ?? []), detected)
        let (gray, w, h) = grayscale(image, maxSide: 256)
        return FrameQuality(time: time, presence: presence, sharpness: Sharpness.laplacianVariance(gray, width: w, height: h))
    }

    static func grayscale(_ image: CGImage, maxSide: Int) -> ([UInt8], Int, Int) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : ([], 0, 0)
    }

    /// Bölümün ses izi → 48 kHz mono Float32 (BirdNET girdisi). Ses izi yoksa boş dizi.
    func audioSamples(start: Double, length: Double) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: BirdNETOnDevice.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else {
            throw BirdNETOnDevice.Failure.audio(reader.error?.localizedDescription ?? L("ses biçimi çevrilemedi"))
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(length * BirdNETOnDevice.sampleRate))
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes >= MemoryLayout<Float>.size else { continue }
            var chunk = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
            if status == kCMBlockBufferNoErr { samples += chunk }
        }
        if reader.status == .failed {
            throw BirdNETOnDevice.Failure.audio(reader.error?.localizedDescription ?? L("ses biçimi çevrilemedi"))
        }
        return samples
    }
}
