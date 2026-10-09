import CoreLocation
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("acceptedDisclaimer_2026") private var acceptedDisclaimer = false
    @AppStorage("selectedTab") private var selectedTab = "harita"

    var body: some View {
        Group {
            if model.map != nil {
                tabs
            } else {
                ContentUnavailableView("Harita yüklenemedi", systemImage: "map",
                                       description: Text(model.loadError ?? ""))
            }
        }
        .onAppear { model.start() }
        .fullScreenCover(isPresented: Binding(get: { !acceptedDisclaimer }, set: { acceptedDisclaimer = !$0 })) {
            DisclaimerView(mapSeason: model.map?.meta.season ?? "", rulesTitle: model.regs?.title ?? "",
                           needsLocation: model.authorization == .notDetermined,
                           onEnableLocation: { model.requestLocationPermission() }) {
                acceptedDisclaimer = true
            }
        }
    }
}

extension ContentView {
    /// iOS 18+: yeni Tab API'si (iOS 26'da yüzen cam sekme çubuğu, kaydırınca küçülür); öncesi eski tabItem.
    @ViewBuilder var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Harita", systemImage: "map", value: "harita") { MapScreen() }
                Tab("Bugün", systemImage: "calendar", value: "bugun") { TodayView() }
                Tab("Kurallar", systemImage: "book.closed", value: "kurallar") { RulesView() }
                Tab("Kuş Tanı", systemImage: "bird", value: "kus") { BirdIDView() }
            }
            .minimizeTabBarOnScroll()
        } else {
            TabView(selection: $selectedTab) {
                MapScreen()
                    .tabItem { Label("Harita", systemImage: "map") }
                    .tag("harita")
                TodayView()
                    .tabItem { Label("Bugün", systemImage: "calendar") }
                    .tag("bugun")
                RulesView()
                    .tabItem { Label("Kurallar", systemImage: "book.closed") }
                    .tag("kurallar")
                BirdIDView()
                    .tabItem { Label("Kuş Tanı", systemImage: "bird") }
                    .tag("kus")
            }
        }
    }
}

struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.8
    @AppStorage("baseLayer") private var baseLayerRaw = BaseLayer.appleHybrid.rawValue
    @AppStorage("showBuffers") private var showBuffers = false
    @AppStorage("showScentCone") private var showScentCone = false
    @AppStorage("showZones") private var showZones = true
    @AppStorage("showOfficial") private var showOfficial = false
    @AppStorage("rotateWithHeading") private var rotateWithHeading = false
    @State private var showLayers = false
    @State private var showSearch = false
    @State private var showPermits = false
    @State private var followUser = true
    @State private var showLegend = false
    @State private var showSettings = false
    @AppStorage("bannerExpanded") private var expanded = false
    /// İlk açılışta bir kez gösterilen "haritayı indir" önerisi.
    @AppStorage("offlinePromptShown") private var offlinePromptShown = false

    private var offline: OfflineMapStore { .shared }
    private var baseLayer: BaseLayer { BaseLayer(rawValue: baseLayerRaw) ?? .appleHybrid }
    /// Gösterilen altlık: internet yokken çevrimiçi altlık yerine (varsa) çevrimdışı topo.
    private var shownLayer: BaseLayer {
        BaseLayer.effective(chosen: baseLayer, online: offline.isOnline, offlineAvailable: offline.hasAnyPack)
    }
    private var attribution: String? {
        shownLayer == .offlineTopo ? offline.attribution : shownLayer.attribution
    }

    var body: some View {
        @Bindable var model = model
        if let map = model.map {
            ZStack {
                HuntingMapView(map: map, features: model.features, regs: model.regs,
                               followUser: $followUser,
                               inspectedCoordinate: $model.inspectedCoordinate,
                               overlayOpacity: overlayOpacity,
                               baseLayer: shownLayer,
                               showBuffers: showBuffers,
                               scentCone: scentCone,
                               zoneShapes: model.zoneShapes,
                               showZones: showZones,
                               showOfficial: showOfficial || model.zoneShapes.isEmpty,
                               focus: model.focus,
                               heading: rotateWithHeading ? model.heading : nil,
                               highlightName: model.highlighted?.area == nil ? nil : model.highlightedAvlak,
                               highlightPolygons: model.highlighted?.area?.polygons ?? [],
                               offlineRevision: offline.revision)
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 8) {
                    if !locationAllowed {
                        PermissionBanner(notDetermined: model.authorization == .notDetermined) {
                            model.requestLocationPermission()
                        }
                    } else {
                        StatusBanner(assessment: model.assessment, location: model.location, expanded: $expanded,
                                     stationary: model.isStationary)
                        SystemStatusRow()
                        if model.reducedAccuracy {
                            Button { model.requestFullAccuracy() } label: {
                                Label("Kesin konumu aç", systemImage: "location.fill.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                    if !offlinePromptShown, !offline.hasHighPack, offline.isOnline, !offline.isDownloading {
                        OfflinePromptBanner(onDownload: {
                            offlinePromptShown = true
                            offline.download()
                        }, onDismiss: {
                            withAnimation { offlinePromptShown = true }
                        })
                    }
                    if let c = model.inspectedCoordinate, let a = model.inspected {
                        InspectCard(coordinate: c, assessment: a) { model.inspectedCoordinate = nil }
                    }
                    Spacer()
                    // Kural listesi açıkken alttaki kontroller gizlenir (küçük ekranda taşmasın)
                    if !(expanded && locationAllowed) {
                        HStack(alignment: .bottom) {
                            if let n = model.nearestForbidden {
                                NearestForbiddenChip(nearest: n, heading: model.heading)
                            }
                            Spacer()
                            // Haritada yalnızca sık kullanılan 3 kontrol (Apple Haritalar gibi); diğerleri alt panelde
                            GlassGroup { VStack(alignment: .trailing, spacing: 10) {
                                if let h = model.currentWeather {
                                    Button { showScentCone.toggle() } label: {
                                        WindBadge(hour: h, showCone: showScentCone)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Rüzgâr ve koku konisi")
                                }
                                RoundButton(systemImage: "square.3.layers.3d") { showLayers = true }
                                    .accessibilityLabel("Katmanlar")
                                RoundButton(systemImage: followUser ? "location.fill" : "location") { followUser = true }
                                    .accessibilityLabel(followUser ? L("Konum takip ediliyor") : L("Konumuma git"))
                            } }
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        }
                        MapBottomPanel(map: map, attribution: attribution,
                                       showSearch: $showSearch, showPermits: $showPermits,
                                       showLegend: $showLegend, showSettings: $showSettings)
                    }
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 26)   // Apple "Yasal" etiketi görünür kalsın
            }
            .cellularDownloadConfirmation(active: !showLayers && !showSettings)
            .sheet(isPresented: $showLayers) {
                LayersSheet(baseLayerRaw: $baseLayerRaw, showZones: $showZones, showOfficial: $showOfficial,
                            overlayOpacity: $overlayOpacity, showBuffers: $showBuffers, showScentCone: $showScentCone,
                            hasWeather: model.currentWeather != nil)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showPermits) {
                PermitSheet(store: model.permits).environment(model)
            }
            .sheet(isPresented: $showSearch) {
                PlaceSearchView().environment(model)
            }
            .sheet(isPresented: $showLegend) {
                LegendView(classes: map.allClasses, source: map.meta.source, season: map.meta.season)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(overlayOpacity: $overlayOpacity, baseLayerRaw: $baseLayerRaw, showBuffers: $showBuffers)
                    .environment(model)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var scentCone: [CLLocationCoordinate2D]? {
        guard showScentCone, let h = model.currentWeather, let c = model.location?.coordinate, h.windSpeed >= 1 else { return nil }
        return ScentCone.polygon(from: c, windFrom: h.windFrom, windSpeed: h.windSpeed)
    }

    private var locationAllowed: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(model.authorization)
    }
}

struct RoundButton: View {
    let systemImage: String
    let action: () -> Void
    /// Büyük yazı boyutunda düğme de büyür ama haritayı kapatmasın diye 64 pt ile sınırlı.
    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 48
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: min(size, 64), height: min(size, 64))
                .glassCircle()
        }
        .buttonStyle(.plain)
    }
}

extension Assessment.Level {
    var icon: String {
        switch self {
        case .danger: return "xmark.octagon.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .safe: return "checkmark.shield.fill"
        case .unknown: return "location.slash"
        }
    }

    var color: Color {
        switch self {
        case .danger: return .red
        case .caution: return .orange
        case .safe: return .green
        case .unknown: return .gray
        }
    }
}

struct StatusBanner: View {
    let assessment: Assessment
    let location: CLLocation?
    @Binding var expanded: Bool
    var stationary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: assessment.level.icon)
                        .font(.system(size: 26, weight: .bold))
                        // Durum değişince simge zıplar (yasak alana girişte dikkat çeker)
                        .symbolEffect(.bounce, value: assessment.level)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assessment.title).font(.headline).multilineTextAlignment(.leading)
                        Text(assessment.detail).font(.subheadline).multilineTextAlignment(.leading)
                            .lineLimit(expanded ? 4 : 2)
                        if expanded, let l = location {
                            Text(String(format: "%.5f, %.5f  ·  GPS ±%.0f m", l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy)
                                 + (l.verticalAccuracy > 0 ? "  ·  " + L("rakım %@ m", String(Int(l.altitude.rounded()))) : "")
                                 + (stationary ? "  ·  " + L("pusu: pil tasarrufu") : ""))
                                .font(.caption.monospacedDigit())
                                .opacity(0.85)
                        }
                    }
                    Spacer(minLength: 0)
                    if !assessment.checks.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.bold())
                    }
                }
                // Açık listenin altında başlık ve açıklama sıkışıp "…" ile kesilmesin
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)

            if expanded {
                // Uzun listede harita ve sekme çubuğu kapanmasın
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ChecksList(checks: assessment.checks, onColored: assessment.level != .unknown)
                        if let u = assessment.unitName {
                            Text(L("Avlak (yaklaşık, 2024-25 sınırları): %@", u)).font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(assessment.level == .unknown ? Color.primary : Color.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(assessment.level == .unknown ? Color(.secondarySystemBackground) : assessment.level.color,
                    in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 4)
        .animation(.easeInOut, value: assessment.level)
        // Kötüleşmede AppModel uyarı titreşimi verir; burada yalnızca güvenli alana dönüş hissettirilir
        .sensoryFeedback(trigger: assessment.placeLevel) { old, new in
            new == .safe && old >= .caution ? .success : nil
        }
    }
}

struct ChecksList: View {
    let checks: [RuleCheck]
    var onColored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(checks) { c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: c.level.icon)
                        .foregroundStyle(onColored ? AnyShapeStyle(Color.white) : AnyShapeStyle(c.level.color))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((c.kind == .time ? L("Zaman · ") : L("Yer · ")) + c.title).font(.caption.bold())
                        Text(c.detail).font(.caption2)
                    }
                }
            }
        }
        .padding(8)
        .background(onColored ? AnyShapeStyle(Color.black.opacity(0.15)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct InspectCard: View {
    let coordinate: CLLocationCoordinate2D
    let assessment: Assessment
    let onClose: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: assessment.level.icon).foregroundStyle(assessment.level.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Seçilen nokta: ") + assessment.title).font(.subheadline.bold())
                    if let u = assessment.unitName { Text(L("Avlak (yaklaşık): %@", u)).font(.caption) }
                    Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up.circle" : "chevron.down.circle")
                }
                .buttonStyle(.plain)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if expanded { ChecksList(checks: assessment.checks) }
        }
        .padding(12)
        .glassCard(cornerRadius: 14)
    }
}

struct PermissionBanner: View {
    /// Henüz sorulmadıysa sistem iznini iste; reddedildiyse Ayarlar'a yönlendir.
    var notDetermined = false
    var onRequest: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Konum izni gerekli", systemImage: "location.slash").font(.headline)
            if notDetermined {
                Text("Yasak alana girdiğinizde uyarabilmek için konumunuz gerekir. Konum geçmişi yalnızca iz kaydını başlatırsanız cihazda saklanır.").font(.subheadline)
                Button("Konumu etkinleştir", action: onRequest)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Bulunduğunuz alanı gösterebilmek için Ayarlar'dan konum iznini açın.").font(.subheadline)
                Button("Ayarları aç") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }
}

extension ZoneStatus {
    var label: String {
        switch self {
        case .yasak: return L("Avlanmak yasak")
        case .dikkat: return L("Özel izin / ek kural gerekebilir")
        case .izinli: return L("Belge, izin kartı ve MAK kararına uyarak avlanılabilir")
        case .disarida: return L("Avlak olarak işaretli değil")
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
