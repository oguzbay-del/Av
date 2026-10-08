import CoreGraphics
import Foundation
import ImageIO

// MARK: - Fotoğraftan kuş tanıma: alan (domain) katmanı
// Bu katman Vision/CoreML/UIKit bilmez; sunum katmanı yalnızca bu tiplere bağlıdır.

/// Bir tür tahmini.
struct BirdPrediction: Identifiable, Equatable, Sendable {
    var id: String { label }
    /// Modelin ham sınıf etiketi (ör. "Anas platyrhynchos_Mallard").
    let label: String
    /// Etiketten çıkarılan bilimsel ad (MAK yasal durum eşleşmesi için).
    let scientificName: String?
    /// Gösterilecek ad.
    let commonName: String
    /// 0…1 olasılık.
    let probability: Double
    let source: Source

    enum Source: Sendable {
        /// Özel tür modeli (BirdClassifier.mlmodel).
        case speciesModel
        /// Apple'ın yerleşik sınıflandırıcısı: tür değil grup (ördek, baykuş, kartal...).
        case generalModel
    }
}

/// Analiz sonucu: tahminler ve analiz edilen bölge.
struct BirdIdentificationResult: Equatable, Sendable {
    let predictions: [BirdPrediction]
    /// Kuşun bulunduğu tahmin edilen bölge (0…1, Vision koordinatları: sol alt köken); kırpılmadıysa nil.
    let focusRect: CGRect?
    /// Fotoğrafta kuş bulunduğuna dair yerleşik sınıflandırıcının güveni (bilinmiyorsa nil).
    let birdPresence: Double?
    /// Özel tür modeli bulunamadı; yalnızca genel sınıflandırma yapıldı.
    let usedFallback: Bool
}

/// Hatalar: her biri kullanıcıya gösterilebilir bir açıklama taşır.
enum BirdIdentificationError: LocalizedError, Equatable {
    case imageLoadFailed
    case invalidImage
    case modelLoadFailed(String)
    case classificationFailed(String)
    case noBirdDetected
    case noResults
    case cancelled

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed: return L("Fotoğraf yüklenemedi.")
        case .invalidImage: return L("Fotoğraf okunamadı ya da biçimi desteklenmiyor.")
        case .modelLoadFailed(let m): return L("Tanıma modeli açılamadı: %@", m)
        case .classificationFailed(let m): return L("Analiz başarısız: %@", m)
        case .noBirdDetected: return L("Fotoğrafta kuş bulunamadı. Kuşu daha yakından ya da kadrajın ortasında çekin.")
        case .noResults: return L("Tür tahmini yapılamadı. Daha net bir fotoğraf deneyin.")
        case .cancelled: return L("Analiz iptal edildi.")
        }
    }
}

/// Sınıflandırıcı sözleşmesi (bağımlılığın tersine çevrilmesi: sunum katmanı somut sınıfı bilmez,
/// testte sahte sınıflandırıcı verilebilir).
protocol BirdImageClassifying: Sendable {
    func classify(_ image: CGImage, orientation: CGImagePropertyOrientation, maxResults: Int) async throws -> BirdIdentificationResult
}

/// Model sınıf etiketlerinin ayrıştırılması. Desteklenen biçimler:
/// - "Anas platyrhynchos_Mallard" (BirdNET/eğitim betiği biçimi)
/// - "Mallard (Anas platyrhynchos)"
/// - "Anas platyrhynchos" ya da yalnızca ad
enum BirdLabel {
    static func parse(_ raw: String) -> (scientific: String?, common: String) {
        let label = raw.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        if let i = label.firstIndex(of: "_") {
            let sci = String(label[..<i]).trimmingCharacters(in: .whitespaces)
            let common = String(label[label.index(after: i)...]).replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return (looksScientific(sci) ? sci : nil, common.isEmpty ? sci : common)
        }
        if let open = label.lastIndex(of: "("), label.hasSuffix(")") {
            let sci = String(label[label.index(after: open)..<label.index(before: label.endIndex)])
            let common = String(label[..<open]).trimmingCharacters(in: .whitespaces)
            return (looksScientific(sci) ? sci : nil, common)
        }
        return (looksScientific(label) ? label : nil, label)
    }

    /// "Cins tür" biçimi: iki kelime, ilki büyük harfle, ikincisi küçük harfle başlar.
    static func looksScientific(_ s: String) -> Bool {
        let parts = s.split(separator: " ")
        guard parts.count == 2, let a = parts[0].first, let b = parts[1].first else { return false }
        return a.isUppercase && b.isLowercase
    }
}
