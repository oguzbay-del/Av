import MapKit
import SwiftUI

// MARK: - Katmanlar paneli (Google Haritalar "Harita türü" benzeri)

struct LayersSheet: View {
    @Binding var baseLayerRaw: String
    @Binding var showZones: Bool
    @Binding var showOfficial: Bool
    @Binding var overlayOpacity: Double
    @Binding var showBuffers: Bool
    @Binding var showScentCone: Bool
    let hasWeather: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Harita türü").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        ForEach(BaseLayer.allCases) { layer in
                            let selected = layer.rawValue == baseLayerRaw
                            Button { baseLayerRaw = layer.rawValue } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: layer.icon)
                                        .font(.title2)
                                        .frame(maxWidth: .infinity, minHeight: 56)
                                        .background(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                                                    in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12)
                                            .stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                                    Text(layer.shortTitle).font(.caption)
                                        .foregroundStyle(selected ? Color.accentColor : .primary)
                                }
                            }
                            .buttonStyle(.plain)
                            // Çevrimdışı paket yoksa seçilemez (boş harita görünmesin)
                            .disabled(layer == .offlineTopo && !OfflineMapStore.shared.hasAnyPack)
                            .opacity(layer == .offlineTopo && !OfflineMapStore.shared.hasAnyPack ? 0.4 : 1)
                        }
                    }

                    Text("Çevrimdışı harita").font(.headline)
                    OfflineMapPanel()
                        .padding()
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    Text("Katmanlar").font(.headline)
                    VStack(spacing: 0) {
                        LayerToggle(title: L("Avlak bölgeleri"), subtitle: L("Keskin, yarı saydam alanlar; yer adları üstte okunur"),
                                    systemImage: "square.on.square.squareshape.controlhandles", isOn: $showZones)
                        Divider().padding(.leading, 52)
                        LayerToggle(title: L("Resmi harita (taranmış)"), subtitle: L("Bakanlığın basılı haritası; yakında pikselleşir"),
                                    systemImage: "doc.richtext", isOn: $showOfficial)
                        if showOfficial {
                            HStack {
                                Text("Opaklık").font(.caption)
                                Slider(value: $overlayOpacity, in: 0.2...1)
                            }
                            .padding(.leading, 52).padding(.trailing).padding(.bottom, 8)
                        }
                        Divider().padding(.leading, 52)
                        LayerToggle(title: L("300 m yasak bantları"), subtitle: L("Karayolları, köy ve ilçe merkezleri, mesire yerleri"),
                                    systemImage: "circle.dashed.inset.filled", isOn: $showBuffers)
                        Divider().padding(.leading, 52)
                        LayerToggle(title: L("Koku konisi"), subtitle: hasWeather ? L("Rüzgâr altında kokunuzun taşındığı alan") : L("Hava durumu alınınca kullanılabilir"),
                                    systemImage: "wind", isOn: $showScentCone)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Katmanlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Bitti") { dismiss() } }
        }
        .cellularDownloadConfirmation()
    }
}

private struct LayerToggle: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 28).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

// MARK: - Yer arama

