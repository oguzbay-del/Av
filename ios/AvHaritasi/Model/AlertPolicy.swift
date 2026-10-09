import Foundation

/// Bölge uyarısı kararı (yan etkisiz): önceki durum + yeni değerlendirme + "şimdi" →
/// uyarı verilecek mi, hangi seviye ve metinle, hangi sesle; ve güncellenmiş durum.
/// Titreşim, ses ve bildirim `AlertNotifier`dadır.
///
/// Kurallar yalnızca mekânsal seviyeye (`placeLevel`) bakar (ör. Pazartesi günü sürekli
/// "av günü değil" bildirimi gelmesin):
/// - seviye kötüleştiyse ve en az "dikkat"se uyar,
/// - yasak noktada kalındıkça 2 dakikada bir hatırlat,
/// - metin o seviyedeki ilk mekânsal kuraldan (yoksa değerlendirmenin özetinden).
struct AlertPolicy: Equatable, Sendable {
    /// Yasak alanda kalındıkça hatırlatma aralığı.
    static let dangerRepeatInterval: TimeInterval = 120

    struct Alert: Equatable, Sendable {
        let level: Assessment.Level
        let title: String
        let body: String
        let sound: AppSound
    }

    struct Decision: Equatable, Sendable {
        /// nil: uyarı yok.
        let alert: Alert?
        /// Bir sonraki karar için durum (uyarı olmasa da son seviye güncellenir).
        let next: AlertPolicy
    }

    /// Son değerlendirmenin mekânsal seviyesi.
    var lastAlertLevel: Assessment.Level = .unknown
    /// Son "yasak" uyarısının zamanı.
    var lastDangerAlert: Date = .distantPast

    func decide(_ a: Assessment, now: Date) -> Decision {
        let level = a.placeLevel
        var next = self
        next.lastAlertLevel = level
        let worsened = level > lastAlertLevel && level >= .caution
        let repeatDanger = level == .danger && now.timeIntervalSince(lastDangerAlert) > Self.dangerRepeatInterval
        guard worsened || repeatDanger else { return Decision(alert: nil, next: next) }
        if level == .danger { next.lastDangerAlert = now }

        let reason = a.checks.first { $0.kind == .place && $0.level == level }
        let title = (level == .danger ? "⛔️ " : "⚠️ ") + (reason?.title ?? a.title)
        let body = reason?.detail ?? a.detail
        let sound: AppSound = level == .danger ? .yasak : .dikkat
        return Decision(alert: Alert(level: level, title: title, body: body, sound: sound), next: next)
    }

    /// Kararı uygula: durumu güncelle, verilecek uyarıyı döndür.
    mutating func update(with a: Assessment, now: Date) -> Alert? {
        let d = decide(a, now: now)
        self = d.next
        return d.alert
    }
}
