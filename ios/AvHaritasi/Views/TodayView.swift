import CoreLocation
import SwiftUI

/// Seçilen gün için: av günü mü, av saatleri, açık türler ve limitler.
struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var day = AppClock.now()

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.dateFormat = "d MMMM yyyy, EEEE"
        return f
    }()
    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.dateFormat = "d MMM EEE"
        return f
    }()
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            if let regs = model.regs {
                List {
                    Section {
                        DatePicker("Tarih", selection: $day, displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "tr_TR"))
                        dayStatus(regs)
                        if let c = model.referenceCoordinate, let w = regs.huntingWindow(on: day, at: c) {
                            LabeledContent("Avlanma zamanı", value: "\(Self.time.string(from: w.start)) – \(Self.time.string(from: w.end))")
                            Text(model.location == nil ? "Konum yok; İstanbul merkezine göre hesaplandı." : "Bulunduğunuz konuma göre hesaplandı.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(Self.dayTitle.string(from: day))
                    } footer: {
                        Text(regs.huntingDays.note + " " + regs.huntingDays.holidayNote)
                    }

                    if Regulations.istanbulCalendar.isDate(day, inSameDayAs: model.now) {
                        WeatherSection()
                        HarvestSection(log: model.harvest, regs: regs, day: day)
                    }

                    Section {
                        let groups = regs.huntableToday(on: day)
                        if groups.isEmpty {
                            Text("Bu gün avlanabilecek tür yok.").foregroundStyle(.secondary)
                        }
                        ForEach(groups) { g in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(g.name).font(.headline)
                                ForEach(g.species, id: \.self) { s in
                                    HStack {
                                        Text(s)
                                        Spacer()
                                        Text(regs.limit(for: s).map { "Günlük: \($0)" } ?? "")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .multilineTextAlignment(.trailing)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }
                    } header: {
                        Text("Bu gün açık türler (\(regs.province))")
                    } footer: {
                        Text(regs.provinceBannedNote)
                    }

                    Section("Sonraki av günleri") {
                        ForEach(regs.upcomingHuntingDays(from: AppClock.now(), count: 8)) { item in
                            HStack {
                                Text(Self.shortDay.string(from: item.date))
                                Spacer()
                                Text(item.groups.map(\.name).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }

                    Section {
                        ForEach(regs.groups) { g in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(g.name).font(.subheadline.bold())
                                    Spacer()
                                    Text("\(format(g.start)) – \(format(g.end))").font(.caption.monospacedDigit())
                                }
                                Text(g.species.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                if g.species.allSatisfy({ regs.provinceBannedSpecies.contains($0) }) {
                                    Text("\(regs.province)'da yasak").font(.caption.bold()).foregroundStyle(.red)
                                }
                            }
                        }
                    } header: {
                        Text("Sezon tarihleri (\(regs.region) bölgesi)")
                    }

                    Section {
                        ForEach(regs.dailyLimits) { l in
                            HStack(alignment: .top) {
                                Text(l.species).font(.subheadline)
                                Spacer()
                                Text(l.limit).font(.subheadline.bold()).multilineTextAlignment(.trailing)
                            }
                        }
                    } header: {
                        Text("Günlük avlanma limitleri (avcı başına)")
                    } footer: {
                        Text(regs.limitsNote)
                    }
                }
                .navigationTitle("Av takvimi")
            } else {
                ContentUnavailableView("Kural verisi yok", systemImage: "calendar.badge.exclamationmark")
            }
        }
    }

    @ViewBuilder
    private func dayStatus(_ regs: Regulations) -> some View {
        let groups = regs.huntableToday(on: day)
        let inSeason = regs.groupsInSeason(on: day)
        if inSeason.isEmpty {
            Label("Av sezonu kapalı", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else if groups.isEmpty {
            Label("Av günü değil", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else if let h = regs.holiday(on: day) {
            Label("Av günü — \(h)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Label("Av günü", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func format(_ iso: String) -> String {
        let p = iso.split(separator: "-")
        return p.count == 3 ? "\(p[2]).\(p[1]).\(p[0])" : iso
    }
}
