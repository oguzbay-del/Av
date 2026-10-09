import CoreLocation
import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers

/// Saha testi olayı (docs/saha_test_protokolu.md). Koordinatlar 4 ondalığa (~10 m) yuvarlanır ve
/// yalnızca cihazda kalır; hava durumu olaylarında koordinat yoktur.
enum FieldEvent: Codable, Sendable, Equatable {
    enum PowerTier: String, Codable, Sendable { case yakin, uzak, pusu }

    case appLaunch(version: String, build: String, os: String, lowPower: Bool)
    case foreground
    case background
    /// accuracy: yatay doğruluk (m), age: ölçümün yaşı (s), speed: m/s (bilinmiyorsa nil)
    case fix(lat: Double, lon: Double, accuracy: Int, age: Double, speed: Double?)
    case levelChange(from: Int, to: Int, title: String)
    case alert(level: Int, title: String, background: Bool)
    case staleStart(age: Int)
    case staleEnd
    case locationError(code: Int, message: String)
    case powerTier(PowerTier)
    case geofenceArmed(radius: Int)
    case geofenceExit(state: String)
    case geofenceStopped
    case backgroundSession(active: Bool)
    case demo(active: Bool)
    case weatherOK
    case weatherFail(message: String)
    case network(online: Bool, expensive: Bool)
    case liveActivity(active: Bool, reason: String?)

    /// Tek bir konum ölçümünden olay (koordinat 4 ondalığa yuvarlanır).
    static func location(_ loc: CLLocation, now: Date = Date()) -> FieldEvent {
        func r(_ v: Double, _ p: Double) -> Double { (v * p).rounded() / p }
        return .fix(lat: r(loc.coordinate.latitude, 10_000), lon: r(loc.coordinate.longitude, 10_000),
                    accuracy: Int(loc.horizontalAccuracy.rounded()), age: r(now.timeIntervalSince(loc.timestamp), 10),
                    speed: loc.speed >= 0 ? r(loc.speed, 10) : nil)
    }

    /// Durum olayları: aynı değer art arda gelirse yazılmaz.
    fileprivate var stateKey: (key: String, value: String)? {
        switch self {
        case .powerTier(let t): (key: "power", value: t.rawValue)
        case .backgroundSession(let a): (key: "bgSession", value: "\(a)")
        case .network(let o, let e): (key: "network", value: "\(o)-\(e)")
        case .liveActivity(let a, _): (key: "liveActivity", value: "\(a)")
        case .demo(let a): (key: "demo", value: "\(a)")
        case .foreground: (key: "phase", value: "fg")
        case .background: (key: "phase", value: "bg")
        case .geofenceArmed(let r): (key: "geofence", value: "\(r)")
        case .geofenceStopped: (key: "geofence", value: "off")
        default: nil
        }
    }

    fileprivate var osLevel: OSLogType {
        switch self {
        case .locationError, .weatherFail: .error
        case .fix: .debug
        case .foreground, .background, .powerTier, .geofenceArmed, .geofenceStopped, .backgroundSession,
             .network, .weatherOK, .liveActivity: .info
        default: .default
        }
    }

    private static func levelName(_ raw: Int) -> String {
        switch raw {
        case 1: "güvenli"
        case 2: "dikkat"
        case 3: "yasak"
        default: "bilinmiyor"
        }
    }

