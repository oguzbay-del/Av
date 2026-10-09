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
                                Text(LD(c.name)).font(.headline)
                                Text(c.status.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(c.status == .yasak ? Color.red : (c.status == .dikkat ? Color.orange : Color.green))
                                Text(LD(c.description)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(L("Avlak haritası (%@)", season))
                } footer: {
                    Text(L("Kaynak: %@. Bölgeler resmi haritadan vektöre çevrilmiştir; renkler okunaklılık için uyarlanmıştır. Resmi haritanın kendisini Katmanlar'dan açabilirsiniz.", LD(source)))
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
    @Environment(AppModel.self) private var model
    @Binding var overlayOpacity: Double
    @Binding var baseLayerRaw: String
    @Binding var showBuffers: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64 = CachingTileOverlay.cacheSize()
    @AppStorage("rotateWithHeading") private var rotateWithHeading = false
    @AppStorage("birdSounds") private var birdSounds = true
    @AppStorage(FieldLog.enabledKey) private var fieldLogEnabled = FieldLog.defaultEnabled
    @State private var confirmClearFieldLog = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text(L("Yaklaşma uyarısı: %@ m", String(Int(model.bufferMeters))))
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
                    Toggle("Açılış ve kapanışta kuş sesi", isOn: $birdSounds)
                } header: {
                    Text("Takip")
                } footer: {
                    Text("Kapalıyken uyarı: iOS bölge izlemesiyle, uygulama kapalı ya da telefon cebinizdeyken yasak alana yaklaşık 100-200 m kala bildirim gelir; pil tüketimi çok azdır (\"Her Zaman\" konum izni gerekir). Bu bir yedektir: iOS bölge sınırını birkaç dakika ve birkaç yüz metre geç algılayabilir. Sürekli takip: GPS açık kalır, köy/yol mesafeleri dahil tüm kurallar anlık denetlenir; pil tüketimi artar. Pusuda 3 dk kıpırdamazsanız ve yasak alanlardan uzaktaysanız GPS hassasiyeti otomatik düşürülür.")
                }

                Section {
                    Toggle("Durumu kilit ekranında göster", isOn: $model.liveActivityEnabled)
                } header: {
                    Text("Kilit ekranı ve Apple Watch")
                } footer: {
                    Text("Açıkken av durumu (yasak/dikkat/avlanabilir) ve rüzgâr kilit ekranında, Dynamic Island'da ve eşleşmiş Apple Watch'un Akıllı Yığın'ında canlı gösterilir.")
                }

                Section {
                    Picker("Altlık", selection: $baseLayerRaw) {
                        ForEach(BaseLayer.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    VStack(alignment: .leading) {
                        Text(L("Resmi (taranmış) harita opaklığı: %%%@", String(Int(overlayOpacity * 100))))
                        Slider(value: $overlayOpacity, in: 0...1)
                    }
                    Toggle("300 m yasak bantlarını göster", isOn: $showBuffers)
                    Toggle("Harita baktığım yöne dönsün", isOn: $rotateWithHeading)
                } header: {
                    Text("Harita")
                } footer: {
                    Text(L("Gördüğünüz OpenTopoMap ve OpenStreetMap karoları bir süre cihazda saklanır; OSM kullanım kuralı gereği toplu indirme yapılmaz. İnternet yokken çevrimiçi altlık yerine çevrimdışı topo harita gösterilir. Avlak bölgeleri ve kurallar uygulamayla gelir, internetsiz de çalışır. Önbellek: %@.", ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)))
                }
                Section {
                    OfflineMapPanel()
                } header: {
                    Text("Çevrimdışı harita")
                }
                Section {
                    Button("Harita önbelleğini temizle", role: .destructive) {
                        CachingTileOverlay.clearCache()
                        cacheSize = CachingTileOverlay.cacheSize()
                    }
                }

                Section {
                    ForEach(SoundCredit.all) { c in
                        Button { c.sound?.play(force: true) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("%@ — %@", LD(c.use), LD(c.species))).foregroundStyle(.primary)
                                Text(verbatim: "\(c.scientific) · \(c.recordist), \(c.xc) · \(c.license)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Kuş sesleri")
                } footer: {
                    Text("Uyarı ve bildirim sesleri gerçek kuş kayıtlarıdır: dikkat için bıldırcın, yasak alan için saksağan alarmı. Kayıtlar xeno-canto.org'dan, kayıt sahiplerinin CC BY-NC-SA 4.0 lisansıyla; kırpılıp ses düzeyi ayarlandı. Dinlemek için dokunun.")
                }

                Section {
                    let reports = Diagnostics.shared.reports
                    if reports.isEmpty {
                        Text("Henüz tanı raporu yok.").foregroundStyle(.secondary)
                    } else {
                        ShareLink(items: reports) {
                            Label(L("Tanı raporlarını paylaş (%@)", String(reports.count)), systemImage: "stethoscope")
                        }
                    }
                    Toggle("Saha kaydı", isOn: $fieldLogEnabled)
                    ShareLink(items: FieldLogExport.allCases, preview: { SharePreview($0.fileName) }) {
                        Label("Saha kaydını paylaş", systemImage: "list.bullet.rectangle")
                    }
                    Button("Kaydı sil", role: .destructive) { confirmClearFieldLog = true }
                        .confirmationDialog(Text("Saha kaydı silinsin mi?"), isPresented: $confirmClearFieldLog, titleVisibility: .visible) {
                            Button("Kaydı sil", role: .destructive) { FieldLog.shared.clear() }
                        }
                } header: {
                    Text("Tanı raporları")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("iOS'un topladığı çökme, takılma ve pil raporları yalnızca bu cihazda saklanır; konum içermez. Bir sorun bildirmek isterseniz paylaşabilirsiniz.")
                        Text("Saha kaydı, uygulamanın sahada ne yaptığını (konum ölçümleri, seviye değişimleri, uyarılar, GPS kesintileri, pil kademesi, güvenli daire) olay olay yazar. Yalnızca bu telefonda, şifreli saklanır ve konumunuzu içerir; 7 günden eski olaylar kendiliğinden silinir. Yalnızca siz paylaşa dokunursanız seçtiğiniz kişiye ya da uygulamaya gider.")
                    }
                }

                Section {
                    Text(L("Bu uygulama resmi değildir. Harita T.C. Tarım ve Orman Bakanlığı'nın %@ avlak haritasından, kurallar %@ üretilmiştir. Güncel harita ve kararlar için avlakharitalari.tarimorman.gov.tr ve AVBİS'i kontrol edin.", model.map?.meta.season ?? "", model.regs.map { LD($0.title) } ?? L("MAK kararından")))
                        .font(.footnote)
                    Link("Avlak haritaları (resmi site)", destination: URL(string: "https://avlakharitalari.tarimorman.gov.tr")!)
                    Link("Gizlilik politikası", destination: PrivacyPolicy.url)
                    Toggle("Demo modu (İnceleme)", isOn: Binding(get: { model.demoActive },
                                                                set: { $0 ? model.startDemo() : model.stopDemo() }))
                } header: {
                    Text("Hakkında")
                } footer: {
                    Text("Demo modu gerçek GPS yerine Sarıkavak'ta (İstanbul) ava yasak alana giden bir yürüyüş oynatır; uyarıları Türkiye dışında denemek içindir.")
                }
            }
            .navigationTitle("Ayarlar")
            .toolbar { Button("Kapat") { dismiss() } }
        }
        .cellularDownloadConfirmation()
    }
}

