import CoreLocation
import Foundation
import Observation
import UserNotifications

/// Av saati hatırlatmaları: bugün ve yarın (yalnızca MAK av günleri) için yerel bildirimler kurar.
/// Uygulama öne gelince, konum 10 km'den fazla değişince ve gün değişince yeniden kurulur.
@MainActor
@Observable
final class HuntHoursReminders {
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "huntHoursReminders") }
    }
    var leadMinutes: Int {
        didSet { UserDefaults.standard.set(leadMinutes, forKey: "huntHoursLead") }
    }

    /// Bu mesafeden fazla yer değiştirince saatler yeniden hesaplanır (gün doğumu ~10 km'de ~30 sn kayar).
    static let relocateDistance: CLLocationDistance = 10_000

    @ObservationIgnored private var last: (coordinate: CLLocation, day: String, lead: Int)?
    @ObservationIgnored private var lastLoggedCount: Int?

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "huntHoursReminders") as? Bool ?? true
        let lead = d.object(forKey: "huntHoursLead") as? Int ?? HuntHoursSchedule.defaultLead
        leadMinutes = HuntHoursSchedule.leadOptions.contains(lead) ? lead : HuntHoursSchedule.defaultLead
    }

    /// Gerekiyorsa yeniden kur: `force` (öne gelme, ayar değişikliği), gün değişimi ya da >10 km yer değişimi.
    func refresh(regs: Regulations?, coordinate: CLLocationCoordinate2D?, now: Date, notificationsAllowed: Bool?, force: Bool) {
        guard enabled, notificationsAllowed == true, let regs, let coordinate else {
            if last != nil || force { removeAll() }
            last = nil
            return
        }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let day = Regulations.dayString(now)
        if !force, let last, last.day == day, last.lead == leadMinutes,
           last.coordinate.distance(from: here) <= Self.relocateDistance {
            return
        }
        last = (here, day, leadMinutes)
        schedule(HuntHoursSchedule.reminders(now: now, windows: Self.windows(regs: regs, coordinate: coordinate, now: now),
                                             leadMinutes: leadMinutes, calendar: Regulations.istanbulCalendar))
    }

    /// Bugün ve yarının av günü olanlarının avlanma zamanları.
    nonisolated static func windows(regs: Regulations, coordinate: CLLocationCoordinate2D, now: Date) -> [HuntHoursSchedule.Window] {
        let cal = Regulations.istanbulCalendar
        let today = cal.startOfDay(for: now)
        return (0..<2).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: today) else { return nil }
            let noon = d.addingTimeInterval(12 * 3600)
            guard !regs.huntableToday(on: noon).isEmpty, let w = regs.huntingWindow(on: noon, at: coordinate) else { return nil }
            return HuntHoursSchedule.Window(start: w.start, end: w.end)
        }
    }

    private func schedule(_ reminders: [HuntHoursSchedule.Reminder]) {
        let center = UNUserNotificationCenter.current()
        let cal = Regulations.istanbulCalendar
        let count = reminders.count
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter(Self.isReminder)
            center.removePendingNotificationRequests(withIdentifiers: pending)
            for r in reminders {
                let content = UNMutableNotificationContent()
                content.title = r.title
                content.body = r.body
                content.sound = .default
                // Bitişe yaklaşma ve bitiş: av saati dışında atış yasak; Odak modunda da gelsin
                content.interruptionLevel = r.kind == .start ? .active : .timeSensitive
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireDate)
                comps.calendar = cal
                comps.timeZone = cal.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
            }
            await logDelivered()
            if lastLoggedCount != count {
                lastLoggedCount = count
                FieldLog.shared.log(.huntReminders(scheduled: count))
            }
        }
    }

    private func removeAll() {
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter(Self.isReminder)
            center.removePendingNotificationRequests(withIdentifiers: pending)
            if lastLoggedCount != 0 {
                lastLoggedCount = 0
                FieldLog.shared.log(.huntReminders(scheduled: 0))
            }
        }
    }

    nonisolated static func isReminder(_ id: String) -> Bool { id.hasPrefix(HuntHoursSchedule.prefix) }

    /// Uygulama kapalıyken çalmış hatırlatmaları saha kaydına yaz (her biri bir kez).
    private func logDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            .map(\.request.identifier).filter(Self.isReminder)
        for id in delivered { Self.logFired(id) }
    }

    /// Çalan hatırlatmayı bir kez kaydet (ön planda sunum, dokunma ya da sonradan teslim listesi).
    static func logFired(_ id: String) {
        let key = "huntHoursLoggedFired"
        var logged = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !logged.contains(id) else { return }
        logged.append(id)
        UserDefaults.standard.set(Array(logged.suffix(30)), forKey: key)
        FieldLog.shared.log(.huntReminderFired(id: id))
    }
}