    /// Paylaşılan .txt dosyası için Türkçe açıklama.
    var summary: String {
        switch self {
        case let .appLaunch(v, b, sys, low):
            "Uygulama açıldı — sürüm \(v) (\(b)), \(sys)\(low ? ", Düşük Güç Modu açık" : "")"
        case .foreground: "Ön plana geldi"
        case .background: "Arka plana geçti"
        case let .fix(lat, lon, acc, age, speed):
            "Konum \(String(format: "%.4f, %.4f", lat, lon)) ±\(acc) m, \(String(format: "%.1f", age)) s önce"
                + (speed.map { String(format: ", %.1f m/s", $0) } ?? "")
        case let .levelChange(from, to, title):
            "Seviye \(Self.levelName(from)) → \(Self.levelName(to)): \(title)"
        case let .alert(level, title, bg):
            "UYARI (\(Self.levelName(level)), \(bg ? "arka plan bildirimi" : "ön plan")): \(title)"
        case .staleStart(let age): "GPS kesildi: son konum \(age) s önce"
        case .staleEnd: "GPS geri geldi"
        case let .locationError(code, message): "Konum hatası (CLError \(code)): \(message)"
        case .powerTier(let t):
            switch t {
            case .yakin: "GPS kademesi: yakın (tam hassasiyet, 5 m)"
            case .uzak: "GPS kademesi: uzak (10 m, 20 m filtre)"
            case .pusu: "GPS kademesi: pusu (10 m, 15 m filtre)"
            }
        case .geofenceArmed(let r): "Güvenli daire kuruldu: \(r) m"
        case .geofenceExit(let s): "Güvenli daireden çıkış (\(s))"
        case .geofenceStopped: "Güvenli daire kaldırıldı"
        case .backgroundSession(let a): a ? "Arka plan konum oturumu başladı" : "Arka plan konum oturumu kapalı"
        case .demo(let a): a ? "Demo modu başladı" : "Demo modu bitti"
        case .weatherOK: "Hava durumu alındı"
        case .weatherFail(let m): "Hava durumu alınamadı: \(m)"
        case let .network(online, expensive):
            online ? "İnternet var\(expensive ? " (hücresel/ücretli)" : "")" : "İnternet yok (çevrimdışı)"
        case let .liveActivity(a, reason):
            (a ? "Live Activity başladı" : "Live Activity bitti") + (reason.map { " (\($0))" } ?? "")
        }
    }
}

struct FieldLogEntry: Codable, Sendable {
    var t: Date
    var e: FieldEvent
}

/// Saha kaydı: uygulamanın sahada ne yaptığını (konum, seviye, uyarı, GPS kesintisi, pil kademesi,
/// güvenli daire...) olay olay kaydeder. Bellekte son ~2000 olay; diskte
/// Application Support/tani/saha_kaydi.jsonl (2 MB'ta saha_kaydi.1.jsonl'e döner, en çok ~4 MB).
/// 7 günden eski olaylar açılışta silinir. Dosyalar tam koruma (.complete) ile şifreli ve iCloud
/// yedeğine alınmaz; kilitliyken yazılamayan olaylar bellekte bekletilip kilit açılınca yazılır.
/// Her olay ayrıca os.Logger'a ("saha" kategorisi) aktarılır (kayıt kapalıyken de).
/// Herhangi bir iş parçacığından çağrılabilir.
final class FieldLog: Sendable {
    static let shared = FieldLog()

    static let enabledKey = "fieldLogEnabled"
    static let capacity = 2_000
    static let rotateBytes: UInt64 = 2 * 1024 * 1024
    static let maxAge: TimeInterval = 7 * 24 * 3600
    /// Konum ölçümleri en çok 10 sn'de bir (doğruluk kademesi ya da seviye değişmedikçe).
    static let fixInterval: TimeInterval = 10

