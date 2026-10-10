import Observation
import SwiftUI

/// Çevrimiçi yedek kontrolün durumu (fotoğraf ve ses ekranında ortak). Düğme yoktur: cihazdaki sonuç
/// belirsizse ve internet varsa kendiliğinden çalışır (`OnlineCheckPolicy`); ekranda yalnızca durum yazısı görünür.
@MainActor
@Observable
final class OnlineBirdCheck {
    enum Phase: Equatable {
        /// Kontrol yok: hiçbir şey gösterilmez.
        case idle
        /// Gerekirdi ama internet yok.
        case offline
        /// Sunucu bekleniyor; `slow`: birkaç saniyedir yanıt yok (Space uyanıyor olabilir).
        case checking(slow: Bool)
        case finished([BirdPrediction])
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var kind: OnlineBirdID.Kind = .photo

    @ObservationIgnored private let client: OnlineBirdIDClient?
    @ObservationIgnored private let isOnline: @Sendable () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var slowNotice: Task<Void, Never>?

    init(client: OnlineBirdIDClient? = OnlineBirdIDClient.configured,
         isOnline: @escaping @Sendable () -> Bool = { NetworkState.shared.isOnline }) {
        self.client = client
        self.isOnline = isOnline
    }

    /// Cihazdaki sonuca göre karar verir; gerekiyorsa `payload`ı (fotoğraf/ses) hazırlatıp sunucuya sorar.
    /// `payload` ana iş parçacığı dışında çalışır.
    func evaluate(_ kind: OnlineBirdID.Kind, topProbability: Double?, onlyGeneral: Bool, settingEnabled: Bool,
                  payload: @escaping @Sendable () async throws -> Data) {
        cancel()
        self.kind = kind
        let decision = OnlineCheckPolicy.decide(settingEnabled: settingEnabled, configured: client != nil,
                                                online: isOnline(), topProbability: topProbability,
                                                onlyGeneral: onlyGeneral)
        UsageStats.birdID(kind, topProbability: topProbability, online: decision == .check)
        switch decision {
        case .skip: setPhase(.idle)
        case .offline: setPhase(.offline)
        case .check: start(kind, payload: payload)
        }
    }

    /// Süren kontrolü iptal eder ve durumu temizler (yeni fotoğraf/kayıt başlarken).
    func reset() {
        cancel()
        setPhase(.idle)
    }

    func cancel() {
        task?.cancel()
        task = nil
        slowNotice?.cancel()
        slowNotice = nil
    }

    private func setPhase(_ p: Phase) {
        if phase != p { phase = p }
    }

    private func start(_ kind: OnlineBirdID.Kind, payload: @escaping @Sendable () async throws -> Data) {
        guard let client else { return }
        phase = .checking(slow: false)
        slowNotice = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OnlineBirdID.slowNoticeAfter))
            guard !Task.isCancelled else { return }
            self?.markSlow()
        }
        task = Task { [weak self] in
            let result: Phase
            do {
                let data = try await payload()
                let response = try await client.identify(kind, data: data)
                result = .finished(response.predictions())
            } catch {
                // Ayrıntı gösterilmez ve günlüğe yazılmaz
                result = .failed
            }
            guard !Task.isCancelled else { return }
            self?.finish(result)
        }
    }

    private func markSlow() {
        if case .checking(false) = phase { phase = .checking(slow: true) }
    }

    private func finish(_ result: Phase) {
        slowNotice?.cancel()
        slowNotice = nil
        task = nil
        phase = result
    }
}

/// Sonuç alanındaki çevrimiçi kontrol satırı/bölümü. `idle` iken hiçbir şey çizmez.
struct OnlineBirdCheckSection: View {
    @Environment(AppModel.self) private var model
    let check: OnlineBirdCheck

    var body: some View {
        let name = check.kind.modelName
        switch check.phase {
        case .idle:
            EmptyView()
        case .offline:
            Section {
                Label("İnternet yok — yalnızca cihazdaki sonuç gösteriliyor.", systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .checking(let slow):
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Cihazdaki model emin değil — internete soruluyor (%@)…", name))
                            .font(.callout)
                        if slow {
                            Text("Çevrimiçi model uyanıyor, bu bir dakika sürebilir…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        case .finished(let predictions):
            Section {
                if predictions.isEmpty {
                    Text("Çevrimiçi model de bir tür bulamadı.").foregroundStyle(.secondary)
                } else {
                    ForEach(predictions) { p in
                        PhotoPredictionRow(prediction: p,
                                           status: model.regs?.legalStatus(scientific: p.scientificName, on: model.now))
                    }
                }
            } header: {
                Text(L("Çevrimiçi tahmin (%@)", name))
            }
        case .failed:
            Section {
                Label("Çevrimiçi kontrol yapılamadı.", systemImage: "exclamationmark.icloud")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
