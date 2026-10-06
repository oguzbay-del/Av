import ActivityKit
import Foundation

/// Av durumunu kilit ekranında (Live Activity) gösterir; iOS bunu Apple Watch'ta da
/// Akıllı Yığın'da otomatik gösterir.
@MainActor
final class LiveStatus {
    private var activity: Activity<HuntActivityAttributes>?
    private var lastState: HuntActivityAttributes.ContentState?

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
        if let activity {
            Task { await activity.update(content) }
        } else {
            activity = try? Activity.request(attributes: HuntActivityAttributes(areaName: assessment.unitName ?? "Av sahası"),
                                             content: content, pushType: nil)
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
