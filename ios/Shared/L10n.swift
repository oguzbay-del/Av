import Foundation

/// Yerelleştirme. Anahtar, metnin Türkçesidir (kaynak dil); çeviriler `Localizable.xcstrings`
/// kataloğundadır ve `tools/l10n.py` ile kaynak koddan toplanıp denetlenir.
/// Yer tutucular her zaman `%@` (sayılar önceden metne çevrilir).
///
///     L("Karayoluna %@", Geo.formatDistance(d))
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, locale: AppLocale.current, arguments: args)
}

/// Veri dosyalarından gelen metin (kural, tür, bölge adı...). Anahtar aynen veri metnidir.
func LD(_ text: String) -> String {
    Bundle.main.localizedString(forKey: text, value: text, table: nil)
}

enum AppLocale {
    /// Uygulamanın gösterdiği dil (iOS Ayarlar › Av Haritası › Dil ile de değiştirilebilir).
    static var isEnglish: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true }

    /// Tarih ve sayı biçimleri için.
    static var current: Locale { Locale(identifier: isEnglish ? "en_GB" : "tr_TR") }
}

/// Gizlilik politikası (KVKK) — dile göre Türkçe ya da İngilizce sürüm.
enum PrivacyPolicy {
    static var url: URL {
        URL(string: AppLocale.isEnglish
            ? "https://github.com/oguzbay-del/Av/blob/main/docs/PRIVACY.md"
            : "https://github.com/oguzbay-del/Av/blob/main/docs/GIZLILIK.md")!
    }
}
