import Foundation

/// İstanbul tür listesi (`BirdNET_Istanbul_Weeks.json`): fotoğraf modeli ve çevrimiçi tanıma bu listedeki
/// bilimsel adları kullanır (tools/kus_foto, tools/kus_sunucu).
/// - `lawName`: MAK listesinde farklı adla geçen türün MAK'taki adı (yasal durum sorgusu için).
/// - `turkishName`: av listesinde olmayan türlerde de Türkçe ad gösterilebilsin.
enum IstanbulSpecies {
    private struct Entry {
        let law: String
        let tr: String
    }

    private static let table: [String: Entry] = {
        guard let url = Bundle.main.url(forResource: BirdNETOnDevice.speciesFile, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(BirdNETOnDevice.SpeciesList.self, from: data) else { return [:] }
        var out: [String: Entry] = [:]
        for s in list.species where out[s.sci] == nil {
            out[s.sci] = Entry(law: s.mak ?? s.sci, tr: s.tr)
        }
        return out
    }()

    static func lawName(_ scientific: String) -> String {
        table[scientific]?.law ?? scientific
    }

    static func turkishName(_ scientific: String) -> String? {
        table[scientific]?.tr
    }
}
