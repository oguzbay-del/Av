import CoreGraphics
import Foundation

// MARK: - Kuş bulucu (nesne algılama): saf karar mantığı (Core ML/Vision bilmez, birim testli)

/// Bulunan bir kuşun kutusu.
struct BirdBox: Equatable, Sendable {
    /// Asıl görüntüde kutu (0…1, Vision koordinatları: sol alt köken).
    let rect: CGRect
    /// 0…1 kuş puanı (nesne olasılığı × COCO "bird" sınıf olasılığı).
    let score: Double
}

/// Fotoğraftaki kuşlardan biri ve onun tür tahminleri (birden fazla kuş varsa listelenir).
struct DetectedBird: Equatable, Sendable {
    let box: BirdBox
    /// Bu kuşun kırpılmış görüntüsünden en olası türler.
    let predictions: [BirdPrediction]

    /// Sonucu gösterilecek kuş: tür tahmini en emin olan (eşitlikte bulucunun puanı yüksek olan).
    static func primaryIndex(_ birds: [DetectedBird]) -> Int? {
        birds.indices.max { a, b in
            let pa = birds[a].predictions.first?.probability ?? 0, pb = birds[b].predictions.first?.probability ?? 0
            return pa == pb ? birds[a].box.score < birds[b].box.score : pa < pb
        }
    }

    /// Kuşların en olası türleri birbirinden farklı mı ("fotoğrafta birden fazla kuş var" notu için).
    static func differentSpecies(_ birds: [DetectedBird]) -> Bool {
        Set(birds.compactMap { $0.predictions.first?.label }).count > 1
    }
}

/// YOLOX kuş bulucu çıktısının çözümü (tools/kus_bulucu): eşik, koordinat dönüşümü, örtüşme bastırma
/// ve tür modeli için kırpma bölgesi.
///
/// Model girdisi `inputSize`×`inputSize` karedir: görüntü en-boy oranı korunarak sol üst köşeye ölçeklenir,
/// kalan alan griyle doldurulur ("letterbox"). Çıktı kutuları (cx, cy, w, h) bu kareye göre 0…1'dir.
enum DetectionDecoder {
    static let inputSize = 640
    /// Letterbox dolgusu (YOLOX eğitimindeki gri, 0–255).
    static let padValue = 114
    /// Bu puanın altındaki kutular kuş sayılmaz.
    static let defaultThreshold = 0.3
    /// Bundan çok örtüşen kutulardan yalnızca puanı yüksek olan kalır.
    static let iouLimit = 0.45
    /// Tür modeline verilecek en çok kuş.
    static let maxBirds = 3
    /// Kırpma payı: kutunun uzun kenarının her yana bu oranı kadar eklenir (tür modeli bağlam görsün).
    static let padding = 0.15
    /// Kuş kadrajın bu kadarını kaplıyorsa kırpılmaz (tam görüntü yeterli).
    static let fullFrameArea = 0.6

    /// Letterbox ölçeği ve ölçeklenmiş görüntünün boyutu (piksel).
    static func letterbox(width: Int, height: Int, inputSize: Int = inputSize) -> (scale: Double, width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0, 0) }
        let r = min(Double(inputSize) / Double(width), Double(inputSize) / Double(height))
        return (r, max(1, Int((Double(width) * r).rounded())), max(1, Int((Double(height) * r).rounded())))
    }

    /// Ham çıktı → asıl görüntüde kuş kutuları (puana göre, en çok `limit`).
    /// - Parameters:
    ///   - boxes: düz dizi [cx, cy, w, h, cx, cy, …] (girdi karesine göre 0…1)
    ///   - scores: kutu başına kuş puanı
    static func decode(boxes: [Float], scores: [Float], imageWidth: Int, imageHeight: Int,
                       inputSize: Int = inputSize, threshold: Double = defaultThreshold,
                       iouLimit: Double = iouLimit, limit: Int = maxBirds) -> [BirdBox] {
        let lb = letterbox(width: imageWidth, height: imageHeight, inputSize: inputSize)
        guard lb.scale > 0, limit > 0 else { return [] }
        // Girdi karesindeki 0…1 → asıl görüntüde 0…1
        let sx = Double(inputSize) / (lb.scale * Double(imageWidth))
        let sy = Double(inputSize) / (lb.scale * Double(imageHeight))
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var candidates: [BirdBox] = []
        for i in 0..<min(scores.count, boxes.count / 4) {
            let s = Double(scores[i])
            guard s.isFinite, s >= threshold else { continue }
            let cx = Double(boxes[4 * i]), cy = Double(boxes[4 * i + 1])
            let w = Double(boxes[4 * i + 2]), h = Double(boxes[4 * i + 3])
            guard [cx, cy, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { continue }
            let top = (cy - h / 2) * sy, bottom = (cy + h / 2) * sy
            let rect = CGRect(x: (cx - w / 2) * sx, y: 1 - bottom, width: w * sx, height: bottom - top).intersection(unit)
            guard !rect.isNull, rect.width > 0.002, rect.height > 0.002 else { continue }
            candidates.append(BirdBox(rect: rect, score: s))
        }
        return suppress(candidates, iouLimit: iouLimit, limit: limit)
    }

    /// Açgözlü örtüşme bastırma (NMS): puana göre sırala, öncekilerle çok örtüşeni at.
    static func suppress(_ boxes: [BirdBox], iouLimit: Double = iouLimit, limit: Int = maxBirds) -> [BirdBox] {
        var kept: [BirdBox] = []
        for b in boxes.sorted(by: { $0.score > $1.score }) {
            if kept.count >= limit { break }
            if kept.allSatisfy({ iou($0.rect, b.rect) <= iouLimit }) { kept.append(b) }
        }
        return kept
    }

    /// Kesişim / birleşim.
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = Double(inter.width * inter.height)
        let u = Double(a.width * a.height + b.width * b.height) - i
        return u > 0 ? i / u : 0
    }

    /// Tür modeli için kırpma bölgesi (0…1, Vision koordinatları): kutunun çevresinde pikselde kare bölge,
    /// her yana `padding` pay; kenara taşarsa içeri kaydırılır. Kuş kadrajın çoğunu kaplıyorsa nil (kırpma yok).
    static func cropRect(for box: CGRect, imageWidth: Int, imageHeight: Int, padding: Double = padding) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0, box.width > 0, box.height > 0,
              Double(box.width * box.height) < fullFrameArea else { return nil }
        let w = Double(imageWidth), h = Double(imageHeight)
        let bw = Double(box.width) * w, bh = Double(box.height) * h
        // Pikselde kare; görüntüden büyük olamaz
        let side = max(bw, bh) * (1 + 2 * padding)
        let cw = min(side, w), ch = min(side, h)
        let cx = Double(box.midX) * w, cy = Double(box.midY) * h
        let x = min(max(0, cx - cw / 2), w - cw)
        let y = min(max(0, cy - ch / 2), h - ch)
        let r = CGRect(x: x / w, y: y / h, width: cw / w, height: ch / h)
        return r.width >= 0.999 && r.height >= 0.999 ? nil : r
    }
}
