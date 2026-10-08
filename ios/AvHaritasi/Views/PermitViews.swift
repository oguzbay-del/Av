import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let dayFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = AppLocale.current
    f.timeZone = TimeZone(identifier: "Europe/Istanbul")
    f.dateFormat = "d MMMM yyyy EEEE"
    return f
}()

// MARK: - İzin belgeleri ve avlak seçimi

struct PermitSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: PermitStore
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var busy = false
    @State private var error: String?
    @State private var draft: DraftBox?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.permits.isEmpty {
                        Text("Henüz izin belgesi yok. AVBİS'ten aldığınız avlanma izin belgesinin ekran görüntüsünü ya da PDF'ini ekleyin.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(store.permits) { p in
                        Button { select(p.avlak) } label: { PermitRow(permit: p, today: model.now) }
                    }
                    .onDelete { idx in idx.map { store.permits[$0] }.forEach(store.delete) }
                } header: {
                    Text("İzin belgelerim")
                }

                Section {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Ekran görüntüsü / fotoğraf ekle", systemImage: "photo.on.rectangle")
                    }
                    Button { showFiles = true } label: {
                        Label("PDF ya da dosya ekle", systemImage: "doc.badge.plus")
                    }
                    if busy {
                        HStack { ProgressView(); Text("Belge okunuyor…").foregroundStyle(.secondary) }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Belge ekle")
                } footer: {
                    Text("Belge telefonda okunur, hiçbir sunucuya gönderilmez. Avlak, tarih, türler ve kotalar saklanır; ad soyad, avcılık belgesi ve izin kartı numarası saklanmaz.")
                }

                Section {
                    ForEach(avlaklar) { a in
                        Button { select(a.name) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LD(a.name)).foregroundStyle(.primary)
                                    if !a.open {
                                        Text("AVA KAPALI").font(.caption.bold()).foregroundStyle(.red)
                                    } else if model.avlakAreas.area(for: a) == nil {
                                        Text("Sınır verisi yok").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model.highlightedAvlak == a.name {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Avlak seç (belgesiz)")
                } footer: {
                    Text("Avlak sınırları 2024-25 haritasındaki avlak birimlerinden alınmıştır ve yaklaşıktır; Sarıyer ve Pirinççi aynı birim olarak gösterilir.")
                }
            }
            .searchable(text: $query, prompt: "Avlak ara")
            .navigationTitle("Avlak ve izin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { dismiss() } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image]) { result in
                if case .success(let url) = result { Task { await importFile(url) } }
            }
            .sheet(item: $draft) { box in
                PermitConfirmView(result: box.result) { p in
                    store.add(p)
                    draft = nil
                    select(p.avlak)
                }
                .environmentObject(model)
            }
        }
    }

    private var avlaklar: [Regulations.Avlak] {
        let all = model.regs?.avlaklar ?? []
        guard !query.isEmpty else { return all }
        let q = PermitParser.normalize(query)
        return all.filter { PermitParser.normalize($0.name).contains(q) || PermitParser.normalize(LD($0.name)).contains(q) }
    }

    private func select(_ name: String) {
        model.showAvlak(name)
        dismiss()
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        busy = true; error = nil
        defer { busy = false; photo = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                error = L("Görüntü açılamadı."); return
            }
            handle(try await PermitImport.extract(image: image))
        } catch {
            self.error = L("Belge okunamadı: %@", error.localizedDescription)
        }
    }

    private func importFile(_ url: URL) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            handle(try await PermitImport.extract(file: url))
        } catch {
            self.error = L("Belge okunamadı: %@", error.localizedDescription)
        }
    }

    private func handle(_ x: PermitImport.Extracted) {
        guard let regs = model.regs else { return }
        let url = x.qrPayload.flatMap { $0.hasPrefix("http") ? $0 : nil }
        let r = PermitParser.parse(x.text, items: x.items, regs: regs, verifyURL: url)
        if r.permit == nil {
            error = r.problems.first
        } else {
            draft = DraftBox(result: r)
        }
    }
}

private struct DraftBox: Identifiable {
    let id = UUID()
    let result: PermitParser.Result
}

