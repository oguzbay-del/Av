import CoreLocation
import SwiftUI
import UIKit

extension Waypoint.Kind {
    var uiColor: UIColor {
        switch self {
        case .arac: return .systemBlue
        case .pusu: return .systemGreen
        case .avDustu: return .systemPurple
        case .su: return .systemCyan
        case .not: return .systemIndigo
        }
    }
    var color: Color { Color(uiColor: uiColor) }
}

/// Yeni işaret taslağı (koordinat nil: bulunduğunuz konum, canlı).
struct WaypointDraft: Identifiable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D?
}

// MARK: - İşaret koy

struct AddWaypointSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: WaypointDraft
    @State private var kind: Waypoint.Kind = .pusu
    @State private var name = ""
    @State private var note = ""

    private var store: WaypointStore { model.waypoints }
    private var coordinate: CLLocationCoordinate2D? { draft.coordinate ?? model.location?.coordinate }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(Waypoint.Kind.allCases) { k in
                            Button { kind = k } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: k.symbol).font(.title3)
                                        .foregroundStyle(kind == k ? .white : k.color)
                                        .frame(width: 44, height: 44)
                                        .background(kind == k ? k.color : k.color.opacity(0.15), in: Circle())
                                    Text(k.title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(kind == k ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Tür")
                }
                Section {
                    TextField(store.defaultName(for: kind), text: $name)
                    TextField("Not (isteğe bağlı)", text: $note, axis: .vertical)
                }
                Section {
                    if let c = coordinate {
                        Label(draft.coordinate == nil ? L("Bulunduğunuz konum") : L("Haritada seçilen nokta"),
                              systemImage: draft.coordinate == nil ? "location.fill" : "mappin.and.ellipse")
                        Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("Konum alınamıyor. Haritada bir noktaya uzun basarak da işaret koyabilirsiniz.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if store.isFull {
                        Text(L("En fazla %@ işaret saklanabilir; eskilerden silin.", String(WaypointStore.maxCount)))
                            .foregroundStyle(.red)
                    } else {
                        Text("İşaretler yalnızca bu telefonda saklanır.")
                    }
                }
            }
            .navigationTitle("İşaret koy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        guard let c = coordinate else { return }
                        if store.add(kind: kind, name: name, coordinate: c, note: note) != nil {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            dismiss()
                        }
                    }
                    .disabled(coordinate == nil || store.isFull)
                }
            }
        }
    }
}

// MARK: - İşaret ayrıntısı (haritada dokununca)

struct WaypointDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    var onGuide: (UUID) -> Void
    @State private var name = ""
    @State private var note = ""
    @State private var confirmDelete = false

    private var store: WaypointStore { model.waypoints }
    private var waypoint: Waypoint? { store.items.first { $0.id == id } }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLocale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            if let w = waypoint {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: w.kind.symbol).font(.title2).foregroundStyle(.white)
                                .frame(width: 48, height: 48).background(w.kind.color, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Ad", text: $name).font(.headline)
                                    .onSubmit { store.rename(id, to: name) }
                                Text(w.kind.title + " · " + Self.fmt.string(from: w.date))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let l = model.location {
                            let d = w.distance(from: l)
                            let b = WaypointMath.bearing(from: l.coordinate, to: w.coordinate)
                            LabeledContent("Uzaklık", value: Geo.formatDistance(d) + " · " + WaypointMath.formatETA(meters: d))
                            LabeledContent("Yön", value: "\(WaypointMath.directionName(b)) (\(Int(b.rounded()))°)")
                        }
                        Text(String(format: "%.5f, %.5f", w.lat, w.lon))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Section {
                        TextField("Not (isteğe bağlı)", text: $note, axis: .vertical)
                            .onSubmit { store.setNote(id, note) }
                    }
                    Section {
                        Button { commit(); onGuide(id) } label: {
                            Label("Yönlendir", systemImage: "location.north.line.fill").font(.headline)
                        }
                        Button {
                            commit()
                            model.focus = MapFocus(coordinate: w.coordinate, span: 1_500)
                            dismiss()
                        } label: { Label("Haritada göster", systemImage: "map") }
                        ShareLink(item: store.gpxFile([w])) { Label("GPX olarak paylaş", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Sil", systemImage: "trash") }
                    }
                }
                .navigationTitle(w.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Kapat") { commit(); dismiss() } }
                .confirmationDialog(L("İşaret silinsin mi?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Sil", role: .destructive) { store.delete(id); dismiss() }
                }
                .onAppear { name = w.name; note = w.note ?? "" }
                .onDisappear { commit() }
            }
        }
    }

    private func commit() {
        guard waypoint != nil else { return }
        store.rename(id, to: name)
        store.setNote(id, note)
    }
}

// MARK: - İşaretlerim (liste)

