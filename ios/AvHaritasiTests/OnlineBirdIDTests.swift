import CoreGraphics
import ImageIO
import XCTest
@testable import AvHaritasi

/// Çevrimiçi kuş tanıma yedeği: tetikleme kuralı, yanıt çözümleme, çok parçalı gövde, WAV başlığı, JPEG küçültme.
final class OnlineBirdIDTests: XCTestCase {
    // MARK: Tetikleme kuralı

    private func decide(enabled: Bool = true, configured: Bool = true, online: Bool = true,
                        top: Double?, general: Bool = false) -> OnlineCheckPolicy.Decision {
        OnlineCheckPolicy.decide(settingEnabled: enabled, configured: configured, online: online,
                                 topProbability: top, onlyGeneral: general)
    }

    func testConfidentOnDeviceResultIsNotChecked() {
        XCTAssertEqual(decide(top: 0.9), .skip)
        XCTAssertEqual(decide(top: 0.5), .skip, "tam 0,5 belirsiz sayılmaz")
        XCTAssertEqual(decide(online: false, top: 0.9), .skip, "emin sonuçta internet uyarısı da yok")
    }

    func testUncertainResultIsChecked() {
        XCTAssertEqual(decide(top: 0.49), .check)
        XCTAssertEqual(decide(top: 0.1), .check)
    }

    func testNoResultOrGeneralOnlyIsChecked() {
        XCTAssertEqual(decide(top: nil), .check)
        XCTAssertEqual(decide(top: 0.95, general: true), .check, "genel grup sonucu tür değildir")
    }

    func testOfflineShowsNotice() {
        XCTAssertEqual(decide(online: false, top: 0.2), .offline)
        XCTAssertEqual(decide(online: false, top: nil), .offline)
    }

    func testDisabledOrUnconfiguredDoesNothing() {
        XCTAssertEqual(decide(enabled: false, top: 0.1), .skip)
        XCTAssertEqual(decide(configured: false, top: 0.1), .skip)
        XCTAssertEqual(decide(enabled: false, online: false, top: nil), .skip)
        XCTAssertEqual(decide(configured: false, online: false, top: nil), .skip, "adres yoksa arayüz hiç değişmez")
    }

    // MARK: Yanıt çözümleme

    func testDecodesSuccessResponse() throws {
        let json = """
        {"model": "bioclip-2", "sure_ms": 1834,
         "sonuclar": [
           {"sci": "Anas crecca", "en": "Eurasian Teal", "tr": "Çamurcun", "p": 0.21},
           {"sci": "Anas platyrhynchos", "en": "Mallard", "tr": "Yeşilbaş", "p": 0.64},
           {"sci": "Aythya ferina", "en": "Common Pochard", "tr": "", "p": 0.08},
           {"sci": "Tadorna tadorna", "en": "Common Shelduck", "tr": "Angıt", "p": 0.05}
         ]}
        """
        let r = try OnlineBirdIDResponse.decode(data: Data(json.utf8), status: 200)
        XCTAssertEqual(r.model, "bioclip-2")
        XCTAssertEqual(r.sureMs, 1834)
        XCTAssertEqual(r.sonuclar.count, 4)

        let tr = r.predictions(english: false)
        XCTAssertEqual(tr.map(\.scientificName), ["Anas platyrhynchos", "Anas crecca", "Aythya ferina"], "olasılığa göre ilk 3")
        XCTAssertEqual(tr.map(\.commonName), ["Yeşilbaş", "Çamurcun", "Common Pochard"], "Türkçe ad yoksa İngilizce")
        XCTAssertEqual(tr[0].probability, 0.64, accuracy: 1e-9)
        XCTAssertTrue(tr.allSatisfy { $0.source == .onlineModel })

        let en = r.predictions(english: true)
        XCTAssertEqual(en.map(\.commonName), ["Mallard", "Eurasian Teal", "Common Pochard"])
    }

