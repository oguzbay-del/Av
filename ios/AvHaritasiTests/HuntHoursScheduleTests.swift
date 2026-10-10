import CoreLocation
import XCTest
@testable import AvHaritasi

final class HuntHoursScheduleTests: XCTestCase {
    private let cal = Regulations.istanbulCalendar

    private func window(_ start: String, _ end: String) -> HuntHoursSchedule.Window {
        HuntHoursSchedule.Window(start: TestData.istanbul(start), end: TestData.istanbul(end))
    }

    func testThreeRemindersPerDayInOrder() {
        let w = window("2026-10-11T06:07", "2026-10-11T19:30")
        let r = HuntHoursSchedule.reminders(now: TestData.istanbul("2026-10-10T20:00"), windows: [w], leadMinutes: 15, calendar: cal)
        XCTAssertEqual(r.map(\.id), ["avsaati-2026-10-11-baslangic", "avsaati-2026-10-11-uyari", "avsaati-2026-10-11-bitis"])
        XCTAssertEqual(r.map(\.fireDate), [w.start, TestData.istanbul("2026-10-11T19:15"), w.end])
        XCTAssertEqual(r.map(\.kind), [.start, .warning, .end])
        XCTAssertTrue(r.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
        XCTAssertTrue(r.allSatisfy { HuntHoursReminders.isReminder($0.id) })
    }

    func testLeadOptionsShiftWarning() {
        let w = window("2026-10-11T06:07", "2026-10-11T19:30")
        for (lead, at) in [(5, "19:25"), (30, "19:00")] {
            let r = HuntHoursSchedule.reminders(now: TestData.istanbul("2026-10-11T00:00"), windows: [w], leadMinutes: lead, calendar: cal)
            XCTAssertEqual(r.first { $0.kind == .warning }?.fireDate, TestData.istanbul("2026-10-11T" + at))
        }
    }

    func testPastRemindersAreDropped() {
        let w = window("2026-10-11T06:07", "2026-10-11T19:30")
        let r = HuntHoursSchedule.reminders(now: TestData.istanbul("2026-10-11T19:20"), windows: [w], leadMinutes: 15, calendar: cal)
        XCTAssertEqual(r.map(\.kind), [.end])
        XCTAssertTrue(HuntHoursSchedule.reminders(now: TestData.istanbul("2026-10-11T19:31"), windows: [w],
                                                  leadMinutes: 15, calendar: cal).isEmpty)
    }

    func testTodayAndTomorrowSortedWithUniqueIDs() {
        let today = window("2026-10-10T06:06", "2026-10-10T19:31")
        let tomorrow = window("2026-10-11T06:07", "2026-10-11T19:30")
        let r = HuntHoursSchedule.reminders(now: TestData.istanbul("2026-10-10T12:00"), windows: [tomorrow, today],
                                            leadMinutes: 15, calendar: cal)
        XCTAssertEqual(r.count, 5)
        XCTAssertEqual(r.map(\.fireDate), r.map(\.fireDate).sorted())
        XCTAssertEqual(Set(r.map(\.id)).count, r.count)
        XCTAssertEqual(r.first?.id, "avsaati-2026-10-10-uyari")
    }

    func testLeadLongerThanWindowSkipsWarning() {
        let w = window("2026-10-11T06:00", "2026-10-11T06:20")
        let r = HuntHoursSchedule.reminders(now: TestData.istanbul("2026-10-11T00:00"), windows: [w], leadMinutes: 30, calendar: cal)
        XCTAssertEqual(r.map(\.kind), [.start, .end])
    }

    /// Gerçek MAK verisi: av günü olmayan gün (Pazartesi) hatırlatma kurulmaz, av günü (Pazar) kurulur.
    func testWindowsOnlyOnHuntingDays() throws {
        let regs = try TestData.regs()
        let istanbul = CLLocationCoordinate2D(latitude: 41.2, longitude: 28.9)
        // 2026-10-11 Pazar, 2026-10-12 Pazartesi
        let sunday = HuntHoursReminders.windows(regs: regs, coordinate: istanbul, now: TestData.istanbul("2026-10-11T10:00"))
        XCTAssertEqual(sunday.count, 1)
        if let w = sunday.first {
            XCTAssertTrue(cal.isDate(w.start, inSameDayAs: TestData.istanbul("2026-10-11T10:00")))
            XCTAssertLessThan(w.start, TestData.istanbul("2026-10-11T07:30"))
            XCTAssertGreaterThan(w.end, TestData.istanbul("2026-10-11T19:00"))
        }
    }
}
