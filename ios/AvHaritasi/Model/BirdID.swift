import AVFoundation
import CoreLocation
import Foundation
import SoundAnalysis

/// Kuş sesinden tür tahmini.
///
/// 1. **BirdNET API** (önerilen): Cornell Lab'in önceden eğitilmiş BirdNET modeli
///    (6.000+ tür) `server/birdnet-api` sunucusunda çalışır; uygulama kaydı oraya
///    gönderir. Model lisansı: CC BY-NC-SA 4.0 (ticari olmayan kullanım).
/// 2. **Cihazda (internetsiz) yedek**: Apple SoundAnalysis yerleşik sınıflandırıcısı;
///    tür değil genel grup verir (ördek, kaz, karga, baykuş, güvercin...).
struct BirdDetection: Identifiable, Equatable {
    let id = UUID()
    let scientificName: String?
    let commonName: String
    let confidence: Double
    let start: Double?
    let end: Double?
    let source: Source

    enum Source: String {
        case birdnet = "BirdNET", device = "Cihaz (genel)"
        var title: String { self == .birdnet ? "BirdNET" : L("Cihaz (genel)") }
    }
}

/// Tanınan türün MAK 2026-27'ye göre durumu.
struct BirdLegalStatus {
    enum Level { case allowedToday, allowedNotToday, provinceBanned, protected, notGame, falconry, unknown }
    let level: Level
    let turkishName: String?
    let text: String
}

extension Regulations {
    func legalStatus(scientific: String?, on date: Date) -> BirdLegalStatus {
        guard let sci = scientific else {
            return BirdLegalStatus(level: .unknown, turkishName: nil, text: L("Tür belirlenemedi; avlanmadan önce türden emin olun."))
        }
        if let tr = huntableLatin?[sci] {
            if falconryOnly?.contains(tr) == true {
                return BirdLegalStatus(level: .falconry, turkishName: tr,
                                       text: L("Yalnızca atmacacılık kapsamında (Madde 5/5); tüfekle avlanamaz."))
            }
            if provinceBannedSpecies.contains(tr) {
                return BirdLegalStatus(level: .provinceBanned, turkishName: tr, text: L("%@'da avı yasak (Tablo-1).", LD(province)))
            }
            let today = huntableToday(on: date).flatMap(\.species)
            if today.contains(tr) {
                let lim = limit(for: tr).map { " " + L("Günlük limit: %@.", LD($0)) } ?? ""
                return BirdLegalStatus(level: .allowedToday, turkishName: tr, text: L("Bugün avlanabilir (EK-2).") + lim)
            }
            let g = group(of: tr)
            let season = g.map { " " + L("Sezon: %@ – %@.", $0.start, $0.end) } ?? ""
            return BirdLegalStatus(level: .allowedNotToday, turkishName: tr,
                                   text: L("Av türü (EK-2) ama bugün avlanamaz (sezon ya da av günü dışı).") + season)
        }
        if let tr = protectedLatin?[sci] {
            return BirdLegalStatus(level: .protected, turkishName: tr, text: L("MAK'ça koruma altında (EK-1); avlanamaz."))
        }
        return BirdLegalStatus(level: .notGame, turkishName: nil,
                               text: L("Avına izin verilen türler (EK-2) arasında değil; avlanamaz."))
    }
}

@MainActor
final class BirdIDModel: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case recording(progress: Double)
        case analyzing
        case done
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var detections: [BirdDetection] = []
    @Published private(set) var note: String?

    /// Kayıt ya da analiz sürüyor (yöntem değiştirilemez).
    var isBusy: Bool {
        if case .recording = state { return true }
        return state == .analyzing
    }

    static let duration: TimeInterval = 15
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var started = Date()
    private let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("kus_sesi.wav")

    var serverURL: String {
        UserDefaults.standard.string(forKey: "birdnetURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func start(location: CLLocationCoordinate2D?) {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else {
                    self.state = .failed(L("Mikrofon izni verilmedi. Ayarlar'dan izin verin."))
                    return
                }
                self.beginRecording(location: location)
            }
        }
    }

    private func beginRecording(location: CLLocationCoordinate2D?) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            let r = try AVAudioRecorder(url: fileURL, settings: settings)
            r.isMeteringEnabled = true
            r.record(forDuration: Self.duration)
            recorder = r
            started = Date()
            detections = []
            note = nil
            state = .recording(progress: 0)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick(location: location) }
            }
        } catch {
            state = .failed(L("Kayıt başlatılamadı: %@", error.localizedDescription))
        }
    }

    private func tick(location: CLLocationCoordinate2D?) {
        guard let r = recorder else { return }
        r.updateMeters()
        level = max(0, min(1, (r.averagePower(forChannel: 0) + 60) / 60))
        let p = Date().timeIntervalSince(started) / Self.duration
        if p >= 1 || !r.isRecording {
            stop(location: location)
        } else {
            state = .recording(progress: p)
        }
    }

    func stop(location: CLLocationCoordinate2D?) {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .analyzing
        Task { await analyze(location: location) }
    }

    private func analyze(location: CLLocationCoordinate2D?) async {
        var results: [BirdDetection] = []
        var notes: [String] = []
        if !serverURL.isEmpty {
            do {
                results = try await BirdNETClient(base: serverURL).analyze(file: fileURL, location: location, date: AppClock.now())
                if results.isEmpty { notes.append(L("BirdNET kayıtta yeterince emin olduğu bir kuş bulamadı.")) }
            } catch {
                notes.append(L("BirdNET sunucusuna ulaşılamadı (%@); cihazdaki genel sınıflandırıcı kullanıldı.", error.localizedDescription))
            }
        } else {
            notes.append(L("BirdNET sunucu adresi girilmedi (Ayarlar). Cihazdaki genel sınıflandırıcı kullanıldı; tür değil grup verir."))
        }
        if results.isEmpty {
            results = (try? await DeviceSoundClassifier.classify(file: fileURL)) ?? []
        }
        detections = results
        note = notes.isEmpty ? nil : notes.joined(separator: " ")
        state = .done
    }
}