    func testDecodesWithoutDurationAndEmptyResults() throws {
        let r = try OnlineBirdIDResponse.decode(data: Data(#"{"model":"perch-v2","sonuclar":[]}"#.utf8), status: 200)
        XCTAssertEqual(r.model, "perch-v2")
        XCTAssertNil(r.sureMs)
        XCTAssertTrue(r.predictions().isEmpty)
    }

    func testProbabilityIsClamped() throws {
        let json = #"{"model":"perch-v2","sonuclar":[{"sci":"Coturnix coturnix","en":"Common Quail","tr":"Bıldırcın","p":1.7}],"sure_ms":5}"#
        let p = try OnlineBirdIDResponse.decode(data: Data(json.utf8), status: 200).predictions()
        XCTAssertEqual(p.first?.probability, 1)
    }

    func testErrorBodyIsDecoded() {
        let body = Data(#"{"hata": "Dosya çok büyük"}"#.utf8)
        XCTAssertThrowsError(try OnlineBirdIDResponse.decode(data: body, status: 413)) { e in
            XCTAssertEqual(e as? OnlineBirdIDError, .server(status: 413, message: "Dosya çok büyük"))
        }
    }

    func testErrorWithoutBodyAndMalformedSuccess() {
        XCTAssertThrowsError(try OnlineBirdIDResponse.decode(data: Data("<html>503</html>".utf8), status: 503)) { e in
            XCTAssertEqual(e as? OnlineBirdIDError, .http(status: 503))
        }
        XCTAssertThrowsError(try OnlineBirdIDResponse.decode(data: Data(#"{"hata":"x"}"#.utf8), status: 200)) { e in
            XCTAssertEqual(e as? OnlineBirdIDError, .badResponse)
        }
    }

    // MARK: Çok parçalı gövde

    func testMultipartBody() {
        let payload = Data([0xFF, 0xD8, 0x00, 0x0D, 0x0A, 0xFF, 0xD9])
        let body = Multipart.body(boundary: "SINIR", field: "file", fileName: "kus.jpg", mimeType: "image/jpeg", data: payload)
        let head = Data(("--SINIR\r\n"
                         + "Content-Disposition: form-data; name=\"file\"; filename=\"kus.jpg\"\r\n"
                         + "Content-Type: image/jpeg\r\n\r\n").utf8)
        let tail = Data("\r\n--SINIR--\r\n".utf8)
        XCTAssertEqual(body, head + payload + tail)
    }

    func testKindEndpoints() {
        XCTAssertEqual(OnlineBirdID.Kind.photo.path, "foto")
        XCTAssertEqual(OnlineBirdID.Kind.sound.path, "ses")
        XCTAssertEqual(OnlineBirdID.Kind.photo.mimeType, "image/jpeg")
        XCTAssertEqual(OnlineBirdID.Kind.sound.mimeType, "audio/wav")
        XCTAssertEqual(OnlineBirdID.Kind.photo.modelName, "BioCLIP 2")
        XCTAssertEqual(OnlineBirdID.Kind.sound.modelName, "Perch v2")
    }

    // MARK: WAV

    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.subdata(in: o..<o + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    private func u16(_ d: Data, _ o: Int) -> UInt16 {
        d.subdata(in: o..<o + 2).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    func testWAVHeader() {
        let samples: [Float] = [0, 1, -1, 0.5, 2, .nan]
        let d = WAV.encode(samples: samples, sampleRate: 32_000)
        XCTAssertEqual(d.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(u32(d, 4), UInt32(36 + samples.count * 2))
        XCTAssertEqual(String(decoding: d[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(u32(d, 16), 16)
        XCTAssertEqual(u16(d, 20), 1, "PCM")
        XCTAssertEqual(u16(d, 22), 1, "mono")
        XCTAssertEqual(u32(d, 24), 32_000)
        XCTAssertEqual(u32(d, 28), 64_000, "bayt/sn")
        XCTAssertEqual(u16(d, 32), 2, "blok hizası")
        XCTAssertEqual(u16(d, 34), 16, "bit")
        XCTAssertEqual(String(decoding: d[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(u32(d, 40), UInt32(samples.count * 2))
        let pcm = (0..<samples.count).map { Int16(bitPattern: u16(d, 44 + $0 * 2)) }
        XCTAssertEqual(pcm, [0, 32_767, -32_767, 16_384, 32_767, 0], "kırpılır; NaN sessizlik olur")
    }

    // MARK: Fotoğraf

    func testScaledSizeKeepsAspectAndNeverUpscales() {
        XCTAssertEqual(OnlineBirdIDPayload.scaledSize(CGSize(width: 1600, height: 1200), maxSide: 1024),
                       CGSize(width: 1024, height: 768))
        XCTAssertEqual(OnlineBirdIDPayload.scaledSize(CGSize(width: 900, height: 1600), maxSide: 1024),
                       CGSize(width: 576, height: 1024))
        XCTAssertEqual(OnlineBirdIDPayload.scaledSize(CGSize(width: 800, height: 600), maxSide: 1024),
                       CGSize(width: 800, height: 600))
    }

    func testJPEGIsDownscaled() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let image = try XCTUnwrap(ctx.makeImage())
        let jpeg = try XCTUnwrap(OnlineBirdIDPayload.jpeg(image))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "JPEG başlığı")
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 1024)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 512)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "konum üst verisi yok")
    }
}
