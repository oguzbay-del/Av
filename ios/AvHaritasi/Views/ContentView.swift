import CoreLocation
import StoreKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("acceptedDisclaimer_2026") private var acceptedDisclaimer = false
    /// İlk açılış tanıtımı (kılavuzun `tanitim` konuları) gösterildi mi; uyarı kabulünden sonra bir kez.
    @AppStorage("tanitimGosterildi") private var tanitimGosterildi = false
    @AppStorage("selectedTab") private var selectedTab = "harita"
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview

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
        .onChange(of: selectedTab, initial: true) { _, tab in
            if let f = UsageFeature(tab: tab) { UsageStats.record(f) }
        }
        .task(id: scenePhase) { await askForReviewIfDue() }
        .modifier(FieldThemeRoot())
        .alert(Text("Uygulama kilidi"), isPresented: Binding(get: { AppLock.shared.notice != nil && !AppLock.shared.isLocked },
                                                           set: { if !$0 { AppLock.shared.notice = nil } })) {
            Button("Tamam", role: .cancel) { AppLock.shared.notice = nil }
        } message: {
            Text(AppLock.shared.notice ?? "")
        }
        // Tek tam ekran örtü: önce "Önemli" uyarısı (kabul edilmeden geçilmez), ardından bir kez tanıtım.
        // İki ayrı örtü art arda açılamadığı için içerik aynı örtüde değişir.
        .fullScreenCover(isPresented: Binding(get: { !acceptedDisclaimer || !tanitimGosterildi },
                                              set: { if !$0, acceptedDisclaimer { tanitimGosterildi = true } })) {
            if !acceptedDisclaimer {
                DisclaimerView(mapSeason: model.map?.meta.season ?? "", rulesTitle: model.regs?.title ?? "",
                               needsLocation: model.authorization == .notDetermined,
                               onEnableLocation: { model.requestLocationPermission() }) {
                    acceptedDisclaimer = true
                }
            } else {
                TanitimView(konular: Kilavuz.paket.tanitimKonulari) { tanitimGosterildi = true }
            }
        }
    }
}

extension ContentView {
    /// App Store değerlendirme istemi (`ReviewPromptPolicy`): öne geldikten birkaç saniye sonra, uyarı yokken.
    func askForReviewIfDue() async {
        guard scenePhase == .active else { return }
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, scenePhase == .active, acceptedDisclaimer, tanitimGosterildi else { return }
        // Güvenlik uyarısı (yasak/dikkat alanı, bayat GPS, Kesin Konum kapalı) ya da demo sürerken asla
        let safetyAlert = model.assessment.placeLevel >= .caution || model.locationStale || model.demoActive
        guard ReviewPromptPolicy.shouldPrompt(ReviewPromptStore.state, now: Date(), safetyAlertActive: safetyAlert)
        else { return }
        ReviewPromptStore.update { ReviewPromptPolicy.recordPrompt(&$0, now: Date()) }
        requestReview()
    }

