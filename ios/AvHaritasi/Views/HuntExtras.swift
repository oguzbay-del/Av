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
            .accessibilityLabel(L("Rüzgâr %@ yönünden", Compass.name(windFrom)))
    }
}

// MARK: - Bugün sekmesi: hava ve rüzgâr

struct WeatherSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let h = model.currentWeather, let w = model.weather {
                HStack(spacing: 14) {
                    WindArrow(windFrom: h.windFrom).font(.system(size: 34)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("%@ · %@ km/sa", Compass.windName(from: h.windFrom), String(Int(h.windSpeed.rounded()))))
                            .font(.headline)
                        Text(L("Hamle %@ km/sa · %@°C · yağış %%%@", String(Int(h.windGusts.rounded())), String(Int(h.temperature.rounded())), String(Int(h.precipitationChance))))
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
                                Text(verbatim: String(Int(x.windSpeed.rounded()))).font(.caption.monospacedDigit())
                                Text(verbatim: "\(Int(x.temperature.rounded()))°").font(.caption2)
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
        let arrow = t > 1 ? L("↑ yükseliyor") : (t < -1 ? L("↓ düşüyor") : L("→ sabit"))
        return String(format: "%.0f hPa %@", p, arrow)
    }

    private func scentAdvice(_ h: WeatherForecast.Hour) -> String {
        let downwind = Compass.name(h.windFrom + 180)
        if h.windSpeed < 3 {
            return L("Rüzgâr çok hafif: kokunuz her yöne yayılır, av sizi kolay fark eder.")
        }
        return L("Kokunuz %@ yönüne taşınıyor. Ava rüzgârı yüzünüze alarak (%@ yönünden) yaklaşın. Haritadaki koku konisini rüzgâr düğmesiyle açabilirsiniz.", downwind, Compass.name(h.windFrom))
    }
}

// MARK: - Bugün sekmesi: av defteri ve günlük limit sayacı

struct HarvestSection: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var log: HarvestLog
    let regs: Regulations
    let day: Date

    var body: some View {
        let open = regs.huntableToday(on: day).flatMap(\.species)
        let permit = model.permits.active(on: day).first
        // Bugüne ait izin belgesi varsa yalnızca belgedeki türler, belgedeki kotayla
        let species = permit.map { p in open.filter { p.quota(for: $0) != nil } } ?? open
        Section {
            if let permit {
                Label(L("İzin belgesi: %@", LD(permit.avlak)), systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if species.isEmpty {
                Text("Bugün avlanabilecek tür olmadığı için sayaç kapalı.").foregroundStyle(.secondary)
            }
            ForEach(species, id: \.self) { s in
                let st = capped(log.status(for: s, on: day, regs: regs), by: permit?.quota(for: s))
                HStack {
                    SpeciesIcon.image(for: s, regs: regs)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LD(s)).font(.subheadline)
                        Text(limitText(st)).font(.caption)
                            .foregroundStyle(st.isFull ? Color.red : Color.secondary)
                    }
                    Spacer()
                    Button { log.undoLast(s, on: day) } label: { Image(systemName: "minus.circle") }
                        .disabled(st.used == 0)
                    Text(verbatim: String(st.used)).font(.title3.monospacedDigit().bold()).frame(minWidth: 28)
                    Button {
                        log.add(s, at: model.location?.coordinate, date: AppClock.now())
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolEffect(.bounce, value: st.used)
                    }
                        .disabled(st.isFull)
                }
                .buttonStyle(.borderless)
                .sensoryFeedback(.increase, trigger: st.used)
                .font(.title3)
            }
            NavigationLink("Av defteri") { HarvestHistoryView(log: log) }
        } header: {
            Text("Bugünkü avım")
        } footer: {
            Text("Kayıtlar yalnızca bu cihazda tutulur. Limit dolunca + düğmesi kapanır. Ördekler için grup toplamı (6) ve tür sınırları birlikte uygulanır.")
        }
    }

    /// Belgedeki kota MAK limitinden küçükse onu uygula.
    private func capped(_ s: HarvestLog.LimitStatus, by quota: Int?) -> HarvestLog.LimitStatus {
        guard let quota else { return s }
        return .init(used: s.used, max: min(s.max ?? quota, quota), groupUsed: s.groupUsed, groupMax: s.groupMax, groupName: s.groupName)
    }

    private func limitText(_ s: HarvestLog.LimitStatus) -> String {
        var parts: [String] = []
        if let m = s.max { parts.append(L("Limit %@", String(m))) }
        if let gm = s.groupMax, let gu = s.groupUsed { parts.append(L("grup %@/%@", String(gu), String(gm))) }
        if parts.isEmpty { return L("Limitsiz") }
        if s.isFull { return parts.joined(separator: " · ") + " — " + L("limit doldu") }
        if let r = s.remaining { parts.append(L("kalan %@", String(r))) }
        return parts.joined(separator: " · ")
    }
}

struct HarvestHistoryView: View {
    @ObservedObject var log: HarvestLog

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLocale.current
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
                        LabeledContent(LD(item.species), value: "\(item.count)")
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
            Text(verbatim: "\(Compass.name(hour.windFrom)) \(Int(hour.windSpeed.rounded()))")
                .font(.caption.bold().monospacedDigit())
            Image(systemName: showCone ? "nose.fill" : "nose").font(.caption)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .glassCapsule()
    }
}
