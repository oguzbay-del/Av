import CoreLocation
import Foundation

/// Yürüyüş izi kaydı ve GPX dışa aktarma. Kayıtlar yalnızca cihazda (Application Support/izler).
/// Olası bir itirazda o gün nerede bulunduğunuzu gösteren kayıt da olur.
@MainActor
final class TrackLog: ObservableObject {
    struct Point: Codable {
        let lat: Double
        let lon: Double
        let alt: Double?
        let acc: Double
        let time: Date
    }

    struct Track: Codable, Identifiable {
        var id = UUID()
        var started: Date
        var points: [Point] = []

        var distance: CLLocationDistance {
            zip(points, points.dropFirst()).reduce(0) { sum, pair in
                sum + CLLocation(latitude: pair.0.lat, longitude: pair.0.lon)
                    .distance(from: CLLocation(latitude: pair.1.lat, longitude: pair.1.lon))
            }
        }
    }

    @Published private(set) var current: Track?
    @Published private(set) var saved: [Track] = []

    var isRecording: Bool { current != nil }

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("izler", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        saved = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Track.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    func start() {
        current = Track(started: Date())
    }

    func stop() {
        guard let t = current else { return }
        current = nil
        guard t.points.count > 1 else { return }
        try? JSONEncoder().encode(t).write(to: dir.appendingPathComponent("\(t.id).json"), options: .atomic)
        saved.insert(t, at: 0)
    }

    /// Yalnızca yeterince doğru ve 10 m'den fazla yer değiştiren noktaları ekle.
    func append(_ loc: CLLocation) {
        guard var t = current, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 50 else { return }
        if let last = t.points.last,
           CLLocation(latitude: last.lat, longitude: last.lon).distance(from: loc) < 10 { return }
        t.points.append(Point(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                              alt: loc.verticalAccuracy > 0 ? loc.altitude : nil,
                              acc: loc.horizontalAccuracy, time: loc.timestamp))
        current = t
    }

    func delete(_ t: Track) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(t.id).json"))
        saved.removeAll { $0.id == t.id }
    }

    /// GPX 1.1 dosyası (geçici klasörde); Paylaş menüsüyle dışa aktarılır.
    func gpxFile(for t: Track) -> URL {
        let iso = ISO8601DateFormatter()
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Av Haritasi" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>Av Haritası \(iso.string(from: t.started))</name><trkseg>

        """
        for p in t.points {
            s += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\">"
            if let a = p.alt { s += "<ele>\(String(format: "%.1f", a))</ele>" }
            s += "<time>\(iso.string(from: p.time))</time></trkpt>\n"
        }
        s += "</trkseg></trk></gpx>\n"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av_izi_\(f.string(from: t.started)).gpx")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
