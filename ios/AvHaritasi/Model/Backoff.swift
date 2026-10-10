import Foundation

/// Sınırlı üstel bekleme (yan etkisiz): başarısızlıktan sonra 1, 2, 4, 8 … dk, en çok 30 dk,
/// ±%10 rastgele sapma (aynı anda yeniden denemeler yığılmasın). Başarıda sıfırlanır.
/// Yalnızca hava durumu için kullanılır; uygulama başka ağ isteğini yeniden denemez.
struct Backoff: Equatable, Sendable {
    let base: TimeInterval
    let cap: TimeInterval
    /// Sapma oranı (0,1 = ±%10).
    let jitter: Double

    /// Art arda başarısızlık sayısı.
    private(set) var failures = 0
    /// Bu andan önce yeniden denenmez (nil: bekleme yok).
    private(set) var retryAt: Date?

    init(base: TimeInterval = 60, cap: TimeInterval = 30 * 60, jitter: Double = 0.1) {
        self.base = base
        self.cap = cap
        self.jitter = jitter
    }

    /// `failures`. başarısızlıktan sonraki bekleme; `unit` [-1, 1] aralığında sapma.
    func delay(afterFailures failures: Int, unit: Double) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 30))
        let raw = min(cap, base * pow(2, exponent))
        let u = min(1, max(-1, unit))
        return raw * (1 + jitter * u)
    }

    func canAttempt(at now: Date) -> Bool {
        retryAt.map { now >= $0 } ?? true
    }

    mutating func recordFailure(at now: Date, unit: Double = Double.random(in: -1...1)) {
        failures += 1
        retryAt = now.addingTimeInterval(delay(afterFailures: failures, unit: unit))
    }

    mutating func recordSuccess() {
        failures = 0
        retryAt = nil
    }
}
