import CoreLocation
import Foundation
import MapKit

/// İnternetsiz yer arama: uygulamayla gelen köy/ilçe/mesire noktaları ve avlak adları.
/// Eşleştirme Türkçeye duyarsızdır: büyük/küçük harf, İ/ı/i, ç/ğ/ö/ş/ü ve boşluklar fark etmez.
struct PlaceIndex {
    struct Entry: Identifiable {
        let id: Int
        let name: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
        /// Avlak gibi alanlarda haritaya sığdırılacak bölge.
        let rect: MKMapRect?
        fileprivate let key: String
        fileprivate let compact: String
        fileprivate let words: [String]
    }

    private let entries: [Entry]

    static var empty: PlaceIndex { PlaceIndex(entries: []) }

    private init(entries: [Entry]) { self.entries = entries }

    init(features: MapFeatures?, regs: Regulations?, areas: AvlakAreas) {
        var out: [Entry] = []
        func add(_ name: String, _ subtitle: String, _ c: CLLocationCoordinate2D, rect: MKMapRect? = nil) {
            let key = Self.normalize(name)
            out.append(Entry(id: out.count, name: name, subtitle: subtitle, coordinate: c, rect: rect,
                             key: key, compact: key.replacingOccurrences(of: " ", with: ""),
                             words: key.split(separator: " ").map(String.init)))
        }
        for a in regs?.avlaklar ?? [] {
            guard let area = areas.area(for: a) else { continue }
            add(LD(a.name), a.open ? L("Avlak") : L("Avlak (kapalı)"), area.labelPoint, rect: area.boundingRect)
        }
        for p in features?.places ?? [] {
            guard let n = p.name else { continue }
            add(n, p.title, p.coordinate)
        }
        entries = out
    }

    /// Küçük harf (Türkçe kurallarıyla), ı → i, aksanlar atılır, harf/rakam dışı karakterler boşluk olur.
    static func normalize(_ s: String) -> String {
        let lower = s.lowercased(with: Locale(identifier: "tr_TR")).replacingOccurrences(of: "ı", with: "i")
        let folded = lower.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "tr_TR"))
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    func search(_ query: String, limit: Int = 20) -> [Entry] {
        let q = Self.normalize(query)
        guard q.count >= 2 else { return [] }
        let qCompact = q.replacingOccurrences(of: " ", with: "")
        let qWords = q.split(separator: " ").map(String.init)
        var scored: [(score: Int, entry: Entry)] = []
        for e in entries {
            let score: Int
            if e.key == q || e.compact == qCompact {
                score = 0
            } else if e.compact.hasPrefix(qCompact) {
                score = 1
            } else if qWords.allSatisfy({ w in e.words.contains { $0.hasPrefix(w) } }) {
                score = 2
            } else if e.compact.contains(qCompact) {
                score = 3
            } else {
                continue
            }
            scored.append((score, e))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.entry.name.count < $1.entry.name.count }
            .prefix(limit)
            .map(\.entry)
    }

    /// Çevrimiçi sonuç yerel bir sonuçla aynı yer mi (aynı ad, 1 km'den yakın)?
    func isDuplicate(name: String, at c: CLLocationCoordinate2D, of local: [Entry]) -> Bool {
        let key = Self.normalize(name).replacingOccurrences(of: " ", with: "")
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return local.contains { e in
            (e.compact == key || key.contains(e.compact) || e.compact.contains(key))
                && here.distance(from: CLLocation(latitude: e.coordinate.latitude, longitude: e.coordinate.longitude)) < 1_000
        }
    }
}
