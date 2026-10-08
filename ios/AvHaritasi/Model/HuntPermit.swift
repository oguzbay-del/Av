import CoreGraphics
import CoreLocation
import Foundation

/// AVBİS "Avlanma İzin Belgesi" (ör. "İstanbul İli Beykoz Devlet Avlağı 2026-2027 Av Dönemi Avlanma İzin Belgesi").
/// Kişisel bilgiler (ad soyad, avcılık belgesi ve izin kartı numarası) okunur ama SAKLANMAZ.
struct HuntPermit: Codable, Identifiable, Equatable {
    struct Quota: Codable, Equatable, Hashable {
        let species: String   // MAK'taki Türkçe tür adı
        let count: Int
    }

    var id = UUID()
    var number: String?          // Belge numarası
    var avlak: String            // MAK 2026-27 avlak adı, ör. "Beykoz Devlet Avlağı"
    var date: Date               // Belgenin geçerli olduğu gün (İstanbul saatiyle gün başı)
    var quotas: [Quota]
    var verifyURL: String?       // Belgedeki karekod bir bağlantıysa
    var addedAt = Date()

    func isValid(on day: Date) -> Bool {
        Regulations.istanbulCalendar.isDate(date, inSameDayAs: day)
    }

    func quota(for species: String) -> Int? {
        quotas.first { $0.species == species }?.count
    }
}

/// Cihazda saklanan izin belgeleri ve elle seçilen avlak.
@MainActor
final class PermitStore: ObservableObject {
    @Published private(set) var permits: [HuntPermit] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("izin_belgeleri.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([HuntPermit].self, from: data) {
            permits = list.sorted { $0.date > $1.date }
        }
    }

    private func save() {
        try? JSONEncoder().encode(permits).write(to: url, options: [.atomic, .completeFileProtection])
    }

    func add(_ p: HuntPermit) {
        // Aynı belge numarası tekrar eklenirse güncelle
        permits.removeAll { $0.number != nil && $0.number == p.number }
        permits.append(p)
        permits.sort { $0.date > $1.date }
        save()
    }

    func delete(_ p: HuntPermit) {
        permits.removeAll { $0.id == p.id }
        save()
    }

    func active(on day: Date) -> [HuntPermit] {
        permits.filter { $0.isValid(on: day) }
    }
}

// MARK: - Belge metnini çözümleme

enum PermitParser {
    struct Result {
        var permit: HuntPermit?
        var problems: [String]
    }

    /// OCR metin parçası ve kutusu (Vision: 0-1, sol-alt orijin).
    struct TextItem {
        let text: String
        let box: CGRect
    }

