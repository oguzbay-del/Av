import SwiftUI

/// Liquid Glass (iOS 26) ile yüzen harita kontrolleri; eski iOS'ta buzlu cam (material).
/// `#if compiler(>=6.2)`: Xcode 26 ile derlenince cam API'leri kullanılır, Xcode 16 ile derleme de bozulmaz.
extension View {
    /// Daire biçimli cam (harita düğmeleri).
    @ViewBuilder func glassCircle(interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: Circle())
        } else {
            background(.regularMaterial, in: Circle())
        }
        #else
        background(.regularMaterial, in: Circle())
        #endif
    }

    /// Kapsül biçimli cam (rozetler, göstergeler).
    @ViewBuilder func glassCapsule(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
        #else
        background(.regularMaterial, in: Capsule())
        #endif
    }

    /// Köşeleri yuvarlatılmış cam (kartlar).
    @ViewBuilder func glassCard(cornerRadius: CGFloat = 16) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #else
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }

    /// Kart içindeki birincil/ikincil düğmeler: iOS 26'da cam düğme biçimi.
    @ViewBuilder func glassButtonStyle(prominent: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
        #else
        if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        #endif
    }
}

extension View {
    /// iOS 26: liste kaydırılınca sekme çubuğu küçülür (içeriğe yer açar).
    @ViewBuilder func minimizeTabBarOnScroll() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Yakın cam öğeleri tek bir cam yüzey gibi birleştirir (dokununca akışkan geçiş).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Tür simgesi: av türüne göre özel simge (Assets'te "av.*" sembolleri) ya da SF Symbol.
enum SpeciesIcon {
    static func image(for species: String, regs: Regulations?) -> Image {
        let ducks = regs?.groups.first { $0.species.contains("Yeşilbaş") }?.species ?? []
        switch species {
        case "Yaban domuzu": return Image("av.domuz")
        case "Yaban tavşanı": return Image(systemName: "hare.fill")
        case "Tilki", "Çakal": return Image(systemName: "pawprint.fill")
        case "Sakarmeke", "Sakarca": return Image("av.ordek")
        default:
            if ducks.contains(species) || species.contains("kaz") || species.contains("ördek") { return Image("av.ordek") }
            if species == "Bıldırcın" || species.lowercased().contains("keklik") { return Image("av.bildircin") }
            return Image(systemName: "bird.fill")
        }
    }
}
