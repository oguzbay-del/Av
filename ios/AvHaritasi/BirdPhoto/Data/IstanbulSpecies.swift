import Foundation

/// İstanbul tür listesi (`BirdNET_Istanbul_Weeks.json`): fotoğraf modeli ve çevrimiçi tanıma bu listedeki
/// bilimsel adları kullanır (tools/kus_foto, tools/kus_sunucu).
/// - `lawName`: MAK listesinde farklı adla geçen türün MAK'taki adı (yasal durum sorgusu için).
/// - `turkishName`: av listesinde olmayan türlerde de Türkçe ad gösterilebilsin.
/// - `occurrence`: türün o hafta İstanbul'da görülme ölçüsü (0…1, `SeasonalPrior`).
enum IstanbulSpecies {
    private struct Entry {
        let law: String
        let tr: String
        let weeks: String
    }

    private static let table: [String: Entry] = {
        guard let url = Bundle.main.url(forResource: BirdNETOnDevice.speciesFile, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(BirdNETOnDevice.SpeciesList.self, from: data) else { return [:] }
        var out: [String: Entry] = [:]
        for s in list.species where out[s.sci] == nil {
            out[s.sci] = Entry(law: s.mak ?? s.sci, tr: s.tr, weeks: s.weeks)
        }
        return out
    }()

    static func lawName(_ scientific: String) -> String {
        table[scientific]?.law ?? scientific
    }

    static func turkishName(_ scientific: String) -> String? {
        table[scientific]?.tr
    }

    static func occurrence(_ scientific: String, week: Int) -> Double? {
        table[scientific].flatMap { SeasonalPrior.occurrence(weeks: $0.weeks, week: week) }
    }
}
