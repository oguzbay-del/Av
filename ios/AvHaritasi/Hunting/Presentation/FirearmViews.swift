import SwiftUI

// MARK: - Tüfeklerim: liste ve adım adım ekle/düzenle

struct FirearmListView: View {
    @ObservedObject var store: FirearmStore
    @State private var editing: Firearm?
    @State private var adding = false
    /// DEBUG ekran görüntüleri: düzenleme formu bu adımda açılır (`-tufekEkleAdim`).
    @State private var startStep: Int?

    var body: some View {
        List {
            if store.items.isEmpty {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "scope").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Henüz tüfek yok").font(.title3.bold())
                        Text("Tüfeğinizin tipini, kalibresini, namlu boyunu ve elinizdeki şokları girin. Ava hazırlık ekranı türe göre hangi tüfeği, şoku ve saçmayı alacağınızı önerir.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button { adding = true } label: {
                            Label("Tüfek ekle", systemImage: "plus").frame(maxWidth: .infinity).frame(minHeight: 44)
                        }
                        .glassButtonStyle(prominent: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                Section {
                    ForEach(store.items) { f in
                        Button { editing = f } label: { FirearmRow(firearm: f) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { idx in idx.map { store.items[$0].id }.forEach(store.delete) }
                } header: {
                    Text(L("%@ / %@ tüfek", String(store.items.count), String(FirearmStore.maxCount)))
                } footer: {
                    Text("Düzenlemek için dokunun, silmek için sola kaydırın.")
                }
            }
            Section {
                Label("Yalnızca bu telefonda saklanır; hiçbir yere gönderilmez ve yedeğe alınmaz.", systemImage: "lock.iphone")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Tüfeklerim")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Tüfek ekle", systemImage: "plus") }
                    .disabled(!store.canAdd)
            }
        }
        .sheet(isPresented: $adding) {
            FirearmEditorView(store: store, original: nil)
        }
        .sheet(item: $editing) { f in
            FirearmEditorView(store: store, original: f, startStep: startStep)
        }
        .task {
            #if DEBUG
            if let n = ScreenshotArguments.value("-tufekEkleAdim").flatMap(Int.init), let f = store.items.first {
                startStep = n
                try? await Task.sleep(for: .seconds(0.6))
                editing = f
            }
            #endif
        }
    }
}

struct FirearmRow: View {
    let firearm: Firearm
    @Environment(\.nightRed) private var night