    /// iOS 18+: yeni Tab API'si (iOS 26'da yüzen cam sekme çubuğu, kaydırınca küçülür); öncesi eski tabItem.
    @ViewBuilder var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Harita", systemImage: "map", value: "harita") { MapScreen() }
                Tab("Bugün", systemImage: "calendar", value: "bugun") { TodayView() }
                Tab("Kurallar", systemImage: "book.closed", value: "kurallar") { RulesView() }
                Tab("Kuş Tanı", systemImage: "bird", value: "kus") { BirdIDView() }
                Tab("Ayarlar", systemImage: "gearshape", value: "ayarlar") { SettingsTab() }
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
                SettingsTab()
                    .tabItem { Label("Ayarlar", systemImage: "gearshape") }
                    .tag("ayarlar")
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
    /// +/− düğmelerinin son isteği (haritaya iletilir).
    @State private var zoomRequest: MapZoomRequest?
    /// Yerleşim ölçüleri (`MapOverlayLayout`): kontrol alanı, alt yığın, güvenlik şeridi, kartların doğal
    /// yüksekliği, kontroller ve alt panel. Kartlar aradaki boşluğa sığdırılır.
    @State private var overlayHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    @State private var safetyHeight: CGFloat = 0
    @State private var cardsHeight: CGFloat = 0
    @State private var controlsBlockHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0
    /// Sağ araç sütununun genişliği (kartlar, sınır satırı ve alt panel bu kadar sola çekilir).
    @State private var railWidth: CGFloat = 0
    @State private var showLegend = false
    @State private var showSettings = false
    @State private var waypointDraft: WaypointDraft?
    @State private var selectedWaypoint: WaypointRef?
    @State private var showWaypoints = false
    @State private var showGuidance = false
    /// Sayfa kapanınca yönlendirme ekranını aç (sayfa üstüne tam ekran açılamaz).
    @State private var pendingGuidance = false
    @AppStorage("selectedTab") private var selectedTab = "harita"
    @AppStorage("bannerExpanded") private var expanded = false
    /// İlk açılışta bir kez gösterilen "haritayı indir" önerisi.
    @AppStorage("offlinePromptShown") private var offlinePromptShown = false
    @Environment(\.fieldMode) private var fieldMode
    @Environment(\.nightRed) private var nightRed

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
                               zoom: zoomRequest,
                               heading: rotateWithHeading ? model.heading : nil,
                               highlightName: model.highlighted?.area == nil ? nil : model.highlightedAvlak,
                               highlightPolygons: model.highlighted?.area?.polygons ?? [],
                               offlineRevision: offline.revision,
                               userLocation: model.location,
                               borderTarget: model.nearestForbidden?.point,
                               waypoints: model.waypoints.items,
                               onSelectWaypoint: { selectedWaypoint = WaypointRef(id: $0) })
                    .ignoresSafeArea(edges: .top)
                if nightRed {
                    NightMapDim().ignoresSafeArea(edges: .top)
                }

                // Üst (durum şeridi, kartlar), alt (sınır/rüzgâr satırı, panel) ve sağ kenarda araç sütunu: içerik
                // ekrana sığmasa bile güvenlik şeridi üstte tam görünür, alt panel sekme çubuğunun altına itilmez.
                // Sütun şeridin altından başlar; kartlar, alt satır ve panel onun solunda kalır (çakışmaz). Üst
                // yığın en üstte çizilir; çakışmada hiçbir şey şeridi örtmez.
                ZStack {
                    VStack(spacing: fieldMode ? 12 : 8) {
                        // Kural listesi açıkken alttaki kontroller gizlenir (küçük ekranda taşmasın)
                        if showsControls {
                            VStack(spacing: fieldMode ? 12 : 8) { mapControls() }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsBlockHeight = $0 }
                            if !hidesPanel {
                                MapBottomPanel(map: map, attribution: attribution,
                                               showSearch: $showSearch, showPermits: $showPermits,
                                               showLegend: $showLegend, showSettings: $showSettings,
                                               onShowWaypoints: { showWaypoints = true })
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                        if $0 > 0 { panelHeight = $0 }
                                    }
                            }
                        }
                    }
                    .padding(.trailing, railInset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    if showsControls {
                        MapToolRail(tracks: model.tracks, following: followUser, region: railRegion,
                                    onLayers: { showLayers = true },
                                    onLocate: { followUser = true },
                                    onZoom: { zoomRequest = MapZoomRequest(direction: $0) },
                                    onAddWaypoint: { waypointDraft = WaypointDraft(coordinate: nil) })
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { railWidth = $0 }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(.top, safetyHeight + (fieldMode ? 12 : 8))
                    }
                    VStack(spacing: fieldMode ? 12 : 8) {
                        VStack(spacing: fieldMode ? 12 : 8) {
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
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { safetyHeight = $0 }
                        // Sorgu kartı ve öneri yer yoksa kaydırılır; kontrolleri ve güvenlik şeridini itmez/örtmez
                        if hasCards {
                            ViewThatFits(in: .vertical) {
                                cards
                                ScrollView { cards }.scrollBounceBehavior(.basedOnSize)
                            }
                            .padding(.trailing, railInset)
                        }
                    }
                    // Kartların doğal yüksekliği (görünmez kopya; yalnızca ölçü için)
                    .background(alignment: .top) {
                        if hasCards {
                            cards.padding(.trailing, railInset).fixedSize(horizontal: false, vertical: true).hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
                        }
                    }
                    .frame(maxHeight: topLimit, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overlayHeight = $0 }
                .padding([.horizontal, .top])
                .padding(.bottom, 26)   // Apple "Yasal" etiketi görünür kalsın
            }
            .cellularDownloadConfirmation(active: !showLayers && !showSettings && selectedTab != "ayarlar")
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
            .sheet(item: $waypointDraft) { d in
                AddWaypointSheet(draft: d).environment(model).presentationDetents([.medium, .large])
            }
            .sheet(item: $selectedWaypoint, onDismiss: { openPendingGuidance() }) { r in
                WaypointDetailSheet(id: r.id, onGuide: { guide($0) }).environment(model).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showWaypoints, onDismiss: { openPendingGuidance() }) {
                WaypointListView(onGuide: { guide($0) }, onSelect: { id in
                    showWaypoints = false
                    if let w = model.waypoints.items.first(where: { $0.id == id }) {
                        model.focus = MapFocus(coordinate: w.coordinate, span: 1_500)
                    }
                })
                .environment(model).presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showGuidance) {
                WaypointGuidanceView().environment(model)
            }
            .task {
                #if DEBUG
                // Ekran görüntüleri: -acYonlendir <tür> ile yönlendirme açılışta açılır
                if ScreenshotArguments.guideKind != nil, model.waypoints.guiding != nil {
                    try? await Task.sleep(for: .seconds(1.5))
                    showGuidance = true
                }
                #endif
            }
        }
    }

    private var hasCards: Bool {
        (!offlinePromptShown && !offline.hasHighPack && offline.isOnline && !offline.isDownloading)
            || (model.inspectedCoordinate != nil && model.inspected != nil)
    }

    /// Üstteki bilgi kartları ("haritayı indir" önerisi, sorgu kartı).
    private var cards: some View {
        VStack(spacing: fieldMode ? 12 : 8) {
            if !offlinePromptShown, !offline.hasHighPack, offline.isOnline, !offline.isDownloading {
                OfflinePromptBanner(onDownload: {
                    offlinePromptShown = true
                    offline.download()
                }, onDismiss: {
                    withAnimation { offlinePromptShown = true }
                })
            }
            if let c = model.inspectedCoordinate, let a = model.inspected {
                InspectCard(coordinate: c, assessment: a, onAddWaypoint: {
                    waypointDraft = WaypointDraft(coordinate: c)
                }) { model.inspectedCoordinate = nil }
            }
        }
    }

    /// Üst yığının en çok yüksekliği: alttaki kontrollerin üstünde kalan boşluk (ölçülmeden önce sınırsız).
    /// Güvenlik şeridi bundan büyükse yine tam çizilir (üst yığın en üstte).
    private var topLimit: CGFloat {
        guard overlayHeight > 0 else { return .infinity }
        return max(0, overlayHeight - bottomHeight - (fieldMode ? 12 : 8))
    }

    /// Kural listesi (şerit) açıkken alt kontroller ve araç sütunu gizlenir (küçük ekranda taşmasın).
    private var showsControls: Bool { !(expanded && locationAllowed) }

    /// Kartlar, alt satır ve panel sütunun solunda kalsın diye sağdan bırakılan boşluk.
    private var railInset: CGFloat {
        showsControls && railWidth > 0 ? railWidth + (fieldMode ? 12 : 8) : 0
    }

    /// Araç sütununa ayrılan dikey alan (güvenlik şeridinin altı).
    private var railRegion: CGFloat {
        CGFloat(MapOverlayLayout.railRegion(available: Double(overlayHeight), safety: Double(safetyHeight),
                                            spacing: fieldMode ? 12 : 8))
    }

    /// Haritanın alt satırı: solda sınır göstergesi, sağda rüzgâr (tek satır). Katmanlar, konum, −/+, işaret,
    /// iz kaydı ve acil durum sağ kenardaki araç sütunundadır (`MapToolRail`).
    @ViewBuilder private func mapControls() -> some View {
        if let w = model.waypoints.guiding, !showGuidance {
            WaypointGuideChip(waypoint: w) { showGuidance = true }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if model.nearestForbidden != nil || model.insideForbidden || model.currentWeather != nil {
            HStack(alignment: .bottom) {
                if let n = model.nearestForbidden {
                    NearestForbiddenChip(nearest: n, heading: model.heading)
                } else if model.insideForbidden {
                    InsideForbiddenChip()
                }
                Spacer(minLength: 8)
                if let h = model.currentWeather {
                    Button { showScentCone.toggle() } label: {
                        WindBadge(hour: h, showCone: showScentCone)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rüzgâr ve koku konisi")
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                }
            }
        }
    }

    /// Küçük ekranda kart açıkken yer yetmezse alt panel geçici olarak çekilir (kart kapanınca geri gelir).
    private var hidesPanel: Bool {
        MapOverlayLayout.hidesPanel(available: Double(overlayHeight), safety: Double(safetyHeight),
                                    cards: hasCards ? Double(cardsHeight) : 0, controls: Double(controlsBlockHeight),
                                    panel: Double(panelHeight), spacing: fieldMode ? 12 : 8)
    }

    /// Yönlendirmeyi başlat: açık sayfayı kapat, kapanınca tam ekran pusulayı aç.
    private func guide(_ id: UUID) {
        model.waypoints.guidingID = id
        UsageStats.record(.isaretYonlendirme)
        pendingGuidance = true
        selectedWaypoint = nil
        showWaypoints = false
    }

    private func openPendingGuidance() {
        guard pendingGuidance else { return }
        pendingGuidance = false
        if model.waypoints.guiding != nil { showGuidance = true }
    }

    private var scentCone: [CLLocationCoordinate2D]? {
        guard showScentCone, let h = model.currentWeather, let c = model.location?.coordinate, h.windSpeed >= 1 else { return nil }
        return ScentCone.polygon(from: c, windFrom: h.windFrom, windSpeed: h.windSpeed)
    }

    private var locationAllowed: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(model.authorization)
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
    @Environment(\.fieldMode) private var fieldMode
    @Environment(\.nightRed) private var nightRed
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 26

    /// WCAG ≥ 4.5:1 düz renkler (cam/saydam değil); bkz. `BannerPalette`, ContrastTests.
    private var palette: BannerPalette { .of(assessment.level, night: nightRed) }

    var body: some View {
        VStack(alignment: .leading, spacing: fieldMode ? 12 : 8) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: fieldMode ? 16 : 12) {
                    Image(systemName: assessment.level.icon)
                        .font(.system(size: min(iconSize, 44) * (fieldMode ? 1.35 : 1), weight: .bold))
                        // Durum değişince simge zıplar (yasak alana girişte dikkat çeker)
                        .symbolEffect(.bounce, value: assessment.level)
                    VStack(alignment: .leading, spacing: fieldMode ? 6 : 4) {
                        Text(assessment.title).font(fieldMode ? .title2.bold() : .headline).multilineTextAlignment(.leading)
                        Text(assessment.detail).font(fieldMode ? .body.weight(.medium) : .subheadline).multilineTextAlignment(.leading)
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
                        ChecksList(checks: assessment.checks, onColored: true)
                        if let u = assessment.unitName {
                            Text(L("Avlak (yaklaşık, 2024-25 sınırları): %@", u)).font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(palette.foreground.color)
        .padding(.horizontal, fieldMode ? 18 : 14).padding(.vertical, fieldMode ? 14 : 10)
        .background(palette.background.color, in: RoundedRectangle(cornerRadius: 16))
        // Gece: yasak alan kalın, parlak kenarla da ayırt edilir (yalnızca renge dayanmaz; simge + metin de var)
        .overlay {
            if nightRed && assessment.level == .danger {
                RoundedRectangle(cornerRadius: 16).strokeBorder(FieldTheme.nightAccent, lineWidth: 3)
            }
        }
        .shadow(radius: 4)
        // Dynamic Type'a uyar ama haritayı tamamen kapatmasın
        .dynamicTypeSize(...(fieldMode ? DynamicTypeSize.xxxLarge : DynamicTypeSize.accessibility2))
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
                        // Renkli şeritte şeridin yazı rengini (kontrastı denetlenmiş) kullanır
                        .foregroundStyle(onColored ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(c.level.color))
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

struct WaypointRef: Identifiable {
    let id: UUID
}

struct InspectCard: View {
    let coordinate: CLLocationCoordinate2D
    let assessment: Assessment
    var onAddWaypoint: (() -> Void)? = nil
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
                if let onAddWaypoint {
                    Button(action: onAddWaypoint) { Image(systemName: "mappin.and.ellipse") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("İşaret koy")
                }
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
