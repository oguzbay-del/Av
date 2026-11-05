import Foundation

/// Av mühimmatı bilgi tablosu (`Hunting/Data/AvMuhimmat.json`, okunabilir hâli `docs/AV_MUHIMMAT.md`;
/// denetim `tools/av_muhimmat_denetim.py`). Yalnızca okunur; öneri motoru (`AmmoAdvisor`) ve başvuru tablosu kullanır.
struct AmmoKnowledge: Decodable, Sendable {
    struct ShotSize: Decodable, Sendable, Identifiable {
        let id: String
        let mm: Double
        let pelletsPer32gLead: Int?
        let pelletsPer32gSteel: Int?
        let steelOnly: Bool
    }

    struct ChokeInfo: Decodable, Sendable, Identifiable {
        let id: Int
        let name: String
        let tr: String
        let marks: String
        let patternPct35m: Int
        let effectiveRangeM: [Int]
        let steel: String
        let note: String
    }

    struct Paradox: Decodable, Sendable {
        let tr: String
        let use: String
    }

    struct Steel: Decodable, Sendable {
        let sizeRule: String
        let sizeStep: Int
        let chokeRule: String
        let maxChokeId: Int
        let proof: String
    }

    struct Terrain: Decodable, Sendable, Identifiable {
        let id: String
        let tr: String
        let distanceM: [Int]
        let chokeShift: Int
        let shotShift: Int
        let note: String
    }

    struct ShotChoice: Decodable, Sendable {
        let primary: String
        let alternatives: [String]

        /// Birincil önce, sonra alternatifler.
        var all: [String] { [primary] + alternatives }
    }

    struct ChokePlan: Decodable, Sendable {
        let first: Int
        let second: Int
        let steelFirst: Int
        let steelSecond: Int
    }

    struct Slug: Decodable, Sendable {
        let gauges: [String]
        let grams12: [Int]
        let grams20: [Int]?
        let chokes: [Choke]
        let maxRangeM: Int
        let note: String

        private enum CodingKeys: String, CodingKey { case gauges, grams12, grams20, chokes, maxRangeM, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            gauges = try c.decode([String].self, forKey: .gauges)
            grams12 = try c.decode([Int].self, forKey: .grams12)
            grams20 = try c.decodeIfPresent([Int].self, forKey: .grams20)
            maxRangeM = try c.decode(Int.self, forKey: .maxRangeM)
            note = try c.decode(String.self, forKey: .note)
            // [5, 4, "paradoks"]: sayı ya da "paradoks"
            var list = try c.nestedUnkeyedContainer(forKey: .chokes)
            var out: [Choke] = []
            while !list.isAtEnd {
                if let n = try? list.decode(Int.self) {
                    if let ch = Choke(rawValue: n) { out.append(ch) }
                } else if (try? list.decode(String.self)) != nil {
                    out.append(.paradox)
                } else {
                    throw DecodingError.dataCorruptedError(in: list, debugDescription: "Geçersiz şok")
                }
            }
            chokes = out
        }
    }

    struct Rifle: Decodable, Sendable {
        let calibers: [String]
        let note: String
        let maxRangeM: Int
        let minCaliberMm: Double?
    }

    struct Species: Decodable, Sendable, Identifiable {
        var id: String { name }
        let name: String
        let latin: String
        let group: String
        /// "kuş" ya da "memeli".
        let category: String
        let distanceM: [Int]
        let terrains: [String]
        let shotAllowed: Bool
        let leadShot: ShotChoice?
        let steelShot: ShotChoice?
        let loadGrams12: [Int]?
        let loadGrams20: [Int]?
        let choke: ChokePlan?
        let gauges: [String]
        let minGauge: String
        let magnumNeeded: Bool
        let slug: Slug?
        let rifle: Rifle?
        let aim: String
        let maxEthicalRangeM: Int
        let notes: String
        let sources: [String]
        /// "high", "medium", "low".
        let confidence: String

        var isBird: Bool { category == "kuş" }
        var isLowConfidence: Bool { confidence == "low" }
        /// Yivli tüfek bu türde yasak mı (MAK 10/1-ğ: kuş ve tavşan).
        var rifleBanned: Bool { isBird || name == "Yaban tavşanı" }
        /// Su kuşu (sulak alan türü): kurşunsuz saçma etik önerisi.
        var isWaterfowl: Bool { isBird && terrains.first == "sulak_alan" || name == "Sakarca" }
        /// Yürüyüş/köpek önü avı (hafif tüfek avantajlı).
        var isWalkingHunt: Bool { !isWaterfowl && (terrains.contains("orman_cali") || terrains.first == "acik_mera") }
    }

    let disclaimer: String
    let sources: [String: String]
    let shotSizes: [ShotSize]
    let chokes: [ChokeInfo]
    let paradox: Paradox
    let steel: Steel
    let terrains: [Terrain]
    let species: [Species]

    static let fileName = "AvMuhimmat"

    static func load(bundle: Bundle = .main) throws -> AmmoKnowledge {
        guard let url = bundle.url(forResource: fileName, withExtension: "json")
                ?? bundle.url(forResource: fileName, withExtension: "json", subdirectory: "Data") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(AmmoKnowledge.self, from: Data(contentsOf: url))
    }

    /// Uygulama boyunca tek kopya (paket içi, değişmez).
    static let shared: AmmoKnowledge? = try? load()

    func species(named name: String) -> Species? { species.first { $0.name == name } }
    func shot(_ id: String) -> ShotSize? { shotSizes.first { $0.id == id } }
    func terrain(_ id: String?) -> Terrain? { id.flatMap { t in terrains.first { $0.id == t } } }
    func chokeInfo(_ c: Choke) -> ChokeInfo? { chokes.first { $0.id == c.rawValue } }

    /// Saçma numarasını n adım iri/ufak kaydırır (shotSizes iriden ufağa sıralı; negatif = iri).
    func shiftedShot(_ id: String, by steps: Int, steel: Bool) -> String {
        let list = shotSizes.filter { steel || !$0.steelOnly }
        guard steps != 0, let i = list.firstIndex(where: { $0.id == id }) else { return id }
        return list[min(list.count - 1, max(0, i + steps))].id
    }
}
