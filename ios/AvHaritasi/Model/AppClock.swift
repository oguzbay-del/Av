import Foundation

/// Uygulamanın "şimdi"si. Debug derlemesinde `debugNow` (ISO 8601) ayarıyla
/// sabitlenebilir; ekran görüntüleri için kullanılır (tools/screenshots.sh).
enum AppClock {
    static func now() -> Date {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "debugNow"),
           let d = ISO8601DateFormatter().date(from: s) {
            return d
        }
        #endif
        return Date()
    }
}