struct WaypointListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onGuide: (UUID) -> Void
    var onSelect: (UUID) -> Void

    private var store: WaypointStore { model.waypoints }

    var body: some View {
        NavigationStack {
            let list = store.sorted(from: model.location)
            List {
                if list.isEmpty {
                    Text("Henüz işaret yok. Alt paneldeki “İşaret koy” ya da haritada uzun basarak ekleyin.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { w in
                    HStack(spacing: 12) {
                        Image(systemName: w.kind.symbol).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(w.kind.color, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.name).lineLimit(1)
                            if let l = model.location {
                                let b = WaypointMath.bearing(from: l.coordinate, to: w.coordinate)
                                Text(WaypointMath.directionName(b) + " · " + Geo.formatDistance(w.distance(from: l)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            } else {
                                Text(w.kind.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { onGuide(w.id) } label: { Image(systemName: "location.north.line.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Yönlendir")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(w.id) }
                }
                .onDelete { idx in idx.map { list[$0].id }.forEach { store.delete($0) } }
            }
            .navigationTitle("İşaretlerim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
                if !store.items.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: store.gpxFile(list)) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("GPX olarak paylaş")
                    }
                }
            }
        }
    }
}

// MARK: - Yönlendir (tam ekran, internetsiz pusula)

struct WaypointGuidanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var arrived = false

    private var store: WaypointStore { model.waypoints }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if let w = store.guiding {
                content(w)
            } else {
                Text("İşaret bulunamadı").foregroundStyle(.secondary)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.title3.bold()).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Haritaya dön")
                    Spacer()
                    Button(role: .destructive) {
                        store.guidingID = nil
                        dismiss()
                    } label: { Text("Bitir").bold() }
                    .buttonStyle(.bordered)
                }
                .padding()
                Spacer()
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = model.keepScreenOn }
        .onChange(of: distance) { _, d in
            guard let d else { return }
            if d <= WaypointMath.arrivalRadius, !arrived {
                arrived = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if d > WaypointMath.arrivalRadius * 2 {
                arrived = false
            }
        }
    }

    private var distance: Double? {
        guard let w = store.guiding, let l = model.location else { return nil }
        return w.distance(from: l)
    }

    @ViewBuilder
    private func content(_ w: Waypoint) -> some View {
        VStack(spacing: 20) {
            Label(w.name, systemImage: w.kind.symbol)
                .font(.title2.bold()).foregroundStyle(w.kind.color)
                .lineLimit(1).padding(.horizontal, 60)
            if let l = model.location {
                let d = w.distance(from: l)
                let b = WaypointMath.bearing(from: l.coordinate, to: w.coordinate)
                let angle = model.heading.map { WaypointMath.relativeAngle(bearing: b, heading: $0) } ?? b
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                    Image(systemName: arrived ? "checkmark.circle.fill" : "location.north.fill")
                        .resizable().scaledToFit()
                        .frame(width: 140, height: 140)
                        .foregroundStyle(arrived ? .green : w.kind.color)
                        .rotationEffect(.degrees(arrived ? 0 : angle))
                        .animation(.easeOut(duration: 0.25), value: angle)
                }
                .frame(width: 240, height: 240)
                .accessibilityHidden(true)
                if arrived {
                    Text("Hedefe vardınız").font(.largeTitle.bold()).foregroundStyle(.green)
                } else {
                    Text(Geo.formatDistance(d))
                        .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.5).lineLimit(1)
                }
                Text(WaypointMath.directionName(b) + " · " + Geo.formatDistance(d))
                    .font(.title3)
                Text(L("Yürüyerek %@ (4 km/sa)", WaypointMath.formatETA(meters: d)))
                    .foregroundStyle(.secondary)
                if model.heading == nil {
                    Text("Pusula yok: ok kuzeye göre gösteriliyor (telefonun üstü kuzeye baksın).")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if l.horizontalAccuracy > 30 {
                    Text(L("Konum doğruluğu ±%@ m", String(Int(l.horizontalAccuracy))))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                Text("Konum bekleniyor…").foregroundStyle(.secondary)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

/// Haritada yönlendirme sürerken küçük çip (dokun: tam ekran; ×: bitir).
struct WaypointGuideChip: View {
    @Environment(AppModel.self) private var model
    let waypoint: Waypoint
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if let l = model.location {
                        let b = WaypointMath.bearing(from: l.coordinate, to: waypoint.coordinate)
                        Image(systemName: model.heading == nil ? "location.north.fill" : "arrow.up")
                            .font(.caption.bold())
                            .rotationEffect(.degrees(model.heading.map { WaypointMath.relativeAngle(bearing: b, heading: $0) } ?? b))
                            .foregroundStyle(waypoint.kind.color)
                        Text(waypoint.name + " · " + Geo.formatDistance(waypoint.distance(from: l)))
                    } else {
                        Image(systemName: waypoint.kind.symbol).foregroundStyle(waypoint.kind.color)
                        Text(waypoint.name)
                    }
                }
                .font(.caption.bold().monospacedDigit())
                .lineLimit(1)
            }
            .accessibilityLabel(L("Yönlendirme: %@", waypoint.name))
            Button { model.waypoints.guidingID = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Yönlendirmeyi bitir")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .glassCapsule()
    }
}
