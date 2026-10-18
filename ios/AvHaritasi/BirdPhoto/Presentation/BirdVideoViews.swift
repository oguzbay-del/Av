import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Videonun önizlemesi (bölümün en iyi karesi) ve durum yazısı.
struct VideoPreview: View {
    let video: BirdVideoService

    var body: some View {
        Group {
            if let image = video.preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay { focus }
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text("Videonun seçilen karesi"))
            } else {
                Color.secondary.opacity(0.1).frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .overlay {
            if let status {
                ProgressView(status)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .listRowInsets(EdgeInsets())
    }

    private var status: String? {
        switch video.phase {
        case .loading: return L("Video yükleniyor…")
        case .scanning(let p): return L("Video taranıyor… %@", p.formatted(.percent.precision(.fractionLength(0))))
        case .selecting: return L("En iyi bölüm seçiliyor…")
        case .analyzingFrames: return L("Kareler analiz ediliyor…")
        case .analyzingSound: return L("Ses analiz ediliyor…")
        case .idle, .finished, .failed: return nil
        }
    }

    @ViewBuilder
    private var focus: some View {
        if let f = video.focusRect, !video.isBusy {
            GeometryReader { geo in
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: f.width * geo.size.width, height: f.height * geo.size.height)
                    .position(x: f.midX * geo.size.width, y: (1 - f.midY) * geo.size.height)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Uzun videoda 10 sn'lik bölümü kaydırma: tarama puanları çubuk olarak, seçili bölüm vurgulu.
struct VideoWindowPicker: View {
    let video: BirdVideoService
    @State private var start: Double = 0

    var body: some View {
        let scores = video.timeline, pos = start
        let total = VideoWindowSelector.scanDuration(video.duration)
        VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in
                guard !scores.isEmpty, total > 0 else { return }
                let w = size.width / CGFloat(scores.count)
                for (n, s) in scores.enumerated() {
                    let h = max(2, CGFloat(s) * size.height)
                    ctx.fill(Path(CGRect(x: CGFloat(n) * w, y: size.height - h, width: max(1, w - 1), height: h)),
                             with: .color(Color.secondary.opacity(0.5)))
                }
                let x = CGFloat(pos / total) * size.width
                let ww = CGFloat(VideoWindowSelector.window / total) * size.width
                ctx.fill(Path(CGRect(x: x, y: 0, width: ww, height: size.height)), with: .color(Color.accentColor.opacity(0.3)))
            }
            .frame(height: 32)
            .accessibilityHidden(true)
            Slider(value: $start, in: 0...max(1, video.maxStart), step: 1, onEditingChanged: { editing in
                if !editing { video.shiftWindow(to: self.start) }
            })
            .disabled(video.isBusy)
            .accessibilityLabel(Text("Analiz edilen bölüm"))
            Text(L("Bölüm: %@ – %@", Self.clock(start), Self.clock(start + VideoWindowSelector.window)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .onChange(of: video.windowStart, initial: true) { _, s in start = s }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Video sonuçları: görüntü ve ses aynı türdeyse birleşik satır; ayrıca her biri ayrı ve etiketli.
struct VideoResultSections: View {
    let video: BirdVideoService
    let status: (String?) -> BirdLegalStatus?

    /// Birleşik sonuç satırı (ekran görüntüsü demosunda oraya kaydırılır).
    static let combinedRowID = "videoBirlesikSonuc"

    var body: some View {
        if let f = video.fusion {
            if let c = f.combined {
                Section {
                    PhotoPredictionRow(prediction: c, status: status(c.scientificName))
                        .id(Self.combinedRowID)
                } header: {
                    Text("Görüntü + ses")
                } footer: {
                    Text("Görüntü ve ses aynı türü gösteriyor; güven birleştirildi.")
                }
            } else if f.agreement == .disagree {
                Section {
                    Label("Görüntü ve ses farklı türleri gösteriyor; ikisini ayrı değerlendirin.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section("Görüntü") {
                if f.image.isEmpty {
                    Text("Görüntüde tür bulunamadı.").foregroundStyle(.secondary)
                }
                ForEach(f.image) { p in PhotoPredictionRow(prediction: p, status: status(p.scientificName)) }
            }
            Section("Ses") {
                if f.sound.isEmpty {
                    Text("Seste tür bulunamadı.").foregroundStyle(.secondary)
                }
                ForEach(f.sound) { d in DetectionRow(detection: d, status: status(d.scientificName)) }
            }
        }
        if case .failed(let message) = video.phase {
            Section {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
        }
        if let note = video.note {
            Section { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Galeriden seçilen video: geçici klasöre kopyalanır (sistem dosyası seçimden sonra silinir).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            guard let url = copyToTemp(received.file) else { throw BirdIdentificationError.imageLoadFailed }
            return PickedMovie(url: url)
        }
    }

    static func copyToTemp(_ source: URL) -> URL? {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("kus-video-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: source, to: dst)
            return dst
        } catch {
            return nil
        }
    }
}

/// Uygulama içinde en çok 10 sn video çekimi (sistem kamerası).
struct VideoRecorder: UIViewControllerRepresentable {
    let onFinish: (URL?) -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && (UIImagePickerController.availableMediaTypes(for: .camera)?.contains(UTType.movie.identifier) ?? false)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoMaximumDuration = VideoWindowSelector.window
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (URL?) -> Void

        init(onFinish: @escaping (URL?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish((info[.mediaURL] as? URL).flatMap(PickedMovie.copyToTemp))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
