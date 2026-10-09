import UIKit
import UserNotifications

/// `AlertPolicy` kararının yan etkileri: titreşim, ses; uygulama önde değilse bildirim.
@MainActor
enum AlertNotifier {
    static func deliver(_ alert: AlertPolicy.Alert) {
        UINotificationFeedbackGenerator().notificationOccurred(alert.level == .danger ? .error : .warning)
        alert.sound.alert()

        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = alert.sound.notificationSound
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "zone-alert", content: content, trigger: nil))
        }
    }
}
