import SwiftUI

// MARK: - Tüfek/fişek ekranlarında ortak küçük görünümler
// Renkler gece (kırmızı) temasında tek kırmızı tona iner; saha modunda dokunma alanları ≥ 60 pt.

enum HuntPalette {
    static func tint(_ c: Color, night: Bool) -> Color { night ? FieldTheme.nightAccent : c }
    static func good(_ night: Bool) -> Color { tint(.green, night: night) }
    static func warn(_ night: Bool) -> Color { tint(.orange, night: night) }
    static func steel(_ night: Bool) -> Color { tint(.blue, night: night) }
}

/// Seçilebilir kapsül (çip). Saha modunda büyür.
struct SelectChip: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    let action: () -> Void
    @Environment(\.fieldMode) private var fieldMode
    @Environment(\.nightRed) private var night

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(fieldMode ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
            .padding(.horizontal, fieldMode ? 18 : 14)
            .frame(minHeight: fieldMode ? FieldTheme.minTarget : 40)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? HuntPalette.tint(.accentColor, night: night) : Color.secondary.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Şok rozeti: büyük numara, altında kısa ad; eşleşmeye göre çerçeve rengi.
struct ChokeBadge: View {
    let choke: Choke
    var match: BarrelPlan.Match = .exact
    var size: CGFloat = 54
    @Environment(\.nightRed) private var night
    @Environment(\.fieldMode) private var fieldMode

    private var color: Color {
        switch match {
        case .exact: return HuntPalette.good(night)
        case .adjacent, .missing: return HuntPalette.warn(night)
        case .unusable: return .secondary
        }
    }

    var body: some View {
        let s = fieldMode ? size * 1.2 : size
        VStack(spacing: 0) {
            Text(verbatim: choke.badge)
                .font(.system(size: s * 0.46, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(choke.shortName)
                .font(.system(size: s * 0.2, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: s, height: s)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: match == .missing ? [5, 3] : []))
        )
    }
}

/// Kurşun / çelik / tek kurşun etiketi.
struct MaterialTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Simgeli kısa not satırı (uyarı, gerekçe).
struct NoteRow: View {
    let note: AdvisorNote
    var systemImage = "exclamationmark.triangle.fill"
    var color: Color = .orange
    @Environment(\.nightRed) private var night

    var body: some View {
        Label {
            Text(note.text).font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(HuntPalette.tint(color, night: night))
        }
    }
}

/// Tüfek tipinin simgesi (daire içinde).
struct FirearmIcon: View {
    let type: FirearmType
    var body: some View {
        Image(systemName: type.isRifled ? "scope" : (type.barrelCount == 2 ? "line.3.horizontal" : "minus"))
            .font(.title3.weight(.semibold))
            .frame(width: 40, height: 40)
            .background(Color.accentColor.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Satır satır sarılan yatay yerleşim (çipler için).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
