import Foundation

/// Harita ekranının üst (güvenlik şeridi, kartlar) ve alt (kontroller, alt panel) yığınlarının yerleşim kararı
/// (saf mantık, birim testli). Güvenlik şeridi ve −/+ ile konum düğmeleri hiçbir zaman gizlenmez; küçük ekranda
/// (iPhone SE, saha modu) sorgu kartı ya da öneri açıkken yer yetmezse önce alt panel geçici olarak çekilir.
enum MapOverlayLayout {
    /// Alt panel gizlensin mi? Tüm yükseklikler pt; `cards` açık kartların doğal yüksekliği (yoksa 0),
    /// `available` kontrol alanının yüksekliği (ölçülmeden önce 0 → gizlenmez).
    static func hidesPanel(available: Double, safety: Double, cards: Double,
                           controls: Double, panel: Double, spacing: Double) -> Bool {
        guard available > 0, cards > 0, panel > 0 else { return false }
        let needed = safety + cards + controls + panel + 3 * spacing
        return needed > available
    }
}