    var body: some View {
        HStack(spacing: 12) {
            FirearmIcon(type: firearm.type)
            VStack(alignment: .leading, spacing: 3) {
                Text(firearm.name).font(.headline)
                Text(firearm.type.title + " · " + firearm.specLine).font(.subheadline).foregroundStyle(.secondary)
                if let c = firearm.chokeLine {
                    Text(c).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if firearm.steelProof == .yes {
                MaterialTag(text: L("Çelik"), color: HuntPalette.steel(night))
            }
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Adım adım tüfek formu: tip → kalibre ve yatak → namlu → şoklar → çelik → ad.
struct FirearmEditorView: View {
    @ObservedObject var store: FirearmStore
    let original: Firearm?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fieldMode) private var fieldMode
    @State private var draft: Firearm
    @State private var step: Step = .type
    @State private var error: String?

    enum Step: Int, CaseIterable {
        case type, caliber, barrel, chokes, steel, name

        var title: String {
            switch self {
            case .type: return L("Tüfek tipi")
            case .caliber: return L("Kalibre ve yatak")
            case .barrel: return L("Namlu boyu")
            case .chokes: return L("Şoklar")
            case .steel: return L("Çelik saçma")
            case .name: return L("Ad")
            }
        }
    }

    init(store: FirearmStore, original: Firearm?, startStep: Int? = nil) {
        self.store = store
        self.original = original
        _draft = State(initialValue: original ?? Firearm(name: "", type: .superpoze, gauge: .g12, chamber: .mm76,
                                                         barrelCm: 71, mobileChokes: true, ownedChokes: [.modified, .improvedCylinder]))
        let s = startStep.flatMap(Step.init(rawValue:)) ?? (original == nil ? .type : .name)
        _step = State(initialValue: s)
    }

    private var steps: [Step] { draft.type.isRifled ? [.type, .caliber, .barrel, .name] : Step.allCases }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProgressView(value: Double(index + 1), total: Double(steps.count))
                        .accessibilityLabel(L("Adım %@ / %@", String(index + 1), String(steps.count)))
                    Text(L("Adım %@ / %@ · %@", String(index + 1), String(steps.count), step.title))
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                switch step {
                case .type: typeStep
                case .caliber: caliberStep
                case .barrel: barrelStep
                case .chokes: chokeStep
                case .steel: steelStep
                case .name: nameStep
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(original == nil ? L("Tüfek ekle") : L("Tüfeği düzenle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                if original != nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Kaydet") { save() }.disabled(!draft.isValid) }
                }
            }
            .safeAreaInset(edge: .bottom) { navButtons }
            .animation(.default, value: step)
        }
    }

    // MARK: Gezinme

    private var navButtons: some View {
        HStack(spacing: 12) {
            if index > 0 {
                Button { step = steps[index - 1] } label: {
                    Label("Geri", systemImage: "chevron.left").frame(maxWidth: .infinity).frame(minHeight: fieldMode ? FieldTheme.minTarget : 46)
                }
                .glassButtonStyle(prominent: false)
            }
            if step == steps.last {
                Button { save() } label: {
                    Label("Kaydet", systemImage: "checkmark").frame(maxWidth: .infinity).frame(minHeight: fieldMode ? FieldTheme.minTarget : 46)
                }
                .glassButtonStyle(prominent: true)
                .disabled(!draft.isValid)
            } else {
                Button { step = steps[index + 1] } label: {
                    Label("İleri", systemImage: "chevron.right").frame(maxWidth: .infinity).frame(minHeight: fieldMode ? FieldTheme.minTarget : 46)
                }
                .glassButtonStyle(prominent: true)
                .disabled(!stepValid)
            }
        }
        .font(.headline)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var stepValid: Bool {
        switch step {
        case .caliber: return draft.type.isRifled ? !(draft.rifleCaliber ?? "").isEmpty : (draft.gauge != nil && draft.chamber != nil)
        case .chokes: return draft.mobileChokes || draft.fixedChokes.count == draft.type.barrelCount
        default: return true
        }
    }

    private func save() {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = suggestedName }
        do {
            try store.save(draft)
            dismiss()
        } catch FirearmStore.StoreError.limitReached {
            error = L("En çok %@ tüfek eklenebilir.", String(FirearmStore.maxCount))
        } catch {
            self.error = L("Eksik bilgi var: önceki adımları kontrol edin.")
        }
    }

    private var suggestedName: String {
        draft.type.isRifled ? L("Yivli %@", draft.rifleCaliber ?? "") : "\(draft.type.title) \(draft.gauge?.rawValue ?? "")"
    }

    // MARK: Adımlar

    private var typeStep: some View {
        Section {
            ForEach(FirearmType.allCases) { t in
                Button {
                    setType(t)
                    step = steps[1]
                } label: {
                    HStack(spacing: 12) {
                        FirearmIcon(type: t)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.headline)
                            Text(typeHelp(t)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if draft.type == t { Image(systemName: "checkmark").font(.headline).foregroundStyle(Color.accentColor) }
                    }
                    .frame(minHeight: fieldMode ? FieldTheme.minTarget : 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(draft.type == t ? .isSelected : [])
            }
        } header: {
            Text("Tüfeğiniz hangi tip?")
        }
    }

    private func typeHelp(_ t: FirearmType) -> String {
        switch t {
        case .yariOtomatik: return L("Tek namlu, hazneli; avda takoz (2+1) gerekir.")
        case .pompali: return L("Tek namlu, elle doldurmalı; avda takoz (2+1) gerekir.")
        case .superpoze: return L("Üst üste iki namlu; her namlunun ayrı şoku.")
        case .cifte: return L("Yan yana iki namlu; her namlunun ayrı şoku.")
        case .tekKirma: return L("Tek namlu, tek fişek.")
        case .yivli: return L("Mermi atar; kuş ve tavşanda kullanılamaz.")
        }
    }

    private func setType(_ t: FirearmType) {
        draft.type = t
        if t.isRifled {
            draft.gauge = nil
            draft.chamber = nil
            if draft.rifleCaliber == nil { draft.rifleCaliber = ".308 Win" }
            if draft.barrelCm > 61 { draft.barrelCm = 56 }
        } else {
            draft.rifleCaliber = nil
            if draft.gauge == nil { draft.gauge = .g12 }
            if draft.chamber == nil { draft.chamber = .mm76 }
            if draft.fixedChokes.count != t.barrelCount {
                draft.fixedChokes = t.barrelCount == 2 ? [.improvedCylinder, .improvedModified] : [.modified]
            }
        }
    }

    @ViewBuilder private var caliberStep: some View {
        if draft.type.isRifled {
            Section {
                ForEach(RifleCaliber.all) { c in
                    Button { draft.rifleCaliber = c.name } label: {
                        HStack {
                            Text(verbatim: c.name).font(.headline)
                            Spacer()
                            if draft.rifleCaliber == c.name { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .frame(minHeight: fieldMode ? FieldTheme.minTarget : 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                TextField("Başka kalibre", text: Binding(
                    get: { RifleCaliber.named(draft.rifleCaliber) == nil ? (draft.rifleCaliber ?? "") : "" },
                    set: { draft.rifleCaliber = $0.isEmpty ? nil : $0 }))
            } header: {
                Text("Yivli kalibre")
            } footer: {
                Text("Domuz için en az 6,5 mm (ör. .308 Win, 7x64, 9.3x62) önerilir; .222/.223 sınıfı tilki ve çakal içindir.")
            }
        } else {
            Section {
                FlowLayout {
                    ForEach(Gauge.allCases) { g in
                        SelectChip(title: L("%@ ga", g.rawValue), selected: draft.gauge == g) { draft.gauge = g }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Kalibre")
            } footer: {
                Text("Namlu üzerinde ya da kundak altında yazar (ör. \"12\", \"20\"). Türkiye'de en yaygını 12.")
            }
            Section {
                FlowLayout {
                    ForEach(ChamberLength.allCases) { c in
                        SelectChip(title: L("%@ mm", String(c.rawValue)), selected: draft.chamber == c) { draft.chamber = c }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Fişek yatağı")
            } footer: {
                Text("Namlu üzerinde yazar: 70 mm (2¾\"), 76 mm magnum (3\"), 89 mm süper magnum (3½\"). Uygulama yataktan uzun fişek önermez.")
            }
        }
    }

    private var barrelStep: some View {
        Group {
            Section {
                HStack {
                    Text(L("%@ cm", String(draft.barrelCm)))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    Spacer()
                    Stepper("Namlu boyu", value: $draft.barrelCm, in: 40...90).labelsHidden()
                }
                FlowLayout {
                    ForEach([51, 56, 61, 66, 71, 76, 81], id: \.self) { cm in
                        SelectChip(title: String(cm), selected: draft.barrelCm == cm) { draft.barrelCm = cm }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Namlu boyu")
            } footer: {
                Text("Kısa namlu (56–66 cm) çalı ve çullukta hızlıdır; uzun namlu (71–76 cm) geçit ve su kuşunda salınımı düzgün yapar.")
            }
            Section {
                FlowLayout {
                    ForEach(WeightClass.allCases) { w in
                        SelectChip(title: w.title, selected: draft.weight == w) { draft.weight = draft.weight == w ? nil : w }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Ağırlık (isteğe bağlı)")
            } footer: {
                Text("Yürüyüş avında hafif tüfek öne çıkar.")
            }
        }
    }

    private var chokeStep: some View {
        Group {
            Section {
                Picker("Şok sistemi", selection: $draft.mobileChokes) {
                    Text("Mobil (değişir)").tag(true)
                    Text("Sabit").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(minHeight: fieldMode ? FieldTheme.minTarget : 36)
            } footer: {
                Text("Mobil şok namlu ağzına vidalanır ve değiştirilebilir. Sabit şoklu namluda şok değişmez.")
            }
            if draft.mobileChokes {
                Section {
                    FlowLayout {
                        ForEach(Choke.allCases) { c in
                            let on = draft.ownedChokes.contains(c)
                            SelectChip(title: c == .paradox ? L("Paradoks") : "\(c.badge) · \(c.shortName)", selected: on) {
                                if on { draft.ownedChokes.removeAll { $0 == c } } else { draft.ownedChokes.append(c) }
                                draft.ownedChokes.sort()
                            }
                            .accessibilityLabel(c.title)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Elinizdeki şoklar")
                } footer: {
                    Text("Şokun üstündeki yıldız ya da çentik sayısı numarasıdır: 1 tam (en dar), 5 silindir (en açık). Paradoks yalnızca tek kurşun içindir.")
                }
            } else {
                ForEach(0..<max(1, draft.type.barrelCount), id: \.self) { i in
                    Section {
                        FlowLayout {
                            ForEach(Choke.shotChokes) { c in
                                SelectChip(title: "\(c.badge) · \(c.shortName)", selected: draft.fixedChokes.indices.contains(i) && draft.fixedChokes[i] == c) {
                                    setFixed(i, c)
                                }
                                .accessibilityLabel(c.title)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(draft.type.barrelCount == 2
                             ? (i == 0 ? L("1. atış namlusu (alt / sağ)") : L("2. atış namlusu (üst / sol)"))
                             : L("Namlunun şoku"))
                    }
                }
            }
        }
    }

    private func setFixed(_ i: Int, _ c: Choke) {
        let n = max(1, draft.type.barrelCount)
        if draft.fixedChokes.count != n { draft.fixedChokes = Array(repeating: .modified, count: n) }
        draft.fixedChokes[i] = c
    }

    private var steelStep: some View {
        Section {
            ForEach(SteelProof.allCases) { s in
                Button { draft.steelProof = s } label: {
                    HStack(spacing: 12) {
                        Image(systemName: draft.steelProof == s ? "largecircle.fill.circle" : "circle")
                            .font(.title2).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.headline)
                            Text(steelHelp(s)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: fieldMode ? FieldTheme.minTarget : 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(draft.steelProof == s ? .isSelected : [])
            }
        } header: {
            Text("Tüfek çelik saçmaya uygun mu?")
        } footer: {
            Text("Namluda \"STEEL\" yazısı ya da zambak (fleur-de-lys) biçimli çelik muayene damgası varsa uygundur. Emin değilseniz \"Bilmiyorum\" seçin: uygulama çelik önermez, kurşun önerir.")
        }
    }

    private func steelHelp(_ s: SteelProof) -> String {
        switch s {
        case .yes: return L("Namluda çelik damgası var.")
        case .no: return L("Eski ya da ince namlu; çelik atılmaz.")
        case .unknown: return L("Damgayı bilmiyorum.")
        }
    }

    private var preview: Firearm {
        var f = draft
        if f.name.trimmingCharacters(in: .whitespaces).isEmpty { f.name = suggestedName }
        return f
    }

    private var nameStep: some View {
        Group {
            Section {
                TextField(suggestedName, text: $draft.name)
                    .font(.title3)
                    .frame(minHeight: fieldMode ? FieldTheme.minTarget : 44)
            } header: {
                Text("Tüfeğe bir ad verin")
            } footer: {
                Text("Öneride bu adı görürsünüz (ör. \"Babamın çiftesi\").")
            }
            Section("Özet") {
                FirearmRow(firearm: preview)
            }
            if original != nil {
                Section {
                    Button("Tüfeği sil", role: .destructive) {
                        store.delete(draft.id)
                        dismiss()
                    }
                }
            }
        }
    }
}
