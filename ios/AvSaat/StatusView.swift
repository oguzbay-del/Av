import SwiftUI

/// Büyük renkli av durumu, kısa açıklama, rüzgâr, en yakın yasak alan ve son güncelleme.
struct StatusView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
            .navigationTitle(L("Av Durumu"))
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let stale = store.isStale(at: now)
        let status = store.status
        let style = LevelStyle(level: status?.level ?? 0, stale: stale)
        ScrollView {
            VStack(spacing: 6) {
                Image(systemName: style.symbol)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(style.color)
                    .accessibilityHidden(true)

                Text(status?.title ?? L("Veri bekleniyor"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(style.color)

                if let status {
                    Text(status.detail)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                } else {
                    Text("iPhone'da Av Haritası'nı açın.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                if let wind = status?.wind {
                    Label(wind, systemImage: "wind")
                        .font(.footnote)
                }
                if let nearest = status?.nearest {
                    Label(nearest, systemImage: "location.north.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(.red)
                }

                if stale {
                    Label(L("Telefonla bağlantı yok"), systemImage: "iphone.slash")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                        .padding(.top, 4)
                }
                if let updated = status?.updated {
                    Text(updatedText(updated, now: now))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .containerBackground(style.color.opacity(0.35).gradient, for: .navigation)
        .accessibilityElement(children: .combine)
    }

    private func updatedText(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let ago: String
        if seconds < 60 {
            ago = L("az önce")
        } else if seconds < 3600 {
            ago = L("%@ dk önce", String(Int(seconds / 60)))
        } else {
            let f = DateFormatter()
            f.locale = AppLocale.current
            f.dateFormat = "d MMM HH:mm"
            ago = f.string(from: date)
        }
        return L("Güncelleme: %@", ago)
    }
}

/// Seviye → renk ve SF Symbol. Bayat veri gri gösterilir (eski bir "avlanabilir" yanıltmasın).
struct LevelStyle {
    let symbol: String
    let color: Color

    init(level: Int, stale: Bool) {
        let base: Color
        switch level {
        case 3: symbol = "xmark.octagon.fill"; base = .red
        case 2: symbol = "exclamationmark.triangle.fill"; base = .orange
        case 1: symbol = "checkmark.shield.fill"; base = .green
        default: symbol = "location.slash"; base = .gray
        }
        color = stale ? .gray : base
    }
}
