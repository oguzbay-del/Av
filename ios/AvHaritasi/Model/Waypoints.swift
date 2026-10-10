import CoreLocation
import Foundation
import Observation

/// Haritaya konulan işaret (araç, pusu, av düştü, su, not). Yalnızca cihazda saklanır.
struct Waypoint: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case arac, pusu, avDustu, su, not

        var id: String { rawValue }

        var title: String {
            switch self {
            case .arac: return L("Araç")
            case .pusu: return L("Pusu")
            case .avDustu: return L("Av düştü")
            case .su: return L("Su / kaynak")
            case .not: return L("Not")
            }
        }

        /// SF Symbol (harita işaretinin glifi).
        var symbol: String {
            switch self {
            case .arac: return "car.fill"
            case .pusu: return "binoculars.fill"
            case .avDustu: return "scope"
            case .su: return "drop.fill"
            case .not: return "mappin"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var name: String
    var lat: Double
    var lon: Double
    var date: Date
    var note: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    func distance(from l: CLLocation) -> CLLocationDistance {
        CLLocation(latitude: lat, longitude: lon).distance(from: l)
    }
}

/// Yönlendirme için saf yardımcılar (internetsiz; birim testli).
enum WaypointMath {
    /// Yürüme hızı (4 km/sa) — m/sn.
    static let walkingSpeed = 4_000.0 / 3_600
    /// Bu mesafenin içinde "hedefe vardınız".
    static let arrivalRadius = 20.0

    /// Büyük daire başlangıç yönü (derece, gerçek kuzeyden saat yönünde, 0..<360).
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalize(atan2(y, x) * 180 / .pi)
    }

    static func normalize(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Telefonun baktığı yöne göre hedefin açısı (-180...180; 0 tam önde, + sağda).
    static func relativeAngle(bearing: Double, heading: Double) -> Double {
        let r = normalize(bearing - heading)
        return r > 180 ? r - 360 : r
    }

    /// 8 ana yönden hangisi (0 = kuzey, 1 = kuzeydoğu ... 7 = kuzeybatı).
    static func octant(_ bearing: Double) -> Int {
        Int((normalize(bearing) / 45).rounded()) % 8
    }

    static func directionName(_ bearing: Double) -> String {
        switch octant(bearing) {
        case 0: return L("Kuzey")
        case 1: return L("Kuzeydoğu")
        case 2: return L("Doğu")
        case 3: return L("Güneydoğu")
        case 4: return L("Güney")
        case 5: return L("Güneybatı")
        case 6: return L("Batı")
        default: return L("Kuzeybatı")
        }
    }

    /// 4 km/sa yürüyüşle süre (dakika, yukarı yuvarlanmış; en az 1).
    static func etaMinutes(meters: Double) -> Int {
        max(1, Int((max(0, meters) / walkingSpeed / 60).rounded(.up)))
    }

    /// (saat, dakika) — biçimlendirmeden bağımsız test için.
    static func etaParts(meters: Double) -> (hours: Int, minutes: Int) {
        let m = etaMinutes(meters: meters)
        return (m / 60, m % 60)
    }

    static func formatETA(meters: Double) -> String {
        let p = etaParts(meters: meters)
        if p.hours == 0 { return L("~%@ dk", String(p.minutes)) }
        if p.minutes == 0 { return L("~%@ sa", String(p.hours)) }
        return L("~%@ sa %@ dk", String(p.hours), String(p.minutes))
    }

    /// GPX 1.1 (yalnızca <wpt>), XML kaçışlı.
    static func gpx(_ waypoints: [Waypoint]) -> String {
        let iso = ISO8601DateFormatter()
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Av Haritasi" xmlns="http://www.topografix.com/GPX/1/1">

        """
        for w in waypoints {
            s += "<wpt lat=\"\(w.lat)\" lon=\"\(w.lon)\"><time>\(iso.string(from: w.date))</time>"
            s += "<name>\(xmlEscape(w.name))</name>"
            if let n = w.note, !n.isEmpty { s += "<desc>\(xmlEscape(n))</desc>" }
            s += "<type>\(w.kind.rawValue)</type></wpt>\n"
        }
        s += "</gpx>\n"
        return s
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// İşaretler: Application Support/isaretler.json (iOS dosya koruması, yedeğe alınmaz).
@MainActor
@Observable
final class WaypointStore {
    static let maxCount = 200

    private(set) var items: [Waypoint] = []
    /// Yönlendirilen işaret (nil: yönlendirme yok).
    var guidingID: UUID?

    @ObservationIgnored private let url: URL

    var guiding: Waypoint? { guidingID.flatMap { id in items.first { $0.id == id } } }
    var isFull: Bool { items.count >= Self.maxCount }

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("isaretler.json")
        if let data = try? Data(contentsOf: self.url),
           let list = try? JSONDecoder().decode([Waypoint].self, from: data) {
            items = list
        }
    }

    /// Varsayılan ad: tür adı (aynı türden varsa numaralı: "Pusu 2").
    func defaultName(for kind: Waypoint.Kind) -> String {
        let n = items.filter { $0.kind == kind }.count
        return n == 0 ? kind.title : "\(kind.title) \(n + 1)"
    }

    @discardableResult
    func add(kind: Waypoint.Kind, name: String? = nil, coordinate: CLLocationCoordinate2D,
             note: String? = nil, date: Date = Date()) -> Waypoint? {
        guard !isFull else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = Waypoint(kind: kind, name: trimmed.isEmpty ? defaultName(for: kind) : trimmed,
                         lat: coordinate.latitude, lon: coordinate.longitude, date: date,
                         note: n?.isEmpty == false ? n : nil)
        items.append(w)
        save()
        return w
    }

    func rename(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = items.firstIndex(where: { $0.id == id }), items[i].name != t else { return }
        items[i].name = t
        save()
    }

    func setNote(_ id: UUID, _ note: String) {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }), (items[i].note ?? "") != t else { return }
        items[i].note = t.isEmpty ? nil : t
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        if guidingID == id { guidingID = nil }
        save()
    }

    /// Konuma göre yakından uzağa (konum yoksa yeniden eskiye).
    func sorted(from location: CLLocation?) -> [Waypoint] {
        guard let location else { return items.sorted { $0.date > $1.date } }
        return items.sorted { $0.distance(from: location) < $1.distance(from: location) }
    }

    /// GPX dosyası (geçici klasörde); Paylaş menüsüyle dışa aktarılır.
    func gpxFile(_ list: [Waypoint]? = nil) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("isaretler_\(f.string(from: Date())).gpx")
        try? WaypointMath.gpx(list ?? items).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var u = url
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try u.setResourceValues(v)
        } catch {
            Log.konum.error("İşaretler kaydedilemedi: \(error.localizedDescription, privacy: .public)")
        }
    }
}
