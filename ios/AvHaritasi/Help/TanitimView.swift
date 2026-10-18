import SwiftUI

/// İlk açılış tanıtımı: kılavuzun `tanitim: true` konularından birkaç kısa sayfa.
/// "Önemli" uyarısı (DisclaimerView) kabul edildikten sonra bir kez gösterilir; atlanabilir,
/// Ayarlar › Yardım'dan yeniden açılabilir.
struct TanitimView: View {
    let konular: [Kilavuz.Konu]
    let onBitir: () -> Void
    @State private var sayfa = TanitimView.ilkSayfa

    /// İlk sayfa (ekran görüntüsü demosunda `-tanitimSayfa`).
    private static var ilkSayfa: Int {
        #if DEBUG
        if let n = ScreenshotArguments.value("-tanitimSayfa").flatMap(Int.init) { return n }
        #endif
        return 0
    }

    private var sonSayfa: Bool { sayfa >= konular.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Atla") { onBitir() }
                    .padding()
            }
            TabView(selection: $sayfa) {
                ForEach(Array(konular.enumerated()), id: \.element.id) { i, konu in
                    TanitimSayfasi(konu: konu).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            VStack(spacing: 8) {
                Button {
                    if sonSayfa { onBitir() } else { withAnimation { sayfa += 1 } }
                } label: {
                    Text(sonSayfa ? L("Başla") : L("İleri")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Bu sayfaları Ayarlar › Yardım'dan yeniden açabilirsiniz.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .interactiveDismissDisabled()
        .onAppear { if konular.isEmpty { onBitir() } }
    }
}

private struct TanitimSayfasi: View {
    let konu: Kilavuz.Konu

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: konu.ikon ?? "info.circle")
                    .font(.system(size: 60))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(LD(konu.baslik)).font(.largeTitle.bold())
                Text(LD(konu.metin)).font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 48)
        }
    }
}
