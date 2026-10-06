import CoreLocation
import Foundation

/// Avlanan hayvanların kaydı ve MAK Tablo-4 günlük limit kontrolü.
/// Kayıtlar yalnızca cihazda (Application Support/av_defteri.json) tutulur.
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

    @Published private(set) var entries: [Entry] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("av_defteri.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
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

    /// Son günlerin özeti (en yeni gün önce).
    func days(limit: Int = 14) -> [DaySummary] {
        let cal = Regulations.istanbulCalendar
        let grouped = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).prefix(limit).map { day in
            let bySpecies = Dictionary(grouping: grouped[day] ?? []) { $0.species }
                .map { (species: $0.key, count: $0.value.reduce(0) { $0 + $1.count }) }
                .sorted { $0.species < $1.species }
            return DaySummary(day: day, items: bySpecies)
        }
    }
}
