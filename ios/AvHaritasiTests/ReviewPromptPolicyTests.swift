import XCTest
@testable import AvHaritasi

final class ReviewPromptPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    /// `days` farklı günde birer açılış.
    private func state(days: Int, extraSessions: Int = 0, birdIDs: Int = 0) -> ReviewPromptState {
        var s = ReviewPromptState()
        for d in 0..<days { ReviewPromptPolicy.recordSession(&s, now: t0.addingTimeInterval(Double(d) * day)) }
        for _ in 0..<extraSessions { ReviewPromptPolicy.recordSession(&s, now: t0) }
        for _ in 0..<birdIDs { ReviewPromptPolicy.recordBirdID(&s) }
        return s
    }

    private func ask(_ s: ReviewPromptState, after days: Double = 10, alert: Bool = false) -> Bool {
        ReviewPromptPolicy.shouldPrompt(s, now: t0.addingTimeInterval(days * day), safetyAlertActive: alert)
    }

    func testNeedsEngagement() {
        XCTAssertFalse(ask(ReviewPromptState()), "hiç açılış yok")
        XCTAssertFalse(ask(state(days: 4, extraSessions: 20, birdIDs: 10)), "5 farklı gün gerekir")
        XCTAssertFalse(ask(state(days: 5)), "5 oturum ve kuş tanıma yok")
        XCTAssertTrue(ask(state(days: 5, birdIDs: 3)), "5 gün + 3 kuş tanıma")
        XCTAssertTrue(ask(state(days: 5, extraSessions: 5)), "5 gün + 10 oturum")
        XCTAssertFalse(ask(state(days: 5, extraSessions: 4, birdIDs: 2)))
    }

    func testSameDaySessionsCountOnce() {
        let s = state(days: 1, extraSessions: 30)
        XCTAssertEqual(s.activeDays.count, 1)
        XCTAssertEqual(s.sessions, 31)
    }

    func testNotInFirstWeek() {
        let s = state(days: 5, birdIDs: 3)
        XCTAssertFalse(ask(s, after: 6.9))
        XCTAssertTrue(ask(s, after: 7))
    }

    func testNeverDuringSafetyAlert() {
        XCTAssertFalse(ask(state(days: 5, birdIDs: 3), alert: true))
    }

    func testAtMostOncePer120Days() {
        var s = state(days: 5, birdIDs: 3)
        ReviewPromptPolicy.recordPrompt(&s, now: t0.addingTimeInterval(10 * day))
        XCTAssertFalse(ask(s, after: 11))
        XCTAssertFalse(ask(s, after: 129.9))
        XCTAssertTrue(ask(s, after: 130))
    }

    func testStoredDaysCapped() {
        let s = state(days: 40)
        XCTAssertEqual(s.activeDays.count, ReviewPromptPolicy.maxStoredDays)
    }
}
