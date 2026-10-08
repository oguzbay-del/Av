import AudioToolbox
import Foundation
import UserNotifications

/// Xeno-canto'dan alınmış gerçek kuş sesleri (`tools/fetch_sounds.py`, künye: Sounds/kus_sesleri_kunye.json).
/// Sistem sesi olarak çalınır: telefon sessizdeyken çalmaz, kısa ve düşük gecikmelidir.
enum AppSound: String, CaseIterable {
    case acilis = "kus_acilis"     // Kınalı keklik — uygulama açılışı
    case kapanis = "kus_kapanis"   // Kızılgerdan — arka plana geçiş
    case dikkat = "kus_dikkat"     // Bıldırcın — dikkat uyarısı
    case yasak = "kus_yasak"       // Saksağan alarmı — yasak alan uyarısı

    private static var ids: [AppSound: SystemSoundID] = [:]

    private var soundID: SystemSoundID? {
        if let id = Self.ids[self] { return id }
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "wav") else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        Self.ids[self] = id
        return id
    }

    /// Kullanıcı Ayarlar'da kapatabilir (uyarı sesleri hariç).
    static var interfaceSoundsEnabled: Bool {
        UserDefaults.standard.object(forKey: "birdSounds") as? Bool ?? true
    }

    /// Açılış/kapanış gibi arayüz sesi.
    func play(force: Bool = false) {
        guard force || Self.interfaceSoundsEnabled, let id = soundID else { return }
        AudioServicesPlaySystemSound(id)
    }

    /// Uyarı: ses + titreşim (sessiz moddayken yalnızca titreşim). Dosya yoksa sistem sesine düşer.
    func alert() {
        if let id = soundID {
            AudioServicesPlayAlertSound(id)
        } else {
            AudioServicesPlayAlertSound(self == .yasak ? SystemSoundID(1005) : SystemSoundID(1007))
        }
    }

    /// Bildirim sesi (uygulama arka plandayken / kapalıyken).
    var notificationSound: UNNotificationSound {
        Bundle.main.url(forResource: rawValue, withExtension: "wav") != nil
            ? UNNotificationSound(named: UNNotificationSoundName(rawValue + ".wav"))
            : .default
    }
}

/// Ses künyesi (Ayarlar › Kuş sesleri). Lisans gereği kayıt sahibi ve kaynak gösterilir.
struct SoundCredit: Decodable, Identifiable {
    let file: String
    let species: String
    let scientific: String
    let use: String
    let xc: String
    let license: String
    let recordist: String
    let url: String

    var id: String { file }
    var sound: AppSound? { AppSound(rawValue: (file as NSString).deletingPathExtension) }

    static let all: [SoundCredit] = {
        guard let url = Bundle.main.url(forResource: "kus_sesleri_kunye", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SoundCredit].self, from: data)) ?? []
    }()
}
