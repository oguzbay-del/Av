import SwiftUI

/// Ayarlar › Yardım: kullanım kılavuzu. Bölümlere ayrılmış, aranabilir liste; internetsiz çalışır.
/// İçerik `Kilavuz.json`'dan gelir (bkz. `Kilavuz`).
struct KilavuzView: View {
    var kilavuz: Kilavuz = .paket
    @State private var arama = ""
    @State private var tanitimAcik = false

    var body: some View {
        let gruplar = kilavuz.gruplar(arama: arama, metin: LD)
        List {
            ForEach(gruplar) { g in
                Section {
                    ForEach(g.konular) { KilavuzKonuSatiri(konu: $0) }
                } header: {
                    Label(LD(g.bolum.baslik), systemImage: g.bolum.ikon ?? "book")
                }
            }
            if arama.isEmpty, !kilavuz.tanitimKonulari.isEmpty {
                Section {
                    Button {
                        tanitimAcik = true
                    } label: {
                        Label("Tanıtımı yeniden göster", systemImage: "play.rectangle")
                    }
                }
            }
        }
        .overlay {
            if gruplar.isEmpty, !arama.isEmpty {
                ContentUnavailableView.search(text: arama)
            }
        }
        .searchable(text: $arama, prompt: "Kılavuzda ara")
        .navigationTitle("Kullanım kılavuzu")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $tanitimAcik) {
            TanitimView(konular: kilavuz.tanitimKonulari) { tanitimAcik = false }
        }
    }
}

private struct KilavuzKonuSatiri: View {
    let konu: Kilavuz.Konu

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(LD(konu.baslik)).font(.headline)
            } icon: {
                Image(systemName: konu.ikon ?? "info.circle").foregroundStyle(.tint)
            }
            Text(LD(konu.metin))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
