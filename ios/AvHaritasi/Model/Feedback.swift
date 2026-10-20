import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Uygulama içi geri bildirim: saf katman (birim testli)
// Kullanıcının yazdığı bildirim `POST {OnlineBirdID.baseURL}/geribildirim` ile geliştiricinin sunucusuna
// (tools/kus_sunucu/geribildirim.py) gider; sunucu özel bir GitHub deposunda konu açar. Yalnızca kullanıcı
// "Gönder"e dokununca gönderilir. Bu dosya yan etkisizdir; ağ ve disk `FeedbackOutbox`ta.

/// Geri bildirimin tek ayar yeri (sınırlar sunucuyla aynı).
enum Feedback {
    /// Sunucu adresi yoksa özellik görünmez.
    static var endpoint: URL? { OnlineBirdID.baseURL?.appendingPathComponent("geribildirim") }
    static var isConfigured: Bool { endpoint != nil }

    static let maxTextLength = 2000
    static let maxContactLength = 200
    static let maxInfoLength = 40
    /// Çözülmüş JPEG en çok 1,5 MB.
    static let maxImageBytes = 1_572_864
    static let imageMaxSide = 1024.0
    /// Gönderilemeyen en çok bu kadar bildirim cihazda bekler.
    static let maxQueued = 5
    /// Bu kadar günden eski, gönderilemeyen bildirim silinir.
    static let maxQueuedDays = 30
    /// Sunucunun gürültü süzgeci başlığı (güvenlik değildir).
    static let appHeader = "X-Av-Uygulama"
    /// Koordinat 4 ondalığa (~11 m) yuvarlanır ve gönderilmeden önce gösterilir.
    static let coordinateDecimals = 4
}

/// Bildirim türü (ham değer sunucudaki `tur`).
enum FeedbackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case hata, oneri, harita, kus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hata: L("Hata")
        case .oneri: L("Öneri")
        case .harita: L("Harita / alan hatası")
        case .kus: L("Kuş tanıma")
        }
    }

    var systemImage: String {
        switch self {
        case .hata: "ladybug"
        case .oneri: "lightbulb"
        case .harita: "map"
        case .kus: "bird"
        }
    }

    /// Haritadaki nokta yalnızca harita bildirimine eklenebilir.
    var allowsLocation: Bool { self == .harita }
}

/// Sunucuya giden JSON gövdesi (alan adları sunucuyla aynı; nil alanlar yazılmaz).
struct FeedbackPayload: Codable, Equatable, Sendable {
    struct Coordinate: Codable, Equatable, Sendable {
        let lat: Double
        let lon: Double
    }

    let tur: FeedbackKind
    let metin: String
    var iletisim: String?
    var uygulama: String?
    var ios: String?
    var cihaz: String?
    var konum: Coordinate?
    /// base64 JPEG.
    var gorsel: String?

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }
}

/// Uygulama sürümü, iOS sürümü ve cihaz modeli (formda gösterilir, otomatik eklenir).
struct FeedbackDeviceInfo: Equatable, Sendable {
    var app: String
    var os: String
    var model: String

    static var current: FeedbackDeviceInfo {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return FeedbackDeviceInfo(app: build.map { "\(version) (\($0))" } ?? version,
                                  os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                  model: UsageRecorder.deviceModel)
    }
}

enum FeedbackValidationError: Error, Equatable {
    case emptyText, textTooLong, contactTooLong, invalidContact, imageTooLarge

    var message: String {
        switch self {
        case .emptyText: L("Lütfen ne olduğunu kısaca yazın.")
        case .textTooLong: L("Metin en çok %@ karakter olabilir.", String(Feedback.maxTextLength))
        case .contactTooLong: L("E-posta en çok %@ karakter olabilir.", String(Feedback.maxContactLength))
        case .invalidContact: L("E-posta adresi geçerli görünmüyor.")
        case .imageTooLarge: L("Görsel çok büyük.")
        }
    }
}