struct PlaceSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var online: [MKMapItem] = []
    @State private var searchTask: Task<Void, Never>?

    private var isOnline: Bool { OfflineMapStore.shared.isOnline }

    var body: some View {
        NavigationStack {
            List {
                // Uygulamadaki yerler her zaman önce (internetsiz de çalışır)
                let local = model.placeIndex.search(query)
                if !local.isEmpty {
                    Section("Haritadaki yerler") {
                        ForEach(local) { h in row(h.name, h.subtitle, h.coordinate, rect: h.rect) }
                    }
                }
                let extra = isOnline ? online.filter { item in
                    !model.placeIndex.isDuplicate(name: item.name ?? "", at: item.placemark.coordinate, of: local)
                } : []
                if !extra.isEmpty {
                    Section("Apple Haritalar") {
                        ForEach(extra, id: \.self) { item in
                            row(item.name ?? L("Yer"), item.placemark.title ?? "", item.placemark.coordinate)
                        }
                    }
                }
                if query.count >= 2 && local.isEmpty && extra.isEmpty {
                    Text("Sonuç yok").foregroundStyle(.secondary)
                }
                if !isOnline {
                    Label("Çevrimdışı: yalnızca uygulamadaki köy, ilçe, mesire yeri ve avlak adları aranıyor.", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Köy, ilçe, avlak, orman, baraj…")
            .onChange(of: query) { _, q in search(q) }
            .navigationTitle("Yer ara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { dismiss() } }
        }
    }

    private func row(_ name: String, _ subtitle: String, _ c: CLLocationCoordinate2D, rect: MKMapRect? = nil) -> some View {
        Button {
            model.focus = MapFocus(coordinate: c, rect: rect)
            model.inspectedCoordinate = c
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: rect == nil ? "mappin.circle.fill" : "scope").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text(name).foregroundStyle(.primary)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let zone = model.map?.zone(at: c) {
                    Text(LD(zone.name)).font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(uiColor: zone.displayColor).opacity(0.2), in: Capsule())
                }
            }
        }
    }

    /// Apple Haritalar araması yalnızca internet varken (çevrimdışıyken zaman aşımı beklenmez).
    private func search(_ q: String) {
        searchTask?.cancel()
        guard q.count >= 3, isOnline, let map = model.map else { online = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            let b = map.meta.bounds
            req.region = MKCoordinateRegion(center: map.center,
                                            span: MKCoordinateSpan(latitudeDelta: b.north - b.south, longitudeDelta: b.east - b.west))
            if #available(iOS 18.0, *) { req.regionPriority = .required }
            let items = ((try? await MKLocalSearch(request: req).start())?.mapItems ?? []).filter {
                let c = $0.placemark.coordinate
                return (b.south...b.north).contains(c.latitude) && (b.west...b.east).contains(c.longitude)
            }
            if !Task.isCancelled { online = Array(items.prefix(10)) }
        }
    }
}

// MARK: - En yakın yasak alan göstergesi

struct NearestForbiddenChip: View {
    let nearest: NearbyRestriction
    /// Pusula yönü; varsa ok telefonun baktığı yöne göre döner ("şu tarafta").
    var heading: Double?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: heading == nil ? "location.north.fill" : "arrow.up")
                .font(.caption.bold())
                .rotationEffect(.degrees(nearest.bearing - (heading ?? 0)))
                .animation(.easeOut(duration: 0.3), value: heading)
                .foregroundStyle(.red)
            Text(L("Yasak alan %@ · %@", distance, heading.map { relative($0) } ?? Compass.name(nearest.bearing)))
                .font(.caption.bold().monospacedDigit())
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .glassCapsule()
        .overlay(Capsule().stroke(Color.red.opacity(nearest.distance < 300 ? 0.8 : 0.0), lineWidth: 1.5))
        .accessibilityLabel(L("En yakın ava yasak alan %@, %@ yönünde", distance, Compass.name(nearest.bearing)))
    }

    /// Telefonun baktığı yöne göre: önünüzde, sağınızda, arkanızda, solunuzda.
    private func relative(_ h: Double) -> String {
        let r = ((nearest.bearing - h).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch r {
        case ..<30, 330...: return L("önünüzde")
        case 30..<150: return L("sağınızda")
        case 150..<210: return L("arkanızda")
        default: return L("solunuzda")
        }
    }

    private var distance: String {
        nearest.distance >= 1000 ? String(format: "%.1f km", nearest.distance / 1000) : "\(Int((nearest.distance / 10).rounded() * 10)) m"
    }
}

// MARK: - Sistem durumu satırı (uyarıların çalıştığını tek bakışta gösterir; hiçbir arıza sessiz kalmasın)

