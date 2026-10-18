#if DEBUG
import CoreGraphics
import UIKit

/// Yalnızca DEBUG derlemesi: App Store ekran görüntüleri için hazır kuş tanıma sonuçları (`-kusDemo foto|video`).
/// Simülatörde kamera ve galeri seçimi olmadığından örnek görüntü (tools/ekran_demo, CC0) uygulamanın
/// `Documents/ekran_demo/` klasörüne kopyalanır; kutular o görüntüdeki kuşlara göre elle ölçülmüştür.
enum ScreenshotBirdDemo {
    private static func image(_ name: String) -> UIImage? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = dir?.appendingPathComponent("ekran_demo/\(name)") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private static func prediction(_ label: String, _ p: Double) -> BirdPrediction {
        let parsed = BirdLabel.parse(label)
        return BirdPrediction(label: label, scientificName: parsed.scientific, commonName: parsed.common,
                              probability: p, source: .speciesModel)
    }

    /// Fotoğraf: kıyıda yeşilbaş (sarı çerçeve, 1) ve sutavuğu (2) — iki farklı tür.
    @MainActor
    static func applyPhoto(to service: BirdIdentifierService) {
        guard let img = image("kus_foto.jpg") else { return }
        let mallard = CGRect(x: 0.232, y: 0.087, width: 0.296, height: 0.433)
        let moorhen = CGRect(x: 0.332, y: 0.561, width: 0.156, height: 0.25)
        let duck = [prediction("Anas platyrhynchos_Mallard", 0.93),
                    prediction("Mareca strepera_Gadwall", 0.03),
                    prediction("Anas acuta_Northern Pintail", 0.01)]
        let birds = [DetectedBird(box: BirdBox(rect: mallard, score: 0.91), predictions: duck),
                     DetectedBird(box: BirdBox(rect: moorhen, score: 0.84),
                                  predictions: [prediction("Gallinula chloropus_Eurasian Moorhen", 0.88)])]
        let result = BirdIdentificationResult(predictions: duck, focusRect: mallard, birdPresence: 0.97,
                                              usedFallback: false, birds: birds)
        service.showDemo(image: img, result: result)
    }

    /// Video: 47 sn'lik videoda 0:18–0:28 bölümü; görüntü ve ses alakargada birleşir.
    @MainActor
    static func applyVideo(to video: BirdVideoService) {
        guard let img = image("kus_video_kare.jpg") else { return }
        let image = [prediction("Garrulus glandarius_Eurasian Jay", 0.84),
                     prediction("Pica pica_Eurasian Magpie", 0.05),
                     prediction("Turdus merula_Eurasian Blackbird", 0.02)]
        let sound = [BirdDetection(scientificName: "Garrulus glandarius", commonName: "Eurasian Jay", confidence: 0.79,
                                   start: 21, end: 24, source: .onDevice),
                     BirdDetection(scientificName: "Pica pica", commonName: "Eurasian Magpie", confidence: 0.14,
                                   start: 24, end: 27, source: .onDevice)]
        // Tarama puanları (saniyede bir kare): kuş 0:17 civarında kadraja girip 0:29'da çıkıyor
        let timeline: [Double] = (0..<47).map { t in
            let x = Double(t)
            let bird = (17...29).contains(t) ? 0.75 + 0.2 * sin(x * 0.9) : 0
            return max(0.06 + 0.05 * abs(sin(x * 1.7)), bird)
        }
        video.showDemo(duration: 47, timeline: timeline, windowStart: 18, preview: img,
                       focusRect: CGRect(x: 0.325, y: 0.102, width: 0.432, height: 0.8),
                       fusion: VideoFusion.fuse(image: image, sound: sound))
    }
}
#endif
