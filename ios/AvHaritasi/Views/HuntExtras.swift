import CoreLocation
import SwiftUI

private let hourFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "Europe/Istanbul")
    f.dateFormat = "HH"
    return f
}()

/// Rüzgârın estiği yönü gösteren ok (rüzgâr ALTI yönünü gösterir).
struct WindArrow: View {
    let windFrom: Double
    var body: some View {
        Image(systemName: "location.north.fill")
            .rotationEffect(.degrees(windFrom + 180))
            .accessibilityLabel("Rüzgâr \(Compass.name(windFrom)) yönünden")
    }
}

// MARK: - Bugün sekmesi: hava ve rüzgâr

struct WeatherSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            if let h = model.currentWeather, let w = model.weather {
                HStack(spacing: 14) {
                    WindArrow(windFrom: h.windFrom).font(.system(size: 34)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Compass.windName(from: h.windFrom)) · \(Int(h.windSpeed.rounded())) km/sa")
                            .font(.headline)
                        Text("Hamle \(Int(h.windGusts.rounded())) km/sa · \(Int(h.temperature.rounded()))°C · yağış %\(Int(h.precipitationChance))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Basınç") {
                    Text(pressureText(h.pressure, trend: w.pressureTrend(at: model.now)))
                }
                Text(scentAdvice(h))
                    .font(.caption)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(w.upcoming(from: model.now, count: 12)) { x in
                            VStack(spacing: 4) {
                                Text(hourFormatter.string(from: x.time)).font(.caption2).foregroundStyle(.secondary)
                                WindArrow(windFrom: x.windFrom).foregroundStyle(.blue)
                                Text("\(Int(x.windSpeed.rounded()))").font(.caption.monospacedDigit())
                                Text("\(Int(x.temperature.rounded()))°").font(.caption2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if let e = model.weatherError {
                Text(e).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack { ProgressView(); Text("Hava durumu alınıyor…").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Hava ve rüzgâr")
        } footer: {
            Text("Kaynak: Open-Meteo (CC BY 4.0). Rüzgâr hızı 10 m yükseklikte, km/sa. Ok rüzgârın estiği yönü gösterir.")
        }
    }

    private func pressureText(_ p: Double, trend: Double?) -> String {
        guard let t = trend else { return String(format: "%.0f hPa", p) }
        let arrow = t > 1 ? "↑ yükseliyor" : (t < -1 ? "↓ düşüyor" : "→ sabit")
        return String(format: "%.0f hPa %@", p, arrow)
    }

    private func scentAdvice(_ h: WeatherForecast.Hour) -> String {
        let downwind = Compass.name(h.windFrom + 180)
        if h.windSpeed < 3 {
            return "Rüzgâr çok hafif: kokunuz her yöne yayılır, av sizi kolay fark eder."
        }
        return "Kokunuz \(downwind) yönüne taşınıyor. Ava rüzgârı yüzünüze alarak (\(Compass.name(h.windFrom)) yönünden) yaklaşın. Haritadaki koku konisini rüzgâr düğmesiyle açabilirsiniz."
    }
}

// MARK: - Bugün sekmesi: av defteri ve günlük limit sayacı

struct HarvestSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var log: HarvestLog
    let regs: Regulations
    let day: Date

    var body: some View {
        let species = regs.huntableToday(on: day).flatMap(\.species)
        Section {
            if species.isEmpty {
                Text("Bugün avlanabilecek tür olmadığı için sayaç kapalı.").foregroundStyle(.secondary)
            }
            ForEach(species, id: \.self) { s in
                let st = log.status(for: s, on: day, regs: regs)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s).font(.subheadline)
                        Text(limitText(st)).font(.caption)
                            .foregroundStyle(st.isFull ? Color.red : Color.secondary)
                    }
                    Spacer()
                    Button { log.undoLast(s, on: day) } label: { Image(systemName: "minus.circle") }
                        .disabled(st.used == 0)
                    Text("\(st.used)").font(.title3.monospacedDigit().bold()).frame(minWidth: 28)
                    Button {
                        log.add(s, at: model.location?.coordinate, date: AppClock.now())
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(st.isFull)
                }
                .buttonStyle(.borderless)
                .font(.title3)
            }
            NavigationLink("Av defteri") { HarvestHistoryView(log: log) }
        } header: {
            Text("Bugünkü avım")
        } footer: {
            Text("Kayıtlar yalnızca bu cihazda tutulur. Limit dolunca + düğmesi kapanır. Ördekler için grup toplamı (6) ve tür sınırları birlikte uygulanır.")
        }
    }

    private func limitText(_ s: HarvestLog.LimitStatus) -> String {
        var parts: [String] = []
        if let m = s.max { parts.append("Limit \(m)") }
        if let gm = s.groupMax, let gu = s.groupUsed { parts.append("grup \(gu)/\(gm)") }
        if parts.isEmpty { return "Limitsiz" }
        if s.isFull { return parts.joined(separator: " · ") + " — limit doldu" }
        if let r = s.remaining { parts.append("kalan \(r)") }
        return parts.joined(separator: " · ")
    }
}

struct HarvestHistoryView: View {
    @ObservedObject var log: HarvestLog

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.dateFormat = "d MMMM yyyy EEEE"
        return f
    }()

    var body: some View {
        List {
            let days = log.days(limit: 60)
            if days.isEmpty {
                ContentUnavailableView("Kayıt yok", systemImage: "book.closed",
                                       description: Text("Bugün sekmesindeki + düğmesiyle avınızı kaydedin."))
            }
            ForEach(days) { d in
                Section(Self.dayFormat.string(from: d.day)) {
                    ForEach(d.items, id: \.species) { item in
                        LabeledContent(item.species, value: "\(item.count)")
                    }
                }
            }
        }
        .navigationTitle("Av defteri")
    }
}

// MARK: - Harita: rüzgâr rozeti

struct WindBadge: View {
    let hour: WeatherForecast.Hour
    let showCone: Bool

    var body: some View {
        HStack(spacing: 6) {
            WindArrow(windFrom: hour.windFrom).foregroundStyle(.blue)
            Text("\(Compass.name(hour.windFrom)) \(Int(hour.windSpeed.rounded()))")
                .font(.caption.bold().monospacedDigit())
            Image(systemName: showCone ? "nose.fill" : "nose").font(.caption)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.regularMaterial, in: Capsule())
    }
}
