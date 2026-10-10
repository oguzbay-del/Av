import PhotosUI
import SwiftUI

/// Fotoğraftan kuş tanıma ekranı: galeriden seç → göster → ilk 3 tahmin (yüzde) + MAK durumu.
struct BirdPhotoIDView: View {
    @Environment(AppModel.self) private var model
    @State private var service = BirdIdentifierService()
    @State private var pickerItem: PhotosPickerItem?
    @State private var online = OnlineBirdCheck()
    @AppStorage(OnlineBirdID.settingKey) private var onlineEnabled = OnlineBirdID.defaultEnabled

    /// Çevrimiçi yedek kontrol yapılandırılmış ve açık mı (kapalıyken ekran eskisi gibidir).
    private var onlineActive: Bool { OnlineBirdID.isConfigured && onlineEnabled }

    var body: some View {
        List {
            Section {
                photo
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(service.image == nil ? L("Galeriden fotoğraf seç") : L("Başka fotoğraf seç"),
                          systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isBusy)
            } footer: {
                if onlineActive {
                    Text("Fotoğraf önce cihazda analiz edilir. Cihazdaki model emin olmazsa ve internet varsa fotoğraf (konum olmadan) Hugging Face sunucusundaki BioCLIP 2 modeline gönderilir ve saklanmaz. Ayarlar'dan kapatılabilir.")
                } else {
                    Text("Fotoğraf cihazda analiz edilir; hiçbir yere gönderilmez ve internet gerekmez.")
                }
            }

            results

            OnlineBirdCheckSection(check: online)

            Section {
                Label("Tahmin bir yardımdır, kesin teşhis değildir. Türden emin olmadan atış yapmayın; koruma altındaki türler av türlerine benzeyebilir.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
        }
        .task(id: pickerItem) {
            guard let item = pickerItem else { return }
            do {
                let data = try await item.loadTransferable(type: Data.self)
                await service.classify(imageData: data)
            } catch {
                service.fail(.imageLoadFailed)
            }
        }
        .onChange(of: service.state) { _, new in checkOnlineIfUnsure(new) }
        .onDisappear { online.cancel() }
        .sensoryFeedback(.success, trigger: service.predictions.first?.label)
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

    /// Analiz edilen bölgeyi (kuşun bulunduğu tahmin edilen alan) çerçeveyle göster.
    @ViewBuilder
    private var focusOverlay: some View {
        if case .finished(let r) = service.state, let f = r.focusRect {
            GeometryReader { geo in
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: f.width * geo.size.width, height: f.height * geo.size.height)
                    .position(x: f.midX * geo.size.width, y: (1 - f.midY) * geo.size.height)
            }
            .allowsHitTesting(false)
        }
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
