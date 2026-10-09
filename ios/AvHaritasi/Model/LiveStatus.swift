import ActivityKit
import Foundation

/// Av durumunu kilit ekranında (Live Activity) gösterir; iOS bunu Apple Watch'ta da
/// Akıllı Yığın'da otomatik gösterir.
@MainActor
final class LiveStatus {
    private var activity: Activity<HuntActivityAttributes>?
    private var lastState: HuntActivityAttributes.ContentState?
    private var startedAt = Date.distantPast
    /// iOS bir Live Activity'yi en fazla 8 saat etkin tutar; uzun av gününde süresi dolmadan yenile.
    private static let maxAge: TimeInterval = 7.5 * 3600

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func update(enabled: Bool, assessment: Assessment, wind: String?) {
        guard enabled, isAvailable, assessment.level != .unknown || activity != nil else {
            if !enabled { end() }
            return
        }
        let reason = assessment.checks.first { $0.level == assessment.level }
        let state = HuntActivityAttributes.ContentState(
            level: assessment.level.rawValue,
            title: assessment.title,
            detail: reason?.detail ?? assessment.detail,
            wind: wind,
            updated: AppClock.now())
        // Yalnızca anlamlı değişiklikte güncelle (pil ve kota için)
        if let last = lastState, last.level == state.level, last.title == state.title, last.wind == state.wind,
           state.updated.timeIntervalSince(last.updated) < 300 {
            return
        }
        lastState = state
        let content = ActivityContent(state: state, staleDate: AppClock.now().addingTimeInterval(30 * 60))
        if let old = activity, Date().timeIntervalSince(startedAt) > Self.maxAge {
            activity = nil
            FieldLog.shared.log(.liveActivity(active: false, reason: "8 saat sınırı, yenileniyor"))
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        if let activity {
            Task { await activity.update(content) }
        } else {
            activity = try? Activity.request(attributes: HuntActivityAttributes(areaName: assessment.unitName ?? L("Av sahası")),
                                             content: content, pushType: nil)
            startedAt = Date()
            if activity != nil { FieldLog.shared.log(.liveActivity(active: true, reason: nil)) }
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        FieldLog.shared.log(.liveActivity(active: false, reason: nil))
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