    /// Türkçe harfleri sadeleştirilmiş, büyük harfli, tek boşluklu metin (OCR hatalarına dayanıklı eşleşme için).
    static func normalize(_ s: String) -> String {
        let map: [Character: Character] = ["İ": "I", "ı": "I", "i": "I", "Ş": "S", "ş": "S", "Ğ": "G", "ğ": "G",
                                           "Ü": "U", "ü": "U", "Ö": "O", "ö": "O", "Ç": "C", "ç": "C"]
        let up = String(s.map { map[$0] ?? $0 }).uppercased()
        let cleaned = up.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "/" ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    static func parse(_ text: String, items: [TextItem] = [], regs: Regulations, verifyURL: String?) -> Result {
        let t = normalize(text)
        var problems: [String] = []

        // 1) Avlak: "BEYKOZ DEVLET AVLAGI" (boşluklar OCR'da kayabilir → boşluksuz da ara)
        let compact = t.replacingOccurrences(of: " ", with: "")
        var best: (name: String, score: Int)?
        for a in regs.avlaklar {
            let key = normalize(a.name).replacingOccurrences(of: " ", with: "")
            let place = normalize(String(a.name.split(separator: " ").first ?? "")).replacingOccurrences(of: " ", with: "")
            var score = compact.components(separatedBy: key).count - 1
            if score == 0, compact.contains(place + "DEVLET") || compact.contains(place + "GENEL") || compact.contains(place + "ORNEK") {
                score = 1
            }
            if score > 0, score > (best?.score ?? 0) { best = (a.name, score) }
        }
        guard let avlak = best?.name else {
            return Result(permit: nil, problems: [L("Belgede avlak adı bulunamadı. Avlağı listeden elle seçin.")])
        }

        // 2) Geçerlilik tarihi: "GECERLI OLDUGU TARIH 4.10.2026"
        let dateRx = try! NSRegularExpression(pattern: #"(\d{1,2})[./](\d{1,2})[./](20\d{2})"#)
        func dates(in s: String) -> [Date] {
            dateRx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
                guard let d = Int(s[Range(m.range(at: 1), in: s)!]), let mo = Int(s[Range(m.range(at: 2), in: s)!]),
                      let y = Int(s[Range(m.range(at: 3), in: s)!]) else { return nil }
                return Regulations.istanbulCalendar.date(from: DateComponents(year: y, month: mo, day: d))
            }
        }
        let afterValid = t.range(of: "GECERLI").map { String(t[$0.upperBound...]) } ?? t
        let date = dates(in: afterValid).first ?? dates(in: t).first
        if date == nil { problems.append(L("Geçerlilik tarihi okunamadı; bugünün tarihi kullanıldı.")) }

        // 3) Belge numarası
        var number: String?
        if let r = t.range(of: "BELGE NUMARASI") {
            number = String(t[r.upperBound...]).split(separator: " ").first { $0.allSatisfy(\.isNumber) && $0.count >= 5 }.map(String.init)
        }

        // 4) Türler ve kotalar: yalnızca "AVINA IZIN VERILEN" ile "YASAKLI" arasındaki bölüm
        //    (alttaki dipnot da tür adları içerir: karga, saksağan, tilki...)
        var section = t
        if let s0 = t.range(of: "IZIN VERILEN TUR") ?? t.range(of: "AVINA IZIN") {
            section = String(t[s0.upperBound...])
        }
        if let e = section.range(of: "YASAKLI") ?? section.range(of: "AVLAK SINIRLARI") {
            section = String(section[..<e.lowerBound])
        }
        let speciesList = regs.groups.flatMap(\.species)
        var found: [(index: String.Index, species: String)] = []
        for sp in speciesList {
            let key = normalize(sp)
            var from = section.startIndex
            while let r = section.range(of: key, range: from..<section.endIndex) {
                // "KUCUK KARGA" içindeki "KARGA" gibi alt eşleşmeleri ele: kelime sınırı
                let beforeOK = r.lowerBound == section.startIndex || section[section.index(before: r.lowerBound)] == " "
                let afterOK = r.upperBound == section.endIndex || section[r.upperBound] == " "
                if beforeOK && afterOK { found.append((r.lowerBound, sp)) }
                from = r.upperBound
            }
        }
        found.sort { $0.index < $1.index }
        // Uzun adı içeren kısa adları at (ör. "Boz ördek" ↔ "ördek")
        var uniq: [(String.Index, String)] = []
        for f in found where !uniq.contains(where: { $0.1 == f.species }) { uniq.append((f.index, f.species)) }

        var quotas: [HuntPermit.Quota] = []
        // Konum bilgisi varsa (OCR): tür adını, sağındaki sütunda dikeyde en yakın sayıyla eşle.
        // Tabloda sayı hücrenin üstünde, tür adı ortasında olabilir; metin sırası güvenilmez.
        let geo = geometricQuotas(items, species: uniq.map(\.1))
        if !geo.isEmpty {
            let q = uniq.compactMap { f in geo[f.1].map { HuntPermit.Quota(species: f.1, count: $0) } }
            if q.count == uniq.count {
                return finish(avlak: avlak, number: number, date: date, quotas: q, problems: problems, text: t, verifyURL: verifyURL)
            }
        }
        func ints(_ sub: Substring) -> [Int] {
            sub.split(separator: " ").compactMap { w in w.allSatisfy(\.isNumber) ? Int(w) : nil }.filter { (1...100).contains($0) }
        }
        // Satır düzeni: "BILDIRCIN 10 UVEYIK 3" — her tür adının ardından bir sonraki tür adına kadar bir sayı.
        // Sütun düzeni: "BILDIRCIN UVEYIK 10 3" — OCR tablo sütunlarını ayrı okumuş; sayılar sırayla eşlenir.
        let slices: [[Int]] = uniq.enumerated().map { i, f in
            let start = section.index(f.0, offsetBy: normalize(f.1).count, limitedBy: section.endIndex) ?? section.endIndex
            let end = i + 1 < uniq.count ? uniq[i + 1].0 : section.endIndex
            return start < end ? ints(section[start..<end]) : []
        }
        let rowLayout = !slices.isEmpty && slices.allSatisfy { !$0.isEmpty }
        let ordered = uniq.first.map { ints(section[$0.0...]) } ?? []
        for (i, f) in uniq.enumerated() {
            let n = rowLayout ? slices[i].first : (i < ordered.count ? ordered[i] : nil)
            if let n {
                quotas.append(.init(species: f.1, count: n))
            } else if let lim = regs.limitRule(for: f.1)?.max {
                quotas.append(.init(species: f.1, count: lim))
                problems.append(L("%@ için kota okunamadı; MAK günlük limiti (%@) kullanıldı.", LD(f.1), String(lim)))
            }
        }
        return finish(avlak: avlak, number: number, date: date, quotas: quotas, problems: problems, text: t, verifyURL: verifyURL)
    }

    private static func finish(avlak: String, number: String?, date: Date?, quotas: [HuntPermit.Quota],
                               problems: [String], text t: String, verifyURL: String?) -> Result {
        var problems = problems
        if quotas.isEmpty { problems.append(L("Belgede izin verilen tür bulunamadı.")) }
        if !t.contains("2026 2027") && !t.contains("20262027") {
            problems.append(L("Belge 2026-2027 av dönemine ait görünmüyor."))
        }
        let permit = HuntPermit(number: number, avlak: avlak,
                                date: date ?? Regulations.istanbulCalendar.startOfDay(for: AppClock.now()),
                                quotas: quotas, verifyURL: verifyURL)
        return Result(permit: permit, problems: problems)
    }

    /// Tür kutusunun sağında, dikey merkezi en yakın (en fazla ~3 satır uzaklıkta) 1-100 arası sayı.
    static func geometricQuotas(_ items: [TextItem], species: [String]) -> [String: Int] {
        guard !items.isEmpty else { return [:] }
        // Tablo bölümü: "İzin Verilen" başlığının altı, "Yasaklı Türler"in üstü (Vision'da y yukarı doğru artar)
        // Dipnotta da "izin verilen" geçer: en üstteki eşleşme tablo başlığıdır
        let top = items.filter { normalize($0.text).contains("IZIN VERILEN") || normalize($0.text).contains("KOTA") }
            .max { $0.box.midY < $1.box.midY }?.box.minY ?? 1
        let bottom = items.filter { normalize($0.text).contains("YASAKLI") && $0.box.midY < top }
            .max { $0.box.midY < $1.box.midY }?.box.maxY ?? 0
        let inTable = items.filter { $0.box.midY < top && $0.box.midY > bottom }
        let numbers: [(Int, CGRect)] = inTable.compactMap { it in
            let w = normalize(it.text).split(separator: " ")
            guard w.count == 1, let n = Int(w[0]), (1...100).contains(n) else { return nil }
            return (n, it.box)
        }
        var out: [String: Int] = [:]
        for sp in species {
            let key = normalize(sp)
            guard let s = inTable.first(where: { (" " + normalize($0.text) + " ").contains(" " + key + " ") }) else { continue }
            let cand = numbers.filter { $0.1.minX > s.box.midX }
                .map { (n: $0.0, dy: abs($0.1.midY - s.box.midY)) }
                .filter { $0.dy < s.box.height * 4 }
                .min { $0.dy < $1.dy }
            if let c = cand { out[sp] = c.n }
        }
        return out
    }
}
