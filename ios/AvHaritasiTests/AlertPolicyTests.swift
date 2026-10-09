import XCTest
@testable import AvHaritasi

final class AlertPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func check(_ id: String, _ kind: RuleCheck.Kind, _ level: Assessment.Level,
                       title: String? = nil, detail: String? = nil) -> RuleCheck {
        RuleCheck(id: id, kind: kind, level: level, title: title ?? "T-\(id)", detail: detail ?? "D-\(id)")
    }

    private func assessment(place: Assessment.Level, level: Assessment.Level? = nil, checks: [RuleCheck] = [],
                            title: String = "Summary", detail: String = "Summary detail") -> Assessment {
        Assessment(level: level ?? place, placeLevel: place, title: title, detail: detail,
                   zone: nil, unitName: nil, checks: checks)
    }

    // MARK: Kötüleşme

    func testSafeDoesNotAlert() {
        let d = AlertPolicy().decide(assessment(place: .safe), now: t0)
        XCTAssertNil(d.alert)
        XCTAssertEqual(d.next.lastAlertLevel, .safe)
        XCTAssertEqual(d.next.lastDangerAlert, .distantPast)
    }

    func testUnknownToCautionAlertsWithWarningPrefixAndCautionSound() {
        let a = assessment(place: .caution, checks: [check("near", .place, .caution, title: "Near", detail: "Close by")])
        let d = AlertPolicy().decide(a, now: t0)
        XCTAssertEqual(d.alert, AlertPolicy.Alert(level: .caution, title: "⚠️ Near", body: "Close by", sound: .dikkat))
        XCTAssertEqual(d.next.lastAlertLevel, .caution)
        // Dikkat uyarısı yasak hatırlatma zamanını değiştirmez
        XCTAssertEqual(d.next.lastDangerAlert, .distantPast)
    }

    func testSameCautionDoesNotRepeat() {
        let a = assessment(place: .caution, checks: [check("near", .place, .caution)])
        var p = AlertPolicy()
        XCTAssertNotNil(p.update(with: a, now: t0))
        XCTAssertNil(p.update(with: a, now: t0.addingTimeInterval(1)))
        XCTAssertNil(p.update(with: a, now: t0.addingTimeInterval(10_000)))
    }

    func testCautionToDangerAlertsWithStopPrefixAndDangerSound() {
        var p = AlertPolicy(lastAlertLevel: .caution, lastDangerAlert: .distantPast)
        let a = assessment(place: .danger, checks: [check("zone", .place, .danger, title: "Forbidden", detail: "Inside")])
        let alert = p.update(with: a, now: t0)
        XCTAssertEqual(alert, AlertPolicy.Alert(level: .danger, title: "⛔️ Forbidden", body: "Inside", sound: .yasak))
        XCTAssertEqual(p.lastAlertLevel, .danger)
        XCTAssertEqual(p.lastDangerAlert, t0)
    }

    func testImprovingDoesNotAlertButUpdatesLevel() {
        var p = AlertPolicy(lastAlertLevel: .caution, lastDangerAlert: .distantPast)
        XCTAssertNil(p.update(with: assessment(place: .safe), now: t0))
        XCTAssertEqual(p.lastAlertLevel, .safe)
        // Yeniden dikkat seviyesine çıkınca tekrar uyarır
        XCTAssertNotNil(p.update(with: assessment(place: .caution), now: t0.addingTimeInterval(1)))
    }

    func testDroppingToUnknownThenCautionAlertsAgain() {
        var p = AlertPolicy(lastAlertLevel: .caution, lastDangerAlert: .distantPast)
        XCTAssertNil(p.update(with: assessment(place: .unknown), now: t0))
        XCTAssertNotNil(p.update(with: assessment(place: .caution), now: t0))
    }

    // MARK: Yasak hatırlatması (120 sn)

    func testDangerRepeatsOnlyAfterMoreThan120Seconds() {
        let a = assessment(place: .danger, checks: [check("zone", .place, .danger)])
        var p = AlertPolicy()
        XCTAssertNotNil(p.update(with: a, now: t0))
        XCTAssertNil(p.update(with: a, now: t0.addingTimeInterval(60)))
        XCTAssertNil(p.update(with: a, now: t0.addingTimeInterval(120)), "tam 120 sn: henüz değil (kesin büyük)")
        let again = p.update(with: a, now: t0.addingTimeInterval(120.5))
        XCTAssertEqual(again?.level, .danger)
        XCTAssertEqual(p.lastDangerAlert, t0.addingTimeInterval(120.5))
        XCTAssertNil(p.update(with: a, now: t0.addingTimeInterval(200)))
    }

    func testDangerRepeatTimerSurvivesLeavingAndReturning() {
        let danger = assessment(place: .danger, checks: [check("zone", .place, .danger)])
        var p = AlertPolicy()
        XCTAssertNotNil(p.update(with: danger, now: t0))
        XCTAssertNil(p.update(with: assessment(place: .safe), now: t0.addingTimeInterval(10)))
        // Geri dönüş kötüleşmedir: 120 sn dolmasa da uyarır
        XCTAssertNotNil(p.update(with: danger, now: t0.addingTimeInterval(20)))
        XCTAssertEqual(p.lastDangerAlert, t0.addingTimeInterval(20))
    }

    func testNoAlertWhenOnlyTimeLevelIsDanger() {
        // Mekânsal seviye güvenli, zaman kuralı yasak (ör. av günü değil): bildirim yok
        let a = assessment(place: .safe, level: .danger, checks: [check("day", .time, .danger)])
        let d = AlertPolicy().decide(a, now: t0)
        XCTAssertNil(d.alert)
        XCTAssertEqual(d.next.lastAlertLevel, .safe)
    }

    // MARK: Metin

    func testTextComesFromFirstPlaceCheckOfThatLevel() {
        let a = assessment(place: .danger, checks: [
            check("time", .time, .danger, title: "TimeTitle", detail: "TimeDetail"),
            check("near", .place, .caution, title: "CautionTitle", detail: "CautionDetail"),
            check("zone1", .place, .danger, title: "First", detail: "FirstDetail"),
            check("zone2", .place, .danger, title: "Second", detail: "SecondDetail"),
        ])
        let alert = AlertPolicy().decide(a, now: t0).alert
        XCTAssertEqual(alert?.title, "⛔️ First")
        XCTAssertEqual(alert?.body, "FirstDetail")
    }

    func testFallsBackToAssessmentSummaryWithoutMatchingPlaceCheck() {
        let a = assessment(place: .caution, checks: [check("time", .time, .caution)],
                           title: "Overall", detail: "Overall detail")
        let alert = AlertPolicy().decide(a, now: t0).alert
        XCTAssertEqual(alert?.title, "⚠️ Overall")
        XCTAssertEqual(alert?.body, "Overall detail")
    }

    func testDecideDoesNotMutateReceiver() {
        let p = AlertPolicy()
        _ = p.decide(assessment(place: .danger), now: t0)
        XCTAssertEqual(p, AlertPolicy())
    }

    // MARK: Konum güncel değil

    func testStaleSafeLocationAlertsCautionWithStaleCheckText() {
        let last = assessment(place: .safe)
        let stale = Assessment.stale(age: 120, last: last)
        XCTAssertEqual(stale.placeLevel, .caution)
        var p = AlertPolicy(lastAlertLevel: .safe, lastDangerAlert: .distantPast)
        let alert = p.update(with: stale, now: t0)
        let staleCheck = stale.checks.first { $0.id == "konum_eski" }
        XCTAssertNotNil(staleCheck)
        XCTAssertEqual(alert?.level, .caution)
        XCTAssertEqual(alert?.title, "⚠️ " + (staleCheck?.title ?? ""))
        XCTAssertEqual(alert?.body, staleCheck?.detail)
        XCTAssertEqual(alert?.sound, .dikkat)
    }

    func testStaleDangerKeepsDangerReasonFromLastAssessment() {
        let last = assessment(place: .danger, checks: [check("zone", .place, .danger, title: "Forbidden", detail: "Inside")])
        let stale = Assessment.stale(age: 300, last: last)
        XCTAssertEqual(stale.placeLevel, .danger)
        let alert = AlertPolicy(lastAlertLevel: .safe, lastDangerAlert: .distantPast).decide(stale, now: t0).alert
        XCTAssertEqual(alert?.title, "⛔️ Forbidden")
        XCTAssertEqual(alert?.body, "Inside")
        XCTAssertEqual(alert?.sound, .yasak)
    }

    func testStaleWhileAlreadyCautionDoesNotRealert() {
        let last = assessment(place: .caution, checks: [check("near", .place, .caution)])
        let stale = Assessment.stale(age: 100, last: last)
        let d = AlertPolicy(lastAlertLevel: .caution, lastDangerAlert: .distantPast).decide(stale, now: t0)
        XCTAssertNil(d.alert)
    }

    func testReducedAccuracyAlertsCautionLevel() {
        // Kesin Konum kapalı: genel seviye yasak ama mekânsal seviye dikkat
        let a = Assessment.reducedAccuracy(1_500)
        let alert = AlertPolicy().decide(a, now: t0).alert
        XCTAssertEqual(alert?.level, .caution)
        // Dikkat seviyesinde mekânsal kural yok → özet başlık
        XCTAssertEqual(alert?.title, "⚠️ " + a.title)
        XCTAssertEqual(alert?.body, a.detail)
    }
}
