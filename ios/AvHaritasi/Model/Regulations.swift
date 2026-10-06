import CoreLocation
import Foundation

/// Merkez Av Komisyonu kararından yapılandırılmış kurallar (`mak_2026_2027.json`).
struct Regulations: Decodable {
    struct HuntingDays: Decodable {
        struct Holiday: Decodable { let date: String; let name: String }
        let weekdays: [Int]                 // Calendar.weekday: 1 = Pazar, 4 = Çarşamba, 7 = Cumartesi
        let extraTuesdayGroups: [String]
        let note: String
        let holidays: [Holiday]
        let holidayNote: String
    }

    struct HuntingHours: Decodable {
        let minutesBeforeSunrise: Double
        let minutesAfterSunset: Double
        let note: String
    }

    struct Group: Decodable, Identifiable {
        let id: String
        let name: String
        let start: String
        let end: String
        let species: [String]
    }

    struct Limit: Decodable, Identifiable {
        var id: String { species }
        let species: String
        let limit: String
    }

    struct DistanceRule: Decodable, Identifiable {
        let id: String
        let meters: Double
        let text: String
        let ref: String
    }

    struct Change: Decodable, Identifiable {
        var id: String { title }
        let title: String
        let status: String
        let ref: String
        let text: String
    }

    struct Avlak: Decodable, Identifiable {
        var id: String { name }
        let name: String
        let type: String
        let open: Bool
        let excluded: String?
        let note: String?
    }

    struct Override: Decodable, Identifiable {
        let id: String
        let name: String
        let status: ZoneStatus
        let buffer: Double
        let ref: String
        let note: String
        let polygon: [[Double]]

        var coordinates: [CLLocationCoordinate2D] {
            polygon.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        }
    }

    struct ClosedUnit: Decodable {
        let label: String
        let name: String
        let ref: String
    }

    struct KeyRule: Decodable, Identifiable {
        var id: String { title }
        let title: String
        let text: String
        let ref: String
    }

    struct ProtectedAreas: Decodable {
        let tabiatParki: [String]
        let tabiatKorumaAlani: [String]
        let yhgs: [String]
        let yhys: [String]
    }

    let title: String
    let decision: String
    let province: String
    let region: String
    let huntingDays: HuntingDays
    let huntingHours: HuntingHours
    let groups: [Group]
    let provinceBannedSpecies: [String]
    let provinceBannedNote: String
    let dailyLimits: [Limit]
    let limitsNote: String
    let distanceRules: [DistanceRule]
    let provinceChanges: [Change]
    let protectedAreas: ProtectedAreas
    let avlaklar: [Avlak]
    let unitAliases: [String: String]
    let closedUnits: [ClosedUnit]?
    let overrides: [Override]
    let keyRules: [KeyRule]

    static func load(bundle: Bundle = .main) throws -> Regulations {
        let url = try HuntingMap.resourceURL(for: "mak_2026_2027.json", in: bundle)
        return try JSONDecoder().decode(Regulations.self, from: Data(contentsOf: url))
    }

    func distanceRule(_ id: String) -> DistanceRule? { distanceRules.first { $0.id == id } }

    // MARK: - Zaman

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static var istanbulCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        c.locale = Locale(identifier: "tr_TR")
        return c
    }

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    func holiday(on date: Date) -> String? {
        let d = Self.dayString(date)
        return huntingDays.holidays.first { $0.date == d }?.name
    }

    /// Bugün sezonu açık olan gruplar (ilde yasak türler çıkarılmış).
    func groupsInSeason(on date: Date) -> [Group] {
        let d = Self.dayString(date)
        return groups.compactMap { g in
            guard d >= g.start, d <= g.end else { return nil }
            let allowed = g.species.filter { !provinceBannedSpecies.contains($0) }
            guard !allowed.isEmpty else { return nil }
            return Group(id: g.id, name: g.name, start: g.start, end: g.end, species: allowed)
        }
    }

    /// Bugün av günü olan gruplar ve türler.
    func huntableToday(on date: Date) -> [Group] {
        let cal = Self.istanbulCalendar
        let weekday = cal.component(.weekday, from: date)
        let inSeason = groupsInSeason(on: date)
        if huntingDays.weekdays.contains(weekday) || holiday(on: date) != nil {
            return inSeason
        }
        if weekday == 3 {
            // Salı: yaban domuzu ile 1. ve 3. grup kuşlar
            return inSeason.compactMap { g in
                guard huntingDays.extraTuesdayGroups.contains(g.id) else { return nil }
                if g.id == "memeli2_domuz" {
                    return Group(id: g.id, name: g.name + " (yalnız yaban domuzu)", start: g.start, end: g.end,
                                 species: g.species.filter { $0 == "Yaban domuzu" })
                }
                return g
            }
        }
        return []
    }

    func huntingWindow(on date: Date, at c: CLLocationCoordinate2D) -> (start: Date, end: Date)? {
        guard let t = Sun.times(on: date, latitude: c.latitude, longitude: c.longitude, calendar: Self.istanbulCalendar) else {
            return nil
        }
        return (t.sunrise.addingTimeInterval(-huntingHours.minutesBeforeSunrise * 60),
                t.sunset.addingTimeInterval(huntingHours.minutesAfterSunset * 60))
    }

    struct HuntDay: Identifiable {
        var id: Date { date }
        let date: Date
        let groups: [Group]
    }

    /// Bugünden itibaren sonraki av günleri.
    func upcomingHuntingDays(from date: Date, count: Int) -> [HuntDay] {
        let cal = Self.istanbulCalendar
        var out: [HuntDay] = []
        var d = cal.startOfDay(for: date)
        for _ in 0..<120 where out.count < count {
            let g = huntableToday(on: d.addingTimeInterval(12 * 3600))
            if !g.isEmpty { out.append(HuntDay(date: d, groups: g)) }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    func limit(for species: String) -> String? {
        dailyLimits.first { $0.species == species || $0.species.contains(species) }?.limit
    }
}
