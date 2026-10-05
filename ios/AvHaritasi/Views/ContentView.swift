import CoreLocation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.8
    @AppStorage("baseStyle") private var baseStyleRaw = BaseMapStyle.hybrid.rawValue
    @AppStorage("acceptedDisclaimer") private var acceptedDisclaimer = false
    @State private var followUser = true
    @State private var showLegend = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if let map = model.map {
                mapScreen(map)
            } else {
                ContentUnavailableView("Harita yüklenemedi", systemImage: "map",
                                       description: Text(model.loadError ?? ""))
            }
        }
        .onAppear { model.start() }
        .fullScreenCover(isPresented: Binding(get: { !acceptedDisclaimer }, set: { acceptedDisclaimer = !$0 })) {
            DisclaimerView(season: model.map?.meta.season ?? "") { acceptedDisclaimer = true }
        }
    }

    private func mapScreen(_ map: HuntingMap) -> some View {
        ZStack {
            HuntingMapView(map: map,
                           followUser: $followUser,
                           inspectedCoordinate: $model.inspectedCoordinate,
                           overlayOpacity: overlayOpacity,
                           baseStyle: BaseMapStyle(rawValue: baseStyleRaw) ?? .hybrid)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                if !locationAllowed {
                    PermissionBanner()
                } else {
                    StatusBanner(assessment: model.assessment, location: model.location)
                }
                if let c = model.inspectedCoordinate {
                    InspectCard(coordinate: c, zone: model.inspectedZone) { model.inspectedCoordinate = nil }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Text("\(map.meta.title) \(map.meta.season)\nHaritaya uzun basarak bir noktayı sorgulayın")
                        .font(.caption2)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    VStack(spacing: 10) {
                        RoundButton(systemImage: "list.bullet.rectangle") { showLegend = true }
                        RoundButton(systemImage: "gearshape") { showSettings = true }
                        RoundButton(systemImage: followUser ? "location.fill" : "location") { followUser = true }
                    }
                }
            }
            .padding()
        }
        .sheet(isPresented: $showLegend) {
            LegendView(classes: map.allClasses, source: map.meta.source, season: map.meta.season)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(overlayOpacity: $overlayOpacity, baseStyleRaw: $baseStyleRaw)
                .environmentObject(model)
                .presentationDetents([.medium, .large])
        }
    }

    private var locationAllowed: Bool {
        model.authorization == .authorizedWhenInUse || model.authorization == .authorizedAlways
            || model.authorization == .notDetermined
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

struct StatusBanner: View {
    let assessment: Assessment
    let location: CLLocation?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .bold))
            VStack(alignment: .leading, spacing: 4) {
                Text(assessment.title).font(.headline)
                Text(assessment.detail).font(.subheadline)
                if let l = location {
                    Text(String(format: "%.5f, %.5f  ·  GPS ±%.0f m",
                                l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy))
                        .font(.caption.monospacedDigit())
                        .opacity(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding()
        .background(background, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 4)
        .animation(.easeInOut, value: assessment.level)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch assessment.level {
        case .danger: return "xmark.octagon.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .safe: return "checkmark.shield.fill"
        case .unknown: return "location.slash"
        }
    }

    private var background: Color {
        switch assessment.level {
        case .danger: return .red
        case .caution: return .orange
        case .safe: return .green
        case .unknown: return Color(.secondarySystemBackground)
        }
    }

    private var foreground: Color {
        assessment.level == .unknown ? .primary : .white
    }
}

struct InspectCard: View {
    let coordinate: CLLocationCoordinate2D
    let zone: ZoneClass?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: zone?.color ?? "#FFFFFF"))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text("Seçilen nokta: \(zone?.name ?? "Harita dışı")").font(.subheadline.bold())
                if let zone { Text(zone.status.label).font(.caption) }
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
        case .yasak: return "Avlanmak yasak"
        case .dikkat: return "Özel izin / ek kural gerekebilir"
        case .izinli: return "Belge, izin kartı ve MAK kararına uyarak avlanılabilir"
        case .disarida: return "Avlak olarak işaretli değil"
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
