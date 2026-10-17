import Observation
import UIKit

/// Videodan kuş tanıma (tamamen cihazda; video hiçbir yere gönderilmez):
/// 1. 10 sn'den uzun videoda ilk 5 dk saniyede bir kare taranır (kuş varlığı + keskinlik) ve en iyi
///    10 sn'lik bölüm seçilir (`VideoWindowSelector`); kullanıcı bölümü kaydırabilir.
/// 2. Bölümden 2 kare/sn örneklenir; en iyi 6 kare fotoğraf modeliyle tanınır ve kare kalitesiyle
///    ağırlıklı ortalaması alınır (`FrameAggregator`; mevsim ön bilgisi sınıflandırıcıda uygulanır).
/// 3. Bölümün sesi BirdNET'e verilir; görüntü ve ses birleştirilir (`VideoFusion`).
@MainActor
@Observable
final class BirdVideoService {
    enum Phase: Equatable {
        case idle
        case loading
        case scanning(Double)
        case selecting
        case analyzingFrames(Double)
        case analyzingSound
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var duration: Double = 0
    /// Taranan karelerin puanları (zaman çizelgesi için; kısa videoda boş).
    private(set) var timeline: [Double] = []
    private(set) var windowStart: Double = 0
    /// Bölümün en iyi karesi ve kuş bölgesi (Vision koordinatları).
    private(set) var preview: UIImage?
    private(set) var focusRect: CGRect?
    private(set) var fusion: VideoFusion?
    private(set) var note: String?

    var isActive: Bool { phase != .idle }
    var isBusy: Bool {
        switch phase {
        case .loading, .scanning, .selecting, .analyzingFrames, .analyzingSound: return true
        case .idle, .finished, .failed: return false
        }
    }
    /// Bölüm kaydırılabilir mi (video 10 sn'den uzun).
    var canShiftWindow: Bool { VideoWindowSelector.scanDuration(duration) > VideoWindowSelector.window }
    var maxStart: Double { max(0, VideoWindowSelector.scanDuration(duration) - VideoWindowSelector.window) }

    @ObservationIgnored private let classifier: any BirdImageClassifying
    @ObservationIgnored private var reader: BirdVideoReader?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var regs: Regulations?

    init(classifier: any BirdImageClassifying = CoreMLBirdClassifier()) {
        self.classifier = classifier
    }

    /// Yeni video: tara, en iyi bölümü seç, çözümle.
    func load(url: URL, regs: Regulations?) {
        reset()
        self.regs = regs
        let reader = BirdVideoReader(url: url)
        self.reader = reader
        phase = .loading
        task = Task { [weak self] in
            do {
                let d = try await reader.duration()
                guard let self, !Task.isCancelled else { return }
                self.duration = d
                var start = 0.0
                if self.canShiftWindow {
                    let frames = try await self.scan(reader, duration: d)
                    self.timeline = VideoWindowSelector.scores(frames)
                    self.phase = .selecting
                    start = VideoWindowSelector.bestStart(frames, duration: d)
                }
                self.windowStart = start
                await self.analyzeWindow(reader)
                if case .finished = self.phase { UsageStats.record(.kusVideo) }
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(L("Video okunamadı ya da biçimi desteklenmiyor."))
            }
        }
    }

    /// Kullanıcı bölümü kaydırdı: yalnızca bölüm yeniden çözümlenir.
    func shiftWindow(to start: Double) {
        guard let reader else { return }
        switch phase {
        case .loading, .scanning, .selecting, .idle: return
        default: break
        }
        windowStart = VideoWindowSelector.clamp(start: start, duration: duration)
        task?.cancel()
        task = Task { [weak self] in await self?.analyzeWindow(reader) }
    }

    /// Video yüklenemedi (galeri seçicisi).
    func fail(_ message: String) {
        reset()
        phase = .failed(message)
    }

    func reset() {
        task?.cancel()
        task = nil
        if let url = reader?.url, url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
        reader = nil
        phase = .idle
        duration = 0
        timeline = []
        windowStart = 0
        preview = nil
        focusRect = nil
        fusion = nil
        note = nil
    }

    // MARK: Adımlar

