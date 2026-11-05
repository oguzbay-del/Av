import SwiftUI

/// Haritanın sağ kenarındaki ince cam araç sütunu (sosyal uygulamalardaki sağ eylem sütunu gibi).
/// Üstte seyrek kullanılanlar (Katmanlar, İşaret koy, İz kaydı), altta başparmağa yakın olanlar (Konum, +, −,
/// Acil durum). Yer yetmezse yalnızca üst grup kaydırılır; −/+, Konum ve Acil durum hiçbir ekranda gizlenmez
/// (`MapOverlayLayout.railOptionalHeight`). Dokunma alanı en az 48 pt, saha modunda en az 60 pt.
/// Saha modunda zemin güneşte okunsun diye daha opak; "Saydamlığı Azalt" açıksa düz zemin (`glassRail`).
struct MapToolRail: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var tracks: TrackLog
    let following: Bool
    /// Sütuna ayrılan dikey alan (güvenlik şeridinin altı); ölçülmeden önce 0.
    let region: CGFloat
    let onLayers: () -> Void
    let onLocate: () -> Void
    let onZoom: (MapZoomDirection) -> Void
    let onAddWaypoint: () -> Void
    @State private var showEmergency = false
    @State private var zoomTaps = 0
    /// Büyük yazı boyutunda düğme de büyür ama haritayı kapatmasın diye 64 pt ile sınırlı.
    /// Saha modunda (eldiven) en az 60 pt, en çok 76 pt.
    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 48
    @Environment(\.fieldMode) private var fieldMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Sütunun iç dikey boşluğu.
    static let inset: CGFloat = 4
    static func side(size: CGFloat, fieldMode: Bool) -> CGFloat {
        fieldMode ? min(max(size * 1.3, FieldTheme.minTarget), 76) : min(size, 64)
    }

    private var side: CGFloat { Self.side(size: size, fieldMode: fieldMode) }
    /// Ayırıcı çizgi ve çevresindeki boşluk.
    private var separator: CGFloat { fieldMode ? 9 : 7 }
    private var optionalHeight: CGFloat? {
        MapOverlayLayout.railOptionalHeight(region: Double(region), side: Double(side),
                                            chrome: Double(2 * Self.inset + 2 * separator)).map { CGFloat($0) }
    }

    var body: some View {
        GlassGroup(spacing: 0) {
            VStack(spacing: 0) {
                if let h = optionalHeight {
                    ScrollView { optionalTools }
                        .frame(height: h)
                        .scrollIndicators(.visible)
                        .scrollBounceBehavior(.basedOnSize)
                } else {
                    optionalTools
                }
                divider
                tool(following ? "location.fill" : "location",
                     following ? L("Konum takip ediliyor") : L("Konumuma git"), action: onLocate)
                tool("plus", L("Yakınlaştır")) { zoom(.zoomIn) }
                tool("minus", L("Uzaklaştır")) { zoom(.zoomOut) }
                divider
                tool("sos", L("Acil durum"), tint: .red) { showEmergency = true }
            }
            .padding(.vertical, Self.inset)
            .frame(width: side + 2 * Self.inset)
            .glassRail(fieldMode: fieldMode, reduceTransparency: reduceTransparency)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: zoomTaps)
        .sheet(isPresented: $showEmergency) {
            EmergencyCard().environment(model).presentationDetents([.medium, .large])
        }
    }

    private var optionalTools: some View {
        VStack(spacing: 0) {
            tool("square.3.layers.3d", L("Katmanlar"), action: onLayers)
            tool("mappin.and.ellipse", L("İşaret koy"), action: onAddWaypoint)
            tool(tracks.isRecording ? "stop.circle.fill" : "record.circle",
                 tracks.isRecording ? L("İzi durdur") : L("İz kaydı"), tint: tracks.isRecording ? .red : nil) {
                if tracks.isRecording { tracks.stop() } else { tracks.start() }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(.secondary.opacity(0.35))
            .frame(width: side * 0.5, height: 1)
            .padding(.vertical, (separator - 1) / 2)
            .accessibilityHidden(true)
    }

    private func zoom(_ d: MapZoomDirection) {
        zoomTaps += 1
        onZoom(d)
    }

    private func tool(_ systemImage: String, _ label: String, tint: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(fieldMode ? .title2.weight(.semibold) : .title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint ?? .primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
