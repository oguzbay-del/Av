import Foundation

/// Kullanım kılavuzu: tek kaynak `Kilavuz.json` (uygulamayla gelir, internetsiz çalışır).
/// Yardım ekranı (`KilavuzView`), ilk açılış tanıtımı (`TanitimView`) ve `docs/KILAVUZ.md` /
/// `docs/USER_GUIDE.md` (`tools/kilavuz.py`) aynı dosyadan beslenir. Metinler Türkçedir; ekranda `LD()`
/// ile çevrilir (İngilizceleri `tools/l10n/en.json`).
struct Kilavuz: Decodable, Sendable {
    struct Bolum: Decodable, Identifiable, Sendable {
        let id: String
        let baslik: String
        let ikon: String?
    }

    struct Konu: Decodable, Identifiable, Sendable {
        let id: String
        let bolum: String
        let baslik: String
        let metin: String
        let ikon: String?
        /// İlk açılış tanıtımında da gösterilir (sırası dosyadaki sıradır).
        let tanitim: Bool?
        /// Konunun anlattığı özelliklerin kaynak dosyaları (`tools/kilavuz.py --check` denetler).
        let kaynak: [String]
        /// Yalnızca web sitesi (tools/destek_site.py): konunun ekran görüntüsü sahnesi
        /// (docs/site/gorsel/<dil>/<sahne>.webp). Uygulama görseli paketlemez ve bu alanı kullanmaz.
        let gorsel: String?

        var tanitimda: Bool { tanitim ?? false }
    }

    let bolumler: [Bolum]
    let konular: [Konu]

    static let dosyaAdi = "Kilavuz"

    /// Paketteki kılavuz (bir kez okunur). Okunamazsa boş kılavuz: ekran ve tanıtım sessizce boş kalır.
    static let paket: Kilavuz = (try? yukle()) ?? Kilavuz(bolumler: [], konular: [])

    static func yukle(bundle: Bundle = .main) throws -> Kilavuz {
        guard let url = bundle.url(forResource: dosyaAdi, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Kilavuz.self, from: Data(contentsOf: url))
    }

    /// Tanıtım sayfaları (dosya sırasıyla).
    var tanitimKonulari: [Konu] { konular.filter(\.tanitimda) }

    /// Bölüm sırasıyla, her bölümün konuları; `arama` boş değilse yalnızca eşleşen konular.
    /// Eşleşme çevrilmiş metinde büyük/küçük harf ve aksan duyarsızdır (`metin` dönüştürücüsüyle).
    func gruplar(arama: String = "", metin: (String) -> String = { $0 }) -> [Grup] {
        let q = arama.trimmingCharacters(in: .whitespacesAndNewlines)
        return bolumler.compactMap { b -> Grup? in
            let list = konular.filter { k in
                k.bolum == b.id && (q.isEmpty || Self.eslesir(q, [metin(k.baslik), metin(k.metin), metin(b.baslik)]))
            }
            return list.isEmpty ? nil : Grup(bolum: b, konular: list)
        }
    }

    /// Ekranda bir bölüm ve (aramaya uyan) konuları.
    struct Grup: Identifiable {
        let bolum: Bolum
        let konular: [Konu]
        var id: String { bolum.id }
    }

    static func eslesir(_ q: String, _ alanlar: [String]) -> Bool {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let locale = Locale(identifier: "tr_TR")
        // Her kelime bir alanda geçmeli ("gps eski" → iki kelime de)
        return q.split(separator: " ").allSatisfy { w in
            alanlar.contains { $0.range(of: w, options: opts, locale: locale) != nil }
        }
    }
}
