import Foundation
import MetricKit
import os

/// Kategori bazlı günlük (Console.app / Xcode'da "AvHaritasi" alt sistemiyle süzülür).
enum Log {
    static let konum = Logger(subsystem: "com.example.avharitasi", category: "konum")
    static let cit = Logger(subsystem: "com.example.avharitasi", category: "geofence")
    static let ag = Logger(subsystem: "com.example.avharitasi", category: "ag")
}

/// MetricKit çökme / takılma / enerji raporları: yalnızca cihazda saklanır, kullanıcı isterse
/// Ayarlar › Tanı raporları'ndan paylaşır. Üçüncü taraf SDK ya da sunucu yok.
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()

    let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tani", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { save(p.jsonRepresentation(), prefix: "tani") }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { save(p.jsonRepresentation(), prefix: "olcum") }
    }

    private func save(_ data: Data, prefix: String) {
        let name = "\(prefix)-\(Int(Date().timeIntervalSince1970)).json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        // En fazla 30 dosya tut
        let files = reports.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in files.dropFirst(30) { try? FileManager.default.removeItem(at: f) }
    }

    var reports: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
