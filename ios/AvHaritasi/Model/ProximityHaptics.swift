import Foundation
import UIKit

/// Yasak alan sınırına yaklaşırken kısa titreşim ("tık").
/// Karar kısmı (`ProximityTickPolicy`) saftır ve birim testlidir; titreşim yalnızca uygulama ön plandayken verilir
/// (arka planda bildirimler/uyarılar devrededir).
struct ProximityTickPolicy {
    enum Intensity: Equatable {
        case light
        case strong
    }

    /// Aşağı doğru geçildiğinde tık verilen eşikler (m): 300, 250, …, 50.
    static let steps: [Double] = stride(from: 300.0, through: 50.0, by: -50.0).map { $0 }
    /// Bu mesafenin altında güçlü tık.
    static let strongBelow: Double = 100
    /// İki tık arasında en az bu kadar saniye.
    static let minInterval: TimeInterval = 5

    private(set) var lastDistance: Double?
    private(set) var lastTick: Date?

    /// Saf karar: önceki ve yeni uzaklığa göre tık verilip verilmeyeceği.
    /// Yalnızca bir eşik yukarıdan aşağı geçildiğinde (yaklaşırken) tık verilir; uzaklaşırken asla.
    static func decide(previous: Double?, current: Double?, lastTick: Date?, now: Date) -> Intensity? {
        guard let previous, let current, current < previous else { return nil }
        guard steps.contains(where: { previous > $0 && current <= $0 }) else { return nil }
        if let lastTick, now.timeIntervalSince(lastTick) < minInterval { return nil }
        return current < strongBelow ? .strong : .light
    }

    /// Yeni uzaklığı kaydeder ve tık gerekiyorsa şiddetini döndürür.
    mutating func update(distance: Double?, now: Date) -> Intensity? {
        let result = Self.decide(previous: lastDistance, current: distance, lastTick: lastTick, now: now)
        lastDistance = distance
        if result != nil { lastTick = now }
        return result
    }
}

@MainActor
final class ProximityHaptics {
    static let shared = ProximityHaptics()
    /// Ayarlar: "Sınıra yaklaşırken titreşim" (varsayılan açık).
    static let settingKey = "proximityHaptics"

    private var policy = ProximityTickPolicy()
    private let light = UIImpactFeedbackGenerator(style: .medium)
    private let strong = UIImpactFeedbackGenerator(style: .heavy)

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true
    }

    /// En yakın yasak alana uzaklık (m; yoksa ya da içindeyken nil).
    func update(distance: Double?) {
        let active = enabled && UIApplication.shared.applicationState == .active
        // Arka planda/kapalıyken de uzaklık izlenir ki ön plana dönünce eski değerle yanlış tık olmasın.
        guard let intensity = policy.update(distance: distance, now: Date()), active else { return }
        switch intensity {
        case .light: light.impactOccurred()
        case .strong: strong.impactOccurred(intensity: 1)
        }
    }
}
