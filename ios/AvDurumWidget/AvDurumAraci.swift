import SwiftUI
import WidgetKit

/// Ana ekran ve kilit ekranı aracı: uygulamanın App Group'a yazdığı son av durumu ve avlanma saati.
struct AvDurumAraci: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AvDurumAraci", provider: AvDurumSaglayici()) { entry in
            AvDurumAracGorunumu(entry: entry)
        }
        .configurationDisplayName("Av durumu")
        .description("Bulunduğunuz yerin av durumu ve avlanma saatinin bitişi.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

struct AvDurumSaglayici: TimelineProvider {
    func placeholder(in context: Context) -> AvDurumKaydi {
        AvDurumKaydi(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AvDurumKaydi) -> Void) {
        completion(AvDurumKaydi(date: Date(), snapshot: context.isPreview ? .placeholder : StatusSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AvDurumKaydi>) -> Void) {
        completion(StatusSnapshot.timeline(StatusSnapshot.load()))
    }
}
