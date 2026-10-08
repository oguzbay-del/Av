import CoreLocation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("acceptedDisclaimer_2026") private var acceptedDisclaimer = false
    @AppStorage("selectedTab") private var selectedTab = "harita"

    var body: some View {
        Group {
            if model.map != nil {
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
                        .tabItem { Label("Kuş Sesi", systemImage: "waveform") }
                        .tag("kus")
                }
            } else {
                ContentUnavailableView("Harita yüklenemedi", systemImage: "map",
                                       description: Text(model.loadError ?? ""))
            }
        }
        .onAppear { model.start() }
        .fullScreenCover(isPresented: Binding(get: { !acceptedDisclaimer }, set: { acceptedDisclaimer = !$0 })) {
            DisclaimerView(mapSeason: model.map?.meta.season ?? "", rulesTitle: model.regs?.title ?? "") {
                acceptedDisclaimer = true
            }
        }
    }
}

struct MapScreen: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.8
    @AppStorage("baseLayer") private var baseLayerRaw = BaseLayer.appleHybrid.rawValue
    @AppStorage("showBuffers") private var showBuffers = false
    @AppStorage("showScentCone") private var showScentCone = false
    @AppStorage("showZones") private var showZones = true
    @AppStorage("showOfficial") private var showOfficial = false
    @AppStorage("rotateWithHeading") private var rotateWithHeading = false
    @State private var showLayers = false
    @State private var showSearch = false
    @State private var followUser = true
    @State private var showLegend = false
    @State private var showSettings = false
    @AppStorage("bannerExpanded") private var expanded = false

    private var baseLayer: BaseLayer { BaseLayer(rawValue: baseLayerRaw) ?? .appleHybrid }

    var body: some View {
        if let map = model.map {
            ZStack {
                HuntingMapView(map: map, features: model.features, regs: model.regs,
                               followUser: $followUser,
                               inspectedCoordinate: $model.inspectedCoordinate,
                               overlayOpacity: overlayOpacity,
                               baseLayer: baseLayer,
                               showBuffers: showBuffers,
                               scentCone: scentCone,
                               zoneShapes: model.zoneShapes,
                               showZones: showZones,
                               showOfficial: showOfficial || model.zoneShapes.isEmpty,
                               focus: model.focus,
                               heading: rotateWithHeading ? model.heading : nil)
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 8) {
                    if !locationAllowed {
                        PermissionBanner()
                    } else {
                        StatusBanner(assessment: model.assessment, location: model.location, expanded: $expanded,
                                     stationary: model.isStationary)
                        if model.reducedAccuracy {
                            Button { model.requestFullAccuracy() } label: {
                                Label("Kesin konumu aç", systemImage: "location.fill.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                    if let c = model.inspectedCoordinate, let a = model.inspected {
                        InspectCard(coordinate: c, assessment: a) { model.inspectedCoordinate = nil }
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let n = model.nearestForbidden {
                                NearestForbiddenChip(nearest: n, heading: model.heading)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(LD(map.meta.title)) \(map.meta.season) · MAK 2026-27")
                                Text("Uzun basın: o noktayı sorgula")
                                if let a = baseLayer.attribution { Text(a) }
                            }
                            .font(.caption2)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 10) {
                            if let h = model.currentWeather {
                                Button { showScentCone.toggle() } label: {
                                    WindBadge(hour: h, showCone: showScentCone)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Rüzgâr ve koku konisi")
                            }
                            RoundButton(systemImage: "magnifyingglass") { showSearch = true }
                                .accessibilityLabel("Yer ara")
                            RoundButton(systemImage: "square.3.layers.3d") { showLayers = true }
                                .accessibilityLabel("Katmanlar")
                            RoundButton(systemImage: "list.bullet.rectangle") { showLegend = true }
                                .accessibilityLabel("Lejant")
                            RoundButton(systemImage: "gearshape") { showSettings = true }
                            RoundButton(systemImage: followUser ? "location.fill" : "location") { followUser = true }
                        }
                    }
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 30)   // Apple "Yasal" etiketinin üstünde kalsın
            }
            .sheet(isPresented: $showLayers) {
                LayersSheet(baseLayerRaw: $baseLayerRaw, showZones: $showZones, showOfficial: $showOfficial,
                            overlayOpacity: $overlayOpacity, showBuffers: $showBuffers, showScentCone: $showScentCone,
                            hasWeather: model.currentWeather != nil)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSearch) {
                PlaceSearchView().environmentObject(model)
            }
            .sheet(isPresented: $showLegend) {
                LegendView(classes: map.allClasses, source: map.meta.source, season: map.meta.season)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(overlayOpacity: $overlayOpacity, baseLayerRaw: $baseLayerRaw, showBuffers: $showBuffers)
                    .environmentObject(model)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var scentCone: [CLLocationCoordinate2D]? {
        guard showScentCone, let h = model.currentWeather, let c = model.location?.coordinate, h.windSpeed >= 1 else { return nil }
        return ScentCone.polygon(from: c, windFrom: h.windFrom, windSpeed: h.windSpeed)
    }

    private var locationAllowed: Bool {
        [.authorizedWhenInUse, .authorizedAlways, .notDetermined].contains(model.authorization)
    }
}

struct RoundButton: View {
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assessment.title).font(.headline).multilineTextAlignment(.leading)
                        Text(assessment.detail).font(.subheadline).multilineTextAlignment(.leading)
                            .lineLimit(expanded ? nil : 2)
                        if expanded, let l = location {
                            Text(String(format: "%.5f, %.5f  ·  GPS ±%.0f m", l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy)
                                 + (l.verticalAccuracy > 0 ? String(format: "  ·  rakım %.0f m", l.altitude) : "")
                                 + (stationary ? "  ·  pusu: pil tasarrufu" : ""))
                                .font(.caption.monospacedDigit())
                                .opacity(0.85)
                        }
                    }
                    Spacer(minLength: 0)
                    if !assessment.checks.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.bold())
                    }
                }
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
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(assessment.level == .unknown ? Color.primary : Color.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(assessment.level == .unknown ? Color(.secondarySystemBackground) : assessment.level.color,
                    in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 4)
        .animation(.easeInOut, value: assessment.level)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PermissionBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Konum izni gerekli", systemImage: "location.slash").font(.headline)
            Text("Bulunduğunuz alanı gösterebilmek için Ayarlar'dan konum iznini açın.").font(.subheadline)
            Button("Ayarları aç") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
