import CoreGraphics
import CoreLocation
import ImageIO
import XCTest
@testable import AvHaritasi

final class FeedbackTests: XCTestCase {
    private let info = FeedbackDeviceInfo(app: "1.4 (52)", os: "26.0.1", model: "iPhone17,1")
    private let point = CLLocationCoordinate2D(latitude: 41.123_456, longitude: 29.987_654)

    private func build(_ kind: FeedbackKind = .hata, text: String = "Harita açılmıyor", contact: String = "",
                       coordinate: CLLocationCoordinate2D? = nil,
                       image: Data? = nil) -> Result<FeedbackPayload, FeedbackValidationError> {
        FeedbackBuilder.build(kind: kind, text: text, contact: contact, coordinate: coordinate, image: image, info: info)
    }

    // MARK: Doğrulama

    func testValidMinimal() throws {
        let p = try build(text: "  Harita\r\nyavaş  ").get()
        XCTAssertEqual(p.tur, .hata)
        XCTAssertEqual(p.metin, "Harita\nyavaş")
        XCTAssertNil(p.iletisim)
        XCTAssertNil(p.konum)
        XCTAssertNil(p.gorsel)
        XCTAssertEqual(p.uygulama, "1.4 (52)")
        XCTAssertEqual(p.ios, "26.0.1")
        XCTAssertEqual(p.cihaz, "iPhone17,1")
    }

    func testTextLimits() {
        XCTAssertEqual(build(text: " \n ").failureValue, .emptyText)
        XCTAssertEqual(build(text: String(repeating: "ş", count: 2001)).failureValue, .textTooLong)
        XCTAssertNil(build(text: String(repeating: "ş", count: 2000)).failureValue)
    }

    func testContact() throws {
        XCTAssertEqual(try build(contact: " avci@ornek.com ").get().iletisim, "avci@ornek.com")
        XCTAssertEqual(build(contact: "avci").failureValue, .invalidContact)
        XCTAssertEqual(build(contact: "a b@c.d").failureValue, .invalidContact)
        XCTAssertEqual(build(contact: "a@b").failureValue, .invalidContact)
        XCTAssertEqual(build(contact: String(repeating: "a", count: 195) + "@b.com").failureValue, .contactTooLong)
    }

    func testLocationOnlyForMapAndRounded() throws {
        XCTAssertNil(try build(.hata, coordinate: point).get().konum, "harita dışı türde konum eklenmez")
        let p = try build(.harita, coordinate: point).get()
        XCTAssertEqual(p.konum, FeedbackPayload.Coordinate(lat: 41.1235, lon: 29.9877))
        XCTAssertEqual(FeedbackBuilder.coordinateText(point), "41.1235, 29.9877")
        XCTAssertNil(try build(.harita, coordinate: CLLocationCoordinate2D(latitude: 200, longitude: 0)).get().konum)
    }

    func testImageLimit() throws {
        XCTAssertEqual(build(image: Data(count: Feedback.maxImageBytes + 1)).failureValue, .imageTooLarge)
        let small = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertEqual(try build(image: small).get().gorsel, small.base64EncodedString())
    }

    func testInfoSanitized() {
        XCTAssertEqual(FeedbackBuilder.sanitizedInfo("iPhone<17,1>"), "iPhone17,1")
        XCTAssertNil(FeedbackBuilder.sanitizedInfo("ğüş"))
        XCTAssertEqual(FeedbackBuilder.sanitizedInfo(String(repeating: "a", count: 50))?.count, Feedback.maxInfoLength)
    }

