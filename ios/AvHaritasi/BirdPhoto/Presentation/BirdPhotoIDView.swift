import PhotosUI
import SwiftUI

/// Fotoğraftan kuş tanıma ekranı: galeriden seç → göster → ilk 3 tahmin (yüzde) + MAK durumu.
/// Video da seçilebilir ya da 10 sn çekilebilir (`BirdVideoService`; yalnızca cihazda, çevrimiçi kontrol yok).
struct BirdPhotoIDView: View {
    @Environment(AppModel.self) private var model
    @State private var service = BirdIdentifierService()
    @State private var pickerItem: PhotosPickerItem?
    @State private var video = BirdVideoService()
    @State private var videoItem: PhotosPickerItem?
    @State private var showRecorder = false
    @State private var online = OnlineBirdCheck()
    @AppStorage(OnlineBirdID.settingKey) private var onlineEnabled = OnlineBirdID.defaultEnabled

    /// Çevrimiçi yedek kontrol yapılandırılmış ve açık mı (kapalıyken ekran eskisi gibidir).
    private var onlineActive: Bool { OnlineBirdID.isConfigured && onlineEnabled }

    var body: some View {
        ScrollViewReader { proxy in
            content.task { await loadScreenshotDemo(proxy) }
        }
    }

    private var content: some View {
        List {
            Section {
                if video.isActive {
                    VideoPreview(video: video)
                    if video.canShiftWindow { VideoWindowPicker(video: video) }
                } else {
                    photo
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(service.image == nil ? L("Galeriden fotoğraf seç") : L("Başka fotoğraf seç"),
                          systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                HStack {
                    PhotosPicker(selection: $videoItem, matching: .videos) {
                        Label("Video seç", systemImage: "film").frame(maxWidth: .infinity)
                    }
                    if VideoRecorder.isAvailable {
                        Button {
                            showRecorder = true
                        } label: {
                            Label("10 sn video çek", systemImage: "video").frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if onlineActive {
                        Text("Fotoğraf önce cihazda analiz edilir. Cihazdaki model emin olmazsa ve internet varsa fotoğraf (konum olmadan) Google Cloud sunucusundaki BioCLIP 2 modeline gönderilir ve saklanmaz. Ayarlar'dan kapatılabilir.")
                    } else {
                        Text("Fotoğraf cihazda analiz edilir; hiçbir yere gönderilmez ve internet gerekmez.")
                    }
                    Text("Video yalnızca cihazda analiz edilir (en iyi 10 sn'lik bölümün görüntüsü ve sesi); hiçbir yere gönderilmez.")
                }
            }

            if video.isActive {
                VideoResultSections(video: video) { model.regs?.legalStatus(scientific: $0, on: model.now) }
            } else {
                results
            }

            OnlineBirdCheckSection(check: online)

            Section {
                Label("Tahmin bir yardımdır, kesin teşhis değildir. Türden emin olmadan atış yapmayın; koruma altındaki türler av türlerine benzeyebilir.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                Text("Tür modeli: İstanbul'daki 331 kuş türü, iNaturalist katılımcılarının serbest lisanslı (CC0 / CC BY / CC BY-NC) fotoğraflarıyla eğitildi; ticari olmayan kullanım.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Kuş bulucu: YOLOX (Megvii, Apache-2.0 lisansı); COCO ve Open Images kuş kutularıyla yalnızca kuş için ince ayarlı.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: pickerItem) {
            guard let item = pickerItem else { return }
            video.reset()
            do {
                let data = try await item.loadTransferable(type: Data.self)
                await service.classify(imageData: data)
            } catch {
                service.fail(.imageLoadFailed)
            }
        }
        .task(id: videoItem) {
            guard let item = videoItem else { return }
            if let url = try? await item.loadTransferable(type: PickedMovie.self)?.url {
                startVideo(url)
            } else {
                service.reset()
                video.fail(L("Video okunamadı ya da biçimi desteklenmiyor."))
            }
        }
        .fullScreenCover(isPresented: $showRecorder) {
            VideoRecorder { url in
                showRecorder = false
                startVideo(url)
            }
            .ignoresSafeArea()
        }
        .onChange(of: service.state) { _, new in checkOnlineIfUnsure(new) }
        .onDisappear {
            online.cancel()
            video.reset()
        }
        .sensoryFeedback(.success, trigger: service.predictions.first?.label)
    }

    private var busy: Bool { service.isBusy || video.isBusy }

    /// Yalnızca DEBUG: App Store ekran görüntüsü için hazır sonuç (`-kusDemo foto|video`).
    /// Videoda sonuçlar ekranın altında kaldığından birleşik sonuç satırı görünene kadar kaydırılır.
    private func loadScreenshotDemo(_ proxy: ScrollViewProxy) async {
        #if DEBUG
        switch ScreenshotArguments.birdDemo {
        case "foto":
            ScreenshotBirdDemo.applyPhoto(to: service)
        case "video":
            ScreenshotBirdDemo.applyVideo(to: video)
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo(VideoResultSections.combinedRowID, anchor: .bottom)
        default:
            break
        }
        #endif
    }

    /// Video seçildi ya da çekildi: fotoğraf sonucu ve çevrimiçi kontrol temizlenir (video gönderilmez).
    private func startVideo(_ url: URL?) {
        videoItem = nil
        guard let url else { return }
        pickerItem = nil
        service.reset()
        online.reset()
        video.load(url: url, regs: model.regs)
    }

    @ViewBuilder
    private var photo: some View {
        if let image = service.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay { focusOverlay } // görüntünün kendi sınırlarında (kenar boşlukları hariç)
                .frame(maxWidth: .infinity, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if service.state == .analyzing {
                        ProgressView("Analiz ediliyor…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .accessibilityLabel(Text("Seçilen fotoğraf"))
                .listRowInsets(EdgeInsets())
        } else if service.state == .loadingImage {
            ProgressView("Fotoğraf yükleniyor…").frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ContentUnavailableView("Kuş fotoğrafı seçin", systemImage: "bird",
                                   description: Text("Kuş kadrajın ortasında ve net olsun. Uzaktaki kuşlarda fotoğrafı yakınlaştırıp kırpın."))
        }
    }

    /// Analiz edilen bölgeyi (kuşun bulunduğu tahmin edilen alan) çerçeveyle göster. Kuş bulucu birden fazla
    /// kuş bulduysa diğerleri ince beyaz çerçeveyle; farklı türlerse listedeki sıra numarasıyla gösterilir.
    @ViewBuilder
    private var focusOverlay: some View {
        if case .finished(let r) = service.state, let f = r.focusRect {
            GeometryReader { geo in
                ForEach(Array(r.birds.dropFirst().enumerated()), id: \.offset) { n, bird in
                    box(bird.box.rect, in: geo.size, color: .white, width: 1, number: r.showsBirdList ? n + 2 : nil)
                }
                box(f, in: geo.size, color: .yellow, width: 2, number: r.showsBirdList ? 1 : nil)
            }
            .allowsHitTesting(false)
        }
    }

    private func box(_ f: CGRect, in size: CGSize, color: Color, width: CGFloat, number: Int?) -> some View {
        Rectangle()
            .stroke(color, lineWidth: width)
            .overlay(alignment: .topLeading) {
                if let number {
                    Text(number, format: .number)
                        .font(.caption2.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3)
                        .background(color)
                }
            }
            .frame(width: f.width * size.width, height: f.height * size.height)
            .position(x: f.midX * size.width, y: (1 - f.midY) * size.height)
    }

    @ViewBuilder
    private var results: some View {
        switch service.state {
        case .finished(let r):
            Section {
                ForEach(r.predictions) { p in
                    PhotoPredictionRow(prediction: p,
                                       status: model.regs?.legalStatus(scientific: p.scientificName, on: model.now))
                }
            } header: {
                Text("Tahminler")
            } footer: {
                if r.usedFallback {
                    Text("Tür modeli yüklü değil: yalnızca genel kuş grubu gösteriliyor (Apple Vision).")
                }
            }
            if r.showsBirdList {
                Section {
                    ForEach(Array(r.birds.enumerated()), id: \.offset) { n, bird in
                        if let p = bird.predictions.first {
                            HStack(alignment: .top, spacing: 8) {
                                Text(n + 1, format: .number)
                                    .font(.caption.bold())
                                    .frame(width: 18, height: 18)
                                    .background(n == 0 ? Color.yellow : Color.secondary.opacity(0.3), in: Circle())
                                    .accessibilityLabel(Text(L("Kuş %@", String(n + 1))))
                                PhotoPredictionRow(prediction: p,
                                                   status: model.regs?.legalStatus(scientific: p.scientificName, on: model.now))
                            }
                        }
                    }
                } header: {
                    Text("Fotoğrafta birden fazla kuş var")
                } footer: {
                    Text("Yukarıdaki tahminler sarı çerçeveli (1) kuş içindir. Her kuşun en olası türü numarasıyla burada; her kuşu ayrı ayrı doğrulayın.")
                }
            }
        case .failed(let e):
            Section {
                Label(e.localizedDescription, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        default:
            EmptyView()
        }
    }
}

struct PhotoPredictionRow: View {
    let prediction: BirdPrediction
    let status: BirdLegalStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    let primary = AppLocale.isEnglish ? prediction.commonName : (status?.turkishName ?? prediction.commonName)
                    Text(primary).font(.headline)
                    if let sci = prediction.scientificName {
                        Text(primary == prediction.commonName ? sci : "\(prediction.commonName) · \(sci)")
                            .font(.caption).italic().foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(prediction.probability, format: .percent.precision(.fractionLength(0)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(prediction.probability >= 0.7 ? Color.primary : Color.secondary)
            }
            ProgressView(value: prediction.probability).tint(prediction.probability >= 0.7 ? .green : .orange)
            // Yasal durum yalnızca tür düzeyinde güvenilir; genel grup sonucunda gösterilmez
            if let s = status, prediction.source == .speciesModel || prediction.scientificName != nil {
                Label(s.text, systemImage: s.level.icon)
                    .font(.caption.bold())
                    .foregroundStyle(s.level.color)
            }
            Text(sourceTitle)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var sourceTitle: String {
        switch prediction.source {
        case .speciesModel: return L("Cihazda tür modeli")
        case .generalModel: return L("Apple Vision (genel)")
        case .onlineModel: return L("Çevrimiçi model")
        case .videoCombined: return L("Görüntü + ses (cihazda)")
        }
    }
}

// MARK: - Çevrimiçi yedek kontrol

private extension BirdPhotoIDView {
    /// Cihazdaki sonuç belirsizse (ya da sonuç yoksa) fotoğrafı çevrimiçi modele sor (`OnlineCheckPolicy`).
    func checkOnlineIfUnsure(_ state: BirdIdentifierService.State) {
        switch state {
        case .finished(let r):
            guard let image = service.image else { return online.reset() }
            let onlyGeneral = r.usedFallback || r.predictions.allSatisfy { $0.source == .generalModel }
            online.evaluate(.photo, topProbability: r.predictions.map(\.probability).max(), onlyGeneral: onlyGeneral,
                            settingEnabled: onlineEnabled, payload: Self.photoPayload(image))
        case .failed(let e):
            // Fotoğraf hiç okunamadıysa gönderilecek bir şey yok
            guard let image = service.image, e != .imageLoadFailed, e != .invalidImage, e != .cancelled else {
                return online.reset()
            }
            online.evaluate(.photo, topProbability: nil, onlyGeneral: false,
                            settingEnabled: onlineEnabled, payload: Self.photoPayload(image))
        case .idle, .loadingImage, .analyzing:
            online.reset()
        }
    }

    /// Ekrandaki (dik, küçültülmüş) fotoğraf → yüklemeye hazır JPEG (≤ 1024 px).
    static func photoPayload(_ image: UIImage) -> @Sendable () async throws -> Data {
        let box = OnlinePhotoBox(image: image.cgImage)
        return {
            guard let cg = box.image, let data = OnlineBirdIDPayload.jpeg(cg) else { throw OnlineBirdIDError.badPayload }
            return data
        }
    }
}

/// CGImage değişmez olduğundan iş parçacıkları arasında güvenle taşınır.
private struct OnlinePhotoBox: @unchecked Sendable { let image: CGImage? }
