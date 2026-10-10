import Foundation

// MARK: - Çevrimiçi kuş tanıma (yedek): alan katmanı
// Cihazdaki model emin olmadığında fotoğraf (BioCLIP 2) ya da ses kaydı (Perch v2) Hugging Face
// Space'teki sunucuya gönderilir. Konum hiçbir zaman gönderilmez. Bu katman ağ ve UIKit bilmez.

/// Çevrimiçi tanımanın tek ayar yeri.
enum OnlineBirdID {
    /// Sunucunun kök adresi (Hugging Face Space "Oguzbayrakdar/av-haritasi-kus"; alt alan adı küçük harf,
    /// sonda "/" yok). nil yapılırsa özellik tamamen kapanır: istek yapılmaz, arayüzde hiçbir şey değişmez.
    static let baseURL: URL? = URL(string: "https://oguzbayrakdar-av-haritasi-kus.hf.space")

    /// Ayarlar › "Belirsiz sonuçlarda çevrimiçi kontrol" (@AppStorage anahtarı).
    static let settingKey = "onlineBirdCheck"
    static let defaultEnabled = true

    /// Cihazdaki en yüksek olasılık bunun altındaysa sonuç "belirsiz" sayılır.
    static let uncertainBelow = 0.5
    /// Bu kadar saniye sonra hâlâ yanıt yoksa "model uyanıyor" yazısı gösterilir (ücretsiz Space uykudan kalkar).
    static let slowNoticeAfter: TimeInterval = 8
    /// İstek zaman aşımı: uyuyan Space'in ilk yanıtı 30–120 sn sürebilir.
    static let timeout: TimeInterval = 120
    /// Gösterilen çevrimiçi tahmin sayısı.
    static let maxResults = 3

    /// Sunucu sınırları.
    static let maxUploadBytes = 10 * 1024 * 1024
    static let photoMaxSide = 1024.0
    static let photoJPEGQuality = 0.85
    static let soundSampleRate = 32_000
    static let soundMaxSeconds = 30.0
    static let soundMinSeconds = 5.0

    /// Özellik yapılandırılmış mı (adres var mı).
    static var isConfigured: Bool { baseURL != nil }

    /// Kullanıcı ayarı (varsayılan açık).
    static var isEnabledSetting: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? defaultEnabled
    }

    enum Kind: Sendable, Equatable {
        case photo, sound

        /// Sunucudaki uç nokta.
        var path: String {
            switch self {
            case .photo: return "foto"
            case .sound: return "ses"
            }
        }

        /// Arayüzde gösterilen model adı.
        var modelName: String {
            switch self {
            case .photo: return "BioCLIP 2"
            case .sound: return "Perch v2"
            }
        }

        var fileName: String {
            switch self {
            case .photo: return "kus.jpg"
            case .sound: return "kus.wav"
            }
        }

        var mimeType: String {
            switch self {
            case .photo: return "image/jpeg"
            case .sound: return "audio/wav"
            }
        }
    }
}

/// Çevrimiçi kontrol kararı (yan etkisiz, birim testli).
enum OnlineCheckPolicy {
    enum Decision: Equatable, Sendable {
        /// Gerek yok ya da özellik kapalı: arayüzde hiçbir şey gösterilmez.
        case skip
        /// Kontrol gerekirdi ama internet yok.
        case offline
        /// Sunucuya sor.
        case check
    }

    /// - Parameters:
    ///   - topProbability: cihazdaki en olası türün olasılığı (sonuç yoksa nil).
    ///   - onlyGeneral: cihazda yalnızca genel (tür düzeyinde olmayan) sınıflandırıcı sonuç verdi.
    static func decide(settingEnabled: Bool, configured: Bool, online: Bool,
                       topProbability: Double?, onlyGeneral: Bool) -> Decision {
        guard settingEnabled, configured else { return .skip }
        let uncertain = onlyGeneral || (topProbability ?? 0) < OnlineBirdID.uncertainBelow
        guard uncertain else { return .skip }
        return online ? .check : .offline
    }
}

/// Sunucu yanıtı: {"model": "bioclip-2", "sonuclar": [{"sci", "en", "tr", "p"}], "sure_ms": 1234}.
struct OnlineBirdIDResponse: Decodable, Equatable, Sendable {
    struct Result: Decodable, Equatable, Sendable {
        let sci: String
        let en: String
        let tr: String
        let p: Double
    }

    let model: String
    let sonuclar: [Result]
    let sureMs: Int?

    enum CodingKeys: String, CodingKey {
        case model, sonuclar
        case sureMs = "sure_ms"
    }
}

/// Hata yanıtı (4xx/5xx): {"hata": "..."}.
struct OnlineBirdIDErrorBody: Decodable, Equatable, Sendable {
    let hata: String
}

enum OnlineBirdIDError: Error, Equatable {
    case notConfigured
    /// Gönderilecek veri hazırlanamadı ya da sınırı aşıyor.
    case badPayload
    /// Sunucu hata gövdesiyle yanıt verdi.
    case server(status: Int, message: String)
    case http(status: Int)
    case badResponse
}

extension OnlineBirdIDResponse {
    /// HTTP yanıtını çözümler: 2xx → sonuç; diğerleri → `OnlineBirdIDError`.
    static func decode(data: Data, status: Int) throws -> OnlineBirdIDResponse {
        guard (200..<300).contains(status) else {
            if let body = try? JSONDecoder().decode(OnlineBirdIDErrorBody.self, from: data) {
                throw OnlineBirdIDError.server(status: status, message: body.hata)
            }
            throw OnlineBirdIDError.http(status: status)
        }
        do {
            return try JSONDecoder().decode(OnlineBirdIDResponse.self, from: data)
        } catch {
            throw OnlineBirdIDError.badResponse
        }
    }

    /// Gösterilecek tahminler: olasılığa göre sıralı, en çok `limit`; ad dile göre (Türkçede `tr`).
    func predictions(limit: Int = OnlineBirdID.maxResults, english: Bool = AppLocale.isEnglish) -> [BirdPrediction] {
        sonuclar
            .filter { !$0.sci.isEmpty && $0.p.isFinite }
            .sorted { $0.p > $1.p }
            .prefix(limit)
            .map { r in
                let tr = r.tr.trimmingCharacters(in: .whitespaces)
                let en = r.en.trimmingCharacters(in: .whitespaces)
                let name = english ? (en.isEmpty ? r.sci : en) : (tr.isEmpty ? (en.isEmpty ? r.sci : en) : tr)
                return BirdPrediction(label: r.sci, scientificName: r.sci, commonName: name,
                                      probability: min(1, max(0, r.p)), source: .onlineModel)
            }
    }
}
