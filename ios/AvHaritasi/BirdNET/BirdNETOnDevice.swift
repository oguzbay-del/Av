import AVFoundation
import CoreML
import Foundation
import os

/// BirdNET V2.4 ile kuş sesinden tür tahmini — tamamen cihazda, internetsiz; ses telefondan çıkmaz.
///
/// Model (`BirdNET.mlpackage`, `tools/birdnet_coreml.py` ile üretilir) depoda yoktur; bir geliştirici
/// `ios/AvHaritasi/BirdNET/` klasörüne koyarsa Xcode onu `BirdNET.mlmodelc` olarak pakete ekler ve burada
/// çalışma anında yüklenir. Model yoksa uygulama yine derlenir; `isAvailable` false olur ve
/// `BirdIDModel` sunucuya ya da Apple'ın genel ses sınıflandırıcısına düşer.
///
/// Akış:
/// 1. Kayıt `AVAudioFile` ile okunur; 48 kHz mono değilse `AVAudioConverter` ile çevrilir.
/// 2. 3 sn'lik (144 000 örnek), 1,5 sn örtüşen pencerelere bölünür; kısa son pencere sıfırla doldurulur.
///    Spektrogram modelin içindedir; ölçek de modelde normalleştirilir.
/// 3. Model logit verir (`birdnet.output = logits` üst verisi); olasılık = sigmoid(logit).
/// 4. Tür başına en yüksek olasılık alınır; İstanbul'un o haftasında olası türler
///    (`BirdNET_Istanbul_Weeks.json`, BirdNET meta modeli ≥ 0,03) gösterilir, eşik 0,5.
actor BirdNETOnDevice {
    static let shared = BirdNETOnDevice()

    static let modelName = "BirdNET"
    static let speciesFile = "BirdNET_Istanbul_Weeks"
    static let sampleRate = 48_000.0
    static let windowSamples = 144_000
    static let classCount = 6522
    /// Gösterim eşiği ve "yüksek güven" eşiği.
    static let threshold = 0.5
    static let highConfidence = 0.7
    /// "Benzer korunan tür" karşılaştırması için eşiğin bu kadar altına kadar aday tutulur.
    static let candidateFloor = threshold - BirdLookalike.margin

    struct Analysis: Sendable {
        /// Bölgede o hafta olası ve eşiği geçen türler (yüksekten düşüğe).
        let detections: [BirdDetection]
        /// Eşiğin altındakiler ve bölge dışı MAK türleri dahil tüm adaylar (≥ `candidateFloor`).
        let candidates: [BirdDetection]
    }

    enum Failure: LocalizedError {
        case modelMissing
        case badModel(String)
        case audio(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing: return L("BirdNET modeli uygulamada yok.")
            case .badModel(let s): return L("BirdNET modeli açılamadı: %@", s)
            case .audio(let s): return L("Kayıt okunamadı: %@", s)
            }
        }
    }

    /// Model ve tür listesi uygulama paketinde mi (yüklemeden, ucuz denetim).
    static var isAvailable: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: speciesFile, withExtension: "json") != nil
    }

    private var model: MLModel?
    private var outputIsLogits = true
    private var outputName = "logits"
    private var species: [SpeciesList.Species] = []
    private let log = Logger(subsystem: "AvHaritasi", category: "birdnet")

    // MARK: Yükleme

    private func load() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            throw Failure.modelMissing
        }
        guard let listURL = Bundle.main.url(forResource: Self.speciesFile, withExtension: "json") else {
            throw Failure.badModel(L("tür listesi yok"))
        }
        do {
            let list = try JSONDecoder().decode(SpeciesList.self, from: Data(contentsOf: listURL))
            guard list.classes == Self.classCount else {
                throw Failure.badModel(L("tür listesi bu modelle uyumsuz"))
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let m = try MLModel(contentsOf: url, configuration: config)
            let meta = m.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            if let n = meta["birdnet.classes"], Int(n) != Self.classCount {
                throw Failure.badModel(L("sınıf sayısı uyumsuz"))
            }
            // Üst veri yoksa çıktı logit kabul edilir (referans TFLite gibi); "probabilities" ise sigmoid uygulanmaz
            outputIsLogits = meta["birdnet.output"] != "probabilities"
            outputName = m.modelDescription.outputDescriptionsByName["logits"] != nil
                ? "logits" : (m.modelDescription.outputDescriptionsByName.keys.first ?? "logits")
            species = list.species.filter { $0.i >= 0 && $0.i < Self.classCount && $0.weeks.count == 48 }
            model = m
            log.info("BirdNET yüklendi: \(self.species.count) tür, çıktı \(self.outputName, privacy: .public)")
            return m
        } catch let e as Failure {
            throw e
        } catch {
            log.error("BirdNET açılamadı: \(error.localizedDescription, privacy: .public)")
            throw Failure.badModel(error.localizedDescription)
        }
    }

    // MARK: Çözümleme

    func analyze(file: URL, date: Date) async throws -> Analysis {
        let model = try load()
        let samples = try Self.readMono48k(file)
        let week = BirdNETWeek.week(for: date)
        let starts = Self.windowStarts(count: samples.count)

        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        // Tür başına (en yüksek olasılık, pencere başlangıcı sn)
        var best = [Double](repeating: 0, count: species.count)
        var bestStart = [Double](repeating: 0, count: species.count)
        for start in starts {
            try Task.checkCancellation()
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
                let n = min(Self.windowSamples, samples.count - start)
                samples.withUnsafeBufferPointer { src in
                    for j in 0..<n { buf[j] = src[start + j] }
                }
                for j in n..<Self.windowSamples { buf[j] = 0 }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: input)])
            let out = try await model.prediction(from: provider)
            guard let scores = out.featureValue(for: outputName)?.multiArrayValue, scores.count >= Self.classCount else {
                throw Failure.badModel(L("beklenmeyen çıktı"))
            }
            for (k, s) in species.enumerated() {
                let raw = scores[s.i].doubleValue
                let p = outputIsLogits ? Self.sigmoid(raw) : raw
                if p > best[k] {
                    best[k] = p
                    bestStart[k] = Double(start) / Self.sampleRate
                }
            }
        }

        var detections: [BirdDetection] = []
        var candidates: [BirdDetection] = []
        for (k, s) in species.enumerated() where best[k] >= Self.candidateFloor {
            let d = BirdDetection(scientificName: s.mak ?? s.sci,
                                  commonName: AppLocale.isEnglish ? s.en : s.tr,
                                  confidence: best[k], start: bestStart[k], end: bestStart[k] + 3, source: .onDevice)
            candidates.append(d)
            if best[k] >= Self.threshold && s.isPresent(week: week) { detections.append(d) }
        }
        detections.sort { $0.confidence > $1.confidence }
        candidates.sort { $0.confidence > $1.confidence }
        return Analysis(detections: detections, candidates: candidates)
    }

    // MARK: Yardımcılar

    static func sigmoid(_ x: Double) -> Double {
        1 / (1 + exp(-min(15, max(-15, x))))
    }

    /// 1,5 sn adımlı pencere başlangıçları. Bir pencere, öncekinin içinde kalmayacak kadar (> 1,5 sn)
    /// ses kalıyorsa açılır: 15 sn → 0, 1,5 … 12 sn (9 pencere). `tools/birdnet_coreml.py` ile aynı.
    static func windowStarts(count: Int) -> [Int] {
        let step = windowSamples / 2
        guard count > 0 else { return [] }
        return stride(from: 0, to: count, by: step).filter { $0 == 0 || count - $0 > step }
    }

    /// Ses dosyası → 48 kHz mono Float32 örnekleri.
    static func readMono48k(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.audio(error.localizedDescription) }
        let src = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else {
            throw Failure.audio(L("kayıt boş"))
        }
        do { try file.read(into: inBuf) } catch { throw Failure.audio(error.localizedDescription) }

        if src.commonFormat == .pcmFormatFloat32, src.sampleRate == sampleRate, src.channelCount == 1,
           let ch = inBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        }
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: src, to: dst) else {
            throw Failure.audio(L("ses biçimi çevrilemedi"))
        }
        let capacity = AVAudioFrameCount((Double(inBuf.frameLength) * sampleRate / src.sampleRate).rounded(.up)) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: capacity) else {
            throw Failure.audio(L("ses biçimi çevrilemedi"))
        }
        // Giriş bloğu tek seferde tüm kaydı verir, sonra akış sonunu bildirir
        final class Feed: @unchecked Sendable { var done = false }
        let feed = Feed()
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
            if feed.done {
                inputStatus.pointee = .endOfStream
                return nil
            }
            feed.done = true
            inputStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, let ch = outBuf.floatChannelData else {
            throw Failure.audio(error?.localizedDescription ?? L("ses biçimi çevrilemedi"))
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }

    /// `BirdNET_Istanbul_Weeks.json`: İstanbul'da olası türler + MAK listesindeki tüm türler.
    struct SpeciesList: Decodable {
        struct Species: Decodable, Sendable {
            /// Model çıktısındaki sıra.
            let i: Int
            let sci: String
            let en: String
            let tr: String
            /// 48 karakter, "1" = o hafta İstanbul'da olası.
            let weeks: String
            /// MAK listesinde farklı bilimsel adla geçiyorsa o ad.
            let mak: String?

            func isPresent(week: Int) -> Bool {
                let idx = weeks.index(weeks.startIndex, offsetBy: max(0, min(47, week - 1)))
                return weeks[idx] == "1"
            }
        }

        let classes: Int
        let species: [Species]
    }
}