struct SystemStatusRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("baseLayer") private var baseLayerRaw = BaseLayer.appleHybrid.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if model.demoActive {
                        Button { model.stopDemo() } label: {
                            chip(L("Demo konumu · kapat"), icon: "play.circle.fill", tint: .purple)
                        }
                        .buttonStyle(.plain)
                    }
                    let offline = OfflineMapStore.shared
                    if !offline.isOnline {
                        let chosen = BaseLayer(rawValue: baseLayerRaw) ?? .appleHybrid
                        let auto = chosen.isOnline && offline.hasAnyPack
                        chip(auto ? L("Çevrimdışı · topo harita") : L("Çevrimdışı"), icon: "wifi.slash", tint: nil)
                    }
                    if offline.isDownloading {
                        chip(L("Harita indiriliyor %%%@", String(Int(offline.progress * 100))), icon: "arrow.down.circle", tint: nil)
                    }
                    if let l = model.location {
                        let age = max(0, ctx.date.timeIntervalSince(l.timestamp))
                        let stale = age > AppModel.staleAfter
                        let bad = age > 15 || l.horizontalAccuracy > 50
                        chip(L("GPS ±%@ m · %@", String(Int(l.horizontalAccuracy)), ageText(age)),
                             icon: bad ? "location.slash" : "location.fill", tint: stale ? .red : (bad ? .orange : nil))
                    }
                    if let e = model.locationError {
                        chip(e, icon: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if model.notificationsAllowed == false, model.backgroundTracking || model.geofenceAlerts {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            chip(L("Bildirimler kapalı"), icon: "bell.slash.fill", tint: .red)
                        }
                        .buttonStyle(.plain)
                    }
                    if let t = model.tracks.current {
                        chip(L("İz kaydediliyor · %@", Geo.formatDistance(t.distance)), icon: "record.circle", tint: .red)
                    }
                    if model.backgroundTracking {
                        chip(L("Arka plan takibi"), icon: "dot.radiowaves.left.and.right", tint: nil)
                    }
                    if let r = model.geofenceRadius {
                        chip(L("Kapalıyken uyarı · %@", Geo.formatDistance(r)), icon: "circle.dashed", tint: nil)
                    }
                    if model.isStationary {
                        chip(L("Pusu: pil tasarrufu"), icon: "leaf.fill", tint: nil)
                    } else if model.lowPowerTier {
                        chip(L("Yasak alanlardan uzak: pil tasarrufu"), icon: "leaf", tint: nil)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func ageText(_ s: TimeInterval) -> String {
        s < 60 ? L("%@ sn önce", String(Int(s))) : L("%@ dk önce", String(Int(s / 60)))
    }

    private func chip(_ text: String, icon: String, tint: Color?) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.bold())
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .glassCapsule()
            .overlay(Capsule().stroke(tint ?? .clear, lineWidth: 1))
    }
}

// MARK: - Alt panel (Apple Haritalar tarzı): arama, avlak/izin, lejant, ayarlar; yukarı çekince kurallar

struct MapBottomPanel: View {
    @Environment(AppModel.self) private var model
    let map: HuntingMap
    let attribution: String?
    @Binding var showSearch: Bool
    @Binding var showPermits: Bool
    @Binding var showLegend: Bool
    @Binding var showSettings: Bool
    @AppStorage("panelExpanded") private var expanded = false
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tutamaç: sürükle ya da dokun
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                .accessibilityLabel(expanded ? L("Paneli küçült") : L("Paneli büyüt"))
                .accessibilityAddTraits(.isButton)

            if let h = model.highlighted {
                AvlakCard(avlak: h.avlak, area: h.area)
                Divider()
            }

            Button { showSearch = true } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Yer ara").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                quick(model.highlightedAvlak == nil ? "scope" : "checkmark.seal.fill", L("Avlak ve izin")) { showPermits = true }
                quick("list.bullet.rectangle", L("Lejant")) { showLegend = true }
                quick("gearshape", L("Ayarlar")) { showSettings = true }
            }

            if expanded {
                SafetyTools(tracks: model.tracks)
                Divider()
                Text("Bulunduğunuz yerdeki kurallar").font(.subheadline.bold())
                ScrollView {
                    ChecksList(checks: model.assessment.checks)
                }
                .frame(maxHeight: 220)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(LD(map.meta.title)) \(map.meta.season) · MAK 2026-27 · ") + Text("Uzun basın: o noktayı sorgula")
                if let attribution { Text(attribution) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassCard(cornerRadius: 24)
        .offset(y: max(0, drag))
        .gesture(
            DragGesture(minimumDistance: 12)
                .updating($drag) { v, s, _ in s = v.translation.height }
                .onEnded { v in
                    withAnimation(.snappy) {
                        if v.translation.height < -40 { expanded = true }
                        if v.translation.height > 40 { expanded = false }
                    }
                }
        )
    }

    private func quick(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3).symbolRenderingMode(.hierarchical)
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Güvenlik araçları: iz kaydı, konum paylaşma, acil durum

struct SafetyTools: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var tracks: TrackLog
    @State private var showEmergency = false
    @State private var showTracks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            Button {
                if tracks.isRecording { tracks.stop() } else { tracks.start() }
            } label: {
                tool(tracks.isRecording ? "stop.circle.fill" : "record.circle",
                     tracks.isRecording ? L("İzi durdur") : L("İz kaydı"), tint: tracks.isRecording ? .red : nil)
            }
            if let c = model.location?.coordinate {
                ShareLink(item: Self.shareText(c, accuracy: model.location?.horizontalAccuracy ?? 0)) {
                    tool("square.and.arrow.up", L("Konumu paylaş"), tint: nil)
                }
            }
            Button { showEmergency = true } label: { tool("sos", L("Acil durum"), tint: .red) }
        }
        .buttonStyle(.plain)
        if !tracks.saved.isEmpty {
            Button { showTracks = true } label: {
                Label(L("Kayıtlı izler (%@)", String(tracks.saved.count)), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption)
            }
        }
        }
        .sheet(isPresented: $showEmergency) { EmergencyCard().environment(model).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showTracks) { TrackListView(tracks: tracks).presentationDetents([.medium, .large]) }
    }

    static func shareText(_ c: CLLocationCoordinate2D, accuracy: Double) -> String {
        let ll = String(format: "%.6f,%.6f", c.latitude, c.longitude)
        return L("Konumum: %@ (±%@ m) https://maps.apple.com/?ll=%@&q=%@", ll, String(Int(accuracy)), ll, ll)
    }

    private func tool(_ icon: String, _ title: String, tint: Color?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint ?? .primary)
            Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Büyük puntolu konum ve 112 — acil durumda yeri sözlü iletmek için.
