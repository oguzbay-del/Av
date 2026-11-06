import Foundation

/// Harita ekranının yerleşim kararları (saf mantık, birim testli).
///
/// Üstte güvenlik şeridi tam genişlikte ve en üstte çizilir; hiçbir şey onu örtmez. Şeridin altında sağ kenarda ince
/// cam araç sütunu (Katmanlar, İşaret koy, İz kaydı, Konum, +, −, Acil durum), solunda kartlar, sınır/rüzgâr satırı
/// ve alt panel bulunur. Küçük ekranda (iPhone SE, saha modu) yer yetmezse önce sütunun üst grubu kaydırılır,
/// kart açıkken de alt panel geçici olarak çekilir; −/+, Konum ve Acil durum hiçbir zaman gizlenmez.
enum MapOverlayLayout {
    /// Sütunun üst grubundaki (seyrek kullanılan, gerekirse kaydırılan) düğme sayısı: Katmanlar, İşaret koy, İz kaydı.
    static let railOptionalCount = 3
    /// Alt gruptaki (her zaman görünen) düğme sayısı: Konum, +, −, Acil durum.
    static let railEssentialCount = 4

    /// Alt panel gizlensin mi? Tüm yükseklikler pt; `cards` açık kartların doğal yüksekliği (yoksa 0),
    /// `controls` sınır/rüzgâr satırı (ve yönlendirme çipi), `available` kontrol alanının yüksekliği
    /// (ölçülmeden önce 0 → gizlenmez). Kartlar ve alt panel sütunun solunda aynı dikey alanı paylaşır.
    static func hidesPanel(available: Double, safety: Double, cards: Double,
                           controls: Double, panel: Double, spacing: Double) -> Bool {
        guard available > 0, cards > 0, panel > 0 else { return false }
        let needed = safety + cards + controls + panel + 3 * spacing
        return needed > available
    }

    /// Araç sütununa ayrılan dikey alan: güvenlik şeridinin altından kontrol alanının dibine kadar.
    static func railRegion(available: Double, safety: Double, spacing: Double) -> Double {
        guard available > 0 else { return 0 }
        return max(0, available - safety - spacing)
    }

    /// Kaydırılan üst grupta bir sonraki düğmenin görünen kısmı (düğme boyunun oranı): kaydırılabildiğini belli eder.
    static let railPeek = 0.35

    /// Sütunun üst grubunun yüksekliği: `nil` → tüm düğmeler sığar, kaydırma yok. Sığmıyorsa üst grup bu
    /// yükseklikte kaydırılır; alt grup (Konum, +, −, Acil durum) her zaman tam boy kalır. Üst grup tam düğmeler
    /// ve altta bir sonrakinin küçük bir kısmını gösterir (yarım kesik simge yok); yer yine de yetmezse tek düğme
    /// boyudur (Katmanlar her ekranda erişilebilir). `side` düğme boyu, `chrome` iç boşluk ve ayırıcılar.
    static func railOptionalHeight(region: Double, side: Double, chrome: Double) -> Double? {
        guard region > 0, side > 0 else { return nil }
        let full = Double(railOptionalCount + railEssentialCount) * side + chrome
        if full <= region { return nil }
        let free = region - chrome - Double(railEssentialCount) * side
        let whole = min(Double(railOptionalCount - 1), ((free - railPeek * side) / side).rounded(.down))
        guard whole >= 1 else { return side }
        return (whole + railPeek) * side
    }
}