/// BirdNET'in "48 haftalık yılı": ayda 4 hafta (gün 1–7 → 1, 8–14 → 2, 15–21 → 3, 22+ → 4).
enum BirdNETWeek {
    static func week(for date: Date) -> Int {
        let cal = Regulations.istanbulCalendar
        let m = cal.component(.month, from: date), d = cal.component(.day, from: date)
        return (m - 1) * 4 + min(4, (d - 1) / 7 + 1)
    }
}

/// Güvenlik kuralı: bir av türü ile koruma altındaki bir tür arasında skor farkı 0,15'ten azsa
/// (ya da korunan tür daha yüksekse) av türü tahmini "Emin değil" olarak işaretlenir.
enum BirdLookalike {
    static let margin = 0.15

    static func mark(_ detections: [BirdDetection], candidates: [BirdDetection],
                     huntable: [String: String], protected: [String: String]) -> [BirdDetection] {
        let pool = candidates + detections
        return detections.map { d in
            guard let sci = d.scientificName, huntable[sci] != nil else { return d }
            let rival = pool
                .filter { c in
                    guard let cs = c.scientificName, cs != sci, protected[cs] != nil else { return false }
                    return c.confidence > d.confidence - margin
                }
                .max { $0.confidence < $1.confidence }
            guard let r = rival, let rs = r.scientificName else { return d }
            var out = d
            out.similarProtected = AppLocale.isEnglish ? r.commonName : (protected[rs] ?? r.commonName)
            return out
        }
    }
}