struct EmergencyCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let l = model.location {
                    Section {
                        Text(String(format: "%.5f, %.5f", l.coordinate.latitude, l.coordinate.longitude))
                            .font(.title.monospacedDigit().bold())
                            .textSelection(.enabled)
                        Text(Self.dms(l.coordinate)).font(.title3.monospacedDigit())
                        Text(L("Doğruluk ±%@ m", String(Int(l.horizontalAccuracy))) +
                             (l.verticalAccuracy > 0 ? " · " + L("rakım %@ m", String(Int(l.altitude.rounded()))) : ""))
                            .foregroundStyle(.secondary)
                        if let p = model.features?.nearestPlace(kinds: ["koy", "ilce"], to: l.coordinate, within: 10_000) {
                            Text(L("En yakın yerleşim: %@ (%@)", p.place.title, Geo.formatDistance(p.distance)))
                        }
                    } header: {
                        Text("Konumunuz")
                    }
                    Section {
                        ShareLink(item: SafetyTools.shareText(l.coordinate, accuracy: l.horizontalAccuracy)) {
                            Label("Konumu paylaş", systemImage: "square.and.arrow.up")
                        }
                    }
                } else {
                    Text("Konum alınamıyor. Açık alana çıkın ve bekleyin.").foregroundStyle(.secondary)
                }
                Section {
                    Link(destination: URL(string: "tel://112")!) {
                        Label("112'yi ara", systemImage: "phone.fill").font(.headline).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Görevliye koordinatları rakam rakam okuyun. iPhone'da Acil Durum SOS için yan tuş ile ses tuşuna birlikte basılı tutabilirsiniz.")
                }
            }
            .navigationTitle("Acil durum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { dismiss() } }
        }
    }

    static func dms(_ c: CLLocationCoordinate2D) -> String {
        func f(_ v: Double, _ pos: String, _ neg: String) -> String {
            let a = abs(v), d = Int(a), m = Int((a - Double(d)) * 60), s = (a - Double(d) - Double(m) / 60) * 3600
            return String(format: "%d°%02d′%04.1f″%@", d, m, s, v >= 0 ? pos : neg)
        }
        let en = AppLocale.isEnglish
        return f(c.latitude, en ? "N" : "K", en ? "S" : "G") + "  " + f(c.longitude, en ? "E" : "D", en ? "W" : "B")
    }
}

struct TrackListView: View {
    @ObservedObject var tracks: TrackLog
    @Environment(\.dismiss) private var dismiss

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLocale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                ForEach(tracks.saved) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(Self.fmt.string(from: t.started))
                            Text(L("%@ · %@ nokta", Geo.formatDistance(t.distance), String(t.points.count)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: tracks.gpxFile(for: t)) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .onDelete { idx in idx.map { tracks.saved[$0] }.forEach(tracks.delete) }
            }
            .navigationTitle("Kayıtlı izler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { dismiss() } }
        }
    }
}