    /// Varsayılan kapalı (Xcode, TestFlight ve App Store derlemelerinde aynı). Kullanıcı açarsa seçim
    /// UserDefaults'ta (`enabledKey`) saklanır; saha testinden önce elle açılır (docs/saha_test_protokolu.md K12).
    static let defaultEnabled = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private struct State: Sendable {
        var ring: [FieldLogEntry] = []
        var pending: [FieldLogEntry] = []
        var lastFixTime: Date?
        var lastFixBucket = -1
        var levelChanged = false
        var lastState: [String: String] = [:]
        /// Eski olaylar silindi ve diskteki kayıt belleğe alındı mı.
        var prepared = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "av.saha-kaydi", qos: .utility)
    private let fileURL: URL
    private let oldFileURL: URL
    private let exportDir: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tani", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("saha_kaydi.jsonl")
        oldFileURL = dir.appendingPathComponent("saha_kaydi.1.jsonl")
        exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("saha_paylasim", isDirectory: true)
        UserDefaults.standard.register(defaults: [Self.enabledKey: Self.defaultEnabled])
        // Eski sürümlerin TestFlight algılama kaydı (artık kullanılmıyor)
        UserDefaults.standard.removeObject(forKey: "fieldLogTestFlight")
        queue.async { [self] in
            prepareIfNeeded()
            NetworkState.shared.observe { [self] s in log(.network(online: s.online, expensive: s.expensive)) }
        }
    }

    // MARK: Kayıt

    /// Açılış olayı (sürüm, iOS, Düşük Güç Modu).
    func logLaunch() {
        let info = Bundle.main.infoDictionary
        let p = ProcessInfo.processInfo
        log(.appLaunch(version: info?["CFBundleShortVersionString"] as? String ?? "?",
                       build: info?["CFBundleVersion"] as? String ?? "?",
                       os: p.operatingSystemVersionString, lowPower: p.isLowPowerModeEnabled))
    }

    func log(_ event: FieldEvent, at date: Date = Date()) {
        let enabled = isEnabled
        let accepted = state.withLock { s -> Bool in
            switch event {
            case .fix(_, _, let accuracy, _, _):
                let bucket = Self.accuracyBucket(accuracy)
                if let last = s.lastFixTime, date.timeIntervalSince(last) < Self.fixInterval,
                   bucket == s.lastFixBucket, !s.levelChanged {
                    return false
                }
                s.lastFixTime = date
                s.lastFixBucket = bucket
                s.levelChanged = false
            case .levelChange:
                s.levelChanged = true
            default:
                if let k = event.stateKey {
                    if s.lastState[k.key] == k.value { return false }
                    s.lastState[k.key] = k.value
                }
            }
            guard enabled else { return true }
            let entry = FieldLogEntry(t: date, e: event)
            s.ring.append(entry)
            if s.ring.count > Self.capacity { s.ring.removeFirst(s.ring.count - Self.capacity) }
            s.pending.append(entry)
            if s.pending.count > Self.capacity { s.pending.removeFirst(s.pending.count - Self.capacity) }
            return true
        }
        guard accepted else { return }
        let text = event.summary
        if case .fix = event {
            Log.saha.debug("\(text, privacy: .private)")
        } else {
            Log.saha.log(level: event.osLevel, "\(text, privacy: .public)")
        }
        if enabled { queue.async { [self] in flush() } }
    }

    /// Kaydı ve paylaşım kopyalarını sil.
    func clear() {
        state.withLock { s in
            s.ring = []
            s.pending = []
        }
        queue.async { [self] in
            for u in [fileURL, oldFileURL, exportDir] { try? FileManager.default.removeItem(at: u) }
        }
    }

    /// Paylaşım dosyası üret (geçici klasörde; her paylaşımda ve "Kaydı sil"de temizlenir).
    func export(_ kind: FieldLogExport) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            queue.async { [self] in c.resume(with: Result { try writeExport(kind) }) }
        }
    }

    // MARK: Disk (yalnızca `queue` üzerinde)

    private static func accuracyBucket(_ a: Int) -> Int {
        switch a {
        case ..<11: 0
        case ..<31: 1
        case ..<101: 2
        case ..<501: 3
        default: 4
        }
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func flush() {
        prepareIfNeeded()
        let batch = state.withLock { s -> [FieldLogEntry] in
            defer { s.pending = [] }
            return s.pending
        }
        guard !batch.isEmpty else { return }
        do {
            try append(batch)
        } catch {
            // Cihaz kilitli (tam koruma): bellekte beklet, sonraki olayda yeniden dene
            state.withLock { s in s.pending = Array((batch + s.pending).suffix(Self.capacity)) }
        }
    }

    private func append(_ entries: [FieldLogEntry]) throws {
        let enc = Self.encoder()
        var data = Data()
        for e in entries {
            data.append(try enc.encode(e))
            data.append(0x0A)
        }
        let fm = FileManager.default
        if let size = Self.fileSize(fileURL), size > 0, size + UInt64(data.count) > Self.rotateBytes {
            try? fm.removeItem(at: oldFileURL)
            try fm.moveItem(at: fileURL, to: oldFileURL)
        }
        if !fm.fileExists(atPath: fileURL.path) { try create(fileURL) }
        let h = try FileHandle(forWritingTo: fileURL)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data)
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return try? h.seekToEnd()
    }

    private func create(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        Self.excludeFromBackup(url)
    }

    private static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// Dosyadaki satırlar (tarihiyle); okunamazsa nil (ör. cihaz kilitli).
    private func readLines(_ url: URL) -> [(date: Date, line: Data)]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = Self.decoder()
        return data.split(separator: 0x0A).compactMap { line in
            guard let e = try? dec.decode(FieldLogEntry.self, from: Data(line)) else { return nil }
            return (e.t, Data(line))
        }
    }

    /// Açılışta (ilk okunabildiğinde) 7 günden eski olayları sil, kaydı belleğe al.
    private func prepareIfNeeded() {
        guard !state.withLock({ $0.prepared }) else { return }
        try? FileManager.default.removeItem(at: exportDir)
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var kept: [Data] = []
        for url in [oldFileURL, fileURL] {
            guard let lines = readLines(url) else { return }
            let fresh = lines.filter { $0.date >= cutoff }
            if fresh.count != lines.count {
                if fresh.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    let data = fresh.reduce(into: Data()) { $0.append($1.line); $0.append(0x0A) }
                    try? data.write(to: url, options: [.atomic, .completeFileProtection])
                    Self.excludeFromBackup(url)
                }
            }
            kept += fresh.map(\.line)
        }
        let dec = Self.decoder()
        let loaded = kept.suffix(Self.capacity).compactMap { try? dec.decode(FieldLogEntry.self, from: $0) }
        state.withLock { s in
            s.ring = Array((loaded + s.ring).suffix(Self.capacity))
            s.prepared = true
        }
    }

    private func writeExport(_ kind: FieldLogExport) throws -> URL {
        flush()
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var lines: [Data] = []
        var readable = true
        for url in [oldFileURL, fileURL] {
            guard let l = readLines(url) else { readable = false; break }
            lines += l.filter { $0.date >= cutoff }.map(\.line)
        }
        // Dosya okunamazsa (ya da henüz yazılamadıysa) bellekteki son olaylar
        let memory = state.withLock { $0.ring }
        if !readable || lines.isEmpty {
            let enc = Self.encoder()
            lines = memory.compactMap { try? enc.encode($0) }
        } else {
            let pending = state.withLock { $0.pending }
            let enc = Self.encoder()
            lines += pending.compactMap { try? enc.encode($0) }
        }

        let fm = FileManager.default
        try? fm.removeItem(at: exportDir)
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let tz = TimeZone(identifier: "Europe/Istanbul") ?? .current
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = tz
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let base = "saha_kaydi_\(stamp.string(from: Date()))"

        let data: Data
        let url: URL
        switch kind {
        case .jsonl:
            url = exportDir.appendingPathComponent(base + ".jsonl")
            data = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        case .text:
            url = exportDir.appendingPathComponent(base + ".txt")
            let dec = Self.decoder()
            let entries = lines.compactMap { try? dec.decode(FieldLogEntry.self, from: $0) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "tr_TR")
            f.timeZone = tz
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let info = Bundle.main.infoDictionary
            var text = "Av Haritası — Saha kaydı\n"
            text += "Sürüm: \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))\n"
            text += "Sistem: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            text += "Saat dilimi: Europe/Istanbul (yerel saat)\n"
            text += "Olay sayısı: \(entries.count)\n"
            text += "Not: konumlar 4 ondalığa (~10 m) yuvarlanmıştır; konum ölçümleri en çok 10 sn'de bir yazılır.\n\n"
            for e in entries { text += "\(f.string(from: e.t))  \(e.e.summary)\n" }
            data = Data(text.utf8)
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

/// Ayarlar › Gelişmiş › Tanı raporları'ndaki paylaşım: dosya ancak paylaş menüsü istediğinde üretilir.
enum FieldLogExport: String, CaseIterable, Sendable, Transferable {
    case text, jsonl

    var fileName: String { self == .text ? "saha_kaydi.txt" : "saha_kaydi.jsonl" }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { item in
            SentTransferredFile(try await FieldLog.shared.export(item))
        }
    }
}
