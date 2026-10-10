import Foundation

/// Av saati hatırlatmalarının saf hesabı: av günlerinin avlanma zamanlarından (gün doğumundan önce –
/// gün batımından sonra) "başladı", "bitmesine N dk" ve "bitti" bildirimleri. Yan etkisi yoktur;
/// `HuntHoursReminders` sonucu UNCalendarNotificationTrigger olarak kurar.
enum HuntHoursSchedule {
    /// Tüm av saati bildirimlerinin kimlik öneki (kaldırırken yalnızca bunlar silinir).
    static let prefix = "avsaati-"
    /// Ayarlardaki uyarı süresi seçenekleri (dakika).
    static let leadOptions = [5, 15, 30]
    static let defaultLead = 15

    /// Bir av gününün avlanma zamanı.
    struct Window: Sendable, Equatable {
        let start: Date
        let end: Date
    }

    enum Kind: String, Sendable {
        case start = "baslangic"
        case warning = "uyari"
        case end = "bitis"
    }

    struct Reminder: Sendable, Equatable {
        let id: String
        let kind: Kind
        let fireDate: Date
        let title: String
        let body: String
    }

    /// `now`dan sonra çalacak hatırlatmalar, zamana göre sıralı. `windows` yalnızca av günlerini içermeli.
    /// Uyarı, süre avlanma zamanından uzunsa ya da başlangıçtan önceye düşerse atlanır.
    static func reminders(now: Date, windows: [Window], leadMinutes: Int, calendar: Calendar) -> [Reminder] {
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = calendar.timeZone
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.calendar = Calendar(identifier: .gregorian)
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"

        var out: [Reminder] = []
        for w in windows where w.end > w.start {
            let key = day.string(from: w.start)
            let range = "\(time.string(from: w.start))–\(time.string(from: w.end))"
            func add(_ kind: Kind, _ date: Date, _ title: String, _ body: String) {
                guard date > now else { return }
                out.append(Reminder(id: "\(prefix)\(key)-\(kind.rawValue)", kind: kind, fireDate: date, title: title, body: body))
            }
            add(.start, w.start, L("Av saati başladı"), L("Bugünkü avlanma zamanı: %@.", range))
            let warn = w.end.addingTimeInterval(-Double(leadMinutes) * 60)
            if leadMinutes > 0, warn > w.start {
                add(.warning, warn, L("Av saatinin bitmesine %@ dk", String(leadMinutes)),
                    L("Avlanma zamanı %@ itibarıyla sona eriyor.", time.string(from: w.end)))
            }
            add(.end, w.end, L("Av saati bitti"), L("Avlanma zamanı sona erdi. Tüfeğinizi boşaltıp kılıfına koyun."))
        }
        return out.sorted { $0.fireDate < $1.fireDate }
    }
}
