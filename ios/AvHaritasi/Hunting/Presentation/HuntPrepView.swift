import SwiftUI

// MARK: - Ava hazırlık: tür seç → tüfek, şok, saçma önerisi (AmmoAdvisor)

struct HuntPrepView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var store: FirearmStore
    /// DEBUG ekran görüntüleri: açılışta seçili türler ve arazi.
    var initialSpecies: [String] = []
    var initialTerrain: String?
    var openChecklist = false

    /// Gün için hatırlanan seçim: "yyyy-MM-dd|tür,tür|arazi".
    @AppStorage("hazirlikSecim") private var saved = ""
    @State private var selected: [String] = []
    @State private var terrain: String?
    @State private var picking = false
    @State private var checklistOpen = false
    @Environment(\.fieldMode) private var fieldMode
    @Environment(\.nightRed) private var night

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLocale.current
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        f.dateFormat = "d MMMM EEEE"
        return f
    }()

    var body: some View {
        Group {
            if let regs = model.regs, let k = AmmoKnowledge.shared {
                content(regs: regs, k: k)
            } else {
                ContentUnavailableView("Bilgi tablosu yüklenemedi", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("Ava hazırlık")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { FirearmListView(store: store) } label: { Label("Tüfeklerim", systemImage: "scope") }
            }
        }
        .onAppear { UsageStats.record(.tufekOnerisi) }
    }

    /// Bugün av günüyse bugün, değilse sonraki av günü.
    private func prepDay(_ regs: Regulations) -> (date: Date, isToday: Bool) {
        let now = AppClock.now()
        if !regs.huntableToday(on: now).isEmpty { return (now, true) }
        if let next = regs.upcomingHuntingDays(from: now, count: 1).first {
            return (next.date.addingTimeInterval(12 * 3600), false)
        }
        return (now, true)
    }

    // swiftlint:disable:next function_body_length
    @ViewBuilder private func content(regs: Regulations, k: AmmoKnowledge) -> some View {
        let day = prepDay(regs)
        let legal = HuntLegalContext(regs: regs, day: day.date)
        let selectable = AmmoAdvisor.selectableSpecies(knowledge: k, legal: legal)
        let request = AdvisorRequest(species: selected, terrain: terrain, firearms: store.items)
        let result = AmmoAdvisor.advise(request, knowledge: k, legal: legal)
        let boar = result.notes.contains(.boarSlugOnly)
        let items = PrepChecklist.items(species: result.species, limit: { regs.limit(for: $0) }, picks: result.picks,
                                        boarHunt: boar, inStateAvlak: inStateAvlak)
        List {
            Section {
                speciesHeader(selectable: selectable, regs: regs)
                terrainChips(k)
            } header: {
                Text(day.isToday
                     ? L("Bugün · %@", Self.dayFormat.string(from: day.date))
                     : L("Sonraki av günü · %@", Self.dayFormat.string(from: day.date)))
            } footer: {
                if !day.isToday {
                    Text("Bugün av günü değil; öneri sonraki av gününde açık türlere göre.")
                }
            }

            if selected.isEmpty {
                Section {
                    Label("Ne avlayacağınızı seçin; uygulama tüfeğinizi, şokunuzu ve saçmanızı önersin.", systemImage: "hand.point.up.left")
                        .foregroundStyle(.secondary)
                }
            } else if let conflict = result.notes.first(where: { if case .boarConflict = $0 { return true } else { return false } }) {
                Section {
                    NoteRow(note: conflict, systemImage: "xmark.octagon.fill", color: .red)
                }
            } else if let first = result.first {
                Section {
                    RecommendationCard(rec: first, rank: 1, prominent: true)
                } header: {
                    Text("1. tercih")
                }
                .listRowBackground(Color.accentColor.opacity(night || fieldMode ? 0.0 : 0.07))
                if let second = result.second {
                    Section("2. tercih") {
                        RecommendationCard(rec: second, rank: 2, prominent: false)
                    }
                }
                if !result.others.isEmpty || !result.unsuitable.isEmpty {
                    Section {
                        DisclosureGroup(L("Diğer tüfekler (%@)", String(result.others.count + result.unsuitable.count))) {
                            ForEach(result.others) { r in
                                RecommendationCard(rec: r, rank: 3, prominent: false)
                            }
                            ForEach(result.unsuitable) { u in UnsuitableRow(item: u) }
                        }
                    }
                }
                reasonsSection(first)
            } else {
                missingSection(result)
            }

            let notes = result.notes.filter { $0 != .pattern && !isConflict($0) }
            if !selected.isEmpty, !notes.isEmpty {
                Section("Dikkat") {
                    ForEach(notes, id: \.self) { n in
                        NoteRow(note: n, systemImage: icon(for: n), color: n == .boarSlugOnly || n == .takoz ? .red : .orange)
                    }
                }
            }

            if !result.species.isEmpty {
                Section {
                    ForEach(result.species, id: \.self) { name in
                        if let s = k.species(named: name) { AimRow(species: s) }
                    }
                } header: {
                    Text("Nişan ve etik")
                }
                Section {
                    NavigationLink {
                        PrepChecklistView(items: items, dayKey: Regulations.dayString(day.date),
                                          title: Self.dayFormat.string(from: day.date))
                    } label: {
                        Label("Kontrol listesi", systemImage: "checklist")
                            .font(.headline)
                            .frame(minHeight: fieldMode ? FieldTheme.minTarget : 44)
                    }
                }
            }

            Section {
                Text(AdvisorNote.pattern.text).font(.footnote).foregroundStyle(.secondary)
                NavigationLink("Saçma ve şok başvuru tablosu") { AmmoReferenceView() }
            }
        }
        .navigationDestination(isPresented: $checklistOpen) {
            PrepChecklistView(items: items, dayKey: Regulations.dayString(day.date), title: Self.dayFormat.string(from: day.date))
        }
        .sheet(isPresented: $picking) {
            SpeciesPickerSheet(species: selectable, regs: regs, selected: $selected)
        }
        .onAppear { restore(dayKey: Regulations.dayString(day.date), valid: Set(selectable.map(\.name))) }
        .onChange(of: selected) { _, _ in persist(dayKey: Regulations.dayString(day.date)) }
        .onChange(of: terrain) { _, _ in persist(dayKey: Regulations.dayString(day.date)) }
    }

    private func isConflict(_ n: AdvisorNote) -> Bool { if case .boarConflict = n { return true } else { return false } }

    private func icon(for n: AdvisorNote) -> String {
        switch n {
        case .takoz: return "lock.fill"
        case .boarSlugOnly: return "exclamationmark.octagon.fill"
        case .wetlandNonToxic: return "drop.fill"
        case .lowConfidence: return "questionmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var inStateAvlak: Bool {
        let name = model.assessment.unitName ?? model.highlightedAvlak ?? ""
        return name.contains("D.A.") || name.contains("Devlet Avlağı")
    }

    // MARK: Tür ve arazi

    @ViewBuilder private func speciesHeader(selectable: [AmmoKnowledge.Species], regs: Regulations) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if selected.isEmpty {
                Text("Avlanacak tür").font(.headline)
            } else {
                FlowLayout {
                    ForEach(selected, id: \.self) { s in
                        SelectChip(title: LD(s), systemImage: "xmark", selected: true) { selected.removeAll { $0 == s } }
                            .accessibilityLabel(L("%@, kaldır", LD(s)))
                    }
                }
            }
            Button { picking = true } label: {
                Label(selected.isEmpty ? L("Tür seç") : L("Tür ekle / değiştir"), systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: fieldMode ? FieldTheme.minTarget : 44)
            }
            .glassButtonStyle(prominent: selected.isEmpty)
            .disabled(selectable.isEmpty)
            if selectable.isEmpty {
                Text("Bu gün açık tür yok.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func terrainChips(_ k: AmmoKnowledge) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Arazi (isteğe bağlı)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(k.terrains) { t in
                        SelectChip(title: LD(t.tr), systemImage: terrainIcon(t.id), selected: terrain == t.id) {
                            terrain = terrain == t.id ? nil : t.id
                        }
                    }
                }
            }
            if let t = k.terrain(terrain) {
                Text(LD(t.note)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func terrainIcon(_ id: String) -> String {
        switch id {
        case "orman_cali": return "tree.fill"
        case "acik_mera": return "sun.horizon.fill"
        case "sulak_alan": return "drop.fill"
        default: return "arrow.left.and.right"
        }
    }

    // MARK: Gerekçe ve eksik

    private func reasonsSection(_ first: Recommendation) -> some View {
        Section {
            DisclosureGroup("Neden bu?") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(first.reasons, id: \.self) { r in
                        NoteRow(note: r, systemImage: "checkmark.circle.fill", color: .green)
                    }
                    Text("Sıralama: önce yasal ve güvenlik kuralları elenir; sonra elinizdeki şokların önerilene uyumu, yatak (magnum) ihtiyacı, kalibre, namlu boyu–arazi ve ağırlık–yürüyüş uyumu puanlanır.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private func missingSection(_ result: AdvisorResult) -> some View {
        Section {
            Label("Uygun tüfek yok", systemImage: "xmark.circle.fill")
                .font(.headline).foregroundStyle(HuntPalette.tint(.red, night: night))
            ForEach(result.missing, id: \.self) { m in
                NoteRow(note: m, systemImage: "wrench.and.screwdriver.fill", color: .orange)
            }
            ForEach(result.unsuitable) { u in UnsuitableRow(item: u) }
            NavigationLink { FirearmListView(store: store) } label: {
                Label(store.items.isEmpty ? L("Tüfek ekle") : L("Tüfeklerim"), systemImage: "scope")
                    .frame(minHeight: fieldMode ? FieldTheme.minTarget : 44)
            }
        } header: {
            Text("Ne eksik?")
        }
    }

    // MARK: Seçimi gün için hatırla

    private func restore(dayKey: String, valid: Set<String>) {
        if !initialSpecies.isEmpty {
            selected = initialSpecies.filter(valid.contains)
            terrain = initialTerrain
            if openChecklist { checklistOpen = true }
            return
        }
        guard selected.isEmpty else { return }
        let parts = saved.components(separatedBy: "|")
        guard parts.count == 3, parts[0] == dayKey else { return }
        selected = parts[1].split(separator: ",").map(String.init).filter(valid.contains)
        terrain = parts[2].isEmpty ? nil : parts[2]
    }

    private func persist(dayKey: String) {
        saved = [dayKey, selected.joined(separator: ","), terrain ?? ""].joined(separator: "|")
    }
}

// MARK: - Öneri kartı

struct RecommendationCard: View {
    let rec: Recommendation
    let rank: Int
    let prominent: Bool
    @Environment(\.fieldMode) private var fieldMode
    @Environment(\.nightRed) private var night

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 14 : 10) {
            HStack(spacing: 10) {
                FirearmIcon(type: rec.firearm.type)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.firearm.name)
                        .font(prominent ? (fieldMode ? .title.bold() : .title2.bold()) : .headline)
                    Text(rec.firearm.type.title + " · " + rec.firearm.specLine)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !rec.barrels.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(rec.barrels, id: \.index) { b in BarrelView(plan: b, count: rec.barrels.count, large: prominent) }
                }
            }
            ForEach(Array(rec.ammo.enumerated()), id: \.offset) { _, a in
                AmmoLine(choice: a, showSpecies: rec.ammo.count > 1, large: prominent)
            }
            if prominent {
                ForEach(rec.reasons.prefix(3), id: \.self) { r in
                    NoteRow(note: r, systemImage: "checkmark.circle.fill", color: .green)
                }
            }
            ForEach(rec.cautions, id: \.self) { c in
                NoteRow(note: c)
            }
        }
        .padding(.vertical, prominent ? 8 : 4)
    }
}

