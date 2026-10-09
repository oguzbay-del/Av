import SwiftUI

/// Kuş sesini 15 sn kaydeder, BirdNET (cihazda ya da sunucuda) veya genel sınıflandırıcı ile türü tahmin eder
/// ve türün MAK 2026-27'ye göre bugünkü durumunu gösterir.
struct BirdIDView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var bird = BirdIDModel()
    @State private var mode = Mode.sound
    @AppStorage("birdnetURL") private var birdnetURL = ""
    @AppStorage("birdnetPreferServer") private var preferServer = false

    enum Mode: Hashable { case sound, photo }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .sound: soundList
                case .photo: BirdPhotoIDView()
                }
            }
            .navigationTitle(mode == .sound ? L("Kuş sesi tanıma") : L("Fotoğraftan tanıma"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                Picker("Yöntem", selection: $mode) {
                    Label("Ses", systemImage: "waveform").tag(Mode.sound)
                    Label("Fotoğraf", systemImage: "camera").tag(Mode.photo)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 6)
                .background(.bar)
                .disabled(bird.isBusy)
            }
        }
    }

    private var soundList: some View {
        List {
            Section {
                recorder
            } footer: {
                pathFooter
            }

            if !bird.detections.isEmpty {
                Section("Tahminler") {
                    ForEach(bird.detections) { d in
                        DetectionRow(detection: d, status: model.regs?.legalStatus(scientific: d.scientificName, on: model.now))
                    }
                }
            } else if bird.state == .done {
                Section {
                    Text("Kuş sesi tanınamadı. Daha yakından ve sessiz bir ortamda yeniden deneyin.")
                        .foregroundStyle(.secondary)
                }
            }
            if let n = bird.note {
                Section { Text(n).font(.caption).foregroundStyle(.secondary) }
            }

            Section {
                Label("Tahmin bir yardımdır, kesin teşhis değildir. Türden emin olmadan atış yapmayın; koruma altındaki türler ses olarak av türlerine benzeyebilir.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
            } footer: {
                Text("Model: BirdNET (K. Lisa Yang Center for Conservation Bioacoustics, Cornell Lab of Ornithology & Chemnitz University of Technology), CC BY-NC-SA 4.0 — ticari olmayan kullanım.")
            }
        }
    }

    /// Kaydın nereye gittiğini doğru söyler (cihazda BirdNET: hiçbir şey telefondan çıkmaz).
    @ViewBuilder
    private var pathFooter: some View {
        switch BirdIDModel.path(serverURL: birdnetURL, preferServer: preferServer) {
        case .onDevice:
            Text("Kuşa doğru tutun, konuşmayın. Kayıt telefonda BirdNET modeliyle çözümlenir; ses ve konum telefondan çıkmaz, internet gerekmez. Tahmin, İstanbul'da o hafta bulunabilecek türlerle sınırlanır.")
        case .server:
            Text("Kuşa doğru tutun, konuşmayın. Kayıt BirdNET sunucusuna konum ve hafta bilgisiyle gönderilir; konum, o bölgede o mevsimde bulunabilecek türlere göre tahmini iyileştirir.")
        case .general:
            Text("Kuşa doğru tutun, konuşmayın. Kayıt telefonda iOS'un genel ses sınıflandırıcısıyla çözümlenir ve telefondan çıkmaz; bu sınıflandırıcı tür değil yalnızca grup (ördek, kaz, baykuş…) söyler.")
        }
    }

    @ViewBuilder
    private var recorder: some View {
        VStack(spacing: 14) {
            switch bird.state {
            case .recording(let p):
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 8)
                    Circle().trim(from: 0, to: p).stroke(Color.red, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle().fill(Color.red.opacity(0.15 + 0.6 * Double(bird.level)))
                        .padding(18)
                    Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                }
                .frame(width: 140, height: 140)
                Text(L("Dinleniyor… %@ sn", String(Int((1 - p) * BirdIDModel.duration)))).font(.headline)
                Button("Durdur ve analiz et") { bird.stop(location: model.location?.coordinate) }
                    .buttonStyle(.bordered)
            case .analyzing:
                ProgressView().controlSize(.large).frame(height: 140)
                Text("Analiz ediliyor…").font(.headline)
            default:
                Button { bird.start(location: model.location?.coordinate, regs: model.regs) } label: {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "mic.fill").font(.system(size: 48)).foregroundStyle(.white)
                            .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: bird.state == .idle)
                    }
                    .frame(width: 140, height: 140)
                }
                .buttonStyle(.plain)
                Text(bird.state == .done ? L("Yeniden dinle") : L("Dinlemeye başla")).font(.headline)
                if case .failed(let msg) = bird.state {
                    Text(msg).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct DetectionRow: View {
    let detection: BirdDetection
    let status: BirdLegalStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    // İngilizcede BirdNET'in İngilizce adı, Türkçede MAK listesindeki Türkçe ad
                    let primary = AppLocale.isEnglish ? detection.commonName : (status?.turkishName ?? detection.commonName)
                    Text(primary).font(.headline)
                    if let sci = detection.scientificName {
                        Text(primary == detection.commonName ? sci : "\(detection.commonName) · \(sci)")
                            .font(.caption).italic().foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(verbatim: "%" + String(Int((detection.confidence * 100).rounded())))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(detection.confidence >= 0.7 ? Color.primary : Color.secondary)
            }
            ProgressView(value: detection.confidence).tint(detection.confidence >= 0.7 ? .green : .orange)
            if let s = status {
                Label(s.text, systemImage: s.level.icon)
                    .font(.caption.bold())
                    .foregroundStyle(s.level.color)
            }
            if let rival = detection.similarProtected {
                Label(L("Emin değil — benzer korunan tür: %@", rival), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
            Text(detection.source.title + (detection.start.map { " · " + L("%@. sn", String(Int($0))) } ?? ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

extension BirdLegalStatus.Level {
    var icon: String {
        switch self {
        case .allowedToday: return "checkmark.circle.fill"
        case .allowedNotToday: return "calendar.badge.exclamationmark"
        case .provinceBanned, .protected, .notGame: return "xmark.octagon.fill"
        case .falconry: return "bird.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .allowedToday: return .green
        case .allowedNotToday, .falconry, .unknown: return .orange
        case .provinceBanned, .protected, .notGame: return .red
        }
    }
}
