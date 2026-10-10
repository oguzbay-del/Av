import XCTest
@testable import AvHaritasi

final class BackoffTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testDelaysDoubleFromOneMinuteWithoutJitter() {
        let b = Backoff()
        XCTAssertEqual(b.delay(afterFailures: 0, unit: 0), 0)
        XCTAssertEqual(b.delay(afterFailures: 1, unit: 0), 60)
        XCTAssertEqual(b.delay(afterFailures: 2, unit: 0), 120)
        XCTAssertEqual(b.delay(afterFailures: 3, unit: 0), 240)
        XCTAssertEqual(b.delay(afterFailures: 4, unit: 0), 480)
        XCTAssertEqual(b.delay(afterFailures: 5, unit: 0), 960)
        XCTAssertEqual(b.delay(afterFailures: 6, unit: 0), 1_800, "32 dk yerine 30 dk sınırı")
        XCTAssertEqual(b.delay(afterFailures: 50, unit: 0), 1_800)
        XCTAssertEqual(b.delay(afterFailures: Int.max, unit: 0), 1_800)
    }

    func testJitterIsTenPercentAndClamped() {
        let b = Backoff()
        XCTAssertEqual(b.delay(afterFailures: 1, unit: 1), 66, accuracy: 1e-9)
        XCTAssertEqual(b.delay(afterFailures: 1, unit: -1), 54, accuracy: 1e-9)
        XCTAssertEqual(b.delay(afterFailures: 6, unit: 1), 1_980, accuracy: 1e-9)
        XCTAssertEqual(b.delay(afterFailures: 6, unit: -1), 1_620, accuracy: 1e-9)
        // [-1, 1] dışı değerler sınırlanır
        XCTAssertEqual(b.delay(afterFailures: 1, unit: 5), 66, accuracy: 1e-9)
        XCTAssertEqual(b.delay(afterFailures: 1, unit: -5), 54, accuracy: 1e-9)
    }

    func testRandomJitterStaysInBounds() {
        for n in 1...10 {
            var b = Backoff()
            for _ in 0..<n { b.recordFailure(at: t0) }
            let d = b.retryAt!.timeIntervalSince(t0)
            let nominal = min(1_800, 60 * pow(2, Double(n - 1)))
            XCTAssertGreaterThanOrEqual(d, nominal * 0.9 - 1e-9)
            XCTAssertLessThanOrEqual(d, nominal * 1.1 + 1e-9)
        }
    }

    func testFreshBackoffAllowsAttempt() {
        let b = Backoff()
        XCTAssertEqual(b.failures, 0)
        XCTAssertNil(b.retryAt)
        XCTAssertTrue(b.canAttempt(at: t0))
    }

    func testFailureBlocksUntilRetryTime() {
        var b = Backoff()
        b.recordFailure(at: t0, unit: 0)
        XCTAssertEqual(b.failures, 1)
        XCTAssertFalse(b.canAttempt(at: t0))
        XCTAssertFalse(b.canAttempt(at: t0.addingTimeInterval(59)))
        XCTAssertTrue(b.canAttempt(at: t0.addingTimeInterval(60)))

        let t1 = t0.addingTimeInterval(60)
        b.recordFailure(at: t1, unit: 0)
        XCTAssertEqual(b.failures, 2)
        XCTAssertFalse(b.canAttempt(at: t1.addingTimeInterval(119)))
        XCTAssertTrue(b.canAttempt(at: t1.addingTimeInterval(120)))
    }

    func testSuccessResets() {
        var b = Backoff()
        for _ in 0..<5 { b.recordFailure(at: t0, unit: 0) }
        b.recordSuccess()
        XCTAssertEqual(b.failures, 0)
        XCTAssertNil(b.retryAt)
        XCTAssertTrue(b.canAttempt(at: t0))
        b.recordFailure(at: t0, unit: 0)
        XCTAssertEqual(b.retryAt, t0.addingTimeInterval(60), "başarıdan sonra yeniden 1 dk'dan başlar")
    }

    func testCustomParameters() {
        let b = Backoff(base: 10, cap: 25, jitter: 0)
        XCTAssertEqual(b.delay(afterFailures: 1, unit: 1), 10)
        XCTAssertEqual(b.delay(afterFailures: 2, unit: 1), 20)
        XCTAssertEqual(b.delay(afterFailures: 3, unit: 1), 25)
    }
}