struct BarrelView: View {
    let plan: BarrelPlan
    let count: Int
    let large: Bool
    @Environment(\.nightRed) private var night

    private var shown: Choke { plan.fixed ? (plan.use ?? plan.want) : plan.want }

    private var status: String {
        switch plan.match {
        case .exact: return plan.fixed ? L("Namluda") : L("Elinizde")
        case .adjacent: return plan.fixed ? L("Önerilen: %@", plan.want.badge) : L("Yerine %@", plan.use?.badge ?? "")
        case .missing: return plan.fixed ? L("Önerilen: %@", plan.want.badge) : L("Elinizde yok")
        case .unusable: return L("Kullanmayın")
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(count == 2 ? L("%@. atış", String(plan.index + 1)) : L("Şok"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ChokeBadge(choke: shown, match: plan.match, size: large ? 58 : 44)
            Text(status).font(.caption2.weight(.medium))
                .foregroundStyle(plan.match == .exact ? Color.secondary : HuntPalette.warn(night))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%@: %@ numara şok, %@. %@", count == 2 ? L("%@. atış", String(plan.index + 1)) : L("Şok"),
                              shown.badge, shown.title, status))
    }
}

struct AmmoLine: View {
    let choice: AmmoChoice
    let showSpecies: Bool
    let large: Bool
    @Environment(\.nightRed) private var night

