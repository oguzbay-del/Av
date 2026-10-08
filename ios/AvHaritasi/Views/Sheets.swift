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
                                .fill(Color(uiColor: c.displayColor).opacity(max(c.fillAlpha, 0.12) + 0.15))
                                .frame(width: 28, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(uiColor: c.displayColor), style: StrokeStyle(lineWidth: 2, dash: c.status == .dikkat ? [4, 2] : [])))
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
                } header: {
                    Text("Avlak haritası (\(season))")
                } footer: {
                    Text("Kaynak: \(source). Bölgeler resmi haritadan vektöre çevrilmiştir; renkler okunaklılık için uyarlanmıştır. Resmi haritanın kendisini Katmanlar'dan açabilirsiniz.")
                }
                Section("Uygulamanın eklediği katmanlar") {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Kesikli kırmızı alan").font(.headline)
                            Text("Haritada çok küçük kalan Adalar gibi, karara göre ek olarak işaretlenen yasak alanlar.").font(.caption)
                        }
                    } icon: { Image(systemName: "square.dashed").foregroundStyle(.red) }
                    Label {
                        VStack(alignment: .leading) {
                            Text("Kesikli turuncu alan").font(.headline)
                            Text("Kararda geçen ama yeri tam belirlenemeyen alan; avlanmadan önce DKMP'ye danışın.").font(.caption)
                        }
                    } icon: { Image(systemName: "square.dashed").foregroundStyle(.orange) }
                    Label {
                        VStack(alignment: .leading) {
                            Text("Kırmızı bantlar (isteğe bağlı)").font(.headline)
                            Text("Karayolları ve köy/ilçe merkezleri ile mesire yerleri çevresindeki 300 m yasak bantları.").font(.caption)
                        }
                    } icon: { Image(systemName: "circle.dashed.inset.filled").foregroundStyle(.red) }
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
    @Binding var baseLayerRaw: String
    @Binding var showBuffers: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64 = CachingTileOverlay.cacheSize()
    @AppStorage("birdnetURL") private var birdnetURL = ""
    @AppStorage("birdnetKey") private var birdnetKey = ""
    @AppStorage("rotateWithHeading") private var rotateWithHeading = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text("Yaklaşma uyarısı: \(Int(model.bufferMeters)) m")
                        Slider(value: $model.bufferMeters, in: 100...1000, step: 50)
                    }
                    Toggle("Zaman kurallarını da değerlendir", isOn: $model.includeTimeRules)
                } header: {
                    Text("Uyarılar")
                } footer: {
                    Text("Yasal 300/500 m kuralları her zaman uygulanır. Buradaki mesafe, ava yasak alanlara ve yaklaşık çizilen sınırlara ek temkin payıdır. Zaman kuralları açıkken av günü, av saati ve sezon da ana durumu etkiler.")
                }

                Section {
                    Toggle("Uygulama kapalıyken de uyar", isOn: $model.geofenceAlerts)
                    Toggle("Arka planda sürekli takip", isOn: $model.backgroundTracking)
                    Toggle("Ekranı açık tut", isOn: $model.keepScreenOn)
                } header: {
                    Text("Takip")
                } footer: {
                    Text("Kapalıyken uyarı: iOS bölge izlemesiyle, uygulama kapalı ya da telefon cebinizdeyken yasak alana yaklaşık 100 m kala bildirim gelir; pil tüketimi çok azdır (\"Her Zaman\" konum izni gerekir, iOS bölge sınırını ±100 m kadar geç algılayabilir). Sürekli takip: GPS açık kalır, köy/yol mesafeleri dahil tüm kurallar anlık denetlenir; pil tüketimi artar. Pusuda 3 dk kıpırdamazsanız ve yasak alanlardan uzaktaysanız GPS hassasiyeti otomatik düşürülür.")
                }

                Section {
                    Toggle("Durumu kilit ekranında göster", isOn: $model.liveActivityEnabled)
                } header: {
                    Text("Kilit ekranı ve Apple Watch")
                } footer: {
                    Text("Açıkken av durumu (yasak/dikkat/avlanabilir) ve rüzgâr kilit ekranında, Dynamic Island'da ve eşleşmiş Apple Watch'un Akıllı Yığın'ında canlı gösterilir.")
                }

                Section {
                    TextField("https://…", text: $birdnetURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API anahtarı (isteğe bağlı)", text: $birdnetKey)
                } header: {
                    Text("Kuş sesi tanıma (BirdNET sunucusu)")
                } footer: {
                    Text("server/birdnet-api klasöründeki sunucunun adresi (ör. Hugging Face Space ya da ev bilgisayarınız). Boş bırakılırsa cihazdaki genel ses sınıflandırıcısı kullanılır; o tür değil yalnızca grup (ördek, kaz, baykuş…) söyler.")
                }

                Section {
                    Picker("Altlık", selection: $baseLayerRaw) {
                        ForEach(BaseLayer.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    VStack(alignment: .leading) {
                        Text("Resmi (taranmış) harita opaklığı: %\(Int(overlayOpacity * 100))")
                        Slider(value: $overlayOpacity, in: 0...1)
                    }
                    Toggle("300 m yasak bantlarını göster", isOn: $showBuffers)
                    Toggle("Harita baktığım yöne dönsün", isOn: $rotateWithHeading)
                } header: {
                    Text("Harita")
                } footer: {
                    Text("OpenTopoMap ve OpenStreetMap karoları gezdikçe cihaza kaydedilir; avlanacağınız bölgeyi internet varken bir kez gezerseniz ormanda internetsiz de görünür. Önbellek: \(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)).")
                }
                Section {
                    Button("Harita önbelleğini temizle", role: .destructive) {
                        CachingTileOverlay.clearCache()
                        cacheSize = CachingTileOverlay.cacheSize()
                    }
                }

                Section("Hakkında") {
                    Text("Bu uygulama resmi değildir. Harita T.C. Tarım ve Orman Bakanlığı'nın \(model.map?.meta.season ?? "") avlak haritasından, kurallar \(model.regs?.title ?? "MAK kararından") üretilmiştir. Güncel harita ve kararlar için avlakharitalari.tarimorman.gov.tr ve AVBİS'i kontrol edin.")
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
    let mapSeason: String
    let rulesTitle: String
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
                    Text("• Alan haritası resmi \(mapSeason) İstanbul Avlaklar Haritası'dır (taranmış görüntü, koordinatları 2024-25 haritasına hizalanarak bulundu). Kurallar \(rulesTitle)'ndan alınmıştır.")
                    Text("• Harita 1:490.000 ölçekli basılı bir haritadan üretilmiştir. Sınırlar birkaç yüz metre sapabilir. Sınıra yakınsanız ve emin değilseniz avlanmayın.")
                    Text("• Köy, mesire yeri ve karayolu mesafeleri haritadaki noktalardan hesaplanır; köyün en dış evi, gerçek yol sınıfı ve haritada olmayan tesisler (askeri alan, okul, cezaevi vb. — 500 m) için kendi gözleminizi esas alın.")
                    Text("• GPS konumu ormanlık ve engebeli arazide onlarca metre hatalı olabilir.")
                    Text("• Yeşil durum; avcılık belgesi, avlanma izin kartı, AVBİS izni ve tür limitleri gibi diğer yükümlülükleri kaldırmaz.")
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
