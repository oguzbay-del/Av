import SwiftUI

struct LegendView: View {
    let classes: [ZoneClass]
    let source: String
    let season: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(classes.filter { $0.status != .disarida }) { c in
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: c.color))
                                .frame(width: 28, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.headline)
                                Text(c.status.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(c.status == .yasak ? Color.red : (c.status == .dikkat ? Color.orange : Color.green))
                                Text(c.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("Kaynak: \(source), \(season) sezonu haritası. Haritadaki ilçe/il sınırları, yollar ve yerleşimler yalnızca görseldir; uyarılar renkli alanlara göre verilir.")
                }
                Section("Unutmayın") {
                    Text("Avlanılabilecek türler, günler ve kotalar her sezon Merkez Av Komisyonu (MAK) kararıyla belirlenir. İstanbul genelinde tüm keklik türlerinin avlanması yasaktır (2024-2025 haritası).")
                        .font(.callout)
                }
            }
            .navigationTitle("Lejant")
            .toolbar { Button("Kapat") { dismiss() } }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var overlayOpacity: Double
    @Binding var baseStyleRaw: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text("Yasak alana yaklaşma uyarısı: \(Int(model.bufferMeters)) m")
                        Slider(value: $model.bufferMeters, in: 100...1000, step: 50)
                    }
                } header: {
                    Text("Uyarı mesafesi")
                } footer: {
                    Text("Yasak bir alana bu mesafeden (ve GPS hata payından) daha yakınsanız turuncu uyarı verilir. Basılı haritanın sınır hassasiyeti sınırlı olduğundan 300 m altına düşürmeniz önerilmez.")
                }

                Section {
                    Toggle("Arka planda takip ve bildirim", isOn: $model.backgroundTracking)
                    Toggle("Ekranı açık tut", isOn: $model.keepScreenOn)
                } header: {
                    Text("Takip")
                } footer: {
                    Text("Arka planda takip açıkken telefon cebinizdeyken de yasak alana girdiğinizde veya yaklaştığınızda bildirim ve titreşimle uyarılırsınız. Pil tüketimi artar.")
                }

                Section("Harita görünümü") {
                    Picker("Altlık", selection: $baseStyleRaw) {
                        ForEach(BaseMapStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    VStack(alignment: .leading) {
                        Text("Avlak haritası opaklığı: %\(Int(overlayOpacity * 100))")
                        Slider(value: $overlayOpacity, in: 0...1)
                    }
                }

                Section("Hakkında") {
                    Text("Bu uygulama resmi değildir. Harita T.C. Tarım ve Orman Bakanlığı'nın yayınladığı \(model.map?.meta.season ?? "") avlak haritasından üretilmiştir. Güncel harita ve kararlar için avlakharitalari.tarimorman.gov.tr ve AYBİS'i kontrol edin.")
                        .font(.footnote)
                    Link("Avlak haritaları (resmi site)", destination: URL(string: "https://avlakharitalari.tarimorman.gov.tr")!)
                }
            }
            .navigationTitle("Ayarlar")
            .toolbar { Button("Kapat") { dismiss() } }
        }
    }
}

struct DisclaimerView: View {
    let season: String
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                Text("Önemli").font(.largeTitle.bold())
                Group {
                    Text("• Bu uygulama resmi değildir; yalnızca yardımcı bir araçtır. Yasal sorumluluk avcıya aittir.")
                    Text("• Gösterilen harita \(season) sezonuna aittir. Yeni sezon haritası ve Merkez Av Komisyonu kararı farklı olabilir; avlanmadan önce resmi kaynakları kontrol edin.")
                    Text("• Harita 1:490.000 ölçekli basılı bir haritadan üretilmiştir. Alan sınırları birkaç yüz metre sapabilir. Sınıra yakınsanız turuncu uyarıyı ciddiye alın ve emin değilseniz avlanmayın.")
                    Text("• GPS konumu ormanlık ve engebeli arazide onlarca metre hatalı olabilir.")
                    Text("• Yeşil uyarı yalnızca alanın yasak olmadığını gösterir; avcılık belgesi, avlanma izin kartı, av günleri, türler ve kotalar ayrıca geçerlidir.")
                }
                .font(.body)
                Button(action: onAccept) {
                    Text("Okudum, anladım").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top)
            }
            .padding(24)
        }
        .interactiveDismissDisabled()
    }
}
