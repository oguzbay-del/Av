#if canImport(WidgetKit)
import SwiftUI
import WidgetKit

/// Ana ekran / kilit ekranı aracı (AvDurumWidget) ve saat komplikasyonu (AvSaatKomplikasyon)
/// için ortak zaman çizelgesi kaydı ve görünümü.
struct AvDurumKaydi: TimelineEntry {
    let date: Date
    let snapshot: StatusSnapshot?
}

extension StatusSnapshot {
    /// Görünümün değiştiği anlar: şimdi, durumun "güncel değil" olacağı an ve av saati sınırları.
    func timelineDates(from now: Date) -> [Date] {
        let points = [updated.addingTimeInterval(Self.staleAfter), huntStart, huntEnd, nextHuntStart, nextHuntEnd]
        return [now] + points.compactMap { $0 }.filter { $0 > now }.sorted()
    }

    static func timeline(_ s: StatusSnapshot?, now: Date = Date()) -> Timeline<AvDurumKaydi> {
        let dates = s?.timelineDates(from: now) ?? [now]
        let entries = dates.map { AvDurumKaydi(date: $0, snapshot: s) }
        // Son sınırdan sonra (ya da en geç 2 saatte bir) yeniden sor
        let next = max(dates.last ?? now, now).addingTimeInterval(dates.count > 1 ? 60 : 2 * 3600)
        return Timeline(entries: entries, policy: .after(next))
    }

    static var placeholder: StatusSnapshot {
        StatusSnapshot(level: 1, title: L("Avlanabilir"), reason: "", nearest: nil, nearestMeters: nil,
                       huntStart: Date().addingTimeInterval(-3600), huntEnd: Date().addingTimeInterval(3 * 3600),
                       updated: Date())
    }
}

struct AvDurumAracGorunumu: View {
    let entry: AvDurumKaydi
    @Environment(\.widgetFamily) private var family

    private var snapshot: StatusSnapshot? { entry.snapshot }
    private var stale: Bool { snapshot?.isStale(at: entry.date) ?? true }
    private var style: AvDurumStili { AvDurumStili(level: snapshot?.level ?? 0, stale: stale) }
    private var window: (start: Date, end: Date, active: Bool)? { snapshot?.huntWindow(at: entry.date) }
    private var isSmall: Bool {
        #if os(iOS)
        return family == .systemSmall
        #else
        return false
        #endif
    }
    private var title: String {
        guard let snapshot else { return L("Veri bekleniyor") }
        return stale ? L("Güncel değil") : snapshot.title
    }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if isSmall {
                    style.color.opacity(0.18)
                } else {
                    Color.clear
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: style.symbol).font(.title3.bold()).widgetAccentable()
                    if let w = window {
                        Text(w.active ? w.end : w.start, style: .time)
                            .font(.system(size: 10, weight: .semibold)).minimumScaleFactor(0.6)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
        case .accessoryInline:
            if let w = window, w.active, !stale {
                Label { Text(verbatim: style.short + " · ") + Text(w.end, style: .relative) }
                    icon: { Image(systemName: style.symbol) }
            } else {
                Label(title, systemImage: style.symbol)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(title, systemImage: style.symbol)
                    .font(.headline).widgetAccentable().lineLimit(1)
                if let n = snapshot?.nearest, !stale {
                    Text(n).font(.caption).lineLimit(1)
                }
                huntLine.font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: style.symbol)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(style.color)
                Text(title).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                if let n = snapshot?.nearest, !stale {
                    Text(n).font(.caption2.bold()).foregroundStyle(.red).lineLimit(1)
                }
                Spacer(minLength: 0)
                huntLine.font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var huntLine: some View {
        if let w = window {
            if w.active {
                Text(L("Av saati bitişi:")) + Text(verbatim: " ") + Text(w.end, style: .relative)
            } else {
                Text(L("Av saati başlangıcı:")) + Text(verbatim: " ") + Text(w.start, style: .time)
            }
        } else if snapshot == nil {
            Text(L("Av Haritası'nı açın"))
        }
    }
}

#endif