    func testJSONMatchesServerFields() throws {
        var p = try build(.harita, contact: "a@b.co", coordinate: point).get()
        p.gorsel = "AAAA"
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["tur", "metin", "iletisim", "uygulama", "ios", "cihaz", "konum", "gorsel"])
        XCTAssertEqual(obj["tur"] as? String, "harita")
        let minimal = try XCTUnwrap(JSONSerialization.jsonObject(with: build().get().encoded()) as? [String: Any])
        XCTAssertNil(minimal["konum"], "boş alanlar gönderilmez")
        XCTAssertNil(minimal["iletisim"])
    }

    // MARK: Yanıt ve sıra

    func testDeliveryOutcome() {
        XCTAssertEqual(FeedbackDelivery.outcome(status: 201), .sent)
        XCTAssertEqual(FeedbackDelivery.outcome(status: 503), .unavailable)
        XCTAssertEqual(FeedbackDelivery.outcome(status: nil), .retryLater)
        XCTAssertEqual(FeedbackDelivery.outcome(status: 429), .retryLater)
        XCTAssertEqual(FeedbackDelivery.outcome(status: 502), .retryLater)
        XCTAssertEqual(FeedbackDelivery.outcome(status: 400, body: Data(#"{"hata":"Bilinmeyen alan: x"}"#.utf8)),
                       .rejected("Bilinmeyen alan: x"))
        XCTAssertTrue(FeedbackDelivery.unavailable.keepsQueued)
        XCTAssertFalse(FeedbackDelivery.rejected(nil).keepsQueued)
    }

    func testQueueMaxAndPrune() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let p = try build().get()
        var q = FeedbackQueue()
        for _ in 0..<Feedback.maxQueued { XCTAssertTrue(q.enqueue(QueuedFeedback(created: now, payload: p))) }
        XCTAssertFalse(q.enqueue(QueuedFeedback(created: now, payload: p)), "sıra dolu")
        q.remove(q.items[0].id)
        XCTAssertTrue(q.enqueue(QueuedFeedback(created: now.addingTimeInterval(-31 * 24 * 3600), payload: p)))
        q.prune(now: now)
        XCTAssertEqual(q.items.count, Feedback.maxQueued - 1)
    }

    // MARK: Gönderim kutusu (sahte ağ)

    @MainActor
    func testOutboxSendsQueuesAndKeepsOn503() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(URL(string: "https://ornek.invalid/geribildirim"))
        let status = Box(201)
        let online = Box(true)
        let seen = Box<[URLRequest]>([])
        func makeOutbox() -> FeedbackOutbox {
            FeedbackOutbox(directory: dir, endpoint: url, isOnline: { online.value },
                           transport: { r in seen.value.append(r); return (status: status.value, body: nil) })
        }
        let outbox = makeOutbox()
        let p = try build().get()

        let sent = await outbox.submit(p)
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(outbox.pendingCount, 0)
        let request = try XCTUnwrap(seen.value.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Av-Uygulama"), "1")
        XCTAssertEqual(request.httpMethod, "POST")

        online.value = false
        let offline = await outbox.submit(p)
        XCTAssertEqual(offline, .queued)
        XCTAssertEqual(outbox.pendingCount, 1)

        online.value = true
        status.value = 503
        let unavailable = await outbox.submit(p)
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertEqual(outbox.pendingCount, 2, "503'te ikisi de sırada kalır")
        XCTAssertEqual(makeOutbox().pendingCount, 2, "sıra diske yazılır")

        status.value = 400
        let rejected = await outbox.submit(p)
        XCTAssertEqual(rejected, .rejected(nil))
        XCTAssertEqual(outbox.pendingCount, 0, "reddedilenler sıradan düşer")
    }

    // MARK: Görsel

    func testImageReencodedWithoutMetadataAndDownscaled() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        let image = try XCTUnwrap(ctx.makeImage())
        // GPS üst verili JPEG
        let src = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(src, "public.jpeg" as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 41.1, kCGImagePropertyGPSLongitude: 29.1]
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let out = try XCTUnwrap(FeedbackImage.jpeg(from: src as Data))
        XCTAssertLessThanOrEqual(out.count, Feedback.maxImageBytes)
        let s = try XCTUnwrap(CGImageSourceCreateWithData(out as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "konum üst verisi yazılmaz")
        let w = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int)
        let h = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertEqual(max(w, h), 1024)
        XCTAssertNil(FeedbackImage.jpeg(from: Data("jpeg değil".utf8)))
    }
}

/// Kapanışlarda değiştirilebilen kutu (testler ana aktörde sırayla koşar).
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
