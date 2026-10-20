import CoreLocation
import PhotosUI
import SwiftUI

/// Ayarlar › Yardım › Geri bildirim gönder: hata, öneri, harita/alan düzeltmesi ya da kuş tanıma bildirimi.
/// Yalnızca "Gönder"e dokununca, yalnızca formda görünenler gönderilir (`FeedbackBuilder`, `FeedbackOutbox`).
struct FeedbackView: View {
    @Environment(AppModel.self) private var model
    @State private var kind: FeedbackKind = .hata
    @State private var text = ""
    @State private var contact = ""
    @State private var addImage = false
    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var imagePreview: UIImage?
    @State private var imageError = false
    @State private var addPoint = false
    @State private var sending = false
    @State private var status: FeedbackOutbox.Status?
    @State private var validation: FeedbackValidationError?
    private let info = FeedbackDeviceInfo.current
    private var outbox: FeedbackOutbox { .shared }

    private struct MapPoint {
        let coordinate: CLLocationCoordinate2D
        let source: String
    }

    /// Eklenecek nokta: haritada uzun basılarak seçilen nokta, yoksa haritanın merkezi.
    private var point: MapPoint? {
        if let c = model.inspectedCoordinate { return MapPoint(coordinate: c, source: L("Haritada seçtiğiniz nokta")) }
        if let c = MapViewport.center { return MapPoint(coordinate: c, source: L("Harita merkezi")) }
        return nil
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Section {
                Picker("Tür", selection: $kind) {
                    ForEach(FeedbackKind.allCases) { k in
                        Label(k.title, systemImage: k.systemImage).tag(k)
                    }
                }
            }

            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 140)
                    .accessibilityLabel("Geri bildirim metni")
            } header: {
                Text("Ne oldu?")
            } footer: {
                Text(L("%@ / %@ karakter", String(text.count), String(Feedback.maxTextLength)))
                    .foregroundStyle(text.count > Feedback.maxTextLength ? Color.red : Color.secondary)
            }

            Section {
                Toggle("Ekran görüntüsü / fotoğraf ekle", isOn: $addImage)
                if addImage {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(imageData == nil ? L("Görsel seç") : L("Başka görsel seç"), systemImage: "photo")
                    }
                    if let imagePreview, let imageData {
                        Image(uiImage: imagePreview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                        Text(L("%@ JPEG; konum ve EXIF bilgisi olmadan", ByteCountFormatter.string(fromByteCount: Int64(imageData.count), countStyle: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if imageError {
                        Text("Görsel okunamadı.").font(.caption).foregroundStyle(.red)
                    }
                }
                if kind.allowsLocation {
                    Toggle("Haritadaki noktayı ekle", isOn: $addPoint)
                    if addPoint {
                        if let p = point {
                            LabeledContent(p.source, value: FeedbackBuilder.coordinateText(p.coordinate))
                        } else {
                            Text("Haritada henüz bir nokta yok; önce Harita sekmesini açın.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                TextField("İletişim e-postası (isteğe bağlı)", text: $contact)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("İsteğe bağlı")
            } footer: {
                if kind.allowsLocation {
                    Text("Nokta: haritada uzun bastığınız yer, yoksa haritanın ortası. 4 ondalığa (~11 m) yuvarlanır; GPS konumunuz gönderilmez.")
                }
            }

            Section {
                LabeledContent("Uygulama", value: info.app)
                LabeledContent("iOS", value: info.os)
                LabeledContent("Cihaz", value: info.model)
            } header: {
                Text("Otomatik eklenir")
            }

            Section {
                Button {
                    send()
                } label: {
                    HStack {
                        Label("Gönder", systemImage: "paperplane")
                        if sending {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(sending || isEmpty)
                if let validation {
                    Text(validation.message).foregroundStyle(.red)
                }
                if let status {
                    Label(status.message, systemImage: icon(status))
                        .foregroundStyle(color(status))
                }
                if outbox.pendingCount > 0 {
                    Text(L("Gönderilmeyi bekleyen: %@", String(outbox.pendingCount)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Yalnızca bu formda gördükleriniz gönderilir: tür, metin, seçtiyseniz görsel (en çok 1024 px, konum ve EXIF bilgisi silinerek yeniden kodlanır), haritadaki nokta ve e-postanız; ayrıca uygulama sürümü, iOS sürümü ve cihaz modeli. Bildirim geliştiricinin Google Cloud'daki sunucusu üzerinden özel bir GitHub deposuna kaydedilir; adınız, GPS konumunuz ve cihaz kimliğiniz eklenmez. İnternet yoksa telefonda bekler (en çok 5) ve bağlantı gelince gönderilir.")
            }
        }
        .navigationTitle("Geri bildirim")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: kind) { _, k in if !k.allowsLocation { addPoint = false } }
        .onChange(of: addImage) { _, on in if !on { clearImage() } }
        .onChange(of: photoItem) { _, item in loadImage(item) }
        .onAppear { outbox.flush() }
    }

    private func send() {
        validation = nil
        status = nil
        let coordinate = kind.allowsLocation && addPoint ? point?.coordinate : nil
        switch FeedbackBuilder.build(kind: kind, text: text, contact: contact, coordinate: coordinate,
                                     image: addImage ? imageData : nil, info: info) {
        case .failure(let e):
            validation = e
        case .success(let payload):
            sending = true
            Task {
                let s = await outbox.submit(payload)
                sending = false
                status = s
                // Gönderildi ya da sıraya alındı: form temizlensin (aynı bildirim iki kez gitmesin)
                if s == .sent || s == .queued || s == .unavailable {
                    text = ""
                    addImage = false
                    addPoint = false
                    clearImage()
                }
            }
        }
    }

    private func clearImage() {
        photoItem = nil
        imageData = nil
        imagePreview = nil
        imageError = false
    }

    private func loadImage(_ item: PhotosPickerItem?) {
        imageData = nil
        imagePreview = nil
        imageError = false
        guard let item else { return }
        Task {
            let raw = try? await item.loadTransferable(type: Data.self)
            let jpeg = await Task.detached(priority: .userInitiated) { raw.flatMap { FeedbackImage.jpeg(from: $0) } }.value
            guard photoItem == item else { return }
            imageData = jpeg
            imagePreview = jpeg.flatMap { UIImage(data: $0) }
            imageError = jpeg == nil
        }
    }

    private func icon(_ s: FeedbackOutbox.Status) -> String {
        switch s {
        case .sent: "checkmark.circle"
        case .queued, .unavailable: "clock"
        case .rejected, .queueFull: "exclamationmark.triangle"
        }
    }

    private func color(_ s: FeedbackOutbox.Status) -> Color {
        switch s {
        case .sent: .green
        case .queued, .unavailable: .orange
        case .rejected, .queueFull: .red
        }
    }
}