    private func scan(_ reader: BirdVideoReader, duration: Double) async throws -> [FrameQuality] {
        let times = VideoWindowSelector.scanTimes(duration: duration)
        var frames: [FrameQuality] = []
        for (n, t) in times.enumerated() {
            try Task.checkCancellation()
            phase = .scanning(Double(n) / Double(max(1, times.count)))
            if let q = try? await Self.quality(reader, at: t, large: false) { frames.append(q.quality) }
        }
        return frames
    }

    private func analyzeWindow(_ reader: BirdVideoReader) async {
        preview = nil
        focusRect = nil
        fusion = nil
        note = nil
        phase = .analyzingFrames(0)
        var notes: [String] = []

        // Görüntü: bölümden örnek kareler → en iyi kareler → tür modeli → ağırlıklı ortalama
        let times = VideoWindowSelector.sampleTimes(start: windowStart, duration: duration)
        var sampled: [FrameQuality] = []
        for t in times {
            guard !Task.isCancelled else { return }
            if let q = try? await Self.quality(reader, at: t, large: false) { sampled.append(q.quality) }
        }
        var perFrame: [(predictions: [BirdPrediction], weight: Double)] = []
        var bestShown = -1.0
        let chosen = VideoWindowSelector.bestFrames(sampled)
        for (n, c) in chosen.enumerated() {
            guard !Task.isCancelled else { return }
            phase = .analyzingFrames(Double(n + 1) / Double(max(1, chosen.count)))
            guard let image = try? await reader.frame(at: c.frame.time, large: true) else { continue }
            do {
                let r = try await classifier.classify(image, orientation: .up, maxResults: 10)
                perFrame.append((r.predictions, c.score))
                if c.score > bestShown {
                    bestShown = c.score
                    preview = UIImage(cgImage: image)
                    focusRect = r.focusRect
                }
            } catch BirdIdentificationError.modelLoadFailed(let m) {
                let text = L("Tanıma modeli açılamadı: %@", m)
                if !notes.contains(text) { notes.append(text) }
            } catch {
                continue // bu karede kuş yok ya da tahmin yok
            }
        }
        if preview == nil, let t = chosen.first?.frame.time ?? times.first,
           let image = try? await reader.frame(at: t, large: true) {
            preview = UIImage(cgImage: image)
        }
        let image = FrameAggregator.aggregate(perFrame)

        // Ses: bölümün ses izi → BirdNET (o hafta olası türler; benzer korunan tür işareti)
        guard !Task.isCancelled else { return }
        phase = .analyzingSound
        var sound: [BirdDetection] = []
        if BirdNETOnDevice.isAvailable {
            do {
                let samples = try await reader.audioSamples(start: windowStart, length: VideoWindowSelector.window)
                if samples.count >= Int(BirdNETOnDevice.sampleRate) {
                    let a = try await BirdNETOnDevice.shared.analyze(samples: samples, date: AppClock.now())
                    sound = a.detections
                    if let regs {
                        sound = BirdLookalike.mark(sound, candidates: a.candidates,
                                                   huntable: regs.huntableLatin ?? [:], protected: regs.protectedLatin ?? [:])
                    }
                } else {
                    notes.append(L("Videoda ses yok; yalnızca görüntü analiz edildi."))
                }
            } catch {
                notes.append(L("Ses analiz edilemedi (%@).", error.localizedDescription))
            }
        } else {
            notes.append(L("BirdNET modeli uygulamada yok."))
        }
        guard !Task.isCancelled else { return }

        let f = VideoFusion.fuse(image: image, sound: sound)
        note = notes.isEmpty ? nil : notes.joined(separator: " ")
        if f.image.isEmpty && f.sound.isEmpty {
            phase = .failed(L("Bu bölümde kuş bulunamadı. Bölümü kaydırın ya da kuşun yakın ve net göründüğü bir video seçin."))
        } else {
            fusion = f
            phase = .finished
        }
    }

    /// Kare + kalite (Vision işi ana iş parçacığı dışında).
    private nonisolated static func quality(_ reader: BirdVideoReader, at t: Double, large: Bool) async throws -> QualityBox {
        let box = ImageBox(image: try await reader.frame(at: t, large: large))
        return await Task.detached(priority: .userInitiated) {
            QualityBox(quality: BirdVideoReader.quality(box.image, time: t))
        }.value
    }

    private struct QualityBox: Sendable { let quality: FrameQuality }
    /// CGImage değişmez olduğundan iş parçacıkları arasında güvenle taşınır.
    private struct ImageBox: @unchecked Sendable { let image: CGImage }
}
