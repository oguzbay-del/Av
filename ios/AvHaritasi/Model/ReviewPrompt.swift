import Foundation

// MARK: - App Store değerlendirme istemi
// iOS'un kendi değerlendirme penceresi (SwiftUI `requestReview`) yalnızca uygulama bir süredir
// kullanılıyorsa, en çok 120 günde bir ve hiçbir güvenlik uyarısı etkin değilken istenir.
// iOS ayrıca kendi sınırını uygular (yılda en çok 3 kez; pencere hiç gösterilmeyebilir).

/// Değerlendirme istemi için cihazda tutulan sayaçlar (UserDefaults; yalnızca sayı ve tarih).
struct ReviewPromptState: Codable, Equatable, Sendable {
    var firstLaunch: Date?
    /// Uygulamanın açıldığı farklı günler ("yyyy-MM-dd", İstanbul saati); en çok 30 gün tutulur.
    var activeDays: [String] = []
    var sessions = 0
    var successfulBirdIDs = 0
    var lastPrompt: Date?
}

enum ReviewPromptPolicy {
    static let minDaysSinceFirstLaunch = 7
    static let minActiveDays = 5
    static let minBirdIDs = 3
    static let minSessions = 10
    static let minDaysBetweenPrompts = 120
    /// Saklanan en çok gün sayısı (karar için 5 yeter).
    static let maxStoredDays = 30

    /// İstem şimdi gösterilebilir mi. `safetyAlertActive`: yasak/dikkat alanı, bayat GPS ya da uyarı ekranda.
    static func shouldPrompt(_ s: ReviewPromptState, now: Date, safetyAlertActive: Bool) -> Bool {
        guard !safetyAlertActive, let first = s.firstLaunch else { return false }
        let day: TimeInterval = 24 * 3600
        guard now.timeIntervalSince(first) >= Double(minDaysSinceFirstLaunch) * day else { return false }
        if let last = s.lastPrompt, now.timeIntervalSince(last) < Double(minDaysBetweenPrompts) * day, last <= now {
            return false
        }
        guard Set(s.activeDays).count >= minActiveDays else { return false }
        return s.successfulBirdIDs >= minBirdIDs || s.sessions >= minSessions
    }

    /// Uygulama öne geldi: oturum ve etkin gün say.
    static func recordSession(_ s: inout ReviewPromptState, now: Date) {
        if s.firstLaunch == nil { s.firstLaunch = now }
        s.sessions += 1
        let key = UsageStats.dayKey(now)
        if !s.activeDays.contains(key) {
            s.activeDays.append(key)
            if s.activeDays.count > maxStoredDays { s.activeDays.removeFirst(s.activeDays.count - maxStoredDays) }
        }
    }

    static func recordBirdID(_ s: inout ReviewPromptState) { s.successfulBirdIDs += 1 }

    /// İstem gösterildi: süre yeniden başlar.
    static func recordPrompt(_ s: inout ReviewPromptState, now: Date) { s.lastPrompt = now }
}

/// Sayaçların UserDefaults kaydı (herhangi bir iş parçacığından çağrılabilir).
enum ReviewPromptStore {
    private static let key = "reviewPrompt"
    private static let lock = NSLock()

    static var state: ReviewPromptState {
        lock.withLock { load() }
    }

    static func update(_ change: (inout ReviewPromptState) -> Void) {
        lock.withLock {
            var s = load()
            change(&s)
            if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
        }
    }

    private static func load() -> ReviewPromptState {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ReviewPromptState.self, from: $0) }
            ?? ReviewPromptState()
    }
}
