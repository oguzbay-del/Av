import CryptoKit
import XCTest
@testable import AvHaritasi

/// Saat ve ağ testlerde elle sürülür.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class TestTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var status = 202
    var requests: [URLRequest] { lock.withLock { _requests } }
    func send(_ r: URLRequest) async throws -> Int {
        lock.withLock { _requests.append(r) }
        return status
    }
}

final class UsageStatsTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UsageStatsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeRecorder(appID: String? = "TEST-APP", clock: TestClock, enabled: Bool = true,
                              transport: TestTransport = TestTransport()) -> UsageRecorder {
        UsageRecorder(directory: root, appID: appID, key: key, isEnabled: { enabled }, isOnline: { true },
                      now: { clock.now }, transport: { try await transport.send($0) })
    }

    // MARK: Sayaçlar ve gün dönümü

    func testCountersAggregateAndRollOverAtIstanbulMidnight() {
        let clock = TestClock(TestData.istanbul("2026-10-10T23:50"))
        let r = makeRecorder(clock: clock)
        r.record(.harita)
        r.record(.harita)
        r.recordAlert()
        r.recordBirdID(.foto, confidence: .yuksek, online: false)
        _ = r.snapshot()
        clock.now = TestData.istanbul("2026-10-11T00:05")
        r.record(.bugun)
        let l = r.snapshot()
        XCTAssertEqual(l.days["2026-10-10"]?.features["harita"], 2)
        XCTAssertEqual(l.days["2026-10-10"]?.features["kus_foto"], 1)
        XCTAssertEqual(l.days["2026-10-10"]?.alerts, 1)
        XCTAssertEqual(l.days["2026-10-10"]?.birdIDs["foto|yuksek|cihaz"], 1)
        XCTAssertEqual(l.days["2026-10-11"]?.features, ["bugun": 1])
        XCTAssertEqual(l.completedDays(now: clock.now).map(\.key), ["2026-10-10"])
    }

    func testAreaCountedOncePerSessionAndUnknownWhenNeverDetermined() {
        let clock = TestClock(TestData.istanbul("2026-10-10T08:00"))
        let r = makeRecorder(clock: clock)
        r.sessionStarted()
        r.noteArea(nil)            // ava yasak alan / konum yok: ad gelmez
        r.noteArea("Şile Devlet Avlağı")
        r.noteArea("Beykoz Devlet Avlağı")
        r.sessionEnded()
        r.sessionStarted()
        r.sessionEnded()
        let d = r.snapshot().days["2026-10-10"]
        XCTAssertEqual(d?.sessions, 2)
        XCTAssertEqual(d?.areas, ["Şile Devlet Avlağı": 1, UsageStats.unknownArea: 1])
    }

    func testAreaNameDropsExplanation() {
        XCTAssertEqual(UsageStats.areaName("Durusu D.A. (2024-25; 2026-27 listesinde yok)"), "Durusu D.A.")
        XCTAssertNil(UsageStats.areaName(nil))
        XCTAssertNil(UsageStats.areaName(" "))
    }

    func testConfidenceBuckets() {
        XCTAssertEqual(UsageConfidence(probability: nil), .dusuk)
        XCTAssertEqual(UsageConfidence(probability: 0.3), .dusuk)
        XCTAssertEqual(UsageConfidence(probability: 0.6), .orta)
        XCTAssertEqual(UsageConfidence(probability: 0.95), .yuksek)
    }

    // MARK: Disk

    func testPersistsEncrypted() throws {
        let clock = TestClock(TestData.istanbul("2026-10-10T08:00"))
        let r = makeRecorder(clock: clock)
        r.record(.kurallar)
        _ = r.snapshot()
        XCTAssertTrue(r.fileExists)
        let raw = try Data(contentsOf: root.appendingPathComponent("gunluk.bin"))
        XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "kurallar"), "dosya düz metin olmamalı")
        // Yeni nesne aynı anahtarla okur ve üstüne ekler
        let r2 = makeRecorder(clock: clock)
        r2.record(.kurallar)
        XCTAssertEqual(r2.snapshot().days["2026-10-10"]?.features["kurallar"], 2)
    }

    func testOptOutRecordsNothingAndDeletesPending() {
        let clock = TestClock(TestData.istanbul("2026-10-10T08:00"))
        let r = makeRecorder(clock: clock)
        r.record(.harita)
        let id = r.snapshot().installID
        XCTAssertTrue(r.fileExists)
        r.deleteAll()
        XCTAssertTrue(r.snapshot().days.isEmpty)
        XCTAssertFalse(r.fileExists)
        XCTAssertNotEqual(r.snapshot().installID, id, "kurulum kimliği de silinmeli")

        let off = makeRecorder(clock: clock, enabled: false)
        off.record(.harita)
        off.recordAlert()
        off.sessionStarted()
        XCTAssertTrue(off.snapshot().days.isEmpty)
        XCTAssertFalse(off.fileExists)
    }

    func testNilAppIDIsInactive() {
        let clock = TestClock(TestData.istanbul("2026-10-10T08:00"))
        let transport = TestTransport()
        let r = makeRecorder(appID: nil, clock: clock, transport: transport)
        r.sessionStarted()
        r.record(.harita)
        r.noteArea("Şile Devlet Avlağı")
        r.sendIfDue()
        XCTAssertTrue(r.snapshot().days.isEmpty)
        XCTAssertFalse(r.fileExists)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(UsageStats.isConfigured, UsageStats.appID?.isEmpty == false)
    }

    func testPrunesDaysOlderThan30() {
        var l = UsageLedger()
        let now = TestData.istanbul("2026-11-15T12:00")
        l.days["2026-10-01"] = UsageDay(sessions: 1)
        l.days["2026-10-20"] = UsageDay(sessions: 1)
        l.days["2026-11-15"] = UsageDay(sessions: 1)
        l.prune(now: now)
        XCTAssertEqual(l.days.keys.sorted(), ["2026-10-20", "2026-11-15"])
    }

    // MARK: Gönderim

    func testPayloadHasNoForbiddenFields() throws {
        var d = UsageDay(sessions: 3, features: ["harita": 2], areas: ["Şile Devlet Avlağı": 2], alerts: 4,
                         birdIDs: ["ses|orta|cevrimici": 1])
        d.appVersion = "1.4"
        d.osVersion = "18.2"
        d.deviceModel = "iPhone15,2"
        let id = UUID()
        let signals = UsageSignalBuilder.signals(for: [(key: "2026-10-10", day: d)], appID: "TEST-APP", installID: id, testMode: true)
        XCTAssertEqual(Set(signals.map(\.type)),
                       [UsageSignalBuilder.sessionSignal, "Usage.featureUsed", "Usage.areaOpened", "Usage.alertsShown", "Usage.birdIdentified"])
        XCTAssertTrue(signals.allSatisfy { $0.isTestMode == "true" && $0.appID == "TEST-APP" })
        XCTAssertEqual(signals.filter { $0.type == UsageSignalBuilder.sessionSignal }.count, 3, "oturum başına bir sinyal")
        XCTAssertTrue(signals.allSatisfy { $0.receivedAt == "2026-10-10T09:00:00+0000" })
        XCTAssertEqual(signals.first?.payload["TelemetryDeck.Device.systemVersion"], "iOS 18.2.0")
        XCTAssertEqual(signals.first?.payload["TelemetryDeck.Device.systemMajorVersion"], "iOS 18")
        // clientUser: kurulum kimliğinin tuzlu SHA-256'sı; kimliğin kendisi gönderilmez
        XCTAssertTrue(signals.allSatisfy { $0.clientUser.count == 64 && $0.clientUser != id.uuidString })
        XCTAssertEqual(signals.first { $0.type == "Usage.alertsShown" }?.floatValue, 4)
        XCTAssertNil(signals.first { $0.type == "Usage.alertsShown" }?.payload["Usage.area"], "uyarıya yer eklenmemeli")
        let bird = try XCTUnwrap(signals.first { $0.type == "Usage.birdIdentified" })
        XCTAssertEqual(bird.payload["Usage.BirdID.confidence"], "orta")
        XCTAssertEqual(bird.payload["Usage.BirdID.onlineFallback"], "true")

        let body = try XCTUnwrap(UsageSignalBuilder.request(signals, namespace: nil).httpBody)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertNil(text.range(of: id.uuidString), "kurulum kimliği açık gönderilmemeli")
        XCTAssertNil(text.range(of: #"\d{2}\.\d{4,}"#, options: .regularExpression), "koordinata benzer sayı olmamalı")
        // Yalnızca izinli alanlar; yükte iç içe nesne yok (Ingest API v2)
        let allowedTop: Set<String> = ["receivedAt", "appID", "clientUser", "sessionID", "type", "isTestMode", "floatValue", "payload"]
        let allowedPayload: Set<String> = [
            "Usage.day", "Usage.feature", "Usage.area", "Usage.BirdID.kind", "Usage.BirdID.confidence",
            "Usage.BirdID.onlineFallback", "TelemetryDeck.AppInfo.version", "TelemetryDeck.Device.systemVersion",
            "TelemetryDeck.Device.modelName", "TelemetryDeck.Device.platform", "TelemetryDeck.Device.operatingSystem",
            "TelemetryDeck.Device.systemMajorVersion", "TelemetryDeck.Device.systemMajorMinorVersion",
            "TelemetryDeck.RunContext.isDebug", "platform", "operatingSystem", "isDebug", "appVersion", "systemVersion",
            "majorSystemVersion", "majorMinorSystemVersion", "modelName",
        ]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(json.count, signals.count)
        for s in json {
            XCTAssertTrue(Set(s.keys).isSubset(of: allowedTop), "\(s.keys)")
            let payload = try XCTUnwrap(s["payload"] as? [String: Any])
            XCTAssertTrue(Set(payload.keys).isSubset(of: allowedPayload), "\(payload.keys)")
            for v in payload.values { XCTAssertTrue(v is String) }
        }
    }

    func testRequestFormat() throws {
        let r = try UsageSignalBuilder.request([], namespace: nil)
        XCTAssertEqual(r.url?.absoluteString, "https://nom.telemetrydeck.com/v2/")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(try UsageSignalBuilder.request([], namespace: "ns").url?.absoluteString,
                       "https://nom.telemetrydeck.com/v2/namespace/ns/")
    }

    func testSendsCompletedDaysOncePerDayAndDeletesOnSuccess() async throws {
        let clock = TestClock(TestData.istanbul("2026-10-10T08:00"))
        let transport = TestTransport()
        let r = makeRecorder(clock: clock, transport: transport)
        r.record(.harita)
        r.sendIfDue()
        _ = r.snapshot()
        XCTAssertTrue(transport.requests.isEmpty, "bugün bitmeden gönderilmez")

        clock.now = TestData.istanbul("2026-10-11T09:00")
        r.record(.bugun)
        r.sendIfDue()
        try await waitUntil { r.snapshot().days["2026-10-10"] == nil }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNotNil(r.snapshot().days["2026-10-11"], "bugünkü sayaçlar kalır")

        // Aynı gün ikinci deneme yok
        clock.now = TestData.istanbul("2026-10-12T08:00")
        r.sendIfDue()
        _ = r.snapshot()
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFailedSendKeepsDataAndDoesNotRetrySameDay() async throws {
        let clock = TestClock(TestData.istanbul("2026-10-10T08:00"))
        let transport = TestTransport()
        transport.status = 500
        let r = makeRecorder(clock: clock, transport: transport)
        r.record(.harita)
        clock.now = TestData.istanbul("2026-10-11T09:00")
        r.sendIfDue()
        try await waitUntil { transport.requests.count == 1 }
        _ = r.snapshot()
        r.sendIfDue()
        _ = r.snapshot()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNotNil(r.snapshot().days["2026-10-10"])
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
