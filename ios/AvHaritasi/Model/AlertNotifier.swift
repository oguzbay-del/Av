import UIKit
import UserNotifications

/// `AlertPolicy` kararının yan etkileri: titreşim, ses; uygulama önde değilse ya da uygulama kilidi
/// (AppLock) ekranı örtüyorsa bildirim.
@MainActor
enum AlertNotifier {
    static let notificationID = "zone-alert"

    static func deliver(_ alert: AlertPolicy.Alert) {
        UINotificationFeedbackGenerator().notificationOccurred(alert.level == .danger ? .error : .warning)
        alert.sound.alert()

        if shouldPost(appActive: UIApplication.shared.applicationState == .active, locked: AppLock.shared.isLocked) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = alert.sound.notificationSound
            content.interruptionLevel = interruptionLevel(for: alert.level)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))
        }
    }

    /// Yasak alan uyarısı "Zamana Duyarlı": Odak modları (Rahatsız Etme, Uyku...) susturmaz.
    nonisolated static func interruptionLevel(for level: Assessment.Level) -> UNNotificationInterruptionLevel {
        level == .danger ? .timeSensitive : .active
    }

    /// Bildirim gönderilsin mi: arka planda her zaman; öndeyken yalnızca kilit ekranı durumu örtüyorsa.
    nonisolated static func shouldPost(appActive: Bool, locked: Bool) -> Bool {
        !appActive || locked
    }

    /// Uygulama öndeyken gelen bildirim: yalnızca kilitliyken banner olarak gösterilir (kilit açıkken
    /// durum zaten ekranda; titreşim ve ses `deliver`de verildi).
    nonisolated static func foregroundPresentation(locked: Bool) -> UNNotificationPresentationOptions {
        locked ? [.banner, .sound, .list] : []
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let id = notification.request.identifier
        if HuntHoursReminders.isReminder(id) {
            // Av saati hatırlatması öndeyken de banner olarak görünsün
            await MainActor.run { HuntHoursReminders.logFired(id) }
            return [.banner, .sound, .list]
        }
        let locked = await MainActor.run { AppLock.shared.isLocked }
        return AlertNotifier.foregroundPresentation(locked: locked)
    }

    /// Bildirime dokunma: uygulama açılır (kilitliyse önce kilit ekranı); av saati hatırlatması kayda yazılır.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        if HuntHoursReminders.isReminder(id) { await MainActor.run { HuntHoursReminders.logFired(id) } }
    }
}
