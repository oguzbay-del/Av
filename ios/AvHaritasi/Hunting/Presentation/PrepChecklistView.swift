import SwiftUI

/// Ava hazırlık kontrol listesi: işaretlenebilir, gün için hatırlanır (gün değişince boşalır).
struct PrepChecklistView: View {
    let items: [PrepChecklist.Item]
    let dayKey: String
    let title: String
    @AppStorage(ChecklistDay.storageKey) private var raw = ""
    @Environment(\.fieldMode) private var fieldMode
    @Environment(\.nightRed) private var night

    private var state: ChecklistDay {
        let stored = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(ChecklistDay.self, from: $0) }
        return ChecklistDay.current(stored: stored, today: dayKey)
    }

    var body: some View {
        let s = state
        let done = items.filter { s.checked.contains($0.id) }.count
        List {
            Section {
                ProgressView(value: Double(done), total: Double(max(1, items.count)))
                    .tint(HuntPalette.good(night))
                Text(L("%@ / %@ hazır", String(done), String(items.count)))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } header: {
                Text(title)
            }
            Section {
                ForEach(items) { item in
                    let on = s.checked.contains(item.id)
                    Button { toggle(item.id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(fieldMode ? .largeTitle : .title2)
                                .foregroundStyle(on ? HuntPalette.good(night) : (item.important ? HuntPalette.warn(night) : .secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(fieldMode ? .title3.weight(.semibold) : .body.weight(item.important ? .semibold : .regular))
                                    .strikethrough(on, color: .secondary)
                                if let d = item.detail {
                                    Text(d).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: fieldMode ? FieldTheme.minTarget : 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .sensoryFeedback(.selection, trigger: on)
                }
            } footer: {
                Text("İşaretler yalnızca bu gün için bu telefonda hatırlanır.")
            }
            if done > 0 {
                Section {
                    Button("İşaretleri temizle", role: .destructive) { save(ChecklistDay(day: dayKey, checked: [])) }
                }
            }
        }
        .navigationTitle("Kontrol listesi")
    }

    private func toggle(_ id: String) {
        var s = state
        s.toggle(id)
        save(s)
    }

    private func save(_ s: ChecklistDay) {
        if let d = try? JSONEncoder().encode(s), let str = String(data: d, encoding: .utf8) { raw = str }
    }
}