struct PermitRow: View {
    let permit: HuntPermit
    let today: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(LD(permit.avlak)).font(.headline).foregroundStyle(.primary)
                Spacer()
                if permit.isValid(on: today) {
                    Text("BUGÜN").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2), in: Capsule()).foregroundStyle(.green)
                } else if permit.date < today {
                    Text("Geçti").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(dayFormat.string(from: permit.date)).font(.caption).foregroundStyle(.secondary)
            if !permit.quotas.isEmpty {
                Text(permit.quotas.map { "\(LD($0.species)) \($0.count)" }.joined(separator: " · ")).font(.caption)
                    .foregroundStyle(.primary)
            }
            if let n = permit.number {
                Text(L("Belge no: %@", n)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Okunan belgeyi kaydetmeden önce gösterir ve düzeltmeye izin verir.
struct PermitConfirmView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let result: PermitParser.Result
    let onSave: (HuntPermit) -> Void
    @State private var permit: HuntPermit

    init(result: PermitParser.Result, onSave: @escaping (HuntPermit) -> Void) {
        self.result = result
        self.onSave = onSave
        _permit = State(initialValue: result.permit!)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Avlak", selection: $permit.avlak) {
                        ForEach(model.regs?.avlaklar ?? []) { Text(LD($0.name)).tag($0.name) }
                    }
                    DatePicker("Geçerli olduğu gün", selection: $permit.date, displayedComponents: .date)
                        .environment(\.locale, AppLocale.current)
                    if let n = permit.number { LabeledContent("Belge no", value: n) }
                    if let u = permit.verifyURL, let url = URL(string: u) {
                        Link(destination: url) { Label("Belgeyi doğrula (karekod)", systemImage: "qrcode") }
                    }
                } header: {
                    Text("Belgeden okunan")
                }
                Section {
                    ForEach($permit.quotas, id: \.species) { $q in
                        Stepper(value: Binding(get: { q.count }, set: { q = .init(species: q.species, count: $0) }), in: 0...50) {
                            LabeledContent(LD(q.species), value: "\(q.count)")
                        }
                    }
                } header: {
                    Text("İzin verilen türler ve kota")
                }
                if !result.problems.isEmpty {
                    Section {
                        ForEach(result.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption) }
                    }
                    .foregroundStyle(.orange)
                }
            }
            .navigationTitle("İzin belgesi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Kaydet") { onSave(permit) } }
            }
        }
    }
}

// MARK: - Haritada vurgulanan avlak kartı

struct AvlakCard: View {
    @EnvironmentObject private var model: AppModel
    let avlak: Regulations.Avlak
    let area: AvlakAreas.Area?
    @State private var askRoute = false

    var body: some View {
        let permit = model.permits.active(on: model.now).first { $0.avlak == avlak.name }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "scope").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LD(avlak.name)).font(.subheadline.bold())
                    if !avlak.open {
                        Text("AVA KAPALI").font(.caption.bold()).foregroundStyle(.red)
                    } else if let permit {
                        Text(L("Bugün izinli · %@", permit.quotas.map { "\(LD($0.species)) \($0.count)" }.joined(separator: " · ")))
                            .font(.caption).foregroundStyle(.green)
                    } else if !model.permits.permits.isEmpty {
                        Text("Bu avlak için bugüne ait izin belgesi yok").font(.caption).foregroundStyle(.orange)
                    }
                    if area == nil {
                        Text("Sınır verisi yok").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { model.highlightedAvlak = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if let area {
                HStack {
                    Button { askRoute = true } label: {
                        Label("Yol tarifi", systemImage: "car.fill").frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle(prominent: true)
                    Button { model.focus = MapFocus(coordinate: area.labelPoint, rect: area.boundingRect) } label: {
                        Label("Göster", systemImage: "viewfinder").frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle(prominent: false)
                }
                .confirmationDialog(L("Yol tarifi: %@", LD(avlak.name)), isPresented: $askRoute, titleVisibility: .visible) {
                    let target = area.destination(from: model.location?.coordinate)
                    Button("Google Haritalar") { UIApplication.shared.open(Directions.googleMaps(to: target)) }
                    Button("Apple Haritalar") { Directions.openAppleMaps(to: target, name: LD(avlak.name)) }
                    Button("Vazgeç", role: .cancel) {}
                } message: {
                    Text("Avlağın size en yakın kenarına yol tarifi açılır. Avlak sınırı yaklaşıktır.")
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 18)
    }
}
