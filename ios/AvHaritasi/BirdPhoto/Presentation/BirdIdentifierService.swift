import Observation
import UIKit

/// Fotoğraftan kuş tanıma durumu (sunum katmanı). Sınıflandırıcıyı protokol üzerinden alır;
/// Vision/CoreML ayrıntısını bilmez.
@MainActor
@Observable
final class BirdIdentifierService {
    enum State: Equatable {
        case idle
        case loadingImage
        case analyzing
        case finished(BirdIdentificationResult)
        case failed(BirdIdentificationError)
    }

    private(set) var state: State = .idle
    /// Ekranda gösterilen (küçültülmüş, dik) fotoğraf.
    private(set) var image: UIImage?

    var predictions: [BirdPrediction] {
        if case .finished(let r) = state { return r.predictions }
        return []
    }

    var isBusy: Bool { state == .loadingImage || state == .analyzing }

    @ObservationIgnored private let classifier: any BirdImageClassifying
    @ObservationIgnored private let maxResults: Int
    @ObservationIgnored private var current: Task<[BirdPrediction], Never>?

    init(classifier: any BirdImageClassifying = CoreMLBirdClassifier(), maxResults: Int = 3) {
        self.classifier = classifier
        self.maxResults = maxResults
    }

    /// Fotoğrafı arka planda sınıflandırır; en olası `maxResults` (3) türü döndürür.
    /// Hata durumunda boş dizi döner ve `state` hatayı taşır. Yeni çağrı öncekini iptal eder.
    @discardableResult
    func classify(image: UIImage) async -> [BirdPrediction] {
        current?.cancel()
        self.image = image
        state = .analyzing
        let classifier = classifier, maxResults = maxResults
        let task = Task { [weak self] () -> [BirdPrediction] in
            do {
                let cg = try BirdImageLoader.upright(image)
                let result = try await classifier.classify(cg, orientation: .up, maxResults: maxResults)
                try Task.checkCancellation()
                self?.state = .finished(result)
                return result.predictions
            } catch is CancellationError {
                return []
            } catch BirdIdentificationError.cancelled {
                return []
            } catch let e as BirdIdentificationError {
                self?.state = .failed(e)
                return []
            } catch {
                self?.state = .failed(.classificationFailed(error.localizedDescription))
                return []
            }
        }
        current = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// PhotosPicker verisinden: önce bellek dostu küçültme, sonra sınıflandırma.
    @discardableResult
    func classify(imageData: Data?) async -> [BirdPrediction] {
        current?.cancel()
        state = .loadingImage
        guard let imageData else {
            state = .failed(.imageLoadFailed)
            return []
        }
        do {
            let box = try await Task.detached(priority: .userInitiated) {
                ImageBox(image: try BirdImageLoader.downsample(imageData))
            }.value
            return await classify(image: UIImage(cgImage: box.image))
        } catch let e as BirdIdentificationError {
            state = .failed(e)
        } catch {
            state = .failed(.imageLoadFailed)
        }
        return []
    }

    /// Fotoğraf yükleme sırasında (PhotosPicker) oluşan hata.
    func fail(_ error: BirdIdentificationError) {
        current?.cancel()
        state = .failed(error)
    }

    /// CGImage değişmez (immutable) olduğundan iş parçacıkları arasında güvenle taşınır.
    private struct ImageBox: @unchecked Sendable { let image: CGImage }

    func reset() {
        current?.cancel()
        image = nil
        state = .idle
    }
}
