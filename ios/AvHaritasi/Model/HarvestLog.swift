import CoreLocation
import Foundation

/// Avlanan hayvanların kaydı ve MAK Tablo-4 günlük limit kontrolü.
/// Kayıtlar yalnızca cihazda (Application Support/av_defteri.json) tutulur. Güne ait isteğe bağlı "tüfek + fişek"
/// notu ayrı dosyada (av_defteri_donanim.json, Tüfeklerim gibi yedekten hariç) tutulur; tüfek silinse de not kalır.
@MainActor
final class HarvestLog: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let species: String
        let count: Int
        let latitude: Double?
        let longitude: Double?
    }

    struct LimitStatus {
        let used: Int
        let max: Int?          // nil = limitsiz
        let groupUsed: Int?
        let groupMax: Int?
        let groupName: String?

        var remaining: Int? {
            var r: Int?
            if let max { r = max - used }
            if let groupMax, let groupUsed { r = min(r ?? .max, groupMax - groupUsed) }
            return r
        }
        var isFull: Bool { (remaining ?? 1) <= 0 }
    }

    /// Bir av gününde kullanılan tüfek ve fişek (ikisi de isteğe bağlı, serbest metin; tüfek adı kayıt anındaki adıdır).
    struct DayGear: Codable, Equatable {
        var firearm: String?
        var ammo: String?

        /// Boşlukları kırpar; ikisi de boşsa nil (not silinir).
        var normalized: DayGear? {
            func clean(_ s: String?) -> String? {
                guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                return String(t.prefix(80))
            }
            let g = DayGear(firearm: clean(firearm), ammo: clean(ammo))
            return g.firearm == nil && g.ammo == nil ? nil : g
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// Gün anahtarı (İstanbul takvimi, "yyyy-MM-dd") → tüfek + fişek notu.
    @Published private(set) var gearByDay: [String: DayGear] = [:]

    let url: URL
    let gearURL: URL

    /// Uygulama: Application Support. Testler kendi klasörünü verir.
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("av_defteri.json")
        gearURL = directory.appendingPathComponent("av_defteri_donanim.json")
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
        if let data = try? Data(contentsOf: gearURL),
           let map = try? JSONDecoder().decode([String: DayGear].self, from: data) {
            gearByDay = map
        }
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    // MARK: Tüfek + fişek notu

    /// İstanbul saatine göre gün anahtarı ("2026-11-07").
    static func dayKey(_ date: Date) -> String { Regulations.dayString(date) }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Gün anahtarından o günün başlangıcı (İstanbul).
    static func day(fromKey key: String) -> Date? {
        keyFormatter.date(from: key).map { Regulations.istanbulCalendar.startOfDay(for: $0) }
    }

    func gear(on day: Date) -> DayGear? { gearByDay[Self.dayKey(day)] }

    /// Günün notunu yazar; boş not silinir.
    func setGear(_ g: DayGear?, on day: Date) {
        let key = Self.dayKey(day)
        let new = g?.normalized
        guard gearByDay[key] != new else { return }
        gearByDay[key] = new
        saveGear()
    }

    private func saveGear() {
        do {
            let data = try JSONEncoder().encode(gearByDay)
            try data.write(to: gearURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var u = gearURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try u.setResourceValues(values)
        } catch {
            // Disk hatası: bellekteki not korunur, bir sonraki kayıtta yeniden denenir
        }
    }

    func add(_ species: String, count: Int = 1, at c: CLLocationCoordinate2D?, date: Date) {
        entries.append(Entry(date: date, species: species, count: count, latitude: c?.latitude, longitude: c?.longitude))
        save()
    }

    /// Bugünkü son kaydı geri al.
    func undoLast(_ species: String, on day: Date) {
        let cal = Regulations.istanbulCalendar
        if let i = entries.lastIndex(where: { $0.species == species && cal.isDate($0.date, inSameDayAs: day) }) {
            entries.remove(at: i)
            save()
        }
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func count(_ species: String, on day: Date) -> Int {
        let cal = Regulations.istanbulCalendar
        return entries.filter { $0.species == species && cal.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.count }
    }

    func totalToday(on day: Date) -> Int {
        let cal = Regulations.istanbulCalendar
        return entries.filter { cal.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.count }
    }

    func status(for species: String, on day: Date, regs: Regulations) -> LimitStatus {
        let used = count(species, on: day)
        guard let rule = regs.limitRule(for: species) else {
            return LimitStatus(used: used, max: nil, groupUsed: nil, groupMax: nil, groupName: nil)
        }
        if rule.species.count == 1 {
            return LimitStatus(used: used, max: rule.max, groupUsed: nil, groupMax: nil, groupName: nil)
        }
        let groupUsed = rule.species.reduce(0) { $0 + count($1, on: day) }
        let perMax = rule.perSpecies?[species]
        return LimitStatus(used: used, max: perMax, groupUsed: groupUsed, groupMax: rule.max,
                           groupName: rule.species.joined(separator: ", "))
    }

    struct DaySummary: Identifiable {
        var id: Date { day }
        let day: Date
        let items: [(species: String, count: Int)]
    }

    /// Son günlerin özeti (en yeni gün önce); kaydı olmayan ama notu olan günde `items` boştur.
    func days(limit: Int = 14) -> [DaySummary] {
        let cal = Regulations.istanbulCalendar
        let grouped = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }
        // Yalnızca tüfek + fişek notu olan günler de listelenir
        let allDays = Set(grouped.keys).union(gearByDay.keys.compactMap(Self.day(fromKey:)))
        return allDays.sorted(by: >).prefix(limit).map { day in
            let bySpecies = Dictionary(grouping: grouped[day] ?? []) { $0.species }
                .map { (species: $0.key, count: $0.value.reduce(0) { $0 + $1.count }) }
                .sorted { $0.species < $1.species }
            return DaySummary(day: day, items: bySpecies)
        }
    }
}
