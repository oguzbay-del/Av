import SwiftUI

/// Çevrimdışı başvuru tablosu: tür → saçma/şok/mesafe, saçma no ↔ mm, şok no ↔ ad, patern denemesi.
/// Kaynak: Hunting/Data/AvMuhimmat.json (docs/AV_MUHIMMAT.md).
struct AmmoReferenceView: View {
    var body: some View {
        if let k = AmmoKnowledge.shared {
            List {
                Section {
                    Text(LD(k.disclaimer)).font(.callout)
                } header: {
                    Text("Önce okuyun")
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 30–35 m'ye büyük bir kâğıt asın, nişan noktasına ateş edin.")
                        Text("2. En yoğun bölgenin çevresine 75 cm çaplı daire çizin, içindeki delikleri sayın.")
                        Text(L("3. Yüzde = daire içindeki saçma ÷ fişekteki saçma. Kabaca hedef: tam ~%%70, yarım ~%%60, 1/4 ~%%50, silindir ~%%40.", ""))
                        Text("4. Kuşun sığacağı boşluklar varsa saçmayı küçültün ya da şoku değiştirin.")
                    }
                    .font(.callout)
                } header: {
                    Text("Patern denemesi")
                }
                speciesSection(k, birds: true)
                speciesSection(k, birds: false)
                Section {
                    ForEach(Choke.shotChokes) { c in
                        if let info = k.chokeInfo(c) {
                            HStack(alignment: .top, spacing: 12) {
                                ChokeBadge(choke: c, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LD(info.tr)).font(.subheadline.bold())
                                    Text(L("%@–%@ m · 35 m'de ~%%%@", String(info.effectiveRangeM.first ?? 0),
                                           String(info.effectiveRangeM.last ?? 0), String(info.patternPct35m)))
                                        .font(.caption.monospacedDigit())
                                    Text(LD(info.note)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ChokeBadge(choke: .paradox, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LD(k.paradox.tr)).font(.subheadline.bold())
                            Text(LD(k.paradox.use)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Şok numaraları")
                }
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("No").bold()
                            Text("Çap").bold()
                            Text("Kurşun 32 g").bold()
                        }
                        .font(.caption)
                        ForEach(k.shotSizes.filter { $0.id != "11" }) { s in
                            GridRow {
                                Text(verbatim: AmmoFormat.shotNumber(s.id)).bold()
                                Text(L("%@ mm", AmmoFormat.mm(s.mm)))
                                Text(s.pelletsPer32gLead.map { L("~%@ saçma", String($0)) } ?? L("yalnızca çelik"))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Saçma numarası ↔ çap")
                } footer: {
                    Text("Türk numaraları kıta Avrupası düzenini izler; üreticiler arasında ±0,1–0,2 mm fark olur, kutudaki mm değerine bakın.")
                }
                Section {
                    Text(LD(k.steel.sizeRule)).font(.callout)
                    Text(LD(k.steel.chokeRule)).font(.callout)
                    Text(LD(k.steel.proof)).font(.callout)
                } header: {
                    Text("Çelik saçma")
                }
                Section {
                    Text("Değerler yayımlanmış balistik çalışmaların ve av pratiğinin ihtiyatlı özetidir. Güven: yüksek (birden çok kaynak uyuşuyor), orta, düşük (az kaynak; doğrulanmamış). Ayrıntı ve kaynak listesi tür sayfalarında.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Başvuru tablosu")
        } else {
            ContentUnavailableView("Bilgi tablosu yüklenemedi", systemImage: "exclamationmark.triangle")
        }
    }

    private func speciesSection(_ k: AmmoKnowledge, birds: Bool) -> some View {
        Section(birds ? L("Kuşlar") : L("Kara avı")) {
            ForEach(k.species.filter { $0.isBird == birds }) { s in
                NavigationLink { AmmoSpeciesDetail(species: s, knowledge: k) } label: { AmmoSpeciesRow(species: s) }
            }
        }
    }
}

struct AmmoSpeciesRow: View {
    let species: AmmoKnowledge.Species

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(LD(species.name)).font(.subheadline.bold())
                Spacer()
                ConfidenceTag(confidence: species.confidence)
            }
            Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts: [String] = []
        if let lead = species.leadShot {
            parts.append(L("Saçma %@", AmmoFormat.shotNumber(lead.primary)))
        } else if species.slug != nil {
            parts.append(L("Tek kurşun / yivli"))
        }
        if let c = species.choke { parts.append(L("şok %@/%@", String(c.first), String(c.second))) }
        parts.append(L("%@–%@ m", String(species.distanceM.first ?? 0), String(species.distanceM.last ?? 0)))
        return parts.joined(separator: " · ")
    }
}

struct ConfidenceTag: View {
    let confidence: String

    var body: some View {
        switch confidence {
        case "low": MaterialTag(text: L("Güven: düşük"), color: .orange)
        case "medium": MaterialTag(text: L("Güven: orta"), color: .secondary)
        default: MaterialTag(text: L("Güven: yüksek"), color: .green)
        }
    }
}

struct AmmoSpeciesDetail: View {
    let species: AmmoKnowledge.Species
    let knowledge: AmmoKnowledge

    var body: some View {
        List {
            Section {
                LabeledContent("Mesafe", value: L("%@–%@ m", String(species.distanceM.first ?? 0), String(species.distanceM.last ?? 0)))
                LabeledContent("Etik üst sınır", value: L("%@ m", String(species.maxEthicalRangeM)))
                if let lead = species.leadShot {
                    LabeledContent("Kurşun saçma", value: shotText(lead))
                }
                if let steel = species.steelShot {
                    LabeledContent("Çelik saçma", value: shotText(steel))
                }
                if let g = species.loadGrams12, g.count == 2 {
                    LabeledContent("Gramaj (12 ga)", value: L("%@–%@ g", String(g[0]), String(g[1])))
                }
                if let c = species.choke {
                    LabeledContent("Şok 1./2. atış", value: "\(c.first) / \(c.second)")
                    LabeledContent("Çelikte şok", value: "\(c.steelFirst) / \(c.steelSecond)")
                }
                LabeledContent("Kalibre", value: species.gauges.joined(separator: ", "))
                if species.magnumNeeded { Text("76 mm (magnum) fişek önerilir.").font(.callout) }
                if let s = species.slug {
                    LabeledContent("Tek kurşun", value: s.chokes.map(\.badge).joined(separator: ", "))
                    Text(LD(s.note)).font(.caption).foregroundStyle(.secondary)
                }
                if let r = species.rifle {
                    LabeledContent("Yivli", value: r.calibers.joined(separator: ", "))
                    Text(LD(r.note)).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack { Text(verbatim: species.latin).italic(); Spacer(); ConfidenceTag(confidence: species.confidence) }
            }
            Section("Nişan ve etik") {
                Text(LD(species.aim)).font(.callout)
                if !species.notes.isEmpty { Text(LD(species.notes)).font(.callout).foregroundStyle(.secondary) }
            }
            Section("Kaynaklar") {
                ForEach(species.sources, id: \.self) { id in
                    if let s = knowledge.sources[id], let url = URL(string: s), s.hasPrefix("http") {
                        Link(destination: url) {
                            Text(verbatim: url.host ?? s).font(.caption)
                        }
                    } else {
                        Text(verbatim: knowledge.sources[id] ?? id).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(LD(species.name))
    }

    private func shotText(_ c: AmmoKnowledge.ShotChoice) -> String {
        let main = AmmoFormat.shotNumber(c.primary) + (knowledge.shot(c.primary).map { " (" + L("%@ mm", AmmoFormat.mm($0.mm)) + ")" } ?? "")
        guard !c.alternatives.isEmpty else { return main }
        return main + " · " + c.alternatives.map(AmmoFormat.shotNumber).joined(separator: ", ")
    }
}
