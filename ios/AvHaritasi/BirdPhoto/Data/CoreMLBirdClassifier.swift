import CoreGraphics
import CoreML
import Foundation
import ImageIO
import os
import Vision

/// Fotoğraftan kuş tanıma (tamamen cihazda, internetsiz).
///
/// Aşamalar:
/// 1. **Kuş var mı?** Apple'ın yerleşik sınıflandırıcısı (`VNClassifyImageRequest`, model gerekmez)
///    fotoğrafta kuş olup olmadığını ve genel grubu (ördek, baykuş, kartal...) verir.
/// 2. **Kırpma:** `VNGenerateObjectnessBasedSaliencyImageRequest` en belirgin nesneyi bulur; uzaktaki
///    küçük kuşlar kırpılınca tür modeli çok daha iyi çalışır.
/// 3. **Tür:** `BirdClassifier.mlmodel` (uygulama paketinde varsa) kırpılmış ve tam görüntüde çalışır;
///    tür başına en yüksek olasılık alınır. Model yoksa 1. aşamanın genel sonucu döner.
///
/// Model çalışma anında paketten yüklenir (derleme anında üretilen sınıf kullanılmaz), böylece model
/// dosyası eklenmeden de uygulama derlenir ve genel sınıflandırmayla çalışır.
actor CoreMLBirdClassifier: BirdImageClassifying {
    static let modelName = "BirdClassifier"

    private enum ModelState {
        case notLoaded
        case loaded(VNCoreMLModel)
        case missing
    }

    private var modelState: ModelState = .notLoaded
    private let bundle: Bundle
    /// Vision istekleri eşzamanlı (bloklayan) çalışır: ana iş parçacığını ve Swift eşzamanlılık
    /// havuzunu meşgul etmemek için ayrı bir kuyrukta yürütülür.
    private let queue = DispatchQueue(label: "kus.foto.vision", qos: .userInitiated)
    private let log = Logger(subsystem: "AvHaritasi", category: "kusfoto")

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Paketteki tür modeli (yoksa nil). Hata yalnızca model var ama açılamıyorsa fırlatılır.
    private func speciesModel() throws -> VNCoreMLModel? {
        switch modelState {
        case .loaded(let m): return m
        case .missing: return nil
        case .notLoaded:
            // Xcode .mlmodel/.mlpackage dosyasını derleyip pakete .mlmodelc olarak koyar
            guard let url = bundle.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
                log.info("BirdClassifier.mlmodelc yok; genel sınıflandırma kullanılacak")
                modelState = .missing
                return nil
            }
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
                modelState = .loaded(model)
                return model
            } catch {
                log.error("Model açılamadı: \(error.localizedDescription, privacy: .public)")
                throw BirdIdentificationError.modelLoadFailed(error.localizedDescription)
            }
        }
    }

    func classify(_ image: CGImage, orientation: CGImagePropertyOrientation, maxResults: Int) async throws -> BirdIdentificationResult {
        let model = try speciesModel().map(ModelBox.init)
        try checkCancellation()

        // 1–2: kuş var mı + belirgin bölge (tek görüntü işleyicide birlikte)
        let scene = try await run {
            let general = VNClassifyImageRequest()
            let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
            try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([general, saliency])
            let obs = general.results ?? []
            return SceneInfo(presence: Self.birdPresence(obs),
                             groups: Self.generalBirdPredictions(obs, maxResults: maxResults),
                             focus: Self.focusRect(saliency.results?.first))
        }
        try checkCancellation()

        guard let model else {
            if scene.groups.isEmpty {
                throw scene.presence < 0.1 ? BirdIdentificationError.noBirdDetected : BirdIdentificationError.noResults
            }
            return BirdIdentificationResult(predictions: scene.groups, focusRect: scene.focus,
                                            birdPresence: scene.presence, usedFallback: true)
        }

        // 3: tür modeli — tam görüntü ve (varsa) kırpılmış bölge; tür başına en yüksek olasılık
        var best: [String: Double] = [:]
        var inputs: [(CGImage, CGImagePropertyOrientation)] = [(image, orientation)]
        if let focus = scene.focus, let crop = Self.crop(image, orientation: orientation, to: focus) { inputs.append((crop, .up)) }
        for (img, ori) in inputs {
            try checkCancellation()
            let probs = try await run {
                let request = VNCoreMLRequest(model: model.model)
                request.imageCropAndScaleOption = .centerCrop
                try VNImageRequestHandler(cgImage: img, orientation: ori, options: [:]).perform([request])
                return Self.probabilities(from: request.results ?? [])
            }
            for (label, p) in probs where p > (best[label] ?? 0) { best[label] = p }
        }

        let predictions = best.sorted { $0.value > $1.value }
            .prefix(maxResults)
            .map { label, p in
                let parsed = BirdLabel.parse(label)
                return BirdPrediction(label: label, scientificName: parsed.scientific, commonName: parsed.common,
                                      probability: p, source: .speciesModel)
            }
        guard let top = predictions.first else { throw BirdIdentificationError.noResults }
        // Yerleşik sınıflandırıcı kuş görmüyor ve tür modeli de emin değilse "kuş yok" de
        if scene.presence < 0.05 && top.probability < 0.5 { throw BirdIdentificationError.noBirdDetected }
        return BirdIdentificationResult(predictions: Array(predictions), focusRect: scene.focus,
                                        birdPresence: scene.presence, usedFallback: false)
    }

    // MARK: Vision yürütme

    private struct SceneInfo: Sendable {
        let presence: Double
        let groups: [BirdPrediction]
        let focus: CGRect?
    }

    /// VNCoreMLModel iş parçacığı güvenlidir ama Sendable işaretli değildir.
    private struct ModelBox: @unchecked Sendable {
        let model: VNCoreMLModel
    }

    /// Bloklayan Vision işini ayrı kuyrukta çalıştırır; Vision hatası alan hatasına çevrilir.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    cont.resume(returning: try work())
                } catch {
                    cont.resume(throwing: BirdIdentificationError.classificationFailed(error.localizedDescription))
                }
            }
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw BirdIdentificationError.cancelled }
    }

    // MARK: Sonuç ayrıştırma

    /// Sınıflandırıcı modeller `VNClassificationObservation` üretir; sınıflandırıcı olarak işaretlenmemiş
    /// modellerde olasılık sözlüğü (`classLabelProbs`) özellik değeri olarak gelir.
    static func probabilities(from results: [VNObservation]) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in results {
            if let c = r as? VNClassificationObservation {
                out[c.identifier] = Double(c.confidence)
            } else if let f = r as? VNCoreMLFeatureValueObservation {
                let dict = f.featureValue.dictionaryValue
                for (k, v) in dict {
                    if let key = k as? String { out[key] = v.doubleValue }
                }
            }
        }
        return out
    }

    /// Yerleşik sınıflandırıcının kuş grupları (Apple taksonomisi tanımlayıcısı → Türkçe ad, bilimsel ad).
    /// Bilimsel ad yalnızca grup tek türe karşılık geliyorsa verilir.
    static let generalBirdLabels: [String: (name: String, scientific: String?)] = [
        "bird": (L("Kuş (tür belirsiz)"), nil),
        "duck": (L("Ördek (tür belirsiz)"), nil),
        "goose": (L("Kaz (tür belirsiz)"), nil),
        "swan": (L("Kuğu — koruma altında"), nil),
        "owl": (L("Baykuş — koruma altında"), nil),
        "eagle": (L("Kartal — koruma altında"), nil),
        "hawk": (L("Şahin / atmaca — koruma altında"), nil),
        "vulture": (L("Akbaba — koruma altında"), nil),
        "pigeon": (L("Güvercin / üveyik grubu"), nil),
        "dove": (L("Güvercin / üveyik grubu"), nil),
        "crow": (L("Karga (tür belirsiz)"), nil),
        "raven": (L("Kuzgun"), "Corvus corax"),
        "magpie": (L("Saksağan"), "Pica pica"),
        "gull": (L("Martı — koruma altında"), nil),
        "heron": (L("Balıkçıl — koruma altında"), nil),
        "stork": (L("Leylek — koruma altında"), "Ciconia ciconia"),
        "pelican": (L("Pelikan — koruma altında"), nil),
        "flamingo": (L("Flamingo — koruma altında"), "Phoenicopterus roseus"),
        "woodpecker": (L("Ağaçkakan — koruma altında"), nil),
        "kingfisher": (L("Yalıçapkını — koruma altında"), "Alcedo atthis"),
        "songbird": (L("Ötücü kuş (tür belirsiz)"), nil),
        "sparrow": (L("Serçe"), "Passer domesticus"),
        "pheasant": (L("Sülün"), "Phasianus colchicus"),
        "quail": (L("Bıldırcın"), "Coturnix coturnix"),
        "partridge": (L("Keklik (tür belirsiz)"), nil),
        "chicken": (L("Tavuk"), nil),
        "rooster": (L("Horoz"), nil),
        "turkey": (L("Hindi"), nil),
        "parrot": (L("Papağan"), nil),
    ]

    static func birdPresence(_ obs: [VNClassificationObservation]) -> Double {
        obs.filter { generalBirdLabels[$0.identifier] != nil }.map { Double($0.confidence) }.max() ?? 0
    }

    static func generalBirdPredictions(_ obs: [VNClassificationObservation], maxResults: Int) -> [BirdPrediction] {
        var seen = Set<String>()
        return obs
            .filter { $0.identifier != "bird" && $0.confidence >= 0.1 }
            .sorted { $0.confidence > $1.confidence }
            .compactMap { o -> BirdPrediction? in
                guard let g = generalBirdLabels[o.identifier], seen.insert(g.name).inserted else { return nil }
                return BirdPrediction(label: o.identifier, scientificName: g.scientific, commonName: g.name,
                                      probability: Double(o.confidence), source: .generalModel)
            }
            .prefix(maxResults)
            .map { $0 }
    }

    // MARK: Kırpma

    /// En belirgin nesnenin kutusu %20 genişletilip kareye yaklaştırılır. Nesne zaten kadrajın
    /// çoğunu kaplıyorsa kırpma yapılmaz (nil).
    static func focusRect(_ obs: VNSaliencyImageObservation?) -> CGRect? {
        guard let box = obs?.salientObjects?.max(by: { $0.confidence < $1.confidence })?.boundingBox,
              box.width * box.height < 0.6 else { return nil }
        let side = max(box.width, box.height) * 1.2
        var r = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.isNull || r.width < 0.05 ? nil : r
    }

    /// Vision bölgesi (normalize, sol alt köken) → CGImage kırpması. Görüntü dik (.up) değilse
    /// kırpma yapılmaz; yükleyici zaten dik görüntü üretir.
    static func crop(_ image: CGImage, orientation: CGImagePropertyOrientation, to rect: CGRect) -> CGImage? {
        guard orientation == .up else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pixel = CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h).integral
        return image.cropping(to: pixel)
    }
}
