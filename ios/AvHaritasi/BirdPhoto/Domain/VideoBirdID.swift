import Foundation

// MARK: - Videodan kuş tanıma: saf karar mantığı (AVFoundation/Vision bilmez, birim testli)

/// Bir video karesinin kalitesi: kuş varlığı (Apple Vision "bird" güveni ya da kuş bulucu puanı) ve keskinlik (Laplace varyansı).
struct FrameQuality: Equatable, Sendable {
    /// Videodaki zaman (sn).
    let time: Double
    /// 0…1 kuş varlığı.
    let presence: Double
    /// Laplace varyansı (ölçeksiz; yalnızca aynı videonun kareleri arasında karşılaştırılır).
    let sharpness: Double
}

/// En iyi 10 sn'lik bölümün seçimi.
enum VideoWindowSelector {
    static let window = 10.0
    /// Bundan uzun videoların yalnızca başı taranır (5 dk).
    static let maxDuration = 300.0
    /// Tarama sıklığı (kare/sn) ve bölüm içi örnekleme sıklığı.
    static let scanFPS = 1.0
    static let windowFPS = 2.0

    /// Karelerin 0…1 puanı: kuş varlığı ağırlıklı, keskinlik (videonun en keskin karesine göre) çarpanı.
    /// Vision hiç kuş görmese de keskin bölüm seçilebilsin diye varlığa küçük bir taban eklenir.
    static func scores(_ frames: [FrameQuality]) -> [Double] {
        let maxSharp = frames.map(\.sharpness).max() ?? 0
        return frames.map { f in
            let sharp = maxSharp > 0 ? max(0, f.sharpness) / maxSharp : 1
            return (0.1 + 0.9 * max(0, min(1, f.presence))) * (0.3 + 0.7 * sharp)
        }
    }

    /// İncelenecek süre (en çok `maxDuration`).
    static func scanDuration(_ duration: Double) -> Double {
        max(0, min(duration, maxDuration))
    }

    /// Başlangıcı [0, süre − pencere] aralığına sıkıştırır (kısa videoda 0).
    static func clamp(start: Double, duration: Double, window: Double = window) -> Double {
        max(0, min(start, scanDuration(duration) - window))
    }

    /// Tarama zamanları: 0, 1, 2 … sn (süre içinde).
    static func scanTimes(duration: Double, fps: Double = scanFPS) -> [Double] {
        let d = scanDuration(duration)
        guard d > 0, fps > 0 else { return [] }
        return stride(from: 0, to: d, by: 1 / fps).map { $0 }
    }

    /// Kare puanları toplamı en yüksek pencerenin başlangıcı. Adaylar kare zamanlarıdır; eşitlikte erken olan.
    static func bestStart(_ frames: [FrameQuality], duration: Double, window: Double = window) -> Double {
        guard scanDuration(duration) > window, !frames.isEmpty else { return 0 }
        let s = scores(frames)
        var best = 0.0, bestScore = -1.0
        let starts = Set(frames.map { clamp(start: $0.time, duration: duration, window: window) } + [0]).sorted()
        for start in starts {
            let total = zip(frames, s).filter { $0.0.time >= start && $0.0.time < start + window }.map(\.1).reduce(0, +)
            if total > bestScore + 1e-9 {
                best = start
                bestScore = total
            }
        }
        return best
    }

    /// Bölüm içinde örnek kare zamanları (`windowFPS`, kare ortalarında).
    static func sampleTimes(start: Double, duration: Double, window: Double = window, fps: Double = windowFPS) -> [Double] {
        let s = clamp(start: start, duration: duration, window: window)
        let end = min(scanDuration(duration), s + window)
        guard end > s, fps > 0 else { return [] }
        let step = 1 / fps
        return stride(from: s + step / 2, to: end, by: step).map { $0 }
    }

    /// Sınıflandırılacak kareler: puanı en yüksek `count` kare (zamana göre sıralı).
    static func bestFrames(_ frames: [FrameQuality], count: Int = 6) -> [(frame: FrameQuality, score: Double)] {
        zip(frames, scores(frames)).sorted { $0.1 > $1.1 }.prefix(count)
            .sorted { $0.0.time < $1.0.time }
            .map { (frame: $0.0, score: $0.1) }
    }
}

/// Keskinlik ölçüsü: gri görüntünün 4-komşu Laplace yanıtının varyansı (bulanık karede düşük).
enum Sharpness {
    static func laplacianVariance(_ gray: [UInt8], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, gray.count >= width * height else { return 0 }
        var sum = 0.0, sumSq = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let v = 4 * Double(gray[i]) - Double(gray[i - 1]) - Double(gray[i + 1])
                    - Double(gray[i - width]) - Double(gray[i + width])
                sum += v
                sumSq += v * v
            }
        }
        let n = Double((width - 2) * (height - 2))
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }
}

/// Karelerin tahminlerini birleştirir: kare kalitesiyle ağırlıklı olasılık ortalaması
/// (karede çıkmayan türün o karedeki olasılığı 0 sayılır).
enum FrameAggregator {
    static func aggregate(_ frames: [(predictions: [BirdPrediction], weight: Double)], maxResults: Int = 3) -> [BirdPrediction] {
        let used = frames.filter { !$0.predictions.isEmpty }
        guard !used.isEmpty else { return [] }
        let weights = used.map { max(0, $0.weight) }
        let total = weights.reduce(0, +)
        let w = total > 0 ? weights.map { $0 / total } : Array(repeating: 1 / Double(used.count), count: used.count)
        var sums: [String: Double] = [:]
        var sample: [String: BirdPrediction] = [:]
        for (frame, wi) in zip(used, w) {
            for p in frame.predictions {
                sums[p.label, default: 0] += wi * p.probability
                if sample[p.label] == nil { sample[p.label] = p }
            }
        }
        return sums.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(maxResults)
            .compactMap { label, prob in
                guard let p = sample[label] else { return nil }
                return BirdPrediction(label: p.label, scientificName: p.scientificName, commonName: p.commonName,
                                      probability: min(1, prob), source: p.source)
            }
    }
}

/// Görüntü ve ses sonuçlarının birleştirilmesi.
struct VideoFusion: Equatable {
    enum Agreement: Equatable {
        /// İki yol aynı türü gösteriyor: birleşik güven `combined`da.
        case agree
        /// Farklı türler: ikisi ayrı gösterilir.
        case disagree
        /// Yalnızca biri sonuç verdi ya da hiçbiri.
        case single
    }

    let agreement: Agreement
    let combined: BirdPrediction?
    let image: [BirdPrediction]
    let sound: [BirdDetection]

    /// Bağımsız iki kanıtın birleşimi (gürültülü VEYA): 1 − (1 − a)(1 − b); her birinden büyük ya da eşit.
    static func combine(_ a: Double, _ b: Double) -> Double {
        1 - (1 - max(0, min(1, a))) * (1 - max(0, min(1, b)))
    }

    static func fuse(image: [BirdPrediction], sound: [BirdDetection]) -> VideoFusion {
        guard let i = image.first, let s = sound.first else {
            return VideoFusion(agreement: .single, combined: nil, image: image, sound: sound)
        }
        guard let sci = i.scientificName, sci == s.scientificName else {
            return VideoFusion(agreement: .disagree, combined: nil, image: image, sound: sound)
        }
        let c = BirdPrediction(label: i.label, scientificName: sci, commonName: i.commonName,
                               probability: combine(i.probability, s.confidence), source: .videoCombined)
        return VideoFusion(agreement: .agree, combined: c, image: image, sound: sound)
    }
}
