import SwiftUI

// MARK: - Çevrimdışı harita: durum, indirme, güncelleme, silme (Katmanlar ve Ayarlar'da)

struct OfflineMapPanel: View {
    private var store: OfflineMapStore { .shared }
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.hasHighPack ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(store.hasHighPack ? Color.green : Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(BaseLayer.offlineTopo.title).font(.headline)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
            }

            if store.isDownloading {
                ProgressView(value: store.progress)
                HStack {
                    Text(L("%@ / %@", OfflineMapStore.format(store.bytesWritten), OfflineMapStore.format(store.bytesExpected)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Durdur", role: .cancel) { store.cancelDownload() }
                }
            } else if store.isVerifying {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Doğrulanıyor…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    if !store.hasHighPack {
                        Button {
                            store.download()
                        } label: {
                            Label(store.hasResumeData ? L("Kaldığı yerden devam et") : L("İndir"), systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    } else if store.updateAvailable {
                        Button {
                            store.download()
                        } label: {
                            Label("Güncelle", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Güncellemeleri denetle") { store.checkForUpdate() }
                            .buttonStyle(.bordered)
                    }
                    if store.hasHighPack || store.hasResumeData {
                        Button("Sil", role: .destructive) { confirmDelete = true }
                            .buttonStyle(.bordered)
                    }
                    if store.isChecking { ProgressView() }
                }
                .disabled(store.isChecking || (!store.isOnline && !store.hasHighPack && !store.hasResumeData))
            }

            if let e = store.errorMessage {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Topoğrafik harita (OpenStreetMap + Copernicus yükselti verisi) cihazda saklanır ve internetsiz çalışır. Genel görünüm uygulamayla gelir; köy ve patika düzeyindeki ayrıntılı kısım (en çok 150 MB) bir kez indirilir. Sahaya çıkmadan önce Wi-Fi'de indirin.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .confirmationDialog(Text("Çevrimdışı harita silinsin mi?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Sil", role: .destructive) { store.deleteDownloaded() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("İnternet olmayan yerlerde ayrıntılı harita görünmez; yeniden indirmeniz gerekir.")
        }
    }

    private var statusLine: String {
        if let i = store.installed {
            var s = L("Yüklü: sürüm %@ · %@", i.version, OfflineMapStore.format(i.file.bytes))
            if store.updateAvailable, let v = store.latest?.version {
                s += "\n" + L("Yeni sürüm var: %@", v)
            } else if store.checkedUpToDate {
                s += " · " + L("güncel")
            }
            return s
        }
        if store.isDownloading { return L("İndiriliyor…") }
        if !store.isOnline { return L("İnternet yok: indirmek için bağlantı gerekli") }
        if store.lowPackBundled { return L("Genel görünüm yüklü; ayrıntılı harita indirilmedi") }
        return L("İndirilmedi")
    }
}

// MARK: - Hücresel veri onayı

/// Hücresel bağlantıda 50 MB'den büyük indirme için onay. `active` yalnızca o an görünen ekranda açık olmalı.
struct CellularDownloadConfirmation: ViewModifier {
    private var store: OfflineMapStore { .shared }
    var active = true

    func body(content: Content) -> some View {
        let pending = store.pendingCellular
        content.confirmationDialog(
            Text("Mobil veri kullanılsın mı?"),
            isPresented: Binding(get: { active && store.pendingCellular != nil },
                                 set: { if !$0 { store.cancelPending() } }),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(L("Mobil veriyle indir (%@)", OfflineMapStore.format(pending.highPack?.bytes ?? 0))) {
                    store.confirmCellular(pending)
                }
            }
            Button("Wi-Fi'yi bekle", role: .cancel) { store.cancelPending() }
        } message: {
            Text(L("Çevrimdışı harita %@. Mobil veri kotanızdan düşer; Wi-Fi'de indirmeniz önerilir.",
                   OfflineMapStore.format(pending?.highPack?.bytes ?? 0)))
        }
    }
}

extension View {
    func cellularDownloadConfirmation(active: Bool = true) -> some View {
        modifier(CellularDownloadConfirmation(active: active))
    }
}

// MARK: - İlk açılışta bir kez: sahaya çıkmadan haritayı indir

struct OfflinePromptBanner: View {
    let onDownload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sahada internet olmayabilir", systemImage: "wifi.slash").font(.subheadline.bold())
            Text("Çekmeyen yerlerde de harita görünsün diye ayrıntılı topoğrafik haritayı Wi-Fi'deyken indirin (en çok 150 MB).")
                .font(.caption)
            HStack {
                Button("İndir", action: onDownload).buttonStyle(.borderedProminent)
                Button("Sonra", action: onDismiss).buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }
}
