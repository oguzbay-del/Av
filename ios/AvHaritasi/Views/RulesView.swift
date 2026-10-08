import SwiftUI

/// MAK kararının uygulamayla ilgili özetleri.
struct RulesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            if let regs = model.regs {
                List {
                    Section {
                        Text(LD(regs.decision)).font(.footnote)
                        if AppLocale.isEnglish {
                            Text("Bu bir çeviridir; hukuken geçerli olan Merkez Av Komisyonu kararının Türkçe metnidir.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } header: {
                        Text(LD(regs.title))
                    }

                    Section(L("%@ için 2026-2027 değişiklikleri", LD(regs.province))) {
                        ForEach(regs.provinceChanges) { c in
                            RuleRow(title: c.title, text: c.text, ref: c.ref,
                                    color: c.status == "yasak" ? .red : .orange)
                        }
                    }

                    Section {
                        ForEach(regs.distanceRules) { r in
                            RuleRow(title: "\(Int(r.meters)) m", text: r.text, ref: r.ref, color: .red)
                        }
                    } header: {
                        Text("Mesafe yasakları")
                    } footer: {
                        Text(model.osm != nil
                             ? L("Uygulama; köy/ilçe merkezleri, mesire yerleri, karayolları ve korunan alanlar için avlak haritasından, yerleşim alanları, okul, sağlık tesisi, askeri alan, cezaevi, spor tesisi, kamp ve göletler için OpenStreetMap'ten (%@) bu mesafeleri otomatik kontrol eder. OSM eksik olabilir; arazide gördüğünüz tesisler için kuralı kendiniz uygulayın.", model.osm?.fetched ?? "")
                             : L("Uygulama; köy/ilçe merkezleri, mesire yerleri, karayolları ve korunan alanlar için bu mesafeleri otomatik kontrol eder. Askeri alan, okul, sağlık tesisi, cezaevi gibi yerler için veri yüklü değil; 500 m kuralını kendiniz uygulayın."))
                    }

                    Section(L("Avlaklar (%@)", LD(regs.province))) {
                        ForEach(regs.avlaklar) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(LD(a.name)).font(.subheadline.bold())
                                    Spacer()
                                    Text(a.open ? L("Açık") : L("AVA KAPALI"))
                                        .font(.caption.bold())
                                        .foregroundStyle(a.open ? Color.green : Color.red)
                                }
                                if let e = a.excluded { Text(L("Avlak dışı: %@", LD(e))).font(.caption).foregroundStyle(.secondary) }
                                if let n = a.note { Text(LD(n)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }

                    Section(L("Korunan alanlar (%@)", LD(regs.province))) {
                        ProtectedRow(title: L("Tabiat parkları"), items: regs.protectedAreas.tabiatParki)
                        ProtectedRow(title: L("Tabiatı koruma alanı"), items: regs.protectedAreas.tabiatKorumaAlani)
                        ProtectedRow(title: L("Yaban hayatı geliştirme sahaları"), items: regs.protectedAreas.yhgs)
                        ProtectedRow(title: L("Yaban hayvanı yerleştirme sahaları"), items: regs.protectedAreas.yhys)
                    }

                    Section("Önemli yasaklar") {
                        ForEach(regs.keyRules) { r in
                            RuleRow(title: r.title, text: r.text, ref: r.ref, color: .primary)
                        }
                    }
                }
                .navigationTitle("Kurallar")
            } else {
                ContentUnavailableView("Kural verisi yok", systemImage: "book.closed")
            }
        }
    }
}

private struct RuleRow: View {
    let title: String
    let text: String
    let ref: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LD(title)).font(.subheadline.bold()).foregroundStyle(color)
            Text(LD(text)).font(.callout)
            Text(LD(ref)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ProtectedRow: View {
    let title: String
    let items: [String]

    var body: some View {
        DisclosureGroup("\(title) (\(items.count))") {
            Text(items.joined(separator: " · ")).font(.caption)
        }
    }
}