/// `server/birdnet-api` ile konuşan istemci.
struct BirdNETClient {
    let base: String

    func analyze(file: URL, location: CLLocationCoordinate2D?, date: Date) async throws -> [BirdDetection] {
        guard var url = URL(string: base) else { throw URLError(.badURL) }
        url.append(path: "analyze")
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        let boundary = "AvHaritasi-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key = Keychain.get("birdnetKey"), !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-API-Key")
        }

        var fields: [String: String] = ["min_conf": "0.25"]
        if let c = location {
            fields["lat"] = String(format: "%.4f", c.latitude)
            fields["lon"] = String(format: "%.4f", c.longitude)
        }
        // BirdNET "48 haftalık yıl": ayda 4 hafta
        let cal = Regulations.istanbulCalendar
        let m = cal.component(.month, from: date), d = cal.component(.day, from: date)
        fields["week"] = String((m - 1) * 4 + min(4, (d - 1) / 7 + 1))

        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"kayit.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Raw: Decodable {
            struct D: Decodable {
                let scientific_name: String
                let common_name: String
                let confidence: Double
                let start_time: Double?
                let end_time: Double?
            }
            let detections: [D]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        // Aynı tür birden çok 3 sn'lik dilimde çıkabilir: en yüksek güveni tut
        var best: [String: Raw.D] = [:]
        for d in raw.detections where (best[d.scientific_name]?.confidence ?? 0) < d.confidence {
            best[d.scientific_name] = d
        }
        return best.values.sorted { $0.confidence > $1.confidence }.map {
            BirdDetection(scientificName: $0.scientific_name, commonName: $0.common_name, confidence: $0.confidence,
                          start: $0.start_time, end: $0.end_time, source: .birdnet)
        }
    }
}

/// Apple'ın cihazdaki yerleşik ses sınıflandırıcısı (internetsiz). Tür düzeyinde değildir.
enum DeviceSoundClassifier {
    /// Yerleşik etiketlerden kuşlarla ilgili olanlar → (Türkçe ad, temsilci bilimsel ad).
    static let birdLabels: [String: (String, String?)] = [
        "bird": (L("Kuş (tür belirsiz)"), nil),
        "bird_vocalization": (L("Kuş ötüşü (tür belirsiz)"), nil),
        "bird_flapping": (L("Kuş kanat sesi"), nil),
        "chirp_tweet": (L("Cıvıltı (ötücü kuş)"), nil),
        "duck": (L("Ördek (tür belirsiz)"), nil),
        "goose": (L("Kaz (tür belirsiz)"), nil),
        "crow": (L("Karga (tür belirsiz)"), nil),
        "owl": (L("Baykuş — koruma altında"), "Strix aluco"),
        "pigeon_dove": (L("Güvercin / üveyik grubu"), nil),
        "chicken_rooster": (L("Tavuk / horoz"), nil),
        "turkey": (L("Hindi"), nil),
        "gull_seagull": (L("Martı — koruma altında"), "Larus michahellis"),
    ]

    static func classify(file: URL) async throws -> [BirdDetection] {
        let analyzer = try SNAudioFileAnalyzer(url: file)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let observer = Collector()
        try analyzer.add(request, withObserver: observer)
        _ = await analyzer.analyze()
        return observer.best
            .filter { birdLabels[$0.key] != nil && $0.value >= 0.3 }
            .sorted { $0.value > $1.value }
            .map { key, conf in
                let (trName, sci) = birdLabels[key]!
                let name = trName
                return BirdDetection(scientificName: sci, commonName: name, confidence: conf, start: nil, end: nil, source: .device)
            }
    }

    private final class Collector: NSObject, SNResultsObserving {
        var best: [String: Double] = [:]
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            for c in r.classifications where c.confidence > (best[c.identifier] ?? 0) {
                best[c.identifier] = c.confidence
            }
        }
    }
}