    var body: some View {
        switch choice {
        case .shot(let l):
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 0) {
                    Text(verbatim: AmmoFormat.shotNumber(l.size))
                        .font(.system(size: large ? 38 : 28, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("numara").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(minWidth: large ? 64 : 50)
                VStack(alignment: .leading, spacing: 3) {
                    if showSpecies {
                        Text(l.species.map(LD).joined(separator: ", ")).font(.caption.weight(.semibold))
                    }
                    Text([l.mm.map { L("%@ mm saçma", AmmoFormat.mm($0)) }, AmmoFormat.grams(l.grams)].compactMap { $0 }.joined(separator: " · "))
                        .font(large ? .headline : .subheadline)
                    HStack(spacing: 6) {
                        MaterialTag(text: l.material.title, color: l.material == .steel ? HuntPalette.steel(night) : .secondary)
                        Text(L("%@ mm fişek", String(l.shellMm))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(choice.summary)
        case .slug(let g, let mm):
            HStack(spacing: 12) {
                Image(systemName: "circle.fill").font(.system(size: large ? 30 : 22)).frame(minWidth: large ? 64 : 50)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tek kurşun").font(large ? .title3.bold() : .headline)
                    Text([g.map(AmmoFormat.grams), L("%@ mm fişek", String(mm))].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .rifle(let c):
            HStack(spacing: 12) {
                Image(systemName: "scope").font(.system(size: large ? 30 : 22)).frame(minWidth: large ? 64 : 50)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: c).font(large ? .title3.bold() : .headline)
                    Text("Kontrollü açılan av mermisi").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct UnsuitableRow: View {
    let item: UnsuitableFirearm

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.firearm.name).font(.subheadline.bold())
                Spacer()
                Text("Uygun değil").font(.caption.bold()).foregroundStyle(.secondary)
            }
            ForEach(item.reasons, id: \.self) { r in
                Text(r.text).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tür için mesafe, nişan ve etik notu (bilgi tablosundan).
struct AimRow: View {
    let species: AmmoKnowledge.Species

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Tipik mesafe %@–%@ m · etik üst sınır %@ m", String(species.distanceM.first ?? 0),
                       String(species.distanceM.last ?? 0), String(species.maxEthicalRangeM)))
                    .font(.subheadline.weight(.semibold))
                Text(LD(species.aim)).font(.callout)
                if !species.notes.isEmpty { Text(LD(species.notes)).font(.callout).foregroundStyle(.secondary) }
                if let s = species.slug { Text(LD(s.note)).font(.caption).foregroundStyle(.secondary) }
                if let r = species.rifle { Text(LD(r.note)).font(.caption).foregroundStyle(.secondary) }
                if species.confidence != "high" {
                    Text(species.isLowConfidence ? L("Bilgi güveni: düşük") : L("Bilgi güveni: orta"))
                        .font(.caption.bold()).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label { Text(LD(species.name)) } icon: { SpeciesIcon.image(for: species.name, regs: nil) }
        }
    }
}

// MARK: - Tür seçimi

struct SpeciesPickerSheet: View {
    let species: [AmmoKnowledge.Species]
    let regs: Regulations
    @Binding var selected: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fieldMode) private var fieldMode

    var body: some View {
        NavigationStack {
            List {
                let birds = species.filter(\.isBird)
                let mammals = species.filter { !$0.isBird }
                if !birds.isEmpty {
                    Section("Kuşlar") { ForEach(birds) { row($0) } }
                }
                if !mammals.isEmpty {
                    Section {
                        ForEach(mammals) { row($0) }
                    } header: {
                        Text("Kara avı")
                    } footer: {
                        Text("Domuz avında yalnızca tek kurşun bulundurulabildiği için domuz, saçmayla avlanan türlerle birlikte seçilemez; seçince diğerleri kaldırılır.")
                    }
                }
                Section {
                    Text(L("Yalnızca bu gün açık ve yasal türler listelenir. %@", LD(regs.provinceBannedNote)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tür seç")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
                if !selected.isEmpty {
                    ToolbarItem(placement: .cancellationAction) { Button("Temizle") { selected = [] } }
                }
            }
        }
    }

    private func row(_ s: AmmoKnowledge.Species) -> some View {
        let on = selected.contains(s.name)
        return Button { toggle(s) } label: {
            HStack(spacing: 12) {
                SpeciesIcon.image(for: s.name, regs: regs).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LD(s.name)).font(.body)
                    if let l = regs.limit(for: s.name) {
                        Text(L("Günlük: %@", LD(l))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .frame(minHeight: fieldMode ? FieldTheme.minTarget : 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ s: AmmoKnowledge.Species) {
        if let i = selected.firstIndex(of: s.name) {
            selected.remove(at: i)
            return
        }
        let byName = Dictionary(uniqueKeysWithValues: species.map { ($0.name, $0) })
        if s.slug != nil {
            // Domuz: saçma gerektiren türler kaldırılır
            selected.removeAll { name in
                guard let other = byName[name] else { return true }
                return other.slug == nil && other.rifle == nil
            }
        } else if s.rifle == nil {
            selected.removeAll { name in byName[name]?.slug != nil }
        }
        selected.append(s.name)
    }
}