enum FeedbackBuilder {
    /// Formdaki girdilerden doğrulanmış gövde. Konum yalnızca harita bildiriminde ve 4 ondalığa yuvarlanmış eklenir.
    static func build(kind: FeedbackKind, text: String, contact: String, coordinate: CLLocationCoordinate2D?,
                      image: Data?, info: FeedbackDeviceInfo) -> Result<FeedbackPayload, FeedbackValidationError> {
        let body = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure(.emptyText) }
        guard body.count <= Feedback.maxTextLength else { return .failure(.textTooLong) }
        let mail = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mail.count <= Feedback.maxContactLength else { return .failure(.contactTooLong) }
        if !mail.isEmpty, !isPlausibleEmail(mail) { return .failure(.invalidContact) }
        if let image, image.count > Feedback.maxImageBytes { return .failure(.imageTooLarge) }
        var p = FeedbackPayload(tur: kind, metin: body)
        p.iletisim = mail.isEmpty ? nil : mail
        p.uygulama = sanitizedInfo(info.app)
        p.ios = sanitizedInfo(info.os)
        p.cihaz = sanitizedInfo(info.model)
        if kind.allowsLocation, let c = coordinate, CLLocationCoordinate2DIsValid(c) {
            p.konum = FeedbackPayload.Coordinate(lat: rounded(c.latitude), lon: rounded(c.longitude))
        }
        p.gorsel = image.map { $0.base64EncodedString() }
        return .success(p)
    }

    /// Koordinatı gönderilecek hassasiyete yuvarlar (4 ondalık ≈ 11 m).
    static func rounded(_ v: Double) -> Double {
        let k = pow(10, Double(Feedback.coordinateDecimals))
        return (v * k).rounded() / k
    }

    /// Ekranda gösterilen biçim (gönderilen değerle aynı): "41.1234, 29.0123".
    static func coordinateText(_ c: CLLocationCoordinate2D) -> String {
        let f = "%.\(Feedback.coordinateDecimals)f"
        return String(format: f, locale: Locale(identifier: "en_US_POSIX"), rounded(c.latitude)) + ", "
            + String(format: f, locale: Locale(identifier: "en_US_POSIX"), rounded(c.longitude))
    }

    /// Basit e-posta denetimi: tek "@", boşluk yok, alan adında nokta.
    static func isPlausibleEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// Sunucunun kabul ettiği karakterler (harf, rakam, boşluk, . , _ ( ) + -), en çok 40.
    static func sanitizedInfo(_ s: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,_()+-")
        let clean = String(s.unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : String(clean.prefix(Feedback.maxInfoLength))
    }
}

/// Sunucu yanıtına göre ne yapılacağı.
enum FeedbackDelivery: Equatable, Sendable {
    /// Alındı: sıradan sil.
    case sent
    /// Sunucu şu an almıyor (503): sırada kalsın.
    case unavailable
    /// Bağlantı hatası, hız sınırı ya da geçici sunucu hatası: sırada kalsın.
    case retryLater
    /// İstek reddedildi (400/413...): yeniden denemek işe yaramaz, sıradan sil.
    case rejected(String?)

    /// `status` nil: yanıt alınamadı (bağlantı yok / zaman aşımı).
    static func outcome(status: Int?, body: Data? = nil) -> FeedbackDelivery {
        guard let status else { return .retryLater }
        switch status {
        case 200..<300: return .sent
        case 503: return .unavailable
        case 408, 429, 500...599: return .retryLater
        default:
            let message = body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["hata"]
            return .rejected(message)
        }
    }

    var keepsQueued: Bool { self == .unavailable || self == .retryLater }
}

/// Gönderilmeyi bekleyen bildirim.
struct QueuedFeedback: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var created: Date
    var payload: FeedbackPayload
}

/// Gönderim sırası (en çok `Feedback.maxQueued`; doluyken yeni bildirim kabul edilmez).
struct FeedbackQueue: Codable, Equatable, Sendable {
    private(set) var items: [QueuedFeedback] = []

    var isFull: Bool { items.count >= Feedback.maxQueued }

    @discardableResult
    mutating func enqueue(_ item: QueuedFeedback) -> Bool {
        guard !isFull else { return false }
        items.append(item)
        return true
    }

    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Çok eski bildirimleri sil.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Feedback.maxQueuedDays) * 24 * 3600)
        items.removeAll { $0.created < cutoff || $0.created > now.addingTimeInterval(24 * 3600) }
    }
}

/// Seçilen fotoğraf/ekran görüntüsünü gönderime hazırlar: uzun kenar ≤ 1024 px, JPEG ≤ 1,5 MB.
/// Görüntü yeniden kodlanır; EXIF, konum ve diğer üst veriler yazılmaz.
enum FeedbackImage {
    static func jpeg(from data: Data, maxSide: Double = Feedback.imageMaxSide,
                     maxBytes: Int = Feedback.maxImageBytes) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: Int(maxSide)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return jpeg(image, maxBytes: maxBytes)
    }

    static func jpeg(_ image: CGImage, maxBytes: Int = Feedback.maxImageBytes) -> Data? {
        var q = 0.8
        while q >= 0.3 {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if out.length <= maxBytes { return out as Data }
            q -= 0.15
        }
        return nil
    }
}