struct DisclaimerView: View {
    let mapSeason: String
    let rulesTitle: String
    /// Konum izni henüz sorulmadıysa ikinci adımda açıklayıp istenir.
    var needsLocation = false
    var onEnableLocation: () -> Void = {}
    let onAccept: () -> Void
    @State private var step = 0

    var body: some View {
        Group {
            if step == 0 { disclaimer } else { locationPrimer }
        }
        .interactiveDismissDisabled()
    }

    private var disclaimer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                Text("Önemli").font(.largeTitle.bold())
                Group {
                    Text("• Bu uygulama resmi değildir; yalnızca yardımcı bir araçtır. Yasal sorumluluk avcıya aittir.")
                    Text(L("• Alan haritası resmi %@ İstanbul Avlaklar Haritası'dır (taranmış görüntü, koordinatları 2024-25 haritasına hizalanarak bulundu). Kurallar %@'ndan alınmıştır.", mapSeason, LD(rulesTitle)))
                    Text("• Harita 1:490.000 ölçekli basılı bir haritadan üretilmiştir. Sınırlar birkaç yüz metre sapabilir. Sınıra yakınsanız ve emin değilseniz avlanmayın.")
                    Text("• Köy, mesire yeri ve karayolu mesafeleri haritadaki noktalardan hesaplanır; köyün en dış evi, gerçek yol sınıfı ve haritada olmayan tesisler (askeri alan, okul, cezaevi vb. — 500 m) için kendi gözleminizi esas alın.")
                    Text("• GPS konumu ormanlık ve engebeli arazide onlarca metre hatalı olabilir.")
                    Text("• Yeşil durum; avcılık belgesi, avlanma izin kartı, AVBİS izni ve tür limitleri gibi diğer yükümlülükleri kaldırmaz.")
                }
                .font(.body)
                Link("Gizlilik politikası", destination: PrivacyPolicy.url).font(.footnote)
            }
            .padding(24)
        }
        // Düğme uzun metnin sonunda kaybolmasın: altta sabit
        .safeAreaInset(edge: .bottom) {
            Button { if needsLocation { withAnimation { step = 1 } } else { onAccept() } } label: {
                Text("Okudum, anladım").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.bar)
        }
    }

    /// İzin istemeden önce neden gerektiğini anlat (Apple HIG: bağlam içinde izin iste).
    private var locationPrimer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "location.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
            Text("Konum izni").font(.largeTitle.bold())
            Label("Yasak alana, köye ya da karayoluna yaklaştığınızda uyarmak için", systemImage: "exclamationmark.triangle.fill")
            Label("Avlanma saatini bulunduğunuz yere göre hesaplamak için", systemImage: "sunrise.fill")
            Label("Konum yalnızca cihazda işlenir; iz kaydını siz başlatmazsanız konum geçmişi tutulmaz. Hava tahmini için yalnızca yaklaşık konum (~1 km) paylaşılır.", systemImage: "lock.fill")
            Text("Uygulama kapalıyken de uyarı isterseniz bunu sonra Ayarlar'dan açabilirsiniz.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button {
                onEnableLocation()
                onAccept()
            } label: {
                Text("Konumu etkinleştir").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Şimdi değil") { onAccept() }
                .frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}
