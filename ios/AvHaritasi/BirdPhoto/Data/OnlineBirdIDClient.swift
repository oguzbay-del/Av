import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Çevrimiçi kuş tanıma istemcisi (Hugging Face Space, `OnlineBirdID.baseURL`).
/// - `POST {base}/foto`: çok parçalı `file` alanı, JPEG ≤ 10 MB → BioCLIP 2
/// - `POST {base}/ses`: çok parçalı `file` alanı, mono WAV ≤ 30 sn → Perch v2
///
/// Yalnızca fotoğraf ya da ses gönderilir; konum, cihaz kimliği veya başka bir bilgi eklenmez.
/// İçerik günlüğe yazılmaz. Geçici (ephemeral) oturum: çerez ve önbellek tutulmaz.
struct OnlineBirdIDClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = OnlineBirdIDClient.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Yapılandırılmışsa varsayılan istemci; adres yoksa nil (özellik kapalı).
    static var configured: OnlineBirdIDClient? {
        OnlineBirdID.baseURL.map { OnlineBirdIDClient(baseURL: $0) }
    }

    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Uyuyan ücretsiz Space'in ilk yanıtı 30–120 sn sürebilir
        config.timeoutIntervalForRequest = OnlineBirdID.timeout
        config.timeoutIntervalForResource = OnlineBirdID.timeout + 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// Veriyi ilgili uca gönderir ve yanıtı çözümler. Görev iptal edilirse istek de iptal olur.
    func identify(_ kind: OnlineBirdID.Kind, data: Data) async throws -> OnlineBirdIDResponse {
        guard !data.isEmpty, data.count <= OnlineBirdID.maxUploadBytes else { throw OnlineBirdIDError.badPayload }
        let boundary = "AvHaritasi-" + UUID().uuidString
        var request = URLRequest(url: baseURL.appendingPathComponent(kind.path), timeoutInterval: OnlineBirdID.timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = Multipart.body(boundary: boundary, field: "file", fileName: kind.fileName,
                                  mimeType: kind.mimeType, data: data)
        let (respData, response) = try await session.upload(for: request, from: body)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OnlineBirdIDError.badResponse }
        return try OnlineBirdIDResponse.decode(data: respData, status: http.statusCode)
    }
}

/// `multipart/form-data` gövdesi (RFC 7578): tek dosya alanı.
enum Multipart {
    static func body(boundary: String, field: String, fileName: String, mimeType: String, data: Data) -> Data {
        var out = Data()
        out.append(Data("--\(boundary)\r\n".utf8))
        out.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(fileName)\"\r\n".utf8))
        out.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        out.append(data)
        out.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }
}

/// Gönderilecek veriyi hazırlar.
enum OnlineBirdIDPayload {
    /// Fotoğraf: uzun kenar ≤ 1024 px, JPEG kalite ≈ 0,85 (sınırı aşarsa kalite düşürülür).
    /// Yalnızca Core Graphics / ImageIO: herhangi bir iş parçacığında çalışır. EXIF/konum üst verisi yazılmaz.
    static func jpeg(_ image: CGImage, maxSide: Double = OnlineBirdID.photoMaxSide,
                     quality: Double = OnlineBirdID.photoJPEGQuality) -> Data? {
        let size = scaledSize(CGSize(width: image.width, height: image.height), maxSide: CGFloat(maxSide))
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        var q = quality
        while q > 0.3 {
            if let d = encodeJPEG(scaled, quality: q), d.count <= OnlineBirdID.maxUploadBytes { return d }
            q -= 0.15
        }
        return nil
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Uzun kenarı `maxSide`ı geçmeyecek biçimde orantılı küçültülmüş boyut (büyütülmez).
    static func scaledSize(_ size: CGSize, maxSide: CGFloat) -> CGSize {
        let long = max(size.width, size.height)
        guard long > maxSide, long > 0 else {
            return CGSize(width: size.width.rounded(), height: size.height.rounded())
        }
        let k = maxSide / long
        return CGSize(width: max(1, (size.width * k).rounded()), height: max(1, (size.height * k).rounded()))
    }

    /// Ses: BirdNET'in çözümlediği kayıt → 32 kHz mono 16 bit WAV; en çok 30 sn, kısa kayıt 5 sn'ye
    /// sessizlikle tamamlanır (Perch 5 sn'lik pencerelerle çalışır).
    static func wav(fromRecording url: URL) throws -> Data {
        let rate = OnlineBirdID.soundSampleRate
        var samples = try BirdNETOnDevice.readMono(url, sampleRate: Double(rate))
        guard !samples.isEmpty else { throw OnlineBirdIDError.badPayload }
        let maxCount = Int(OnlineBirdID.soundMaxSeconds * Double(rate))
        let minCount = Int(OnlineBirdID.soundMinSeconds * Double(rate))
        if samples.count > maxCount { samples.removeLast(samples.count - maxCount) }
        if samples.count < minCount { samples.append(contentsOf: repeatElement(0, count: minCount - samples.count)) }
        return WAV.encode(samples: samples, sampleRate: rate)
    }
}

/// Mono 16 bit PCM WAV (RIFF) üretici.
enum WAV {
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let channels = 1, bits = 16
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8
        let dataSize = samples.count * blockAlign
        var out = Data(capacity: 44 + dataSize)
        out.append(Data("RIFF".utf8))
        out.appendLE(UInt32(36 + dataSize))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.appendLE(UInt32(16))              // fmt bölüm boyu
        out.appendLE(UInt16(1))               // PCM
        out.appendLE(UInt16(channels))
        out.appendLE(UInt32(sampleRate))
        out.appendLE(UInt32(byteRate))
        out.appendLE(UInt16(blockAlign))
        out.appendLE(UInt16(bits))
        out.append(Data("data".utf8))
        out.appendLE(UInt32(dataSize))
        for s in samples {
            let v = s.isFinite ? max(-1, min(1, s)) : 0
            out.appendLE(Int16((v * 32_767).rounded()))
        }
        return out
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
