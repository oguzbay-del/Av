import SwiftUI
import WidgetKit

/// Apple Watch saat yüzü komplikasyonu: AvSaat'in App Group'a yazdığı son av durumu
/// (iPhone'dan gelen WatchStatus) ve avlanma saati.
@main
struct AvSaatKomplikasyonBundle: WidgetBundle {
    var body: some Widget {
        AvSaatKomplikasyon()
    }
}

struct AvSaatKomplikasyon: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AvSaatKomplikasyon", provider: KomplikasyonSaglayici()) { entry in
            AvDurumAracGorunumu(entry: entry)
        }
        .configurationDisplayName("Av durumu")
        .description("iPhone'daki Av Haritası'nın hesapladığı av durumu ve avlanma saati.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct KomplikasyonSaglayici: TimelineProvider {
    private static func load() -> StatusSnapshot? {
        guard let data = AppGroup.defaults.data(forKey: WatchStatus.key), let s = WatchStatus(data: data) else { return nil }
        return StatusSnapshot(level: s.level, title: s.title, reason: s.detail, nearest: s.nearest, nearestMeters: nil,
                              huntStart: s.huntStart, huntEnd: s.huntEnd, updated: s.updated)
    }

    func placeholder(in context: Context) -> AvDurumKaydi {
        AvDurumKaydi(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AvDurumKaydi) -> Void) {
        completion(AvDurumKaydi(date: Date(), snapshot: context.isPreview ? .placeholder : Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AvDurumKaydi>) -> Void) {
        completion(StatusSnapshot.timeline(Self.load()))
    }
}
