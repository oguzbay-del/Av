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
                        }
                    }

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
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var online: [MKMapItem] = []
    @State private var searchTask: Task<Void, Never>?

    private struct Hit: Identifiable {
        let id = UUID()
        let name: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
    }

    /// Haritadaki köy/ilçe/mesire noktaları (internetsiz).
    private var offline: [Hit] {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
        guard q.count >= 2, let places = model.features?.places else { return [] }
        return places.compactMap { p -> Hit? in
            guard let n = p.name else { return nil }
            let key = n.replacingOccurrences(of: " ", with: "")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            guard key.contains(q.replacingOccurrences(of: " ", with: "")) else { return nil }
            return Hit(name: n, subtitle: p.title, coordinate: p.coordinate)
        }
        .prefix(15).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                let local = offline
                if !local.isEmpty {
                    Section("Haritadaki yerler") {
                        ForEach(local) { h in row(h.name, h.subtitle, h.coordinate) }
                    }
                }
                if !online.isEmpty {
                    Section("Apple Haritalar") {
                        ForEach(online, id: \.self) { item in
                            row(item.name ?? "Yer", item.placemark.title ?? "", item.placemark.coordinate)
                        }
                    }
                }
                if query.count >= 2 && local.isEmpty && online.isEmpty {
                    Text("Sonuç yok").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Köy, ilçe, orman, baraj…")
            .onChange(of: query) { _, q in search(q) }
            .navigationTitle("Yer ara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { dismiss() } }
        }
    }

    private func row(_ name: String, _ subtitle: String, _ c: CLLocationCoordinate2D) -> some View {
        Button {
            model.focus = MapFocus(coordinate: c)
            model.inspectedCoordinate = c
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.red)
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

    private func search(_ q: String) {
        searchTask?.cancel()
        guard q.count >= 3, let map = model.map else { online = []; return }
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
