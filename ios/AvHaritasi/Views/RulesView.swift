import SwiftUI

/// MAK kararının uygulamayla ilgili özetleri.
struct RulesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            if let regs = model.regs {
                List {
                    Section {
                        Text(regs.decision).font(.footnote)
                    } header: {
                        Text(regs.title)
                    }

                    Section("\(regs.province) için 2026-2027 değişiklikleri") {
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
                        Text("Uygulama; köy/ilçe merkezleri, mesire yerleri, karayolları ve korunan alanlar için bu mesafeleri otomatik kontrol eder. Askeri alan, okul, sağlık tesisi, cezaevi gibi yerler haritada olmadığından 500 m kuralını kendiniz uygulayın.")
                    }

                    Section("Avlaklar (\(regs.province))") {
                        ForEach(regs.avlaklar) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(a.name).font(.subheadline.bold())
                                    Spacer()
                                    Text(a.open ? "Açık" : "AVA KAPALI")
                                        .font(.caption.bold())
                                        .foregroundStyle(a.open ? Color.green : Color.red)
                                }
                                if let e = a.excluded { Text("Avlak dışı: \(e)").font(.caption).foregroundStyle(.secondary) }
                                if let n = a.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }

                    Section("Korunan alanlar (\(regs.province))") {
                        ProtectedRow(title: "Tabiat parkları", items: regs.protectedAreas.tabiatParki)
                        ProtectedRow(title: "Tabiatı koruma alanı", items: regs.protectedAreas.tabiatKorumaAlani)
                        ProtectedRow(title: "Yaban hayatı geliştirme sahaları", items: regs.protectedAreas.yhgs)
                        ProtectedRow(title: "Yaban hayvanı yerleştirme sahaları", items: regs.protectedAreas.yhys)
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
            Text(title).font(.subheadline.bold()).foregroundStyle(color)
            Text(text).font(.callout)
            Text(ref).font(.caption2).foregroundStyle(.secondary)
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
