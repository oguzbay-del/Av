import Foundation

/// Mevsim (hafta) ön bilgisi: fotoğraf modelinin olasılıklarını türün İstanbul'da o haftaki görülme
/// durumuna göre yumuşakça yeniden ağırlıklandırır (saf mantık; veri `IstanbulSpecies.occurrence`).
///
/// p' ∝ p · (taban + (1 − taban) · görülme). Görülme 0…1'dir: BirdNET meta modelinin 48 haftalık
/// "olası" işaretlerinin ±2 haftalık ortalaması (göç sınırında ani düşüş olmasın). Mevsim dışı tür
/// en çok `floor` katına iner, hiçbir zaman silinmez; toplam olasılık korunur.
///
/// Ses yolu (BirdNET) haftayı zaten kendi uygular (o hafta olası olmayan tür gösterilmez); orada
/// ikinci kez uygulanmaz.
enum SeasonalPrior {
    static let floor = 0.3
    /// Görülme ortalamasında haftanın iki yanındaki hafta sayısı.
    static let spread = 2

    /// 48 karakterlik hafta dizisinden ("1" = olası) `week` (1…48) için 0…1 görülme; yıl döngüseldir.
    static func occurrence(weeks: String, week: Int, spread: Int = spread) -> Double? {
        let flags = Array(weeks)
        guard flags.count == 48 else { return nil }
        let center = max(1, min(48, week)) - 1
        let range = -spread...spread
        let present = range.filter { flags[(center + $0 + 48) % 48] == "1" }.count
        return Double(present) / Double(range.count)
    }

    /// Ağırlık: bilinmeyen türde (görülme nil) 1 — ön bilgi yoksa ceza da yok.
    static func weight(occurrence: Double?, floor: Double = floor) -> Double {
        guard let o = occurrence else { return 1 }
        return floor + (1 - floor) * max(0, min(1, o))
    }

    /// Olasılıkları yeniden ağırlıklandırır ve girdinin toplamına yeniden ölçekler.
    static func apply(_ probs: [String: Double], floor: Double = floor,
                      occurrence: (String) -> Double?) -> [String: Double] {
        let total = probs.values.reduce(0, +)
        var out: [String: Double] = [:]
        for (label, p) in probs { out[label] = p * weight(occurrence: occurrence(label), floor: floor) }
        let newTotal = out.values.reduce(0, +)
        guard total > 0, newTotal > 0 else { return probs }
        let k = total / newTotal
        return out.mapValues { min(1, $0 * k) }
    }
}
